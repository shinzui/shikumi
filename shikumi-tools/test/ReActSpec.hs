-- | M2: the ReAct loop as a 'Program', driven by a mock LM. A scripted tool-call
-- then finish yields the typed answer plus a two-step trajectory; a script that
-- never finishes stops at @maxIters@ and still extracts a best-effort answer.
module ReActSpec (tests) where

import Control.Lens ((&), (.~))
import Data.Generics.Labels ()
import Data.Vector qualified as V
import Fixtures
  ( WeatherResp,
    expectedWeather,
    maxItersScript,
    promptScript,
    weatherQuestion,
    weatherRegistry,
    weatherSignature,
  )
import MockLLM (runAgent)
import Shikumi.Agent.ReAct
  ( Action (..),
    Step (..),
    Termination (..),
    Trajectory (..),
    defaultReActConfig,
    reactWithTrajectory,
  )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

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
          Left e -> assertFailure ("agent failed: " <> show e)
    ]
