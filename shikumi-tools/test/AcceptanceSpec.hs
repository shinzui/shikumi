-- | M4: the headline acceptance from the plan's Purpose, demonstrated entirely
-- against a mock LM (no live provider). It shows the four observable facts: a typed
-- 'WeatherResp' answer from a ReAct run; the recorded 'Trajectory' with the expected
-- steps and 'TerminatedFinish'; the frozen 'WeatherReq' schema; and malformed tool
-- arguments captured as a recorded 'ToolError' observation while the agent still
-- returns a typed value and throws nothing.
module AcceptanceSpec (tests) where

import Baikai (Response)
import Control.Lens ((&), (.~))
import Data.Generics.Labels ()
import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import Data.Vector qualified as V
import Fixtures
  ( WeatherResp,
    badArgsPromptScript,
    expectedReqSchema,
    expectedWeather,
    nativeScript,
    promptScript,
    weatherQuestion,
    weatherRegistry,
    weatherSignature,
    weatherTool,
  )
import MockLLM (runAgent)
import Shikumi.Agent.ReAct
  ( Action (..),
    Step (..),
    Termination (..),
    ToolProtocol (..),
    Trajectory (..),
    defaultReActConfig,
    reactWithTrajectory,
  )
import Shikumi.Tool (toolSchemaOf)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Acceptance"
    [ testCase "derived tool schema is the frozen WeatherReq schema" $
        toolSchemaOf weatherTool @?= expectedReqSchema,
      testCase "typed tool + ReAct + mock LM end-to-end (prompt protocol)" $
        endToEnd ProtocolPrompt promptScript,
      testCase "typed tool + ReAct + mock LM end-to-end (native protocol)" $
        endToEnd ProtocolNative nativeScript,
      testCase "malformed args become a recorded ToolError, no crash" $ do
        res <-
          runAgent
            badArgsPromptScript
            (reactWithTrajectory weatherSignature weatherRegistry (defaultReActConfig & #protocol .~ ProtocolPrompt))
            weatherQuestion
        case res of
          Right (o :: WeatherResp, traj) -> do
            o @?= expectedWeather
            let obs = fromMaybe "" (observation (V.head (steps traj)))
            assertBool "the bad tool call is recorded as an invalid-arguments observation" ("invalid arguments" `T.isInfixOf` obs)
          Left e -> assertFailure ("agent should recover and return, but failed: " <> show e)
    ]

-- | Run the agent under a forced protocol against a script and assert the typed
-- answer, a two-step (tool call then finish) trajectory, and a clean finish.
endToEnd :: ToolProtocol -> [Response] -> Assertion
endToEnd proto script = do
  res <-
    runAgent
      script
      (reactWithTrajectory weatherSignature weatherRegistry (defaultReActConfig & #protocol .~ proto))
      weatherQuestion
  case res of
    Right (o :: WeatherResp, traj) -> do
      o @?= expectedWeather
      termination traj @?= TerminatedFinish
      V.length (steps traj) @?= 2
      case action (V.head (steps traj)) of
        CallTool nm _ -> nm @?= "get_weather"
        other -> assertFailure ("first step should be a tool call, got " <> show other)
    Left e -> assertFailure ("agent failed: " <> show e)
