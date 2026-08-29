{-# LANGUAGE GADTs #-}

-- | M0 de-risking spike for EP-7
-- (@docs/plans/7-hierarchical-tracing-observability-and-replay.md@).
--
-- The one genuinely novel piece of the tracing plan is /how the span hierarchy is
-- formed/, since neither baikai nor EP-1's @LLM@ effect carries a parent\/child
-- relationship. This spike proves the mechanism the production effect (M1) is
-- built on:
--
--   * a manually-maintained __stack of span ids__ (an @IORef [SpanId]@), and
--   * an __interpose__ over EP-1's @LLM@ effect that, on each 'Shikumi.LLM.complete',
--     reads the id currently on top of the stack and tags the call with it before
--     delegating to the real handler.
--
-- This is the same @interpose@ seam EP-6's @cachedLLM@ already uses, so the risk
-- is low; the spike confirms that the id on top of the stack /at the moment the
-- call is sent/ is the enclosing span, which is exactly what M1 needs.
--
-- Decision (EP-7, 2026-06-08): capture LM calls by interposing on the @LLM@
-- effect rather than installing a baikai 'Baikai.Trace.Sink.TraceSink'. EP-1's
-- interpreters expose no sink parameter, and @LLM.complete@ returns the full
-- baikai 'Baikai.Response' (latency, usage, cost, tool blocks) — strictly more
-- than baikai's flat @TraceEvent@. See the plan's Decision Log.
module Shikumi.Trace.Internal.Spike
  ( SpanId (..),
    runSpike,
  )
where

import Baikai
  ( AssistantContent (..),
    Context,
    Response,
    TextContent (..),
    emptyContext,
    emptyModel,
    emptyOptions,
    emptyResponse,
    emptyTextContent,
  )
import Control.Lens ((&), (.~), (^.))
import Data.Generics.Labels ()
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Data.Vector qualified as V
import Effectful (Eff, IOE, liftIO, runEff, (:>))
import Effectful.Dispatch.Dynamic (interpose, interpret)
import Shikumi.LLM (LLM (..), complete)

-- | A span identifier. The production effect (M1) reuses this newtype.
newtype SpanId = SpanId Text
  deriving stock (Eq, Ord, Show)

-- | Run two fake LM calls nested under two distinct span ids and return, for
-- each captured call, the @(enclosing span id, response text)@ pair. If the
-- mechanism works, the first call is tagged with @"draft"@ and the second with
-- @"critique"@ — the ids that were on top of the stack when each call ran.
runSpike :: IO [(SpanId, Text)]
runSpike = runEff $ do
  stack <- liftIO (newIORef [])
  captured <- liftIO (newIORef [])
  runScripted [stubResponse "first draft", stubResponse "a sharp critique"]
    . traceSpike stack captured
    $ do
      _ <- withSpike stack (SpanId "draft") oneCall
      _ <- withSpike stack (SpanId "critique") oneCall
      pure ()
  liftIO (readIORef captured)
  where
    oneCall = complete emptyModel neutralCtx emptyOptions

neutralCtx :: Context
neutralCtx = emptyContext

-- ---------------------------------------------------------------------------
-- The mechanism under test
-- ---------------------------------------------------------------------------

-- | Push @sid@ on the stack for the dynamic extent of @act@, then pop it. The
-- enclosing span is whatever is on top while @act@ runs.
withSpike :: (IOE :> es) => IORef [SpanId] -> SpanId -> Eff es a -> Eff es a
withSpike stack sid act = do
  liftIO (modifyIORef' stack (sid :))
  r <- act
  liftIO (modifyIORef' stack (drop 1))
  pure r

-- | Interpose on @LLM@: on each 'Complete', read the top-of-stack span id,
-- delegate to the underlying handler, and record @(top, responseText)@.
traceSpike ::
  (IOE :> es, LLM :> es) =>
  IORef [SpanId] ->
  IORef [(SpanId, Text)] ->
  Eff es a ->
  Eff es a
traceSpike stack captured = interpose $ \_ -> \case
  Complete m c o -> do
    top <- topOf <$> liftIO (readIORef stack)
    resp <- complete m c o
    liftIO (modifyIORef' captured (++ [(top, responseText resp)]))
    pure resp
  Stream m c o -> stream' m c o
  where
    topOf [] = SpanId "<root>"
    topOf (x : _) = x
    stream' m c o = complete m c o >> pure []

-- ---------------------------------------------------------------------------
-- A network-free scripted @LLM@ interpreter (pops canned responses in order)
-- ---------------------------------------------------------------------------

runScripted :: (IOE :> es) => [Response] -> Eff (LLM : es) a -> Eff es a
runScripted rs0 act = do
  ref <- liftIO (newIORef rs0)
  interpret
    ( \_ -> \case
        Complete {} -> liftIO (pop ref)
        Stream {} -> pure []
    )
    act
  where
    pop :: IORef [Response] -> IO Response
    pop ref = do
      rs <- readIORef ref
      case rs of
        (x : xs) -> modifyIORef' ref (const xs) >> pure x
        [] -> pure (stubResponse "")

-- ---------------------------------------------------------------------------
-- Tiny helpers
-- ---------------------------------------------------------------------------

-- | A 'Response' carrying @t@ as its single assistant text block.
stubResponse :: Text -> Response
stubResponse t =
  emptyResponse & #message . #content .~ V.singleton (AssistantText (emptyTextContent & #text .~ t))

-- | Concatenate the assistant text blocks of a response.
responseText :: Response -> Text
responseText resp =
  mconcat [t | AssistantText (TextContent t) <- V.toList (resp ^. #message . #content)]
