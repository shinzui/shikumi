{-# LANGUAGE OverloadedStrings #-}

-- | M3: the native-vs-prompt protocol seam. The same @react@ program reaches the
-- same typed answer under either forced protocol, and 'ProtocolAuto' resolves
-- conservatively (a CLI model — whose tools baikai silently drops — picks the
-- prompt path; a native-capable model picks the native path).
module ProtocolSpec (tests) where

import Baikai (Api (..), emptyModel)
import Control.Lens ((&), (.~))
import Data.Aeson (object, (.=))
import Data.Generics.Labels ()
import Data.Text (Text)
import Data.Vector qualified as V
import Fixtures
  ( WeatherResp,
    expectedWeather,
    nativeScript,
    promptScript,
    weatherQuestion,
    weatherRegistry,
    weatherSignature,
  )
import MockLLM (mkTextResponse, mkToolCallsResponse, runAgent)
import Shikumi.Agent.ReAct
  ( Action (..),
    Step (..),
    Termination (..),
    ToolProtocol (..),
    Trajectory (..),
    defaultReActConfig,
    reactWithTrajectory,
    resolveProtocolKind,
  )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Protocol"
    [ testCase "native and prompt paths agree on the typed answer" $ do
        nat <-
          runAgent
            nativeScript
            (reactWithTrajectory weatherSignature weatherRegistry (defaultReActConfig & #protocol .~ ProtocolNative))
            weatherQuestion
        pro <-
          runAgent
            promptScript
            (reactWithTrajectory weatherSignature weatherRegistry (defaultReActConfig & #protocol .~ ProtocolPrompt))
            weatherQuestion
        case (nat, pro) of
          (Right (oN :: WeatherResp, tN), Right (oP, tP)) -> do
            oN @?= expectedWeather
            oP @?= expectedWeather
            termination tN @?= TerminatedFinish
            termination tP @?= TerminatedFinish
            V.length (steps tN) @?= 2
            V.length (steps tP) @?= 2
          _ -> assertFailure "both protocols should succeed",
      testCase "ProtocolAuto picks prompt for a CLI model" $
        resolveProtocolKind ProtocolAuto (emptyModel & #api .~ AnthropicMessagesCli) @?= ProtocolPrompt,
      testCase "ProtocolAuto picks native for a native-capable model" $
        resolveProtocolKind ProtocolAuto (emptyModel & #provider .~ "openai" & #api .~ OpenAIChatCompletions) @?= ProtocolNative,
      testCase "native turn with two tool calls executes both in order" $ do
        let parisArgs = object ["city" .= ("Paris" :: Text), "units" .= ("c" :: Text)]
            londonArgs = object ["city" .= ("London" :: Text), "units" .= ("c" :: Text)]
            script =
              [ mkToolCallsResponse [("c1", "get_weather", parisArgs), ("c2", "get_weather", londonArgs)],
                mkTextResponse "done",
                mkTextResponse "{\"tempC\": 12.0, \"summary\": \"mild\"}"
              ]
        out <-
          runAgent
            script
            (reactWithTrajectory weatherSignature weatherRegistry (defaultReActConfig & #protocol .~ ProtocolNative))
            weatherQuestion
        case out of
          Right (answer :: WeatherResp, traj) -> do
            answer @?= expectedWeather
            termination traj @?= TerminatedFinish
            case V.toList (steps traj) of
              [s1, s2, s3] -> do
                action s1 @?= CallTool "get_weather" parisArgs
                action s2 @?= CallTool "get_weather" londonArgs
                action s3 @?= Finish
              other -> assertFailure ("expected two tool-call steps followed by finish, got " <> show other)
          Left err -> assertFailure ("native multi-call run failed: " <> show err)
    ]
