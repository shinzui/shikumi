-- | Live OpenTelemetry export of a shikumi 'TraceTree' (EP-17).
--
-- 'Shikumi.Trace.OpenTelemetry.exportTree' turns a finished tree into nested OTel
-- spans against a 'Otel.Tracer', but a bare tracer exports nothing on its own — it
-- needs a 'TracerProvider' holding a span processor that wraps an exporter. This
-- module supplies that orchestration:
--
--   * 'exportTreeWith' builds a provider from a given 'SpanProcessor', makes a
--     tracer, runs 'exportTree', then flushes and shuts the provider down. Factored
--     on the processor so the hermetic test passes the in-memory recording
--     processor and the live path passes the OTLP batch processor — one code path.
--   * 'exportTreeLive' builds the real OTLP/HTTP exporter from the standard
--     @OTEL_*@ environment variables (default endpoint @http:\/\/localhost:4318@),
--     wraps it in a batch processor, and exports through 'exportTreeWith'.
--
-- The batch processor requires the @-threaded@ runtime; both this package's test
-- suite and the @shikumi@ executable already pass it. Because the batch processor
-- exports on a timer, 'exportTreeWith' shuts the provider down before returning so
-- the spans are flushed.
module Shikumi.Trace.LiveExport
  ( exportTreeWith,
    exportTreeLive,
  )
where

import Control.Exception (bracket)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.String (fromString)
import Data.Text (Text)
import Data.Text qualified as T
import OpenTelemetry.Exporter.OTLP.Span (loadExporterEnvironmentVariables, otlpExporter)
import OpenTelemetry.Processor.Batch.Span (batchProcessor, batchTimeoutConfig)
import OpenTelemetry.Processor.Span (SpanProcessor)
import OpenTelemetry.Trace.Core qualified as Otel
import Shikumi.Trace (TraceTree)
import Shikumi.Trace.OpenTelemetry (exportTree)

-- | Build a 'TracerProvider' around the given processor, export the tree
-- through the shared 'exportTree' walker, then flush and shut the provider
-- down. The shutdown runs under 'bracket', so an exception thrown while
-- exporting still flushes buffered spans and releases the provider before
-- propagating to the caller.
exportTreeWith :: (MonadIO m) => SpanProcessor -> Text -> TraceTree -> m ()
exportTreeWith processor name tree =
  liftIO $
    bracket
      (Otel.createTracerProvider [processor] Otel.emptyTracerProviderOptions)
      (\tp -> Otel.shutdownTracerProvider tp Nothing)
      ( \tp -> do
          let tracer = Otel.makeTracer tp (fromString (T.unpack name)) Otel.tracerOptions
          exportTree tracer tree
      )

-- | The live path: load OTLP config from the standard @OTEL_EXPORTER_OTLP_*@
-- environment variables (default endpoint @http:\/\/localhost:4318@), build the
-- OTLP/HTTP exporter, wrap it in a batch processor, and export the tree.
exportTreeLive :: (MonadIO m) => Text -> TraceTree -> m ()
exportTreeLive name tree = do
  cfg <- loadExporterEnvironmentVariables
  exporter <- otlpExporter cfg
  processor <- batchProcessor batchTimeoutConfig exporter
  exportTreeWith processor name tree
