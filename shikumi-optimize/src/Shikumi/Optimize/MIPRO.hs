{-# LANGUAGE ScopedTypeVariables #-}

-- | MIPROv2 (EP-20): the joint instruction-and-demonstration optimizer. Where
-- 'Shikumi.Optimize.Instruction.instructionSearch' improves one axis (instructions)
-- one node at a time, MIPROv2 searches /both/ axes — instruction × demo set — across
-- all nodes jointly, in three phases:
--
--   1. __bootstrap__ candidate demo sets (per node) from the teacher's passing runs
--      plus the labelled training pairs ('bootstrapDemoCandidates');
--   2. __propose__ candidate instructions (per node) through EP-19's grounded
--      proposer ('proposeInstructionCandidates'); and
--   3. __search__ the joint @(instruction × demoset)@ grid with cheap minibatch
--      trials gated by periodic full evaluation ('searchJoint').
--
-- The result is V1's 'Shikumi.Compile.Types.CompiledProgram', produced via
-- 'freezeProgram', invoked through V1's 'Shikumi.Optimize.optimize' and persisted
-- with V1's serialization — no parallel optimizer or persistence surface (MasterPlan
-- integration point #4).
--
-- __Search surrogate.__ DSPy drives phase 3 with Optuna's TPE sampler, which has no
-- Haskell equivalent in this workspace. We implement __greedy coordinate descent with
-- minibatch pruning__ over the joint grid: each trial screens the one-coordinate
-- neighbours of the running best on a seeded minibatch, then full-evaluates the
-- best-screened neighbour and accepts it only if it strictly improves the full score.
-- This keeps the three essential, testable behaviours — joint grid, minibatch-screen
-- + full-eval-confirm, and a hard 'Budget' — while staying fully deterministic. A
-- later EP can swap the neighbour-selection step for a TPE-lite without changing this
-- module's public surface.
module Shikumi.Optimize.MIPRO
  ( -- * Public surface
    Miprov2Auto (..),
    Miprov2Config (..),
    miprov2Auto,
    miprov2,
    miprov2With,

    -- * Phases (exported for tests)
    bootstrapDemoCandidates,
    proposeInstructionCandidates,
    searchJoint,
  )
where

import Control.Monad (forM)
import Data.Aeson (ToJSON)
import Data.Aeson.Text (encodeToLazyText)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text.Lazy qualified as TL
import Effectful (Eff, (:>))
import Effectful.Concurrent (Concurrent)
import Effectful.Error.Static (Error, catchError)
import Effectful.Prim (Prim)
import GHC.Generics (Generic)
import Shikumi.Effect.Time (Time)
import Shikumi.Error (ShikumiError)
import Shikumi.Eval
  ( Dataset,
    Example (..),
    Metric,
    dataset,
    datasetExamples,
    datasetSize,
    prediction,
    unScore,
  )
import Shikumi.LLM (LLM)
import Shikumi.Optimize.Bootstrap (recoverDemo)
import Shikumi.Optimize.Propose
  ( ProposeRequest (..),
    ProposeResult (..),
    proposeInstructions,
  )
import Shikumi.Optimize.Search (freezeProgram, scoreOn)
import Shikumi.Optimize.Types (Budget (..), Optimizer (..), defaultBudget)
import Shikumi.Program
  ( Demo (..),
    Params (..),
    Program,
    foldParams,
    mapParamsAt,
    runProgram,
  )

-- ---------------------------------------------------------------------------
-- Configuration and presets
-- ---------------------------------------------------------------------------

-- | How aggressively to search. Mirrors DSPy's light/medium/heavy "auto" modes.
data Miprov2Auto = Miprov2Light | Miprov2Medium | Miprov2Heavy
  deriving stock (Eq, Show)

-- | The full, explicit configuration. Presets fill it in; advanced users build one
-- directly.
data Miprov2Config = Miprov2Config
  { -- | instruction candidates proposed per node (incl. the current at index 0)
    numInstructCandidates :: !Int,
    -- | demo-set candidates per node (incl. the empty set at index 0)
    numDemoCandidates :: !Int,
    -- | minibatch trials the search performs
    numTrials :: !Int,
    -- | examples per minibatch screening evaluation
    minibatchSize :: !Int,
    -- | run a full eval of a trial's proposal every k trials (also retained for
    -- config compatibility; the implementation full-evaluates each trial's single
    -- proposal to gate acceptance — see the module header)
    fullEvalEvery :: !Int,
    -- | cap on demos in one bootstrapped set (prompt-size guard)
    maxBootstrappedDemos :: !Int,
    -- | min metric score for a teacher run to contribute demos
    bootstrapThreshold :: !Double,
    -- | hard LM-call / candidate ceiling (V1's 'Budget')
    budget :: !Budget
  }
  deriving stock (Eq, Show, Generic)

-- | Turn a preset into a concrete config. Values are small enough for hermetic tests
-- yet keep DSPy's monotonic ordering (heavier => more candidates, more trials).
miprov2Auto :: Miprov2Auto -> Miprov2Config
miprov2Auto Miprov2Light = Miprov2Config 2 2 6 3 3 4 1.0 defaultBudget
miprov2Auto Miprov2Medium = Miprov2Config 3 3 12 5 4 4 1.0 defaultBudget
miprov2Auto Miprov2Heavy = Miprov2Config 4 4 18 8 5 4 1.0 defaultBudget

-- ---------------------------------------------------------------------------
-- Public optimizers
-- ---------------------------------------------------------------------------

-- | MIPROv2 with a preset. The teacher (whose successful runs seed bootstrapped
-- demos) defaults to the student itself, matching DSPy's default.
miprov2 :: (ToJSON i, ToJSON o) => Miprov2Auto -> Optimizer i o
miprov2 a = Optimizer $ \train metric student ->
  runOptimizer (miprov2With (miprov2Auto a) student) train metric student

-- | MIPROv2 with an explicit config and an explicit teacher program.
miprov2With :: (ToJSON i, ToJSON o) => Miprov2Config -> Program i o -> Optimizer i o
miprov2With cfg teacher = Optimizer $ \train metric student -> do
  demoCands <- bootstrapDemoCandidates cfg teacher train metric student
  instrCands <- proposeInstructionCandidates cfg student train demoCands
  best <- searchJoint cfg train metric student instrCands demoCands
  pure (freezeProgram best)

-- ---------------------------------------------------------------------------
-- Phase 1 — bootstrap demo-set candidates
-- ---------------------------------------------------------------------------

-- | For each node (in @foldParams@ order), a list of candidate demo sets. Candidate
-- 0 is always the empty set (so "no demos" is always reachable). The remaining sets
-- come from the teacher's metric-passing runs (bootstrapped) and from the labelled
-- training pairs (labelled demos, DSPy's @max_labeled_demos@) — recovered at the
-- program-I/O level and attached to every node (the documented degradation while
-- per-node trace recovery via EP-16 is deferred; for single-node programs the two
-- coincide).
bootstrapDemoCandidates ::
  (ToJSON i, ToJSON o, LLM :> es, Error ShikumiError :> es) =>
  Miprov2Config ->
  -- | teacher
  Program i o ->
  Dataset i o ->
  Metric o ->
  -- | student (for the node count)
  Program i o ->
  Eff es [[[Demo]]]
bootstrapDemoCandidates cfg teacher train metric student = do
  let exs = datasetExamples train
      keepIfPassing (Example inp expd) =
        ( do
            out <- runProgram teacher inp
            let s = unScore (metric expd (prediction out))
            pure [recoverDemo inp out | s >= bootstrapThreshold cfg]
        )
          `catchError` \_ (_ :: ShikumiError) -> pure []
  bootstrapped <- concat <$> mapM keepIfPassing exs
  let cap = max 1 (maxBootstrappedDemos cfg)
      labeledSet = take cap (map (\(Example i o) -> recoverDemo i o) exs)
      bootSet = take cap bootstrapped
      sets = take (max 1 (numDemoCandidates cfg)) ([] : filter (not . null) [labeledSet, bootSet])
      nNodes = length (foldParams student)
  pure (replicate nNodes sets)

-- ---------------------------------------------------------------------------
-- Phase 2 — propose instruction candidates
-- ---------------------------------------------------------------------------

-- | For each node (in @foldParams@ order), a list of candidate instructions with the
-- node's current instruction first (the grounded proposer guarantees retention).
-- Uses EP-19's 'proposeInstructions'; the per-candidate tip starts at the /creative/
-- tip (@tipIndex = 1@) so a node always gets a strong proposal even at small N.
proposeInstructionCandidates ::
  (ToJSON i, ToJSON o, LLM :> es, Error ShikumiError :> es) =>
  Miprov2Config ->
  Program i o ->
  Dataset i o ->
  [[[Demo]]] ->
  Eff es [[Text]]
proposeInstructionCandidates cfg student train demoCands =
  forM (zip3 [0 ..] (foldParams student) demoCands) $ \(k, ps, nodeDemoSets) -> do
    let curInstr = fromMaybe "" (instructionOverride ps)
        demoTexts = map renderDemo (concat (take 1 (filter (not . null) nodeDemoSets)))
    ProposeResult cs <-
      proposeInstructions
        train
        ProposeRequest
          { program = student,
            targetNode = k,
            currentInstruction = curInstr,
            history = [],
            bootstrappedDemos = demoTexts,
            numCandidates = max 0 (numInstructCandidates cfg - 1),
            tipIndex = 1,
            viewBatch = 2
          }
    pure cs

-- | Render a recovered 'Demo' as @<input-json> => <output-json>@ for the proposal
-- prompt's demo signal.
renderDemo :: Demo -> Text
renderDemo (Demo i o) = enc i <> " => " <> enc o
  where
    enc = TL.toStrict . encodeToLazyText

-- ---------------------------------------------------------------------------
-- Phase 3 — the joint minibatch search
-- ---------------------------------------------------------------------------

-- | A per-node selection: @(instructionIndex, demoSetIndex)@.
type JointVec = [(Int, Int)]

-- | Search the joint per-node @(instruction × demoset)@ grid by greedy coordinate
-- descent with minibatch screening, returning the best program found within the
-- 'Budget'. Each trial screens the one-coordinate neighbours of the running best on a
-- seeded minibatch, then full-evaluates the best-screened neighbour and accepts it
-- only if it strictly improves the full score.
searchJoint ::
  (LLM :> es, Concurrent :> es, Error ShikumiError :> es, Time :> es, Prim :> es) =>
  Miprov2Config ->
  Dataset i o ->
  Metric o ->
  Program i o ->
  -- | per-node instruction candidates
  [[Text]] ->
  -- | per-node demo-set candidates
  [[[Demo]]] ->
  Eff es (Program i o)
searchJoint cfg train metric student instrCands demoCands = do
  let nNodes = length (foldParams student)
      dsSize = datasetSize train
      mbSize = max 1 (min dsSize (minibatchSize cfg))
      maxCalls = maxLmCalls (budget cfg)
      apply = applyVec instrCands demoCands student
      baseVec = replicate nNodes (0, 0)
  if dsSize > maxCalls
    then pure (apply baseVec)
    else do
      baseFull <- scoreOn train metric (apply baseVec)
      let screen _t calls acc [] = pure (reverse acc, calls)
          screen t calls acc (v : vs)
            | calls + mbSize > maxCalls = pure (reverse acc, calls)
            | otherwise = do
                s <- scoreOn (minibatchAt mbSize (t * 7 + length acc) train) metric (apply v)
                screen t (calls + mbSize) ((v, s) : acc) vs
          go t calls bestVec bestFull
            | t >= numTrials cfg = pure bestVec
            | otherwise = do
                (scored, calls1) <- screen t calls [] (oneCoordNeighbors instrCands demoCands bestVec)
                case bestByScore scored of
                  Nothing -> pure bestVec
                  Just propVec
                    | calls1 + dsSize > maxCalls -> pure bestVec
                    | otherwise -> do
                        fs <- scoreOn train metric (apply propVec)
                        if fs > bestFull
                          then go (t + 1) (calls1 + dsSize) propVec fs
                          else go (t + 1) (calls1 + dsSize) bestVec bestFull
      best <- go 0 dsSize baseVec baseFull
      pure (apply best)

-- | Apply a joint vector to the student: set each node's instruction and demos to the
-- selected candidates.
applyVec :: [[Text]] -> [[[Demo]]] -> Program i o -> JointVec -> Program i o
applyVec instrCands demoCands prog vec = foldl step prog (zip [0 ..] vec)
  where
    step p (k, (i, d)) =
      mapParamsAt
        k
        ( \ps ->
            ps
              { instructionOverride = Just (instrCands !! k !! i),
                demos = demoCands !! k !! d
              }
        )
        p

-- | The one-coordinate neighbours of a vector: each move changes exactly one node's
-- instruction or demo index to a non-current alternative.
oneCoordNeighbors :: [[Text]] -> [[[Demo]]] -> JointVec -> [JointVec]
oneCoordNeighbors instrCands demoCands vec =
  [setAt k (i, snd (vec !! k)) vec | k <- nodes, i <- idxs (instrCands !! k), i /= fst (vec !! k)]
    ++ [setAt k (fst (vec !! k), d) vec | k <- nodes, d <- idxs (demoCands !! k), d /= snd (vec !! k)]
  where
    nodes = [0 .. length vec - 1]
    idxs xs = [0 .. length xs - 1]
    setAt k v xs = take k xs ++ [v] ++ drop (k + 1) xs

-- | The vector with the strictly-highest score (earliest on ties); 'Nothing' if none.
bestByScore :: [(JointVec, Double)] -> Maybe JointVec
bestByScore [] = Nothing
bestByScore (x : xs) = Just (fst (foldl (\b c -> if snd c > snd b then c else b) x xs))

-- | A deterministic minibatch of @sz@ examples, rotated by @seed@ (a seeded sample is
-- as reproducible as the whole set, and far cheaper to screen on).
minibatchAt :: Int -> Int -> Dataset i o -> Dataset i o
minibatchAt sz seed ds =
  let exs = datasetExamples ds
      n = length exs
   in if n == 0 then ds else dataset (take (max 1 sz) (drop (seed `mod` n) (cycle exs)))
