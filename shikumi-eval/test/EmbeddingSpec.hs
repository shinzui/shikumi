{-# LANGUAGE TypeApplications #-}

-- | End-to-end tests for the embeddings path (EP-15, M3).
--
-- The hermetic test drives @semanticSimilarity@ through the /real/ interpreter
-- shape ('runEmbeddingBy') with a deterministic stub embedder — exercising the new
-- code path without a network — and asserts a semantically-close pair scores
-- strictly higher than a distant pair. The live test is gated on
-- @SHIKUMI_EMBEDDING_LIVE=1@ and asserts a real vector's dimensionality.
module EmbeddingSpec (tests) where

import Data.Text (Text)
import Data.Vector (Vector)
import Data.Vector qualified as V
import Effectful (runEff)
import Effectful.Error.Static (runErrorNoCallStack)
import Shikumi.Error (ShikumiError)
import Shikumi.Eval.Embedding (runEmbeddingBy, runEmbeddingLLM)
import Shikumi.Eval.Metric (embedText, semanticSimilarity)
import Shikumi.Eval.Types (Score, prediction, unScore)
import System.Environment (lookupEnv)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

-- | A deterministic stub embedder. The two cat sentences point in nearly the same
-- direction (cosine ≈ 0.995); the revenue sentence is near-orthogonal/opposite to
-- them, so the close pair must outscore the distant pair under @cosineScore@.
stubEmbed :: [Text] -> IO (Vector (Vector Double))
stubEmbed = pure . V.fromList . map vecFor
  where
    vecFor "a cat sat on the mat" = V.fromList [1, 0.9]
    vecFor "the cat is on the rug" = V.fromList [0.9, 1]
    vecFor "quarterly revenue rose" = V.fromList [1, -1]
    vecFor _ = V.fromList [0, 0]

-- | Score the similarity of two texts through the real interpreter over the stub.
runSim :: Text -> Text -> IO (Either ShikumiError Score)
runSim expd predd =
  runEff . runErrorNoCallStack @ShikumiError . runEmbeddingBy stubEmbed $
    semanticSimilarity id expd (prediction predd)

tests :: TestTree
tests =
  testGroup
    "Embedding"
    [ testCase "semanticSimilarity scores close pair above distant pair (hermetic)" $ do
        close <- runSim "a cat sat on the mat" "the cat is on the rug"
        distant <- runSim "a cat sat on the mat" "quarterly revenue rose"
        case (close, distant) of
          (Right c, Right d) ->
            assertBool
              ("close (" <> show (unScore c) <> ") must exceed distant (" <> show (unScore d) <> ")")
              (unScore c > unScore d)
          _ -> assertFailure "stub-backed semanticSimilarity errored",
      testCase "live embedding returns expected dimensionality" $ do
        live <- lookupEnv "SHIKUMI_EMBEDDING_LIVE"
        case live of
          Just "1" -> do
            r <- runEff . runErrorNoCallStack @ShikumiError . runEmbeddingLLM $ embedText "hello"
            case r of
              Right v -> V.length v @?= 1536
              Left e -> assertFailure ("live embedding failed: " <> show e)
          _ -> putStrLn "SHIKUMI_EMBEDDING_LIVE not set; skipping live test"
    ]
