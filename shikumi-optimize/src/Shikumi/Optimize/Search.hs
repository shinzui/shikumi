-- | The shared search-state plumbing every concrete optimizer reuses: the pure
-- 'selectBest' fold, the @evaluate@-backed 'scoreOn' scorer, and 'freezeProgram'.
--
-- This module sits /below/ both 'Shikumi.Optimize' (which re-exports it) and the
-- four optimizer modules (which import it), so there is no import cycle: the
-- optimizers depend on the plumbing, not on the public driver.
--
-- __No global mutable state.__ Candidates are threaded as ordinary values; the
-- only effectful step is scoring a candidate (running it over the dataset).
module Shikumi.Optimize.Search
  ( selectBest,
    scoreOn,
    freezeProgram,
    setNodeInstr,
    setNodeInstrIfNew,
    instructionAt,
    effectiveInstructionAt,
  )
where

import Control.Lens ((&), (?~))
import Data.Generics.Labels ()
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Effectful (Eff, (:>))
import Effectful.Concurrent (Concurrent)
import Effectful.Error.Static (Error)
import Effectful.Prim (Prim)
import Shikumi.Compile.Types (CompiledProgram (..))
import Shikumi.Effect.Time (Time)
import Shikumi.Error (ShikumiError)
import Shikumi.Eval (Dataset, Metric, Report (aggregateScore), evaluatePure)
import Shikumi.LLM (LLM)
import Shikumi.Optimize.Types (Budget (..), Scored (..))
import Shikumi.Program (Params (..), Program, foldParams, mapParamsAt, nodeInstructionsIndexed)

-- | Score every candidate (left to right), stopping once the candidate budget is
-- hit, and return the best by score (ties: earliest wins). The scorer is the
-- /only/ effectful part; the selection is a pure fold over the results, so the
-- search is reproducible and trivially testable by swapping in a pure scorer.
selectBest ::
  (Monad m) =>
  Budget ->
  -- | scorer (typically 'scoreOn')
  (cand -> m Double) ->
  -- | candidates, threaded explicitly
  [cand] ->
  m (Maybe (Scored cand))
selectBest budget scorer cands = do
  scored <- mapM scoreOne (take (max 0 (maxCandidates budget)) cands)
  pure (bestOf scored)
  where
    scoreOne c = do
      s <- scorer c
      pure (Scored c s)
    -- Fold to the maximum by score; @>@ (strict) keeps the earliest on ties.
    bestOf [] = Nothing
    bestOf (x : xs) = Just (foldl' (\b c -> if score c > score b then c else b) x xs)

-- | Score a candidate program against a dataset and pure metric: run EP-8's
-- @evaluate@ and take the aggregate. One call scores one program over the whole
-- dataset (one LM call per example).
scoreOn ::
  (LLM :> es, Concurrent :> es, Error ShikumiError :> es, Time :> es, Prim :> es) =>
  Dataset i o ->
  Metric o ->
  Program i o ->
  Eff es Double
scoreOn ds m p = aggregateScore <$> evaluatePure ds m p

-- | Mark a program compiled without changing its parameters. EP-9 stores each
-- node's parameters /on/ the node, so an optimizer that has already rewritten a
-- program's parameters just wraps the finished program — there is nothing to
-- freeze on the side.
freezeProgram :: Program i o -> CompiledProgram i o
freezeProgram = CompiledProgram

-- | Set node @idx@'s instruction override (in @foldParams@ order). Shared by
-- @instructionSearch@ and @copro@.
setNodeInstr :: Int -> Text -> Program i o -> Program i o
setNodeInstr idx instr = mapParamsAt idx (\ps -> ps & #instructionOverride ?~ instr)

-- | The instruction node @idx@ actually runs with: its 'instructionOverride' when
-- set, otherwise its signature's base instruction. This mirrors the runtime
-- precedence in 'Shikumi.Program.effectiveSignature'. Out-of-range indices yield
-- the empty string.
effectiveInstructionAt :: Int -> Program i o -> Text
effectiveInstructionAt idx prog =
  case drop idx (zip (nodeInstructionsIndexed prog) (foldParams prog)) of
    ((base, ps) : _) -> fromMaybe base (instructionOverride ps)
    [] -> ""

-- | Set node @idx@'s instruction override unless @instr@ is already its effective
-- instruction. Keeping the current signature instruction therefore leaves
-- 'instructionOverride' as 'Nothing' instead of serializing a redundant override.
setNodeInstrIfNew :: Int -> Text -> Program i o -> Program i o
setNodeInstrIfNew idx instr prog
  | instr == effectiveInstructionAt idx prog = prog
  | otherwise = setNodeInstr idx instr prog

-- | The instruction override stored at node @idx@ (in @foldParams@ order), if any.
instructionAt :: Int -> Program i o -> Maybe Text
instructionAt idx prog = case drop idx (foldParams prog) of
  (ps : _) -> instructionOverride ps
  [] -> Nothing
