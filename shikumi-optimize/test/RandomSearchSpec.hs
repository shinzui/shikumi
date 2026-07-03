{-# LANGUAGE TypeApplications #-}

-- | EP-23 acceptance (random search): the best-of-N bootstrap held-out score is
-- @>=@ a single bootstrap run on the same fixture; the search is reproducible; and
-- the best compiled output round-trips through serialization.
module RandomSearchSpec (tests) where

import Data.IORef (newIORef, readIORef)
import Effectful (Eff, IOE, runEff)
import Effectful.Concurrent (Concurrent, runConcurrent)
import Effectful.Error.Static (Error, runErrorNoCallStack)
import Effectful.Prim (Prim, runPrim)
import Shikumi.Compile.Serialize (decodeCompiledOnto, encodeCompiled)
import Shikumi.Compile.Types (compiledProgram)
import Shikumi.Effect.Time (Time, runTime)
import Shikumi.Error (ShikumiError)
import Shikumi.Eval (Dataset, dataset, exactMatch, example)
import Shikumi.LLM (LLM)
import Shikumi.Optimize
  ( Budget (..),
    bootstrapFewShot,
    bootstrapRandomSearch,
    defaultBudget,
    optimize,
    scoreOn,
    setNodeInstr,
  )
import Shikumi.Program (Program)
import StubLM (Label (..), Sentence (..), ruleInstruction, runStubLM, runStubLMCounting, sentimentProg)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

-- ---------------------------------------------------------------------------
-- Fixtures and run helpers
-- ---------------------------------------------------------------------------

trainset :: Dataset Sentence Label
trainset =
  dataset
    [ example (Sentence "good film") (Label "positive"),
      example (Sentence "bad film") (Label "negative"),
      example (Sentence "good show") (Label "positive"),
      example (Sentence "bad play") (Label "negative")
    ]

heldout :: Dataset Sentence Label
heldout =
  dataset
    [ example (Sentence "good book") (Label "positive"),
      example (Sentence "bad book") (Label "negative")
    ]

-- A teacher that answers correctly under the stub (a RULE-bearing instruction), so
-- bootstrap can harvest good demos from its passing runs.
teacher :: Program Sentence Label
teacher = setNodeInstr 0 ruleInstruction sentimentProg

runStub :: Eff '[LLM, Error ShikumiError, Concurrent, Time, Prim, IOE] a -> IO (Either ShikumiError a)
runStub act = runEff . runPrim . runTime . runConcurrent . runErrorNoCallStack @ShikumiError $ runStubLM act

tests :: TestTree
tests = testGroup "RandomSearch" [bestOfNAtLeastSingle, reproducible, budgetRespected, roundTrips]

bestOfNAtLeastSingle :: TestTree
bestOfNAtLeastSingle =
  testCase "best-of-N held-out score >= single bootstrap" $ do
    res <-
      runStub $ do
        single <- optimize (bootstrapFewShot teacher defaultBudget) trainset exactMatch sentimentProg
        singleScore <- scoreOn heldout exactMatch (compiledProgram single)
        rs <- optimize (bootstrapRandomSearch teacher 8 defaultBudget) trainset exactMatch sentimentProg
        rsScore <- scoreOn heldout exactMatch (compiledProgram rs)
        pure (singleScore, rsScore)
    case res of
      Left e -> assertFailure ("unexpected error: " <> show e)
      Right (singleScore, rsScore) ->
        assertBool
          ("random search " <> show rsScore <> " should be >= single bootstrap " <> show singleScore)
          (rsScore >= singleScore)

reproducible :: TestTree
reproducible =
  testCase "bootstrapRandomSearch is reproducible" $ do
    res <-
      runStub $ do
        a <- optimize (bootstrapRandomSearch teacher 8 defaultBudget) trainset exactMatch sentimentProg
        sa <- scoreOn heldout exactMatch (compiledProgram a)
        b <- optimize (bootstrapRandomSearch teacher 8 defaultBudget) trainset exactMatch sentimentProg
        sb <- scoreOn heldout exactMatch (compiledProgram b)
        pure (sa, sb)
    case res of
      Left e -> assertFailure ("unexpected error: " <> show e)
      Right (sa, sb) -> sa @?= sb

budgetRespected :: TestTree
budgetRespected =
  testCase "bootstrapRandomSearch shares one budget across seeds and scoring" $ do
    ref <- newIORef (0 :: Int)
    let budget = Budget {maxLmCalls = 20, maxCandidates = 100}
    res <-
      runEff . runPrim . runTime . runConcurrent . runErrorNoCallStack @ShikumiError $
        runStubLMCounting ref (optimize (bootstrapRandomSearch teacher 5 budget) trainset exactMatch sentimentProg)
    case res of
      Left e -> assertFailure ("unexpected error: " <> show e)
      Right _ -> pure ()
    count <- readIORef ref
    assertBool ("expected 0 < calls <= 20, got " <> show count) (count > 0 && count <= 20)

roundTrips :: TestTree
roundTrips =
  testCase "best compiled output round-trips, scoring identically" $ do
    res <-
      runStub $ do
        cp <- optimize (bootstrapRandomSearch teacher 8 defaultBudget) trainset exactMatch sentimentProg
        before <- scoreOn heldout exactMatch (compiledProgram cp)
        case decodeCompiledOnto sentimentProg (encodeCompiled cp) of
          Left err -> pure (Left err)
          Right cp' -> do
            after <- scoreOn heldout exactMatch (compiledProgram cp')
            pure (Right (before, after))
    case res of
      Left e -> assertFailure ("unexpected error: " <> show e)
      Right (Left err) -> assertFailure ("decode failed: " <> err)
      Right (Right (before, after)) -> after @?= before
