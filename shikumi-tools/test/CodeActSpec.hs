{-# LANGUAGE DeriveAnyClass #-}

-- | EP-27 M3: @codeAct@ — a multi-turn loop whose action is a code snippet that may
-- call provided tools. Verified hermetically: a snippet calls a registered tool
-- (@addOne@) via the @call("name", args)@ convention, a second snippet computes a
-- value in the sandbox, the loop records a two-step 'Trajectory', finishes, and the
-- typed answer is extracted.
module CodeActSpec (tests) where

import Data.Aeson (object, (.=))
import Data.Text (Text)
import Data.Vector qualified as V
import GHC.Generics (Generic)
import MockLLM (mkTextResponse, runAgent)
import Shikumi.Adapter (ToPrompt)
import Shikumi.Agent.ReAct (Step (..), Termination (..), Trajectory (..))
import Shikumi.CodeExec.CodeAct (codeActWithTrajectory, defaultCodeActConfig)
import Shikumi.CodeExec.Prompt (encodeText)
import Shikumi.Schema (FromModel, ToSchema)
import Shikumi.Signature (Signature, mkSignature)
import Shikumi.Tool (SomeTool (..), Tool, ToolRegistry, mkRegistry, mkTool)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))

newtype Task = Task {task :: Text}
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToPrompt)

newtype CalcAnswer = CalcAnswer {value :: Int}
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToSchema, FromModel, ToPrompt)

newtype AddIn = AddIn {n :: Int}
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToSchema, FromModel)

-- | A tool that adds one to its argument.
addOneTool :: Tool AddIn Int
addOneTool = mkTool "addOne" "Add one to the integer n." (\(AddIn k) -> pure (k + 1))

registry :: ToolRegistry
registry = mkRegistry [SomeTool addOneTool]

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
          Left e -> assertFailure ("expected a typed answer, got " <> show e)
    ]
