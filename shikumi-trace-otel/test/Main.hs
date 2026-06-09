{-# LANGUAGE ScopedTypeVariables #-}

-- | M4 acceptance for shikumi-trace-otel: exporting a fixed two-stage trace tree
-- emits the right number of OTel spans, the LM-call spans carry GenAI attributes,
-- and the parent/child nesting survives (all spans share one trace id; each
-- non-root span's parent is another emitted span).
module Main (main) where

import Data.HashMap.Strict qualified as HashMap
import Data.IORef (IORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes)
import Data.Text (Text)
import Data.Time (UTCTime)
import OpenTelemetry.Attributes qualified as Attr
import OpenTelemetry.Exporter.InMemory.Span (inMemoryListExporter)
import OpenTelemetry.Trace.Core qualified as Otel
import OpenTelemetry.Trace.Id qualified as OtelId
import Shikumi.Trace
  ( Span (..),
    SpanAttrs (..),
    SpanId (..),
    SpanKind (..),
    TraceTree (..),
    emptyAttrs,
  )
import Shikumi.Trace.OpenTelemetry (exportTree)
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, testCase)

main :: IO ()
main = defaultMain $ testGroup "shikumi-trace-otel" [nestingTest]

nestingTest :: TestTree
nestingTest =
  testCase "exportTree emits nested spans with GenAI attributes" $ do
    (tracer, getSpans) <- newTracerWithInMemory
    exportTree tracer fixedTree
    emitted <- getSpans
    -- (a) one span per tree node.
    assertEqual "one OTel span per tree node" (Map.size (spans fixedTree)) (length emitted)
    -- (b) the two LM-call spans carry gen_ai.request.model.
    let llmSpans = [s | s <- emitted, Otel.spanKind s == Otel.Client]
    assertEqual "two LM-call (Client) spans" 2 (length llmSpans)
    modelled <-
      mapM
        ( \s -> do
            hot <- readIORef (Otel.spanHot s)
            pure (HashMap.member "gen_ai.request.model" (Attr.getAttributeMap (Otel.hotAttributes hot)))
        )
        llmSpans
    assertBool "every LM-call span has gen_ai.request.model" (and modelled)
    -- (c) nesting survived: all spans share one trace id; every non-root span's
    -- parent is one of the emitted spans.
    let traceIds = map (Otel.traceId . Otel.spanContext) emitted
    case traceIds of
      (t0 : rest) -> assertBool "all spans share one trace id" (all (== t0) rest)
      [] -> assertBool "no spans" False
    let emittedSpanIds = map (Otel.spanId . Otel.spanContext) emitted
    parentIds <- mapM parentSpanId emitted
    let presentParents = catMaybes parentIds
    assertEqual "exactly one root (no parent)" 1 (length emitted - length presentParents)
    assertBool
      "every parent is an emitted span"
      (all (`elem` emittedSpanIds) presentParents)

-- | The recorded parent span id of an immutable span, if it has a parent.
parentSpanId :: Otel.ImmutableSpan -> IO (Maybe OtelId.SpanId)
parentSpanId s = case Otel.spanParent s of
  Nothing -> pure Nothing
  Just p -> Just . Otel.spanId <$> Otel.getSpanContext p

-- | A tracer wired to an in-memory span exporter, plus a reader for the captured
-- spans (in emission order).
newTracerWithInMemory :: IO (Otel.Tracer, IO [Otel.ImmutableSpan])
newTracerWithInMemory = do
  (proc, spansRef :: IORef [Otel.ImmutableSpan]) <- inMemoryListExporter
  tp <- Otel.createTracerProvider [proc] Otel.emptyTracerProviderOptions
  let tracer = Otel.makeTracer tp "shikumi-trace-otel-test" Otel.tracerOptions
  pure (tracer, reverse <$> readIORef spansRef)

-- ---------------------------------------------------------------------------
-- A fixed two-stage tree: program -> {draft module -> draft llm, critique module
-- -> critique llm}. Five spans, two of them LM-call leaves.
-- ---------------------------------------------------------------------------

fixedTree :: TraceTree
fixedTree =
  TraceTree
    { root = SpanId "s0",
      spans =
        Map.fromList
          [ (SpanId "s0", node "s0" Nothing ProgramSpan "summarize-and-critique" emptyAttrs 0),
            (SpanId "s1", node "s1" (Just "s0") ModuleSpan "predict:Draft" emptyAttrs 1),
            (SpanId "s2", node "s2" (Just "s1") LlmCallSpan "anthropic/claude" llmAttrs 2),
            (SpanId "s3", node "s3" (Just "s0") ModuleSpan "predict:Critique" emptyAttrs 3),
            (SpanId "s4", node "s4" (Just "s3") LlmCallSpan "anthropic/claude" llmAttrs 4)
          ]
    }

node :: Text -> Maybe Text -> SpanKind -> Text -> SpanAttrs -> Int -> Span
node sid par k lbl a n =
  Span
    { spanId = SpanId sid,
      parent = SpanId <$> par,
      kind = k,
      label = lbl,
      startedAt = at (2 * n),
      endedAt = Just (at (2 * n + 1)),
      attrs = a
    }

llmAttrs :: SpanAttrs
llmAttrs =
  emptyAttrs
    { model = Just "claude-sonnet-4-6",
      provider = Just "anthropic",
      inputTokens = Just 812,
      outputTokens = Just 143,
      latencyMs = Just 205
    }

at :: Int -> UTCTime
at n = read ("2026-06-08 00:00:0" <> show n <> " UTC")
