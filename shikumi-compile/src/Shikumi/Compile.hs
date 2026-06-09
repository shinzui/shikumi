-- | The shikumi compiler layer (EP-9): pure @Program -> Program@ transformations
-- that bake a prompting strategy into a program.
--
-- A /compiler/ (in the DSPy sense the user is porting) sets a program's per-node
-- parameters and/or rewrites its structure according to a fixed recipe — zero-shot,
-- few-shot, chain-of-thought, retrieval-augmented. It is pure and never calls the
-- LM; searching for better parameters is the optimizer's job (EP-10).
--
-- @
-- import Shikumi.Compile
--
-- qaFewShot :: CompiledProgram Question Answer
-- qaFewShot = compile (fewShotTyped [(Question \"2+2?\", Answer \"4\")]) qa
--
-- qaCoT :: CompiledProgram Question Answer
-- qaCoT = compile chainOfThoughtCompiler qa
-- @
--
-- This module re-exports the full public surface; see the per-strategy modules for
-- detail and caveats.
module Shikumi.Compile
  ( -- * Types
    Compiler (..),
    CompiledProgram (..),
    compile,
    runCompiled,
    identity,

    -- * Strategies
    zeroShot,
    zeroShotClear,
    fewShot,
    fewShotTyped,
    chainOfThoughtCompiler,
    rag,

    -- * Retrieval
    Retriever (..),
    Passage (..),
    inMemoryRetriever,
    formatPassages,

    -- * Serialization
    encodeCompiled,
    decodeCompiledOnto,
  )
where

import Shikumi.Compile.ChainOfThought (chainOfThoughtCompiler)
import Shikumi.Compile.FewShot (fewShot, fewShotTyped)
import Shikumi.Compile.RAG (formatPassages, rag)
import Shikumi.Compile.Retriever (Passage (..), Retriever (..), inMemoryRetriever)
import Shikumi.Compile.Serialize (decodeCompiledOnto, encodeCompiled)
import Shikumi.Compile.Types (CompiledProgram (..), Compiler (..), compile, identity, runCompiled)
import Shikumi.Compile.ZeroShot (zeroShot, zeroShotClear)
