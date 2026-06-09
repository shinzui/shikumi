-- | The public surface of the optimizer framework (EP-10).
--
-- 'optimize' is the one stable entry point EP-12's CLI calls: it applies an
-- 'Optimizer' strategy to a starting program and returns a 'CompiledProgram'. The
-- shared search-state plumbing — 'selectBest' (the pure "score candidates, keep
-- the best" fold) and 'scoreOn' (the standard scorer, built on EP-8's @evaluate@)
-- — lives here too, so every concrete optimizer reuses one mechanism. The four
-- strategies are re-exported from their own modules.
--
-- __No global mutable state.__ Candidate programs are threaded as ordinary values
-- through pure folds; the /only/ effectful step is scoring a candidate (which runs
-- it over the dataset via 'scoreOn'). This is the "thread candidates explicitly"
-- discipline the MasterPlan mandates.
module Shikumi.Optimize
  ( -- * The driver
    optimize,

    -- * Shared search-state plumbing
    selectBest,
    scoreOn,
    freezeProgram,

    -- * Re-exports
    module Shikumi.Optimize.Types,
  )
where

import Effectful (Eff, IOE, (:>))
import Effectful.Concurrent (Concurrent)
import Effectful.Error.Static (Error)
import Shikumi.Compile.Types (CompiledProgram (..))
import Shikumi.Error (ShikumiError)
import Shikumi.Eval (Dataset, Metric, Report (aggregateScore), evaluatePure)
import Shikumi.LLM (LLM)
import Shikumi.Optimize.Types
import Shikumi.Program (Program)

-- | Apply an optimizer to a starting program. A thin wrapper around the strategy
-- so the public API is one stable name (and so EP-12's CLI dispatches on one
-- function regardless of which optimizer the user picked).
optimize ::
  (LLM :> es, Concurrent :> es, Error ShikumiError :> es, IOE :> es) =>
  Optimizer i o ->
  Dataset i o ->
  Metric o ->
  Program i o ->
  Eff es (CompiledProgram i o)
optimize opt train metric prog = runOptimizer opt train metric prog

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
  (LLM :> es, Concurrent :> es, Error ShikumiError :> es, IOE :> es) =>
  Dataset i o ->
  Metric o ->
  Program i o ->
  Eff es Double
scoreOn ds m p = aggregateScore <$> evaluatePure ds m p

-- | Mark a program compiled without changing its parameters. EP-9 stores each
-- node's parameters /on/ the node, so an optimizer that has already rewritten a
-- program's parameters just wraps the finished program — there is nothing to
-- freeze on the side. (This is EP-9's @CompiledProgram@ constructor; named here
-- for the optimizers' return paths.)
freezeProgram :: Program i o -> CompiledProgram i o
freezeProgram = CompiledProgram
