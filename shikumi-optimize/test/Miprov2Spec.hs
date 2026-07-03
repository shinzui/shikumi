{-# LANGUAGE TypeApplications #-}

-- | EP-20 acceptance: MIPROv2. Hermetic, offline. The headline (M3) is that on a
-- joint-win task — where a sentence is answered correctly only if /both/ a @RULE@
-- instruction and a covering demo are present — MIPROv2's joint search lifts the
-- held-out score to 1.0, strictly above the 0.5 that single-axis @instructionSearch@
-- can reach. M1 checks candidate generation, M2 the search surrogate (budget +
-- joint selection), and M3 the lift plus the serialization round-trip.
module Miprov2Spec (tests) where

import Control.Lens ((&), (.~), (?~))
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
    Miprov2Auto (..),
    Miprov2Config (..),
    bootstrapDemoCandidates,
    defaultBudget,
    instructionSearch,
    miprov2,
    miprov2Auto,
    miprov2With,
    optimize,
    proposeInstructionCandidates,
    scoreOn,
    searchJoint,
  )
import Shikumi.Program (mapParamsAt)
import StubLM
  ( Label (..),
    Sentence (..),
    ruleInstruction,
    runJointStubLM,
    runJointStubLMCounting,
    sentimentProg,
  )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

-- ---------------------------------------------------------------------------
-- Fixtures and run helpers
-- ---------------------------------------------------------------------------

-- | Region A (good/bad) needs a RULE instruction; region B (great/terrible) needs a
-- covering demo. See "StubLM".'StubLM.runJointStubLM'.
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

-- | Run an action under the joint-task stub with the five optimizer effects.
runJoint :: Eff '[LLM, Error ShikumiError, Concurrent, Time, Prim, IOE] a -> IO (Either ShikumiError a)
runJoint act =
  runEff . runPrim . runTime . runConcurrent . runErrorNoCallStack @ShikumiError $ runJointStubLM act

cfgLight :: Miprov2Config
cfgLight = miprov2Auto Miprov2Light

tests :: TestTree
tests = testGroup "Miprov2" [candidates, search, acceptance, serialize]

-- ---------------------------------------------------------------------------
-- M1 — candidate generation
-- ---------------------------------------------------------------------------

candidates :: TestTree
candidates =
  testGroup
    "candidates"
    [ testCase "proposeInstructionCandidates returns the current instruction first plus a RULE candidate" $ do
        res <-
          runJoint $ do
            demoCands <- bootstrapDemoCandidates cfgLight sentimentProg jointTrain exactMatch sentimentProg
            proposeInstructionCandidates cfgLight sentimentProg jointTrain demoCands
        case res of
          Left e -> assertFailure ("unexpected error: " <> show e)
          Right [node0] -> do
            length node0 @?= numInstructCandidates cfgLight
            take 1 node0 @?= [""] -- the node's current (empty) instruction, first
            assertBool "contains the RULE instruction" (ruleInstruction `elem` node0)
          Right other -> assertFailure ("expected one node, got " <> show (length other)),
      testCase "bootstrapDemoCandidates yields an empty set then a non-empty labelled set" $ do
        res <- runJoint (bootstrapDemoCandidates cfgLight sentimentProg jointTrain exactMatch sentimentProg)
        case res of
          Left e -> assertFailure ("unexpected error: " <> show e)
          Right [sets] -> do
            assertBool "candidate 0 is the empty set" (take 1 sets == [[]])
            assertBool "at least one non-empty candidate set" (any (not . null) sets)
          Right other -> assertFailure ("expected one node, got " <> show (length other))
    ]

-- ---------------------------------------------------------------------------
-- M2 — the search surrogate
-- ---------------------------------------------------------------------------

search :: TestTree
search =
  testGroup
    "search"
    [ testCase "searchJoint selects both axes, beating any single-axis choice" $ do
        res <-
          runJoint $ do
            demoCands <- bootstrapDemoCandidates cfgLight sentimentProg jointTrain exactMatch sentimentProg
            instrCands <- proposeInstructionCandidates cfgLight sentimentProg jointTrain demoCands
            best <- searchJoint cfgLight jointTrain exactMatch sentimentProg instrCands demoCands
            joint <- scoreOn jointHeldout exactMatch best
            ruleOnly <-
              scoreOn
                jointHeldout
                exactMatch
                (mapParamsAt 0 (\ps -> ps & #instructionOverride ?~ ruleInstruction) sentimentProg)
            pure (joint, ruleOnly)
        case res of
          Left e -> assertFailure ("unexpected error: " <> show e)
          Right (joint, ruleOnly) -> do
            ruleOnly @?= 0.5
            assertBool ("joint " <> show joint <> " should beat single-axis " <> show ruleOnly) (joint > ruleOnly)
            joint @?= 1.0,
      testCase "searchJoint honors the LM-call budget" $ do
        ref <- newIORef (0 :: Int)
        let cfg = cfgLight & #numTrials .~ 5 & #minibatchSize .~ 2 & #budget .~ Budget {maxLmCalls = 8, maxCandidates = 32}
            instrCands = [["", ruleInstruction]]
            demoCands = [[[], []]]
        res <-
          runEff . runPrim . runTime . runConcurrent . runErrorNoCallStack @ShikumiError $
            runJointStubLMCounting ref (searchJoint cfg jointTrain exactMatch sentimentProg instrCands demoCands)
        case res of
          Left e -> assertFailure ("unexpected error: " <> show e)
          Right _ -> pure ()
        count <- readIORef ref
        assertBool ("expected 0 < calls <= 8, got " <> show count) (count > 0 && count <= 8)
    ]

-- ---------------------------------------------------------------------------
-- M3 — the held-out lift and serialization round-trip
-- ---------------------------------------------------------------------------

acceptance :: TestTree
acceptance =
  testGroup
    "acceptance"
    [ testCase "miprov2 lifts held-out score above before and above instructionSearch" $ do
        res <-
          runJoint $ do
            before <- scoreOn jointHeldout exactMatch sentimentProg
            cpInstr <- optimize (instructionSearch 3 defaultBudget) jointTrain exactMatch sentimentProg
            afterInstr <- scoreOn jointHeldout exactMatch (compiledProgram cpInstr)
            cpMipro <- optimize (miprov2With cfgLight sentimentProg) jointTrain exactMatch sentimentProg
            afterMipro <- scoreOn jointHeldout exactMatch (compiledProgram cpMipro)
            pure (before, afterInstr, afterMipro)
        case res of
          Left e -> assertFailure ("unexpected error: " <> show e)
          Right (before, afterInstr, afterMipro) -> do
            assertBool ("before should be low, got " <> show before) (before < 0.5)
            assertBool ("miprov2 should lift above before: " <> show (before, afterMipro)) (afterMipro > before)
            assertBool
              ("miprov2 " <> show afterMipro <> " should beat instructionSearch " <> show afterInstr)
              (afterMipro > afterInstr)
            assertBool ("miprov2 should reach the floor, got " <> show afterMipro) (afterMipro >= 0.75),
      testCase "miprov2With shares one budget across bootstrap, proposal, and search" $ do
        ref <- newIORef (0 :: Int)
        let cfg = cfgLight & #budget .~ Budget {maxLmCalls = 4, maxCandidates = 32}
        res <-
          runEff . runPrim . runTime . runConcurrent . runErrorNoCallStack @ShikumiError $
            runJointStubLMCounting ref (optimize (miprov2With cfg sentimentProg) jointTrain exactMatch sentimentProg)
        case res of
          Left e -> assertFailure ("unexpected error: " <> show e)
          Right _ -> pure ()
        count <- readIORef ref
        assertBool ("expected 0 < calls <= 4, got " <> show count) (count > 0 && count <= 4),
      testCase "miprov2 preset stays within the default budget" $ do
        ref <- newIORef (0 :: Int)
        res <-
          runEff . runPrim . runTime . runConcurrent . runErrorNoCallStack @ShikumiError $
            runJointStubLMCounting ref (optimize (miprov2 Miprov2Light) jointTrain exactMatch sentimentProg)
        case res of
          Left e -> assertFailure ("unexpected error: " <> show e)
          Right _ -> pure ()
        count <- readIORef ref
        assertBool ("expected 0 < calls <= 200, got " <> show count) (count > 0 && count <= maxLmCalls defaultBudget)
    ]

serialize :: TestTree
serialize =
  testGroup
    "serialize"
    [ testCase "miprov2 output round-trips through encodeCompiled/decodeCompiledOnto" $ do
        res <-
          runJoint $ do
            cp <- optimize (miprov2With cfgLight sentimentProg) jointTrain exactMatch sentimentProg
            let bytes = encodeCompiled cp
            case decodeCompiledOnto sentimentProg bytes of
              Left err -> pure (Left err)
              Right decoded -> do
                a <- scoreOn jointHeldout exactMatch (compiledProgram cp)
                b <- scoreOn jointHeldout exactMatch (compiledProgram decoded)
                pure (Right (a, b))
        case res of
          Left e -> assertFailure ("unexpected error: " <> show e)
          Right (Left err) -> assertFailure ("decode failed: " <> err)
          Right (Right (a, b)) -> a @?= b
    ]
