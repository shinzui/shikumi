{-# LANGUAGE TypeApplications #-}

-- | EP-19 acceptance: the grounded instruction proposer. Three hermetic groups
-- (M1 field metadata + program describer, M2 dataset summary + tips + history, M3
-- the assembled @proposeInstructions@), all offline against the deterministic stub
-- LM. The headline check (M3) reads back the rendered prompt the final instruction
-- generator received and asserts it carries the dataset summary, the node's real
-- field names, and the selected tip — proving the proposer is genuinely grounded.
module ProposeSpec (tests) where

import Control.Monad (forM)
import Data.IORef (newIORef, readIORef)
import Data.List (nub)
import Data.Text (Text)
import Data.Text qualified as T
import Effectful (Eff, IOE, runEff, (:>))
import Effectful.Error.Static (Error, runErrorNoCallStack)
import Shikumi.Error (ShikumiError)
import Shikumi.Eval (Dataset, dataset, example)
import Shikumi.LLM (LLM)
import Shikumi.Optimize.Propose
  ( NodeFieldNames (..),
    PastInstruction (..),
    ProposeRequest (..),
    ProposeResult (..),
    datasetSummary,
    programFieldNames,
    proposeInstructions,
    renderHistory,
    renderProgramPseudo,
    tipAt,
    tipBank,
  )
import Shikumi.Optimize.Propose.Summarize
  ( ProgramDescribeIn (..),
    ProgramDescribeOut (..),
    programDescriber,
  )
import Shikumi.Program (Program, foldParams, runProgram)
import StubLM
  ( Label (..),
    Sentence (..),
    runStubLM,
    runStubLMCapturing,
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

runStub :: Eff '[LLM, Error ShikumiError, IOE] a -> IO (Either ShikumiError a)
runStub act = runEff . runErrorNoCallStack @ShikumiError $ runStubLM act

runCapturing :: Eff '[LLM, Error ShikumiError, IOE] a -> IO (Either ShikumiError a, [Text])
runCapturing act = do
  ref <- newIORef []
  res <- runEff . runErrorNoCallStack @ShikumiError $ runStubLMCapturing ref act
  texts <- readIORef ref
  pure (res, texts)

tests :: TestTree
tests = testGroup "Propose" [m1, m2, m3]

-- ---------------------------------------------------------------------------
-- M1 — field metadata + program describer
-- ---------------------------------------------------------------------------

m1 :: TestTree
m1 =
  testGroup
    "Propose.M1"
    [ testCase "programFieldNames recovers each node's input/output field names" $
        programFieldNames sentimentProg
          @?= [NodeFieldNames {inputFieldNames = ["text"], outputFieldNames = ["sentiment"]}],
      testCase "renderProgramPseudo renders the node deterministically" $
        renderProgramPseudo sentimentProg @?= "predict(text) -> sentiment",
      testCase "programDescriber returns a description and the prompt carried the pseudo-code" $ do
        let code = renderProgramPseudo sentimentProg
        (res, texts) <-
          runCapturing (runProgram programDescriber (ProgramDescribeIn code "good film => positive"))
        case res of
          Left e -> assertFailure ("unexpected error: " <> show e)
          Right (ProgramDescribeOut d) -> assertBool "non-empty description" (not (T.null d))
        assertBool
          "the describer prompt carried the program pseudo-code"
          (any (T.isInfixOf "predict(text)") texts)
    ]

-- ---------------------------------------------------------------------------
-- M2 — dataset summary, tips, instruction history
-- ---------------------------------------------------------------------------

m2 :: TestTree
m2 =
  testGroup
    "Propose.M2"
    [ testCase "datasetSummary returns a summary and the describer prompt saw a training row" $ do
        (res, texts) <- runCapturing (datasetSummary 2 trainset)
        case res of
          Left e -> assertFailure ("unexpected error: " <> show e)
          Right s -> assertBool "non-empty summary" (not (T.null s))
        assertBool
          "a sampled training row reached the describer"
          (any (T.isInfixOf "good film") texts),
      testCase "tipAt selects deterministically and wraps" $ do
        tipAt 1 @?= (tipBank !! 1)
        tipAt (length tipBank) @?= tipAt 0,
      testCase "renderHistory formats entries and empties" $ do
        renderHistory 5 [PastInstruction "a" 0.5, PastInstruction "b" 0.9]
          @?= "score 0.5 :: a\nscore 0.9 :: b"
        renderHistory 5 [] @?= "No previous instructions."
    ]

-- ---------------------------------------------------------------------------
-- M3 — the assembled proposeInstructions surface
-- ---------------------------------------------------------------------------

m3 :: TestTree
m3 =
  testGroup
    "Propose.M3"
    [ testCase "proposeInstructions returns distinct candidates retaining the current one" $ do
        let req = ProposeRequest sentimentProg 0 "Classify it." [] [] 3 0 2
        res <- runStub (proposeInstructions trainset req)
        case res of
          Left e -> assertFailure ("unexpected error: " <> show e)
          Right (ProposeResult cs) -> do
            assertBool "current instruction retained" ("Classify it." `elem` cs)
            assertBool "candidates are distinct" (cs == nub cs)
            assertBool "more than one candidate" (length cs >= 2),
      testCase "the grounded signals reach the instruction generator" $ do
        let req = ProposeRequest sentimentProg 0 "Classify it." [] [] 3 0 2
        (res, texts) <- runCapturing (proposeInstructions trainset req)
        case res of
          Left e -> assertFailure ("unexpected error: " <> show e)
          Right _ -> pure ()
        let genReqs = filter (T.isInfixOf "## proposedInstruction ##") texts
        assertBool "at least one generator request" (not (null genReqs))
        assertBool
          "dataset summary reached the generator"
          (any (T.isInfixOf "A sentiment dataset") genReqs)
        assertBool
          "the node's field names reached the generator (via the module signature)"
          (any (T.isInfixOf "predict(text) -> sentiment") genReqs)
        assertBool
          "the creative tip reached the generator"
          (any (T.isInfixOf (tipAt 1)) genReqs),
      testCase "the surface drives a MIPROv2-shaped caller" $ do
        res <- runStub (miproShapedPropose trainset sentimentProg 3)
        case res of
          Left e -> assertFailure ("unexpected error: " <> show e)
          Right perNode -> case perNode of
            [node0] -> assertBool "the node got candidates" (not (null node0))
            _ -> assertFailure ("expected one node, got " <> show (length perNode))
    ]

-- | A stand-in for MIPROv2's proposal stage: for each node, ask the grounded
-- proposer for @n@ candidates. Proves the shared contract is usable before MIPROv2
-- exists — it compiles against 'proposeInstructions' exactly as EP-20 will.
miproShapedPropose ::
  (LLM :> es, Error ShikumiError :> es) =>
  Dataset Sentence Label ->
  Program Sentence Label ->
  Int ->
  Eff es [[Text]]
miproShapedPropose ds prog n =
  forM [0 .. length (foldParams prog) - 1] $ \k ->
    rankedCandidates <$> proposeInstructions ds (ProposeRequest prog k "" [] [] n 0 2)
