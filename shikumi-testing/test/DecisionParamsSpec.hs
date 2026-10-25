module DecisionParamsSpec (tests) where

import Data.Aeson (eitherDecode, encode)
import Data.IORef (newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Text qualified
import Data.Vector qualified as V
import Effectful (runEff)
import Effectful.Concurrent (runConcurrent)
import Effectful.Error.Static (runErrorNoCallStack)
import Shikumi.Decision
import Shikumi.Decision.Setting
import Shikumi.Error
import Shikumi.Program
import Shikumi.Routing
import Shikumi.Schema (field, unField)
import Shikumi.Testing.DecisionFixtures
import Shikumi.Testing.StubLLM
import Shikumi.Testing.SystemOne
import Test.Tasty
import Test.Tasty.HUnit

fields :: [(Data.Text.Text, FieldEvidence)]
fields = [("urgent", FieldNoul (NoulEvidence 0.6)), ("severity", FieldScore (ScoreEvidence (V.fromList [0.1, 0.3, 0.6]) Nothing)), ("category", FieldChoice (ChoiceEvidence (Map.fromList [("billing", 0.2), ("technical", 0.8)]) Nothing))]

tests :: TestTree
tests =
  testGroup
    "Decision Params"
    [ testCase "old JSON remains byte-identical and settings round-trip" $ do
        eitherDecode "{\"instructionOverride\":null,\"demos\":[]}" @?= Right emptyParams
        encode emptyParams @?= "{\"demos\":[],\"instructionOverride\":null}"
        let ps = setDecisionSetting "urgent" (NoulSetting 0.7) emptyParams
        eitherDecode (encode ps) @?= Right ps,
      testCase "threshold, cuts and weights change typed values in both executors" $ do
        let ps = setDecisionSetting "urgent" (NoulSetting 0.7) $ setDecisionSetting "severity" (ScoreSetting [0.5, 1.6]) $ setDecisionSetting "category" (ChoiceSetting (Map.singleton "technical" 0)) emptyParams
            program = Predict assessmentSig ps
        result <- runEff . runConcurrent . runErrorNoCallStack @ShikumiError . runRouting (systemOneModel "jev-latest") . runStubLLM (systemOneResponder (const fields)) . routeLLM $ do
          a <- runProgram program (Ticket (field "x"))
          b <- runProgramConc program (Ticket (field "x"))
          pure (a, b)
        case result of
          Right (a@(Assessment u s c), b) -> do
            a @?= b
            case unField u of Noul answer _ _ -> answer @?= False
            case unField s of Score mean lev _ _ -> do mean @?= 1.5; lev @?= 1
            case unField c of Choice answer _ _ -> answer @?= Billing
          Left err -> assertFailure (show err),
      testCase "invalid settings fail before any model call" $ do
        seen <- newIORef []
        result <-
          runEff . runErrorNoCallStack @ShikumiError . runStubLLM (systemOneResponder (const fields)) . captureLLMRequests seen $
            runProgram (Predict assessmentSig (setDecisionSetting "urgent" (NoulSetting 1.5) emptyParams)) (Ticket (field "x"))
        assertBool "ValidationFailure" (case result of Left (ValidationFailure _) -> True; _ -> False)
        readIORef seen >>= (@?= [])
    ]
