-- | The plan's primary acceptance: @evaluate@ end-to-end against a mock LM, with
-- no network. Three cases — a four-of-five exact-match run scoring 0.8; a
-- program error scored 0 under the default 'FailScore' policy while the run
-- completes; and the same error aborting the run under 'FailAbort'.
module EvaluateSpec (tests) where

import Effectful (runEff)
import Effectful.Concurrent (runConcurrent)
import Effectful.Error.Static (runErrorNoCallStack)
import Effectful.Prim (runPrim)
import EvalFixtures
  ( Answer (..),
    MockReply (..),
    Question (..),
    answerResponse,
    qaProg,
    runConstLLM,
    runScriptedLLM,
  )
import Shikumi.Effect.Time (runTime)
import Shikumi.Error (ShikumiError (..))
import Shikumi.Eval.Evaluate (evaluatePure, evaluateWith)
import Shikumi.Eval.Metric (exactMatch, liftMetric)
import Shikumi.Eval.Report
  ( EvalConfig (..),
    ExampleResult (..),
    FailurePolicy (..),
    FailureReason (..),
    Report (..),
    defaultEvalConfig,
  )
import Shikumi.Eval.Types (Score, dataset, example, scoreZero)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

-- | Five questions; the program (driven by the constant mock) always answers
-- "yes", so the four examples whose expected answer is "yes" pass exactMatch and
-- the one whose expected answer is "no" fails — a 0.8 aggregate, independent of
-- evaluation order.
aggregateData :: [(Question, Answer)]
aggregateData =
  [ (Question "q1", Answer "yes"),
    (Question "q2", Answer "yes"),
    (Question "q3", Answer "yes"),
    (Question "q4", Answer "yes"),
    (Question "q5", Answer "no")
  ]

tests :: TestTree
tests =
  testGroup
    "Evaluate"
    [ testCase "four-of-five exact match -> aggregateScore 0.8" $ do
        let ds = dataset [example q a | (q, a) <- aggregateData]
        report <-
          runEff . runPrim . runTime . runConcurrent . runErrorNoCallStack @ShikumiError $
            runConstLLM (answerResponse "yes") $
              evaluatePure ds exactMatch qaProg
        case report of
          Left e -> assertFailure ("unexpected error: " <> show e)
          Right r -> do
            assertBool
              ("expected ~0.8, got " <> show (aggregateScore r))
              (abs (aggregateScore r - 0.8) < 1e-9)
            passCount r @?= 4
            failCount r @?= 0
            total r @?= 5
            length (results r) @?= 5
            map index (results r) @?= [0, 1, 2, 3, 4],
      testCase "program error -> FailScore scoreZero, run completes" $ do
        -- concurrency = 1 so the scripted replies pop in dataset order: the first
        -- example fails, the rest succeed.
        let ds = dataset [example (Question "q0") (Answer "a"), example (Question "q1") (Answer "ok")]
            replies = [MockFail providerErr, MockOk (answerResponse "ok")]
            cfg = defaultEvalConfig {concurrency = 1}
        report <-
          runEff . runPrim . runTime . runConcurrent . runErrorNoCallStack @ShikumiError $
            runScriptedLLM replies $
              evaluateWith cfg ds (liftMetric exactMatch) qaProg
        case report of
          Left e -> assertFailure ("run should not abort, but got: " <> show e)
          Right r -> do
            total r @?= 2
            failCount r @?= 1
            case results r of
              (er0 : _) -> do
                index er0 @?= 0
                score er0 @?= (scoreZero :: Score)
                case failure er0 of
                  Just (ProgramError _) -> pure ()
                  other -> assertFailure ("expected ProgramError, got " <> show other)
              [] -> assertFailure "expected two results",
      testCase "FailAbort surfaces the error" $ do
        let ds = dataset [example (Question "q0") (Answer "a"), example (Question "q1") (Answer "ok")]
            replies = [MockFail providerErr, MockOk (answerResponse "ok")]
            cfg = defaultEvalConfig {concurrency = 1, failurePolicy = FailAbort}
        report <-
          runEff . runPrim . runTime . runConcurrent . runErrorNoCallStack @ShikumiError $
            runScriptedLLM replies $
              evaluateWith cfg ds (liftMetric exactMatch) qaProg
        case report of
          Left _ -> pure ()
          Right _ -> assertFailure "expected FailAbort to surface a Left"
    ]
  where
    providerErr = ProviderFailure "boom"
