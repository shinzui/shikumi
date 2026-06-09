-- | Export a shikumi 'TraceTree' as nested OpenTelemetry spans (EP-7, M4).
--
-- Unlike baikai's @baikai-trace-otel@ (one flat span per provider call),
-- 'exportTree' preserves the tree's parent/child nesting: it walks from the root
-- depth-first and creates each child span in a 'Context' carrying its parent span
-- (via 'OpenTelemetry.Context.insertSpan'), the explicit-context approach for
-- reconstructing a recorded tree rather than discovering it from the live call
-- stack. Each span's start/end times come from the recorded 'startedAt'/'endedAt'.
--
-- LM-call spans carry GenAI semantic-convention attributes
-- (@gen_ai.provider.name@, @gen_ai.request.model@, @gen_ai.response.model@,
-- @gen_ai.usage.input_tokens@, @gen_ai.usage.output_tokens@,
-- @gen_ai.operation.name@); every span carries @shikumi.@-prefixed attributes
-- (@shikumi.span_kind@, @shikumi.retries@, and, on LM-call spans,
-- @shikumi.cost.usd@ / @shikumi.latency_ms@).
module Shikumi.Trace.OpenTelemetry
  ( exportTree,
  )
where

import Control.Lens ((^.))
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Generics.Labels ()
import Data.HashMap.Strict (HashMap)
import Data.HashMap.Strict qualified as HashMap
import Data.Int (Int64)
import Data.Map.Strict qualified as Map
import Data.Scientific qualified as Sci
import Data.Text (Text)
import Data.Time (UTCTime)
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import Data.Word (Word64)
import OpenTelemetry.Attributes qualified as Attr
import OpenTelemetry.Attributes.Map qualified as AttrMap
import OpenTelemetry.Common (Timestamp, mkTimestamp)
import OpenTelemetry.Context qualified as Context
import OpenTelemetry.SemanticConventions qualified as SC
import OpenTelemetry.Trace.Core qualified as Otel
import Shikumi.Trace (Span, SpanAttrs, SpanKind (..), TraceTree, childrenOf)
import Shikumi.Trace.Node (renderNodePath)

-- | Export a finished trace tree to a tracer as a forest of nested spans. Pure
-- structural ('ProgramSpan' / 'ModuleSpan' / 'CombinatorSpan') and LM-call
-- ('LlmCallSpan') nodes alike become spans; nesting is preserved.
exportTree :: (MonadIO m) => Otel.Tracer -> TraceTree -> m ()
exportTree tracer tree = liftIO (go Context.empty (tree ^. #root))
  where
    smap = tree ^. #spans
    go ctx sid = case Map.lookup sid smap of
      Nothing -> pure ()
      Just s -> do
        sp <- Otel.createSpan tracer ctx (s ^. #label) (argsFor s)
        Otel.addAttributes sp (attrsFor s)
        Otel.setStatus sp Otel.Ok
        let childCtx = Context.insertSpan sp Context.empty
        mapM_ (go childCtx) (childrenOf tree sid)
        Otel.endSpan sp (utcToTimestamp <$> (s ^. #endedAt))

    argsFor :: Span -> Otel.SpanArguments
    argsFor s =
      Otel.defaultSpanArguments
        { Otel.kind = if (s ^. #kind) == LlmCallSpan then Otel.Client else Otel.Internal,
          Otel.startTime = Just (utcToTimestamp (s ^. #startedAt))
        }

-- | The OTel attribute map for a span. Every span carries @shikumi.span_kind@ and
-- @shikumi.retries@, plus — when the source span was produced by
-- @runProgramTraced@ (EP-16) — @shikumi.node_path@, the structural path of the
-- @Program@ node that issued it. LM-call spans additionally carry the GenAI
-- attributes.
attrsFor :: Span -> HashMap Text Attr.Attribute
attrsFor s =
  let a = s ^. #attrs
      base =
        HashMap.fromList
          [ ("shikumi.span_kind", Attr.toAttribute (kindText (s ^. #kind))),
            ("shikumi.retries", Attr.toAttribute (a ^. #retries))
          ]
      withNode =
        maybe
          id
          (\p -> HashMap.insert "shikumi.node_path" (Attr.toAttribute (renderNodePath p)))
          (a ^. #nodePath)
   in withNode (if (s ^. #kind) == LlmCallSpan then genAiAttrs a base else base)

-- | Overlay the GenAI semantic-convention attributes (plus shikumi cost/latency)
-- for an LM-call span.
genAiAttrs :: SpanAttrs -> HashMap Text Attr.Attribute -> HashMap Text Attr.Attribute
genAiAttrs a m0 =
  maybe id (AttrMap.insertByKey SC.genAi_provider_name) (a ^. #provider) $
    maybe id (AttrMap.insertByKey SC.genAi_request_model) (a ^. #model) $
      maybe id (AttrMap.insertByKey SC.genAi_response_model) (a ^. #model) $
        maybe id (\n -> AttrMap.insertByKey SC.genAi_usage_inputTokens (fromIntegral n :: Int64)) (a ^. #inputTokens) $
          maybe id (\n -> AttrMap.insertByKey SC.genAi_usage_outputTokens (fromIntegral n :: Int64)) (a ^. #outputTokens) $
            maybe id (\u -> HashMap.insert "shikumi.cost.usd" (Attr.toAttribute (Sci.toRealFloat u :: Double))) (a ^. #costUsd) $
              maybe id (\l -> HashMap.insert "shikumi.latency_ms" (Attr.toAttribute (fromIntegral l :: Int))) (a ^. #latencyMs) $
                AttrMap.insertByKey SC.genAi_operation_name ("chat" :: Text) m0

kindText :: SpanKind -> Text
kindText = \case
  ProgramSpan -> "program"
  ModuleSpan -> "module"
  CombinatorSpan -> "combinator"
  LlmCallSpan -> "llm-call"

-- | Convert a 'UTCTime' to an OpenTelemetry 'Timestamp' (nanoseconds since the
-- Unix epoch), going via 'Rational' so no precision is dropped (mirrors baikai's
-- adapter).
utcToTimestamp :: UTCTime -> Timestamp
utcToTimestamp t =
  let posix :: Rational
      posix = toRational (utcTimeToPOSIXSeconds t)
      secs :: Word64
      secs = floor posix
      nanos :: Word64
      nanos = floor ((posix - toRational secs) * 1_000_000_000)
   in mkTimestamp secs nanos
