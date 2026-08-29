{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE OverloadedStrings #-}

-- | EP-27 M3: @codeAct@ — a multi-turn loop whose action is a code snippet that may
-- call provided tools. Verified hermetically: a snippet calls a registered tool
-- (@addOne@) via the @call("name", args)@ convention, a second snippet computes a
-- value in the sandbox, the loop records a two-step 'Trajectory', finishes, and the
-- typed answer is extracted.
module CodeActSpec (tests) where

import Baikai (emptyModel)
import Control.Lens ((&), (.~))
import Data.Aeson (object, (.=))
import Data.Generics.Labels ()
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import Effectful (runEff)
import Effectful.Error.Static (runErrorNoCallStack)
import GHC.Generics (Generic)
import MockLLM (mkTextResponse, mkUsageResponse, runAgent, runMockLLMThrowingOn)
import Shikumi.Adapter (ToPrompt)
import Shikumi.Agent.ReAct (Action (..), Step (..), Termination (..), Trajectory (..))
import Shikumi.CodeExec.CodeAct (CodeActConfig (..), codeActWithTrajectory, defaultCodeActConfig)
import Shikumi.CodeExec.Interpreter (CodeInterpreter (..))
import Shikumi.CodeExec.Prompt (encodeText)
import Shikumi.Compaction (CompactionConfig (..), defaultCompactionConfig)
import Shikumi.Error (ShikumiError (..))
import Shikumi.Program (runProgram)
import Shikumi.Schema (FromModel, ToSchema, Validatable)
import Shikumi.Signature (Signature, mkSignature)
import Shikumi.Tool (SomeTool (..), Tool, ToolRegistry, mkRegistry, mkTool)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

newtype Task = Task {task :: Text}
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToPrompt)

newtype CalcAnswer = CalcAnswer {value :: Int}
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToSchema, FromModel, ToPrompt)

instance Validatable CalcAnswer

newtype AddIn = AddIn {n :: Int}
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToSchema, FromModel)

instance Validatable AddIn

-- | A tool that adds one to its argument.
addOneTool :: Tool AddIn Int
addOneTool = mkTool "addOne" "Add one to the integer n." (\(AddIn k) -> pure (k + 1))

registry :: ToolRegistry
registry = mkRegistry [SomeTool addOneTool]

alwaysFail :: CodeInterpreter
alwaysFail = CodeInterpreter (\_ -> pure (Left "sandbox disabled"))

sig :: Signature Task CalcAnswer
sig = mkSignature "Answer the task, using tools from code when helpful."

-- | A model turn JSON object @{code, finished}@.
turn :: Text -> Bool -> Text
turn code finished = encodeText (object ["code" .= code, "finished" .= finished])

tests :: TestTree
tests =
  testGroup
    "CodeActSpec"
    [ testCase "a code snippet calls a tool, accumulates a 2-step trajectory, extracts the answer" $ do
        let script =
              [ mkTextResponse (turn "call(\"addOne\", {\"n\": 41})" False),
                mkTextResponse (turn "result = 42" True),
                mkTextResponse "{\"value\": 42}"
              ]
        out <-
          runAgent
            script
            (codeActWithTrajectory defaultCodeActConfig sig registry)
            (Task "add one to 41")
        case out of
          Right (answer, traj) -> do
            answer @?= CalcAnswer 42
            V.length (steps traj) @?= 2
            termination traj @?= TerminatedFinish
            -- the first step's observation is the tool result (addOne 41 = 42)
            observation (V.head (steps traj)) @?= Just "42"
          Left e -> assertFailure ("expected a typed answer, got " <> show e),
      testCase "interpreter errors are tagged in observations" $ do
        let cfg = defaultCodeActConfig {interpreter = alwaysFail}
            script =
              [ mkTextResponse (turn "1 / 0" True),
                mkTextResponse "{\"value\": 0}"
              ]
        out <- runAgent script (codeActWithTrajectory cfg sig registry) (Task "try bad code")
        case out of
          Right (_answer, traj) -> case V.toList (steps traj) of
            [Step {observation = Just obs}] ->
              assertBool "observation tags code failure" ("Error: code failed: sandbox disabled" `T.isInfixOf` obs)
            other -> assertFailure ("expected one code step, got " <> show other)
          Left e -> assertFailure ("expected a typed answer, got " <> show e),
      testCase "usage-triggered compaction injects a summarized CodeAct step" $ do
        let cfg =
              defaultCodeActConfig
                { maxIters = 3,
                  compaction = defaultCompactionConfig {reserveTokens = 10, keepRecent = 1}
                }
            model = emptyModel & #contextWindow .~ 100
            script =
              [ mkUsageResponse model 10 (turn "result = 1" False),
                mkUsageResponse model 90 (turn "result = 2" False),
                mkTextResponse "summary of the first code step",
                mkUsageResponse model 10 (turn "result = 42" True),
                mkTextResponse "{\"value\": 42}"
              ]
        out <- runAgent script (codeActWithTrajectory cfg sig registry) (Task "compute 42")
        case out of
          Right (answer, traj) -> do
            answer @?= CalcAnswer 42
            assertBool "trajectory contains summary step" (any ((== Summarized) . action) (V.toList (steps traj)))
          Left e -> assertFailure ("expected a typed answer, got " <> show e),
      testCase "context overflow is caught, compacted, and retried once" $ do
        let cfg =
              defaultCodeActConfig
                { maxIters = 3,
                  compaction = defaultCompactionConfig {reserveTokens = 10, keepRecent = 0}
                }
            script =
              [ mkTextResponse (turn "result = 1" False),
                mkTextResponse "reactive summary",
                mkTextResponse (turn "result = 42" True),
                mkTextResponse "{\"value\": 42}"
              ]
            prog = codeActWithTrajectory cfg sig registry
        out <-
          runEff
            . runErrorNoCallStack @ShikumiError
            . runMockLLMThrowingOn [2] (ContextWindowExceeded "context length exceeded") script
            $ runProgram prog (Task "compute 42")
        case out of
          Right (answer, traj) -> do
            answer @?= CalcAnswer 42
            assertBool "trajectory contains reactive summary step" (any ((== Summarized) . action) (V.toList (steps traj)))
          Left e -> assertFailure ("expected a typed answer, got " <> show e),
      testCase "disabled CodeAct compaction propagates context overflow" $ do
        let cfg =
              defaultCodeActConfig
                { maxIters = 3,
                  compaction = defaultCompactionConfig {enabled = False, reserveTokens = 10, keepRecent = 0}
                }
            script =
              [ mkTextResponse (turn "result = 1" False),
                mkTextResponse "unused summary",
                mkTextResponse (turn "result = 42" True),
                mkTextResponse "{\"value\": 42}"
              ]
            prog = codeActWithTrajectory cfg sig registry
        out <-
          runEff
            . runErrorNoCallStack @ShikumiError
            . runMockLLMThrowingOn [2] (ContextWindowExceeded "context length exceeded") script
            $ runProgram prog (Task "compute 42")
        out @?= Left (ContextWindowExceeded "context length exceeded")
    ]
