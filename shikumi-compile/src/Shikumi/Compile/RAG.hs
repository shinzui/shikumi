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
-- The injection is a /structural/ rewrite (like "Shikumi.Compile.ChainOfThought"):
-- each @Predict sig ps@ leaf becomes @Predict (setInstruction (base <> context)
-- sig) ps@, so the original task instruction is preserved /and/ the retrieved
-- context is added (it appears in the rendered system prompt). The node's existing
-- 'Shikumi.Program.Params' are untouched; the same @instructionOverride@-precedence
-- caveat as chain-of-thought applies (an override set on a node replaces the whole
-- instruction at run time, context included), so apply 'rag' before a zero-shot
-- instruction if both are wanted.
module Shikumi.Compile.RAG
  ( rag,
    formatPassages,
  )
where

import Data.Text (Text)
import Data.Text qualified as T
import Effectful (runPureEff)
import Shikumi.Compile.Retriever (Passage (..), Retriever (..))
import Shikumi.Compile.Types (Compiler (..))
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
  )
import Shikumi.Signature (getInstruction, setInstruction)

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

-- | Append the context block to every node's signature instruction, recursing
-- through every composite/combinator node. A no-op when @ctx@ is empty.
install :: Text -> Program i o -> Program i o
install ctx
  | T.null ctx = id
  | otherwise = go
  where
    go :: forall i o. Program i o -> Program i o
    go (Predict sig ps) = Predict (setInstruction (getInstruction sig <> "\n\n" <> ctx) sig) ps
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
