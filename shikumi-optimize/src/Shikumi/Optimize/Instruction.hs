-- | M3 — instruction search (a MIPRO/COPRO-style optimizer). For each node, an LM
-- /proposer/ suggests several candidate instruction strings; each is scored, and
-- the best is kept. Optimization is greedy coordinate ascent — one node at a time,
-- holding the others fixed — so the candidate count is linear in
-- @nodes × proposals@ rather than exponential.
--
-- The proposer ('proposeInstruction') is itself an ordinary shikumi 'Program', so
-- it is typed, cached, traced, and testable with the same stub-LM machinery as
-- everything else — the optimizer is written in the framework it optimizes. The
-- /current/ instruction is always included as a candidate, so a node can never
-- end up worse than where it started.
--
-- __Budget.__ Every proposer call costs one LM call; scoring one candidate costs
-- one LM call per dataset example. The search threads a running raw-call count and
-- stops — returning the best found /so far/ — before either bound in the 'Budget'
-- would be exceeded, so the recorded LM-call count never exceeds @maxLmCalls@.
--
-- __Adaptation note.__ EP-4 exposes no per-node 'Shikumi.Signature.Signature'
-- accessor (no @nodeSignature@), so the proposer's @fieldSummary@ is a static
-- description rather than the node's actual field names; this does not affect the
-- search, only the proposer prompt's richness.
module Shikumi.Optimize.Instruction
  ( instructionSearch,
    proposeInstruction,
    ProposeIn (..),
    ProposeOut (..),
  )
where

import Control.Monad (foldM)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Generics (Generic)
import Shikumi.Adapter (ToPrompt)
import Shikumi.Eval (datasetSize)
import Shikumi.Module (predict)
import Shikumi.Optimize.Search (freezeProgram, scoreOn)
import Shikumi.Optimize.Types (Budget (..), Optimizer (..))
import Shikumi.Program (Params (..), Program, foldParams, mapParamsAt, runProgram)
import Shikumi.Schema (FromModel, ToSchema, Validatable)
import Shikumi.Signature (Signature, mkSignature)

-- | The proposer's input: the node's current instruction, a summary of its task's
-- fields, and a few example inputs (or, in tests, a @variant:N@ marker selecting a
-- deterministic proposal).
data ProposeIn = ProposeIn
  { currentInstruction :: Text,
    fieldSummary :: Text,
    examples :: Text
  }
  deriving stock (Generic, Show)

instance FromModel ProposeIn

instance ToPrompt ProposeIn

-- | The proposer's output: a single proposed instruction string.
newtype ProposeOut = ProposeOut {proposedInstruction :: Text}
  deriving stock (Generic, Show)

instance ToSchema ProposeOut

instance FromModel ProposeOut

instance ToPrompt ProposeOut

instance Validatable ProposeOut

-- | The proposer program: a single structured-output predictor that, given the
-- current instruction and task summary, returns a better instruction.
proposeInstruction :: Program ProposeIn ProposeOut
proposeInstruction = predict proposeSig

proposeSig :: Signature ProposeIn ProposeOut
proposeSig =
  mkSignature
    "You are improving the instruction for a task. Given the current instruction \
    \and a summary of the task's input and output fields, write a single improved \
    \instruction in the `proposedInstruction` field."

-- | Search for a better instruction at every node by greedy coordinate ascent
-- under an explicit LM-call budget.
instructionSearch :: Int -> Budget -> Optimizer i o
instructionSearch proposalsPerNode budget = Optimizer $ \train metric student -> do
  let dsSize = datasetSize train
      nNodes = length (foldParams student)
      -- EP-4 ships no per-node signature accessor, so the summary is static.
      summary = "the task's input and output fields"

      -- Generate proposals for the variant indices in @vs@, threading the call
      -- count and stopping before the budget is exceeded.
      genProposals calls vs curInstr = case vs of
        [] -> pure ([], calls)
        (v : rest)
          | calls + 1 > maxLmCalls budget -> pure ([], calls)
          | otherwise -> do
              ProposeOut p <-
                runProgram proposeInstruction (ProposeIn curInstr summary ("variant:" <> tshow v))
              (ps, calls') <- genProposals (calls + 1) rest curInstr
              pure (p : ps, calls')

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
        (proposed, calls1) <- genProposals calls [0 .. proposalsPerNode - 1] curInstr
        (best, calls2) <- scoreCands calls1 Nothing idx prog (curInstr : proposed)
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

tshow :: (Show a) => a -> Text
tshow = T.pack . show
