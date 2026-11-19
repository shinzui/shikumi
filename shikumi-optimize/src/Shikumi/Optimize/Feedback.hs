-- | Indexed execution evidence and explicitly attributed, bounded feedback.
module Shikumi.Optimize.Feedback
  ( FeedbackMetric,
    EvidenceMetric,
    EvaluationEvidence (..),
    NodeFeedback (..),
    Provenance (..),
    StoredCritique (..),
    storedCritiqueFeedback,
    FeedbackResult (..),
    FeedbackConfig (..),
    defaultFeedbackConfig,
    candidateFailurePolicy,
    legacyFeedback,
    validateFeedback,
    validateFeedbackConfig,
    boundText,
    captureEvidence,
  )
where

import Control.Monad (forM, unless)
import Data.Text (Text)
import Data.Text qualified as T
import Effectful (Eff, (:>))
import Effectful.Error.Static (Error, throwError)
import Effectful.Prim (Prim)
import Shikumi.Error (ShikumiError (..))
import Shikumi.Eval (Dataset, Example (..), Metric, Prediction, Score, datasetExamples, prediction, scoreZero)
import Shikumi.Eval.Evaluate (scoreExecution, tryShikumi)
import Shikumi.Eval.Report (FailurePolicy (..), FailureReason (..), UsageTotals)
import Shikumi.Eval.Usage (withUsageTotals)
import Shikumi.LLM (LLM)
import Shikumi.Program (Program)
import Shikumi.Trace.Node (NodePath, programNodePaths)
import Shikumi.Trace.Observation (NodeObservation (..), runProgramObserved)

type FeedbackMetric o = o -> Prediction o -> (Score, Text)

type EvidenceMetric es o = o -> EvaluationEvidence o -> Eff es FeedbackResult

data EvaluationEvidence o = EvaluationEvidence
  { exampleIndex :: !Int,
    executionResult :: !(Either ShikumiError o),
    observations :: ![NodeObservation],
    executionUsage :: !UsageTotals
  }
  deriving stock (Eq, Show)

-- | Who produced a critique. 'Human' and 'Inferred' label stored production
-- evidence: an adjudication by a person, and a critique derived from an
-- operational outcome rather than written by anyone. None of the values implies
-- human approval of a candidate (ADR-4).
data Provenance = Caller | Model | LegacyProgram | Human | Inferred deriving stock (Eq, Show)

-- | A critique stored with an example in a dataset rather than computed by a
-- callback. It is keyed by the example's stable identifier, so it survives
-- reordering, and it keeps the provenance of whoever produced it. A critique with
-- no node is program-scoped.
data StoredCritique = StoredCritique
  { critiqueExampleId :: !Text,
    critiqueNode :: !(Maybe NodePath),
    critiqueText :: !Text,
    critiqueProvenance :: !Provenance,
    critiqueAuthor :: !Text
  }
  deriving stock (Eq, Show)

data NodeFeedback = NodeFeedback
  { feedbackExample :: !Int,
    feedbackPath :: !NodePath,
    feedbackInvocation :: !(Maybe Int),
    critique :: !Text,
    provenance :: !Provenance
  }
  deriving stock (Eq, Show)

data FeedbackResult = FeedbackResult
  { overallScore :: !Score,
    programCritique :: !(Maybe (Provenance, Text)),
    nodeCritiques :: ![NodeFeedback]
  }
  deriving stock (Eq, Show)

-- | Redaction runs on the entire rendered reflection payload before truncation.
-- It does not erase the raw evidence returned to the caller.
data FeedbackConfig = FeedbackConfig
  { critiqueCharacters :: !Int,
    reflectionExamples :: !Int,
    reflectionCharacters :: !Int,
    includeProgramCritique :: !Bool,
    redactEvidence :: Text -> Text,
    failureClassification :: ShikumiError -> FailurePolicy
  }

defaultFeedbackConfig :: FeedbackConfig
defaultFeedbackConfig = FeedbackConfig 2000 4 8000 False id (candidateFailurePolicy scoreZero)

-- | Only candidate/output errors are scored by default. Budget exhaustion always
-- escapes, even when a caller supplies a broader classifier.
candidateFailurePolicy :: Score -> ShikumiError -> FailurePolicy
candidateFailurePolicy s = \case
  InvalidJSON {} -> FailScore s
  MissingField {} -> FailScore s
  SchemaMismatch {} -> FailScore s
  ValidationFailure {} -> FailScore s
  _ -> FailAbort

-- | Legacy critiques remain program-scoped, including for single predictors.
legacyFeedback :: (Applicative m) => FeedbackMetric o -> o -> EvaluationEvidence o -> m FeedbackResult
legacyFeedback metric expected ev = pure $ case executionResult ev of
  Left _ -> FeedbackResult scoreZero Nothing []
  Right out ->
    let (s, t) = metric expected (prediction out)
     in FeedbackResult s (if T.null t then Nothing else Just (LegacyProgram, t)) []

-- | A feedback callback over critiques stored with the examples.
--
-- The first argument lists the stable example identifiers in the order of the
-- dataset being captured, so the example at position @n@ has identifier @n@ of
-- the list. Each example is scored with the metric (zero when execution failed).
-- Every stored node critique for the example whose node executed in this run is
-- attached with its provenance; a critique for a node that did not execute is
-- dropped rather than rejected, because production evidence may name a node a
-- failing rerun never reached. The example's program-scoped critique, at most
-- one, fills 'programCritique' and is rendered only when
-- 'includeProgramCritique' is set. Critiques still attach when execution failed,
-- and positions beyond the identifier list attach nothing. The result passes
-- through 'validateFeedback' like any other callback, so the bounds and
-- redaction of 'FeedbackConfig' apply unchanged.
storedCritiqueFeedback ::
  (Applicative m) => [Text] -> [StoredCritique] -> Metric o -> o -> EvaluationEvidence o -> m FeedbackResult
storedCritiqueFeedback ids stored metric expected ev =
  pure (FeedbackResult score programScoped nodeScoped)
  where
    score = either (const scoreZero) (metric expected . prediction) (executionResult ev)
    ix = exampleIndex ev
    mine = case drop ix ids of
      (ident : _) | ix >= 0 -> [c | c <- stored, critiqueExampleId c == ident]
      _ -> []
    executed path = any (\obs -> observationPath obs == path && not (observationOpaque obs)) (observations ev)
    nodeScoped =
      [ NodeFeedback ix path Nothing (critiqueText c) (critiqueProvenance c)
      | c <- mine,
        Just path <- [critiqueNode c],
        executed path
      ]
    programScoped = case [c | c <- mine, critiqueNode c == Nothing] of
      (c : _) -> Just (critiqueProvenance c, critiqueText c)
      [] -> Nothing

validateFeedbackConfig :: FeedbackConfig -> Either ShikumiError ()
validateFeedbackConfig cfg =
  unless
    (all (>= 0) [critiqueCharacters cfg, reflectionExamples cfg, reflectionCharacters cfg])
    (Left (ValidationFailure "feedback: character and example bounds must be nonnegative"))

-- | Unicode-safe prefix with an in-budget truncation marker, including odd/zero limits.
boundText :: Int -> Text -> Text
boundText n t
  | n <= 0 = ""
  | T.length t <= n = t
  | otherwise = T.take (n - 1) t <> "…"

validateFeedback :: FeedbackConfig -> [NodePath] -> EvaluationEvidence o -> FeedbackResult -> Either ShikumiError FeedbackResult
validateFeedback cfg paths ev result = do
  validateFeedbackConfig cfg
  critiques <- forM (nodeCritiques result) $ \fb -> do
    unless
      (feedbackExample fb == exampleIndex ev && feedbackPath fb `elem` paths && any (matches fb) (observations ev))
      (Left (ValidationFailure ("feedback: target was not executed in example " <> T.pack (show (exampleIndex ev)) <> ": " <> T.pack (show fb))))
    unless
      (provenance fb /= LegacyProgram)
      (Left (ValidationFailure "feedback: LegacyProgram cannot assert node attribution"))
    pure fb {critique = boundText (critiqueCharacters cfg) (critique fb)}
  pure result {nodeCritiques = critiques, programCritique = fmap (\(p, t) -> (p, boundText (critiqueCharacters cfg) t)) (programCritique result)}
  where
    matches fb obs =
      not (observationOpaque obs)
        && observationPath obs == feedbackPath fb
        && maybe True (== observationInvocation obs) (feedbackInvocation fb)

-- | Sequential, position-stable capture. Each envelope retains the original root
-- error and retry lineage. Metric errors are separately identified; configuration
-- errors escape. Host exceptions (including cancellation) are never intercepted.
captureEvidence ::
  (LLM :> es, Error ShikumiError :> es, Prim :> es) =>
  FeedbackConfig ->
  Dataset i o ->
  EvidenceMetric es o ->
  Program i o ->
  Eff es [(EvaluationEvidence o, FeedbackResult, Maybe FailureReason)]
captureEvidence cfg ds metric prog = do
  either throwError pure (validateFeedbackConfig cfg)
  forM (zip [0 ..] (datasetExamples ds)) $ \(ix, Example inp expected) -> do
    ((out, obs), usage) <- withUsageTotals (runProgramObserved prog inp)
    let ev = EvaluationEvidence ix out obs usage
        policy BudgetExceeded {} = FailAbort
        policy e = failureClassification cfg e
    (_, (rootScore, rootFailure)) <- scoreExecution policy executionResult (pure ev) (const (pure scoreZero))
    -- Keep the full feedback value while reusing the evaluator's metric boundary.
    (judged, (metricScore, metricFailure)) <-
      scoreExecution
        policy
        id
        (tryShikumi (metric expected ev))
        (pure . overallScore)
    case judged of
      Left _ -> pure (ev, FeedbackResult metricScore Nothing [], fmap asMetric metricFailure)
      Right fb -> do
        valid <- either throwError pure (validateFeedback cfg (programNodePaths prog) ev fb)
        pure (ev, case out of Left _ -> valid {overallScore = rootScore}; Right _ -> valid, rootFailure)
  where
    asMetric (ProgramError t) = MetricError t
    asMetric reason = reason
