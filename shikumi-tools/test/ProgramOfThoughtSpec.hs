{-# LANGUAGE DeriveAnyClass #-}

-- | EP-27 M2: @programOfThought@ — the model writes code, the sandbox runs it, the
-- result flows into a typed answer. Verified hermetically against the network-free
-- mock LM and the pure 'restrictedInterpreter'. The sandbox is shown to be
-- /load-bearing/ two ways: an always-fail interpreter makes the program give up
-- (proving the loop consults the interpreter's verdict), and an error-then-fix run
-- only reaches the answer because the interpreter really rejected @1 / 0@ and
-- accepted the correction.
module ProgramOfThoughtSpec (tests) where

import Data.Text (Text)
import GHC.Generics (Generic)
import MockLLM (mkTextResponse, runAgent)
import Shikumi.Adapter (ToPrompt)
import Shikumi.CodeExec.Interpreter (CodeInterpreter (..))
import Shikumi.CodeExec.ProgramOfThought (PoTConfig (..), programOfThought, programOfThoughtWith)
import Shikumi.Error (ShikumiError (..))
import Shikumi.Module (predict)
import Shikumi.Program (foldParams)
import Shikumi.Schema (FromModel, ToSchema)
import Shikumi.Signature (Signature, mkSignature)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

newtype Task = Task {task :: Text}
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToPrompt, FromModel)

newtype CalcAnswer = CalcAnswer {value :: Int}
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToSchema, FromModel, ToPrompt)

sig :: Signature Task CalcAnswer
sig = mkSignature "Compute the requested arithmetic result."

-- | A sandbox that always rejects the code, to prove the loop consults it.
alwaysFail :: CodeInterpreter
alwaysFail = CodeInterpreter (\_ -> pure (Left "sandbox disabled"))

tests :: TestTree
tests =
  testGroup
    "ProgramOfThoughtSpec"
    [ testCase "solves an arithmetic task end-to-end (code -> run -> typed answer)" $ do
        -- model emits the code, then (on extract) the typed answer JSON
        out <-
          runAgent
            [mkTextResponse "37 * 19 + 6", mkTextResponse "{\"value\": 709}"]
            (programOfThought sig)
            (Task "multiply 37 by 19 and add 6")
        out @?= Right (CalcAnswer 709),
      testCase "a plain predict baseline returns the (wrong) direct guess" $ do
        out <-
          runAgent
            [mkTextResponse "{\"value\": 700}"]
            (predict sig)
            (Task "multiply 37 by 19 and add 6")
        out @?= Right (CalcAnswer 700),
      testCase "the sandbox is load-bearing: an always-fail interpreter makes it give up" $ do
        out <-
          runAgent
            [mkTextResponse "37 * 19 + 6", mkTextResponse "37 * 19 + 6"]
            (programOfThoughtWith (PoTConfig {maxIters = 2, interpreter = alwaysFail}) sig)
            (Task "multiply 37 by 19 and add 6")
        case out of
          Left (ProviderFailure _) -> pure ()
          other -> assertFailure ("expected ProviderFailure, got " <> show other),
      testCase "error-then-fix: first snippet errors in the sandbox, second succeeds" $ do
        -- 1/0 really errors in restrictedInterpreter -> regenerate -> 6 succeeds
        out <-
          runAgent
            [mkTextResponse "1 / 0", mkTextResponse "6", mkTextResponse "{\"value\": 6}"]
            (programOfThought sig)
            (Task "compute six")
        out @?= Right (CalcAnswer 6),
      testCase "programOfThought carries no params (Embed node)" $
        assertBool "foldParams should be empty" (null (foldParams (programOfThought sig)))
    ]
