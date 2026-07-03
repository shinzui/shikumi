{-# LANGUAGE GADTs #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | The chain-of-thought compiler: ensure every LM-call node reasons step by step
-- before answering.
--
-- __Implementation: a structural rewrite (the plan's preferred form).__ EP-4 has
-- no @reasoning@ flag on 'Shikumi.Program.Params' to flip; instead, reasoning is a
-- /structural/ property — 'Shikumi.Module.chainOfThought' augments a signature's
-- output with a leading @reasoning@ field and amends its instruction to "think step
-- by step", then projects the answer back out with @FMap@. So this compiler walks
-- the program and replaces each @Predict sig ps@ leaf with exactly that shape:
-- @FMap value (chainOfThoughtRaw sig)@, carrying the node's existing 'Params'
-- across. The rewrite is type-preserving (a @Program i o@ stays a @Program i o@)
-- because the augmented @Program i (WithReasoning o)@ is mapped back through
-- 'Shikumi.Module.value'.
--
-- This is feasible — and faithful — only because EP-4 /exports the GADT
-- constructors/, so a downstream package can pattern-match and rebuild nodes. EP-4
-- does not ship a node-level @rewriteNodes@ helper, so the recursion is spelled out
-- here over every constructor (the EP-4/EP-5 rule: every function over the GADT
-- must match every constructor).
--
-- __Caveat (recorded in the plan's Decision Log).__ The node's existing 'Params'
-- are preserved verbatim. For the common case — compiling a base (uncompiled)
-- program whose nodes carry 'Shikumi.Program.emptyParams' — this reproduces
-- 'Shikumi.Module.chainOfThought' exactly. If a node already carries an
-- @instructionOverride@, that override still replaces the augmented instruction at
-- run time (so the cue is lost): apply chain-of-thought /before/ a zero-shot
-- instruction, or fold the cue into the instruction yourself. If a node already
-- carries demos, they must be chain-of-thought-shaped (include a @reasoning@ field)
-- to decode under the augmented output; otherwise compile chain-of-thought before
-- few-shot.
--
-- Serialized state from this compiler must be decoded onto the same compiled
-- shape, not onto the plain base program. In practice, re-apply
-- 'chainOfThoughtCompiler' to the base template before calling
-- 'Shikumi.Compile.Serialize.decodeCompiledOnto'.
module Shikumi.Compile.ChainOfThought
  ( chainOfThoughtCompiler,
  )
where

import Shikumi.Compile.Types (Compiler (..))
import Shikumi.Module (chainOfThoughtRaw, value)
import Shikumi.Program
  ( Program
      ( Compose,
        Embed,
        Ensemble,
        FMap,
        MajorityVote,
        Map,
        Parallel,
        Predict,
        Retry,
        RetryWhen,
        Validate
      ),
    mapParams,
  )

-- | Rewrite every 'Predict' node into its chain-of-thought form, recursing through
-- every composite/combinator node so nodes nested arbitrarily deep are reached.
-- Saved state produced by this compiler should be loaded onto this compiled shape,
-- not onto the original base program.
chainOfThoughtCompiler :: Compiler
chainOfThoughtCompiler = Compiler cot

-- | The structural rewrite, polymorphic in @i@/@o@ so it threads through the GADT's
-- existential children. At a 'Predict' leaf the constructor's captured dictionaries
-- ('Shikumi.Schema.FromModel' @i@/@o@, 'Shikumi.Schema.ToSchema' @o@, the
-- 'Shikumi.Adapter.ToPrompt's) are exactly what 'chainOfThoughtRaw' needs.
cot :: Program i o -> Program i o
cot (Predict sig ps) = FMap value (mapParams (const ps) (chainOfThoughtRaw sig))
cot (Compose a b) = Compose (cot a) (cot b)
cot (FMap k p) = FMap k (cot p)
cot (Map w p) = Map w (cot p)
cot (Parallel a b) = Parallel (cot a) (cot b)
cot (Retry n p) = Retry n (cot p)
cot (RetryWhen ok n p) = RetryWhen ok n (cot p)
cot (Validate v p) = Validate v (cot p)
cot (MajorityVote k sched r p) = MajorityVote k sched r (cot p)
cot (Ensemble ps reduce) = Ensemble (map cot ps) reduce
cot (Embed f) = Embed f -- an agent node has no 'Predict' to rewrite; pass through
