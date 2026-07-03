-- | EP-4 M4: the @predict@ and @chainOfThought@ modules. @predict@ builds a single
-- default-parameter node; @chainOfThought@ extends the output with a leading
-- @reasoning@ field and (in the bare form) projects it back out, while the
-- underlying node's parameters stay reachable via @mapParamsAt@.
module ModuleSpec (tests) where

import Control.Lens ((&), (.~))
import Data.Generics.Labels ()
import Data.IORef (newIORef)
import Effectful (runEff)
import Effectful.Error.Static (runErrorNoCallStack)
import ProgramFixtures
  ( Outline (..),
    Topic (..),
    markerBody,
    mkResponse,
    runScriptedLLM,
    topicToOutline,
    topicToVerdict,
  )
import Shikumi.Error (ShikumiError (..))
import Shikumi.Module (WithReasoning (..), chainOfThought, chainOfThoughtRaw, predict)
import Shikumi.Program (emptyParams, foldParams, mapParamsAt, runProgram)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "ModuleSpec"
    [ testCase "predict builds a single default-parameter node" $
        foldParams (predict topicToOutline) @?= [emptyParams],
      testCase "chainOfThoughtRaw yields a WithReasoning value through the stub" $ do
        ref <-
          newIORef
            [ mkResponse
                ( markerBody
                    [ ("reasoning", "first I consider the topic"),
                      ("value", "{\"points\": [\"a\", \"b\", \"c\"]}")
                    ]
                )
            ]
        out <-
          runEff . runErrorNoCallStack @ShikumiError . runScriptedLLM ref $
            runProgram (chainOfThoughtRaw topicToOutline) (Topic "haskell")
        out
          @?= Right
            (WithReasoning "first I consider the topic" (Outline {points = ["a", "b", "c"]})),
      testCase "chainOfThought projects out the bare output" $ do
        ref <-
          newIORef
            [ mkResponse
                ( markerBody
                    [ ("reasoning", "thinking"),
                      ("value", "{\"points\": [\"x\", \"y\"]}")
                    ]
                )
            ]
        out <-
          runEff . runErrorNoCallStack @ShikumiError . runScriptedLLM ref $
            runProgram (chainOfThought topicToOutline) (Topic "haskell")
        out @?= Right (Outline {points = ["x", "y"]}),
      testCase "EP-32: a failing Validatable rule surfaces through chainOfThought" $ do
        ref <-
          newIORef
            [ mkResponse
                ( markerBody
                    [ ("reasoning", "thinking"),
                      ("value", "{\"score\": 99}")
                    ]
                )
            ]
        out <-
          runEff . runErrorNoCallStack @ShikumiError . runScriptedLLM ref $
            runProgram (chainOfThought topicToVerdict) (Topic "haskell")
        out @?= Left (ValidationFailure "score: must be at most 10"),
      testCase "the chain-of-thought node's params are reachable via mapParamsAt 0" $
        foldParams (mapParamsAt 0 (\p -> p & #instructionOverride .~ Just "cot") (chainOfThought topicToOutline))
          @?= [emptyParams & #instructionOverride .~ Just "cot"]
    ]
