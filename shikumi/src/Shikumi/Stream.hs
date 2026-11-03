{-# LANGUAGE GADTs #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

-- | Program-level streaming (EP-25). A new, additive entry point 'streamProgram'
-- runs a t'Program' and delivers a sequence of 'StreamEvent's to a caller-supplied
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
--     ("LM call started\/finished", "tool started\/finished", "node started\/finished").
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
    responseFromEvents,
    atomicEventsFromResponse,
  )
where

import Baikai
  ( AssistantContent (..),
    AssistantMessageEvent (..),
    BlockEndPayload (..),
    Context,
    DataEndPayload (..),
    DeltaPayload (..),
    IndexPayload (..),
    Message (..),
    Model,
    Options,
    Response,
    StartPayload (..),
    StopReason (ErrorReason),
    TerminalPayload (..),
    doneTerminal,
    emptyModel,
    emptyResponse,
    emptyTextContent,
    responseError,
  )
import Control.Lens ((&), (.~), (^.))
import Data.Generics.Labels ()
import Data.Maybe (fromMaybe, listToMaybe)
import Data.Text (Text)
import Data.Time.Clock (diffUTCTime)
import Data.Vector qualified as V
import Effectful (Eff, (:>))
import Effectful.Error.Static (Error, throwError)
import GHC.Generics (Generic)
import Shikumi.Adapter (ToPrompt, evidenceFields)
import Shikumi.Error (ShikumiError (..))
import Shikumi.LLM (LLM, stream, streamTerminalError)
import Shikumi.Program
  ( Params (..),
    Program (Compose, Embed, FMap, MajorityVote, Map, Parallel, Predict, PredictCaptured, Retry, RetryWhen, Validate),
    acceptOrReject,
    parseResponseWithSettings,
    preparePredict,
    retryWith,
    runProgram,
  )
import Shikumi.Schema (FromModel, ToSchema, Validatable)
import Shikumi.Schema.Types qualified as ST
import Shikumi.Signature (Signature, outputFields)

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
-- (reassembled from the terminal event) so the caller can decode it into a typed
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
-- fully-assembled assistant message). Falls back to a response synthesized from
-- the @TextEnd@ content if no terminal assistant message is present.
--
-- The 'EventError' branch is retained for robustness against third-party @LLM@
-- interpreters, but is /unreachable through shikumi's own interpreters/: they now
-- convert a terminal 'EventError' to an out-of-band t'ShikumiError' before the event
-- list ever reaches here (see "Shikumi.LLM" — @raiseStreamError@), so a streamed
-- program fails with the real transport error, not a decode of a partial body.
reassemble :: [AssistantMessageEvent] -> Response
reassemble evs = case terminalPayloads of
  (p : _) -> emptyResponse & #message .~ p
  [] -> synthResponse (fromMaybe "" (firstTextEnd evs))
  where
    terminalPayloads =
      [p | EventDone TerminalPayload {message = AssistantMessage p} <- evs]
        ++ [p | EventError TerminalPayload {message = AssistantMessage p} <- evs]

-- | A response carrying @t@ as its single assistant text block.
synthResponse :: Text -> Response
synthResponse t =
  emptyResponse & #message . #content .~ V.singleton (AssistantText (emptyTextContent & #text .~ t))

-- ---------------------------------------------------------------------------
-- M2/M3: streaming a whole program
-- ---------------------------------------------------------------------------

-- | Run a program, delivering 'StreamEvent's to the callback as it executes, and
-- return the typed output equal to 'Shikumi.Program.runProgram'\'s for the same
-- input. The effect row is exactly 'runProgram'\'s plus the callback, so a streamed
-- program runs under the same interpreters as a blocking one.
--
-- A leaf 'Predict' streams its first output field's chunks bracketed by
-- @LmStart@\/@LmEnd@. Composites are bracketed by @NodeStart@\/@NodeEnd@:
-- 'Compose'/'FMap' and the single-result control nodes
-- ('Retry'\/'RetryWhen'\/'Validate') recurse so their leaf predicts still stream;
-- the aggregating combinators ('Map'\/'Parallel'\/'MajorityVote'\/'Shikumi.Program.Ensemble') and the
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
  PredictCaptured _ sig ps -> streamPredict sig ps i cb
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
  MajorityVote _ _ _ _ -> blockingNode prog i cb
  Embed _ -> blockingNode prog i cb
  _ -> blockingNode prog i cb

-- | Prepare exactly the same request and apply the same local settings as the
-- blocking runner. Decision outputs validate the complete terminal before decode
-- and emit only LmStart and LmEnd, including mixed generative decision and text outputs.
-- TypeSafe delivers one atomic structured response. The LLM operation collects
-- events before invoking the program callback; it is not a live transport iterator.
-- Ordinary text outputs retain their field chunks and status timing.
streamPredict ::
  forall i o es.
  (FromModel i, FromModel o, ToSchema o, Validatable o, ToPrompt i, ToPrompt o) =>
  (LLM :> es, Error ShikumiError :> es) =>
  Signature i o ->
  Params ->
  i ->
  (StreamEvent -> Eff es ()) ->
  Eff es o
streamPredict sig ps i cb = do
  (sig', ctx, opts) <- preparePredict sig ps i
  let fieldNm = case map ST.fieldName (outputFields sig') of
        (x : _) -> x
        [] -> ""
      checked = not (null (evidenceFields @o (decisionSettings ps)))
      decode = either throwError pure . parseResponseWithSettings (decisionSettings ps) sig'
  cb (StreamStatus (Status LmStart "LM call started"))
  if checked
    then do
      evs <- stream emptyModel ctx opts
      resp <- either throwError pure (responseFromEvents emptyModel evs)
      result <- decode resp
      cb (StreamStatus (Status LmEnd "LM call finished"))
      pure result
    else do
      resp <- streamComplete fieldNm emptyModel ctx opts cb
      cb (StreamStatus (Status LmEnd "LM call finished"))
      decode resp

-- | Validate terminal integrity and preserve the complete response envelope.
-- Answer validity is checked separately by the settings-aware program decoder.
responseFromEvents :: Model -> [AssistantMessageEvent] -> Either ShikumiError Response
responseFromEvents model evs = case reverse evs of
  EventDone tp : rest | not (any terminal rest) -> case tp ^. #message of
    AssistantMessage payload
      | tp ^. #errorInfo /= Nothing || payload ^. #stopReason == ErrorReason -> Left (streamTerminalError tp)
      | otherwise -> do
          let expected = [(i, d) | (i, AssistantData d) <- zip [0 ..] (V.toList (payload ^. #content))]
              actual = [(i, d) | DataEnd (DataEndPayload i d) <- evs]
              starts = [t | EventStart (StartPayload (AssistantMessage p) _) <- evs, Just t <- [p ^. #timestamp]]
              latency = case (starts, payload ^. #timestamp) of
                (t : _, Just end) -> max 0 (floor (1000 * diffUTCTime end t))
                _ -> 0
          if actual /= expected
            then malformed "structured blocks disagree with terminal"
            else
              Right
                ( emptyResponse
                    & #model .~ model
                    & #api .~ (model ^. #api)
                    & #provider .~ (model ^. #provider)
                    & #message .~ payload
                    & #responseId .~ (tp ^. #responseId)
                    & #evidence .~ (tp ^. #evidence)
                    & #latencyMs .~ latency
                )
    _ -> malformed "terminal is not an assistant message"
  EventError tp : rest | not (any terminal rest) -> Left (streamTerminalError tp)
  _ -> malformed "expected one final success terminal"
  where
    terminal EventDone {} = True
    terminal EventError {} = True
    terminal _ = False
    malformed = Left . SchemaMismatch

-- | Reconstruct an atomic structured stream, without IO or new provider evidence.
-- Text-only and failed recordings cannot supply structured stream replay.
atomicEventsFromResponse :: Response -> Maybe [AssistantMessageEvent]
atomicEventsFromResponse resp
  | responseError resp /= Nothing || null structured = Nothing
  | otherwise =
      Just $
        [EventStart (StartPayload (AssistantMessage skeleton) (resp ^. #responseId))]
          ++ concat [block i b | (i, b) <- zip [0 ..] (V.toList (payload ^. #content))]
          ++ [EventDone (doneTerminal (resp ^. #evidence) (resp ^. #responseId) (payload ^. #stopReason) (AssistantMessage payload))]
  where
    payload = resp ^. #message
    skeleton = payload & #content .~ V.empty
    structured = [d | AssistantData d <- V.toList (payload ^. #content)]
    block i (AssistantData d) = [DataStart (IndexPayload i), DataEnd (DataEndPayload i d)]
    block i (AssistantText t) = [TextStart (IndexPayload i), TextEnd (BlockEndPayload i (t ^. #text))]
    block _ _ = []

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
