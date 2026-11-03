module DecisionReplaySpec (tests) where

import Baikai qualified as B
import Control.Lens ((^.))
import Data.Aeson (eitherDecode, encode)
import Data.Generics.Labels ()
import Data.Map.Strict qualified as Map
import Data.Vector qualified as V
import Effectful (runEff)
import Effectful.Dispatch.Dynamic (interpret)
import Effectful.Error.Static (runErrorNoCallStack)
import Effectful.Exception (try)
import Effectful.Prim (runPrim)
import Shikumi.Decision
import Shikumi.Decision.Setting
import Shikumi.Effect.Time (runTime)
import Shikumi.Error (ShikumiError)
import Shikumi.LLM (LLM (..))
import Shikumi.LLM qualified
import Shikumi.Program
import Shikumi.Routing
import Shikumi.Schema (field)
import Shikumi.Stream
import Shikumi.Testing.DecisionFixtures
import Shikumi.Testing.Response (mkTextResponse)
import Shikumi.Testing.SystemOne
import Shikumi.Trace (runTrace, tracedLLM)
import Shikumi.Trace.Replay (ReplayDivergence, runLLMReplay)
import Shikumi.Trace.Store (replayIndex)
import Test.Tasty
import Test.Tasty.HUnit

tests :: TestTree
tests =
  testGroup "Decision replay" $
    [ testCase ("capture " ++ show capturedStream ++ ", replay " ++ show replayStream) $ do
        let program = Predict assessmentSig emptyParams
            input = Ticket (field "x")
            response = systemOneResponse [("urgent", FieldNoul (NoulEvidence 0.6)), ("severity", FieldScore (ScoreEvidence (V.fromList [0.1, 0.3, 0.6]) (Just 0.55))), ("category", FieldChoice (ChoiceEvidence (Map.fromList [("billing", 0.2), ("technical", 0.8)]) (Just 0.65)))]
            execute streaming p = if streaming then streamProgram p input (const (pure ())) else runProgram p input
            handler = interpret $ \_ -> \case
              Complete {} -> pure response
              Stream {} -> maybe (error "fixture") pure (atomicEventsFromResponse response)
        recorded <- runEff . runPrim . runTime . runErrorNoCallStack @ShikumiError . runRouting (systemOneModel "jev-latest") . runTrace . handler . tracedLLM . routeLLM $ execute capturedStream program
        case recorded of
          Left err -> assertFailure (show err)
          Right (before, tree) -> do
            -- Serialization is part of acceptance, including distributions,
            -- confidence and method. The response codec deliberately drops evidence.
            eitherDecode (encode response) @?= Right response
            restored <- either assertFailure pure (eitherDecode (encode tree))
            case replayIndex restored of
              Left err -> assertFailure (show err)
              Right index -> do
                replayed <- runEff . runErrorNoCallStack @ShikumiError . runRouting (systemOneModel "jev-latest") . runLLMReplay index . routeLLM $ execute replayStream program
                replayed @?= Right before
                calibrated <-
                  runEff . runErrorNoCallStack @ShikumiError . runRouting (systemOneModel "jev-latest") . runLLMReplay index . routeLLM $
                    execute replayStream (mapParams (setDecisionSetting "severity" (ScoreSetting [0.5, 1.6])) program)
                case calibrated of
                  Left err -> assertFailure (show err)
                  Right after -> assertBool "cuts rederive level" (after /= before)
    | capturedStream <- [False, True],
      replayStream <- [False, True]
    ]
      ++ [ testCase "text-only recording cannot become a structured stream" $ do
             let text = mkTextResponse "hello"
             atomicEventsFromResponse text @?= Nothing
             result <- runEff . try @ReplayDivergence . runLLMReplay Map.empty $ B.emptyResponse <$ Shikumi.LLM.stream B.emptyModel B.emptyContext B.emptyOptions
             assertBool "divergence" (case result of Left _ -> True; _ -> False)
         ]
