-- | The comparison report and the pure decision that concludes it.
--
-- 'conclude' is total and ordered. It returns 'Invalid' when the inputs failed
-- validation, the candidate's structure differs, or the holdout is contaminated,
-- below the dataset's declared minimum or unlabeled. A candidate whose compiled
-- state equals the baseline's is then 'Inconclusive' without a comparison. Next
-- it returns 'Invalid' when the exposure limit is exhausted without an override,
-- the two arms observed different routes, the comparison did not finish, or a
-- required metric has no value. Otherwise it returns 'Regressed' when any
-- constraint is violated or the primary metric is worse than the baseline by more
-- than the regression margin; otherwise 'Inconclusive' when there are too few
-- labeled samples, too many missing labels, or too small an improvement; and only
-- otherwise 'Improved'. No failing case can reach 'Improved'.
--
-- A report's per-example rows hold only an example id, an outcome class and
-- numbers. They never contain inputs, outputs or critique text, so a report
-- cannot carry holdout content back to a proposer.
module Shikumi.Evidence.Report
  ( -- * Conclusions
    Conclusion (..),
    Reason (..),
    ComparisonFacts (..),
    conclude,

    -- * Measurements
    RowOutcome (..),
    ExampleRow (..),
    MetricValue (..),
    aggregateMetric,
    armMetrics,
    ConstraintResult (..),
    Verdict (..),
    evaluateConstraints,
    PrimaryComparison (..),
    comparePrimary,

    -- * The report envelope
    ComparisonReport (..),
    ArmResult (..),
    ReportBindings (..),
    EvaluatorDescriptor (..),
    ExposureRecord (..),
    reportKind,
    digestEvaluator,
    sealReport,
    decodeReport,
    validateReport,

    -- * Binding verification
    BindingError (..),
    verifyReportBinding,
  )
where

import Data.Aeson (FromJSON (..), Options (..), ToJSON (..), Value (..), defaultOptions, genericParseJSON, genericToJSON, withText)
import Data.ByteString.Lazy qualified as BL
import Data.List (sort)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (isNothing)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime)
import GHC.Generics (Generic)
import Numeric (showFFloat)
import Shikumi.Evidence.Artifact qualified as A
import Shikumi.Evidence.Dataset qualified as D
import Shikumi.Evidence.Digest
import Shikumi.Evidence.Exposure (ExposureOverride)
import Shikumi.Evidence.Policy
import Shikumi.Evidence.Recording (RouteCount)
import Shikumi.Evidence.Source (SourceRef)

evidenceOptions :: Options
evidenceOptions = defaultOptions {omitNothingFields = True}

-- ---------------------------------------------------------------------------
-- Conclusions
-- ---------------------------------------------------------------------------

-- | The four conclusions.
data Conclusion = Improved | Regressed | Inconclusive | Invalid
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | A machine-readable reason: a stable code and a human-readable detail.
data Reason = Reason
  { code :: !Text,
    detail :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | Everything the decision needs. Metric maps hold each declared metric's
-- aggregate, or 'Nothing' when it has no value.
data ComparisonFacts = ComparisonFacts
  { -- | dataset, artifact, policy and source problems found before any call
    inputProblems :: ![Reason],
    structureMatches :: !Bool,
    holdoutContaminated :: !Bool,
    holdoutSize :: !Int,
    holdoutMinimum :: !Int,
    -- | labeled holdout examples, each executed once per arm
    labeledSamples :: !Int,
    -- | holdout examples without a label
    missingLabels :: !Int,
    exposureLimitReached :: !Bool,
    candidateIdentical :: !Bool,
    routesMatch :: !Bool,
    comparisonFinished :: !Bool,
    baselineMetrics :: !(Map Text (Maybe Double)),
    candidateMetrics :: !(Map Text (Maybe Double))
  }
  deriving stock (Eq, Show)

-- | Decide a comparison. See the module header for the order.
conclude :: MetricPolicy -> ComparisonFacts -> (Conclusion, [Reason])
conclude p f
  | not (null structural) = (Invalid, structural)
  | f.candidateIdentical = (Inconclusive, [Reason "candidate-identical" "the candidate's compiled state equals the baseline's; no comparison was run"])
  | not (null operational) = (Invalid, operational)
  | not (null regressions) = (Regressed, regressions)
  | not (null weak) = (Inconclusive, weak)
  | otherwise = (Improved, [Reason "improved" ("primary metric " <> p.primaryMetric <> " improved by " <> maybe "?" fmt primary.improvement)])
  where
    structural =
      f.inputProblems
        ++ [Reason "structure-mismatch" "the candidate's structure differs from the baseline template" | not f.structureMatches]
        ++ [Reason "holdout-contaminated" "the protected holdout shares a group or input with another split" | f.holdoutContaminated]
        ++ [ Reason "holdout-too-small" (tshow f.holdoutSize <> " holdout examples, dataset requires " <> tshow f.holdoutMinimum)
           | f.holdoutSize < f.holdoutMinimum
           ]
        ++ [Reason "holdout-unlabeled" "the protected holdout has no labeled example" | f.labeledSamples <= 0]
    operational =
      [Reason "exposure-exhausted" "the holdout's exposure limit is exhausted and no override was given" | f.exposureLimitReached]
        ++ [Reason "routes-differ" "the baseline and candidate arms observed different routes" | not f.routesMatch]
        ++ [Reason "comparison-incomplete" "the comparison did not finish within its operation limit" | not f.comparisonFinished]
        ++ [ Reason "metric-missing" ("metric " <> m <> " has no value for the " <> arm)
           | f.routesMatch && f.comparisonFinished && not f.exposureLimitReached,
             m <- requiredMetrics,
             (arm, values) <- [("baseline", f.baselineMetrics), ("candidate", f.candidateMetrics)],
             isNothing (Map.findWithDefault Nothing m values)
           ]
    requiredMetrics =
      sort . nubOrd $
        p.primaryMetric
          : map (.metric) p.constraints
          ++ [m.metricId | m <- p.metrics, m.missing == Required]
    results = evaluateConstraints p f.baselineMetrics f.candidateMetrics
    primary = comparePrimary p f.baselineMetrics f.candidateMetrics
    regressions =
      [Reason "constraint-violated" (c.constraintId <> ": " <> describe c) | c <- results, c.verdict == Violated]
        ++ [ Reason "primary-regressed" ("primary metric " <> p.primaryMetric <> " changed by " <> fmt d <> ", beyond the regression margin " <> fmt p.regressionMargin)
           | Just d <- [primary.improvement],
             d < negate p.regressionMargin
           ]
    missingRate = if f.holdoutSize <= 0 then 0 else fromIntegral f.missingLabels / fromIntegral f.holdoutSize :: Double
    weak =
      [ Reason "insufficient-labels" (tshow f.labeledSamples <> " labeled samples, policy requires " <> tshow p.minLabeledSamples)
      | f.labeledSamples < p.minLabeledSamples
      ]
        ++ [Reason "missing-rate-exceeded" ("missing-label rate " <> fmt missingRate <> " exceeds " <> fmt p.maxMissingRate) | missingRate > p.maxMissingRate]
        ++ [ Reason "improvement-below-threshold" ("primary improvement " <> fmt d <> " is below " <> fmt p.minImprovement)
           | Just d <- [primary.improvement],
             d < p.minImprovement
           ]

nubOrd :: (Ord a) => [a] -> [a]
nubOrd = Map.keys . Map.fromList . map (,())

describe :: ConstraintResult -> Text
describe c = case (c.bound, c.baselineValue, c.candidateValue) of
  (BaselineRatio r, Just b, Just v) -> "ratio " <> (if b == 0 then "undefined" else fmt (v / b)) <> " beyond " <> fmt r
  (BaselineMargin m, Just b, Just v) -> "change " <> fmt (v - b) <> " beyond margin " <> fmt m
  (AbsoluteLimit l, _, Just v) -> "value " <> fmt v <> " beyond limit " <> fmt l
  _ -> "no value"

fmt :: Double -> Text
fmt x = T.pack (showFFloat (Just 4) x "")

tshow :: (Show a) => a -> Text
tshow = T.pack . show

-- ---------------------------------------------------------------------------
-- Measurements
-- ---------------------------------------------------------------------------

-- | How one executed example ended.
data RowOutcome = RowCompleted | RowFailed | RowTimedOut
  deriving stock (Eq, Show, Generic)

instance ToJSON RowOutcome where
  toJSON = String . \case RowCompleted -> "completed"; RowFailed -> "failed"; RowTimedOut -> "timed-out"

instance FromJSON RowOutcome where
  parseJSON = withText "RowOutcome" $ \case
    "completed" -> pure RowCompleted
    "failed" -> pure RowFailed
    "timed-out" -> pure RowTimedOut
    other -> fail ("unknown outcome: " <> T.unpack other)

-- | One executed holdout example: its id, outcome class and measures. Nothing
-- else, by design.
data ExampleRow = ExampleRow
  { exampleId :: !Text,
    outcome :: !RowOutcome,
    measures :: !(Map Text Double)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | A metric's aggregate for one arm, absent when it has no value.
data MetricValue = MetricValue
  { metricId :: !Text,
    value :: !(Maybe Double)
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON MetricValue where toJSON = genericToJSON evidenceOptions

instance FromJSON MetricValue where parseJSON = genericParseJSON evidenceOptions

-- | Aggregate one metric over an arm's rows. A required measure missing from any
-- row in scope, an empty scope for a mean or worst value, no completed example
-- for a per-completed total, and a non-finite result all yield 'Nothing'.
aggregateMetric :: MetricSpec -> [ExampleRow] -> Maybe Double
aggregateMetric spec rows = do
  let completedRows = [r | r <- rows, r.outcome == RowCompleted]
      valuesOf rs = mapM valueOf rs
      valueOf r = case Map.lookup spec.measure r.measures of
        Just v | finite v -> Just v
        _ -> case spec.missing of
          Substitute v -> Just v
          Required -> Nothing
      nonEmpty xs = if null xs then Nothing else Just xs
  v <- case spec.aggregation of
    MeanOverLabeled -> mean <$> (nonEmpty =<< valuesOf rows)
    MeanOverCompleted -> mean <$> (nonEmpty =<< valuesOf completedRows)
    TotalOverLabeled -> sum <$> valuesOf rows
    TotalPerCompleted -> do
      total <- sum <$> valuesOf rows
      if null completedRows then Nothing else Just (total / fromIntegral (length completedRows))
    WorstOverCompleted -> do
      xs <- nonEmpty =<< valuesOf completedRows
      Just (if spec.direction == Maximize then minimum xs else maximum xs)
  if finite v then Just v else Nothing
  where
    mean xs = sum xs / fromIntegral (length xs)

-- | Every declared metric's aggregate over an arm's rows.
armMetrics :: MetricPolicy -> [ExampleRow] -> Map Text (Maybe Double)
armMetrics p rows = Map.fromList [(m.metricId, aggregateMetric m rows) | m <- p.metrics]

-- | A constraint's verdict.
data Verdict = Satisfied | Violated | Unknown
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | A constraint with the values it was judged on.
data ConstraintResult = ConstraintResult
  { constraintId :: !Text,
    metric :: !Text,
    bound :: !Bound,
    baselineValue :: !(Maybe Double),
    candidateValue :: !(Maybe Double),
    verdict :: !Verdict
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON ConstraintResult where toJSON = genericToJSON evidenceOptions

instance FromJSON ConstraintResult where parseJSON = genericParseJSON evidenceOptions

-- | Judge every constraint, reading each bound in its metric's direction.
evaluateConstraints :: MetricPolicy -> Map Text (Maybe Double) -> Map Text (Maybe Double) -> [ConstraintResult]
evaluateConstraints p base cand = map judge p.constraints
  where
    judge c =
      let b = Map.findWithDefault Nothing c.metric base
          v = Map.findWithDefault Nothing c.metric cand
          dir = maybe Maximize (.direction) (lookupMetric p c.metric)
          ok = case (c.bound, b, v) of
            (AbsoluteLimit l, _, Just x) -> Just (within dir x l)
            (BaselineRatio r, Just y, Just x) -> Just (within dir x (r * y))
            (BaselineMargin m, Just y, Just x) -> Just (within dir x (if dir == Minimize then y + m else y - m))
            _ -> Nothing
       in ConstraintResult c.constraintId c.metric c.bound b v (maybe Unknown (\s -> if s then Satisfied else Violated) ok)
    within Minimize x limit = x <= limit
    within Maximize x limit = x >= limit

lookupMetric :: MetricPolicy -> Text -> Maybe MetricSpec
lookupMetric p ident = case [m | m <- p.metrics, m.metricId == ident] of
  (m : _) -> Just m
  [] -> Nothing

-- | The primary metric's comparison with its thresholds. The improvement is
-- oriented so that positive is better.
data PrimaryComparison = PrimaryComparison
  { metric :: !Text,
    baselineValue :: !(Maybe Double),
    candidateValue :: !(Maybe Double),
    improvement :: !(Maybe Double),
    requiredImprovement :: !Double,
    allowedRegression :: !Double
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON PrimaryComparison where toJSON = genericToJSON evidenceOptions

instance FromJSON PrimaryComparison where parseJSON = genericParseJSON evidenceOptions

-- | Compare the primary metric of two arms.
comparePrimary :: MetricPolicy -> Map Text (Maybe Double) -> Map Text (Maybe Double) -> PrimaryComparison
comparePrimary p base cand = PrimaryComparison p.primaryMetric b v d p.minImprovement p.regressionMargin
  where
    b = Map.findWithDefault Nothing p.primaryMetric base
    v = Map.findWithDefault Nothing p.primaryMetric cand
    dir = maybe Maximize (.direction) (lookupMetric p p.primaryMetric)
    d = (\x y -> if dir == Maximize then x - y else y - x) <$> v <*> b

-- ---------------------------------------------------------------------------
-- The report envelope
-- ---------------------------------------------------------------------------

-- | The digests a report is about.
data ReportBindings = ReportBindings
  { baselineDigest :: !Digest,
    candidateDigest :: !(Maybe Digest),
    datasetDigest :: !Digest,
    policyDigest :: !Digest,
    evaluatorDigest :: !Digest,
    sources :: ![SourceRef]
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON ReportBindings where toJSON = genericToJSON evidenceOptions

instance FromJSON ReportBindings where parseJSON = genericParseJSON evidenceOptions

-- | What evaluated the comparison.
data EvaluatorDescriptor = EvaluatorDescriptor
  { evaluatorId :: !Text,
    evaluatorVersion :: !Text,
    cacheKeyVersion :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | The digest of an evaluator descriptor.
digestEvaluator :: EvaluatorDescriptor -> Digest
digestEvaluator = digestValue . toJSON

-- | The holdout exposure this report consumed, if any.
data ExposureRecord = ExposureRecord
  { limit :: !Int,
    prior :: !Int,
    -- | this report's exposure number, absent when no exposure was consumed
    ordinal :: !(Maybe Int),
    override :: !(Maybe ExposureOverride)
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON ExposureRecord where toJSON = genericToJSON evidenceOptions

instance FromJSON ExposureRecord where parseJSON = genericParseJSON evidenceOptions

-- | One arm's measured result on the holdout.
data ArmResult = ArmResult
  { status :: !Text,
    sampleCount :: !Int,
    completed :: !Int,
    failures :: !Int,
    timeouts :: !Int,
    missingLabels :: !Int,
    metrics :: ![MetricValue],
    rows :: ![ExampleRow],
    routes :: ![RouteCount],
    usage :: !A.UsageSummary,
    admittedOperations :: !Int
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | The comparison report envelope.
data ComparisonReport = ComparisonReport
  { artifactKind :: !Text,
    schemaVersion :: !Int,
    reportId :: !Text,
    bindings :: !ReportBindings,
    policy :: !MetricPolicy,
    evaluator :: !EvaluatorDescriptor,
    baselineResult :: !(Maybe ArmResult),
    candidateResult :: !(Maybe ArmResult),
    constraintResults :: ![ConstraintResult],
    primaryComparison :: !(Maybe PrimaryComparison),
    exposure :: !ExposureRecord,
    predictedOperations :: !Int,
    admittedOperations :: !Int,
    recordingDigest :: !(Maybe Digest),
    traceRef :: !(Maybe Text),
    conclusion :: !Conclusion,
    reasons :: ![Reason],
    createdAt :: !UTCTime,
    createdBy :: !Text,
    contentDigest :: !Digest
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON ComparisonReport where toJSON = genericToJSON evidenceOptions

instance FromJSON ComparisonReport where parseJSON = genericParseJSON evidenceOptions

-- | The @artifactKind@ of a report.
reportKind :: Text
reportKind = "shikumi.evidence.report"

-- | Compute and store a report's digest.
sealReport :: ComparisonReport -> ComparisonReport
sealReport = sealEnvelope (\d r -> r {contentDigest = d})

-- | Decode a report: digest on the raw value, exact round trip, validation.
decodeReport :: BL.ByteString -> Either [BindingError] ComparisonReport
decodeReport bytes = do
  (_, r) <- either (Left . (: []) . MalformedReport) Right (decodeEnvelope True bytes)
  r <$ validateReport r

-- | Check a report's kind, version, digest and internal consistency.
validateReport :: ComparisonReport -> Either [BindingError] ()
validateReport r = if null problems then Right () else Left problems
  where
    computed = envelopeDigest (toJSON r)
    problems =
      [MalformedReport ("unexpected artifactKind " <> r.artifactKind) | r.artifactKind /= reportKind]
        ++ [MalformedReport ("unsupported schemaVersion " <> tshow r.schemaVersion) | r.schemaVersion /= 1]
        ++ [ReportDigestMismatch r.contentDigest computed | r.contentDigest /= computed]
        ++ [EmbeddedPolicyMismatch | digestPolicy r.policy /= r.bindings.policyDigest]
        ++ [EvaluatorMismatch | digestEvaluator r.evaluator /= r.bindings.evaluatorDigest]

-- ---------------------------------------------------------------------------
-- Binding verification
-- ---------------------------------------------------------------------------

-- | Why a report does not bind what a verifier holds.
data BindingError
  = MalformedReport !Text
  | ReportDigestMismatch !Digest !Digest
  | HeldArtifactDigestInvalid !Text
  | BaselineMismatch !Digest !Digest
  | CandidateMismatch !(Maybe Digest) !Digest
  | DatasetMismatch !Digest !Digest
  | PolicyMismatch !Digest !Digest
  | EmbeddedPolicyMismatch
  | EvaluatorMismatch
  | SourcesMismatch
  | ParentMismatch !(Maybe Digest) !Digest
  | OptimizationDatasetMismatch !(Maybe Digest) !Digest
  deriving stock (Eq, Show)

-- | Verify that a report is about precisely the baseline, candidate, dataset,
-- policy and source revisions a verifier holds. Returns every mismatch found.
verifyReportBinding ::
  ComparisonReport -> A.ProgramArtifact -> A.ProgramArtifact -> D.EvidenceDataset -> MetricPolicy -> [SourceRef] -> Either [BindingError] ()
verifyReportBinding r base cand ds pol refs = if null problems then Right () else Left problems
  where
    b = r.bindings
    ownDigest :: (ToJSON a) => Text -> Digest -> a -> [BindingError]
    ownDigest name stored value = [HeldArtifactDigestInvalid name | stored /= envelopeDigest (toJSON value)]
    optimizationDataset = fmap (.datasetDigest) cand.optimization
    problems =
      either id (const []) (validateReport r)
        ++ ownDigest "baseline" base.contentDigest base
        ++ ownDigest "candidate" cand.contentDigest cand
        ++ ownDigest "dataset" ds.contentDigest ds
        ++ [BaselineMismatch b.baselineDigest base.contentDigest | b.baselineDigest /= base.contentDigest]
        ++ [CandidateMismatch b.candidateDigest cand.contentDigest | b.candidateDigest /= Just cand.contentDigest]
        ++ [DatasetMismatch b.datasetDigest ds.contentDigest | b.datasetDigest /= ds.contentDigest]
        ++ [PolicyMismatch b.policyDigest (digestPolicy pol) | b.policyDigest /= digestPolicy pol]
        ++ [SourcesMismatch | sort b.sources /= sort refs]
        ++ [ParentMismatch cand.parentDigest base.contentDigest | cand.parentDigest /= Just base.contentDigest]
        ++ [OptimizationDatasetMismatch optimizationDataset ds.contentDigest | optimizationDataset /= Just ds.contentDigest]
