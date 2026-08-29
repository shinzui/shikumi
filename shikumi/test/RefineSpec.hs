{-# LANGUAGE TypeApplications #-}

-- | EP-18 acceptance: the reward-driven self-refinement modules
-- ('Shikumi.Refine.bestOfN', 'Shikumi.Refine.refine',
-- 'Shikumi.Refine.multiChainComparison').
--
-- Every test installs the production router (@routeLLM . runRouting emptyModel@) above a
-- deterministic stub @LLM@ (see "RefineStub") so per-sample temperature reaches the
-- wire exactly as in production — no network, no API key. The headline assertion
-- (M4) shows a deliberately-weak program's score strictly improves once wrapped.
module RefineSpec (tests) where

import Baikai (Context, Options, emptyModel)
import Data.IORef (newIORef, readIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Effectful (runEff)
import Effectful.Concurrent (runConcurrent)
import Effectful.Error.Static (runErrorNoCallStack)
import RefineStub
  ( Answer (..),
    Sentence (..),
    classifyProg,
    decideAdviceFailure,
    decideMCC,
    decideRefine,
    decideTemp,
    goodReward,
    mccSynthSig,
    reasonProg,
    rewardByLabel,
    runRecordingStub,
    runStub,
    runThrowingLLM,
  )
import Shikumi.Combinator (mapP, validate, (>>>))
import Shikumi.Error (ShikumiError)
import Shikumi.Module (predict)
import Shikumi.Program
  ( Program,
    ProgramShape (ShapeEmbed),
    foldParams,
    programShape,
    runProgram,
    runProgramConc,
    setProgramParams,
  )
import Shikumi.Refine (bestOfN, mkReward, multiChainComparison, refine)
import Shikumi.Routing (routeLLM, runRouting)
import Shikumi.Signature (Signature, mkSignature)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Refine"
    [ bestOfNReturnsHighest,
      bestOfNShortCircuits,
      bestOfNExhaustsFailCount,
      refineClimbsViaAdvice,
      refineSurvivesAdviceFailure,
      multiChainSynthesizes,
      moduleComposes,
      moduleIsTransparent,
      rewardDrivenRetryImproves
    ]

-- ---------------------------------------------------------------------------
-- Run helpers — router over the stub, mirroring production install order
-- ---------------------------------------------------------------------------

-- | Run a program sequentially under @routeLLM . runRouting emptyModel@ over the
-- decision-rule stub; returns the result and the completion count.
runCounted ::
  (Context -> Options -> Text) ->
  Program i o ->
  i ->
  IO (Either ShikumiError o, Int)
runCounted decide prog input = do
  ref <- newIORef 0
  res <-
    runEff
      . runErrorNoCallStack @ShikumiError
      . runRouting emptyModel
      . runStub ref decide
      . routeLLM
      $ runProgram prog input
  n <- readIORef ref
  pure (res, n)

-- | As 'runCounted' but under the concurrent executor.
runCountedConc ::
  (Context -> Options -> Text) ->
  Program i o ->
  i ->
  IO (Either ShikumiError o)
runCountedConc decide prog input = do
  ref <- newIORef 0
  runEff
    . runErrorNoCallStack @ShikumiError
    . runConcurrent
    . runRouting emptyModel
    . runStub ref decide
    . routeLLM
    $ runProgramConc prog input

-- | Run a program whose stub throws on every call; returns result and attempt
-- count.
runThrowing ::
  Program i o ->
  i ->
  IO (Either ShikumiError o, Int)
runThrowing prog input = do
  ref <- newIORef 0
  res <-
    runEff
      . runErrorNoCallStack @ShikumiError
      . runRouting emptyModel
      . runThrowingLLM ref
      . routeLLM
      $ runProgram prog input
  n <- readIORef ref
  pure (res, n)

-- | Run recording each request's last user text (to assert what synthesis saw).
runRecorded ::
  (Context -> Options -> Text) ->
  Program i o ->
  i ->
  IO (Either ShikumiError o, [Text])
runRecorded decide prog input = do
  cap <- newIORef []
  res <-
    runEff
      . runErrorNoCallStack @ShikumiError
      . runRouting emptyModel
      . runRecordingStub cap decide
      . routeLLM
      $ runProgram prog input
  texts <- readIORef cap
  pure (res, texts)

-- ---------------------------------------------------------------------------
-- M1 — bestOfN
-- ---------------------------------------------------------------------------

-- | A reward table over the temperature-chosen labels.
labelReward :: [(Text, Double)] -> Answer -> Double
labelReward = rewardByLabel

bestOfNReturnsHighest :: TestTree
bestOfNReturnsHighest =
  testCase "bestOfN returns the highest-reward sample (all attempts run)" $ do
    let reward = mkReward (labelReward [("low", 0.2), ("mid", 0.9), ("high", 0.5)])
    (res, n) <- runCounted decideTemp (bestOfN 3 1.0 reward classifyProg) (Sentence "x")
    res @?= Right (Answer "mid")
    n @?= 3

bestOfNShortCircuits :: TestTree
bestOfNShortCircuits =
  testCase "bestOfN short-circuits on a passing threshold" $ do
    let reward = mkReward (labelReward [("low", 0.2), ("mid", 1.0), ("high", 0.5)])
    (res, n) <- runCounted decideTemp (bestOfN 3 1.0 reward classifyProg) (Sentence "x")
    res @?= Right (Answer "mid")
    n @?= 2

bestOfNExhaustsFailCount :: TestTree
bestOfNExhaustsFailCount =
  testCase "bestOfN exhausts failCount then rethrows" $ do
    let reward = mkReward (labelReward [("low", 0.2)])
    (res, n) <- runThrowing (bestOfN 3 1.0 reward classifyProg) (Sentence "x")
    assertBool "error propagates when every attempt throws" (isLeft res)
    n @?= 3

-- ---------------------------------------------------------------------------
-- M2 — refine
-- ---------------------------------------------------------------------------

refineClimbsViaAdvice :: TestTree
refineClimbsViaAdvice =
  testCase "refine climbs from failing to passing via advice" $ do
    let reward = mkReward goodReward
    (single, _) <- runCounted decideRefine classifyProg (Sentence "x")
    (wrapped, _) <- runCounted decideRefine (refine 2 1.0 reward classifyProg) (Sentence "x")
    single @?= Right (Answer "bad")
    wrapped @?= Right (Answer "good")
    assertBool
      "feedback strictly improves the reward"
      (rewardOf goodReward wrapped > rewardOf goodReward single)

refineSurvivesAdviceFailure :: TestTree
refineSurvivesAdviceFailure =
  testCase "refine returns best-so-far when the advice call fails (EP-35)" $ do
    -- Every classify answers "bad" (sub-threshold); the advice call between
    -- attempts fails to decode. Before EP-35 that error aborted the whole refine;
    -- now it is non-fatal and the best-so-far output is returned.
    let reward = mkReward goodReward
    (wrapped, _) <- runCounted decideAdviceFailure (refine 2 1.0 reward classifyProg) (Sentence "x")
    wrapped @?= Right (Answer "bad")

-- ---------------------------------------------------------------------------
-- M3 — multiChainComparison
-- ---------------------------------------------------------------------------

multiChainSynthesizes :: TestTree
multiChainSynthesizes =
  testCase "multiChainComparison synthesizes the modal consensus from all M attempts" $ do
    (res, texts) <- runRecorded decideMCC (multiChainComparison 3 reasonProg mccSynthSig) (Sentence "x")
    res @?= Right (Answer "Brussels")
    case texts of
      [] -> assertBool "expected at least the synthesis request" False
      _ -> do
        let synthText = last texts
        assertBool "synthesis prompt shows attempt #1" (T.isInfixOf "Student Attempt #1" synthText)
        assertBool "synthesis prompt shows attempt #2" (T.isInfixOf "Student Attempt #2" synthText)
        assertBool "synthesis prompt shows attempt #3" (T.isInfixOf "Student Attempt #3" synthText)

-- ---------------------------------------------------------------------------
-- M4 — composition + the headline acceptance scenario
-- ---------------------------------------------------------------------------

moduleComposes :: TestTree
moduleComposes =
  testCase "module nests inside mapP and >>> and agrees across executors" $ do
    let reward = mkReward (labelReward [("low", 0.2), ("mid", 0.9), ("high", 0.5)])
        p = bestOfN 3 1.0 reward classifyProg
        mapped = mapP 2 p
        inputs = [Sentence "a", Sentence "b"]
    (seqRes, _) <- runCounted decideTemp mapped inputs
    concRes <- runCountedConc decideTemp mapped inputs
    seqRes @?= Right [Answer "mid", Answer "mid"]
    concRes @?= seqRes
    -- a module feeding a downstream validator
    let echoProg = predict (mkSignature "Echo the label." :: Signature Answer Answer)
        guarded = p >>> validate (\(Answer a) -> a `elem` ["low", "mid", "high"]) "unknown label" echoProg
    (gRes, _) <- runCounted decideTemp guarded (Sentence "x")
    assertBool "module >>> validator runs without error" (isRight gRes)

moduleIsTransparent :: TestTree
moduleIsTransparent =
  testCase "module is structurally transparent (ShapeEmbed, no params)" $ do
    let reward = mkReward (labelReward [("mid", 1.0)])
        p = bestOfN 3 1.0 reward classifyProg
    programShape p @?= ShapeEmbed
    foldParams p @?= []
    assertBool "empty param vector loads onto the wrapper" (isRight (setProgramParams [] p))

rewardDrivenRetryImproves :: TestTree
rewardDrivenRetryImproves =
  testCase "reward-driven retry demonstrably improves a deliberately-weak program's score" $ do
    let table = [("low", 0.2), ("mid", 0.9), ("high", 0.5)]
        reward = mkReward (labelReward table)
    (single, _) <- runCounted decideTemp classifyProg (Sentence "x")
    (wrapped, _) <- runCounted decideTemp (bestOfN 3 1.0 reward classifyProg) (Sentence "x")
    let singleScore = rewardOf (labelReward table) single
        wrappedScore = rewardOf (labelReward table) wrapped
    assertBool
      ("wrapped reward " <> show wrappedScore <> " should exceed single-shot " <> show singleScore)
      (wrappedScore > singleScore)

-- ---------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------

rewardOf :: (Answer -> Double) -> Either ShikumiError Answer -> Double
rewardOf f (Right a) = f a
rewardOf _ (Left _) = -1

isRight :: Either a b -> Bool
isRight = either (const False) (const True)

isLeft :: Either a b -> Bool
isLeft = either (const True) (const False)
