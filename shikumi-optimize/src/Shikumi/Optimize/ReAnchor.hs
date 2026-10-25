{-# LANGUAGE ScopedTypeVariables #-}

-- | Fit local thresholds, cuts and weights. All trials share run-local response
-- replay inside SearchSession admission; only new requests consume operations.
module Shikumi.Optimize.ReAnchor
  ( ReAnchorConfig (..),
    defaultReAnchorConfig,
    reAnchor,
    reAnchorWith,
    ReAnchorReport (..),
    FieldCalibration (..),
    ObservationSummary (..),
  )
where

import Baikai (Response)
import Control.Monad (foldM, when)
import Data.Aeson (FromJSON, Result (..), ToJSON, Value (..), fromJSON)
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.List (nub)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import Effectful (Eff, (:>))
import Effectful.Concurrent (Concurrent)
import Effectful.Error.Static (Error, throwError)
import Effectful.Prim.IORef (Prim, newIORef, readIORef)
import GHC.Generics (Generic)
import Shikumi.Adapter (assistantJSON)
import Shikumi.Compile.Types (CompiledProgram (..))
import Shikumi.Decision
import Shikumi.Decision.Runtime (evidenceOf)
import Shikumi.Decision.Setting
import Shikumi.Effect.Time (Time)
import Shikumi.Error (ShikumiError (..))
import Shikumi.Eval (Dataset, FailurePolicy (..), Metric, datasetSize)
import Shikumi.LLM (LLM)
import Shikumi.Optimize.Execution
import Shikumi.Optimize.ReAnchor.Fit
import Shikumi.Optimize.ReAnchor.Replay
import Shikumi.Optimize.Report qualified as R
import Shikumi.Optimize.Types (ConfiguredOptimizer (..))
import Shikumi.Program
import Shikumi.Trace.Node (NodePath, programNodePaths)

-- | Validation is report-only. For a full search, use RunLimits with
-- candidateLimit = 2000; replayed candidates consume no operation budget.
data ReAnchorConfig i o = ReAnchorConfig
  {validation :: !(Maybe (Dataset i o)), maxCandidatesPerStep :: !Int, foldCount :: !Int}

defaultReAnchorConfig :: ReAnchorConfig i o
defaultReAnchorConfig = ReAnchorConfig Nothing 40 5

data ObservationSummary = ObservationSummary
  {calls :: !Int, distinctValues :: !Int, minimumValue :: !(Maybe Double), maximumValue :: !(Maybe Double), candidatesTried :: !Int}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

data FieldCalibration = FieldCalibration
  { nodeIndex :: !Int,
    nodePath :: !Text,
    field :: !Text,
    parameter :: !Text,
    fittedValue :: !(Maybe DecisionSetting),
    skippedReason :: !(Maybe Text),
    trainScoreOriginal :: !Double,
    trainScoreAtStart :: !Double,
    trainScoreRetained :: !Double,
    observations :: !ObservationSummary,
    foldChecksPassed :: !Int,
    foldChecksFailed :: !Int
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

data ReAnchorReport = ReAnchorReport
  {trainScoreBefore :: !Double, trainScore :: !Double, valScoreBefore :: !(Maybe Double), valScore :: !(Maybe Double), fitted :: ![FieldCalibration]}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

reAnchor :: ReAnchorConfig i o -> ConfiguredOptimizer i o
reAnchor cfg = ConfiguredOptimizer $ \session ds metric program -> fst <$> reAnchorWith cfg session ds metric program

mean :: [Double] -> Double
mean [] = 0
mean xs = sum xs / fromIntegral (length xs)

reAnchorWith ::
  forall es i o.
  (LLM :> es, Concurrent :> es, Error ShikumiError :> es, Time :> es, Prim :> es) =>
  ReAnchorConfig i o -> SearchSession es -> Dataset i o -> Metric o -> Program i o -> Eff es (CompiledProgram i o, ReAnchorReport)
reAnchorWith cfg session train metric original = do
  when (datasetSize train == 0) (throwError (ValidationFailure "ReAnchor: empty training set"))
  when (maxCandidatesPerStep cfg < 2 || foldCount cfg < 2) (throwError (ValidationFailure "ReAnchor: candidate and fold counts must be at least two"))
  let targets = [(ix, path, j) | (ix, (path, js)) <- zip [0 ..] (zip (programNodePaths original) (nodeDecisionFieldsIndexed original)), j <- js]
  when (null targets) (throwError (ValidationFailure "ReAnchor: program has no rich decision outputs"))
  store <- newReplayStore
  let score ds metadata program = do
        reservation <- reserveCandidate session
        case reservation of
          Nothing -> pure Nothing
          Just ident -> do
            annotateCandidate session ident metadata
            seen <- newIORef []
            report <-
              evaluateCandidate
                session
                ident
                ds
                ( \input -> do
                    result <- runResponses store seen program input
                    pure (result, [])
                )
                (const FailAbort)
                metric
                R.qualityPolicy
                (scalarObjectives metric)
            responses <- readIORef seen
            pure $
              if R.candidateStatus report == R.CandidateCompleted
                then Just (ident, map snd (R.exampleScores report), responses)
                else Nothing
      scoreTrain = score train
      optionalValidation program = case validation cfg of
        Nothing -> pure Nothing
        Just ds
          | datasetSize ds == 0 -> pure Nothing
          | otherwise -> fmap (\(_, scores, _) -> mean scores) <$> score ds (Map.singleton "role" "validation-report-only") program
  initial <- scoreTrain (Map.singleton "role" "baseline") original
  valBefore <- optionalValidation original
  case initial of
    Nothing -> do
      setSelectedCandidate session Nothing "ReAnchor: unscored baseline; budget exhausted"
      pure (CompiledProgram original, ReAnchorReport 0 0 valBefore Nothing [])
    Just (initialId, initialScores, _) -> do
      let step (program, retainedId, retainedScores, rows) (ix, path, j) = do
            before <- scoreTrain (metadata ix path j "original" Nothing) program
            case before of
              Nothing -> pure (program, retainedId, retainedScores, rows)
              Just (beforeId, beforeScores, _) -> do
                let saved = decisionSettingFor (judgmentField j) (foldParams program !! ix)
                    start = fromMaybe (defaultSetting j) saved
                    set setting = mapParamsAt ix (setDecisionSetting (judgmentField j) setting)
                base <- scoreTrain (metadata ix path j "start" (Just start)) (set start program)
                case base of
                  Nothing -> pure (program, retainedId, retainedScores, rows)
                  Just (baseId, baseScores, responses) -> do
                    evidence <- either throwError pure (traverse (readEvidence j . snd) (filter ((== path) . fst) responses))
                    let trials current scores ident candidates = do
                          tried <-
                            traverse
                              ( \(setting, tie) -> do
                                  measured <- scoreTrain (metadata ix path j "trial" (Just setting)) (set setting program)
                                  pure (fmap (\(cid, sc, _) -> (sc, tie, (setting, cid))) measured)
                              )
                              candidates
                          let available = [x | Just x <- tried]
                              (kept, refused) = selectKept (foldCount cfg) scores available
                          pure $ case kept of
                            Just (sc, _, (setting, cid)) -> (setting, sc, cid, 1, 0, length available)
                            Nothing -> (current, scores, ident, 0, if refused then 1 else 0, length available)
                        fitNoul = case start of
                          NoulSetting t -> trials start baseScores baseId [(NoulSetting c, tie) | (c, tie) <- thresholdCandidates (maxCandidatesPerStep cfg) [p | FieldNoul (NoulEvidence p) <- evidence] t]
                          _ -> pure (start, baseScores, baseId, 0, 0, 0)
                        fitCuts = case start of
                          ScoreSetting cs ->
                            foldM
                              ( \(current, sc, cid, passed, failed, count) k -> case current of
                                  ScoreSetting values -> do
                                    let lo = if k == 0 then 0 else values !! (k - 1)
                                        hi = if k + 1 == length values then fromIntegral (length values) else values !! (k + 1)
                                        means = [v | FieldScore e <- evidence, Right (v, _) <- [deriveScore values e]]
                                        candidates = [(ScoreSetting (take k values ++ [c] ++ drop (k + 1) values), tie) | (c, tie) <- cutCandidates (maxCandidatesPerStep cfg) means lo hi (values !! k)]
                                    (next, sc', cid', p, f, n) <- trials current sc cid candidates
                                    pure (next, sc', cid', passed + p, failed + f, count + n)
                                  _ -> pure (current, sc, cid, passed, failed, count)
                              )
                              (start, baseScores, baseId, 0, 0, 0)
                              [0 .. length cs - 1]
                          _ -> pure (start, baseScores, baseId, 0, 0, 0)
                        fitWeights labels =
                          foldM
                            ( \(current, sc, cid, passed, failed, count) label -> case current of
                                ChoiceSetting ws -> do
                                  let weight l = Map.findWithDefault 1 l ws
                                      flips = [rival / p | FieldChoice (ChoiceEvidence ps _) <- evidence, let p = Map.findWithDefault 0 label ps, let rival = maximum (0 : [weight l * Map.findWithDefault 0 l ps | l <- labels, l /= label]), p > 0, rival > 0]
                                      candidates = [(ChoiceSetting (Map.insert label c ws), tie) | (c, tie) <- weightCandidates (maxCandidatesPerStep cfg) flips (weight label)]
                                  (next, sc', cid', p, f, n) <- trials current sc cid candidates
                                  pure (next, sc', cid', passed + p, failed + f, count + n)
                                _ -> pure (current, sc, cid, passed, failed, count)
                            )
                            (start, baseScores, baseId, 0, 0, 0)
                            labels
                    (setting, scores, ident, passed, failed, count) <- case judgmentKind j of
                      JudgeBoolean {} -> fitNoul
                      JudgeOrdered {} -> fitCuts
                      JudgeChoice labels -> fitWeights (map fst labels)
                    let (accepted, refused) = selectKept (foldCount cfg) beforeScores [(scores, [], ())]
                        keep = case accepted of Just _ -> True; _ -> False
                        chosen = if keep then set setting program else program
                        values = concatMap observedValues evidence
                        summary = ObservationSummary (length evidence) (length (nub values)) (safeMinimum values) (safeMaximum values) count
                        row = FieldCalibration ix (T.pack (show path)) (judgmentField j) (kindName j) (if keep then Just setting else Nothing) (if keep then Nothing else Just "fitted behaviour did not beat the original") (mean beforeScores) (mean baseScores) (mean (if keep then scores else beforeScores)) summary (passed + if keep then 1 else 0) (failed + if refused then 1 else 0)
                    pure (chosen, if keep then ident else beforeId, if keep then scores else beforeScores, rows ++ [row])
      (final, selected, scores, rows) <- foldM step (original, initialId, initialScores, []) targets
      valAfter <- optionalValidation final
      setSelection session "ReAnchor: strict improvement with held-out fold check" R.qualityPolicy
      setSelectedCandidate session (Just selected) "ReAnchor: retained settings passed strict improvement and held-out folds"
      pure (CompiledProgram final, ReAnchorReport (mean initialScores) (mean scores) valBefore valAfter rows)
  where
    metadata :: Int -> NodePath -> Judgment -> Text -> Maybe DecisionSetting -> Map.Map Text Text
    metadata ix path j role setting = Map.fromList [("node", T.pack (show ix)), ("path", T.pack (show path)), ("field", judgmentField j), ("parameter", kindName j), ("role", role), ("value", T.pack (show setting))]
    kindName j = case judgmentKind j of JudgeBoolean {} -> "threshold"; JudgeOrdered {} -> "cuts"; JudgeChoice {} -> "weights"
    observedValues = \case FieldNoul (NoulEvidence p) -> [p]; FieldChoice (ChoiceEvidence ps _) -> Map.elems ps; FieldScore e@(ScoreEvidence _ _) -> case deriveScore [] e of Right (v, _) -> [v]; _ -> []
    safeMinimum [] = Nothing
    safeMinimum xs = Just (minimum xs)
    safeMaximum [] = Nothing
    safeMaximum xs = Just (maximum xs)

readEvidence :: Judgment -> Response -> Either ShikumiError FieldEvidence
readEvidence j response = case evidenceOf [j] response of
  Just result -> result >>= \fields -> maybe (Left (MissingField (judgmentField j))) Right (Map.lookup (judgmentField j) fields)
  Nothing -> do
    value <- assistantJSON response
    raw <- case value of Object fields -> maybe (Left (MissingField (judgmentField j))) Right (KM.lookup (K.fromText (judgmentField j)) fields); _ -> Left (SchemaMismatch "ReAnchor: expected evidence object")
    let decode :: (FromJSON a) => (a -> FieldEvidence) -> Either ShikumiError FieldEvidence
        decode x = case fromJSON raw of Success e -> Right (x e); Error err -> Left (SchemaMismatch (judgmentField j <> ": " <> T.pack err))
    case judgmentKind j of JudgeBoolean {} -> decode FieldNoul; JudgeChoice {} -> decode FieldChoice; JudgeOrdered {} -> decode FieldScore
