-- | M3 — instruction search (a MIPRO/COPRO-style optimizer). For each node, the
-- /grounded/ proposer (EP-19, 'Shikumi.Optimize.Propose.proposeInstructions') suggests
-- several candidate instruction strings — fed a dataset summary, the program's
-- pseudo-code and description, the node's real input/output field names, the
-- instruction history, and a stylistic tip — and each candidate is scored; the best is
-- kept. Optimization is greedy coordinate ascent — one node at a time, holding the
-- others fixed — so the candidate count is linear in @nodes × proposals@.
--
-- The proposer and its signal-gatherers are themselves ordinary shikumi 'Program's, so
-- they are typed, cached, traced, and testable with the same stub-LM machinery as
-- everything else — the optimizer is written in the framework it optimizes. The
-- /current/ instruction is always retained as a candidate (the proposer guarantees it),
-- so a node can never end up worse than where it started.
--
-- __Budget.__ The grounded proposer makes @4 + proposalsPerNode@ LM calls per node
-- (dataset summary, program describe, module describe, and one generation per proposal);
-- scoring one candidate costs one LM call per dataset example. The search threads a
-- running raw-call count and stops — returning the best found /so far/ — before either
-- bound in the 'Budget' would be exceeded, so the recorded LM-call count never exceeds
-- @maxLmCalls@. When the remaining budget cannot cover a node's full proposal, that node
-- keeps its current instruction (no proposer call) rather than partially proposing.
--
-- This module re-points V1's blind proposer at EP-19's grounded surface; the old
-- @ProposeIn@/@ProposeOut@/@proposeInstruction@ predictor is removed (the grounded
-- @GenerateInstructionIn@/@GenerateInstructionOut@ replaces it, still emitting a
-- @proposedInstruction@ output field).
module Shikumi.Optimize.Instruction
  ( instructionSearch,
  )
where

import Control.Monad (foldM)
import Data.Aeson (ToJSON)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Shikumi.Eval (datasetSize)
import Shikumi.Optimize.Propose
  ( ProposeRequest (..),
    ProposeResult (..),
    proposeInstructions,
  )
import Shikumi.Optimize.Search (freezeProgram, scoreOn)
import Shikumi.Optimize.Types (Budget (..), Optimizer (..))
import Shikumi.Program (Params (..), Program, foldParams, mapParamsAt)

-- | Search for a better instruction at every node by greedy coordinate ascent under
-- an explicit LM-call budget, using the grounded proposer to generate candidates.
instructionSearch :: (ToJSON i, ToJSON o) => Int -> Budget -> Optimizer i o
instructionSearch proposalsPerNode budget = Optimizer $ \train metric student -> do
  let dsSize = datasetSize train
      nNodes = length (foldParams student)
      -- The grounded proposer's fixed per-node LM-call cost (see module header).
      proposerCost = 4 + max 0 proposalsPerNode

      -- Score candidate instructions for node @idx@, threading the call count and
      -- the best-so-far; stop before the next scoring would exceed the budget.
      scoreCands calls best idx prog cs = case cs of
        [] -> pure (best, calls)
        (c : rest)
          | calls + dsSize > maxLmCalls budget -> pure (best, calls)
          | otherwise -> do
              s <- scoreOn train metric (setNodeInstr idx c prog)
              let best' = case best of
                    Nothing -> Just (c, s)
                    Just (_, bs) -> if s > bs then Just (c, s) else best
              scoreCands (calls + dsSize) best' idx prog rest

      -- Optimize one node, holding the others fixed.
      stepNode (prog, calls) idx = do
        let curInstr = fromMaybe "" (instructionAt idx prog)
        (cands, calls1) <-
          if calls + proposerCost <= maxLmCalls budget
            then do
              ProposeResult cs <-
                proposeInstructions
                  train
                  ProposeRequest
                    { program = prog,
                      targetNode = idx,
                      currentInstruction = curInstr,
                      history = [],
                      bootstrappedDemos = [],
                      numCandidates = proposalsPerNode,
                      tipIndex = 0,
                      viewBatch = 2
                    }
              pure (cs, calls + proposerCost)
            else pure ([curInstr], calls)
        (best, calls2) <- scoreCands calls1 Nothing idx prog cands
        pure (setNodeInstr idx (maybe curInstr fst best) prog, calls2)

  (final, _) <- foldM stepNode (student, 0) [0 .. nNodes - 1]
  pure (freezeProgram final)

-- | The instruction stored at a node index (in @foldParams@ order), if any.
instructionAt :: Int -> Program i o -> Maybe Text
instructionAt idx prog = case drop idx (foldParams prog) of
  (ps : _) -> instructionOverride ps
  [] -> Nothing

-- | Set node @idx@'s instruction override.
setNodeInstr :: Int -> Text -> Program i o -> Program i o
setNodeInstr idx instr = mapParamsAt idx (\ps -> ps {instructionOverride = Just instr})
