module SystemOneIntegrationSpec (tests) where

import Baikai qualified as B
import Data.Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
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
import Shikumi.Schema (field, unField)
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
            Right (Assessment u s c) -> do
              case unField u of Noul value p _ -> do value @?= True; p @?= 0.83
              case unField s of Score value level _ confidence -> do value @?= 1.5; level @?= 2; confidence @?= Just 0.55
              case unField c of Choice value _ confidence -> do value @?= Technical; confidence @?= Just 0.65
            Left err -> assertFailure (show err)
          bodies <- requests
          bodies @?= [object ["model" .= String "jev-latest", "state" .= renderDecisionState assessmentSig (Ticket (field "Checkout is unavailable.")), "questions" .= Map.fromList [(judgmentField j, questionJSON j) | j <- judgmentsOf @Assessment]]],
      testCase "explicit temperature is terminal with zero HTTP requests" $
        withSystemOneFixture reply $ \model registry requests -> do
          result <-
            runEff . runErrorNoCallStack @ShikumiError . runRouting model . L.runLLMWith registry . withTransportOptions fixtureOptions . routeLLM . interpose (\_ -> \case L.Complete m c o -> L.complete m c (stampTemperature 0.7 o); L.Stream m c o -> L.stream m c o) $
              runProgram (Predict assessmentSig emptyParams) (Ticket (field "x"))
          assertBool "terminal refusal" (case result of Left (SchemaMismatch msg) -> "temperature" `T.isInfixOf` msg; _ -> False)
          requests >>= (@?= []),
      testCase "missing wire evidence or undeclared answers fail after one HTTP request" $ do
        let modifyAnswer name f = modifyObject "answers" (adjust (\case Object o -> Object (f o); v -> v) name) reply
            malformed = [modifyAnswer "category" (KM.delete "confidence"), modifyAnswer "severity" (KM.delete "score"), modifyAnswer "severity" (KM.delete "legend"), modifyObject "answers" (KM.insert "unexpected" (object ["type" .= String "noul", "noul" .= (0.5 :: Double)])) reply]
        mapM_
          ( \bad -> withSystemOneFixture bad $ \model registry requests -> do
              result <-
                runEff . runErrorNoCallStack @ShikumiError . runRouting model . L.runLLMWith registry . withTransportOptions fixtureOptions . routeLLM $
                  runProgram (Predict assessmentSig emptyParams) (Ticket (field "x"))
              assertBool "terminal InvalidJSON" (case result of Left (InvalidJSON _) -> True; _ -> False)
              requests >>= (\xs -> length xs @?= 1)
          )
          malformed
    ]

adjust :: (a -> a) -> Key -> KM.KeyMap a -> KM.KeyMap a
adjust f k o = maybe o (\v -> KM.insert k (f v) o) (KM.lookup k o)

modifyObject :: Key -> (KM.KeyMap Value -> KM.KeyMap Value) -> Value -> Value
modifyObject key f (Object fields) = Object (adjust (\case Object o -> Object (f o); v -> v) key fields)
modifyObject _ _ v = v
