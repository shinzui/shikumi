{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | The evidence job driver: optimize on the training and validation splits,
-- then compare baseline and candidate once on the protected holdout, under
-- recorded or replayed provider responses.
--
-- 'runEvidenceJob' has no @IOE@ in its effect row, so it cannot read credentials,
-- touch a deployment or access files. It validates every input before any model
-- call, and any validation failure yields a sealed 'Invalid' report. Each phase
-- is composed as the phase's record or replay boundary applied to the caller's
-- request pipeline applied to the phase's action, the order ADR-12 prescribes: a
-- call passes the search session's admission, then routing, then defaults, and
-- reaches the recording boundary last, carrying its real route and effective
-- options.
--
-- Evidence jobs execute sequentially: 'evaluationConcurrency' must be one, and
-- the comparison runs the baseline and then the candidate over the holdout
-- examples in order. An optimizer specification that issues identical requests
-- from concurrent threads is outside the reproducibility guarantee.
module Shikumi.Evidence.Driver
  ( -- * Jobs
    EvidenceJob (..),
    ExecutionContext (..),
    ExecutionMode (..),
    JobRecordings (..),
    EvidenceJobResult (..),
    JobSummary (..),
    runEvidenceJob,

    -- * Optimizers
    OptimizerSpec (..),
    OptimizerInputs (..),
    GepaEvidenceConfig (..),
    defaultGepaEvidenceConfig,
    gepaEvidenceOptimizer,
    evidenceFailurePolicy,

    -- * Identity
    evidencePackageVersion,
    evidenceEvaluator,
  )
where

import Control.Lens ((^.))
import Data.Aeson (Value, object, (.=))
import Data.Either (isRight)
import Data.Generics.Labels ()
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust, isNothing)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime)
import Effectful (Eff, (:>))
import Effectful.Concurrent (Concurrent)
import Effectful.Dispatch.Dynamic (interpose)
import Effectful.Error.Static (Error, throwError)
import Effectful.Prim.IORef (Prim, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Shikumi.Cache.Key (currentKeyVersion)
import Shikumi.Compile.Serialize (decodeCompiledOnto, encodeCompiled)
import Shikumi.Compile.Types (CompiledProgram (..))
import Shikumi.Effect.Time (Time)
import Shikumi.Error (ShikumiError (..))
import Shikumi.Eval (Dataset (..), Example (..), Metric, datasetExamples, prediction, scoreZero, unScore)
import Shikumi.Eval.Report (FailurePolicy (..), UsageTotals (..))
import Shikumi.Eval.Usage (withUsageTotals)
import Shikumi.Evidence.Artifact
import Shikumi.Evidence.Dataset
import Shikumi.Evidence.Dataset.Internal (HoldoutExample (..), sealedHoldout)
import Shikumi.Evidence.Digest
import Shikumi.Evidence.Exposure
import Shikumi.Evidence.Policy
import Shikumi.Evidence.Recording
import Shikumi.Evidence.Report
import Shikumi.Evidence.Source
import Shikumi.LLM (LLM (..), complete, stream)
import Shikumi.Optimize (ConfiguredOptimizer, optimizeWith)
import Shikumi.Optimize.Execution
  ( ExampleMeasurement (..),
    RunConfig (..),
    RunLimits (..),
    addPredictedWork,
    evaluateCandidate,
    reserveCandidate,
    runSearchSession,
  )
import Shikumi.Optimize.Feedback (EvaluationEvidence (..), FeedbackConfig (..), StoredCritique (..), defaultFeedbackConfig, storedCritiqueFeedback)
import Shikumi.Optimize.GEPA (FeedbackCallback (..), GEPAConfig (..), ReflectIn, ReflectOut, defaultGEPAConfig, gepaWith)
import Shikumi.Optimize.Report (CandidateReport (..), CandidateStatus (..), OptimizationReport (..), qualityPolicy)
import Shikumi.Optimize.Search (scoringCost)
import Shikumi.Program (Program, programShape)
import Shikumi.Trace.Node (programNodePaths)
import Shikumi.Trace.Observation (runProgramObserved)

-- ---------------------------------------------------------------------------
-- Identity
-- ---------------------------------------------------------------------------

-- | This package's version, named in every report's evaluator descriptor.
evidencePackageVersion :: Text
evidencePackageVersion = "0.1.0.0"

-- | The evaluator that runs every comparison.
evidenceEvaluator :: EvaluatorDescriptor
evidenceEvaluator = EvaluatorDescriptor "shikumi.evidence.evaluate-candidate" evidencePackageVersion currentKeyVersion

-- ---------------------------------------------------------------------------
-- Optimizers
-- ---------------------------------------------------------------------------

-- | What an optimizer specification receives besides the training split and the
-- baseline: the validation split, which may only rank candidates, the training
-- example ids aligned with the training dataset, the critiques stored with
-- training examples, and the search metric. It never receives the holdout.
data OptimizerInputs i o = OptimizerInputs
  { validation :: Dataset i o,
    trainingExampleIds :: [Text],
    trainingCritiques :: [StoredCritique],
    -- | the job's search metric
    metric :: Metric o
  }

-- | An optimizer with the identity and declared configuration copied into the
-- candidate.
data OptimizerSpec i o = OptimizerSpec
  { optimizerId :: Text,
    optimizerVersion :: Text,
    optimizerConfig :: Value,
    buildOptimizer :: OptimizerInputs i o -> ConfiguredOptimizer i o
  }

-- | The declared configuration of the GEPA evidence optimizer. The feedback
-- configuration's redaction and failure classification are code and are not
-- part of the declared configuration.
data GepaEvidenceConfig = GepaEvidenceConfig
  { feedback :: FeedbackConfig,
    minibatch :: Int,
    generationSize :: Int
  }

-- | Four-example minibatches, one child per generation, default feedback bounds.
defaultGepaEvidenceConfig :: GepaEvidenceConfig
defaultGepaEvidenceConfig = GepaEvidenceConfig defaultFeedbackConfig {failureClassification = evidenceFailurePolicy} 4 1

-- | Output-shaped failures are counted failures scored zero; infrastructure
-- failures abort.
evidenceFailurePolicy :: ShikumiError -> FailurePolicy
evidenceFailurePolicy e = if isJust (recordableError e) then FailScore scoreZero else FailAbort

-- | GEPA over production evidence: the validation split ranks candidates, stored
-- critiques feed reflection, and program-scoped critiques are rendered when any
-- exists.
gepaEvidenceOptimizer :: GepaEvidenceConfig -> Program ReflectIn ReflectOut -> OptimizerSpec i o
gepaEvidenceOptimizer cfg proposer =
  OptimizerSpec
    { optimizerId = "shikumi.optimize.gepa",
      optimizerVersion = "0.4.0.0",
      optimizerConfig =
        object
          [ "minibatchSize" .= cfg.minibatch,
            "childrenPerGeneration" .= cfg.generationSize,
            "critiqueCharacters" .= critiqueCharacters cfg.feedback,
            "reflectionExamples" .= reflectionExamples cfg.feedback,
            "reflectionCharacters" .= reflectionCharacters cfg.feedback,
            "programCritiques" .= ("when-stored" :: Text)
          ],
      buildOptimizer = \inputs ->
        let programScoped = any (isNothing . critiqueNode) inputs.trainingCritiques
            fc = cfg.feedback {includeProgramCritique = includeProgramCritique cfg.feedback || programScoped}
            callback = FeedbackCallback (storedCritiqueFeedback inputs.trainingExampleIds inputs.trainingCritiques inputs.metric)
            base = defaultGEPAConfig callback
         in gepaWith
              base
                { validationDataset = if null (datasetExamples inputs.validation) then Nothing else Just inputs.validation,
                  feedbackConfig = fc,
                  minibatchSize = cfg.minibatch,
                  childrenPerGeneration = cfg.generationSize
                }
              proposer
    }

-- ---------------------------------------------------------------------------
-- Jobs
-- ---------------------------------------------------------------------------

-- | The two phase recordings of a job. A job that stopped before the comparison
-- has no comparison recording.
data JobRecordings = JobRecordings
  { optimizationRecording :: Recording,
    comparisonRecording :: Maybe Recording
  }
  deriving stock (Eq, Show)

-- | Record live provider outcomes, or replay a job's recordings.
data ExecutionMode = RecordLive | Replay JobRecordings

-- | Who runs the job, when, and with which sources and exposure count.
data ExecutionContext = ExecutionContext
  { principal :: Text,
    createdAt :: UTCTime,
    jobId :: Text,
    traceRef :: Maybe Text,
    sources :: [SourceRef],
    exposure :: HoldoutExposure
  }

-- | Everything a job needs.
data EvidenceJob es i o = EvidenceJob
  { dataset :: EvidenceDataset,
    codec :: EvidenceCodec i o,
    template :: Program i o,
    baseline :: ProgramArtifact,
    optimizer :: OptimizerSpec i o,
    limits :: RunLimits,
    searchMetric :: Metric o,
    -- | custom measures from the expected output and the example's evidence;
    -- only ids the policy declares are kept, and non-finite values are missing
    customMeasures :: o -> EvaluationEvidence o -> Map Text Double,
    policy :: MetricPolicy,
    context :: ExecutionContext,
    -- | the caller's routing and request defaults, such as
    -- @withRequestDefaults d . routeLLM@, or 'id'
    requestPipeline :: forall a. Eff es a -> Eff es a,
    mode :: ExecutionMode
  }

-- | Facts about the run that are not sealed, because they differ between a live
-- run and its replay.
data JobSummary = JobSummary
  { executionMode :: Text,
    comparisonRan :: Bool,
    exposureConsumed :: Bool
  }
  deriving stock (Eq, Show)

-- | A job's outputs.
data EvidenceJobResult = EvidenceJobResult
  { candidate :: Maybe ProgramArtifact,
    report :: ComparisonReport,
    recordings :: JobRecordings,
    summary :: JobSummary
  }

-- | Run an evidence job. Typed infrastructure failures ('ProviderError',
-- 'ProviderFailure', a cost-ceiling 'BudgetExceeded') abort the job with the
-- original error and no report. Replay divergences and unrecordable calls are
-- exceptions that also abort it.
runEvidenceJob ::
  forall es i o.
  (LLM :> es, Concurrent :> es, Error ShikumiError :> es, Time :> es, Prim :> es) =>
  EvidenceJob es i o -> Eff es EvidenceJobResult
runEvidenceJob job = do
  optBoundary <- case job.mode of
    RecordLive -> newRecorder
    Replay rs -> newReplayer rs.optimizationRecording
  case preflight of
    Left reasons -> do
      optRecording <- finishOptimization optBoundary
      stopWith Nothing (JobRecordings optRecording Nothing) (earlyFacts {inputProblems = reasons}) Nothing
    Right (sealed, baselineProgram) -> do
      setBoundaryScope optBoundary "optimization"
      let inputs =
            OptimizerInputs
              { validation = sealedValidation sealed,
                trainingExampleIds = sealedTrainingIds sealed,
                trainingCritiques = sealedTrainingCritiques sealed,
                metric = job.searchMetric
              }
          configured = job.optimizer.buildOptimizer inputs
          runCfg = RunConfig {runLimits = job.limits, eventSink = const (pure ())}
      ((compiled, optReport), optUsage) <-
        withBoundary optBoundary . pipeline . withUsageTotals $
          optimizeWith runCfg configured (sealedTraining sealed) job.searchMetric baselineProgram
      optRecording <- finishOptimization optBoundary
      optRoutes <- boundaryRoutes optBoundary Nothing
      let record =
            OptimizationRecord
              { optimizerId = job.optimizer.optimizerId,
                optimizerVersion = job.optimizer.optimizerVersion,
                optimizerConfig = job.optimizer.optimizerConfig,
                seed = deterministicSeed job.limits,
                budget = job.limits,
                predictedOperations = predictedWork optReport,
                admittedOperations = optReport.admittedOperations,
                usage = usageSummary optUsage,
                runStatus = optReport.runStatus,
                datasetDigest = ds.contentDigest,
                routes = optRoutes,
                recordingDigest = optRecording.contentDigest
              }
          optOnly = JobRecordings optRecording Nothing
          reloaded = decodeCompiledOnto job.template (encodeCompiled compiled)
          sameShape = programShape (compiledProgram compiled) == programShape job.template
          candidateSpec = ArtifactSpec (ctx.jobId <> "/candidate") ctx.sources ctx.createdAt ctx.principal
      case reloaded of
        Right loaded
          | sameShape,
            Right cand <- sealArtifact candidateSpec job.codec (Just job.baseline.contentDigest) (Just record) loaded ->
              if cand.compiledState == job.baseline.compiledState
                then stopWith (Just cand) optOnly (earlyFacts {candidateIdentical = True}) Nothing
                else
                  if exposureExhausted sp.holdoutExposureLimit ctx.exposure
                    then stopWith (Just cand) optOnly (earlyFacts {exposureLimitReached = True}) Nothing
                    else compare' sealed baselineProgram loaded cand optRecording
        _ -> stopWith Nothing optOnly (earlyFacts {structureMatches = False}) Nothing
  where
    pipeline :: forall a. Eff es a -> Eff es a
    pipeline act = case job of EvidenceJob {requestPipeline = p} -> p act
    ctx = job.context
    ds = job.dataset
    pol = job.policy
    sp = ds.splitPolicy
    liveMode = case job.mode of RecordLive -> True; Replay _ -> False
    holdoutRecords = [e | e <- ds.examples, e.split == Holdout]
    holdoutLabeled = length [() | e <- holdoutRecords, isJust e.expected]
    contamination = [() | GroupCrossesSplits {} <- datasetProblems] ++ [() | InputCrossesSplits {} <- datasetProblems]
    datasetProblems = either id (const []) (validateDataset ds)

    earlyFacts =
      ComparisonFacts
        { inputProblems = [],
          structureMatches = True,
          holdoutContaminated = not (null contamination),
          holdoutSize = length holdoutRecords,
          holdoutMinimum = sp.minHoldoutExamples,
          labeledSamples = holdoutLabeled,
          missingLabels = length holdoutRecords - holdoutLabeled,
          exposureLimitReached = False,
          candidateIdentical = False,
          routesMatch = True,
          comparisonFinished = False,
          baselineMetrics = Map.empty,
          candidateMetrics = Map.empty
        }

    reason code' detail' = Reason code' detail'

    -- Every check that needs no model call. Contamination and holdout size are
    -- reported through their own facts rather than as generic dataset problems.
    preflight :: Either [Reason] (SealedDataset i o, Program i o)
    preflight =
      let datasetReasons =
            [ reason "dataset-invalid" (T.pack (show e))
            | e <- datasetProblems,
              case e of GroupCrossesSplits {} -> False; InputCrossesSplits {} -> False; HoldoutTooSmall {} -> False; _ -> True
            ]
          opened = openDataset job.codec ds
          openReasons = case opened of
            Left es | null datasetProblems -> [reason "dataset-invalid" (T.pack (show e)) | e <- es]
            _ -> []
          loaded = loadArtifact job.codec job.template job.baseline
          baselineReasons = either (map (reason "baseline-invalid" . T.pack . show)) (const []) loaded
          policyReasons = either (map (reason "policy-invalid" . T.pack . show)) (const []) (validatePolicy pol)
          sourceReasons =
            [reason "source-missing" ("no source reference for role " <> r) | r <- missingSourceRoles ctx.sources]
              ++ [reason "source-invalid" e | Left e <- map validateSourceRef ctx.sources]
          concurrencyReasons =
            [reason "concurrency-not-sequential" "evidence jobs require evaluationConcurrency 1" | evaluationConcurrency job.limits /= 1]
          paths = programNodePaths job.template
          critiqueReasons = case opened of
            Right sealed ->
              [ reason "dataset-invalid" ("critique on " <> critiqueExampleId c <> " names a node the template does not have")
              | c <- sealedTrainingCritiques sealed,
                Just p <- [critiqueNode c],
                p `notElem` paths
              ]
            Left _ -> []
          allReasons = datasetReasons ++ openReasons ++ baselineReasons ++ policyReasons ++ sourceReasons ++ concurrencyReasons ++ critiqueReasons
       in case (allReasons, opened, loaded) of
            ([], Right sealed, Right compiled) | null contamination && length holdoutRecords >= sp.minHoldoutExamples && holdoutLabeled > 0 -> Right (sealed, compiledProgram compiled)
            ([], _, _) -> Left []
            _ -> Left allReasons

    finishOptimization b = reseal <$> finishBoundary b "optimization"
    reseal = sealRecording

    bindingsFor cand =
      ReportBindings
        { baselineDigest = job.baseline.contentDigest,
          candidateDigest = (.contentDigest) <$> cand,
          datasetDigest = ds.contentDigest,
          policyDigest = digestPolicy pol,
          evaluatorDigest = digestEvaluator evidenceEvaluator,
          sources = ctx.sources
        }

    exposureRecord consumed =
      ExposureRecord
        { limit = sp.holdoutExposureLimit,
          prior = ctx.exposure.prior,
          ordinal = if consumed then Just (ctx.exposure.prior + 1) else Nothing,
          override = ctx.exposure.override
        }

    -- Seal a report that did not run the comparison.
    stopWith cand recs facts _ = do
      let (c, rs) = conclude pol facts
          rep =
            sealReport
              ComparisonReport
                { artifactKind = reportKind,
                  schemaVersion = 1,
                  reportId = ctx.jobId <> "/report",
                  bindings = bindingsFor cand,
                  policy = pol,
                  evaluator = evidenceEvaluator,
                  baselineResult = Nothing,
                  candidateResult = Nothing,
                  constraintResults = [],
                  primaryComparison = Nothing,
                  exposure = exposureRecord False,
                  predictedOperations = 0,
                  admittedOperations = 0,
                  recordingDigest = Nothing,
                  traceRef = ctx.traceRef,
                  conclusion = c,
                  reasons = rs,
                  createdAt = ctx.createdAt,
                  createdBy = ctx.principal,
                  contentDigest = Digest ""
                }
      pure (EvidenceJobResult cand rep recs (JobSummary modeName False False))

    modeName = if liveMode then "record-live" else "replay"

    compare' sealed baselineProgram (CompiledProgram candidateProgram) cand optRecording = do
      cmpBoundary <- case job.mode of
        RecordLive -> newRecorder
        Replay rs -> newReplayer (maybe emptyRecording id rs.comparisonRecording)
      let labeled = [(hid, Example i o) | HoldoutExample hid i (Just o) <- sealedHoldout sealed]
          ids = map fst labeled
          holdoutDs = Dataset (map snd labeled)
          cmpCfg =
            RunConfig
              { runLimits = RunLimits (max 0 pol.maxComparisonOperations) 2 1 (deterministicSeed job.limits),
                eventSink = const (pure ())
              }
          classify = evidenceFailurePolicy
          declared = Set.fromList pol.customMeasures
          arm session ident label prog = do
            setBoundaryScope cmpBoundary label
            latency <- newIORef (0 :: Int)
            rowsRef <- newIORef []
            let runner input = do
                  writeIORef latency 0
                  interpose
                    ( \_ -> \case
                        Complete m c o' -> do
                          response <- complete m c o'
                          atomicModifyIORef' latency (\n -> (n + response ^. #latencyMs, ()))
                          pure response
                        Stream m c o' -> stream m c o'
                    )
                    (runProgramObserved prog input)
                objective expected measured = do
                  elapsed <- readIORef latency
                  let ev = measured.evidence
                      result = executionResult ev
                      timedOut = isTimeout result || maybe False (elapsed >) pol.exampleTimeoutMs
                      done = isRight result && not timedOut
                      quality = case result of
                        Right out | done -> unScore (job.searchMetric expected (prediction out))
                        _ -> 0
                      u = executionUsage ev
                      custom = Map.filterWithKey (\k v -> Set.member k declared && finite v) (job.customMeasures expected ev)
                      builtIn =
                        Map.fromList
                          [ ("quality", quality),
                            ("completed", if done then 1 else 0),
                            ("timed_out", if timedOut then 1 else 0),
                            ("cost_usd", fromRational (totalCostUsd u)),
                            ("latency_ms", fromIntegral elapsed),
                            ("operations", fromIntegral measured.operations),
                            ("tokens", fromIntegral u.totalTokens)
                          ]
                      outcome'
                        | done = RowCompleted
                        | timedOut = RowTimedOut
                        | otherwise = RowFailed
                      rowId = case drop (exampleIndex ev) ids of (x : _) -> x; [] -> T.pack (show (exampleIndex ev))
                  atomicModifyIORef' rowsRef (\rs -> (ExampleRow rowId outcome' (Map.union builtIn custom) : rs, ()))
                  pure (Map.singleton "quality" quality)
            (rep, used) <- withUsageTotals (evaluateCandidate session ident holdoutDs runner classify job.searchMetric qualityPolicy objective)
            rows <- reverse <$> readIORef rowsRef
            pure (rep, if candidateStatus rep == CandidateCompleted then rows else [], used)
      (outcome, cmpReport) <-
        withBoundary cmpBoundary . pipeline $
          runSearchSession cmpCfg $ \session -> do
            baselineId <- reserveCandidate session
            candidateId' <- reserveCandidate session
            case (baselineId, candidateId') of
              (Just b, Just c) -> do
                addPredictedWork session (scoringCost holdoutDs baselineProgram + scoringCost holdoutDs candidateProgram)
                rb <- arm session b "baseline" baselineProgram
                rc <- arm session c "candidate" candidateProgram
                pure (Just (rb, rc))
              _ -> pure Nothing
      arms <- either throwError pure outcome
      cmpRecording <- reseal <$> finishBoundary cmpBoundary "comparison"
      baseRoutes <- boundaryRoutes cmpBoundary (Just "baseline")
      candRoutes <- boundaryRoutes cmpBoundary (Just "candidate")
      let missingCount = length [() | HoldoutExample _ _ Nothing <- sealedHoldout sealed]
          armResult (armRep, rows, used) rts =
            ArmResult
              { status = T.pack (show (candidateStatus armRep)),
                sampleCount = length labeled,
                completed = length [() | r <- rows, r.outcome == RowCompleted],
                failures = length [() | r <- rows, r.outcome == RowFailed],
                timeouts = length [() | r <- rows, r.outcome == RowTimedOut],
                missingLabels = missingCount,
                metrics = [MetricValue k v | (k, v) <- Map.toList (armMetrics pol rows)],
                rows = rows,
                routes = rts,
                usage = usageSummary used,
                admittedOperations = candidateOperations armRep
              }
          finished = case arms of
            Just ((rb, _, _), (rc, _, _)) -> candidateStatus rb == CandidateCompleted && candidateStatus rc == CandidateCompleted
            Nothing -> False
          metricsOf = maybe Map.empty (\(_, rows, _) -> armMetrics pol rows)
          baseMetrics = metricsOf (fst <$> arms)
          candMetrics = metricsOf (snd <$> arms)
          facts =
            earlyFacts
              { routesMatch = Set.fromList (map (.route) baseRoutes) == Set.fromList (map (.route) candRoutes),
                comparisonFinished = finished,
                baselineMetrics = baseMetrics,
                candidateMetrics = candMetrics
              }
          (c, rs) = conclude pol facts
          rep =
            sealReport
              ComparisonReport
                { artifactKind = reportKind,
                  schemaVersion = 1,
                  reportId = ctx.jobId <> "/report",
                  bindings = bindingsFor (Just cand),
                  policy = pol,
                  evaluator = evidenceEvaluator,
                  baselineResult = (\a -> armResult a baseRoutes) . fst <$> arms,
                  candidateResult = (\a -> armResult a candRoutes) . snd <$> arms,
                  constraintResults = evaluateConstraints pol baseMetrics candMetrics,
                  primaryComparison = Just (comparePrimary pol baseMetrics candMetrics),
                  exposure = exposureRecord True,
                  predictedOperations = predictedWork cmpReport,
                  admittedOperations = cmpReport.admittedOperations,
                  recordingDigest = Just cmpRecording.contentDigest,
                  traceRef = ctx.traceRef,
                  conclusion = c,
                  reasons = rs,
                  createdAt = ctx.createdAt,
                  createdBy = ctx.principal,
                  contentDigest = Digest ""
                }
      pure (EvidenceJobResult (Just cand) rep (JobRecordings optRecording (Just cmpRecording)) (JobSummary modeName True True))

    isTimeout = \case
      Left Timeout {} -> True
      _ -> False

    emptyRecording =
      sealRecording
        Recording
          { artifactKind = recordingKind,
            schemaVersion = 1,
            phase = "comparison",
            cacheKeyVersion = currentKeyVersion,
            entries = [],
            contentDigest = Digest ""
          }
