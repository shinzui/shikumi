{-# LANGUAGE ScopedTypeVariables #-}

-- | M4 acceptance for shikumi-trace-otel: exporting a fixed two-stage trace tree
-- emits the right number of OTel spans, the LM-call spans carry GenAI attributes,
-- and the parent/child nesting survives (all spans share one trace id; each
-- non-root span's parent is another emitted span).
module Main (main) where

import Control.Exception (SomeException, try)
import Data.Aeson (Value (..), object, (.=))
import Data.HashMap.Strict qualified as HashMap
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes)
import Data.Text (Text)
import Data.Time (UTCTime)
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import Data.Word (Word64)
import OpenTelemetry.Attributes qualified as Attr
import OpenTelemetry.Common (OptionalTimestamp (..), Timestamp, mkTimestamp, timestampToOptional)
import OpenTelemetry.Exporter.InMemory.Span (inMemoryListExporter)
import OpenTelemetry.Processor.Span (SpanProcessor (..))
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
import Shikumi.Trace.LiveExport (exportTreeWith)
import Shikumi.Trace.Node (NodePath (..), NodeStep (..))
import Shikumi.Trace.OpenTelemetry (exportTree)
import System.Timeout (timeout)
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, assertFailure, testCase, (@?=))

main :: IO ()
main =
  defaultMain $
    testGroup
      "shikumi-trace-otel"
      [ nestingTest,
        liveExportInMemoryTest,
        exceptionReleasesProviderTest,
        responseStatusAndModelTest,
        openSpanTest,
        cyclicTreeTest
      ]

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

-- | EP-17 M1+M3: the full live orchestration (provider + batch processor + export
-- + shutdown-flush) driven through 'exportTreeWith' with the in-memory recording
-- processor swapped in for the OTLP one — the exact code path the CLI calls, minus
-- the network. Asserts one span per node, the GenAI attributes, and (EP-16 landed)
-- the @shikumi.node_path@ attribute on the model-call spans.
liveExportInMemoryTest :: TestTree
liveExportInMemoryTest =
  testCase "exportTreeWith (recording processor) preserves nesting and node attrs" $ do
    (proc, spansRef :: IORef [Otel.ImmutableSpan]) <- inMemoryListExporter
    exportTreeWith proc "shikumi-live-test" fixedTree
    emitted <- reverse <$> readIORef spansRef
    assertEqual "one OTel span per tree node" (Map.size (spans fixedTree)) (length emitted)
    let llmSpans = [s | s <- emitted, Otel.spanKind s == Otel.Client]
    assertEqual "two LM-call (Client) spans" 2 (length llmSpans)
    modelled <- mapM (spanHasAttr "gen_ai.request.model") llmSpans
    assertBool "every LM-call span has gen_ai.request.model" (and modelled)
    tagged <- mapM (spanHasAttr "shikumi.node_path") llmSpans
    assertBool "every LM-call span carries shikumi.node_path (EP-16 landed)" (and tagged)

exceptionReleasesProviderTest :: TestTree
exceptionReleasesProviderTest =
  testCase "an exception during export still shuts the provider down" $ do
    (proc0, _spansRef :: IORef [Otel.ImmutableSpan]) <- inMemoryListExporter
    shutRef <- newIORef False
    let proc' =
          proc0
            { spanProcessorShutdown = writeIORef shutRef True >> spanProcessorShutdown proc0
            }
    r <- try (exportTreeWith proc' "shikumi-exc-test" throwingTree)
    case r of
      Left (_ :: SomeException) -> pure ()
      Right () -> assertFailure "expected the trace label exception to propagate"
    wasShut <- readIORef shutRef
    assertBool "provider shutdown ran despite the exception" wasShut

responseStatusAndModelTest :: TestTree
responseStatusAndModelTest =
  testCase "error responses export as status Error; response model is honest" $ do
    (tracer, getSpans) <- newTracerWithInMemory
    exportTree tracer responseTree
    emitted <- getSpans
    errSpan <- findSpan "anthropic/error" emitted
    okSpan <- findSpan "anthropic/success" emitted
    errStatus <- spanStatus errSpan
    case errStatus of
      Otel.Error _ -> pure ()
      other -> assertFailure ("expected Error status, got " <> show other)
    spanStatus okSpan >>= assertEqual "successful response status" Otel.Ok
    errHasResponseModel <- spanHasAttr "gen_ai.response.model" errSpan
    assertBool "error response without echoed model omits gen_ai.response.model" (not errHasResponseModel)
    spanAttr "gen_ai.response.model" okSpan
      >>= assertEqual
        "response model comes from echoed response model"
        (Just (Attr.toAttribute ("claude-sonnet-4-6-20250929" :: Text)))

openSpanTest :: TestTree
openSpanTest =
  testCase "a never-closed span exports as incomplete with zero duration" $ do
    (tracer, getSpans) <- newTracerWithInMemory
    exportTree tracer openSpanTree
    emitted <- getSpans
    assertEqual "one OTel span per tree node" (Map.size (spans openSpanTree)) (length emitted)
    openSpan <- findSpan "predict:Draft" emitted
    hasIncomplete <- spanHasAttr "shikumi.incomplete" openSpan
    assertBool "open span carries shikumi.incomplete" hasIncomplete
    spanEnd openSpan
      >>= assertEqual
        "open span ended at its own start timestamp"
        (timestampToOptional (utcToTimestampForTest (at 2)))

cyclicTreeTest :: TestTree
cyclicTreeTest =
  testCase "a corrupt self-parented tree exports finitely" $ do
    (tracer, getSpans) <- newTracerWithInMemory
    r <- timeout 5000000 (exportTree tracer rootCyclicTree)
    r @?= Just ()
    emitted <- getSpans
    assertEqual "self-parented root exported once" 1 (length emitted)
    assertBool "each span exported at most once" (length emitted <= Map.size (spans rootCyclicTree))

-- | Whether the recorded span's attribute map contains a key.
spanHasAttr :: Text -> Otel.ImmutableSpan -> IO Bool
spanHasAttr key s = do
  hot <- readIORef (Otel.spanHot s)
  pure (HashMap.member key (Attr.getAttributeMap (Otel.hotAttributes hot)))

spanAttr :: Text -> Otel.ImmutableSpan -> IO (Maybe Attr.Attribute)
spanAttr key s = do
  hot <- readIORef (Otel.spanHot s)
  pure (HashMap.lookup key (Attr.getAttributeMap (Otel.hotAttributes hot)))

spanStatus :: Otel.ImmutableSpan -> IO Otel.SpanStatus
spanStatus s = Otel.hotStatus <$> readIORef (Otel.spanHot s)

spanEnd :: Otel.ImmutableSpan -> IO OptionalTimestamp
spanEnd s = Otel.hotEnd <$> readIORef (Otel.spanHot s)

findSpan :: Text -> [Otel.ImmutableSpan] -> IO Otel.ImmutableSpan
findSpan name emitted = do
  named <-
    mapM
      ( \s -> do
          hot <- readIORef (Otel.spanHot s)
          pure (Otel.hotName hot, s)
      )
      emitted
  case [s | (n, s) <- named, n == name] of
    [] -> assertFailure ("missing span: " <> show name)
    [s] -> pure s
    _ -> assertFailure ("multiple spans named: " <> show name)

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

throwingTree :: TraceTree
throwingTree =
  TraceTree
    { root = SpanId "s0",
      spans =
        Map.fromList
          [ (SpanId "s0", node "s0" Nothing ProgramSpan (error "trace label exploded") emptyAttrs 0)
          ]
    }

responseTree :: TraceTree
responseTree =
  TraceTree
    { root = SpanId "s0",
      spans =
        Map.fromList
          [ (SpanId "s0", node "s0" Nothing ProgramSpan "responses" emptyAttrs 0),
            (SpanId "s1", node "s1" (Just "s0") LlmCallSpan "anthropic/error" errorResponseAttrs 1),
            (SpanId "s2", node "s2" (Just "s0") LlmCallSpan "anthropic/success" okResponseAttrs 2)
          ]
    }

openSpanTree :: TraceTree
openSpanTree =
  fixedTree
    { spans =
        Map.adjust
          (\s -> s {endedAt = Nothing})
          (SpanId "s1")
          (spans fixedTree)
    }

rootCyclicTree :: TraceTree
rootCyclicTree =
  TraceTree
    { root = SpanId "s0",
      spans =
        Map.fromList
          [ (SpanId "s0", node "s0" (Just "s0") ProgramSpan "self-parented" emptyAttrs 0)
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
      latencyMs = Just 205,
      -- EP-16 landed: model-call spans carry their issuing node's path.
      nodePath = Just (NodePath [StepComposeL])
    }

errorResponseAttrs :: SpanAttrs
errorResponseAttrs =
  llmAttrs
    { response =
        Just
          ( object
              [ "errorInfo" .= object ["category" .= ("overloaded" :: Text)],
                "message" .= object ["stopReason" .= ("error" :: Text)]
              ]
          )
    }

okResponseAttrs :: SpanAttrs
okResponseAttrs =
  llmAttrs
    { response =
        Just
          ( object
              [ "errorInfo" .= Null,
                "message" .= object ["stopReason" .= ("stop" :: Text), "errorMessage" .= Null],
                "model" .= object ["modelId" .= ("claude-sonnet-4-6-20250929" :: Text)]
              ]
          )
    }

at :: Int -> UTCTime
at n = read ("2026-06-08 00:00:0" <> show n <> " UTC")

utcToTimestampForTest :: UTCTime -> Timestamp
utcToTimestampForTest t =
  let posix :: Rational
      posix = toRational (utcTimeToPOSIXSeconds t)
      secs :: Word64
      secs = floor posix
      nanos :: Word64
      nanos = floor ((posix - toRational secs) * 1000000000)
   in mkTimestamp secs nanos
