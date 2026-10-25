module SystemOneIntegrationSpec (tests) where

import Baikai qualified as B
import Control.Lens ((&), (.~))
import Data.Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Effectful (runEff)
import Effectful.Dispatch.Dynamic (interpose)
import Effectful.Error.Static (runErrorNoCallStack)
import Shikumi.Adapter (stampTemperature)
import Shikumi.Decision
import Shikumi.Error
import Shikumi.LLM qualified as L
import Shikumi.LLM.Defaults
import Shikumi.Program
import Shikumi.Routing
import Shikumi.Schema (field)
import Shikumi.Testing.DecisionFixtures
import Shikumi.Testing.Responses (fixtureOptions, withTransportOptions)
import Shikumi.Testing.SystemOne
import Test.Tasty
import Test.Tasty.HUnit

reply :: Value
reply =
  object
    [ "model" .= String "jev-latest",
      "usage" .= object ["input_tokens" .= (10 :: Int), "output_tokens" .= (3 :: Int)],
      "answers"
        .= object
          [ "urgent" .= object ["type" .= String "noul", "noul" .= (0.83 :: Double)],
            "severity" .= object ["type" .= String "score", "probabilities" .= object ["0" .= (0.1 :: Double), "1" .= (0.3 :: Double), "2" .= (0.6 :: Double)], "score" .= (1.5 :: Double), "confidence" .= (0.55 :: Double), "legend" .= object ["0" .= String "Minor", "1" .= String "Disruptive", "2" .= String "Blocking"]],
            "category" .= object ["type" .= String "choice", "probabilities" .= object ["billing" .= (0.2 :: Double), "technical" .= (0.8 :: Double)], "choice" .= String "technical", "confidence" .= (0.65 :: Double)]
          ]
    ]

tests :: TestTree
tests =
  testGroup
    "SystemOne"
    [ testCase "released provider sends state and criteria; defaults exempt" $
        withSystemOneFixture reply $ \model registry requests -> do
          let defaults = emptyRequestDefaults {defaultThinking = Just B.ThinkingHigh, defaultMaxTokens = Just 100}
          result <-
            runEff . runErrorNoCallStack @ShikumiError . runRouting model . L.runLLMWith registry . withTransportOptions fixtureOptions . withRequestDefaults defaults . routeLLM $
              runProgram (Predict assessmentSig emptyParams) (Ticket (field "Checkout is unavailable."))
          case result of
            Right (Assessment _ _ _) -> pure ()
            Left err -> assertFailure (show err)
          bodies <- requests
          bodies @?= [object ["model" .= String "jev-latest", "state" .= renderDecisionState assessmentSig (Ticket (field "Checkout is unavailable.")), "questions" .= Map.fromList [(judgmentField j, questionJSON j) | j <- judgmentsOf @Assessment]]],
      testCase "explicit temperature is terminal with zero HTTP requests" $
        withSystemOneFixture reply $ \model registry requests -> do
          result <-
            runEff . runErrorNoCallStack @ShikumiError . runRouting model . L.runLLMWith registry . withTransportOptions fixtureOptions . routeLLM . interpose (\_ -> \case L.Complete m c o -> L.complete m c (stampTemperature 0.7 o); L.Stream m c o -> L.stream m c o) $
              runProgram (Predict assessmentSig emptyParams) (Ticket (field "x"))
          assertBool "terminal refusal" (case result of Left (SchemaMismatch _) -> True; _ -> False)
          requests >>= (@?= []),
      testCase "malformed confidence is a terminal decode failure" $
        let bad = case reply of Object o -> Object (adjust (\case Object a -> Object (adjust (\case Object c -> Object (KM.delete "confidence" c); v -> v) "category" a); v -> v) "answers" o); v -> v
         in withSystemOneFixture bad $ \model registry _ -> do
              result <-
                runEff . runErrorNoCallStack @ShikumiError . runRouting model . L.runLLMWith registry . withTransportOptions fixtureOptions . routeLLM $
                  runProgram (Predict assessmentSig emptyParams) (Ticket (field "x"))
              assertBool "InvalidJSON" (case result of Left (InvalidJSON _) -> True; _ -> False)
    ]

adjust f k o = maybe o (\v -> KM.insert k (f v) o) (KM.lookup k o)
