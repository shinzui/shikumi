-- | Unit tests for the owned data model: 'Score' clamping, dataset
-- construction, and single-sample 'Prediction' construction.
module TypesSpec (tests) where

import Data.List.NonEmpty (NonEmpty (..))
import Shikumi.Eval.Types
  ( Score (..),
    dataset,
    datasetSize,
    example,
    mkScore,
    prediction,
    predictionSamples,
    scoreOne,
    scoreZero,
  )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Types"
    [ testCase "mkScore clamps high" $ mkScore 1.5 @?= scoreOne,
      testCase "mkScore clamps low" $ mkScore (-0.2) @?= scoreZero,
      testCase "mkScore passes through in-range" $ mkScore 0.5 @?= Score 0.5,
      testCase "datasetSize counts examples" $
        datasetSize (dataset [example (1 :: Int) 'a', example 2 'b']) @?= 2,
      testCase "prediction is single-sample" $
        predictionSamples (prediction ("x" :: String)) @?= ("x" :| [])
    ]
