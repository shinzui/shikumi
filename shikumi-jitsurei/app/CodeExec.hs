{-# LANGUAGE DeriveAnyClass #-}

-- | (12) Code execution: @programOfThought@ and @codeAct@.
--
-- The model writes code, a sandbox runs it, and the result feeds back into a typed
-- answer. Both are ordinary @Program@s (built on @embed@), runnable offline against
-- the hermetic 'restrictedInterpreter' (a tiny arithmetic/string/list DSL — no
-- network, no filesystem, no syscalls).
--
--   * @programOfThought@ asks for a snippet that /computes/ the answer, runs it, and
--     — if it errors — feeds the error back so the model can fix it, before
--     extracting the typed answer.
--   * @codeAct@ is a ReAct-style loop whose action is a code snippet that may call
--     provided tools (via a @call("name", args)@ convention), recording a trajectory.
module Main (main) where

import Data.Aeson (encode, object, (.=))
import Data.ByteString.Lazy qualified as LBS
import Data.Text (Text)
import Data.Text.Encoding (decodeUtf8)
import Data.Vector qualified as V
import GHC.Generics (Generic)
import Shikumi.Adapter (ToPrompt)
import Shikumi.Agent.ReAct (Action (..), Step (..), Trajectory (..))
import Shikumi.CodeExec.CodeAct (codeActWithTrajectory, defaultCodeActConfig)
import Shikumi.CodeExec.ProgramOfThought (programOfThought)
import Shikumi.Jitsurei.Stub (mkTextResponse, runAgent)
import Shikumi.Schema (FromModel, ToSchema)
import Shikumi.Signature (Signature, mkSignature)
import Shikumi.Tool (SomeTool (..), Tool, ToolRegistry, mkRegistry, mkTool)

newtype Task = Task {task :: Text}
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToPrompt, FromModel)

newtype CalcAnswer = CalcAnswer {value :: Int}
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToSchema, FromModel, ToPrompt)

newtype AddIn = AddIn {n :: Int}
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToSchema, FromModel)

calcSig :: Signature Task CalcAnswer
calcSig = mkSignature "Compute the requested result, using tools from code when helpful."

addOneTool :: Tool AddIn Int
addOneTool = mkTool "addOne" "Add one to the integer n." (\(AddIn k) -> pure (k + 1))

registry :: ToolRegistry
registry = mkRegistry [SomeTool addOneTool]

-- A model turn for codeAct: a {code, finished} JSON object.
codeTurn :: Text -> Bool -> Text
codeTurn code finished =
  decodeUtf8 (LBS.toStrict (encode (object ["code" .= code, "finished" .= finished])))

main :: IO ()
main = do
  putStrLn "jitsurei-codeexec: the model writes code, a sandbox runs it, the result flows back\n"

  -- programOfThought: emit code -> run -> extract.
  putStrLn "[programOfThought] solves an arithmetic task a plain guess would miss"
  solved <-
    runAgent
      [mkTextResponse "37 * 19 + 6", mkTextResponse "{\"value\": 709}"]
      (programOfThought calcSig)
      (Task "multiply 37 by 19 and add 6")
  putStrLn $ "  37 * 19 + 6 -> " <> show solved

  -- programOfThought: error-then-fix. The first snippet really errors in the
  -- sandbox (division by zero), the error is fed back, the second succeeds.
  putStrLn "\n[programOfThought] recovers from a sandbox error"
  fixed <-
    runAgent
      [mkTextResponse "1 / 0", mkTextResponse "6", mkTextResponse "{\"value\": 6}"]
      (programOfThought calcSig)
      (Task "compute six")
  putStrLn $ "  1 / 0 (errors) then 6 -> " <> show fixed

  -- codeAct: a code snippet calls a provided tool, then a second computes a value.
  putStrLn "\n[codeAct] a code snippet calls a tool, accumulating a trajectory"
  let script =
        [ mkTextResponse (codeTurn "call(\"addOne\", {\"n\": 41})" False),
          mkTextResponse (codeTurn "result = 42" True),
          mkTextResponse "{\"value\": 42}"
        ]
  acted <- runAgent script (codeActWithTrajectory defaultCodeActConfig calcSig registry) (Task "add one to 41")
  case acted of
    Left err -> putStrLn $ "  failed: " <> show err
    Right (answer, traj) -> do
      putStrLn $ "  answer      -> " <> show answer
      putStrLn $ "  steps:"
      mapM_ printStep (V.toList (steps traj))
  where
    printStep s =
      putStrLn $
        "    - "
          <> describe (action s)
          <> maybe "" (\o -> "  (observed: " <> show o <> ")") (observation s)
    describe (CallTool nm _) = "action " <> show nm
    describe Finish = "finish"
