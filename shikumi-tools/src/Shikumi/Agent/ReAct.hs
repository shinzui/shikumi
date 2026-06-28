{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | ReAct ("Reason + Act") agents as first-class shikumi programs.
--
-- A ReAct agent alternates between /thinking/ and /acting/: at each step the model
-- emits a short thought and either selects a tool with arguments or declares it is
-- finished. The runtime executes the selected tool (via "Shikumi.Tool"), records the
-- result as an /observation/, and asks the model again — until the model finishes or
-- a @maxIters@ bound is hit. A final /extract/ step turns the finished
-- 'Trajectory' into the typed output the caller wanted.
--
-- The whole loop is wrapped in 'Shikumi.Program.Embed', so @react@ is an ordinary
-- @'Program' i o@: it runs under 'Shikumi.Program.runProgram' (the body needs only
-- @LLM@ + @Error ShikumiError@, integration point #4's exact row), is structurally
-- inspectable, and composes with every other shikumi program and combinator.
--
-- Two tool /protocols/ are supported behind one internal interface ('ProtocolImpl'),
-- selected by a 'ToolProtocol' value ('ProtocolAuto' resolves per model via
-- "Shikumi.Adapter"'s 'capabilityFor'): a provider-native function-calling path
-- (baikai @Context.tools@ + @Options.toolChoice@, parsing @AssistantToolCall@ blocks)
-- and a prompt-based fallback that renders an explicit action grammar and parses the
-- model's text. The loop body is protocol-agnostic.
module Shikumi.Agent.ReAct
  ( -- * The trajectory data model
    Action (..),
    Step (..),
    Termination (..),
    Trajectory (..),

    -- * Configuration
    ToolProtocol (..),
    ReActConfig (..),
    defaultReActConfig,

    -- * Building agents
    react,
    reactWithTrajectory,

    -- * The protocol seam
    ProtocolImpl (..),
    resolveProtocolKind,
    resolveProtocol,

    -- * Rendering (exposed for tests/inspection)
    renderTrajectory,
  )
where

import Baikai
  ( AssistantContent (..),
    Context,
    Message,
    Model,
    Options,
    Response,
    TextContent (..),
    Tool,
    ToolCall,
    ToolChoice (..),
    Usage,
    flattenAssistantBlocks,
    user,
    _Context,
    _Model,
    _Options,
    _ToolCall,
  )
import Control.Lens ((&), (.~), (^.))
import Data.Aeson (Value (..), eitherDecodeStrict, encode)
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy qualified as LBS
import Data.Generics.Labels ()
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8, encodeUtf8)
import Data.Vector (Vector)
import Data.Vector qualified as V
import Effectful (Eff, (:>))
import Effectful.Error.Static (Error, catchError, throwError)
import GHC.Generics (Generic)
import Shikumi.Adapter (ModelCapability (..), ToPrompt (toPrompt), attachSchema, capabilityFor)
import Shikumi.Compaction (CompactionConfig, compactTail, defaultCompactionConfig, usageExceedsWindow)
import Shikumi.Error (ShikumiError (..))
import Shikumi.LLM (LLM, complete)
import Shikumi.Program (Program (FMap), embed)
import Shikumi.Schema (FromModel, ToSchema, Validatable, parseOutput, toSchema)
import Shikumi.Signature (Signature, getInstruction)
import Shikumi.Tool (ToolRegistry, registryBaikai, registryTools, renderToolError, runToolCall, someToolDescription, someToolName, someToolSchema)

-- ---------------------------------------------------------------------------
-- The trajectory data model
-- ---------------------------------------------------------------------------

-- | What the model decided to do at a step: invoke a named tool with a raw JSON
-- arguments object, or declare it is finished.
data Action
  = CallTool !Text !Value
  | Finish
  deriving stock (Show, Eq, Generic)

-- | One recorded (thought, action, observation) step. @observation@ is 'Nothing'
-- for 'Finish'; for a tool call it is the tool result text or the rendered
-- 'Shikumi.Tool.ToolError'.
data Step = Step
  { thought :: !Text,
    action :: !Action,
    observation :: !(Maybe Text)
  }
  deriving stock (Show, Eq, Generic)

-- | Why the loop stopped. 'TerminatedBudget' is retained for forward
-- compatibility; the loop itself produces only 'TerminatedFinish' and
-- 'TerminatedMaxIters' (the budget ceiling is enforced one layer down by the
-- resilient @LLM@ interpreter, surfacing as a 'ShikumiError').
data Termination
  = TerminatedFinish
  | TerminatedMaxIters !Int
  | TerminatedBudget
  deriving stock (Show, Eq, Generic)

-- | The recorded sequence of steps plus the reason the loop stopped.
data Trajectory = Trajectory
  { steps :: !(Vector Step),
    termination :: !Termination
  }
  deriving stock (Show, Eq, Generic)

-- ---------------------------------------------------------------------------
-- Configuration
-- ---------------------------------------------------------------------------

-- | Which tool-calling protocol to use. 'ProtocolAuto' resolves per model.
data ToolProtocol
  = ProtocolNative
  | ProtocolPrompt
  | ProtocolAuto
  deriving stock (Show, Eq, Generic)

-- | How an agent runs: the hard iteration cap and the protocol selector.
data ReActConfig = ReActConfig
  { maxIters :: !Int,
    protocol :: !ToolProtocol,
    compaction :: !CompactionConfig
  }
  deriving stock (Show, Eq, Generic)

-- | Six iterations, protocol auto-selected.
defaultReActConfig :: ReActConfig
defaultReActConfig =
  ReActConfig
    { maxIters = 6,
      protocol = ProtocolAuto,
      compaction = defaultCompactionConfig
    }

-- ---------------------------------------------------------------------------
-- Building agents
-- ---------------------------------------------------------------------------

-- | Build a ReAct agent as a @'Program' i o@ that returns the typed answer and
-- drops the trajectory. The ergonomic default.
react ::
  forall i o.
  (ToPrompt i, ToSchema o, FromModel o, Validatable o) =>
  Signature i o ->
  ToolRegistry ->
  ReActConfig ->
  Program i o
react sig reg cfg = FMap fst (reactWithTrajectory sig reg cfg)

-- | Build a ReAct agent that also returns the recorded 'Trajectory', for
-- evaluators/optimizers and tests that assert on the steps.
reactWithTrajectory ::
  forall i o.
  (ToPrompt i, ToSchema o, FromModel o, Validatable o) =>
  Signature i o ->
  ToolRegistry ->
  ReActConfig ->
  Program i (o, Trajectory)
reactWithTrajectory sig reg cfg = embed (reactLoop sig reg cfg)

-- | The agent loop, embedded into a 'Program' by 'reactWithTrajectory'. Runs in
-- exactly 'Shikumi.Program.runProgram'\'s effect row.
reactLoop ::
  forall i o es.
  (LLM :> es, Error ShikumiError :> es, ToPrompt i, ToSchema o, FromModel o, Validatable o) =>
  Signature i o ->
  ToolRegistry ->
  ReActConfig ->
  i ->
  Eff es (o, Trajectory)
reactLoop sig reg cfg i = do
  traj0 <- loop 0 []
  (o, traj) <- extract traj0
  pure (o, traj)
  where
    impl :: ProtocolImpl i o
    impl = resolveProtocol (protocol cfg) _Model sig reg

    -- Propose -> dispatch -> observe, accumulating steps (newest first).
    loop :: Int -> [Step] -> Eff es Trajectory
    loop iter acc
      | iter >= maxIters cfg =
          pure (Trajectory (V.fromList (reverse acc)) (TerminatedMaxIters iter))
      | otherwise = do
          (accForPrompt, resp) <- completeProposeRecover acc
          case parsePropose impl resp of
            Left perr -> loop (iter + 1) (correctiveStep perr : accForPrompt)
            Right (th, Finish) ->
              pure (Trajectory (V.fromList (reverse (Step th Finish Nothing : accForPrompt))) TerminatedFinish)
            Right (th, CallTool nm args) -> do
              res <- runToolCall reg (mkToolCall nm args)
              let obs = either renderToolError id res
                  acc' = Step th (CallTool nm args) (Just obs) : accForPrompt
              acc'' <- compactAcc (resp ^. #model) (resp ^. #message . #usage) acc'
              loop (iter + 1) acc''

    -- The final extract call: render, issue, decode into @o@ (a decode failure
    -- here is the agent's final-answer failure, surfaced as a 'ShikumiError').
    extract :: Trajectory -> Eff es (o, Trajectory)
    extract traj = do
      let (ctx, opts) = renderExtract impl i traj
      (trajForExtract, resp) <-
        catchError
          ((traj,) <$> complete _Model ctx opts)
          ( \_cs -> \case
              ContextWindowExceeded {} -> do
                compacted <- forceCompactTrajectory traj
                let (ctx', opts') = renderExtract impl i compacted
                (compacted,) <$> complete _Model ctx' opts'
              e -> throwError e
          )
      o <- either throwError pure (parseExtract impl resp)
      pure (o, trajForExtract)

    completeProposeRecover :: [Step] -> Eff es ([Step], Response)
    completeProposeRecover acc = do
      let (ctx, opts) = renderPropose impl i (soFar acc)
      catchError
        ((acc,) <$> complete _Model ctx opts)
        ( \_cs -> \case
            ContextWindowExceeded {} -> do
              compacted <- forceCompactAcc acc
              let (ctx', opts') = renderPropose impl i (soFar compacted)
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

    -- A trajectory view of the steps gathered so far (termination is irrelevant
    -- for the propose render).
    soFar :: [Step] -> Trajectory
    soFar acc = Trajectory (V.fromList (reverse acc)) TerminatedFinish

-- | Build a synthetic step recording an unparseable proposal, so the corrective
-- text reaches the model on the next turn (the empty tool name is a sentinel that
-- is never dispatched).
correctiveStep :: Text -> Step
correctiveStep perr =
  Step
    { thought = "",
      action = CallTool "" Null,
      observation =
        Just ("Your previous reply was not a valid action JSON object: " <> perr <> ". Reply with exactly one action object.")
    }

summaryStep :: Text -> Step
summaryStep summaryText =
  Step
    { thought = "(compacted summary of earlier steps)",
      action = CallTool "" Null,
      observation = Just summaryText
    }

renderStepLine :: Step -> Text
renderStepLine s = renderTrajectory (Trajectory (V.singleton s) TerminatedFinish)

-- | A baikai 'ToolCall' built from a name and a raw arguments object (the call id
-- is irrelevant on the prompt path and synthesized on the native path).
mkToolCall :: Text -> Value -> ToolCall
mkToolCall nm args = _ToolCall & #name .~ nm & #arguments .~ args

-- ---------------------------------------------------------------------------
-- The protocol seam
-- ---------------------------------------------------------------------------

-- | The protocol-specific rendering/parsing the loop depends on. Both the native
-- and the prompt implementations satisfy this interface, so the loop body is
-- identical under either seam.
data ProtocolImpl i o = ProtocolImpl
  { renderPropose :: !(i -> Trajectory -> (Context, Options)),
    parsePropose :: !(Response -> Either Text (Text, Action)),
    renderExtract :: !(i -> Trajectory -> (Context, Options)),
    parseExtract :: !(Response -> Either ShikumiError o)
  }

-- | Resolve a (possibly 'ProtocolAuto') selection to a concrete kind for a model.
-- Conservative: a model without native tool support resolves to 'ProtocolPrompt',
-- because a silently-dropped native tool set (baikai does this for CLI providers)
-- would make the loop propose tools that never execute.
resolveProtocolKind :: ToolProtocol -> Model -> ToolProtocol
resolveProtocolKind ProtocolNative _ = ProtocolNative
resolveProtocolKind ProtocolPrompt _ = ProtocolPrompt
resolveProtocolKind ProtocolAuto m = case capabilityFor m of
  NativeSchema -> ProtocolNative
  PromptFallback -> ProtocolPrompt

-- | Build the concrete 'ProtocolImpl' for a model, choosing the native or prompt
-- renderers from 'resolveProtocolKind'.
resolveProtocol ::
  forall i o.
  (ToPrompt i, ToSchema o, FromModel o, Validatable o) =>
  ToolProtocol ->
  Model ->
  Signature i o ->
  ToolRegistry ->
  ProtocolImpl i o
resolveProtocol proto m sig reg = case resolveProtocolKind proto m of
  ProtocolNative -> nativeImpl sig reg
  _ -> promptImpl sig reg

-- ---------------------------------------------------------------------------
-- The prompt protocol
-- ---------------------------------------------------------------------------

promptImpl ::
  forall i o.
  (ToPrompt i, ToSchema o, FromModel o, Validatable o) =>
  Signature i o ->
  ToolRegistry ->
  ProtocolImpl i o
promptImpl sig reg =
  ProtocolImpl
    { renderPropose = \i traj ->
        let sys =
              getInstruction sig
                <> "\n\n"
                <> toolMenu reg
                <> "\n"
                <> proposeGrammar
            msg = user (taskBlock i <> "\n\n" <> historyBlock traj)
         in (buildCtx sys [msg] V.empty Nothing, _Options),
      parsePropose = \resp -> parseActionText (responseText resp),
      renderExtract = \i traj ->
        let sys =
              getInstruction sig
                <> "\n\n"
                <> extractGuide (toSchema (Proxy @o))
            msg = user (taskBlock i <> "\n\n" <> historyBlock traj)
         in (buildCtx sys [msg] V.empty Nothing, _Options),
      parseExtract = \resp -> parseOutput (stripFences (responseText resp))
    }

-- ---------------------------------------------------------------------------
-- The native protocol
-- ---------------------------------------------------------------------------

nativeImpl ::
  forall i o.
  (ToPrompt i, ToSchema o, FromModel o, Validatable o) =>
  Signature i o ->
  ToolRegistry ->
  ProtocolImpl i o
nativeImpl sig reg =
  ProtocolImpl
    { renderPropose = \i traj ->
        let sys =
              getInstruction sig
                <> "\n\nUse a tool when you need one, or answer directly when you have enough information."
            msg = user (taskBlock i <> "\n\n" <> historyBlock traj)
            opts = _Options & #toolChoice .~ Just ToolChoiceAuto
         in (buildCtx sys [msg] (registryBaikai reg) Nothing, opts),
      -- A tool-call block -> CallTool; no tool call (plain text) -> Finish.
      parsePropose = \resp ->
        case toolCallsOf resp of
          (tc : _) -> Right (responseText resp, CallTool (tc ^. #name) (tc ^. #arguments))
          [] -> Right (responseText resp, Finish),
      renderExtract = \i traj ->
        let sys =
              getInstruction sig
                <> "\n\n"
                <> extractGuide (toSchema (Proxy @o))
            msg = user (taskBlock i <> "\n\n" <> historyBlock traj)
            -- Suppress tools so the model answers; attach the output schema (a
            -- no-op until EP-2's responseFormat is wired in the local baikai).
            opts =
              attachSchema (toSchema (Proxy @o)) _Options
                & #toolChoice .~ Just ToolChoiceNone
         in (buildCtx sys [msg] V.empty Nothing, opts),
      parseExtract = \resp -> parseOutput (stripFences (responseText resp))
    }

-- ---------------------------------------------------------------------------
-- Rendering helpers
-- ---------------------------------------------------------------------------

buildCtx :: Text -> [Message] -> Vector Tool -> Maybe ToolChoice -> Context
buildCtx sys msgs tools _ =
  _Context
    & #systemPrompt .~ Just sys
    & #messages .~ V.fromList msgs
    & #tools .~ tools

taskBlock :: (ToPrompt i) => i -> Text
taskBlock i = "Task:\n" <> toPrompt i

-- | Render the steps gathered so far as a readable history.
historyBlock :: Trajectory -> Text
historyBlock traj
  | V.null (steps traj) = "Steps so far: (none)"
  | otherwise = "Steps so far:\n" <> renderTrajectory traj

-- | A human-readable rendering of a trajectory's steps.
renderTrajectory :: Trajectory -> Text
renderTrajectory traj = T.intercalate "\n" (zipWith one [1 :: Int ..] (V.toList (steps traj)))
  where
    one n s =
      "  "
        <> T.pack (show n)
        <> ". thought: "
        <> thought s
        <> "; action: "
        <> renderAction (action s)
        <> maybe "" ("; observation: " <>) (observation s)
    renderAction Finish = "finish"
    renderAction (CallTool nm args) = "call " <> nm <> " " <> encodeText args

-- | The tool menu: each tool's name, description, and compact argument schema.
toolMenu :: ToolRegistry -> Text
toolMenu reg = case registryTools reg of
  [] -> "You have no tools available."
  ts -> "You can use these tools:\n" <> T.unlines (map one ts)
  where
    one st =
      "- "
        <> someToolName st
        <> ": "
        <> someToolDescription st
        <> " (arguments schema: "
        <> encodeText (someToolSchema st)
        <> ")"

-- | The action grammar instruction for the prompt protocol.
proposeGrammar :: Text
proposeGrammar =
  T.unlines
    [ "Reply with exactly one JSON object and nothing else, in one of these two forms:",
      "  {\"thought\": \"...\", \"action\": {\"tool\": \"<name>\", \"args\": { ... }}}",
      "  {\"thought\": \"...\", \"action\": {\"finish\": true}}"
    ]

-- | The extract instruction: ask for one JSON object matching @o@'s schema.
extractGuide :: Value -> Text
extractGuide schema =
  "Now produce the final answer as exactly one JSON object matching this schema, and nothing else:\n"
    <> encodeText schema

-- ---------------------------------------------------------------------------
-- Parsing helpers
-- ---------------------------------------------------------------------------

-- | The concatenated text of every assistant text block.
responseText :: Response -> Text
responseText resp =
  T.concat [t | AssistantText (TextContent t) <- V.toList (flattenAssistantBlocks resp)]

-- | Every tool-call block in a response.
toolCallsOf :: Response -> [ToolCall]
toolCallsOf resp = [tc | AssistantToolCall tc <- V.toList (flattenAssistantBlocks resp)]

-- | Parse the model's propose text into @(thought, action)@. Strips code fences,
-- decodes one JSON object, and reads its @thought@ and @action@ fields.
parseActionText :: Text -> Either Text (Text, Action)
parseActionText raw =
  case eitherDecodeStrict (encodeUtf8 (stripFences raw)) of
    Left e -> Left ("not valid JSON: " <> T.pack e)
    Right v -> parseActionObject v

-- | Read @{thought, action}@ from a decoded JSON value.
parseActionObject :: Value -> Either Text (Text, Action)
parseActionObject (Object o) = do
  th <- case KM.lookup "thought" o of
    Just (String t) -> Right t
    Just _ -> Left "\"thought\" must be a string"
    Nothing -> Right "" -- thought is optional
  act <- case KM.lookup "action" o of
    Just a -> parseAction a
    Nothing -> Left "missing \"action\""
  pure (th, act)
parseActionObject _ = Left "expected a JSON object"

-- | Read an action object: @{finish:true}@ -> 'Finish'; @{tool,args}@ -> 'CallTool'.
parseAction :: Value -> Either Text Action
parseAction (Object o)
  | Just (Bool True) <- KM.lookup "finish" o = Right Finish
  | Just (String nm) <- KM.lookup "tool" o =
      Right (CallTool nm (maybe (Object KM.empty) id (KM.lookup "args" o)))
  | otherwise = Left "action must be {\"finish\":true} or {\"tool\":..,\"args\":..}"
parseAction _ = Left "action must be a JSON object"

-- | Strip a leading/trailing Markdown code fence (```… / ```json … ```), if any,
-- so a fenced JSON reply still decodes. Falls back to the input unchanged.
stripFences :: Text -> Text
stripFences t =
  let trimmed = T.strip t
   in case T.stripPrefix "```" trimmed of
        Nothing -> trimmed
        Just rest ->
          let afterLang = dropFirstLine rest
           in T.strip (dropClosingFence afterLang)
  where
    dropFirstLine s = T.drop 1 (T.dropWhile (/= '\n') s)
    dropClosingFence s = fst (T.breakOn "```" s)

-- | Compact-encode a JSON value to text.
encodeText :: Value -> Text
encodeText = decodeUtf8 . LBS.toStrict . encode
