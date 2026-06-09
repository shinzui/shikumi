{-# LANGUAGE TypeApplications #-}

-- | EP-14 acceptance: ambient model routing and live native structured output.
--
-- Every test installs a /capturing stub/ @LLM@ that records the @(Model, Options)@
-- of each outgoing request, with the production router @routeLLM@ above it and a
-- 'runRouting' supplying the ambient model. No network, no API key. The same
-- assertions fail against the pre-EP-14 code (model id @""@, no @responseFormat@,
-- identical temperatures).
module RoutingSpec (tests) where

import Baikai (Model, Options, ResponseFormat (..), _Model)
import Baikai.Models.Generated (openai_gpt_4o_mini)
import Control.Lens ((^.))
import Data.Generics.Labels ()
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List (nub, sort)
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Effectful (Eff, IOE, liftIO, runEff, type (:>))
import Effectful.Concurrent (runConcurrent)
import Effectful.Dispatch.Dynamic (interpret)
import Effectful.Error.Static (runErrorNoCallStack)
import ProgramFixtures (Outline, Topic (..), outlineResponse, topicToOutline)
import Shikumi.Adapter (metaResponseSchemaKey, metaTemperatureKey)
import Shikumi.Combinator (majorityVote)
import Shikumi.Error (ShikumiError)
import Shikumi.LLM (LLM (..), Response)
import Shikumi.Module (predict)
import Shikumi.Program (Program, TempSchedule (..), runProgram, runProgramConc)
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
      spreadSetsDistinctTemps,
      fixedSetsExactTemps,
      concurrentAgreesOnTemps
    ]

-- ---------------------------------------------------------------------------
-- Capturing stub + run helpers
-- ---------------------------------------------------------------------------

-- | A base @LLM@ interpreter that records every request's @(Model, Options)@ and
-- returns a fixed response.
runCapturingLLM ::
  (IOE :> es) =>
  IORef [(Model, Options)] ->
  Response ->
  Eff (LLM : es) a ->
  Eff es a
runCapturingLLM ref resp = interpret $ \_ -> \case
  Complete m _ o -> do
    liftIO (modifyIORef' ref (++ [(m, o)]))
    pure resp
  Stream _ _ _ -> pure []

-- | Run a program sequentially under @routeLLM . runRouting model@ over a capturing
-- stub and return the captured requests.
captureRouted :: Model -> Program Topic Outline -> Topic -> IO [(Model, Options)]
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
captureRoutedConc :: Model -> Program Topic Outline -> Topic -> IO [(Model, Options)]
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

-- ---------------------------------------------------------------------------
-- M1 — the ambient model id reaches the wire
-- ---------------------------------------------------------------------------

routesModelId :: TestTree
routesModelId =
  testCase "routes the ambient model id onto the wire" $ do
    captured <- captureRouted openai_gpt_4o_mini (predict topicToOutline) (Topic "cats")
    map (^. #modelId) (map fst captured) @?= [openai_gpt_4o_mini ^. #modelId]

-- ---------------------------------------------------------------------------
-- M2 — native responseFormat on the wire; fallback leaves it unset
-- ---------------------------------------------------------------------------

nativeAttachesSchema :: TestTree
nativeAttachesSchema =
  testCase "native model attaches responseFormat with the derived schema" $ do
    captured <- captureRouted openai_gpt_4o_mini (predict topicToOutline) (Topic "cats")
    case captured of
      [(_, o)] -> do
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
      [(_, o)] -> do
        o ^. #responseFormat @?= Nothing
        assertBool
          "private schema key stripped before transport"
          (Map.notMember metaResponseSchemaKey (o ^. #metadata))
      other -> assertBool ("expected exactly one request, got " <> show (length other)) False

-- ---------------------------------------------------------------------------
-- M3 — per-sample temperature from MajorityVote's TempSchedule
-- ---------------------------------------------------------------------------

capturedTemps :: [(Model, Options)] -> [Double]
capturedTemps = mapMaybe (\(_, o) -> o ^. #temperature)

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
      (all (\(_, o) -> Map.notMember metaTemperatureKey (o ^. #metadata)) captured)

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
