module DecisionReplaySpec (tests) where

import Data.Map.Strict qualified as Map
import Data.Vector qualified as V
import Effectful (runEff)
import Effectful.Error.Static (runErrorNoCallStack)
import Effectful.Prim (runPrim)
import Shikumi.Decision
import Shikumi.Decision.Setting
import Shikumi.Effect.Time (runTime)
import Shikumi.Error (ShikumiError)
import Shikumi.Program
import Shikumi.Routing
import Shikumi.Schema (field)
import Shikumi.Testing.DecisionFixtures
import Shikumi.Testing.StubLLM (runStubLLM)
import Shikumi.Testing.SystemOne
import Shikumi.Trace (runTrace, tracedLLM)
import Shikumi.Trace.Replay (runLLMReplay)
import Shikumi.Trace.Store (replayIndex)
import Test.Tasty
import Test.Tasty.HUnit

tests :: TestTree
tests =
  testGroup
    "Decision replay"
    [ testCase "new settings derive a different answer from a recorded response" $ do
        let program = Predict assessmentSig emptyParams
            input = Ticket (field "x")
            responder = systemOneResponder (const [("urgent", FieldNoul (NoulEvidence 0.6)), ("severity", FieldScore (ScoreEvidence (V.fromList [0.1, 0.3, 0.6]) Nothing)), ("category", FieldChoice (ChoiceEvidence (Map.fromList [("billing", 0.2), ("technical", 0.8)]) Nothing))])
        recorded <- runEff . runPrim . runTime . runErrorNoCallStack @ShikumiError . runRouting (systemOneModel "jev-latest") . runTrace . runStubLLM responder . tracedLLM . routeLLM $ runProgram program input
        case recorded of
          Left err -> assertFailure (show err)
          Right (before, tree) -> case replayIndex tree of
            Left err -> assertFailure (show err)
            Right index -> do
              replayed <-
                runEff . runErrorNoCallStack @ShikumiError . runRouting (systemOneModel "jev-latest") . runLLMReplay index . routeLLM $
                  runProgram (mapParams (setDecisionSetting "severity" (ScoreSetting [0.5, 1.6])) program) input
              case replayed of
                Left err -> assertFailure (show err)
                Right after -> assertBool "cuts affect replayed level" (after /= before)
    ]
