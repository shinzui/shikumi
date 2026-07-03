{-# LANGUAGE TypeApplications #-}

-- | Unit tests for the shared optimizer search helpers.
module SearchSpec (tests) where

import Data.IORef (newIORef, readIORef)
import Effectful (Eff, IOE, runEff)
import Effectful.Concurrent (Concurrent, runConcurrent)
import Effectful.Error.Static (Error, runErrorNoCallStack)
import Effectful.Prim (Prim, runPrim)
import Effectful.Prim.IORef qualified as EIORef
import Shikumi.Combinator ((>>>))
import Shikumi.Effect.Time (Time, runTime)
import Shikumi.Error (ShikumiError)
import Shikumi.Eval (Dataset, dataset, exactMatch, example)
import Shikumi.LLM (LLM)
import Shikumi.Module (predict)
import Shikumi.Optimize.Search
  ( BudgetMeter (..),
    effectiveInstructionAt,
    instructionAt,
    meteredScore,
    newBudgetMeter,
    scoreOn,
    selectBestMetered,
    setNodeInstr,
    setNodeInstrIfNew,
    tryCharge,
    withLmCallCount,
  )
import Shikumi.Optimize.Types (Budget (..), Scored (..))
import Shikumi.Program (Program)
import Shikumi.Signature (Signature, mkSignature)
import StubLM (Label (..), Sentence (..), ruleInstruction, ruled, runStubLM, runStubLMCounting, sentimentProg)
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

echoSig :: Signature Label Label
echoSig = mkSignature "Echo the sentiment label unchanged."

twoNode :: Program Sentence Label
twoNode = sentimentProg >>> predict echoSig

tests :: TestTree
tests =
  testGroup
    "Search"
    [ testCase "effectiveInstructionAt reads signature base, override, and out-of-range" $ do
        effectiveInstructionAt 0 ruled @?= ruleInstruction
        effectiveInstructionAt 0 (setNodeInstr 0 "override" ruled) @?= "override"
        effectiveInstructionAt 99 ruled @?= "",
      testCase "setNodeInstrIfNew does not write redundant override" $ do
        let kept = setNodeInstrIfNew 0 ruleInstruction ruled
            changed = setNodeInstrIfNew 0 "different" ruled
        instructionAt 0 kept @?= Nothing
        instructionAt 0 changed @?= Just "different",
      testCase "effectiveInstructionAt is index-aligned on a two-node program" $ do
        effectiveInstructionAt 0 twoNode @?= ""
        effectiveInstructionAt 1 twoNode @?= "Echo the sentiment label unchanged."
        effectiveInstructionAt 1 (setNodeInstr 1 "changed" twoNode) @?= "changed",
      testCase "tryCharge refuses an over-budget charge without changing the counter" $ do
        (ok1, ok2, ok3, calls) <-
          runEff . runPrim $ do
            meter <- newBudgetMeter Budget {maxLmCalls = 3, maxCandidates = 32}
            ok1 <- tryCharge meter 2
            ok2 <- tryCharge meter 2
            ok3 <- tryCharge meter 1
            calls <- EIORef.readIORef (meterCalls meter)
            pure (ok1, ok2, ok3, calls)
        (ok1, ok2, ok3, calls) @?= (True, False, True, 3),
      testCase "meteredScore returns Nothing without invoking the LM when cost does not fit" $ do
        ref <- newIORef (0 :: Int)
        res <-
          runEff . runPrim . runTime . runConcurrent . runErrorNoCallStack @ShikumiError $
            runStubLMCounting ref $ do
              meter <- newBudgetMeter Budget {maxLmCalls = 1, maxCandidates = 32}
              meteredScore meter trainset exactMatch sentimentProg
        case res of
          Left e -> assertFailure ("unexpected error: " <> show e)
          Right Nothing -> pure ()
          Right (Just s) -> assertFailure ("expected no score, got " <> show s)
        count <- readIORef ref
        count @?= 0,
      testCase "selectBestMetered stops at first Nothing and returns best so far" $ do
        best <-
          runEff . runPrim $ do
            meter <- newBudgetMeter Budget {maxLmCalls = 100, maxCandidates = 32}
            selectBestMetered
              meter
              ( \n ->
                  pure $
                    if n >= (4 :: Int)
                      then Nothing
                      else Just (fromIntegral n)
              )
              [1 :: Int, 3, 2, 4, 99]
        best @?= Just (Scored 3 3.0),
      testCase "withLmCallCount counts one completion per scored example" $ do
        res <- runStub $ withLmCallCount (scoreOn trainset exactMatch sentimentProg)
        case res of
          Left e -> assertFailure ("unexpected error: " <> show e)
          Right (_score, count) ->
            assertBool ("expected two completions, got " <> show count) (count == 2)
    ]
