{-# LANGUAGE GADTs #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | The retrieval-augmented (RAG) compiler: install retrieved context so that the
-- rendered prompt at every LM-call node carries the passages a retriever found.
--
-- __Purity vs. retrieval (how the plan's question is resolved here).__ 'compile' is
-- pure, but retrieval fetches data. EP-4 ships /no/ effectful escape-hatch node
-- (no @embed@ / @Embed@ constructor that would let an @i -> Eff es o@ become a
-- @Program@ node), so the plan's "approach 1" (install a runtime retrieval step
-- keyed on the actual input) is not available. This is the plan's documented
-- /fallback/: retrieve at /compile time/ against a fixed sample query, then inject
-- the top passages into every node's signature instruction. 'compile' stays pure
-- because the trivial 'Shikumi.Compile.Retriever.inMemoryRetriever' performs no
-- effect — it is run via 'runPureEff'. The limitation is that retrieval is
-- query-independent of the actual program input; wiring true per-input retrieval
-- awaits an EP-4 embed node and is left as a TODO.
--
-- The injection is a serializable parameter rewrite: each @Predict sig ps@ leaf
-- keeps its signature and receives an @instructionOverride@ containing the
-- effective instruction (an existing override if present, otherwise the
-- signature's base instruction) plus the retrieved context. This means RAG state
-- survives 'Shikumi.Compile.Serialize.encodeCompiled' /
-- 'Shikumi.Compile.Serialize.decodeCompiledOnto'. Composition order still matters:
-- applying 'zeroShot' after 'rag' replaces the whole override and drops the
-- context, while applying 'rag' after 'zeroShot' appends context to the zero-shot
-- instruction.
module Shikumi.Compile.RAG
  ( rag,
    formatPassages,
  )
where

import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Effectful (runPureEff)
import Shikumi.Compile.Retriever (Passage (..), Retriever (..))
import Shikumi.Compile.Types (Compiler (..))
import Shikumi.Program
  ( Params (..),
    Program
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
  )
import Shikumi.Signature (getInstruction)

-- | Install retrieved context at every node. Retrieval happens once, now, against
-- @query@ (the documented compile-time fallback); the formatted passages are then
-- prepended-as-context to every 'Shikumi.Program.Predict' node's instruction.
rag :: Retriever -> Text -> Compiler
rag r query = Compiler (install context)
  where
    passages = runPureEff (retrieve r query)
    context = formatPassages passages

-- | Render retrieved passages as a labeled context block for the prompt. Empty
-- input yields the empty string (no spurious header).
formatPassages :: [Passage] -> Text
formatPassages [] = ""
formatPassages ps =
  "Use the following retrieved context to answer:\n"
    <> T.unlines ["- " <> text p | p <- ps]

-- | Append the context block to every node's effective instruction, storing the
-- result in serializable node parameters. A no-op when @ctx@ is empty.
install :: Text -> Program i o -> Program i o
install ctx
  | T.null ctx = id
  | otherwise = go
  where
    go :: forall i o. Program i o -> Program i o
    go (Predict sig ps) =
      let base = fromMaybe (getInstruction sig) (instructionOverride ps)
       in Predict sig ps {instructionOverride = Just (base <> "\n\n" <> ctx)}
    go (Compose a b) = Compose (go a) (go b)
    go (FMap k p) = FMap k (go p)
    go (Map w p) = Map w (go p)
    go (Parallel a b) = Parallel (go a) (go b)
    go (Retry n p) = Retry n (go p)
    go (RetryWhen ok n p) = RetryWhen ok n (go p)
    go (Validate v p) = Validate v (go p)
    go (MajorityVote k sched r p) = MajorityVote k sched r (go p)
    go (Ensemble ps reduce) = Ensemble (map go ps) reduce
    go (Embed f) = Embed f -- an agent node has no 'Predict' to rewrite; pass through
