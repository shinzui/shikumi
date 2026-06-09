{-# LANGUAGE TypeApplications #-}

-- | M3: instruction search. Two tests. (a) Among the proposer's offerings, exactly
-- one (variant 0) carries the "magic" @RULE@-bearing instruction that unlocks
-- correct answers under the stub; the search selects it for the node. (b) Under a
-- deliberately tight 'Budget', the recorded LM-call count (proposer calls plus
-- per-candidate scoring calls) never exceeds @maxLmCalls@ — the search stops early
-- and returns the best found so far.
module InstructionSpec (tests) where

import Data.IORef (newIORef, readIORef)
import Effectful (Eff, IOE, runEff)
import Effectful.Concurrent (Concurrent, runConcurrent)
import Effectful.Error.Static (Error, runErrorNoCallStack)
import Effectful.Prim (Prim, runPrim)
import Shikumi.Compile.Types (compiledProgram)
import Shikumi.Effect.Time (Time, runTime)
import Shikumi.Error (ShikumiError)
import Shikumi.Eval (Dataset, dataset, exactMatch, example)
import Shikumi.LLM (LLM)
import Shikumi.Optimize
import Shikumi.Program (Params (..), programParams)
import StubLM (Label (..), Sentence (..), ruleInstruction, runStubLM, runStubLMCounting, sentimentProg)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

runStub :: Eff '[LLM, Error ShikumiError, Concurrent, Time, Prim, IOE] a -> IO (Either ShikumiError a)
runStub act = runEff . runPrim . runTime . runConcurrent . runErrorNoCallStack @ShikumiError $ runStubLM act

trainset :: Dataset Sentence Label
trainset =
  dataset
    [ example (Sentence "good film") (Label "positive"),
      example (Sentence "bad film") (Label "negative")
    ]

tests :: TestTree
tests =
  testGroup
    "M3 instructionSearch"
    [ testCase "selects the best proposed instruction for the node" $ do
        res <- runStub (optimize (instructionSearch 3 defaultBudget) trainset exactMatch sentimentProg)
        case res of
          Left e -> assertFailure ("unexpected error: " <> show e)
          Right cp -> case programParams (compiledProgram cp) of
            (ps : _) -> instructionOverride ps @?= Just ruleInstruction
            [] -> assertFailure "expected one node",
      testCase "respects the LM-call budget" $ do
        ref <- newIORef (0 :: Int)
        let budget = Budget {maxLmCalls = 6, maxCandidates = 32}
        res <-
          runEff . runPrim . runTime . runConcurrent . runErrorNoCallStack @ShikumiError $
            runStubLMCounting ref (optimize (instructionSearch 3 budget) trainset exactMatch sentimentProg)
        case res of
          Left e -> assertFailure ("unexpected error: " <> show e)
          Right _ -> pure ()
        count <- readIORef ref
        assertBool
          ("expected 0 < calls <= 6, got " <> show count)
          (count > 0 && count <= 6)
    ]
