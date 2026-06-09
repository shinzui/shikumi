-- | Exercises the worked example from the 'Shikumi.Eval' module header end-to-end
-- under a mock LM, so the documented usage is guaranteed to compile and run. The
-- single import 'Shikumi.Eval' must expose everything the snippet needs.
module DocSpec (tests) where

import Effectful (runEff)
import Effectful.Concurrent (runConcurrent)
import Effectful.Error.Static (runErrorNoCallStack)
import EvalFixtures (Answer (..), Question (..), answerResponse, qaProg, runConstLLM)
import Shikumi.Effect.Time (runTime)
import Shikumi.Error (ShikumiError)
import Shikumi.Eval (aggregateScore, dataset, evaluatePure, exactMatch, example)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase)

tests :: TestTree
tests =
  testGroup
    "Doc"
    [ testCase "module-header example runs under a mock" $ do
        -- The mock answers "4" for every call, so one of the two examples
        -- matches its expected answer: an aggregate score of 0.5.
        let qaData =
              dataset
                [ example (Question "What is 2+2?") (Answer "4"),
                  example (Question "Capital of France?") (Answer "Paris")
                ]
        result <-
          runEff . runTime . runConcurrent . runErrorNoCallStack @ShikumiError $
            runConstLLM (answerResponse "4") $
              evaluatePure qaData exactMatch qaProg
        case result of
          Left e -> assertFailure ("unexpected error: " <> show e)
          Right report ->
            assertBool
              ("expected ~0.5, got " <> show (aggregateScore report))
              (abs (aggregateScore report - 0.5) < 1e-9)
    ]
