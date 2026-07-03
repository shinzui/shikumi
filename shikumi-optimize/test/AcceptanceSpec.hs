{-# LANGUAGE TypeApplications #-}

-- | M5 — the end-to-end acceptance that proves the whole point. A deliberately
-- underspecified sentiment program (empty instruction, no demos) answers a
-- /held-out/ set it never sees during search poorly (every answer is the
-- never-correct @"neutral"@, score 0). After @optimize@ over a disjoint training
-- set, the returned 'CompiledProgram' answers the same held-out set strictly
-- better (a perfect 1.0). The improvement is shown for three different strategies
-- (bootstrap, labeled few-shot, instruction search), so it is not specific to one.
--
-- Everything runs offline against the deterministic stub LM — no network, no key,
-- reproducible.
module AcceptanceSpec (tests) where

import Control.Monad (when)
import Data.IORef (newIORef, readIORef)
import Data.Text qualified as T
import Effectful (Eff, IOE, runEff)
import Effectful.Concurrent (Concurrent, runConcurrent)
import Effectful.Error.Static (Error, runErrorNoCallStack)
import Effectful.Prim (Prim, runPrim)
import Shikumi.Compile.Types (Compiler (runCompiler), compiledProgram)
import Shikumi.Compile.ZeroShot (zeroShot)
import Shikumi.Effect.Time (Time, runTime)
import Shikumi.Error (ShikumiError)
import Shikumi.Eval (Dataset, Prediction, Score, boolScore, dataset, exactMatch, example, predictionPrimary)
import Shikumi.LLM (LLM)
import Shikumi.Optimize
import Shikumi.Program (Program)
import StubLM
  ( Label (..),
    Sentence (..),
    ruleInstruction,
    ruled,
    runStubLM,
    runStubLMCapturing,
    sentimentPipeline,
    sentimentProg,
  )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))

runStub :: Eff '[LLM, Error ShikumiError, Concurrent, Time, Prim, IOE] a -> IO (Either ShikumiError a)
runStub act = runEff . runPrim . runTime . runConcurrent . runErrorNoCallStack @ShikumiError $ runStubLM act

-- | Six labelled training examples spanning both classes (the @good@/@bad@
-- lexicon), across three topics.
trainset :: Dataset Sentence Label
trainset =
  dataset
    [ example (Sentence "good film") (Label "positive"),
      example (Sentence "good book") (Label "positive"),
      example (Sentence "good song") (Label "positive"),
      example (Sentence "bad film") (Label "negative"),
      example (Sentence "bad book") (Label "negative"),
      example (Sentence "bad song") (Label "negative")
    ]

-- | A disjoint held-out set (different topics) the optimizer never sees.
heldout :: Dataset Sentence Label
heldout =
  dataset
    [ example (Sentence "good movie") (Label "positive"),
      example (Sentence "good meal") (Label "positive"),
      example (Sentence "bad movie") (Label "negative"),
      example (Sentence "bad meal") (Label "negative")
    ]

-- | The teacher for bootstrap: the student with the ground-truth-unlocking
-- instruction baked in, so it classifies the training set correctly.
teacher :: Program Sentence Label
teacher = runCompiler (zeroShot ruleInstruction) sentimentProg

-- | The deliberately-underspecified student.
underspecified :: Program Sentence Label
underspecified = sentimentProg

tests :: TestTree
tests =
  testGroup
    "M5 acceptance"
    [ testCase "optimization strictly improves held-out score (3 strategies)" $ do
        res <- runStub $ do
          before <- scoreOn heldout exactMatch underspecified
          afterBoot <- do
            cp <- optimize (bootstrapFewShot teacher defaultBudget) trainset exactMatch underspecified
            scoreOn heldout exactMatch (compiledProgram cp)
          afterLabeled <- do
            cp <- optimize (labeledFewShot 2) trainset exactMatch underspecified
            scoreOn heldout exactMatch (compiledProgram cp)
          afterInstr <- do
            cp <- optimize (instructionSearch 3 defaultBudget) trainset exactMatch underspecified
            scoreOn heldout exactMatch (compiledProgram cp)
          pure (before, afterBoot, afterLabeled, afterInstr)
        case res of
          Left e -> assertFailure ("unexpected error: " <> show e)
          Right (before, afterBoot, afterLabeled, afterInstr) -> do
            assertBool ("before should be low, got " <> show before) (before < 0.5)
            improved "bootstrapFewShot" before afterBoot
            improved "labeledFewShot" before afterLabeled
            improved "instructionSearch" before afterInstr,
      testGroup
        "seeding over multi-node programs"
        [ testCase "instructionSearch optimizes node 0 without changing node 1" $
            checkPipeline "instructionSearch" (instructionSearch 3 defaultBudget) True,
          testCase "copro optimizes node 0 without changing node 1" $
            checkPipeline "copro" (copro defaultCoproConfig) True,
          testCase "miprov2 keeps the echo node's effective instruction" $
            checkPipeline "miprov2" (miprov2 Miprov2Light) False,
          testCase "gepa keeps the echo node's effective instruction" $
            checkPipeline "gepa" (gepa reflectiveProposer fbMetric defaultBudget) False,
          testCase "instructionSearch scores the true student as a candidate" $ do
            ref <- newIORef []
            res <-
              runEff . runPrim . runTime . runConcurrent . runErrorNoCallStack @ShikumiError $
                runStubLMCapturing ref (optimize (instructionSearch 1 defaultBudget) trainset exactMatch ruled)
            case res of
              Left e -> assertFailure ("unexpected error: " <> show e)
              Right _ -> pure ()
            captured <- readIORef ref
            assertBool
              "expected a scored request rendered with the RULE signature instruction"
              (any (\txt -> ruleInstruction `T.isInfixOf` txt && "text: good" `T.isInfixOf` txt) captured)
        ]
    ]
  where
    -- Strictly higher than before, and at least a floor of 0.75, so the test fails
    -- loudly if a future change makes an optimizer a near-no-op.
    improved name before after = do
      assertBool
        (name <> ": expected " <> show after <> " > " <> show before)
        (after > before)
      assertBool
        (name <> ": expected " <> show after <> " >= 0.75")
        (after >= 0.75)

fbMetric :: Label -> Prediction Label -> (Score, T.Text)
fbMetric expd p =
  let correct = expd == predictionPrimary p
   in (boolScore correct, if correct then "" else "be more specific")

checkPipeline :: String -> Optimizer Sentence Label -> Bool -> Assertion
checkPipeline name opt requireFloor = do
  res <- runStub $ do
    before <- scoreOn heldout exactMatch sentimentPipeline
    cp <- optimize opt trainset exactMatch sentimentPipeline
    let out = compiledProgram cp
    after <- scoreOn heldout exactMatch out
    pure (before, after, effectiveInstructionAt 1 out)
  case res of
    Left e -> assertFailure ("unexpected error: " <> show e)
    Right (before, after, node1Instruction) -> do
      assertBool (name <> ": expected " <> show after <> " >= " <> show before) (after >= before)
      when requireFloor $
        assertBool (name <> ": expected " <> show after <> " >= 0.75") (after >= 0.75)
      node1Instruction @?= "Echo the sentiment label unchanged."
