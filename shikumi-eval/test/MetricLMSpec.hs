-- | Unit tests for the LM-backed metrics, run against mock interpreters with no
-- network: 'semanticSimilarity' over a pure 'Embedding' interpreter (identical /
-- orthogonal / opposite vectors), and 'modelJudge' over a constant mock LLM that
-- returns a fixed grade.
module MetricLMSpec (tests) where

import Data.Text (Text)
import Data.Vector (Vector)
import Data.Vector qualified as V
import Effectful (runEff, runPureEff)
import Effectful.Error.Static (runErrorNoCallStack)
import EvalFixtures (markerResponse, runConstLLM)
import Shikumi.Error (ShikumiError)
import Shikumi.Eval.Metric
  ( modelJudge,
    runEmbedding,
    semanticSimilarity,
  )
import Shikumi.Eval.Types
  ( Prediction,
    Score,
    mkScore,
    prediction,
    scoreOne,
    scoreZero,
  )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))

-- | A fixed embedding table: each label maps to a 2-D vector. "a" and "b" are
-- orthogonal (cosine 0 -> score 0.5); "c" is the opposite of "a" (cosine -1 ->
-- score 0); identical labels share a vector (cosine 1 -> score 1); "z" is the
-- zero vector (no signal -> score 0).
embedTable :: Text -> Vector Double
embedTable "a" = V.fromList [1, 0]
embedTable "b" = V.fromList [0, 1]
embedTable "c" = V.fromList [-1, 0]
embedTable _ = V.fromList [0, 0]

-- | Score the similarity of two text labels under the fixed embedding table.
sim :: Text -> Prediction Text -> Score
sim expd predd =
  runPureEff . runEmbedding embedTable $ semanticSimilarity id expd predd

tests :: TestTree
tests =
  testGroup
    "Metric (LM)"
    [ testCase "semanticSimilarity identical -> 1" $
        sim "a" (prediction "a") @?= scoreOne,
      testCase "semanticSimilarity orthogonal -> 0.5" $
        sim "a" (prediction "b") @?= mkScore 0.5,
      testCase "semanticSimilarity opposite -> 0" $
        sim "a" (prediction "c") @?= scoreZero,
      testCase "semanticSimilarity zero-norm -> 0" $
        sim "z" (prediction "z") @?= scoreZero,
      testCase "modelJudge returns the model's grade" $ do
        result <-
          runEff . runErrorNoCallStack @ShikumiError $
            runConstLLM (markerResponse [("grade", "0.7")]) $
              modelJudge "Grade the answer." id ("ref" :: Text) (prediction "cand")
        case result of
          Left e -> assertFailure ("unexpected error: " <> show e)
          Right s -> s @?= mkScore 0.7
    ]
