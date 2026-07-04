{-# LANGUAGE OverloadedStrings #-}

-- | M2: the ReAct loop as a 'Program', driven by a mock LM. A scripted tool-call
-- then finish yields the typed answer plus a two-step trajectory; a script that
-- never finishes stops at @maxIters@ and still extracts a best-effort answer.
module ReActSpec (tests) where

import Baikai (Response)
import Control.Lens ((&), (.~))
import Data.Generics.Labels ()
import Data.Text qualified as T
import Data.Vector qualified as V
import Effectful.Error.Static (throwError)
import Fixtures
  ( WeatherReq,
    WeatherResp,
    expectedWeather,
    maxItersScript,
    promptScript,
    weatherQuestion,
    weatherRegistry,
    weatherSignature,
  )
import MockLLM (mkTextResponse, runAgent)
import Shikumi.Agent.ReAct
  ( Action (..),
    Step (..),
    Termination (..),
    Trajectory (..),
    defaultReActConfig,
    reactWithTrajectory,
  )
import Shikumi.Error (ShikumiError (..))
import Shikumi.Tool (SomeTool (..), Tool, ToolRegistry, mkRegistry, mkTool)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

budgetTool :: Tool WeatherReq WeatherResp
budgetTool =
  mkTool "burn_budget" "Always exceeds the budget." $ \_req ->
    throwError (BudgetExceeded "ceiling reached")

flakyTool :: Tool WeatherReq WeatherResp
flakyTool =
  mkTool "flaky" "Always fails validation." $ \_req ->
    throwError (ValidationFailure "nothing to see")

budgetRegistry :: ToolRegistry
budgetRegistry = mkRegistry [SomeTool budgetTool]

flakyRegistry :: ToolRegistry
flakyRegistry = mkRegistry [SomeTool flakyTool]

extractReply :: T.Text
extractReply = "{\"tempC\": 12.0, \"summary\": \"mild\"}"

finishReply :: T.Text
finishReply = "{\"thought\": \"I have the forecast.\", \"action\": {\"finish\": true}}"

proposeBudgetReply :: T.Text
proposeBudgetReply =
  "{\"thought\": \"I should spend.\", \"action\": {\"tool\": \"burn_budget\", \"args\": {\"city\": \"Paris\", \"units\": \"c\"}}}"

proposeFlakyReply :: T.Text
proposeFlakyReply =
  "{\"thought\": \"I should try a flaky lookup.\", \"action\": {\"tool\": \"flaky\", \"args\": {\"city\": \"Paris\", \"units\": \"c\"}}}"

budgetScript :: [Response]
budgetScript =
  [ mkTextResponse proposeBudgetReply,
    mkTextResponse finishReply,
    mkTextResponse extractReply
  ]

flakyScript :: [Response]
flakyScript =
  [ mkTextResponse proposeFlakyReply,
    mkTextResponse finishReply,
    mkTextResponse extractReply
  ]

tests :: TestTree
tests =
  testGroup
    "ReAct"
    [ testCase "runs tool then finish; returns typed answer + trajectory" $ do
        res <-
          runAgent
            promptScript
            (reactWithTrajectory weatherSignature weatherRegistry defaultReActConfig)
            weatherQuestion
        case res of
          Right (o :: WeatherResp, traj) -> do
            o @?= expectedWeather
            termination traj @?= TerminatedFinish
            V.length (steps traj) @?= 2
            case V.toList (steps traj) of
              [s1, s2] -> do
                case action s1 of
                  CallTool nm _ -> nm @?= "get_weather"
                  other -> assertFailure ("step 1 should be a tool call, got " <> show other)
                assertBool "tool step records an observation" (observation s1 /= Nothing)
                action s2 @?= Finish
              _ -> assertFailure "expected exactly two steps"
          Left e -> assertFailure ("agent failed: " <> show e),
      testCase "stops at maxIters with TerminatedMaxIters" $ do
        let cfg = defaultReActConfig & #maxIters .~ 1
        res <-
          runAgent
            maxItersScript
            (reactWithTrajectory weatherSignature weatherRegistry cfg)
            weatherQuestion
        case res of
          Right (o :: WeatherResp, traj) -> do
            termination traj @?= TerminatedMaxIters 1
            o @?= expectedWeather
          Left e -> assertFailure ("agent failed: " <> show e),
      testCase "a tool throwing BudgetExceeded aborts the loop" $ do
        res <-
          runAgent
            budgetScript
            (reactWithTrajectory weatherSignature budgetRegistry defaultReActConfig)
            weatherQuestion
        case res of
          Left (BudgetExceeded msg) -> msg @?= "ceiling reached"
          other -> assertFailure ("expected escaped BudgetExceeded, got " <> show other),
      testCase "a tool throwing a recoverable error yields an observation and the loop continues" $ do
        res <-
          runAgent
            flakyScript
            (reactWithTrajectory weatherSignature flakyRegistry defaultReActConfig)
            weatherQuestion
        case res of
          Right (o :: WeatherResp, traj) -> do
            o @?= expectedWeather
            termination traj @?= TerminatedFinish
            case V.toList (steps traj) of
              (Step {action = CallTool nm _, observation = Just obs} : _) -> do
                nm @?= "flaky"
                assertBool "observation is a rendered tool failure" ("failed" `T.isInfixOf` obs)
                assertBool "observation includes validation reason" ("nothing to see" `T.isInfixOf` obs)
              other -> assertFailure ("expected first step to be flaky tool call with observation, got " <> show other)
          Left e -> assertFailure ("agent failed: " <> show e)
    ]
