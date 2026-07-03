-- | EP-4 M1 (run a node through the LLM effect) and M2 (the parameter interface:
-- @foldParams@ / @mapParams@ / @mapParamsAt@ and the ordering law).
module ProgramSpec (tests) where

import Control.Lens ((&), (.~))
import Data.Generics.Labels ()
import Data.IORef (newIORef)
import Data.List (foldl1')
import Data.Text (Text)
import Data.Text qualified as T
import Effectful (runEff)
import Effectful.Concurrent (runConcurrent)
import Effectful.Error.Static (runErrorNoCallStack)
import ProgramFixtures
  ( Cell (..),
    Draft,
    Outline (..),
    Topic (..),
    badVerdictResponse,
    cellSig,
    mkResponse,
    outlineResponse,
    outlineToDraft,
    runScriptedLLM,
    topicToOutline,
    topicToVerdict,
  )
import Shikumi.Error (ShikumiError (..))
import Shikumi.Program
  ( Params,
    Program (Compose, Predict),
    emptyParams,
    foldParams,
    mapParams,
    mapParamsAt,
    nodeInstructionsIndexed,
    pipeline,
    runProgram,
    runProgramConc,
  )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))
import Test.Tasty.QuickCheck (NonNegative (..), Positive (..), testProperty, (===))

-- A two-stage program reused across the param tests.
twoStage :: Program Topic Draft
twoStage = pipeline (Predict topicToOutline emptyParams) (Predict outlineToDraft emptyParams)

setInstr :: Text -> Params -> Params
setInstr t p = p & #instructionOverride .~ Just t

-- | A list update mirroring @mapParamsAt@'s contract, used to state the ordering
-- law executably.
adjust :: Int -> (a -> a) -> [a] -> [a]
adjust n f xs = [if i == n then f x else x | (i, x) <- zip [0 ..] xs]

-- | A pipeline of @k@ identical @Cell -> Cell@ predict nodes (k >= 1).
cellPipeline :: Int -> Program Cell Cell
cellPipeline k = foldl1' Compose (replicate k (Predict cellSig emptyParams))

tests :: TestTree
tests =
  testGroup
    "ProgramSpec"
    [ testCase "M1: a single Predict node runs through the LLM effect to a typed output" $ do
        ref <- newIORef [outlineResponse]
        out <-
          runEff . runErrorNoCallStack @ShikumiError . runScriptedLLM ref $
            runProgram (Predict topicToOutline emptyParams) (Topic "haskell")
        out @?= Right (Outline {points = ["intro", "body", "end"]}),
      testCase "EP-32: a failing Validatable rule surfaces as ValidationFailure through runProgram" $ do
        ref <- newIORef [badVerdictResponse]
        out <-
          runEff . runErrorNoCallStack @ShikumiError . runScriptedLLM ref $
            runProgram (Predict topicToVerdict emptyParams) (Topic "haskell")
        out @?= Left (ValidationFailure "score: must be at most 10"),
      testCase "EP-32: a failing Validatable rule surfaces through runProgramConc" $ do
        ref <- newIORef [badVerdictResponse]
        out <-
          runEff . runErrorNoCallStack @ShikumiError . runConcurrent . runScriptedLLM ref $
            runProgramConc (Predict topicToVerdict emptyParams) (Topic "haskell")
        out @?= Left (ValidationFailure "score: must be at most 10"),
      testCase "EP-33: a native JSON body of the wrong shape keeps the located native error" $ do
        -- {"points": 42} parses as JSON, so it is the native wire shape; the
        -- native decode reports the precise SchemaMismatch instead of the marker
        -- parser's misleading MissingField.
        ref <- newIORef [mkResponse "{\"points\": 42}"]
        out <-
          runEff . runErrorNoCallStack @ShikumiError . runScriptedLLM ref $
            runProgram (Predict topicToOutline emptyParams) (Topic "haskell")
        out @?= Left (SchemaMismatch "points: expected array, got number"),
      testCase "M2: foldParams returns nodes in stage order" $
        foldParams twoStage @?= [emptyParams, emptyParams],
      testCase "M5: nodeInstructionsIndexed returns signature instructions in node order" $
        nodeInstructionsIndexed twoStage
          @?= ["Outline the topic into points", "Draft prose from the outline"],
      testCase "M5: nodeInstructionsIndexed aligns one-to-one with foldParams" $
        length (nodeInstructionsIndexed twoStage) @?= length (foldParams twoStage),
      testCase "M2: mapParams touches every node" $
        foldParams (mapParams (setInstr "X") twoStage)
          @?= [setInstr "X" emptyParams, setInstr "X" emptyParams],
      testCase "M2: mapParamsAt 0 edits only the first node" $
        foldParams (mapParamsAt 0 (setInstr "first") twoStage)
          @?= [setInstr "first" emptyParams, emptyParams],
      testCase "M2: mapParamsAt 1 edits only the second node" $
        foldParams (mapParamsAt 1 (setInstr "second") twoStage)
          @?= [emptyParams, setInstr "second" emptyParams],
      testCase "M2: mapParamsAt with an out-of-range index is the identity" $
        foldParams (mapParamsAt 7 (setInstr "nope") twoStage)
          @?= [emptyParams, emptyParams],
      testProperty "M2: ordering law — foldParams . mapParamsAt n f == adjust n f . foldParams" $
        \(Positive k') (NonNegative seed) ->
          let k = 1 + (k' `mod` 8)
              n = seed `mod` k
              f = setInstr ("node " <> T.pack (show n))
              prog = cellPipeline k
           in foldParams (mapParamsAt n f prog) === adjust n f (foldParams prog)
    ]
