-- | The evaluation report and its aggregation. A 'Report' summarises a run over
-- a dataset: the mean per-example score, pass/fail counts, summed token usage and
-- cost, total latency, and a per-example breakdown ('ExampleResult', retained in
-- dataset order for failure analysis). 'mkReport' is the pure aggregator;
-- 'renderReportText' is a deterministic human-readable rendering reused by the
-- CLI (@docs/plans/12-cli-and-developer-experience.md@) and by golden tests.
--
-- 'EvalConfig' carries the run knobs (bounded 'concurrency', the 'FailurePolicy'
-- for per-example errors, and 'numSamples' per example for multi-sample metrics);
-- 'defaultEvalConfig' scores failures @0@ and keeps going.
module Shikumi.Eval.Report
  ( -- * Per-example outcome
    ExampleResult (..),
    FailureReason (..),
    FailurePolicy (..),

    -- * Run configuration
    EvalConfig (..),
    defaultEvalConfig,

    -- * Usage totals
    UsageTotals (..),
    emptyUsageTotals,

    -- * The report
    Report (..),
    mkReport,
    renderReportText,
  )
where

import Data.Maybe (isJust, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Generics (Generic)
import Numeric (showFFloat)
import Numeric.Natural (Natural)
import Shikumi.Eval.Types (Score, scoreZero, unScore)

-- | The reason an example did not complete normally.
data FailureReason
  = -- | @runProgram@ threw a 'Shikumi.Error.ShikumiError' (rendered to text)
    ProgramError !Text
  | -- | the metric itself failed (an effectful metric raised an error)
    MetricError !Text
  | -- | the example exceeded its time budget
    TimedOut
  deriving stock (Eq, Show)

-- | What to do when an example fails.
data FailurePolicy
  = -- | record the failure, assign this score, continue
    FailScore !Score
  | -- | re-throw, ending the whole run
    FailAbort
  deriving stock (Eq, Show)

-- | Per-example outcome retained in the report for failure analysis.
data ExampleResult = ExampleResult
  { -- | position in the dataset (0-based)
    index :: !Int,
    score :: !Score,
    failure :: !(Maybe FailureReason),
    latencyMs :: !Integer
  }
  deriving stock (Eq, Show)

-- | Summed token/cost usage across the run.
data UsageTotals = UsageTotals
  { totalInputTokens :: !Natural,
    totalOutputTokens :: !Natural,
    totalTokens :: !Natural,
    totalCostUsd :: !Rational
  }
  deriving stock (Eq, Show)

-- | The zero of 'UsageTotals'.
emptyUsageTotals :: UsageTotals
emptyUsageTotals = UsageTotals 0 0 0 0

instance Semigroup UsageTotals where
  a <> b =
    UsageTotals
      (totalInputTokens a + totalInputTokens b)
      (totalOutputTokens a + totalOutputTokens b)
      (totalTokens a + totalTokens b)
      (totalCostUsd a + totalCostUsd b)

instance Monoid UsageTotals where
  mempty = emptyUsageTotals

-- | Knobs for an evaluation run.
data EvalConfig = EvalConfig
  { -- | max examples evaluated at once (forced to @>= 1@ by 'evaluate')
    concurrency :: !Int,
    failurePolicy :: !FailurePolicy,
    -- | samples per example for multi-sample metrics (forced to @>= 1@)
    numSamples :: !Int
  }
  deriving stock (Eq, Show, Generic)

-- | The default: four-way concurrency, score failures @0@ and keep going, one
-- sample per example.
defaultEvalConfig :: EvalConfig
defaultEvalConfig =
  EvalConfig
    { concurrency = 4,
      failurePolicy = FailScore scoreZero,
      numSamples = 1
    }

-- | The aggregate result of an evaluation run.
data Report = Report
  { -- | mean of the per-example scores, in @[0, 1]@ (0 when there are no examples)
    aggregateScore :: !Double,
    -- | examples whose score is exactly @1.0@
    passCount :: !Int,
    -- | examples carrying a 'FailureReason'
    failCount :: !Int,
    total :: !Int,
    -- | per-example outcomes, retained in dataset order
    results :: ![ExampleResult],
    usage :: !UsageTotals,
    totalLatencyMs :: !Integer
  }
  deriving stock (Eq, Show)

-- | Build a report from per-example results and the run's usage totals.
-- 'aggregateScore' is the arithmetic mean of the per-example scores (0 if there
-- are no examples). 'passCount' counts perfect scores; 'failCount' counts
-- examples with a 'FailureReason'.
mkReport :: [ExampleResult] -> UsageTotals -> Report
mkReport rs u =
  Report
    { aggregateScore =
        if null rs
          then 0
          else sum (map (unScore . score) rs) / fromIntegral (length rs),
      passCount = length (filter ((== 1.0) . unScore . score) rs),
      failCount = length (filter (isJust . failure) rs),
      total = length rs,
      results = rs,
      usage = u,
      totalLatencyMs = sum (map latencyMs rs)
    }

-- | A deterministic, human-readable multi-line summary of a report. The format
-- is stable (fixed 4-decimal score and cost, examples in index order) so the CLI
-- and golden tests can rely on it. The exact shape, for a 3-example run with one
-- failure:
--
-- > score=0.6667  pass=2/3  fail=1
-- > tokens: in=120 out=45 total=165
-- > cost: $0.0023
-- > latency: 1234 ms
-- > failures:
-- >   [2] ProgramError: decode failed
--
-- When there are no failures the trailing @failures:@ block is omitted.
renderReportText :: Report -> Text
renderReportText r =
  T.intercalate "\n" (header ++ failureLines)
  where
    header =
      [ "score="
          <> fixed4 (aggregateScore r)
          <> "  pass="
          <> tshow (passCount r)
          <> "/"
          <> tshow (total r)
          <> "  fail="
          <> tshow (failCount r),
        "tokens: in="
          <> tshowNat (totalInputTokens (usage r))
          <> " out="
          <> tshowNat (totalOutputTokens (usage r))
          <> " total="
          <> tshowNat (totalTokens (usage r)),
        "cost: $" <> fixed4 (fromRational (totalCostUsd (usage r))),
        "latency: " <> tshow (totalLatencyMs r) <> " ms"
      ]
    failingResults = mapMaybe asFailure (results r)
    asFailure er = (\fr -> (index er, fr)) <$> failure er
    failureLines
      | null failingResults = []
      | otherwise = "failures:" : map renderFailure failingResults
    renderFailure (i, fr) = "  [" <> tshow i <> "] " <> renderReason fr

-- | Render a failure reason for the report.
renderReason :: FailureReason -> Text
renderReason = \case
  ProgramError t -> "ProgramError: " <> t
  MetricError t -> "MetricError: " <> t
  TimedOut -> "TimedOut"

-- | A 'Double' shown with exactly four decimal places.
fixed4 :: Double -> Text
fixed4 d = T.pack (showFFloat (Just 4) d "")

tshow :: (Show a) => a -> Text
tshow = T.pack . show

tshowNat :: Natural -> Text
tshowNat = T.pack . show
