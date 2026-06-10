{-# LANGUAGE TypeApplications #-}

-- | EP-22 acceptance: GEPA reflective evolution. Hermetic, offline. Pure unit tests
-- for the Pareto frontier; effectful tests for per-node feedback capture, reflective
-- mutation, and the end-to-end held-out lift + serialization round-trip.
module GepaSpec (tests) where

import Effectful (Eff, IOE, runEff)
import Effectful.Concurrent (Concurrent, runConcurrent)
import Effectful.Error.Static (Error, runErrorNoCallStack)
import Effectful.Prim (Prim, runPrim)
import Shikumi.Compile.Serialize (decodeCompiledOnto, encodeCompiled)
import Shikumi.Compile.Types (compiledProgram)
import Shikumi.Effect.Time (Time, runTime)
import Shikumi.Error (ShikumiError)
import Shikumi.Eval (Dataset, boolScore, dataset, exactMatch, example, predictionPrimary)
import Shikumi.LLM (LLM)
import Shikumi.Optimize
  ( Candidate (..),
    FeedbackMetric,
    captureFeedback,
    defaultBudget,
    dominates,
    gepa,
    mutateNode,
    optimize,
    paretoFrontier,
    reflectiveProposer,
    sampleParent,
    scoreOn,
  )
import Shikumi.Program (Params (..), foldParams, nodeFieldsIndexed, programParams)
import Shikumi.Trace.Feedback (feedbackFor)
import Shikumi.Trace.Node (programNodePaths)
import StubLM (Label (..), Sentence (..), ruleInstruction, runGepaStubLM, sentimentProg)
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

-- | The feedback metric: correct → score 1, no critique; wrong → score 0 and the
-- critique "be more specific" (which the stub's reflective proposer keys off).
fbMetric :: FeedbackMetric Label
fbMetric expd p =
  let correct = expd == predictionPrimary p
   in (boolScore correct, if correct then "" else "be more specific")

runGepa :: Eff '[LLM, Error ShikumiError, Concurrent, Time, Prim, IOE] a -> IO (Either ShikumiError a)
runGepa act = runEff . runPrim . runTime . runConcurrent . runErrorNoCallStack @ShikumiError $ runGepaStubLM act

tests :: TestTree
tests = testGroup "Gepa" [paretoPure, feedbackCapture, reflectiveMutation, heldoutLift, roundTrips]

-- ---------------------------------------------------------------------------
-- Pure Pareto-frontier tests
-- ---------------------------------------------------------------------------

paretoPure :: TestTree
paretoPure =
  testGroup
    "gepa-pareto"
    [ testCase "dominance and the non-dominated frontier" $ do
        let a = Candidate [] [1.0, 0.0] 0.5
            b = Candidate [] [0.0, 0.0] 0.0
            c = Candidate [] [0.0, 1.0] 0.5
        dominates a b @?= True
        dominates a c @?= False
        paretoFrontier [a, b, c] @?= [a, c],
      testCase "sampleParent is deterministic for a fixed seed" $ do
        let a = Candidate [] [1.0, 0.0] 0.5
            c = Candidate [] [0.0, 1.0] 0.5
        (fst <$> sampleParent 7 [a, c]) @?= (fst <$> sampleParent 7 [a, c])
        assertBool "samples a frontier member" (maybe False ((`elem` [a, c]) . fst) (sampleParent 7 [a, c]))
    ]

-- ---------------------------------------------------------------------------
-- M1 — feedback capture
-- ---------------------------------------------------------------------------

feedbackCapture :: TestTree
feedbackCapture =
  testCase "captureFeedback accumulates a per-node critique keyed by NodePath" $ do
    res <- runGepa (captureFeedback trainset fbMetric sentimentProg)
    case res of
      Left e -> assertFailure ("unexpected error: " <> show e)
      Right (fblog, scores) -> do
        length scores @?= 2
        case programNodePaths sentimentProg of
          (p0 : _) -> do
            let crits = feedbackFor p0 fblog
            assertBool "node 0 accumulated a critique" (not (null crits))
            assertBool "the critique is the expected one" (any (== "be more specific") crits)
          [] -> assertFailure "expected at least one node"

-- ---------------------------------------------------------------------------
-- M2 — reflective mutation
-- ---------------------------------------------------------------------------

reflectiveMutation :: TestTree
reflectiveMutation =
  testCase "a node whose feedback says be-more-specific receives a mutated instruction" $ do
    res <-
      runGepa $ do
        (fblog, _) <- captureFeedback trainset fbMetric sentimentProg
        mutateNode
          reflectiveProposer
          "a one-node program"
          "a tiny dataset"
          (nodeFieldsIndexed sentimentProg)
          fblog
          (programNodePaths sentimentProg)
          0
          sentimentProg
    case res of
      Left e -> assertFailure ("unexpected error: " <> show e)
      Right mutated -> case foldParams mutated of
        -- the original node had no instruction override (Nothing); a Just RULE proves it mutated
        (ps : _) -> instructionOverride ps @?= Just ruleInstruction
        [] -> assertFailure "expected one node"

-- ---------------------------------------------------------------------------
-- M3 — held-out lift and serialization round-trip
-- ---------------------------------------------------------------------------

heldoutLift :: TestTree
heldoutLift =
  testCase "reflective evolution lifts the held-out score" $ do
    res <-
      runGepa $ do
        before <- scoreOn heldout exactMatch sentimentProg
        cp <- optimize (gepa reflectiveProposer fbMetric defaultBudget) trainset exactMatch sentimentProg
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
  testCase "gepa output round-trips through encodeCompiled/decodeCompiledOnto" $ do
    res <- runGepa (optimize (gepa reflectiveProposer fbMetric defaultBudget) trainset exactMatch sentimentProg)
    case res of
      Left e -> assertFailure ("unexpected error: " <> show e)
      Right cp -> case decodeCompiledOnto sentimentProg (encodeCompiled cp) of
        Left err -> assertFailure ("decode failed: " <> err)
        Right cp' -> programParams (compiledProgram cp') @?= programParams (compiledProgram cp)
