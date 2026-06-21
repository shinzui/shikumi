{-# LANGUAGE GADTs #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

-- | Program-level streaming (EP-25). A new, additive entry point 'streamProgram'
-- runs a 'Program' and delivers a sequence of 'StreamEvent's to a caller-supplied
-- callback as execution proceeds, while still returning the fully-decoded typed
-- output — identical to what 'Shikumi.Program.runProgram' would return for the same
-- input. 'runProgram'\'s blocking contract (MasterPlan integration point #4) is
-- untouched; this module adds surface, it changes nothing.
--
-- Two kinds of event reach the callback:
--
--   * a __field chunk__ — a piece of an output field's text as the model writes it.
--     Honestly scoped to a single 'Shikumi.Program.Predict' node (and chains of
--     them) on the prompt-fallback / raw-text path — the path exercised in the
--     hermetic stubs, since 'Shikumi.Program.runProgram'\'s placeholder model maps to
--     the fallback adapter. Native whole-JSON field chunking is /not/ promised (a
--     JSON blob is only parseable once whole).
--   * a __status message__ — a human-readable signal that a phase started or ended
--     ("LM call started/finished", "tool started/finished", "node started/finished").
--     Status brackets every node, including composites; aggregating combinators
--     ('Shikumi.Program.Map', 'Shikumi.Program.Parallel',
--     'Shikumi.Program.MajorityVote', 'Shikumi.Program.Ensemble') and opaque
--     'Shikumi.Program.Embed' bodies stream status only, not field chunks.
--
-- The chunk text is the raw provider delta (marker boilerplate included on the
-- fallback path); trimming markers out of the stream is left to a future refinement.
module Shikumi.Stream
  ( -- * Event types
    FieldChunk (..),
    StatusPhase (..),
    Status (..),
    StreamEvent (..),

    -- * Entry points
    streamComplete,
    streamProgram,
  )
where

import Baikai
  ( AssistantContent (..),
    AssistantMessageEvent (..),
    BlockEndPayload (..),
    Context,
    DeltaPayload (..),
    Message (..),
    Model,
    Options,
    Response,
    TerminalPayload (..),
    _Model,
    _Response,
    _TextContent,
  )
import Control.Lens ((&), (.~))
import Data.Generics.Labels ()
import Data.Maybe (fromMaybe, listToMaybe)
import Data.Text (Text)
import Data.Vector qualified as V
import Effectful (Eff, (:>))
import Effectful.Error.Static (Error, throwError)
import GHC.Generics (Generic)
import Shikumi.Adapter (Adapter (..), ToPrompt, adapterFor)
import Shikumi.Error (ShikumiError)
import Shikumi.LLM (LLM, stream)
import Shikumi.Program
  ( Demo (..),
    Params (..),
    Program (Compose, Embed, FMap, MajorityVote, Map, Parallel, Predict, Retry, RetryWhen, Validate),
    acceptOrReject,
    retryWith,
    runProgram,
  )
import Shikumi.Schema (FromModel, ToSchema, fromModel)
import Shikumi.Schema.Types qualified as ST
import Shikumi.Signature (Signature, getInstruction, outputFields, setDemos, setInstruction)
import Shikumi.Signature qualified as Sig

-- ---------------------------------------------------------------------------
-- Event types
-- ---------------------------------------------------------------------------

-- | A piece of one output field's text, as the model writes it. Mirrors DSPy's
-- @StreamResponse { predict_name, signature_field_name, chunk, is_last_chunk }@.
data FieldChunk = FieldChunk
  { -- | which output field this chunk belongs to (@""@ if not attributed)
    fieldName :: !Text,
    -- | the text delta
    chunk :: !Text,
    -- | 'True' on the final chunk of this field
    isLast :: !Bool
  }
  deriving stock (Eq, Show, Generic)

-- | The phase a status message marks. Borrowed in spirit from the trace SpanKind.
data StatusPhase
  = -- | an LM call is about to begin
    LmStart
  | -- | an LM call finished
    LmEnd
  | -- | a tool call is about to begin
    ToolStart
  | -- | a tool call finished
    ToolEnd
  | -- | a (sub-)program node started
    NodeStart
  | -- | a (sub-)program node finished
    NodeEnd
  deriving stock (Eq, Show, Generic)

-- | A human-readable status signal. Mirrors DSPy's @StatusMessage@, plus the phase.
data Status = Status
  { phase :: !StatusPhase,
    message :: !Text
  }
  deriving stock (Eq, Show, Generic)

-- | One streaming event handed to the caller's callback, in order.
data StreamEvent
  = StreamFieldChunk !FieldChunk
  | StreamStatus !Status
  deriving stock (Eq, Show, Generic)

-- ---------------------------------------------------------------------------
-- M1: driving one streaming LM call
-- ---------------------------------------------------------------------------

-- | Drive one streaming LM call, folding baikai events into 'StreamEvent's
-- delivered to the callback in order, and return the fully assembled 'Response'
-- (reassembled from the terminal event) so the caller can 'parse' it into a typed
-- value exactly as the blocking path would.
--
-- Each @TextDelta@ becomes a 'StreamFieldChunk' attributed to @fieldNm@; the final
-- delta carries @isLast = True@. If the stream carried no deltas (e.g. a cached
-- whole response arrived as a single @TextEnd@), one synthetic chunk carrying the
-- @TextEnd@ content is emitted so the caller still sees the field.
streamComplete ::
  (LLM :> es) =>
  -- | the output field name to attribute chunks to
  Text ->
  Model ->
  Context ->
  Options ->
  -- | per-event callback, runs in the caller's @Eff@
  (StreamEvent -> Eff es ()) ->
  Eff es Response
streamComplete fieldNm model ctx opts cb = do
  evs <- stream model ctx opts
  emitChunks fieldNm [d | TextDelta (DeltaPayload _ d) <- evs] (firstTextEnd evs) cb
  pure (reassemble evs)

-- | Emit the field chunks for one block: every delta in order, the last marked
-- 'isLast'. With no deltas, synthesize a single final chunk from the @TextEnd@
-- content (if any), so the field is still observed.
emitChunks ::
  Text ->
  [Text] ->
  Maybe Text ->
  (StreamEvent -> Eff es ()) ->
  Eff es ()
emitChunks fieldNm deltas mEnd cb = case deltas of
  [] -> maybe (pure ()) (\c -> cb (mkChunk c True)) mEnd
  _ ->
    let n = length deltas
     in mapM_ (\(k, d) -> cb (mkChunk d (k == n))) (zip [1 :: Int ..] deltas)
  where
    mkChunk t l = StreamFieldChunk (FieldChunk fieldNm t l)

-- | The content of the first @TextEnd@ block, if any.
firstTextEnd :: [AssistantMessageEvent] -> Maybe Text
firstTextEnd evs = listToMaybe [c | TextEnd (BlockEndPayload _ c) <- evs]

-- | Reassemble a 'Response' from the stream's terminal event (its payload's
-- fully-assembled assistant message). 'EventError' surfaces the assembled
-- (possibly-partial) response just like the blocking path, so the caller's 'parse'
-- fails on a bad response identically. Falls back to a response synthesized from
-- the @TextEnd@ content if no terminal assistant message is present.
reassemble :: [AssistantMessageEvent] -> Response
reassemble evs = case terminalPayloads of
  (p : _) -> _Response & #message .~ p
  [] -> synthResponse (fromMaybe "" (firstTextEnd evs))
  where
    terminalPayloads =
      [p | EventDone TerminalPayload {message = AssistantMessage p} <- evs]
        ++ [p | EventError TerminalPayload {message = AssistantMessage p} <- evs]

-- | A response carrying @t@ as its single assistant text block.
synthResponse :: Text -> Response
synthResponse t =
  _Response & #message . #content .~ V.singleton (AssistantText (_TextContent & #text .~ t))

-- ---------------------------------------------------------------------------
-- M2/M3: streaming a whole program
-- ---------------------------------------------------------------------------

-- | Run a program, delivering 'StreamEvent's to the callback as it executes, and
-- return the typed output equal to 'Shikumi.Program.runProgram'\'s for the same
-- input. The effect row is exactly 'runProgram'\'s plus the callback, so a streamed
-- program runs under the same interpreters as a blocking one.
--
-- A leaf 'Predict' streams its first output field's chunks bracketed by
-- @LmStart@/@LmEnd@. Composites are bracketed by @NodeStart@/@NodeEnd@:
-- 'Compose'/'FMap' and the single-result control nodes
-- ('Retry'/'RetryWhen'/'Validate') recurse so their leaf predicts still stream;
-- the aggregating combinators ('Map'/'Parallel'/'MajorityVote'/'Ensemble') and the
-- opaque 'Embed' body run blocking and emit node-boundary status only (field chunks
-- come from leaf LM calls on the single-result path).
streamProgram ::
  forall i o es.
  (LLM :> es, Error ShikumiError :> es) =>
  Program i o ->
  i ->
  (StreamEvent -> Eff es ()) ->
  Eff es o
streamProgram prog i cb = case prog of
  Predict sig ps -> streamPredict sig ps i cb
  Compose f g -> bracketNode cb $ do
    b <- streamProgram f i cb
    streamProgram g b cb
  FMap k p -> bracketNode cb (k <$> streamProgram p i cb)
  Retry n p -> bracketNode cb (retryWith (\pp ii -> streamProgram pp ii cb) (const True) n p i)
  RetryWhen ok n p -> bracketNode cb (retryWith (\pp ii -> streamProgram pp ii cb) ok n p i)
  Validate v p -> bracketNode cb (streamProgram p i cb >>= acceptOrReject v)
  -- Aggregating / opaque nodes: bracket with node status, run blocking (no field
  -- chunks where per-field streaming is ambiguous or the body is opaque).
  Map _ _ -> blockingNode prog i cb
  Parallel _ _ -> blockingNode prog i cb
  MajorityVote _ _ _ -> blockingNode prog i cb
  Embed _ -> blockingNode prog i cb
  _ -> blockingNode prog i cb

-- | Stream a single 'Predict': overlay its 'Params', render via the (fallback)
-- adapter, stream the first output field's chunks bracketed by @LmStart@/@LmEnd@,
-- then run the identical 'parse' on the reassembled response so the typed result
-- equals 'runProgram'\'s.
streamPredict ::
  forall i o es.
  (FromModel i, FromModel o, ToSchema o, ToPrompt i, ToPrompt o) =>
  (LLM :> es, Error ShikumiError :> es) =>
  Signature i o ->
  Params ->
  i ->
  (StreamEvent -> Eff es ()) ->
  Eff es o
streamPredict sig ps i cb = do
  sig' <- effectiveSig sig ps
  let adapter = adapterFor _Model
      (ctx, opts) = render adapter sig' i
      fieldNm = case map ST.fieldName (outputFields sig') of
        (x : _) -> x
        [] -> ""
  cb (StreamStatus (Status LmStart "LM call started"))
  resp <- streamComplete fieldNm _Model ctx opts cb
  cb (StreamStatus (Status LmEnd "LM call finished"))
  either throwError pure (parse adapter sig' resp)

-- | Bracket an action with @NodeStart@/@NodeEnd@ status messages.
bracketNode :: (StreamEvent -> Eff es ()) -> Eff es a -> Eff es a
bracketNode cb act = do
  cb (StreamStatus (Status NodeStart "node started"))
  r <- act
  cb (StreamStatus (Status NodeEnd "node finished"))
  pure r

-- | Run a node blocking (no field chunks) bracketed by node-boundary status.
blockingNode ::
  (LLM :> es, Error ShikumiError :> es) =>
  Program i o ->
  i ->
  (StreamEvent -> Eff es ()) ->
  Eff es o
blockingNode prog i cb = bracketNode cb (runProgram prog i)

-- | Overlay a node's 'Params' onto its signature (effective instruction + decoded
-- demos), replicating 'Shikumi.Program.runProgram'\'s internal @effectiveSignature@
-- so a streamed 'Predict' renders byte-for-byte as the blocking one would.
effectiveSig ::
  (FromModel i, FromModel o, Error ShikumiError :> es) =>
  Signature i o ->
  Params ->
  Eff es (Signature i o)
effectiveSig sig (Params {instructionOverride = ovr, demos = ds}) = do
  typed <- either throwError pure (traverse decodeDemo ds)
  pure (setDemos typed (setInstruction (fromMaybe (getInstruction sig) ovr) sig))
  where
    decodeDemo (Demo inJ outJ) = Sig.Demo <$> fromModel inJ <*> fromModel outJ
