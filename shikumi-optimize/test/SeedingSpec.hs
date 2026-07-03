{-# LANGUAGE TypeApplications #-}

-- | Regression tests for optimizer instruction seeding.
module SeedingSpec (tests) where

import Control.Lens ((&), (.~))
import Data.Generics.Labels ()
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
    Miprov2Auto (..),
    Miprov2Config (..),
    bootstrapDemoCandidates,
    copro,
    defaultBudget,
    instructionAt,
    instructionSearch,
    miprov2Auto,
    miprov2With,
    optimize,
    recoverDemo,
    scoreOn,
    withDemos,
  )
import Shikumi.Program (Demo)
import StubLM (Label (..), Sentence (..), ruled, runJointStubLM, runStubLM)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

runStub :: Eff '[LLM, Error ShikumiError, Concurrent, Time, Prim, IOE] a -> IO (Either ShikumiError a)
runStub act = runEff . runPrim . runTime . runConcurrent . runErrorNoCallStack @ShikumiError $ runStubLM act

runJoint :: Eff '[LLM, Error ShikumiError, Concurrent, Time, Prim, IOE] a -> IO (Either ShikumiError a)
runJoint act =
  runEff . runPrim . runTime . runConcurrent . runErrorNoCallStack @ShikumiError $ runJointStubLM act

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

jointTrain :: Dataset Sentence Label
jointTrain =
  dataset
    [ example (Sentence "good movie") (Label "positive"),
      example (Sentence "bad movie") (Label "negative"),
      example (Sentence "great film") (Label "positive"),
      example (Sentence "terrible film") (Label "negative")
    ]

jointHeldout :: Dataset Sentence Label
jointHeldout =
  dataset
    [ example (Sentence "good show") (Label "positive"),
      example (Sentence "bad show") (Label "negative"),
      example (Sentence "great show") (Label "positive"),
      example (Sentence "terrible show") (Label "negative")
    ]

coveringDemos :: [Demo]
coveringDemos =
  [ recoverDemo (Sentence "great film") (Label "positive"),
    recoverDemo (Sentence "terrible film") (Label "negative")
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
            override @?= Nothing,
      testCase "miprov2 never returns worse than its solved input baseline" $ do
        let student = withDemos coveringDemos ruled
            cfg :: Miprov2Config
            cfg = miprov2Auto Miprov2Light & #budget .~ Budget {maxLmCalls = 4, maxCandidates = 32}
        res <-
          runJoint $ do
            before <- scoreOn jointHeldout exactMatch student
            cp <- optimize (miprov2With cfg student) jointTrain exactMatch student
            after <- scoreOn jointHeldout exactMatch (compiledProgram cp)
            pure (before, after)
        case res of
          Left e -> assertFailure ("unexpected error: " <> show e)
          Right (before, after) -> do
            before @?= 1.0
            assertBool ("miprov2: expected " <> show after <> " >= " <> show before) (after >= before),
      testCase "miprov2 demo candidate 0 is the node's current demos" $ do
        let student = withDemos coveringDemos ruled
            cfg :: Miprov2Config
            cfg = miprov2Auto Miprov2Light & #numDemoCandidates .~ 3
        res <- runJoint (bootstrapDemoCandidates cfg student jointTrain exactMatch student)
        case res of
          Left e -> assertFailure ("unexpected error: " <> show e)
          Right [sets] -> do
            take 1 sets @?= [coveringDemos]
            assertBool "empty demo set remains available" ([] `elem` sets)
          Right other -> assertFailure ("expected one node, got " <> show (length other))
    ]
