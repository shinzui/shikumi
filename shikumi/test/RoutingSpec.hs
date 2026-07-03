{-# LANGUAGE TypeApplications #-}

-- | EP-14 acceptance: ambient model routing and live native structured output.
--
-- Every test installs a /capturing stub/ @LLM@ that records the @(Model, Options)@
-- of each outgoing request, with the production router @routeLLM@ above it and a
-- 'runRouting' supplying the ambient model. No network, no API key. The same
-- assertions fail against the pre-EP-14 code (model id @""@, no @responseFormat@,
-- identical temperatures).
module RoutingSpec (tests) where

import Baikai
  ( AssistantContent (..),
    Context,
    Message (..),
    Model,
    Options,
    ResponseFormat (..),
    TextContent (..),
    _Model,
  )
import Baikai.Models.Generated (openai_gpt_4o_mini)
import Control.Lens ((^.))
import Data.Aeson (Value (..), eitherDecodeStrict, object, (.=))
import Data.Aeson.KeyMap qualified as KM
import Data.Generics.Labels ()
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List (nub, sort)
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (encodeUtf8)
import Data.Vector qualified as V
import Effectful (Eff, IOE, liftIO, runEff, type (:>))
import Effectful.Concurrent (runConcurrent)
import Effectful.Dispatch.Dynamic (interpret)
import Effectful.Error.Static (runErrorNoCallStack)
import ProgramFixtures (Outline, Topic (..), outlineResponse, topicToOutline)
import Shikumi.Adapter (metaNativeDemosKey, metaNativePromptKey, metaResponseSchemaKey, metaTemperatureKey)
import Shikumi.Combinator (majorityVote)
import Shikumi.Error (ShikumiError)
import Shikumi.LLM (LLM (..), Response)
import Shikumi.Module (predict)
import Shikumi.Program
  ( Demo (..),
    Params (..),
    Program (Predict),
    TempSchedule (..),
    runProgram,
    runProgramConc,
  )
import Shikumi.Routing (routeLLM, runRouting)
import Shikumi.Schema (deriveSchema)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Routing"
    [ routesModelId,
      nativeAttachesSchema,
      fallbackLeavesSchemaUnset,
      nativeReceivesNativeGuide,
      nativeReceivesJsonDemos,
      fallbackPromptUnchangedAndStampsStripped,
      spreadSetsDistinctTemps,
      fixedSetsExactTemps,
      concurrentAgreesOnTemps
    ]

-- ---------------------------------------------------------------------------
-- Capturing stub + run helpers
-- ---------------------------------------------------------------------------

-- | A base @LLM@ interpreter that records every request's @(Model, Context,
-- Options)@ (the 'Context' so a test can assert the prompt and demo turns that
-- reached the wire) and returns a fixed response.
runCapturingLLM ::
  (IOE :> es) =>
  IORef [(Model, Context, Options)] ->
  Response ->
  Eff (LLM : es) a ->
  Eff es a
runCapturingLLM ref resp = interpret $ \_ -> \case
  Complete m ctx o -> do
    liftIO (modifyIORef' ref (++ [(m, ctx, o)]))
    pure resp
  Stream _ _ _ -> pure []

-- | Run a program sequentially under @routeLLM . runRouting model@ over a capturing
-- stub and return the captured requests.
captureRouted :: Model -> Program Topic Outline -> Topic -> IO [(Model, Context, Options)]
captureRouted model prog input = do
  ref <- newIORef []
  res <-
    runEff
      . runErrorNoCallStack @ShikumiError
      . runRouting model
      . runCapturingLLM ref outlineResponse
      . routeLLM
      $ runProgram prog input
  assertBool "routed program decodes without error" (isRight res)
  readIORef ref

-- | As 'captureRouted' but under the concurrent executor.
captureRoutedConc :: Model -> Program Topic Outline -> Topic -> IO [(Model, Context, Options)]
captureRoutedConc model prog input = do
  ref <- newIORef []
  res <-
    runEff
      . runErrorNoCallStack @ShikumiError
      . runConcurrent
      . runRouting model
      . runCapturingLLM ref outlineResponse
      . routeLLM
      $ runProgramConc prog input
  assertBool "routed program decodes without error" (isRight res)
  readIORef ref

isRight :: Either a b -> Bool
isRight = either (const False) (const True)

-- | The assistant-turn texts of a captured 'Context', in order.
assistantTexts :: Context -> [Text]
assistantTexts ctx =
  [ t
  | AssistantMessage p <- V.toList (ctx ^. #messages),
    AssistantText (TextContent t) <- V.toList (p ^. #content)
  ]

-- ---------------------------------------------------------------------------
-- M1 — the ambient model id reaches the wire
-- ---------------------------------------------------------------------------

routesModelId :: TestTree
routesModelId =
  testCase "routes the ambient model id onto the wire" $ do
    captured <- captureRouted openai_gpt_4o_mini (predict topicToOutline) (Topic "cats")
    map (\(m, _, _) -> m ^. #modelId) captured @?= [openai_gpt_4o_mini ^. #modelId]

-- ---------------------------------------------------------------------------
-- M2 — native responseFormat on the wire; fallback leaves it unset
-- ---------------------------------------------------------------------------

nativeAttachesSchema :: TestTree
nativeAttachesSchema =
  testCase "native model attaches responseFormat with the derived schema" $ do
    captured <- captureRouted openai_gpt_4o_mini (predict topicToOutline) (Topic "cats")
    case captured of
      [(_, _, o)] -> do
        o ^. #responseFormat
          @?= Just (JsonSchema {name = "output", schema = deriveSchema @Outline, strict = True})
        assertBool
          "private schema key stripped before transport"
          (Map.notMember metaResponseSchemaKey (o ^. #metadata))
      other -> assertBool ("expected exactly one request, got " <> show (length other)) False

fallbackLeavesSchemaUnset :: TestTree
fallbackLeavesSchemaUnset =
  testCase "fallback model leaves responseFormat unset" $ do
    captured <- captureRouted _Model (predict topicToOutline) (Topic "cats")
    case captured of
      [(_, _, o)] -> do
        o ^. #responseFormat @?= Nothing
        assertBool
          "private schema key stripped before transport"
          (Map.notMember metaResponseSchemaKey (o ^. #metadata))
      other -> assertBool ("expected exactly one request, got " <> show (length other)) False

-- ---------------------------------------------------------------------------
-- EP-33 — native render channel: the native prompt and JSON demos reach the wire
-- for native-capable models; fallback models keep the marker prompt; stamps stripped
-- ---------------------------------------------------------------------------

nativeReceivesNativeGuide :: TestTree
nativeReceivesNativeGuide =
  testCase "native model receives the native output guide, not the marker guide" $ do
    captured <- captureRouted openai_gpt_4o_mini (predict topicToOutline) (Topic "cats")
    case captured of
      [(_, ctx, _)] -> do
        let sys = maybe "" id (ctx ^. #systemPrompt)
        assertBool
          "system prompt contains the native JSON guide"
          ("Reply with a JSON object containing these fields:" `T.isInfixOf` sys)
        assertBool
          "system prompt carries no marker sections"
          (not ("[[ ##" `T.isInfixOf` sys))
      other -> assertBool ("expected exactly one request, got " <> show (length other)) False

nativeReceivesJsonDemos :: TestTree
nativeReceivesJsonDemos =
  testCase "native model receives demo assistant turns as JSON objects" $ do
    -- Demos must be supplied through the node's Params channel — 'effectiveSignature'
    -- overwrites any signature-level demos with the Params ones. Stored as JSON and
    -- decoded back into typed Topic/Outline demos before rendering.
    let demo =
          Demo
            (object ["subject" .= ("dogs" :: Text)])
            (object ["points" .= (["one", "two"] :: [Text])])
        node = Predict topicToOutline (Params Nothing [demo])
    captured <- captureRouted openai_gpt_4o_mini node (Topic "cats")
    case captured of
      [(_, ctx, _)] -> case assistantTexts ctx of
        (demoText : _) -> do
          assertBool
            "demo turn carries no marker sections"
            (not ("[[ ##" `T.isInfixOf` demoText))
          case eitherDecodeStrict (encodeUtf8 demoText) of
            Right (Object o) ->
              assertBool "demo JSON object carries the points field" (KM.member "points" o)
            other -> assertBool ("demo turn is not a JSON object: " <> show other) False
        [] -> assertBool "expected a demo assistant turn on the wire" False
      other -> assertBool ("expected exactly one request, got " <> show (length other)) False

fallbackPromptUnchangedAndStampsStripped :: TestTree
fallbackPromptUnchangedAndStampsStripped =
  testCase "fallback model keeps the marker prompt and native stamps are stripped" $ do
    captured <- captureRouted _Model (predict topicToOutline) (Topic "cats")
    case captured of
      [(_, ctx, o)] -> do
        let sys = maybe "" id (ctx ^. #systemPrompt)
        assertBool
          "system prompt keeps the marker guide"
          ("Reply using these sections" `T.isInfixOf` sys)
        o ^. #responseFormat @?= Nothing
        assertBool
          "native prompt key stripped before transport"
          (Map.notMember metaNativePromptKey (o ^. #metadata))
        assertBool
          "native demos key stripped before transport"
          (Map.notMember metaNativeDemosKey (o ^. #metadata))
      other -> assertBool ("expected exactly one request, got " <> show (length other)) False

-- ---------------------------------------------------------------------------
-- M3 — per-sample temperature from MajorityVote's TempSchedule
-- ---------------------------------------------------------------------------

capturedTemps :: [(Model, Context, Options)] -> [Double]
capturedTemps = mapMaybe (\(_, _, o) -> o ^. #temperature)

spreadSetsDistinctTemps :: TestTree
spreadSetsDistinctTemps =
  testCase "majorityVote spread sets distinct per-sample temperatures" $ do
    captured <-
      captureRouted openai_gpt_4o_mini (majorityVote 3 (TempSpread 0.5 0.4) (predict topicToOutline)) (Topic "cats")
    let temps = capturedTemps captured
    length temps @?= 3
    assertBool "temperatures are not all equal" (length (nub temps) > 1)
    map round3 (sort temps) @?= [0.1, 0.5, 0.9]
    assertBool
      "private temperature key stripped before transport"
      (all (\(_, _, o) -> Map.notMember metaTemperatureKey (o ^. #metadata)) captured)

fixedSetsExactTemps :: TestTree
fixedSetsExactTemps =
  testCase "majorityVote fixed schedule sets exactly the listed temperatures" $ do
    captured <-
      captureRouted openai_gpt_4o_mini (majorityVote 2 (TempFixed [0.1, 0.9]) (predict topicToOutline)) (Topic "cats")
    sort (capturedTemps captured) @?= [0.1, 0.9]

concurrentAgreesOnTemps :: TestTree
concurrentAgreesOnTemps =
  testCase "runProgramConc produces the same temperature multiset" $ do
    captured <-
      captureRoutedConc openai_gpt_4o_mini (majorityVote 3 (TempSpread 0.5 0.4) (predict topicToOutline)) (Topic "cats")
    let temps = capturedTemps captured
    length temps @?= 3
    map round3 (sort temps) @?= [0.1, 0.5, 0.9]

-- | Round to three decimal places to compare 'TempSpread' floating-point output.
round3 :: Double -> Double
round3 d = fromIntegral (round (d * 1000) :: Integer) / 1000
