{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Reflective evolution with failure-aware, node-grounded evidence. Legacy
-- callbacks produce explicitly program-scoped critiques, never node attribution.
module Shikumi.Optimize.GEPA
  ( FeedbackMetric,
    ReflectIn (..),
    ReflectOut (..),
    reflectiveProposer,
    captureFeedback,
    mutateNode,
    gepa,
    gepaWith,
    GEPAConfig (..),
    ObjectiveCallback (..),
    defaultGEPAConfig,
    gepaWithFeedback,
    FeedbackCallback (..),
    mutateFromEvidence,
  )
where

import Control.Monad (forM, forM_, when)
import Data.Either (isRight)
import Data.List (find, findIndex, sortOn)
import Data.Maybe (catMaybes)
import Data.Text (Text)
import Data.Text qualified as T
import Effectful (Eff, (:>))
import Effectful.Concurrent (Concurrent)
import Effectful.Error.Static (Error, throwError)
import Effectful.Prim (Prim)
import GHC.Generics (Generic)
import Shikumi.Adapter (ToPrompt)
import Shikumi.Effect.Time (Time)
import Shikumi.Error (ShikumiError (..))
import Shikumi.Eval
  ( Dataset,
    dataset,
    datasetExamples,
    datasetSize,
    unScore,
  )
import Shikumi.Eval.Evaluate (tryShikumi)
import Shikumi.LLM (LLM)
import Shikumi.Module (predict)
import Shikumi.Optimize.Execution qualified as X
import Shikumi.Optimize.Feedback
import Shikumi.Optimize.Pareto (Candidate (..), paretoFrontier, sampleParent)
import Shikumi.Optimize.Report qualified as R
import Shikumi.Optimize.Search (effectiveInstructionAt, freezeProgram, newBudgetMeter, scoringCost, setNodeInstrIfNew, tryCharge)
import Shikumi.Optimize.Types (Budget (..), ConfiguredOptimizer (..), Optimizer (..))
import Shikumi.Program
  ( NodeFields (..),
    Program,
    foldParams,
    nodeFieldsIndexed,
    runProgram,
    setProgramParams,
  )
import Shikumi.Schema (FromModel, ToSchema, Validatable)
import Shikumi.Signature (mkSignature)
import Shikumi.Trace.Feedback (FeedbackLog, attachFeedback, feedbackFor, runFeedback)
import Shikumi.Trace.Node (NodePath (..), programNodePaths)
import Shikumi.Trace.Observation (NodeObservation (..), runProgramObserved)

-- ---------------------------------------------------------------------------
-- The reflective proposer
-- ---------------------------------------------------------------------------

-- | The reflective proposer's input: the node's current instruction, its accumulated
-- critiques, program/dataset summaries, and the node's field names.
data ReflectIn = ReflectIn
  { currentInstruction :: !Text,
    feedback :: !Text,
    programSummary :: !Text,
    datasetSummary :: !Text,
    fieldSummary :: !Text
  }
  deriving stock (Generic, Show)

instance FromModel ReflectIn

instance ToPrompt ReflectIn

newtype ReflectOut = ReflectOut {proposedInstruction :: Text}
  deriving stock (Generic, Show)

instance ToSchema ReflectOut

instance FromModel ReflectOut

instance ToPrompt ReflectOut

instance Validatable ReflectOut

-- | The default reflective proposer: a single predict node that addresses the
-- feedback specifically.
reflectiveProposer :: Program ReflectIn ReflectOut
reflectiveProposer =
  predict
    ( mkSignature
        "You are improving the instruction for one node of a language-model pipeline. You are \
        \given the node's current instruction, textual feedback describing how it failed on \
        \several examples, a summary of the whole program, a summary of the dataset, and the \
        \node's input/output field names. Write a single improved instruction that addresses the \
        \feedback specifically, in the `proposedInstruction` field."
    )

-- ---------------------------------------------------------------------------
-- M1 — feedback capture
-- ---------------------------------------------------------------------------

-- | Compatibility projection. Program critique is stored once at the root key,
-- labeled with its provenance; use 'captureEvidence' to retain full attribution.
captureFeedback ::
  (LLM :> es, Error ShikumiError :> es, Prim :> es) =>
  Dataset i o -> FeedbackMetric o -> Program i o -> Eff es (FeedbackLog, [Double])
captureFeedback ds fm prog = do
  captured <- captureEvidence defaultFeedbackConfig ds (legacyFeedback fm) prog
  (_, logbook) <- runFeedback $ forM_ captured $ \(_, fb, _) ->
    forM_ (programCritique fb) $ \(source, t) ->
      when (not (T.null t)) (attachFeedback (NodePath []) ("program (" <> tshow source <> "): " <> t))
  pure (logbook, [unScore (overallScore fb) | (_, fb, _) <- captured])

-- ---------------------------------------------------------------------------
-- M2 — reflective mutation
-- ---------------------------------------------------------------------------

-- | Reflect on node @idx@'s accumulated feedback and overwrite its instruction with
-- the proposal. A node with no feedback is left unchanged (nothing to reflect on).
mutateNode ::
  (LLM :> es, Error ShikumiError :> es) =>
  Program ReflectIn ReflectOut ->
  -- | program summary
  Text ->
  -- | dataset summary
  Text ->
  [NodeFields] ->
  FeedbackLog ->
  [NodePath] ->
  Int ->
  Program i o ->
  Eff es (Program i o)
mutateNode proposer progSummary dataSummary fields fblog paths idx prog =
  case drop idx paths of
    [] -> pure prog
    (path : _) ->
      let crits = feedbackFor path fblog
       in if null crits
            then pure prog
            else do
              let cur = effectiveInstructionAt idx prog
                  fldSummary = renderFields (drop idx fields)
                  fb = T.intercalate "\n" crits
              ReflectOut newInstr <-
                runProgram proposer (ReflectIn cur fb progSummary dataSummary fldSummary)
              pure (setNodeInstrIfNew idx newInstr prog)

-- | Render a node's field names for the proposer prompt.
renderFields :: [NodeFields] -> Text
renderFields [] = "inputs: ?; outputs: ?"
renderFields (NodeFields ins outs : _) =
  "inputs: " <> commas ins <> "; outputs: " <> commas outs
  where
    commas xs = if null xs then "?" else T.intercalate ", " xs

-- ---------------------------------------------------------------------------
-- M3 — the evolution loop
-- ---------------------------------------------------------------------------

-- | The reflective evolutionary optimizer. Takes its reflective proposer and feedback
-- metric explicitly (so it is testable under a stub LM) and returns V1's
-- 'Optimizer'. GEPA gates its seed evaluation before any LM call; if the budget is
-- too small to score the student once, it returns the student unscored. Each
-- evolution step reserves a conservative full-step cost before capture, reflection,
-- and child scoring.
gepa ::
  Program ReflectIn ReflectOut ->
  FeedbackMetric o ->
  Budget ->
  Optimizer i o
gepa proposer fbMetric budget = Optimizer $ \train metric student -> do
  -- Preserve the legacy all-or-nothing predicted seed gate.
  if datasetSize train == 0 || maxLmCalls budget < scoringCost train student || maxCandidates budget <= 0
    then pure (freezeProgram student)
    else do
      let controls = X.defaultRunConfig {X.runLimits = X.RunLimits (max 0 (maxLmCalls budget)) (max 0 (maxCandidates budget)) 1 1}
          cfg =
            (defaultGEPAConfig (FeedbackCallback (legacyFeedback fbMetric)))
              { feedbackConfig = defaultFeedbackConfig {includeProgramCritique = True},
                minibatchSize = datasetSize train
              }
      (result, _) <- X.runSearchSession controls $ \session -> runConfiguredOptimizer (gepaWith cfg proposer) session train metric student
      either throwError pure result

-- | An effectful callback portable across the optimizer's existing effect row.
newtype FeedbackCallback o = FeedbackCallback
  { runFeedbackCallback ::
      forall es.
      (LLM :> es, Concurrent :> es, Error ShikumiError :> es, Time :> es, Prim :> es) =>
      EvidenceMetric es o
  }

gepaWithFeedback :: FeedbackConfig -> Program ReflectIn ReflectOut -> FeedbackCallback o -> Budget -> Optimizer i o
gepaWithFeedback cfg proposer callback budget = Optimizer $ \train metric student -> do
  either throwError pure (validateFeedbackConfig cfg)
  meter <- newBudgetMeter budget
  let paths = programNodePaths student
      progSummary = fallbackProgramSummary (length paths)
      dataSummary = fallbackDatasetSummary (datasetSize train)
      maxCands = maxCandidates budget
      rebuild cand = either (const student) id (setProgramParams (params cand) student)
      seedCost = scoringCost train student

  seedFits <- tryCharge meter seedCost
  if not seedFits
    then pure (freezeProgram student)
    else do
      seedRows <- captureEvidence cfg train (legacyFeedback (\e p -> (metric e p, ""))) student
      let candidateFrom prog rows =
            let scores = [unScore (overallScore fb) | (_, fb, _) <- rows]
             in Candidate (foldParams prog) scores (if null scores then 0 else sum scores / fromIntegral (length scores))
          seedCand = candidateFrom student seedRows

          -- A full step costs: capture + child evaluation over the whole dataset,
          -- plus one reflective proposer call.
          stepCost = 2 * seedCost + 1
          stepCap = maxCands + 4

          loop step cands seed frontier
            | step >= stepCap = pure (bestOf seedCand frontier)
            | length cands >= maxCands = pure (bestOf seedCand frontier)
            | otherwise = do
                fitsStep <- tryCharge meter stepCost
                if not fitsStep
                  then pure (bestOf seedCand frontier)
                  else case sampleParent seed (paretoFrontier frontier) of
                    Nothing -> pure (bestOf seedCand frontier)
                    Just (parent, seed') -> do
                      let parentProg = rebuild parent
                      captured <- captureEvidence cfg train (runFeedbackCallback callback) parentProg
                      child <- mutateFromEvidence cfg proposer progSummary dataSummary captured step parentProg
                      if foldParams child == foldParams parentProg
                        then loop (step + 1) cands seed' frontier
                        else do
                          rows <- captureEvidence cfg train (legacyFeedback (\e p -> (metric e p, ""))) child
                          let childCand = candidateFrom child rows
                              frontier' = paretoFrontier (childCand : frontier)
                          loop (step + 1) (childCand : cands) seed' frontier'

      best <- loop 0 [seedCand] 1 [seedCand]
      pure (freezeProgram (rebuild best))

-- | Reflect only on executed nodes with attributed critiques (or explicitly
-- enabled program fallback). Redaction covers all evidence, errors and critiques
-- before it reaches the proposer. Rejected retries remain labeled evidence.
mutateFromEvidence ::
  (LLM :> es, Error ShikumiError :> es) =>
  FeedbackConfig ->
  Program ReflectIn ReflectOut ->
  Text ->
  Text ->
  [(EvaluationEvidence o, FeedbackResult, a)] ->
  Int ->
  Program i o ->
  Eff es (Program i o)
mutateFromEvidence cfg proposer progSummary dataSummary rows step prog = do
  either throwError pure (validateFeedbackConfig cfg)
  validated <- mapM (\(ev, fb, _) -> (ev,) <$> either throwError pure (validateFeedback cfg paths ev fb)) rows
  let relevant path ev fb =
        [ obs
        | obs <- observations ev,
          observationPath obs == path,
          not (observationOpaque obs),
          any (\f -> feedbackPath f == path && not (T.null (critique f)) && maybe True (== observationInvocation obs) (feedbackInvocation f)) (nodeCritiques fb)
            || (includeProgramCritique cfg && maybe False (not . T.null . snd) (programCritique fb))
        ]
      evidence path = [(ev, fb, obs) | (ev, fb) <- validated, obs <- relevant path ev fb]
      eligible = [p | p <- paths, not (null (evidence p))]
  case eligible of
    [] -> pure prog
    _ | reflectionExamples cfg == 0 || reflectionCharacters cfg == 0 -> pure prog
    _ -> do
      let path = eligible !! (max 0 step `mod` length eligible)
          local = sortOn (\(_, _, obs) -> (isRight (observationStatus obs), null (observationRejectedBy obs))) (evidence path)
          chosen = take (reflectionExamples cfg) local
          render (ev, fb, obs) =
            "example "
              <> tshow (exampleIndex ev)
              <> "; invocation "
              <> tshow (observationInvocation obs)
              <> "; status: "
              <> tshow (observationStatus obs)
              <> "; rejected scopes: "
              <> tshow (observationRejectedBy obs)
              <> "\nnode critiques: "
              <> T.intercalate
                "\n"
                [ tshow (provenance f) <> ": " <> critique f
                | f <- nodeCritiques fb,
                  feedbackPath f == path,
                  maybe True (== observationInvocation obs) (feedbackInvocation f)
                ]
              <> (if includeProgramCritique cfg then "\nprogram critique: " <> maybe "" tshow (programCritique fb) else "")
              <> "\ninput: "
              <> maybe (tshow (observationInputFields obs)) tshow (observationInput obs)
              <> "\noutput: "
              <> maybe (tshow (observationOutputFields obs)) tshow (observationOutput obs)
          payload =
            T.intercalate "\n\n" (map render chosen)
              <> if length chosen < length local then "\n[examples truncated]" else ""
          clean = boundText (reflectionCharacters cfg) . redactEvidence cfg
      case findIndex (== path) paths of
        Nothing -> pure prog
        Just idx -> do
          ReflectOut newInstruction <-
            runProgram
              proposer
              ( ReflectIn
                  (clean (effectiveInstructionAt idx prog))
                  (clean payload)
                  (clean progSummary)
                  (clean dataSummary)
                  (clean (renderFields (drop idx (nodeFieldsIndexed prog))))
              )
          pure (setNodeInstrIfNew idx newInstruction prog)
  where
    paths = programNodePaths prog

-- | The frontier candidate with the highest aggregate (earliest on ties); falls back
-- to the seed if the frontier is somehow empty.
bestOf :: Candidate -> [Candidate] -> Candidate
bestOf seedCand = foldl' (\b c -> if aggregate c > aggregate b then c else b) seedCand

-- | A minimal program summary (EP-19's program describer is the richer source).
fallbackProgramSummary :: Int -> Text
fallbackProgramSummary k = "A language-model program with " <> tshow k <> " predict node(s)."

-- | A minimal dataset summary (EP-19's dataset summarizer is the richer source).
fallbackDatasetSummary :: Int -> Text
fallbackDatasetSummary k = "A dataset of " <> tshow k <> " example(s)."

tshow :: (Show a) => a -> Text
tshow = T.pack . show

-- | Callbacks are trusted code. The framework sends only training evidence to
-- reflection; it is not a security sandbox around caller closures.
data GEPAConfig i o = GEPAConfig
  { validationDataset :: !(Maybe (Dataset i o)),
    feedbackConfig :: !FeedbackConfig,
    feedbackCallback :: !(FeedbackCallback o),
    objectivePolicy :: !R.ObjectivePolicy,
    objectiveCallback :: !(Maybe (ObjectiveCallback o)),
    minibatchSize :: !Int,
    childrenPerGeneration :: !Int
  }

newtype ObjectiveCallback o = ObjectiveCallback
  { runObjectiveCallback ::
      forall es.
      (LLM :> es, Concurrent :> es, Error ShikumiError :> es, Time :> es, Prim :> es) =>
      X.ObjectiveMetric es o
  }

defaultGEPAConfig :: FeedbackCallback o -> GEPAConfig i o
defaultGEPAConfig callback = GEPAConfig Nothing defaultFeedbackConfig callback R.qualityPolicy Nothing 4 1

-- | Configured reflective evolution, with full validation before frontier entry.
-- Children are proposed serially from a generation snapshot, then scored in
-- bounded batches. Width one retains adaptive single-child evolution.
gepaWith :: GEPAConfig i o -> Program ReflectIn ReflectOut -> ConfiguredOptimizer i o
gepaWith cfg proposer = ConfiguredOptimizer $ \session train metric student -> do
  either throwError pure (validateFeedbackConfig (feedbackConfig cfg))
  either (throwError . ValidationFailure) pure (R.validateObjectives (objectivePolicy cfg))
  when (datasetSize train == 0 || maybe False ((== 0) . datasetSize) (validationDataset cfg)) $
    throwError (ValidationFailure "GEPA training and explicit validation datasets must be nonempty")
  when (minibatchSize cfg <= 0 || childrenPerGeneration cfg <= 0) $
    throwError (ValidationFailure "GEPA minibatch and generation sizes must be positive")
  let validation = maybe train id (validationDataset cfg)
      mode = maybe "training-as-validation compatibility" (const "explicit validation") (validationDataset cfg)
      policy = objectivePolicy cfg
      minibatch = dataset (take (minibatchSize cfg) (datasetExamples train))
      objectivesFor expected measured = case objectiveCallback cfg of
        Nothing -> X.scalarObjectives metric expected measured
        Just callback -> runObjectiveCallback callback expected measured
      evaluate ident prog = do
        X.addPredictedWork session (scoringCost validation prog)
        report <-
          X.evaluateCandidate
            session
            ident
            validation
            (runProgramObserved prog)
            (failureClassification (feedbackConfig cfg))
            metric
            policy
            objectivesFor
        pure (report, prog)
      best completed = case R.selectObjectiveWinner policy (map fst completed) of
        Nothing -> student
        Just winner -> maybe student snd (find (\(r, _) -> R.candidateId r == R.candidateId winner) completed)
      propose step parent = do
        X.addPredictedWork session (2 * scoringCost minibatch parent + 1)
        captured <- captureEvidence (feedbackConfig cfg) minibatch (runFeedbackCallback (feedbackCallback cfg)) parent
        child <-
          mutateFromEvidence
            (feedbackConfig cfg)
            proposer
            (fallbackProgramSummary (length (programNodePaths student)))
            (fallbackDatasetSummary (datasetSize train))
            captured
            step
            parent
        -- The screen verifies training execution/feedback before expensive full
        -- validation, without rejecting a child solely for lower training quality.
        _ <- captureEvidence (feedbackConfig cfg) minibatch (legacyFeedback (\e p -> (metric e p, ""))) child
        pure child
      loop step completed = do
        halted <- X.sessionStopped session
        if halted || step >= X.candidateLimit (X.sessionLimits session) + 4
          then pure completed
          else do
            let front = R.objectiveFrontier policy (map fst completed)
                parents = [p | (r, p) <- completed, R.candidateId r `elem` map R.candidateId front]
                parent = if null parents then best completed else parents !! ((X.deterministicSeed (X.sessionLimits session) + step) `mod` length parents)
            proposals <- tryShikumi $ forM [0 .. childrenPerGeneration cfg - 1] $ \offset -> do
              ident <- X.reserveCandidate session
              case ident of
                Nothing -> pure Nothing
                Just ix -> do
                  result <- tryShikumi (propose (step + offset) parent)
                  case result of
                    Right child -> pure (Just (ix, child))
                    Left e -> do
                      -- Close a reserved proposal as an incomplete/failed candidate
                      -- through the same generic lifecycle boundary.
                      _ <-
                        X.evaluateCandidate
                          session
                          ix
                          validation
                          (\_ -> throwError e)
                          (failureClassification (feedbackConfig cfg))
                          metric
                          policy
                          objectivesFor
                      pure Nothing
            case proposals of
              Left e -> do
                haltedNow <- X.sessionStopped session
                if haltedNow && e == BudgetExceeded "optimizer operation admission exhausted" then pure completed else throwError e
              Right pending -> do
                results <- X.evaluateCandidates session (uncurry evaluate) (catMaybes pending)
                let completed' = completed ++ results
                X.setSelection session mode policy
                loop (step + childrenPerGeneration cfg) completed'
  X.setSelection session mode policy
  seedId <- X.reserveCandidate session
  completed <- case seedId of
    Nothing -> pure []
    Just ident -> do
      seed <- evaluate ident student
      loop 0 [seed]
  X.setSelection session mode policy
  pure (freezeProgram (best completed))
