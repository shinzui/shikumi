{-# LANGUAGE TypeApplications #-}

-- | M0: the package scaffold and the central abstraction. A /no-op optimizer/
-- (one that returns its input program compiled unchanged) driven through
-- 'optimize' yields a 'CompiledProgram' whose extracted program is structurally
-- identical to the input — proving the integration surface (the 'Optimizer'
-- record, the @evaluate@-shaped effect row, EP-9's 'CompiledProgram') compiles
-- and round-trips before any real search is written.
module OptimizeSpec (tests) where

import Effectful (Eff, IOE, runEff)
import Effectful.Concurrent (Concurrent, runConcurrent)
import Effectful.Error.Static (Error, runErrorNoCallStack)
import Shikumi.Compile.Types (compiledProgram)
import Shikumi.Error (ShikumiError)
import Shikumi.Eval (dataset, exactMatch, example)
import Shikumi.LLM (LLM)
import Shikumi.Optimize
import Shikumi.Program (programParams, programShape)
import StubLM (Label (..), Sentence (..), runStubLM, sentimentProg)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))

-- | Run an optimizer/scoring action under the deterministic stub and the
-- @evaluate@ effect row, returning either a 'ShikumiError' or the result.
runStub ::
  Eff '[LLM, Error ShikumiError, Concurrent, IOE] a ->
  IO (Either ShikumiError a)
runStub act =
  runEff . runConcurrent . runErrorNoCallStack @ShikumiError $ runStubLM act

-- | The no-op optimizer: ignore the dataset and metric, return the program
-- compiled unchanged.
noopOptimizer :: Optimizer Sentence Label
noopOptimizer = Optimizer (\_ _ p -> pure (freezeProgram p))

tests :: TestTree
tests =
  testGroup
    "M0 scaffold"
    [ testCase "no-op optimizer round-trips a program through optimize" $ do
        let ds = dataset [example (Sentence "good film") (Label "positive")]
        res <- runStub (optimize noopOptimizer ds exactMatch sentimentProg)
        case res of
          Left e -> assertFailure ("unexpected error: " <> show e)
          Right cp -> do
            -- The compiled program is structurally identical to the input.
            programShape (compiledProgram cp) @?= programShape sentimentProg
            programParams (compiledProgram cp) @?= programParams sentimentProg
    ]
