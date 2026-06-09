{-# LANGUAGE RankNTypes #-}

-- | A golden test for a stub program, run deterministically and offline under a
-- constant mock LM. The committed @test/golden/qa-program.golden@ pins the
-- transcript; the plan records the fail-before/pass-after demonstration.
module GoldenSpec (tests) where

import Effectful (Eff, IOE, runEff)
import Effectful.Error.Static (Error, runErrorNoCallStack)
import EvalFixtures (Answer (..), Question (..), answerResponse, qaProg, runConstLLM)
import Shikumi.Error (ShikumiError)
import Shikumi.Eval.Golden (goldenProgram)
import Shikumi.Eval.Types (Dataset, dataset, example)
import Shikumi.LLM (LLM)
import Test.Tasty (TestTree, testGroup)

-- | Two questions; the constant mock always answers "yes", so the transcript is
-- deterministic regardless of the inputs.
goldenData :: Dataset Question Answer
goldenData =
  dataset
    [ example (Question "what is 2+2?") (Answer "ignored"),
      example (Question "capital of France?") (Answer "ignored")
    ]

-- | Discharge @'[LLM, Error ShikumiError, IOE]@ to 'IO' under the constant mock,
-- failing on a 'ShikumiError'.
runMock :: forall a. Eff '[LLM, Error ShikumiError, IOE] a -> IO a
runMock act = do
  r <- runEff . runErrorNoCallStack @ShikumiError . runConstLLM (answerResponse "yes") $ act
  either (fail . show) pure r

tests :: TestTree
tests =
  testGroup
    "Golden"
    [ goldenProgram
        "qa-program golden"
        "test/golden/qa-program.golden"
        runMock
        goldenData
        qaProg
        answer
    ]
