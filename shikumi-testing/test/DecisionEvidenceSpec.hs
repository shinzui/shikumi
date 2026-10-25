{-# LANGUAGE DataKinds #-}

module DecisionEvidenceSpec (tests) where

import Baikai
import Baikai.Models.Generated (openai_gpt_4o_mini)
import Control.Lens ((^.))
import Data.Aeson (Value (..), object, toJSON, (.=))
import Data.Aeson.KeyMap qualified as KM
import Data.Generics.Labels ()
import Data.IORef (newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import Effectful (runEff)
import Effectful.Error.Static (runErrorNoCallStack)
import GHC.Generics (Generic)
import Shikumi.Adapter
import Shikumi.Decision
import Shikumi.Decision.Setting
import Shikumi.Error
import Shikumi.Program
import Shikumi.Program qualified as P
import Shikumi.Routing
import Shikumi.Schema (Field, FromModel, ToSchema, Validatable, deriveSchema, field)
import Shikumi.Signature (Signature, mkSignature, setDemos)
import Shikumi.Signature qualified as Sig
import Shikumi.Stream (streamProgram)
import Shikumi.Testing.DecisionFixtures
import Shikumi.Testing.Response
import Shikumi.Testing.StubLLM
import Shikumi.Testing.SystemOne
import Test.Tasty
import Test.Tasty.HUnit

newtype Flag = Flag {flag :: Bool}
  deriving stock (Generic, Eq, Show)
  deriving anyclass (ToSchema, FromModel, ToPrompt, Validatable)

data NativeLabel = LeftSide | RightSide
  deriving stock (Generic, Eq, Show)
  deriving anyclass (ToSchema, FromModel)

newtype NativeEnum = NativeEnum {nativeLabel :: NativeLabel}
  deriving stock (Generic, Eq, Show)
  deriving anyclass (ToSchema, FromModel, ToPrompt, Validatable)

data Mixed = Mixed
  { urgent :: Noul,
    category :: Choice CalibrationLabel,
    severity :: Score '["Low", "Medium", "High"],
    summary :: Text
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (ToSchema, FromModel, ToPrompt, Validatable)

payloads :: [(Text, Value)]
payloads =
  [ ("urgent", object ["noul" .= (0.83 :: Double)]),
    ("category", object ["probabilities" .= object ["FirstLabel" .= (0.2 :: Double), "SecondLabel" .= (0.7 :: Double), "ThirdLabel" .= (0.1 :: Double)], "confidence" .= (0.9 :: Double)]),
    ("severity", object ["probabilities" .= object ["0" .= (0.1 :: Double), "1" .= (0.3 :: Double), "2" .= (0.6 :: Double)], "confidence" .= (0.8 :: Double)]),
    ("summary", String "Operational issue")
  ]

sig :: Signature Ticket Mixed
sig = mkSignature "Assess impact"

execute model builder ps =
  runEff . runErrorNoCallStack @ShikumiError . runRouting model . runStubLLM (const (builder payloads)) . routeLLM $
    runProgram (Predict sig ps) (Ticket (field "x"))

tests :: TestTree
tests =
  testGroup
    "DecisionEvidence"
    [ testCase "native and marker shapes derive identical rich values alongside text" $ do
        native <- execute openai_gpt_4o_mini evidenceJSONResponse emptyParams
        fallback <- execute emptyModel evidenceMarkerResponse emptyParams
        native @?= fallback
        case native of
          Right (Mixed (Noul answer p _) (Choice label _ _) (Score value level _ _) summary) -> do
            answer @?= True
            p @?= 0.83
            label @?= SecondLabel
            value @?= 1.5
            level @?= 2
            summary @?= "Operational issue"
          Left err -> assertFailure (show err),
      testCase "evidence schema is closed and question criteria appear in both prompts" $ do
        ref <- newIORef []
        let signature = setDemos [assessmentDemo] assessmentSig
            params = case assessmentDemo of Sig.Demo i o -> emptyParams {P.demos = [P.Demo (toJSON i) (toJSON o)]}
        result <-
          runEff . runErrorNoCallStack @ShikumiError . runRouting openai_gpt_4o_mini . runStubLLM (const (systemOneResponse [("urgent", FieldNoul (NoulEvidence 0.8)), ("category", FieldChoice (ChoiceEvidence (Map.fromList [("billing", 0.2), ("technical", 0.8)]) (Just 0.65))), ("severity", FieldScore (ScoreEvidence (V.fromList [0.1, 0.3, 0.6]) (Just 0.55)))])) . captureLLMRequests ref . routeLLM $
            runProgram (Predict signature params) (Ticket (field "x"))
        assertBool "typed success" (either (const False) (const True) result)
        requests <- readIORef ref
        case requests of
          [(_, ctx, opts)] -> do
            V.length (ctx ^. #messages) @?= 1
            assertBool "task examples and criteria in native prompt" (maybe False (\t -> all (`T.isInfixOf` t) ["Task examples (labels or evidence):", "Service unavailable", "probabilities"]) (ctx ^. #systemPrompt))
            Map.null (opts ^. #metadata) @?= True
            case opts ^. #responseFormat of
              Just (JsonSchema fmt) -> fmt ^. #schema @?= stripDecisionMarkers (evidenceSchema (deriveSchema @Assessment) (judgmentsOf @Assessment))
              _ -> assertFailure "missing schema"
          _ -> assertFailure "expected one call"
        let (markerCtx, _) = renderEvidenceRequest Map.empty signature (Ticket (field "x"))
        assertBool "criteria in marker guide" (maybe False (T.isInfixOf "Service unavailable") (markerCtx ^. #systemPrompt)),
      testCase "strict evidence rejects bad range, keys, shape and zero weighted mass" $ do
        let replace name value = map (\(key, old) -> (key, if key == name then value else old)) payloads
            bad =
              [ replace "urgent" (object ["noul" .= (1.2 :: Double)]),
                replace "urgent" (object ["noul" .= String "bad"]),
                replace "urgent" (object ["noul" .= (0.8 :: Double), "x-shikumi-derived" .= True]),
                replace "category" (object ["probabilities" .= object ["FirstLabel" .= (0.2 :: Double), "SecondLabel" .= (0.8 :: Double)], "confidence" .= (0.9 :: Double)]),
                replace "severity" (object ["probabilities" .= object ["0" .= (0.2 :: Double), "1" .= (0.3 :: Double), "2" .= (0.4 :: Double), "3" .= (0.1 :: Double)], "confidence" .= (0.9 :: Double)])
              ]
        mapM_
          ( \fields -> do
              let result = parseResponse sig (evidenceJSONResponse fields)
              assertBool "typed located error" (case result of Left (ValidationFailure msg) -> "urgent" `T.isInfixOf` msg; Left (SchemaMismatch msg) -> any (`T.isInfixOf` msg) ["urgent", "category", "severity"]; _ -> False)
          )
          bad
        zero <- execute openai_gpt_4o_mini evidenceJSONResponse (setDecisionSetting "category" (ChoiceSetting (Map.fromList [("FirstLabel", 0), ("SecondLabel", 0), ("ThirdLabel", 0)])) emptyParams)
        assertBool "zero mass error" (case zero of Left (SchemaMismatch msg) -> "category" `T.isInfixOf` msg; _ -> False),
      testCase "System One and generative evidence produce equal typed results" $ do
        let fields = [("urgent", FieldNoul (NoulEvidence 0.83)), ("category", FieldChoice (ChoiceEvidence (Map.fromList [("billing", 0.2), ("technical", 0.8)]) (Just 0.65))), ("severity", FieldScore (ScoreEvidence (V.fromList [0.1, 0.3, 0.6]) (Just 0.55)))]
            payload = \case FieldNoul e -> toJSON e; FieldChoice e -> toJSON e; FieldScore e -> toJSON e
            run model response = runEff . runErrorNoCallStack @ShikumiError . runRouting model . runStubLLM (const response) . routeLLM $ runProgram (Predict assessmentSig emptyParams) (Ticket (field "x"))
        classified <- run (systemOneModel "jev-latest") (systemOneResponse fields)
        generated <- run openai_gpt_4o_mini (evidenceJSONResponse [(k, payload e) | (k, e) <- fields])
        classified @?= generated
        assertBool "successful parity" (either (const False) (const True) classified),
      testCase "native Bool opts in only when settings are present" $ do
        let signature = mkSignature "Flag it" :: Signature Ticket Flag
            input = Ticket (field "x")
            run ps response = runEff . runErrorNoCallStack @ShikumiError . runRouting openai_gpt_4o_mini . runStubLLM (const response) . routeLLM $ runProgram (Predict signature ps) input
        run emptyParams (evidenceJSONResponse [("flag", Bool True)]) >>= (@?= Right (Flag True))
        run (setDecisionSetting "flag" (NoulSetting 0.7) emptyParams) (evidenceJSONResponse [("flag", object ["noul" .= (0.65 :: Double)])]) >>= (@?= Right (Flag False))
        evidenceFields @Flag Map.empty @?= [],
      testCase "native enums opt into evidence and weights without changing their type" $ do
        let signature = mkSignature "Choose" :: Signature Ticket NativeEnum
            input = Ticket (field "x")
            run ps response = runEff . runErrorNoCallStack @ShikumiError . runRouting openai_gpt_4o_mini . runStubLLM (const response) . routeLLM $ runProgram (Predict signature ps) input
        run emptyParams (evidenceJSONResponse [("nativeLabel", String "LeftSide")]) >>= (@?= Right (NativeEnum LeftSide))
        let ps = setDecisionSetting "nativeLabel" (ChoiceSetting (Map.singleton "LeftSide" 0)) emptyParams
            value = object ["probabilities" .= object ["LeftSide" .= (0.8 :: Double), "RightSide" .= (0.2 :: Double)], "confidence" .= (0.9 :: Double)]
        run ps (evidenceJSONResponse [("nativeLabel", value)]) >>= (@?= Right (NativeEnum RightSide))
        evidenceFields @NativeEnum Map.empty @?= [],
      testCase "decision streaming refuses before dispatch even without routing" $ do
        calls <- newIORef 0
        result <-
          runEff . runErrorNoCallStack @ShikumiError . runCountingLLM calls (evidenceJSONResponse payloads) $
            streamProgram (Predict sig emptyParams) (Ticket (field "x")) (const (pure ()))
        assertBool "typed refusal" (case result of Left (ValidationFailure _) -> True; _ -> False)
        readIORef calls >>= (@?= 0)
    ]
