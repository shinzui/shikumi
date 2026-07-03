{-# LANGUAGE TypeApplications #-}

-- | Regression tests for optimizer instruction seeding.
module SeedingSpec (tests) where

import Effectful (Eff, IOE, runEff)
import Effectful.Concurrent (Concurrent, runConcurrent)
import Effectful.Error.Static (Error, runErrorNoCallStack)
import Effectful.Prim (Prim, runPrim)
import Shikumi.Compile.Types (compiledProgram)
import Shikumi.Effect.Time (Time, runTime)
import Shikumi.Error (ShikumiError)
import Shikumi.Eval (Dataset, dataset, exactMatch, example)
import Shikumi.LLM (LLM)
import Shikumi.Optimize
  ( Budget (..),
    CoproConfig (..),
    copro,
    defaultBudget,
    instructionAt,
    instructionSearch,
    optimize,
    scoreOn,
  )
import StubLM (Label (..), Sentence (..), ruled, runStubLM)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

runStub :: Eff '[LLM, Error ShikumiError, Concurrent, Time, Prim, IOE] a -> IO (Either ShikumiError a)
runStub act = runEff . runPrim . runTime . runConcurrent . runErrorNoCallStack @ShikumiError $ runStubLM act

trainset :: Dataset Sentence Label
trainset =
  dataset
    [ example (Sentence "good film") (Label "positive"),
      example (Sentence "good book") (Label "positive"),
      example (Sentence "bad film") (Label "negative"),
      example (Sentence "bad book") (Label "negative")
    ]

heldout :: Dataset Sentence Label
heldout =
  dataset
    [ example (Sentence "good movie") (Label "positive"),
      example (Sentence "bad movie") (Label "negative")
    ]

tests :: TestTree
tests =
  testGroup
    "instruction seeding"
    [ testCase "instructionSearch never degrades a solved signature instruction" $ do
        res <-
          runStub $ do
            before <- scoreOn heldout exactMatch ruled
            cp <- optimize (instructionSearch 1 defaultBudget) trainset exactMatch ruled
            after <- scoreOn heldout exactMatch (compiledProgram cp)
            pure (before, after, instructionAt 0 (compiledProgram cp))
        case res of
          Left e -> assertFailure ("unexpected error: " <> show e)
          Right (before, after, override) -> do
            before @?= 1.0
            assertBool ("instructionSearch: expected " <> show after <> " >= " <> show before) (after >= before)
            override @?= Nothing,
      testCase "copro never degrades a solved student when proposer calls are unaffordable" $ do
        let cfg = CoproConfig {breadth = 2, depth = 1, budget = Budget {maxLmCalls = 4, maxCandidates = 32}}
        res <-
          runStub $ do
            before <- scoreOn heldout exactMatch ruled
            cp <- optimize (copro cfg) trainset exactMatch ruled
            after <- scoreOn heldout exactMatch (compiledProgram cp)
            pure (before, after, instructionAt 0 (compiledProgram cp))
        case res of
          Left e -> assertFailure ("unexpected error: " <> show e)
          Right (before, after, override) -> do
            before @?= 1.0
            assertBool ("copro: expected " <> show after <> " >= " <> show before) (after >= before)
            override @?= Nothing
    ]
