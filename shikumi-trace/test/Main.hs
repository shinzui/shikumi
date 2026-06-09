-- | EP-7 acceptance test suite. Milestones are selected with tasty's @-p@:
-- @spike@ (M0), @tree@ (M1), @store@ (M2), @replay@ (M3), @e2e@ (M5).
module Main (main) where

import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Effectful (runEff)
import Shikumi.LLM (complete)
import Shikumi.Trace
  ( Span (..),
    SpanId,
    SpanKind (..),
    TraceTree (..),
    childrenOf,
    renderTree,
    runTrace,
    tracedLLM,
    withSpan,
  )
import Shikumi.Trace.Internal.Spike qualified as Spike
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))
import TraceFixtures (ctxFor, mkResponse, optsFor, runFixedLLM, stubModel)

main :: IO ()
main = defaultMain $ testGroup "shikumi-trace" [spikeTests, treeTests]

-- ---------------------------------------------------------------------------
-- M0
-- ---------------------------------------------------------------------------

-- | M0: the interpose-plus-span-stack mechanism tags each LM call with the
-- enclosing span that was on top of the stack when the call ran.
spikeTests :: TestTree
spikeTests =
  testGroup
    "spike"
    [ testCase "each captured LM call is tagged with its enclosing span id" $ do
        captured <- Spike.runSpike
        map fst captured @?= [Spike.SpanId "draft", Spike.SpanId "critique"]
        map snd captured @?= ["first draft", "a sharp critique"]
    ]

-- ---------------------------------------------------------------------------
-- M1
-- ---------------------------------------------------------------------------

-- | M1: a two-@withSpan@ nest containing two stubbed LM calls produces a tree
-- with one root, two module children, each holding exactly one LM-call leaf;
-- @renderTree@ shows the model lines indented under their modules.
treeTests :: TestTree
treeTests =
  testGroup
    "tree"
    [ testCase "nested withSpans build a program -> module -> llm-call tree" $ do
        tree <- buildTree
        -- (a) exactly one root
        let roots = [s | s <- Map.elems (spans tree), parent s == Nothing]
        length roots @?= 1
        kind (spanAt tree (root tree)) @?= ProgramSpan
        -- (b) the root has two module children
        let kids = childrenOf tree (root tree)
        length kids @?= 2
        map (kind . spanAt tree) kids @?= [ModuleSpan, ModuleSpan]
        -- (c) each module child has exactly one llm-call child
        let grandkids = concatMap (childrenOf tree) kids
        length grandkids @?= 2
        map (kind . spanAt tree) grandkids @?= [LlmCallSpan, LlmCallSpan],
      testCase "renderTree shows the model lines indented under their modules" $ do
        tree <- buildTree
        let out = renderTree tree
        assertBool "two llm-call model lines present" (T.count "stub/stub-model" out == 2)
        assertBool "llm-call lines are indented under modules" (T.isInfixOf "    llm-call  stub/stub-model" out)
        assertBool "module lines present" (T.count "module" out == 2)
    ]

-- | Run a two-stage traced computation: a program span containing two module
-- spans, each issuing one stubbed LM call (captured automatically by 'tracedLLM').
buildTree :: IO TraceTree
buildTree = do
  let resp = mkResponse "ok"
  ((), tree) <-
    runEff . runTrace . runFixedLLM resp . tracedLLM $
      withSpan ProgramSpan "summarize-and-critique" $ do
        _ <- withSpan ModuleSpan "predict:Draft" (complete stubModel (ctxFor "draft this") optsFor)
        _ <- withSpan ModuleSpan "predict:Critique" (complete stubModel (ctxFor "critique that") optsFor)
        pure ()
  pure tree

spanAt :: TraceTree -> SpanId -> Span
spanAt tree sid = spans tree Map.! sid
