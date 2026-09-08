-- | The core deliverable: @evaluate@ runs a 'Program' over a typed 'Dataset',
-- scores each example with a metric, and returns a 'Report' summarising the
-- aggregate score, the per-example breakdown, token usage, cost, and latency.
--
-- Examples run with __bounded__ concurrency ('pooledForConcurrentlyN', worker
-- count from 'concurrency'), which preserves dataset order in the result. Each
-- example sits inside a per-example error boundary: a 'ShikumiError' from
-- 'runProgram' becomes a 'ProgramError', one from an effectful metric becomes a
-- 'MetricError', and the 'FailurePolicy' decides whether that example is scored
-- and the run continues ('FailScore') or the whole run aborts ('FailAbort').
-- Usage/cost is accumulated by wrapping the pooled run in
-- 'Shikumi.Eval.Usage.withUsageTotals'; per-example latency is measured with a
-- monotonic clock around each example.
module Shikumi.Eval.Evaluate
  ( evaluate,
    evaluatePure,
    evaluateWith,
    scoreExecution,
    tryShikumi,
  )
where

import Control.Monad (replicateM)
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.Text qualified as T
import Effectful (Eff, (:>))
import Effectful.Concurrent (Concurrent, threadDelay)
import Effectful.Concurrent.Async (pooledForConcurrentlyN, race)
import Effectful.Error.Static (Error, catchError, throwError)
import Effectful.Prim (Prim)
import Shikumi.Effect.Time (Time, getMonotonicTimeNSec)
import Shikumi.Error (ShikumiError (..), renderShikumiError)
import Shikumi.Eval.Metric (Metric, MetricM, liftMetric)
import Shikumi.Eval.Report
  ( EvalConfig (..),
    ExampleResult (..),
    FailurePolicy (..),
    FailureReason (..),
    Report,
    defaultEvalConfig,
    mkReport,
  )
import Shikumi.Eval.Types
  ( Dataset,
    Example (..),
    Prediction (..),
    Score,
    datasetExamples,
    prediction,
  )
import Shikumi.Eval.Usage (withUsageTotals)
import Shikumi.LLM (LLM)
import Shikumi.Program (Program, runProgram)

-- | Evaluate a program over a dataset with an effectful metric, using the
-- default configuration.
evaluate ::
  (LLM :> es, Concurrent :> es, Error ShikumiError :> es, Time :> es, Prim :> es) =>
  Dataset i o ->
  MetricM es o ->
  Program i o ->
  Eff es Report
evaluate = evaluateWith defaultEvalConfig

-- | Convenience for a pure metric.
evaluatePure ::
  (LLM :> es, Concurrent :> es, Error ShikumiError :> es, Time :> es, Prim :> es) =>
  Dataset i o ->
  Metric o ->
  Program i o ->
  Eff es Report
evaluatePure ds m = evaluate ds (liftMetric m)

-- | Evaluate with an explicit configuration.
evaluateWith ::
  (LLM :> es, Concurrent :> es, Error ShikumiError :> es, Time :> es, Prim :> es) =>
  EvalConfig ->
  Dataset i o ->
  MetricM es o ->
  Program i o ->
  Eff es Report
evaluateWith cfg ds metric prog = do
  let indexed = zip [0 ..] (datasetExamples ds)
  (rs, totals) <-
    withUsageTotals $
      pooledForConcurrentlyN (max 1 (concurrency cfg)) indexed (evalOne cfg metric prog)
  pure (mkReport rs totals)

-- | Evaluate a single indexed example inside its error boundary, timing it with a
-- monotonic clock.
evalOne ::
  (LLM :> es, Concurrent :> es, Error ShikumiError :> es, Time :> es) =>
  EvalConfig ->
  MetricM es o ->
  Program i o ->
  (Int, Example i o) ->
  Eff es ExampleResult
evalOne cfg metric prog (ix, Example inp expd) = do
  start <- getMonotonicTimeNSec
  outcome <- case exampleTimeoutMs cfg of
    Nothing -> Right <$> scoreExample cfg metric prog inp expd
    Just ms -> race (threadDelay (max 0 ms * 1000)) (scoreExample cfg metric prog inp expd)
  (s, mFail) <- case outcome of
    Right r -> pure r
    Left () -> case failurePolicy cfg of
      FailAbort -> throwError (Timeout "evaluate: example timed out")
      FailScore sc -> pure (sc, Just TimedOut)
  end <- getMonotonicTimeNSec
  let ms = fromIntegral ((end - start) `div` 1_000_000)
  pure ExampleResult {index = ix, score = s, failure = mFail, latencyMs = ms}

-- | Run the program, apply the metric, and resolve any failure through the
-- configured 'FailurePolicy'. Returns the score and an optional failure reason
-- (or re-throws under 'FailAbort').
scoreExample ::
  (LLM :> es, Error ShikumiError :> es) =>
  EvalConfig ->
  MetricM es o ->
  Program i o ->
  i ->
  o ->
  Eff es (Score, Maybe FailureReason)
scoreExample cfg metric prog inp expd = do
  (_, result) <-
    scoreExecution
      (const (failurePolicy cfg))
      id
      (tryShikumi (buildPrediction cfg prog inp))
      (metric expd)
  pure result

-- | Shared typed execution boundary. The runner retains arbitrary evidence even
-- on failure; the projection identifies its root result. Only checked errors are
-- caught. Callers choose their error classification without losing evidence.
scoreExecution ::
  (Error ShikumiError :> es) =>
  (ShikumiError -> FailurePolicy) ->
  (a -> Either ShikumiError b) ->
  Eff es a ->
  (b -> Eff es Score) ->
  Eff es (a, (Score, Maybe FailureReason))
scoreExecution policy project runner metric = do
  evidence <- runner
  result <- case project evidence of
    Left e -> boundary (ProgramError (renderErr e)) e
    Right value -> do
      scored <- tryShikumi (metric value)
      case scored of
        Left e -> boundary (MetricError (renderErr e)) e
        Right s -> pure (s, Nothing)
  pure (evidence, result)
  where
    boundary reason e = case policy e of
      FailAbort -> throwError e
      FailScore s -> pure (s, Just reason)

-- | Build a 'Prediction' by running the program @numSamples@ times (at least
-- once); a single sample yields a one-element prediction.
buildPrediction ::
  (LLM :> es, Error ShikumiError :> es) =>
  EvalConfig ->
  Program i o ->
  i ->
  Eff es (Prediction o)
buildPrediction cfg prog inp =
  if n <= 1
    then prediction <$> runProgram prog inp
    else do
      outs <- replicateM n (runProgram prog inp)
      case outs of
        (x : xs) -> pure (Prediction x (x :| xs) Nothing)
        [] -> prediction <$> runProgram prog inp -- unreachable: n >= 1
  where
    n = max 1 (numSamples cfg)

-- | Run an action, catching a 'ShikumiError' into a 'Left'.
tryShikumi :: (Error ShikumiError :> es) => Eff es a -> Eff es (Either ShikumiError a)
tryShikumi act = (Right <$> act) `catchError` \_ e -> pure (Left e)

-- | Render a shikumi error for a 'FailureReason'.
renderErr :: ShikumiError -> T.Text
renderErr e@ProviderError {} = renderShikumiError e
renderErr e = T.pack (show e)
