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

import Effectful (Eff, IOE, runEff)
import Effectful.Concurrent (Concurrent, runConcurrent)
import Effectful.Error.Static (Error, runErrorNoCallStack)
import Shikumi.Compile.Types (Compiler (runCompiler), compiledProgram)
import Shikumi.Compile.ZeroShot (zeroShot)
import Shikumi.Error (ShikumiError)
import Shikumi.Eval (Dataset, dataset, exactMatch, example)
import Shikumi.LLM (LLM)
import Shikumi.Optimize
import Shikumi.Program (Program)
import StubLM (Label (..), Sentence (..), ruleInstruction, runStubLM, sentimentProg)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase)

runStub :: Eff '[LLM, Error ShikumiError, Concurrent, IOE] a -> IO (Either ShikumiError a)
runStub act = runEff . runConcurrent . runErrorNoCallStack @ShikumiError $ runStubLM act

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
            improved "instructionSearch" before afterInstr
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
