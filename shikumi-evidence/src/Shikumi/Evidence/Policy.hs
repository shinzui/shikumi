-- | The declared metric policy that decides a comparison.
--
-- A __measure__ is one number per executed example with a stable id. The
-- built-in measures are produced for every executed example; custom measures come
-- from one caller-supplied pure function whose ids the policy lists (the function
-- itself is code, identified by the @program-template@ source revision). A
-- __metric__ is a declared aggregate of one measure, and a __constraint__ is a
-- hard bound on a metric, read in the metric's direction.
--
-- Promotion-gate measures are pure functions of the typed output and execution
-- evidence; a language-model judge cannot be a gate.
module Shikumi.Evidence.Policy
  ( MetricPolicy (..),
    MetricSpec (..),
    MetricAggregation (..),
    Constraint (..),
    Bound (..),
    Direction (..),
    MissingPolicy (..),
    PolicyError (..),
    builtInMeasures,
    validatePolicy,
    digestPolicy,
    decodePolicy,
    encodePolicy,
  )
where

import Data.Aeson (FromJSON (..), Options (..), ToJSON (..), Value (..), defaultOptions, genericParseJSON, genericToJSON, object, withObject, withText, (.:?), (.=))
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy qualified as BL
import Data.List (nub)
import Data.Maybe (catMaybes)
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Generics (Generic)
import Shikumi.Evidence.Digest
import Shikumi.Optimize.Report (Direction (..), MissingPolicy (..))

evidenceOptions :: Options
evidenceOptions = defaultOptions {omitNothingFields = True}

-- | How a metric aggregates its measure over the executed examples of one arm.
-- Only labeled examples execute, so "labeled" means every executed example and
-- "completed" means those that completed within their time limit.
data MetricAggregation
  = MeanOverLabeled
  | MeanOverCompleted
  | TotalOverLabeled
  | -- | the total over labeled examples divided by the number completed
    TotalPerCompleted
  | -- | the worst value, in the metric's direction, over completed examples
    WorstOverCompleted
  deriving stock (Eq, Show, Generic)

instance ToJSON MetricAggregation where
  toJSON =
    String . \case
      MeanOverLabeled -> "mean-over-labeled"
      MeanOverCompleted -> "mean-over-completed"
      TotalOverLabeled -> "total-over-labeled"
      TotalPerCompleted -> "total-per-completed"
      WorstOverCompleted -> "worst-over-completed"

instance FromJSON MetricAggregation where
  parseJSON = withText "MetricAggregation" $ \case
    "mean-over-labeled" -> pure MeanOverLabeled
    "mean-over-completed" -> pure MeanOverCompleted
    "total-over-labeled" -> pure TotalOverLabeled
    "total-per-completed" -> pure TotalPerCompleted
    "worst-over-completed" -> pure WorstOverCompleted
    other -> fail ("unknown aggregation: " <> T.unpack other)

-- | One declared metric.
data MetricSpec = MetricSpec
  { metricId :: !Text,
    measure :: !Text,
    unit :: !Text,
    direction :: !Direction,
    aggregation :: !MetricAggregation,
    -- | what to do when an executed example has no value for the measure
    missing :: !MissingPolicy
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | A bound on a metric, read in the metric's direction: for a minimized metric
-- the candidate must not exceed it, for a maximized one it must reach it.
data Bound
  = -- | an absolute limit
    AbsoluteLimit !Double
  | -- | a multiple of the baseline's value
    BaselineRatio !Double
  | -- | not worse than the baseline by more than this margin
    BaselineMargin !Double
  deriving stock (Eq, Show, Generic)

instance ToJSON Bound where
  toJSON = \case
    AbsoluteLimit x -> object ["absolute" .= x]
    BaselineRatio x -> object ["ratioToBaseline" .= x]
    BaselineMargin x -> object ["marginToBaseline" .= x]

instance FromJSON Bound where
  parseJSON = withObject "Bound" $ \o -> do
    a <- o .:? "absolute"
    r <- o .:? "ratioToBaseline"
    m <- o .:? "marginToBaseline"
    case (KM.size o, a, r, m) of
      (1, Just x, _, _) -> pure (AbsoluteLimit x)
      (1, _, Just x, _) -> pure (BaselineRatio x)
      (1, _, _, Just x) -> pure (BaselineMargin x)
      _ -> fail "a bound holds exactly one of absolute, ratioToBaseline or marginToBaseline"

-- | A hard bound on a declared metric.
data Constraint = Constraint
  { constraintId :: !Text,
    metric :: !Text,
    bound :: !Bound
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | The metric policy.
data MetricPolicy = MetricPolicy
  { policyId :: !Text,
    policyVersion :: !Text,
    metrics :: ![MetricSpec],
    primaryMetric :: !Text,
    constraints :: ![Constraint],
    -- | the ids of the caller's custom measures
    customMeasures :: ![Text],
    -- | the smallest primary improvement that counts, in the primary's direction
    minImprovement :: !Double,
    -- | a primary worse than the baseline by more than this is a regression
    regressionMargin :: !Double,
    minLabeledSamples :: !Int,
    -- | the largest acceptable share of holdout examples without a label
    maxMissingRate :: !Double,
    -- | applied to an example's summed recorded latency, never the wall clock
    exampleTimeoutMs :: !(Maybe Int),
    maxComparisonOperations :: !Int
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON MetricPolicy where toJSON = genericToJSON evidenceOptions

instance FromJSON MetricPolicy where parseJSON = genericParseJSON evidenceOptions

-- | The measures produced for every executed example.
builtInMeasures :: [Text]
builtInMeasures = ["quality", "completed", "timed_out", "cost_usd", "latency_ms", "operations", "tokens"]

-- | Problems with a policy.
data PolicyError
  = MalformedPolicy !Text
  | EmptyPolicyField !Text
  | DuplicateMetric !Text
  | DuplicateConstraint !Text
  | DuplicateCustomMeasure !Text
  | UndeclaredPrimaryMetric !Text
  | UndeclaredConstraintMetric !Text !Text
  | UnknownMeasure !Text !Text
  | CustomMeasureCollision !Text
  | NonFiniteThreshold !Text
  | InvalidThreshold !Text
  deriving stock (Eq, Show)

-- | Validate a policy, returning every problem found.
validatePolicy :: MetricPolicy -> Either [PolicyError] ()
validatePolicy p = if null problems then Right () else Left problems
  where
    metricIds = map (.metricId) p.metrics
    constraintIds = map (.constraintId) p.constraints
    dupes xs = nub [x | x <- xs, length (filter (== x) xs) > 1]
    known = builtInMeasures ++ p.customMeasures
    numbers =
      [("minImprovement", p.minImprovement), ("regressionMargin", p.regressionMargin), ("maxMissingRate", p.maxMissingRate)]
        ++ [(c.constraintId, boundValue c.bound) | c <- p.constraints]
        ++ catMaybes [case m.missing of Substitute v -> Just (m.metricId, v); Required -> Nothing | m <- p.metrics]
    problems =
      [EmptyPolicyField "policyId" | T.null p.policyId]
        ++ [EmptyPolicyField "policyVersion" | T.null p.policyVersion]
        ++ [EmptyPolicyField "metricId" | any T.null metricIds]
        ++ [EmptyPolicyField "constraintId" | any T.null constraintIds]
        ++ map DuplicateMetric (dupes metricIds)
        ++ map DuplicateConstraint (dupes constraintIds)
        ++ map DuplicateCustomMeasure (dupes p.customMeasures)
        ++ [CustomMeasureCollision m | m <- p.customMeasures, m `elem` builtInMeasures]
        ++ [UndeclaredPrimaryMetric p.primaryMetric | p.primaryMetric `notElem` metricIds]
        ++ [UndeclaredConstraintMetric c.constraintId c.metric | c <- p.constraints, c.metric `notElem` metricIds]
        ++ [UnknownMeasure m.metricId m.measure | m <- p.metrics, m.measure `notElem` known]
        ++ [NonFiniteThreshold name | (name, v) <- numbers, not (finite v)]
        ++ [InvalidThreshold "maxMissingRate must lie in [0, 1]" | finite p.maxMissingRate, p.maxMissingRate < 0 || p.maxMissingRate > 1]
        ++ [InvalidThreshold "regressionMargin must be nonnegative" | p.regressionMargin < 0]
        ++ [InvalidThreshold "minLabeledSamples must be nonnegative" | p.minLabeledSamples < 0]
        ++ [InvalidThreshold "maxComparisonOperations must be nonnegative" | p.maxComparisonOperations < 0]
        ++ [InvalidThreshold "exampleTimeoutMs must be positive" | Just t <- [p.exampleTimeoutMs], t <= 0]
    boundValue = \case
      AbsoluteLimit x -> x
      BaselineRatio x -> x
      BaselineMargin x -> x

-- | A policy's digest: the digest of its JSON.
digestPolicy :: MetricPolicy -> Digest
digestPolicy = digestValue . toJSON

-- | Decode a policy: exact round trip and validation.
decodePolicy :: BL.ByteString -> Either [PolicyError] MetricPolicy
decodePolicy bytes = do
  (_, p) <- either (Left . (: []) . MalformedPolicy) Right (decodeEnvelope False bytes)
  p <$ validatePolicy p

-- | A policy file: canonical JSON and a newline.
encodePolicy :: MetricPolicy -> BL.ByteString
encodePolicy = encodeEnvelope
