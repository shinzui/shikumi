{-# LANGUAGE TypeApplications #-}

-- | EP-21 acceptance: COPRO coordinate-ascent instruction optimization. Hermetic,
-- offline. Proves the held-out lift, depth monotonicity, the LM-call budget bound,
-- and the serialization round-trip — the breadth/depth control the MasterPlan tracks.
module CoproSpec (tests) where

import Control.Lens ((&), (.~))
import Data.Generics.Labels ()
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
    copro,
    defaultCoproConfig,
    optimize,
    scoreOn,
  )
import Shikumi.Program (Params (..), programParams)
import StubLM
  ( Label (..),
    Sentence (..),
    ruleInstruction,
    runStubLM,
    runStubLMCounting,
    sentimentProg,
  )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

-- ---------------------------------------------------------------------------
-- Fixtures and run helpers
-- ---------------------------------------------------------------------------

trainset :: Dataset Sentence Label
trainset =
  dataset
    [ example (Sentence "good film") (Label "positive"),
      example (Sentence "bad film") (Label "negative")
    ]

heldout :: Dataset Sentence Label
heldout =
  dataset
    [ example (Sentence "good book") (Label "positive"),
      example (Sentence "bad book") (Label "negative")
    ]

runStub :: Eff '[LLM, Error ShikumiError, Concurrent, Time, Prim, IOE] a -> IO (Either ShikumiError a)
runStub act = runEff . runPrim . runTime . runConcurrent . runErrorNoCallStack @ShikumiError $ runStubLM act

tests :: TestTree
tests = testGroup "Copro" [breadthSurfacesMagic, depthMonotone, budgetRespected, heldoutLift, roundTrips]

-- ---------------------------------------------------------------------------
-- M1/M2 — breadth, depth, budget
-- ---------------------------------------------------------------------------

breadthSurfacesMagic :: TestTree
breadthSurfacesMagic =
  testCase "breadth surfaces and selects the magic RULE instruction" $ do
    res <- runStub (optimize (copro (defaultCoproConfig & #depth .~ 1)) trainset exactMatch sentimentProg)
    case res of
      Left e -> assertFailure ("unexpected error: " <> show e)
      Right cp -> case programParams (compiledProgram cp) of
        (ps : _) -> instructionOverride ps @?= Just ruleInstruction
        [] -> assertFailure "expected one node"

depthMonotone :: TestTree
depthMonotone =
  testCase "deeper depth never scores worse than shallower on held-out" $ do
    res <-
      runStub $ do
        cp1 <- optimize (copro (defaultCoproConfig & #depth .~ 1)) trainset exactMatch sentimentProg
        s1 <- scoreOn heldout exactMatch (compiledProgram cp1)
        cp3 <- optimize (copro (defaultCoproConfig & #depth .~ 3)) trainset exactMatch sentimentProg
        s3 <- scoreOn heldout exactMatch (compiledProgram cp3)
        pure (s1, s3)
    case res of
      Left e -> assertFailure ("unexpected error: " <> show e)
      Right (s1, s3) -> assertBool ("depth3 " <> show s3 <> " >= depth1 " <> show s1) (s3 >= s1)

budgetRespected :: TestTree
budgetRespected =
  testCase "respects the LM-call budget" $ do
    ref <- newIORef (0 :: Int)
    let cfg = defaultCoproConfig & #budget .~ Budget {maxLmCalls = 8, maxCandidates = 32}
    res <-
      runEff . runPrim . runTime . runConcurrent . runErrorNoCallStack @ShikumiError $
        runStubLMCounting ref (optimize (copro cfg) trainset exactMatch sentimentProg)
    case res of
      Left e -> assertFailure ("unexpected error: " <> show e)
      Right _ -> pure ()
    count <- readIORef ref
    assertBool ("expected 0 < calls <= 8, got " <> show count) (count > 0 && count <= 8)

-- ---------------------------------------------------------------------------
-- M3 — held-out lift and serialization round-trip
-- ---------------------------------------------------------------------------

heldoutLift :: TestTree
heldoutLift =
  testCase "held-out score strictly improves after copro" $ do
    res <-
      runStub $ do
        before <- scoreOn heldout exactMatch sentimentProg
        cp <- optimize (copro defaultCoproConfig) trainset exactMatch sentimentProg
        after <- scoreOn heldout exactMatch (compiledProgram cp)
        pure (before, after)
    case res of
      Left e -> assertFailure ("unexpected error: " <> show e)
      Right (before, after) -> do
        assertBool ("before should be low, got " <> show before) (before < 0.5)
        assertBool ("after " <> show after <> " should exceed before " <> show before) (after > before)
        assertBool ("after should reach the floor, got " <> show after) (after >= 0.75)

roundTrips :: TestTree
roundTrips =
  testCase "copro output round-trips through encodeCompiled/decodeCompiledOnto" $ do
    res <- runStub (optimize (copro defaultCoproConfig) trainset exactMatch sentimentProg)
    case res of
      Left e -> assertFailure ("unexpected error: " <> show e)
      Right cp -> case decodeCompiledOnto sentimentProg (encodeCompiled cp) of
        Left err -> assertFailure ("decode failed: " <> err)
        Right cp' ->
          programParams (compiledProgram cp') @?= programParams (compiledProgram cp)
