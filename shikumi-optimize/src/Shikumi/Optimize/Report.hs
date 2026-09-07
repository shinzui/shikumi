-- | Versioned diagnostic metadata. No prompts, examples or executable closures.
module Shikumi.Optimize.Report
  ( Direction (..),
    Aggregation (..),
    MissingPolicy (..),
    ObjectiveSpec (..),
    ObjectivePolicy (..),
    ObjectiveValues,
    qualityPolicy,
    validateObjectives,
    aggregateObjectives,
    objectiveFrontier,
    selectObjectiveWinner,
    RunStatus (..),
    CandidateStatus (..),
    CandidateReport (..),
    EventKind (..),
    OptimizationEvent (..),
    OptimizationReport (..),
  )
where

import Control.Monad (forM, unless)
import Data.Aeson (FromJSON (..), ToJSON, withObject, (.:))
import Data.List (minimumBy, nub, sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Ord (comparing)
import Data.Text (Text)
import GHC.Generics (Generic)

data Direction = Maximize | Minimize
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data Aggregation = Mean | Total | Worst
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data MissingPolicy = Required | Substitute Double
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data ObjectiveSpec = ObjectiveSpec
  { objectiveId :: !Text,
    unit :: !Text,
    direction :: !Direction,
    aggregation :: !Aggregation,
    missingPolicy :: !MissingPolicy,
    lowerBound :: !(Maybe Double),
    upperBound :: !(Maybe Double)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data ObjectivePolicy = ObjectivePolicy
  { objectives :: ![ObjectiveSpec],
    primaryObjective :: !Text,
    tieBreakObjectives :: ![Text]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

type ObjectiveValues = Map Text Double

qualityPolicy :: ObjectivePolicy
qualityPolicy = ObjectivePolicy [ObjectiveSpec "quality" "score" Maximize Mean Required (Just 0) (Just 1)] "quality" []

finite :: Double -> Bool
finite x = not (isNaN x || isInfinite x)

validateObjectives :: ObjectivePolicy -> Either Text ()
validateObjectives p = do
  let ids = map objectiveId (objectives p)
      ordered = primaryObjective p : tieBreakObjectives p
  unless (not (null ids) && all (/= "") ids && nub ids == ids) (Left "objectives must have distinct nonempty IDs")
  unless (all (`elem` ids) ordered && nub ordered == ordered) (Left "selection objectives must be declared and distinct")
  mapM_ check (objectives p)
  where
    check s = do
      unless (all finite (mapMaybe id [lowerBound s, upperBound s]) && case missingPolicy s of Required -> True; Substitute v -> finite v) (Left "objective configuration must be finite")
      unless (case (lowerBound s, upperBound s) of (Just l, Just u) -> l <= u; _ -> True) (Left "objective bounds are reversed")

aggregateObjectives :: ObjectivePolicy -> [ObjectiveValues] -> Either Text ObjectiveValues
aggregateObjectives p rows = do
  validateObjectives p
  unless (not (null rows)) (Left "no complete evaluation rows")
  unless (all (all finite . Map.elems) rows) (Left "non-finite objective value")
  Map.fromList
    <$> forM
      (objectives p)
      ( \s -> do
          xs <- forM rows $ \row -> case Map.lookup (objectiveId s) row of
            Just v -> Right v
            Nothing -> case missingPolicy s of Required -> Left "required objective missing"; Substitute v -> Right v
          let v = case aggregation s of
                Mean -> sum xs / fromIntegral (length xs)
                Total -> sum xs
                Worst -> (if direction s == Maximize then minimum else maximum) xs
          unless (finite v) (Left "non-finite objective aggregate")
          pure (objectiveId s, v)
      )

eligible :: ObjectivePolicy -> CandidateReport -> Bool
eligible p c = candidateStatus c == CandidateCompleted && all valid (objectives p)
  where
    valid s = case Map.lookup (objectiveId s) (objectiveValues c) of
      Nothing -> False
      Just v -> finite v && maybe True (v >=) (lowerBound s) && maybe True (v <=) (upperBound s)

objectiveFrontier :: ObjectivePolicy -> [CandidateReport] -> [CandidateReport]
objectiveFrontier p cs = filter (\c -> not (any (`dominates` c) valid)) valid
  where
    valid = sortOn candidateId (filter (eligible p) cs)
    oriented s c = (if direction s == Maximize then negate else id) (Map.findWithDefault 0 (objectiveId s) (objectiveValues c))
    dominates a b =
      let pairs = [(oriented s a, oriented s b) | s <- objectives p]
       in all (uncurry (<=)) pairs && any (uncurry (<)) pairs

selectObjectiveWinner :: ObjectivePolicy -> [CandidateReport] -> Maybe CandidateReport
selectObjectiveWinner p cs = case objectiveFrontier p cs of
  [] -> Nothing
  xs -> Just (minimumBy (comparing key) xs)
  where
    key c = ([value ident c | ident <- primaryObjective p : tieBreakObjectives p], candidateId c)
    value ident c =
      let v = Map.findWithDefault 0 ident (objectiveValues c)
       in if any (\s -> objectiveId s == ident && direction s == Maximize) (objectives p) then negate v else v

data RunStatus = Completed | BudgetStopped | Failed | Cancelled
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data CandidateStatus = Unscored | CandidateCompleted | CandidateFailed | CandidateIncomplete
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data CandidateReport = CandidateReport
  { candidateId :: !Int,
    candidateStatus :: !CandidateStatus,
    requiredExamples :: !Int,
    completedExamples :: !Int,
    exampleScores :: ![(Int, Double)],
    objectiveValues :: !ObjectiveValues,
    candidateOperations :: !Int,
    candidateReason :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data EventKind = RunStarted | CandidateStarted Int | CandidateEnded Int CandidateStatus | BudgetStop | RunFinished RunStatus
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data OptimizationEvent = OptimizationEvent {eventId :: !Int, eventKind :: !EventKind}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data OptimizationReport = OptimizationReport
  { reportVersion :: !Int,
    runStatus :: !RunStatus,
    admittedOperations :: !Int,
    predictedWork :: !Int,
    runControls :: !(Map Text Int),
    reportedPolicy :: !(Maybe ObjectivePolicy),
    candidates :: ![CandidateReport],
    unexecutedReservations :: ![Int],
    frontier :: ![Int],
    selectedCandidate :: !(Maybe Int),
    resultStatus :: !(Maybe CandidateStatus),
    selectionReason :: !Text,
    candidateDetailAvailable :: !Bool,
    validationMode :: !Text,
    observerFailures :: !Int,
    events :: ![OptimizationEvent]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

instance FromJSON OptimizationReport where
  parseJSON = withObject "OptimizationReport" $ \o -> do
    version <- o .: "reportVersion"
    unless (version == (1 :: Int)) (fail "unsupported optimization report version")
    OptimizationReport version
      <$> o .: "runStatus"
      <*> o .: "admittedOperations"
      <*> o .: "predictedWork"
      <*> o .: "runControls"
      <*> o .: "reportedPolicy"
      <*> o .: "candidates"
      <*> o .: "unexecutedReservations"
      <*> o .: "frontier"
      <*> o .: "selectedCandidate"
      <*> o .: "resultStatus"
      <*> o .: "selectionReason"
      <*> o .: "candidateDetailAvailable"
      <*> o .: "validationMode"
      <*> o .: "observerFailures"
      <*> o .: "events"
