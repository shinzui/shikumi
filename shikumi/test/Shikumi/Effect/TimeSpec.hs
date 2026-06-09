-- | Exercises the 'Shikumi.Effect.Time' effect against its real interpreter
-- 'runTime': wall-clock reads succeed and the monotonic counter never runs
-- backwards. This pins the effect's behavior so a future fake-clock interpreter
-- can be checked against the same contract.
module Shikumi.Effect.TimeSpec (tests) where

import Effectful (runEff)
import Shikumi.Effect.Time (getCurrentTime, getMonotonicTimeNSec, runTime)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase)

tests :: TestTree
tests =
  testGroup
    "Shikumi.Effect.TimeSpec"
    [ testCase "getCurrentTime returns a renderable timestamp" $ do
        t <- runEff (runTime getCurrentTime)
        assertBool "timestamp renders to a non-empty string" (not (null (show t))),
      testCase "getMonotonicTimeNSec is non-decreasing across two reads" $ do
        (a, b) <- runEff $ runTime $ do
          a <- getMonotonicTimeNSec
          b <- getMonotonicTimeNSec
          pure (a, b)
        assertBool "second read is >= first" (b >= a)
    ]
