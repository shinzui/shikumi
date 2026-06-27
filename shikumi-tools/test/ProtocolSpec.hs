{-# LANGUAGE OverloadedStrings #-}

-- | M3: the native-vs-prompt protocol seam. The same @react@ program reaches the
-- same typed answer under either forced protocol, and 'ProtocolAuto' resolves
-- conservatively (a CLI model — whose tools baikai silently drops — picks the
-- prompt path; a native-capable model picks the native path).
module ProtocolSpec (tests) where

import Baikai (Api (..), _Model)
import Control.Lens ((&), (.~))
import Data.Generics.Labels ()
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
import MockLLM (runAgent)
import Shikumi.Agent.ReAct
  ( Termination (..),
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
        resolveProtocolKind ProtocolAuto (_Model & #api .~ AnthropicMessagesCli) @?= ProtocolPrompt,
      testCase "ProtocolAuto picks native for a native-capable model" $
        resolveProtocolKind ProtocolAuto (_Model & #provider .~ "openai" & #api .~ OpenAIChatCompletions) @?= ProtocolNative
    ]
