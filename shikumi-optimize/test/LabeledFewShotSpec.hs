{-# LANGUAGE TypeApplications #-}

-- | M1: labeled few-shot demo selection. The optimizer enumerates every size-@k@
-- demo set drawn from the training examples, scores each, and keeps the best. The
-- test proves the /chosen/ set is the highest-scoring of those tried (not merely
-- "some demos were attached"): it recomputes the score of every candidate set the
-- optimizer considered and asserts the chosen set attains the maximum, that the
-- candidates are not all equal (so the choice is meaningful), and that the maximum
-- is a perfect 1.0.
module LabeledFewShotSpec (tests) where

import Data.IORef (newIORef, readIORef)
import Effectful (Eff, IOE, runEff)
import Effectful.Concurrent (Concurrent, runConcurrent)
import Effectful.Error.Static (Error, runErrorNoCallStack)
import Effectful.Prim (Prim, runPrim)
import Shikumi.Compile.Types (CompiledProgram, compiledProgram)
import Shikumi.Effect.Time (Time, runTime)
import Shikumi.Error (ShikumiError)
import Shikumi.Eval (Dataset, dataset, exactMatch, example)
import Shikumi.LLM (LLM)
import Shikumi.Optimize
import Shikumi.Program (Demo, Params (..), programParams)
import StubLM (Label (..), Sentence (..), runStubLM, runStubLMCounting, sentimentProg)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

runStub :: Eff '[LLM, Error ShikumiError, Concurrent, Time, Prim, IOE] a -> IO (Either ShikumiError a)
runStub act = runEff . runPrim . runTime . runConcurrent . runErrorNoCallStack @ShikumiError $ runStubLM act

-- | A balanced training set: two positives (containing @good@) and two negatives
-- (containing @bad@). A single demo cannot classify all four, so a winning set
-- must pair a @good@-demo with a @bad@-demo whose other words align with the
-- inputs — only some size-2 sets do.
trainset :: Dataset Sentence Label
trainset =
  dataset
    [ example (Sentence "good movie") (Label "positive"),
      example (Sentence "good meal") (Label "positive"),
      example (Sentence "bad movie") (Label "negative"),
      example (Sentence "bad meal") (Label "negative")
    ]

-- | The demos baked into a compiled single-node program.
chosenDemos :: CompiledProgram Sentence Label -> [Demo]
chosenDemos cp = case programParams (compiledProgram cp) of
  (ps : _) -> demos ps
  [] -> []

tests :: TestTree
tests =
  testGroup
    "M1 labeledFewShot"
    [ testCase "selects the highest-scoring demo set of those tried" $ do
        res <- runStub $ do
          cp <- optimize (labeledFewShot 2) trainset exactMatch sentimentProg
          let chosen = chosenDemos cp
          chosenScore <- scoreOn trainset exactMatch (withDemos chosen sentimentProg)
          candScores <-
            mapM
              (\ds -> scoreOn trainset exactMatch (withDemos ds sentimentProg))
              (labeledCandidateSets 2 trainset)
          pure (chosen, chosenScore, candScores)
        case res of
          Left e -> assertFailure ("unexpected error: " <> show e)
          Right (chosen, chosenScore, candScores) -> do
            length chosen @?= 2
            chosenScore @?= maximum candScores
            assertBool
              ("candidate scores should differ, got " <> show candScores)
              (maximum candScores > minimum candScores)
            assertBool
              ("best candidate should be perfect, got " <> show chosenScore)
              (chosenScore == 1.0),
      testCase "labeledFewShotWith respects maxLmCalls while scoring candidates" $ do
        ref <- newIORef (0 :: Int)
        let budget = Budget {maxLmCalls = 6, maxCandidates = 100}
        res <-
          runEff . runPrim . runTime . runConcurrent . runErrorNoCallStack @ShikumiError $
            runStubLMCounting ref (optimize (labeledFewShotWith budget 2) trainset exactMatch sentimentProg)
        case res of
          Left e -> assertFailure ("unexpected error: " <> show e)
          Right _ -> pure ()
        count <- readIORef ref
        assertBool ("expected 0 < calls <= 6, got " <> show count) (count > 0 && count <= 6)
    ]
