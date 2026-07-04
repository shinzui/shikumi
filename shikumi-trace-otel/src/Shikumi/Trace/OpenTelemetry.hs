-- | Export a shikumi 'TraceTree' as nested OpenTelemetry spans (EP-7, M4).
--
-- Unlike baikai's @baikai-trace-otel@ (one flat span per provider call),
-- 'exportTree' preserves the tree's parent/child nesting: it walks from the root
-- depth-first and creates each child span in a 'Context' carrying its parent span
-- (via 'OpenTelemetry.Context.insertSpan'), the explicit-context approach for
-- reconstructing a recorded tree rather than discovering it from the live call
-- stack. Each span's start time comes from the recorded 'startedAt'. Closed
-- spans end at their recorded 'endedAt'; never-closed spans end at their own
-- start time and carry @shikumi.incomplete = true@.
--
-- LM-call spans carry GenAI semantic-convention attributes
-- (@gen_ai.provider.name@, @gen_ai.request.model@, @gen_ai.response.model@,
-- @gen_ai.usage.input_tokens@, @gen_ai.usage.output_tokens@,
-- @gen_ai.operation.name@). The response model is read from the recorded
-- response's echoed @model.modelId@ and omitted when no response model is
-- present. Every span carries @shikumi.@-prefixed attributes
-- (@shikumi.span_kind@, @shikumi.retries@, optional @shikumi.incomplete@, and,
-- on LM-call spans, @shikumi.cost.usd@ / @shikumi.latency_ms@).
module Shikumi.Trace.OpenTelemetry
  ( exportTree,
  )
where

import Control.Lens ((^.))
import Control.Monad (foldM)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Aeson (Value (..))
import Data.Aeson.KeyMap qualified as KM
import Data.Functor (($>))
import Data.Generics.Labels ()
import Data.HashMap.Strict (HashMap)
import Data.HashMap.Strict qualified as HashMap
import Data.Int (Int64)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Scientific qualified as Sci
import Data.Set qualified as Set
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
exportTree tracer tree = liftIO (go Set.empty Context.empty (tree ^. #root) $> ())
  where
    smap = tree ^. #spans
    go visited ctx sid
      | Set.member sid visited = pure visited
      | otherwise = case Map.lookup sid smap of
          Nothing -> pure visited
          Just s -> do
            sp <- Otel.createSpan tracer ctx (s ^. #label) (argsFor s)
            Otel.addAttributes sp (attrsFor s)
            Otel.setStatus sp (statusFor s)
            let childCtx = Context.insertSpan sp Context.empty
                visited' = Set.insert sid visited
            visited'' <- foldM (\vs c -> go vs childCtx c) visited' (childrenOf tree sid)
            Otel.endSpan sp (Just (utcToTimestamp (endTimeOf s)))
            pure visited''

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
        HashMap.fromList $
          [ ("shikumi.span_kind", Attr.toAttribute (kindText (s ^. #kind))),
            ("shikumi.retries", Attr.toAttribute (a ^. #retries))
          ]
            <> [("shikumi.incomplete", Attr.toAttribute True) | (s ^. #endedAt) == Nothing]
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
      maybe id (AttrMap.insertByKey SC.genAi_response_model) (responseModelOf a) $
        maybe id (\n -> AttrMap.insertByKey SC.genAi_usage_inputTokens (fromIntegral n :: Int64)) (a ^. #inputTokens) $
          maybe id (\n -> AttrMap.insertByKey SC.genAi_usage_outputTokens (fromIntegral n :: Int64)) (a ^. #outputTokens) $
            maybe id (\u -> HashMap.insert "shikumi.cost.usd" (Attr.toAttribute (Sci.toRealFloat u :: Double))) (a ^. #costUsd) $
              maybe id (\l -> HashMap.insert "shikumi.latency_ms" (Attr.toAttribute (fromIntegral l :: Int))) (a ^. #latencyMs) $
                AttrMap.insertByKey SC.genAi_operation_name ("chat" :: Text) m0

-- | The end instant to export. A span that never closed is exported with its
-- own start time rather than the wall clock at export time; 'attrsFor' marks
-- such spans with @shikumi.incomplete@.
endTimeOf :: Span -> UTCTime
endTimeOf s = fromMaybe (s ^. #startedAt) (s ^. #endedAt)

-- | Status for an exported span. A recorded response that reports an in-band
-- provider failure becomes 'Otel.Error'; all other spans are explicitly marked
-- 'Otel.Ok'.
statusFor :: Span -> Otel.SpanStatus
statusFor s
  | maybe False isErrorResponse (s ^. #attrs . #response) =
      Otel.Error "recorded response reports an in-band provider error"
  | otherwise = Otel.Ok

-- | Whether a recorded baikai response JSON reports failure: a non-null
-- top-level @errorInfo@, a @message.stopReason@ of @\"error\"@, or a non-null
-- @message.errorMessage@.
isErrorResponse :: Value -> Bool
isErrorResponse (Object o) =
  nonNull (KM.lookup "errorInfo" o) || messageErr (KM.lookup "message" o)
  where
    nonNull = maybe False (/= Null)
    messageErr (Just (Object m)) =
      KM.lookup "stopReason" m == Just (String "error")
        || nonNull (KM.lookup "errorMessage" m)
    messageErr _ = False
isErrorResponse _ = False

-- | The model the provider says actually answered, read from the recorded
-- response's echoed @model.modelId@. 'Nothing' when no response was recorded
-- or the field is absent.
responseModelOf :: SpanAttrs -> Maybe Text
responseModelOf a = do
  Object o <- a ^. #response
  Object m <- KM.lookup "model" o
  String mid <- KM.lookup "modelId" m
  pure mid

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
