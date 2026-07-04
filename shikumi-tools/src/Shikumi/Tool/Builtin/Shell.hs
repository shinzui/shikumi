-- | Built-in shell tool over 'ToolEnv.exec'.
--
-- Security posture: 'bashTool' executes arbitrary model-chosen shell commands
-- through the supplied 'ToolEnv', with whatever filesystem access, environment,
-- and process privileges that environment grants. With 'localToolEnv' this is
-- deliberately non-hermetic host execution for trusted, local, single-operator
-- workflows. Sandboxing is achieved by supplying a confining 'ToolEnv', not by
-- this module.
module Shikumi.Tool.Builtin.Shell
  ( BashReq (..),
    BashResp (..),
    bashTool,
  )
where

import Control.Lens ((^.))
import Data.Aeson (ToJSON)
import Data.Generics.Labels ()
import Data.Text (Text)
import GHC.Generics (Generic)
import Shikumi.Adapter (ToPrompt)
import Shikumi.Schema (FromModel, ToSchema, Validatable)
import Shikumi.Tool (Tool, mkTool)
import Shikumi.Tool.Env (ExecRequest (..), ToolEnv (..))

data BashReq = BashReq
  { command :: !Text,
    cwd :: !(Maybe Text),
    timeoutMs :: !(Maybe Int),
    stdin :: !(Maybe Text)
  }
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToSchema, FromModel, ToPrompt, Validatable)

data BashResp = BashResp
  { exitCode :: !Int,
    stdout :: !Text,
    stderr :: !Text
  }
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToJSON)

bashTool :: ToolEnv -> Tool BashReq BashResp
bashTool env =
  mkTool "bash" "Run a shell command and capture stdout, stderr, and the exit code." $ \req -> do
    result <-
      envExec
        env
        ExecRequest
          { command = req ^. #command,
            cwd = req ^. #cwd,
            timeoutMs = req ^. #timeoutMs,
            stdin = req ^. #stdin
          }
    pure
      BashResp
        { exitCode = result ^. #exitCode,
          stdout = result ^. #stdout,
          stderr = result ^. #stderr
        }
