-- | EP-7 acceptance test suite. Milestones are selected with tasty's @-p@:
-- @spike@ (M0), @tree@ (M1), @store@ (M2), @replay@ (M3), @e2e@ (M5).
module Main (main) where

import Shikumi.Trace.Internal.Spike (SpanId (..), runSpike)
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

main :: IO ()
main = defaultMain $ testGroup "shikumi-trace" [spikeTests]

-- | M0: the interpose-plus-span-stack mechanism tags each LM call with the
-- enclosing span that was on top of the stack when the call ran.
spikeTests :: TestTree
spikeTests =
  testGroup
    "spike"
    [ testCase "each captured LM call is tagged with its enclosing span id" $ do
        captured <- runSpike
        map fst captured @?= [SpanId "draft", SpanId "critique"]
        map snd captured @?= ["first draft", "a sharp critique"]
    ]
