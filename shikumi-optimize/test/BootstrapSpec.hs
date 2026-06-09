{-# LANGUAGE TypeApplications #-}

-- | M2: bootstrap few-shot. Two tests. (a) 'recoverDemo' turns a typed
-- input/output pair into a JSON 'Demo' that round-trips through @fromModel@ — i.e.
-- the recovered demo is decodable back into the node's typed channel, which is
-- what the run-time adapter does. (b) @bootstrapFewShot@ runs a (rule-bearing)
-- teacher over a training set in which one example carries a deliberately wrong
-- label; the search attaches demos only for the examples the metric judged the
-- teacher correct on, and the mislabelled one is excluded.
module BootstrapSpec (tests) where

import Effectful (Eff, IOE, runEff)
import Effectful.Concurrent (Concurrent, runConcurrent)
import Effectful.Error.Static (Error, runErrorNoCallStack)
import Shikumi.Compile.Types (CompiledProgram, Compiler (runCompiler), compiledProgram)
import Shikumi.Compile.ZeroShot (zeroShot)
import Shikumi.Error (ShikumiError)
import Shikumi.Eval (Dataset, dataset, exactMatch, example)
import Shikumi.LLM (LLM)
import Shikumi.Optimize
import Shikumi.Program (Demo (..), Params (..), Program, programParams)
import Shikumi.Schema (fromModel)
import StubLM (Label (..), Sentence (..), ruleInstruction, runStubLM, sentimentProg)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))

runStub :: Eff '[LLM, Error ShikumiError, Concurrent, IOE] a -> IO (Either ShikumiError a)
runStub act = runEff . runConcurrent . runErrorNoCallStack @ShikumiError $ runStubLM act

-- | A teacher that classifies by the ground-truth rule: the student program with
-- a @RULE@-bearing instruction baked in (and no demos).
teacher :: Program Sentence Label
teacher = runCompiler (zeroShot ruleInstruction) sentimentProg

-- | Three examples; the third is mislabelled (the teacher will say "positive" for
-- "good soup", disagreeing with the "negative" label), so it must be dropped.
trainset :: Dataset Sentence Label
trainset =
  dataset
    [ example (Sentence "good film") (Label "positive"),
      example (Sentence "bad film") (Label "negative"),
      example (Sentence "good soup") (Label "negative")
    ]

-- | The demos baked into a compiled single-node program.
compiledDemos :: CompiledProgram Sentence Label -> [Demo]
compiledDemos cp = case programParams (compiledProgram cp) of
  (ps : _) -> demos ps
  [] -> []

tests :: TestTree
tests =
  testGroup
    "M2 bootstrap"
    [ testCase "recoverDemo produces a round-trippable typed demo" $ do
        let d = recoverDemo (Sentence "good film") (Label "positive")
        (fromModel (demoInput d) :: Either ShikumiError Sentence) @?= Right (Sentence "good film")
        (fromModel (demoOutput d) :: Either ShikumiError Label) @?= Right (Label "positive"),
      testCase "bootstrap attaches demos only for metric-passing teacher runs" $ do
        res <- runStub (optimize (bootstrapFewShot teacher defaultBudget) trainset exactMatch sentimentProg)
        case res of
          Left e -> assertFailure ("unexpected error: " <> show e)
          Right cp -> do
            let ds = compiledDemos cp
                ins = traverse (\d -> fromModel (demoInput d)) ds :: Either ShikumiError [Sentence]
                outs = traverse (\d -> fromModel (demoOutput d)) ds :: Either ShikumiError [Label]
            length ds @?= 2
            ins @?= Right [Sentence "good film", Sentence "bad film"]
            outs @?= Right [Label "positive", Label "negative"]
    ]
