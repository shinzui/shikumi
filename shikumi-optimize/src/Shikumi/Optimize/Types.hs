{-# LANGUAGE RankNTypes #-}

-- | The central abstractions of the optimizer framework (EP-10): the 'Optimizer'
-- strategy object, the search 'Budget', and the 'Scored' candidate wrapper.
--
-- An 'Optimizer' is a /search procedure/: given a training 'Dataset', a 'Metric',
-- and a starting 'Program', it proposes new node parameters (instructions and
-- few-shot demonstrations), scores each candidate by running the program over the
-- dataset, and returns the best-scoring 'CompiledProgram' it found. An optimizer
-- never changes a program's structure or types — only its parameters — so the
-- optimized program is the same typed function, merely better-behaved.
--
-- __Why a record of functions, not a typeclass.__ The four optimizers differ in
-- what extra inputs they carry (a teacher program, a budget, an inner optimizer
-- for ensembling) but share one driver signature. A @newtype@ whose field is the
-- driver lets each smart constructor ('Shikumi.Optimize.LabeledFewShot.labeledFewShot',
-- 'Shikumi.Optimize.Bootstrap.bootstrapFewShot', …) close over its own
-- configuration while presenting a uniform interface to
-- 'Shikumi.Optimize.optimize'. A typeclass would force the extra configuration
-- into associated types and make it impossible to build an optimizer at runtime
-- from CLI flags (which EP-12 needs).
--
-- __The effect row.__ The rank-2 'runOptimizer' field quantifies over the exact
-- effect row that EP-8's @evaluate@ requires —
-- @(LLM, Concurrent, Error ShikumiError, IOE)@ — because scoring a candidate
-- /is/ a call to @evaluate@ (via 'Shikumi.Optimize.scoreOn'). This is wider than
-- the plan's original @(LLM :> es)@ sketch: the delivered EP-8 runner threads
-- 'Concurrent' (bounded parallelism) and 'IOE' (monotonic per-example latency).
-- See the plan's Decision Log.
module Shikumi.Optimize.Types
  ( Optimizer (..),
    Budget (..),
    defaultBudget,
    Scored (..),
  )
where

import Effectful (Eff, IOE, (:>))
import Effectful.Concurrent (Concurrent)
import Effectful.Error.Static (Error)
import Shikumi.Compile.Types (CompiledProgram)
import Shikumi.Error (ShikumiError)
import Shikumi.Eval (Dataset, Metric)
import Shikumi.LLM (LLM)
import Shikumi.Program (Program)

-- | A search strategy that, given a training dataset, a metric, and a starting
-- (student) program, searches for better node parameters and returns a compiled
-- program. The rank-2 field shares one driver signature across all four
-- optimizers (see the module header).
newtype Optimizer i o = Optimizer
  { runOptimizer ::
      forall es.
      (LLM :> es, Concurrent :> es, Error ShikumiError :> es, IOE :> es) =>
      -- \| training set the search may fit to
      Dataset i o ->
      -- \| how candidates are scored
      Metric o ->
      -- \| the starting (student) program
      Program i o ->
      Eff es (CompiledProgram i o)
  }

-- | A hard, explicit bound on search cost. The optimizers that issue LM calls
-- count the calls they make (proposer calls + per-candidate scoring evaluations,
-- each scoring evaluation costing one LM call per dataset example) and stop —
-- returning the best candidate found /so far/ — before any bound is exceeded, so
-- they never silently produce an unscored program and never blow a cost ceiling.
data Budget = Budget
  { -- | ceiling on raw LM calls the optimizer may make (proposals + scoring)
    maxLmCalls :: !Int,
    -- | ceiling on the number of candidate programs scored
    maxCandidates :: !Int
  }
  deriving stock (Eq, Show)

-- | A sensible default budget: up to 200 LM calls across at most 32 candidates.
defaultBudget :: Budget
defaultBudget = Budget {maxLmCalls = 200, maxCandidates = 32}

-- | A candidate paired with its score. Threaded as a plain value through the pure
-- selection fold; there is no mutable search state.
data Scored a = Scored
  { candidate :: a,
    score :: !Double
  }
  deriving stock (Eq, Show)
