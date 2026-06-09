-- | EP-4 M5 — the end-to-end acceptance behaviors named in the plan's Purpose:
--
--   * __typed composition runs end-to-end__: two record-typed signatures composed
--     with 'pipeline' run through the stub @LLM@ and return a typed @Draft@;
--   * __the program is rewritable as data, and the rewrite reaches the wire__:
--     editing node 0's instruction with 'mapParamsAt' shows the new instruction in
--     both @foldParams@ (as data) and in the captured first-stage prompt (on the
--     wire), while node 1 is untouched.
module ProgramAcceptanceSpec (tests) where

import Data.Aeson (Value, object, (.=))
import Data.IORef (newIORef, readIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Effectful (runEff)
import Effectful.Error.Static (runErrorNoCallStack)
import ProgramFixtures
  ( Draft (..),
    Topic (..),
    draftResponse,
    outlineResponse,
    outlineToDraft,
    runRecordingLLM,
    runScriptedLLM,
    topicToOutline,
  )
import Shikumi.Error (ShikumiError)
import Shikumi.Module (predict)
import Shikumi.Program
  ( Demo (..),
    Params (..),
    Program,
    foldParams,
    mapParamsAt,
    pipeline,
    runProgram,
  )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

-- The headline two-stage program: Topic -> Outline -> Draft.
essay :: Program Topic Draft
essay = pipeline (predict topicToOutline) (predict outlineToDraft)

-- A JSON demo whose halves decode to a Topic and an Outline (so it can be spliced
-- into the rendered prompt without error).
sampleDemo :: Demo
sampleDemo =
  Demo
    { demoInput = topicJSON "demo topic",
      demoOutput = outlineJSON ["alpha", "beta"]
    }

topicJSON :: Text -> Value
topicJSON s = object ["subject" .= s]

outlineJSON :: [Text] -> Value
outlineJSON ps = object ["points" .= ps]

tests :: TestTree
tests =
  testGroup
    "ProgramAcceptanceSpec"
    [ testCase "Behavior 1: a typed two-stage pipeline returns a Draft" $ do
        ref <- newIORef [outlineResponse, draftResponse]
        out <-
          runEff . runErrorNoCallStack @ShikumiError . runScriptedLLM ref $
            runProgram essay (Topic "haskell")
        out @?= Right (Draft {prose = "A fine essay about the outline."}),
      testCase "Behavior 2 (data): rewriting node 0 changes only node 0's params" $ do
        let rewritten =
              mapParamsAt
                0
                (\p -> p {instructionOverride = Just "NEW INSTRUCTION", demos = [sampleDemo]})
                essay
            params = foldParams rewritten
        length params @?= 2
        instructionOverride (params !! 0) @?= Just "NEW INSTRUCTION"
        demos (params !! 0) @?= [sampleDemo]
        params !! 1 @?= emptyParamsLike,
      testCase "Behavior 2 (wire): the new instruction appears in the captured first-stage prompt" $ do
        capture <- newIORef []
        ref <- newIORef [outlineResponse, draftResponse]
        let rewritten =
              mapParamsAt
                0
                (\p -> p {instructionOverride = Just "NEW INSTRUCTION", demos = [sampleDemo]})
                essay
        out <-
          runEff . runErrorNoCallStack @ShikumiError . runRecordingLLM capture ref $
            runProgram rewritten (Topic "haskell")
        out @?= Right (Draft {prose = "A fine essay about the outline."})
        prompts <- readIORef capture
        case prompts of
          (firstStage : _) -> do
            length prompts @?= 2
            assertBool
              "first-stage prompt should contain the new instruction"
              ("NEW INSTRUCTION" `T.isInfixOf` firstStage)
          [] -> assertBool "expected captured prompts" False
    ]
  where
    -- node 1 should remain the default overlay
    emptyParamsLike :: Params
    emptyParamsLike = Params Nothing []
