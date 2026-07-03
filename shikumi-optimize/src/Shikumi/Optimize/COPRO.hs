-- | COPRO (EP-21): coordinate-ascent prompt optimization. Where
-- 'Shikumi.Optimize.Instruction.instructionSearch' is one-shot per node, COPRO
-- improves each node's instruction over several /rounds/ (depth), proposing several
-- candidates per round (breadth) and feeding the /scored attempt history/ forward so
-- later rounds learn from what scored well. It is the principled generalization of
-- @instructionSearch@ (depth-1, no-history COPRO ≈ @instructionSearch@), kept
-- alongside it rather than replacing it.
--
-- COPRO consumes EP-19's grounded proposer ('Shikumi.Optimize.Propose.proposeInstructions')
-- directly: each round's call passes the node's current instruction and its scored
-- 'PastInstruction' history, and the proposer returns ranked candidates with the
-- current effective instruction always retained. Keeping that candidate writes no
-- redundant override, preserving the safety property that a node never degrades.
--
-- Output is V1's 'Shikumi.Compile.Types.CompiledProgram' via 'freezeProgram', invoked
-- through 'Shikumi.Optimize.optimize' and serialized unchanged (integration point #4).
module Shikumi.Optimize.COPRO
  ( CoproConfig (..),
    defaultCoproConfig,
    copro,
  )
where

import Control.Monad (foldM)
import Data.Aeson (ToJSON)
import Effectful (Eff, (:>))
import Effectful.Concurrent (Concurrent)
import Effectful.Error.Static (Error)
import Effectful.Prim (Prim)
import GHC.Generics (Generic)
import Shikumi.Effect.Time (Time)
import Shikumi.Error (ShikumiError)
import Shikumi.Eval (Dataset, Metric, datasetSize)
import Shikumi.LLM (LLM)
import Shikumi.Optimize.Propose
  ( PastInstruction (..),
    ProposeRequest (..),
    ProposeResult (..),
    proposeInstructions,
  )
import Shikumi.Optimize.Search (effectiveInstructionAt, freezeProgram, scoreOn, setNodeInstrIfNew)
import Shikumi.Optimize.Types (Budget (..), Optimizer (..), defaultBudget)
import Shikumi.Program (Program, foldParams)

-- | COPRO's two knobs plus the shared 'Budget'.
data CoproConfig = CoproConfig
  { -- | candidate instructions generated per node per round (clamped to @>= 2@)
    breadth :: !Int,
    -- | number of coordinate-ascent rounds (clamped to @>= 1@)
    depth :: !Int,
    -- | LM-call / candidate ceilings
    budget :: !Budget
  }
  deriving stock (Eq, Show, Generic)

-- | Breadth 4, depth 3, the default budget.
defaultCoproConfig :: CoproConfig
defaultCoproConfig = CoproConfig {breadth = 4, depth = 3, budget = defaultBudget}

-- | Coordinate-ascent instruction optimization. Visits each node in @foldParams@
-- order, optimizing it over @depth@ rounds against the already-improved earlier
-- nodes, threading one running LM-call count so the 'Budget' bounds the whole search.
copro :: (ToJSON i, ToJSON o) => CoproConfig -> Optimizer i o
copro cfg = Optimizer $ \train metric student -> do
  let nNodes = length (foldParams student)
  (final, _calls) <-
    foldM
      (\acc idx -> optimizeNode cfg train metric idx acc)
      (student, 0)
      [0 .. nNodes - 1]
  pure (freezeProgram final)

-- | Optimize node @idx@ over @depth@ rounds. Returns the program with node @idx@ set
-- to its best-found instruction, plus the updated LM-call count. Each round proposes
-- @breadth - 1@ fresh candidates (plus the retained current instruction) via the
-- grounded proposer fed the scored attempt history, scores the not-yet-seen ones on
-- the whole training set, records @(instruction, best-score)@, and sets the node to
-- the best so far. Every spend is gated against the 'Budget'.
optimizeNode ::
  (ToJSON i, ToJSON o, LLM :> es, Concurrent :> es, Error ShikumiError :> es, Time :> es, Prim :> es) =>
  CoproConfig ->
  Dataset i o ->
  Metric o ->
  Int ->
  (Program i o, Int) ->
  Eff es (Program i o, Int)
optimizeNode cfg train metric idx (prog0, calls0) = goRound 1 prog0 calls0 []
  where
    dsSize = datasetSize train
    bdth = max 2 (breadth cfg)
    dpth = max 1 (depth cfg)
    proposerCost = 4 + (bdth - 1)
    maxCalls = maxLmCalls (budget cfg)
    maxCands = maxCandidates (budget cfg)

    goRound r prog calls evald
      | r > dpth = pure (setBest prog evald, calls)
      | otherwise = do
          let cur = effectiveInstructionAt idx prog
              hist = [PastInstruction i s | (i, s) <- evald]
          (cands, calls1) <-
            if calls + proposerCost <= maxCalls
              then do
                ProposeResult cs <-
                  proposeInstructions
                    train
                    ProposeRequest
                      { program = prog,
                        targetNode = idx,
                        currentInstruction = cur,
                        history = hist,
                        bootstrappedDemos = [],
                        numCandidates = bdth - 1,
                        tipIndex = 1,
                        viewBatch = 2
                      }
                pure (cs, calls + proposerCost)
              else pure ([cur], calls)
          (evald', calls2) <- scoreNew prog calls1 evald (dedupNew evald cands)
          -- set the node to the best instruction found so far, then continue
          let prog' = setBest prog evald'
          goRound (r + 1) prog' calls2 evald'

    -- Score the not-yet-evaluated candidates, threading the call count and stopping
    -- before either Budget ceiling would be exceeded.
    scoreNew _ calls evald [] = pure (evald, calls)
    scoreNew prog calls evald (c : cs)
      | calls + dsSize > maxCalls = pure (evald, calls)
      | length evald >= maxCands = pure (evald, calls)
      | otherwise = do
          s <- scoreOn train metric (setNodeInstrIfNew idx c prog)
          scoreNew prog (calls + dsSize) (evald ++ [(c, s)]) cs

    -- Candidates not already scored, de-duplicated against each other (order-preserving).
    dedupNew evald = go (map fst evald)
      where
        go _ [] = []
        go seen (x : xs)
          | x `elem` seen = go seen xs
          | otherwise = x : go (x : seen) xs

    -- Set node idx to the highest-scoring instruction recorded (earliest on ties).
    setBest prog evald = case evald of
      [] -> prog
      (e : es) -> setNodeInstrIfNew idx (fst (foldl' pick e es)) prog
      where
        pick best c = if snd c > snd best then c else best
