-- | Usage-accounting tests for both blocking and streamed LM calls.
module UsageSpec (tests) where

import Baikai (emptyContext, emptyModel, emptyOptions)
import Effectful (runEff)
import Effectful.Concurrent (runConcurrent)
import Effectful.Error.Static (runErrorNoCallStack)
import Effectful.Prim (runPrim)
import EvalFixtures
  ( Answer (..),
    Question (..),
    qaProg,
    runConstLLM,
    runStreamLLM,
    usageResponse,
    usageTerminalEvents,
    usageTotalsPerCall,
  )
import Shikumi.Effect.Time (runTime)
import Shikumi.Error (ShikumiError)
import Shikumi.Eval.Evaluate (evaluatePure)
import Shikumi.Eval.Metric (exactMatch)
import Shikumi.Eval.Report (Report (..), UsageTotals (..))
import Shikumi.Eval.Types (dataset, example)
import Shikumi.Eval.Usage (withUsageTotals)
import Shikumi.LLM (stream)
import Shikumi.Program (runProgram)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Usage"
    [ testCase "complete calls accumulate non-zero usage" $ do
        result <-
          runEff . runPrim . runErrorNoCallStack @ShikumiError $
            runConstLLM (usageResponse "yes") $
              withUsageTotals $ do
                _ <- runProgram qaProg (Question "q1")
                _ <- runProgram qaProg (Question "q2")
                pure ()
        case result of
          Left e -> assertFailure ("unexpected error: " <> show e)
          Right (_, totals) -> totals @?= usageTotalsPerCall <> usageTotalsPerCall,
      testCase "stream calls accumulate usage" $ do
        let events = usageTerminalEvents "yes"
        result <-
          runEff . runPrim $
            runStreamLLM events $
              withUsageTotals (stream emptyModel emptyContext emptyOptions)
        snd result @?= usageTotalsPerCall,
      testCase "evaluate reports non-zero usage end-to-end" $ do
        let ds =
              dataset
                [ example (Question "q1") (Answer "yes"),
                  example (Question "q2") (Answer "yes"),
                  example (Question "q3") (Answer "yes")
                ]
        report <-
          runEff . runPrim . runTime . runConcurrent . runErrorNoCallStack @ShikumiError $
            runConstLLM (usageResponse "yes") $
              evaluatePure ds exactMatch qaProg
        case report of
          Left e -> assertFailure ("unexpected error: " <> show e)
          Right r ->
            usage r
              @?= UsageTotals
                { totalInputTokens = 300,
                  totalOutputTokens = 60,
                  totalTokens = 360,
                  totalCostUsd = 3 / 1000
                }
    ]
