-- | Unit tests for the pure metrics and combinators: exact match, normalized
-- string similarity (identical / near / disjoint), and the @threshold@,
-- @weightedMean@, and @invert@ combinators. All offline and deterministic.
module MetricSpec (tests) where

import Data.Text (Text)
import Shikumi.Eval.Metric
  ( exactMatch,
    invert,
    normalizedStringSimilarity,
    threshold,
    weightedMean,
  )
import Shikumi.Eval.Types
  ( Prediction,
    Score,
    mkScore,
    prediction,
    scoreOne,
    scoreZero,
    unScore,
  )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

-- | A constant metric ignoring its inputs, for combinator tests.
constMetric :: Double -> (o -> Prediction o -> Score)
constMetric d _ _ = mkScore d

tests :: TestTree
tests =
  testGroup
    "Metric"
    [ testCase "exactMatch equal" $
        exactMatch ("a" :: Text) (prediction "a") @?= scoreOne,
      testCase "exactMatch unequal" $
        exactMatch ("a" :: Text) (prediction "b") @?= scoreZero,
      testCase "normalizedStringSimilarity identical" $
        normalizedStringSimilarity id ("the cat" :: Text) (prediction "the cat") @?= scoreOne,
      testCase "normalizedStringSimilarity case/space-insensitive" $
        normalizedStringSimilarity id ("The  Cat" :: Text) (prediction "the cat") @?= scoreOne,
      testCase "normalizedStringSimilarity near is strictly between" $
        let s = unScore (normalizedStringSimilarity id ("the cat sat" :: Text) (prediction "the cat ran"))
         in assertBool ("expected 0 < " <> show s <> " < 1") (s > 0 && s < 1),
      testCase "normalizedStringSimilarity disjoint is low" $
        let s = unScore (normalizedStringSimilarity id ("alpha" :: Text) (prediction "zzzzz"))
         in assertBool ("expected " <> show s <> " < 0.2") (s < 0.2),
      testCase "threshold passes a high score" $
        threshold 0.5 (constMetric 0.7) () (prediction ()) @?= scoreOne,
      testCase "threshold fails a low score" $
        threshold 0.5 (constMetric 0.3) () (prediction ()) @?= scoreZero,
      testCase "weightedMean averages by weight" $
        -- (1*0.2 + 3*0.6) / (1+3) = 2.0/4 = 0.5 (within float tolerance)
        let s = unScore (weightedMean [(1, constMetric 0.2), (3, constMetric 0.6)] () (prediction ()))
         in assertBool ("expected ~0.5, got " <> show s) (abs (s - 0.5) < 1e-9),
      testCase "weightedMean of empty is zero" $
        weightedMean [] () (prediction ()) @?= scoreZero,
      testCase "invert flips" $
        invert (constMetric 0.25) () (prediction ()) @?= mkScore 0.75
    ]
