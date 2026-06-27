{-# LANGUAGE ScopedTypeVariables #-}

-- | GEPA (EP-22): a reflective, evolutionary instruction optimizer. Where greedy
-- coordinate ascent is blind, GEPA is /reflective/: it runs the program while
-- capturing, per node, a short natural-language critique ("feedback") of how that
-- node performed, then reflects on those critiques to propose a rewritten
-- instruction. Where greedy search keeps one best program, GEPA keeps a __Pareto
-- frontier__ (see "Shikumi.Optimize.Pareto") of candidates none strictly worse than
-- another across the per-example score vector, samples a parent from it, mutates one
-- node by reflection, scores the child, and folds it back in — until a 'Budget' is
-- spent.
--
-- GEPA consumes EP-16's per-node feedback channel ('attachFeedback'/'feedbackFor'
-- keyed by 'NodePath', with node identity from 'programNodePaths') and EP-19's
-- summaries (here via small in-package fallbacks). The 'Trace'/'Feedback' effects are
-- discharged /internally/ (via 'runFeedback' against the ambient 'Prim'), so the
-- public 'Optimizer' row is unchanged (MasterPlan integration point #4/#5). Feedback
-- is attached at the program level to every node (the DSPy default and the M1
-- baseline); node-specific critique from per-node sub-traces is a documented deferral.
--
-- Output is V1's 'Shikumi.Compile.Types.CompiledProgram' via 'freezeProgram'; the
-- frontier is internal bookkeeping, not part of the returned type. GEPA reuses V1's
-- @Metric@/@Score@ plus a critique @Text@ (its 'FeedbackMetric') rather than a
-- parallel reward type (MasterPlan integration point #1).
module Shikumi.Optimize.GEPA
  ( FeedbackMetric,
    ReflectIn (..),
    ReflectOut (..),
    reflectiveProposer,
    captureFeedback,
    mutateNode,
    gepa,
  )
where

import Control.Lens ((&), (?~))
import Control.Monad (forM, forM_, when)
import Data.Generics.Labels ()
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Effectful (Eff, (:>))
import Effectful.Error.Static (Error)
import Effectful.Prim (Prim)
import GHC.Generics (Generic)
import Shikumi.Adapter (ToPrompt)
import Shikumi.Error (ShikumiError)
import Shikumi.Eval
  ( Dataset,
    Example (..),
    ExampleResult (..),
    Prediction,
    Report (..),
    Score,
    datasetExamples,
    datasetSize,
    evaluatePure,
    prediction,
    unScore,
  )
import Shikumi.LLM (LLM)
import Shikumi.Module (predict)
import Shikumi.Optimize.Pareto (Candidate (..), paretoFrontier, sampleParent)
import Shikumi.Optimize.Search (freezeProgram)
import Shikumi.Optimize.Types (Budget (..), Optimizer (..))
import Shikumi.Program
  ( NodeFields (..),
    Params (..),
    Program,
    foldParams,
    mapParamsAt,
    nodeFieldsIndexed,
    runProgram,
    setProgramParams,
  )
import Shikumi.Schema (FromModel, ToSchema, Validatable)
import Shikumi.Signature (mkSignature)
import Shikumi.Trace.Feedback (FeedbackLog, attachFeedback, feedbackFor, runFeedback)
import Shikumi.Trace.Node (NodePath, programNodePaths)

-- | A feedback metric: like V1's @Metric@ but also emits a short critique. Reuses
-- @Score@ (EP-18's reward vocabulary reduces to this) plus a critique @Text@.
type FeedbackMetric o = o -> Prediction o -> (Score, Text)

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

-- | Run the program over the whole dataset, attaching the feedback metric's critique
-- (when non-empty) to every node keyed by its 'NodePath', and returning the
-- 'FeedbackLog' alongside the per-example score vector (for the Pareto frontier).
captureFeedback ::
  (LLM :> es, Error ShikumiError :> es, Prim :> es) =>
  Dataset i o ->
  FeedbackMetric o ->
  Program i o ->
  Eff es (FeedbackLog, [Double])
captureFeedback ds fm prog = do
  let paths = programNodePaths prog
  (scores, fblog) <-
    runFeedback $
      forM (datasetExamples ds) $ \(Example inp expd) -> do
        out <- runProgram prog inp
        let (sc, crit) = fm expd (prediction out)
        when (not (T.null crit)) (forM_ paths (\p -> attachFeedback p crit))
        pure (unScore sc)
  pure (fblog, scores)

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
              let cur = fromMaybe "" (instructionOverride (paramsAt idx prog))
                  fldSummary = renderFields (drop idx fields)
                  fb = T.intercalate "\n" crits
              ReflectOut newInstr <-
                runProgram proposer (ReflectIn cur fb progSummary dataSummary fldSummary)
              pure (mapParamsAt idx (\ps -> ps & #instructionOverride ?~ newInstr) prog)

-- | The 'Params' at a node index (empty if out of range).
paramsAt :: Int -> Program i o -> Params
paramsAt idx prog = case drop idx (foldParams prog) of
  (ps : _) -> ps
  [] -> Params Nothing []

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
-- 'Optimizer'.
gepa ::
  Program ReflectIn ReflectOut ->
  FeedbackMetric o ->
  Budget ->
  Optimizer i o
gepa proposer fbMetric budget = Optimizer $ \train metric student -> do
  let paths = programNodePaths student
      fields = nodeFieldsIndexed student
      nNodes = max 1 (length paths)
      n = max 1 (datasetSize train)
      progSummary = fallbackProgramSummary (length paths)
      dataSummary = fallbackDatasetSummary (datasetSize train)
      maxCalls = maxLmCalls budget
      maxCands = maxCandidates budget
      rebuild cand = either (const student) id (setProgramParams (params cand) student)

  seedRpt <- evaluatePure train metric student
  let seedCand = Candidate (foldParams student) (perEx seedRpt) (aggregateScore seedRpt)

      -- A full step costs: capture (n) + mutate (1) + child eval (n) = 2n + 1.
      stepCost = 2 * n + 1
      stepCap = maxCands + 4

      loop step calls cands seed frontier
        | step >= stepCap = pure (bestOf seedCand frontier)
        | calls + stepCost > maxCalls = pure (bestOf seedCand frontier)
        | length cands >= maxCands = pure (bestOf seedCand frontier)
        | otherwise = case sampleParent seed (paretoFrontier frontier) of
            Nothing -> pure (bestOf seedCand frontier)
            Just (parent, seed') -> do
              let parentProg = rebuild parent
                  idx = step `mod` nNodes
              (fblog, _) <- captureFeedback train fbMetric parentProg
              case drop idx paths of
                (path : _)
                  | null (feedbackFor path fblog) ->
                      -- nothing to reflect on at this node; advance (capture cost only)
                      loop (step + 1) (calls + n) cands seed' frontier
                _ -> do
                  child <- mutateNode proposer progSummary dataSummary fields fblog paths idx parentProg
                  rpt <- evaluatePure train metric child
                  let childCand = Candidate (foldParams child) (perEx rpt) (aggregateScore rpt)
                      frontier' = paretoFrontier (childCand : frontier)
                  loop (step + 1) (calls + stepCost) (childCand : cands) seed' frontier'

  best <- loop 0 n [seedCand] 1 [seedCand]
  pure (freezeProgram (rebuild best))

-- | The per-example score vector from a report, in dataset order.
perEx :: Report -> [Double]
perEx rpt = [unScore s | ExampleResult {score = s} <- results rpt]

-- | The frontier candidate with the highest aggregate (earliest on ties); falls back
-- to the seed if the frontier is somehow empty.
bestOf :: Candidate -> [Candidate] -> Candidate
bestOf seedCand cs = case cs of
  [] -> seedCand
  (x : xs) -> foldl' (\b c -> if aggregate c > aggregate b then c else b) x xs

-- | A minimal program summary (EP-19's program describer is the richer source).
fallbackProgramSummary :: Int -> Text
fallbackProgramSummary k = "A language-model program with " <> tshow k <> " predict node(s)."

-- | A minimal dataset summary (EP-19's dataset summarizer is the richer source).
fallbackDatasetSummary :: Int -> Text
fallbackDatasetSummary k = "A dataset of " <> tshow k <> " example(s)."

tshow :: (Show a) => a -> Text
tshow = T.pack . show
