{-# LANGUAGE RankNTypes #-}

-- | The two types this plan (EP-9) owns and the verbs over them.
--
-- A 'Compiler' is a /pure/ @Program -> Program@ rewrite that bakes a prompting
-- strategy into a program — it sets per-node parameters (zero-shot, few-shot) or
-- rewrites structure (chain-of-thought, RAG). It is emphatically /not/ a search:
-- it never calls the LM to try variations and keep the best (that is the optimizer,
-- @docs/plans/10-optimizer-framework.md@).
--
-- A 'CompiledProgram' is the result of compilation — a phantom-marked 'Program'
-- that says "these parameters are intentional, this program is ready to
-- run/serialize/optimize". It is MasterPlan integration point #6: the optimizer
-- (EP-10) emits one and the CLI (EP-12) loads/runs/saves one.
--
-- __Why a newtype, not a side table of frozen parameters.__ EP-4
-- (@Shikumi.Program@) already stores each node's 'Shikumi.Program.Params' /inside/
-- the @Program@ GADT node. A compiler therefore produces a fully-formed @Program@
-- whose nodes already hold the baked-in parameters; there is nothing to keep on the
-- side. The newtype is a marker that prevents a half-built base program from being
-- silently treated as compiled, and gives the optimizer's return type and the CLI's
-- load/save type something precise to name.
module Shikumi.Compile.Types
  ( Compiler (..),
    CompiledProgram (..),
    compile,
    runCompiled,
    identity,
  )
where

import Effectful (Eff, (:>))
import Effectful.Error.Static (Error)
import Shikumi.Error (ShikumiError)
import Shikumi.LLM (LLM)
import Shikumi.Program (Program, runProgram)

-- | A pure rewrite of a program. The @forall i o@ is the key design move: a
-- compiler must apply to /any/ program regardless of its input/output types
-- (few-shot demos are type-agnostic JSON, an instruction string is type-agnostic,
-- the chain-of-thought rewrite is uniform), so a single 'Compiler' value
-- ('identity', 'Shikumi.Compile.ZeroShot.zeroShot', …) is usable everywhere.
-- @RankNTypes@ (on by default in GHC2024) makes the rank-2 field legal.
newtype Compiler = Compiler
  { runCompiler :: forall i o. Program i o -> Program i o
  }

-- | A program that has been through a 'Compiler'. A newtype over 'Program' — the
-- parameters live on the nodes (see the module header).
newtype CompiledProgram i o = CompiledProgram
  { compiledProgram :: Program i o
  }

-- | Apply a compiler to a base program, marking the result compiled. Pure: no
-- @Eff@, no @IO@. Every initial compiler is a deterministic rewrite given
-- statically-supplied data, so compilation is trivially testable and composable
-- (@compile c2 . CompiledProgram . runCompiler c1@).
compile :: Compiler -> Program i o -> CompiledProgram i o
compile (Compiler f) = CompiledProgram . f

-- | Run a compiled program. Identical to running the wrapped 'Program', so it
-- inherits EP-4's @runProgram@ constraint exactly (MasterPlan integration point
-- #4): @(LLM :> es, Error ShikumiError :> es)@ — the decode path throws typed
-- 'ShikumiError's.
runCompiled ::
  (LLM :> es, Error ShikumiError :> es) =>
  CompiledProgram i o ->
  i ->
  Eff es o
runCompiled (CompiledProgram p) = runProgram p

-- | The no-op compiler: returns the program unchanged. Useful as a baseline and as
-- the unit for composing compilers.
identity :: Compiler
identity = Compiler id
