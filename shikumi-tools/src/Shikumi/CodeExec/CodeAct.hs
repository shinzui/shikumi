{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | @codeAct@ (EP-27): a multi-turn loop where each /action/ is a code snippet that
-- may call provided tools, accumulating a 'Trajectory', then extracting the typed
-- answer. It mirrors DSPy's @CodeAct@ (a ReAct loop whose action is code) and reuses
-- 'Shikumi.Agent.ReAct'\'s @Trajectory@/@Step@/@Termination@ data model.
--
-- The hermetic restricted interpreter does not itself call host functions, so tool
-- use is handled at the /protocol/ level: a snippet of the exact form
-- @call("\<toolName\>", \<argsJSON\>)@ is recognized by the loop and dispatched
-- through the typed 'Shikumi.Tool.runToolCall'; any other snippet is evaluated by the
-- sandbox and its output (or error) becomes the observation. A real subprocess
-- interpreter (EP-27 M4) would instead inject the tool functions into the
-- interpreter and call them natively, and may relax this convention.
--
-- Like @react@/@programOfThought@, the whole loop is one 'Shikumi.Program.Embed'
-- node, so @codeAct@ carries no tunable parameters (@foldParams (codeAct sig reg) ==
-- []@) and composes/serializes unchanged.
module Shikumi.CodeExec.CodeAct
  ( CodeActConfig (..),
    defaultCodeActConfig,
    codeAct,
    codeActWithTrajectory,
  )
where

import Baikai (Model, Response, ToolCall, Usage, _Model, _ToolCall)
import Control.Lens ((&), (.~), (^.))
import Data.Aeson (Value (..), eitherDecodeStrict)
import Data.Aeson.KeyMap qualified as KM
import Data.Generics.Labels ()
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (encodeUtf8)
import Data.Vector qualified as V
import Effectful (Eff, (:>))
import Effectful.Error.Static (Error, catchError, throwError)
import Shikumi.Adapter (ToPrompt (toPrompt), responseText)
import Shikumi.Agent.ReAct (Action (..), Step (..), Termination (..), Trajectory (..), renderStepLine, renderTrajectory, summaryStep)
import Shikumi.CodeExec.Interpreter (CodeInterpreter (..), restrictedInterpreter)
import Shikumi.CodeExec.Prompt (encodeText, schemaInstruction, simpleContext, stripFences)
import Shikumi.Compaction (CompactionConfig (..), compactTail, defaultCompactionConfig, usageExceedsWindow)
import Shikumi.Error (ShikumiError (..))
import Shikumi.LLM (LLM, complete)
import Shikumi.Program (Program (FMap), embed)
import Shikumi.Schema (FromModel, ToSchema, Validatable, parseOutput, toSchema)
import Shikumi.Signature (Signature, getInstruction)
import Shikumi.Tool (ToolRegistry, registryTools, renderToolError, runToolCall, someToolDescription, someToolName, someToolSchema)

-- | How @codeAct@ runs: the hard iteration cap, the sandbox, and trajectory
-- compaction for long runs.
data CodeActConfig = CodeActConfig
  { maxIters :: !Int,
    interpreter :: !CodeInterpreter,
    compaction :: !CompactionConfig
  }

-- | Five iterations, the hermetic 'restrictedInterpreter'.
defaultCodeActConfig :: CodeActConfig
defaultCodeActConfig =
  CodeActConfig
    { maxIters = 5,
      interpreter = restrictedInterpreter,
      compaction = defaultCompactionConfig
    }

-- | Build a @codeAct@ agent returning the typed answer, dropping the trajectory.
codeAct ::
  (ToPrompt i, ToSchema o, FromModel o, Validatable o) =>
  Signature i o ->
  ToolRegistry ->
  Program i o
codeAct sig reg = FMap fst (codeActWithTrajectory defaultCodeActConfig sig reg)

-- | Build a @codeAct@ agent that also returns the recorded 'Trajectory'.
codeActWithTrajectory ::
  (ToPrompt i, ToSchema o, FromModel o, Validatable o) =>
  CodeActConfig ->
  Signature i o ->
  ToolRegistry ->
  Program i (o, Trajectory)
codeActWithTrajectory cfg sig reg = embed (codeActLoop cfg sig reg)

-- | The loop body, in exactly the @Embed@ row.
codeActLoop ::
  forall i o es.
  (LLM :> es, Error ShikumiError :> es, ToPrompt i, ToSchema o, FromModel o, Validatable o) =>
  CodeActConfig ->
  Signature i o ->
  ToolRegistry ->
  i ->
  Eff es (o, Trajectory)
codeActLoop cfg sig reg i = do
  traj0 <- loop 0 []
  (o, traj) <- extract traj0
  pure (o, traj)
  where
    loop :: Int -> [Step] -> Eff es Trajectory
    loop iter acc
      | iter >= maxIters cfg =
          pure (Trajectory (V.fromList (reverse acc)) (TerminatedMaxIters iter))
      | otherwise = do
          (accForPrompt, resp) <- completeTurnRecover acc
          case parseCodeReply (responseText resp) of
            Left perr -> loop (iter + 1) (correctiveStep perr : accForPrompt)
            Right (code, finished) -> do
              (act, obs) <- runAction code
              let step = Step {thought = "", action = act, observation = Just obs}
              acc' <- compactAcc (resp ^. #model) (resp ^. #message . #usage) (step : accForPrompt)
              if finished
                then pure (Trajectory (V.fromList (reverse acc')) TerminatedFinish)
                else loop (iter + 1) acc'

    -- A tool call snippet (call("name", args)) dispatches through runToolCall; any
    -- other snippet runs in the sandbox. Both produce an observation text.
    runAction :: Text -> Eff es (Action, Text)
    runAction code = case parseCall code of
      Just (nm, args) -> do
        res <- runToolCall reg (mkToolCall nm args)
        pure (CallTool nm args, either renderToolError id res)
      Nothing -> do
        r <- runCode (interpreter cfg) code
        pure (CallTool "exec" (String code), either ("Error: code failed: " <>) id r)

    extract :: Trajectory -> Eff es (o, Trajectory)
    extract traj = do
      let prompt = "Task:\n" <> toPrompt i <> "\n\nTrajectory:\n" <> renderTrajectory traj
          (ctx, opts) = simpleContext extractSys prompt
      (trajForExtract, resp) <-
        catchError
          ((traj,) <$> complete _Model ctx opts)
          ( \_cs -> \case
              e@(ContextWindowExceeded {})
                | not (enabled (compaction cfg)) -> throwError e
              ContextWindowExceeded {} -> do
                compacted <- forceCompactTrajectory traj
                let prompt' = "Task:\n" <> toPrompt i <> "\n\nTrajectory:\n" <> renderTrajectory compacted
                    (ctx', opts') = simpleContext extractSys prompt'
                (compacted,) <$> complete _Model ctx' opts'
              e -> throwError e
          )
      o <- either throwError pure (parseOutput (stripFences (responseText resp)))
      pure (o, trajForExtract)

    completeTurnRecover :: [Step] -> Eff es ([Step], Response)
    completeTurnRecover acc = do
      let (ctx, opts) = simpleContext turnSys (turnUser acc)
      catchError
        ((acc,) <$> complete _Model ctx opts)
        ( \_cs -> \case
            e@(ContextWindowExceeded {})
              | not (enabled (compaction cfg)) -> throwError e
            ContextWindowExceeded {} -> do
              compacted <- forceCompactAcc acc
              let (ctx', opts') = simpleContext turnSys (turnUser compacted)
              (compacted,) <$> complete _Model ctx' opts'
            e -> throwError e
        )

    compactAcc :: Model -> Usage -> [Step] -> Eff es [Step]
    compactAcc model usage acc
      | usageExceedsWindow (compaction cfg) model usage = forceCompactAcc acc
      | otherwise = pure acc

    forceCompactAcc :: [Step] -> Eff es [Step]
    forceCompactAcc acc =
      reverse <$> compactTail (compaction cfg) _Model renderStepLine summaryStep (reverse acc)

    forceCompactTrajectory :: Trajectory -> Eff es Trajectory
    forceCompactTrajectory traj = do
      compacted <- compactTail (compaction cfg) _Model renderStepLine summaryStep (V.toList (steps traj))
      pure (traj {steps = V.fromList compacted})

    turnUser acc =
      "Task:\n"
        <> toPrompt i
        <> "\n\n"
        <> if null acc
          then "No steps yet."
          else "Steps so far:\n" <> renderTrajectory (Trajectory (V.fromList (reverse acc)) TerminatedFinish)

    turnSys = getInstruction sig <> "\n\n" <> toolMenu reg <> "\n\n" <> codeActGuide
    extractSys = getInstruction sig <> "\n\n" <> schemaInstruction (toSchema (Proxy @o))

-- | Parse a model turn @{"code": "...", "finished": <bool>}@ (fences stripped).
parseCodeReply :: Text -> Either Text (Text, Bool)
parseCodeReply raw = case eitherDecodeStrict (encodeUtf8 (stripFences raw)) of
  Left e -> Left ("not valid JSON: " <> T.pack e)
  Right (Object o) -> do
    code <- case KM.lookup "code" o of
      Just (String c) -> Right c
      _ -> Left "missing \"code\" string"
    fin <- case KM.lookup "finished" o of
      Just (Bool b) -> Right b
      Nothing -> Right False
      _ -> Left "\"finished\" must be a boolean"
    pure (code, fin)
  Right _ -> Left "expected a JSON object"

-- | Recognize a tool-call snippet @call("name", <argsJSON>)@, decoding the name and
-- arguments. Anything else returns 'Nothing' (it is handed to the sandbox).
parseCall :: Text -> Maybe (Text, Value)
parseCall code = do
  afterOpen <- T.stripPrefix "call(" (T.strip code)
  inner <- T.stripSuffix ")" (T.strip afterOpen)
  case eitherDecodeStrict (encodeUtf8 ("[" <> inner <> "]")) of
    Right (Array v) -> case V.toList v of
      [String nm, args] -> Just (nm, args)
      _ -> Nothing
    _ -> Nothing

-- | A baikai 'ToolCall' from a name and raw arguments object (the id is irrelevant).
mkToolCall :: Text -> Value -> ToolCall
mkToolCall nm args = _ToolCall & #name .~ nm & #arguments .~ args

-- | A synthetic step recording an unparseable reply, fed back as an observation.
correctiveStep :: Text -> Step
correctiveStep perr =
  Step
    { thought = "",
      action = CallTool "" Null,
      observation = Just ("Your previous reply was not a valid {code, finished} object: " <> perr <> ".")
    }

-- | The tool menu rendered into the system prompt.
toolMenu :: ToolRegistry -> Text
toolMenu reg = case registryTools reg of
  [] -> "You have no tools available."
  ts -> "You can call these tools from your code as call(\"name\", {args}):\n" <> T.unlines (map one ts)
  where
    one st =
      "- "
        <> someToolName st
        <> ": "
        <> someToolDescription st
        <> " (arguments schema: "
        <> encodeText (someToolSchema st)
        <> ")"

-- | The action grammar for a code-act turn.
codeActGuide :: Text
codeActGuide =
  "Each turn, reply with exactly one JSON object {\"code\": \"<snippet>\", \"finished\": <true|false>}. "
    <> "The snippet runs in a restricted interpreter (arithmetic + - * / with unary minus, "
    <> "strings with escapes, ++, and len/upper/lower, lists with sum/length/concat). To call a tool, make the snippet exactly "
    <> "call(\"<toolName>\", <argsJSON>). Set finished to true once you have the answer."
