-- | The public surface of the optimizer framework (EP-10).
--
-- 'optimize' is the one stable entry point EP-12's CLI calls: it applies an
-- 'Optimizer' strategy to a starting program and returns a 'CompiledProgram'. The
-- shared search-state plumbing ('selectBest', 'scoreOn', 'freezeProgram') lives in
-- "Shikumi.Optimize.Search" and is re-exported here; the four strategies are
-- re-exported from their own modules.
--
-- __No global mutable state.__ Candidate programs are threaded as ordinary values
-- through pure folds; the /only/ effectful step is scoring a candidate (which runs
-- it over the dataset via 'scoreOn'). This is the "thread candidates explicitly"
-- discipline the MasterPlan mandates.
module Shikumi.Optimize
  ( -- * The driver
    optimize,

    -- * Re-exports
    module Shikumi.Optimize.Types,
    module Shikumi.Optimize.Search,
    module Shikumi.Optimize.LabeledFewShot,
    module Shikumi.Optimize.Bootstrap,
    module Shikumi.Optimize.Instruction,
    module Shikumi.Optimize.COPRO,
    module Shikumi.Optimize.MIPRO,
    module Shikumi.Optimize.Ensemble,
  )
where

import Effectful (Eff, (:>))
import Effectful.Concurrent (Concurrent)
import Effectful.Error.Static (Error)
import Effectful.Prim (Prim)
import Shikumi.Compile.Types (CompiledProgram)
import Shikumi.Effect.Time (Time)
import Shikumi.Error (ShikumiError)
import Shikumi.Eval (Dataset, Metric)
import Shikumi.LLM (LLM)
import Shikumi.Optimize.Bootstrap
import Shikumi.Optimize.COPRO
import Shikumi.Optimize.Ensemble
import Shikumi.Optimize.Instruction
import Shikumi.Optimize.LabeledFewShot
import Shikumi.Optimize.MIPRO
import Shikumi.Optimize.Search
import Shikumi.Optimize.Types
import Shikumi.Program (Program)

-- | Apply an optimizer to a starting program. A thin wrapper around the strategy
-- so the public API is one stable name (and so EP-12's CLI dispatches on one
-- function regardless of which optimizer the user picked).
optimize ::
  (LLM :> es, Concurrent :> es, Error ShikumiError :> es, Time :> es, Prim :> es) =>
  Optimizer i o ->
  Dataset i o ->
  Metric o ->
  Program i o ->
  Eff es (CompiledProgram i o)
optimize opt train metric prog = runOptimizer opt train metric prog
