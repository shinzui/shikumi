-- | Response builders for offline programs and agents.
module Shikumi.Testing.Response (evidenceJSONResponse, evidenceMarkerResponse, markerResponse, mkTextResponse, mkUsageResponse, mkToolCallResponse, mkToolCallsResponse) where

import Baikai
  ( AssistantContent (..),
    Model,
    Response,
    emptyResponse,
    emptyTextContent,
    emptyToolCall,
  )
import Control.Lens ((&), (.~))
import Data.Aeson (Value (..), encode)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy qualified as BL
import Data.Generics.Labels ()
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8)
import Data.Vector qualified as V
import Numeric.Natural (Natural)

-- | Build a 'Response' as the prompt-fallback adapter's @[[ ## field ## ]]@
-- sections — one per @(fieldName, value)@ pair — terminated by the
-- @[[ ## completed ## ]]@ marker. Carries small fixed token usage so traces and
-- reports show non-zero counts. This is exactly the body the provider-neutral
-- decode path expects, so the typed output decodes cleanly.
markerResponse :: [(Text, Text)] -> Response
markerResponse fields =
  emptyResponse
    & #message . #content .~ V.singleton (AssistantText (emptyTextContent & #text .~ body))
    & #message . #usage . #inputTokens .~ 18
    & #message . #usage . #outputTokens .~ 5
    & #latencyMs .~ 4
  where
    body = T.unlines (concatMap sect fields ++ ["[[ ## completed ## ]]"])
    sect (k, v) = ["[[ ## " <> k <> " ## ]]", v]

-- | An assistant 'Response' carrying @t@ as its single text block.
mkTextResponse :: Text -> Response
mkTextResponse t =
  emptyResponse & #message . #content .~ V.singleton (AssistantText (emptyTextContent & #text .~ t))

-- | A text response that also carries a resolved model and input-token usage.
mkUsageResponse :: Model -> Natural -> Text -> Response
mkUsageResponse model inputTokens text =
  mkTextResponse text
    & #model .~ model
    & #message . #usage . #inputTokens .~ inputTokens
    & #message . #usage . #totalTokens .~ inputTokens

-- | An assistant 'Response' carrying a single native tool-call block.
mkToolCallResponse :: Text -> Text -> Value -> Response
mkToolCallResponse callId nm args = mkToolCallsResponse [(callId, nm, args)]

-- | An assistant 'Response' carrying several native tool-call blocks in order.
mkToolCallsResponse :: [(Text, Text, Value)] -> Response
mkToolCallsResponse calls =
  emptyResponse
    & #message
      . #content
      .~ V.fromList
        [ AssistantToolCall (emptyToolCall & #id_ .~ callId & #name .~ nm & #arguments .~ args)
        | (callId, nm, args) <- calls
        ]

-- | Evidence fixtures use the same field payloads in either generative wire shape.
evidenceJSONResponse :: [(Text, Value)] -> Response
evidenceJSONResponse = mkTextResponse . decodeUtf8 . BL.toStrict . encode . Object . KM.fromList . map (\(k, v) -> (Key.fromText k, v))

evidenceMarkerResponse :: [(Text, Value)] -> Response
evidenceMarkerResponse = markerResponse . map (\(k, v) -> (k, case v of String t -> t; _ -> decodeUtf8 (BL.toStrict (encode v))))
