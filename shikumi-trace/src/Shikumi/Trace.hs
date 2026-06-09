{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}

-- | Hierarchical tracing for shikumi (EP-7, M1).
--
-- The 'Trace' effect produces a /tree/ of timed, attributed spans for a program
-- run. A span is a node of one of four 'SpanKind's — a whole program, a module
-- such as @predict@, a combinator such as @Pipeline@, or a single LM call. Each
-- span records its parent, so nesting @withSpan@s builds a real tree even though
-- neither baikai nor EP-1's @LLM@ effect has any parent\/child concept.
--
-- The hierarchy is shikumi's: 'runTrace' keeps a stack of span ids, and 'withSpan'
-- pushes\/pops. LM-call leaves are captured automatically by 'tracedLLM', which
-- __interposes__ on EP-1's @LLM@ effect (the same seam EP-6's @cachedLLM@ uses):
-- on each 'Shikumi.LLM.complete' it opens an 'LlmCallSpan' under the active span
-- and fills its attributes — model, provider, latency, tokens, cost, tool calls,
-- the recorded response JSON, and the EP-6 content-addressed 'Shikumi.Cache.Key.cacheKey'
-- (integration point #7) — from the returned 'Baikai.Response'.
--
-- 'renderTree' pretty-prints the tree; 'Shikumi.Trace.Store' serializes it and
-- 'Shikumi.Trace.Replay' replays it offline.
module Shikumi.Trace
  ( -- * Span and tree types
    SpanKind (..),
    SpanId (..),
    ToolCallRecord (..),
    SpanAttrs (..),
    emptyAttrs,
    Span (..),
    TraceTree (..),
    childrenOf,

    -- * The effect
    Trace,
    withSpan,
    currentSpanId,
    bumpRetry,
    recordToolCall,
    annotateSpan,

    -- * Interpreters and capture
    runTrace,
    tracedLLM,

    -- * Rendering
    renderTree,
  )
where

import Baikai
  ( AssistantContent (..),
    Context,
    Model,
    Options,
    Response,
    flattenAssistantBlocks,
  )
import Control.Lens ((^.))
import Data.Aeson (FromJSON, FromJSONKey, ToJSON, ToJSONKey, Value, toJSON)
import Data.Generics.Labels ()
import Data.IORef
  ( IORef,
    atomicModifyIORef',
    modifyIORef',
    newIORef,
    readIORef,
  )
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Scientific (Scientific)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Clock (UTCTime, diffUTCTime, getCurrentTime)
import Data.Vector qualified as V
import Effectful (Dispatch (Dynamic), DispatchOf, Eff, Effect, IOE, liftIO, (:>))
import Effectful.Dispatch.Dynamic (interpose, interpret, localSeqUnlift, send)
import Effectful.Exception (bracket)
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Shikumi.Cache.Key (CacheKey (..), requestToCanonicalValue)
import Shikumi.Cache.Key qualified as Key
import Shikumi.LLM (LLM (..), complete, stream)
import Shikumi.Trace.ResponseJSON ()

-- ---------------------------------------------------------------------------
-- Span and tree types
-- ---------------------------------------------------------------------------

-- | What sort of work a span records.
data SpanKind = ProgramSpan | ModuleSpan | CombinatorSpan | LlmCallSpan
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | A span identifier (a fresh @"span-N"@ string allocated by 'runTrace').
newtype SpanId = SpanId Text
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (ToJSON, FromJSON, ToJSONKey, FromJSONKey)

-- | A tool call observed on an LM response: the tool name and its JSON arguments.
data ToolCallRecord = ToolCallRecord
  { name :: !Text,
    arguments :: !Value
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | The spec-mandated attribute bag a span can carry. Most fields are populated
-- only on 'LlmCallSpan' nodes; the structural nodes (program\/module\/combinator)
-- leave them empty.
data SpanAttrs = SpanAttrs
  { -- | model id, for LM-call spans
    model :: !(Maybe Text),
    provider :: !(Maybe Text),
    -- | the request as canonical JSON (system, messages, tools, options)
    prompt :: !(Maybe Value),
    -- | the response payload as JSON (for replay + inspection)
    response :: !(Maybe Value),
    latencyMs :: !(Maybe Integer),
    inputTokens :: !(Maybe Natural),
    outputTokens :: !(Maybe Natural),
    costUsd :: !(Maybe Scientific),
    -- | how many times this span retried its body
    retries :: !Int,
    -- | tool calls observed on the response
    toolCalls :: ![ToolCallRecord],
    -- | the EP-6 content-addressed key, present on LM-call spans
    cacheKey :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | A span with everything empty: the base every node starts from.
emptyAttrs :: SpanAttrs
emptyAttrs =
  SpanAttrs
    { model = Nothing,
      provider = Nothing,
      prompt = Nothing,
      response = Nothing,
      latencyMs = Nothing,
      inputTokens = Nothing,
      outputTokens = Nothing,
      costUsd = Nothing,
      retries = 0,
      toolCalls = [],
      cacheKey = Nothing
    }

-- | One node of the trace tree.
data Span = Span
  { spanId :: !SpanId,
    parent :: !(Maybe SpanId),
    kind :: !SpanKind,
    label :: !Text,
    startedAt :: !UTCTime,
    endedAt :: !(Maybe UTCTime),
    attrs :: !SpanAttrs
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | A finished trace tree: a flat 'Map' of spans plus the root id. The nesting is
-- reconstructed from each span's 'parent' pointer ('childrenOf').
data TraceTree = TraceTree
  { root :: !SpanId,
    spans :: !(Map SpanId Span)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | The children of a span, in creation order (sorted by start time, ties broken
-- by span id).
childrenOf :: TraceTree -> SpanId -> [SpanId]
childrenOf t sid =
  map spanId $
    sortOn (\s -> (startedAt s, spanId s)) $
      [s | s <- Map.elems (spans t), parent s == Just sid]

-- ---------------------------------------------------------------------------
-- The effect
-- ---------------------------------------------------------------------------

-- | The hierarchical tracing effect.
data Trace :: Effect where
  WithSpan :: SpanKind -> Text -> m a -> Trace m a
  CurrentSpanId :: Trace m (Maybe SpanId)
  BumpRetry :: Trace m ()
  RecordToolCall :: ToolCallRecord -> Trace m ()
  AnnotateSpan :: (SpanAttrs -> SpanAttrs) -> Trace m ()

type instance DispatchOf Trace = 'Dynamic

-- | Open a span of the given kind and label around an inner computation: it is
-- pushed as a child of the currently-active span, timed, and recorded on exit.
withSpan :: (Trace :> es) => SpanKind -> Text -> Eff es a -> Eff es a
withSpan k lbl act = send (WithSpan k lbl act)

-- | The id of the currently-active span, if any.
currentSpanId :: (Trace :> es) => Eff es (Maybe SpanId)
currentSpanId = send CurrentSpanId

-- | Increment the active span's retry counter.
bumpRetry :: (Trace :> es) => Eff es ()
bumpRetry = send BumpRetry

-- | Record a tool call on the active span.
recordToolCall :: (Trace :> es) => ToolCallRecord -> Eff es ()
recordToolCall = send . RecordToolCall

-- | Apply a function to the active span's attributes (used by 'tracedLLM' to fill
-- an LM-call span after the response arrives).
annotateSpan :: (Trace :> es) => (SpanAttrs -> SpanAttrs) -> Eff es ()
annotateSpan = send . AnnotateSpan

-- ---------------------------------------------------------------------------
-- The interpreter
-- ---------------------------------------------------------------------------

-- | Mutable building state for one trace, all in 'IORef's.
data TraceState = TraceState
  { tsCounter :: !(IORef Int),
    tsStack :: !(IORef [SpanId]),
    tsSpans :: !(IORef (Map SpanId Span)),
    tsRoot :: !(IORef (Maybe SpanId))
  }

-- | Run a traced computation, returning its result and the finished tree.
runTrace :: (IOE :> es) => Eff (Trace : es) a -> Eff es (a, TraceTree)
runTrace act = do
  st <- liftIO newTraceState
  a <-
    interpret
      ( \env -> \case
          CurrentSpanId -> liftIO (safeHead <$> readIORef (tsStack st))
          BumpRetry -> liftIO (modifyActive st (\a' -> a' {retries = retries a' + 1}))
          RecordToolCall tc -> liftIO (modifyActive st (\a' -> a' {toolCalls = toolCalls a' ++ [tc]}))
          AnnotateSpan f -> liftIO (modifyActive st f)
          WithSpan k lbl inner ->
            bracket
              (liftIO (openSpan st k lbl))
              (liftIO . closeSpan st)
              (\_ -> localSeqUnlift env (\unlift -> unlift inner))
      )
      act
  tree <- liftIO (freezeTree st)
  pure (a, tree)

newTraceState :: IO TraceState
newTraceState =
  TraceState <$> newIORef 0 <*> newIORef [] <*> newIORef Map.empty <*> newIORef Nothing

-- | Allocate a fresh span as a child of the current top-of-stack, insert it
-- (open, 'endedAt' = 'Nothing'), push it, and record it as the root if it is the
-- first parentless span.
openSpan :: TraceState -> SpanKind -> Text -> IO SpanId
openSpan st k lbl = do
  n <- atomicModifyIORef' (tsCounter st) (\i -> (i + 1, i + 1))
  let sid = SpanId ("span-" <> T.pack (show n))
  par <- safeHead <$> readIORef (tsStack st)
  now <- getCurrentTime
  let s = Span sid par k lbl now Nothing emptyAttrs
  modifyIORef' (tsSpans st) (Map.insert sid s)
  modifyIORef' (tsStack st) (sid :)
  case par of
    Nothing -> modifyIORef' (tsRoot st) (Just . fromMaybe sid)
    Just _ -> pure ()
  pure sid

-- | Close a span: stamp its 'endedAt' and pop it off the stack.
closeSpan :: TraceState -> SpanId -> IO ()
closeSpan st sid = do
  now <- getCurrentTime
  modifyIORef' (tsSpans st) (Map.adjust (\s -> s {endedAt = Just now}) sid)
  modifyIORef' (tsStack st) (drop 1)

-- | Apply a function to the active span's attributes (a no-op with no active span).
modifyActive :: TraceState -> (SpanAttrs -> SpanAttrs) -> IO ()
modifyActive st f = do
  stk <- readIORef (tsStack st)
  case stk of
    (sid : _) -> modifyIORef' (tsSpans st) (Map.adjust (\s -> s {attrs = f (attrs s)}) sid)
    [] -> pure ()

-- | Freeze the building state into an immutable 'TraceTree'.
freezeTree :: TraceState -> IO TraceTree
freezeTree st = do
  sp <- readIORef (tsSpans st)
  r <- readIORef (tsRoot st)
  pure (TraceTree (fromMaybe (SpanId "") r) sp)

safeHead :: [a] -> Maybe a
safeHead [] = Nothing
safeHead (x : _) = Just x

-- ---------------------------------------------------------------------------
-- LM-call capture (interpose on the LLM effect)
-- ---------------------------------------------------------------------------

-- | Capture every LM call as a leaf 'LlmCallSpan' under the active span. Interpose
-- on EP-1's @LLM@ effect: open a span, delegate to the underlying handler, then
-- fill the span's attributes from the returned 'Response' (and the request). The
-- streaming op is wrapped in a span but its attributes are left empty (streams
-- carry the same data incrementally; the demo/replay path uses 'complete').
tracedLLM :: (Trace :> es, LLM :> es) => Eff es a -> Eff es a
tracedLLM = interpose $ \_ -> \case
  Complete m c o -> withSpan LlmCallSpan (llmLabel m) $ do
    resp <- complete m c o
    annotateSpan (const (llmAttrs m c o resp))
    pure resp
  Stream m c o -> withSpan LlmCallSpan (llmLabel m) (stream m c o)

-- | The label for an LM-call span: @provider/model-id@.
llmLabel :: Model -> Text
llmLabel m = (m ^. #provider) <> "/" <> (m ^. #modelId)

-- | Build the attribute bag for a completed LM call from the request and response.
llmAttrs :: Model -> Context -> Options -> Response -> SpanAttrs
llmAttrs m c o resp =
  emptyAttrs
    { model = Just (m ^. #modelId),
      provider = Just (m ^. #provider),
      prompt = Just (requestToCanonicalValue m c o),
      response = Just (toJSON resp),
      latencyMs = Just (resp ^. #latencyMs),
      inputTokens = Just (resp ^. #message . #usage . #inputTokens),
      outputTokens = Just (resp ^. #message . #usage . #outputTokens),
      costUsd = Just (realToFrac (resp ^. #message . #usage . #cost . #usd :: Rational)),
      toolCalls = toolCallsOf resp,
      cacheKey = Just (unCacheKey (Key.cacheKey m c o))
    }

-- | Extract the tool calls from a response's assistant content blocks.
toolCallsOf :: Response -> [ToolCallRecord]
toolCallsOf resp =
  [ ToolCallRecord (tc ^. #name) (tc ^. #arguments)
  | AssistantToolCall tc <- V.toList (flattenAssistantBlocks resp)
  ]

-- ---------------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------------

-- | Pretty-print a trace tree as an indented outline, one line per span: kind,
-- label, wall-clock duration, and (for LM-call spans) tokens and cost.
renderTree :: TraceTree -> Text
renderTree t
  | Map.null (spans t) = "(empty trace)\n"
  | otherwise = T.concat (go (0 :: Int) (root t))
  where
    go depth sid = case Map.lookup sid (spans t) of
      Nothing -> []
      Just s -> line depth s : concatMap (go (depth + 1)) (childrenOf t sid)
    line depth s =
      T.replicate (depth * 2) " "
        <> kindTag (kind s)
        <> "  "
        <> label s
        <> durationOf s
        <> llmStats s
        <> "\n"
    durationOf s = case endedAt s of
      Just e ->
        let ms = round (realToFrac (diffUTCTime e (startedAt s)) * 1000 :: Double) :: Integer
         in "  " <> tshow ms <> "ms"
      Nothing -> ""
    llmStats s
      | kind s == LlmCallSpan =
          let a = attrs s
           in "  in="
                <> maybe "?" tshow (inputTokens a)
                <> " out="
                <> maybe "?" tshow (outputTokens a)
                <> " $"
                <> maybe "0" tshow (costUsd a)
      | otherwise = ""

kindTag :: SpanKind -> Text
kindTag = \case
  ProgramSpan -> "program"
  ModuleSpan -> "module"
  CombinatorSpan -> "combinator"
  LlmCallSpan -> "llm-call"

tshow :: (Show a) => a -> Text
tshow = T.pack . show
