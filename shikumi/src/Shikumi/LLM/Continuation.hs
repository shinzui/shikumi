-- | Pure continuation checks shared by routing, memoization and transport.
-- Request identity is not provider attestation. No credentials are persisted.
module Shikumi.LLM.Continuation
  ( RequestOrigin,
    requestOrigin,
    originModel,
    opaqueThinking,
    hasOpaqueContinuation,
    contextIdentity,
    stampContinuation,
    validateRequestContinuation,
    stripContinuationMetadata,
    validateReplayOrigin,
  )
where

import Baikai qualified as B
import Control.Lens ((&), (.~), (^.))
import Control.Monad (unless)
import Data.Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (parseEither)
import Data.Generics.Labels ()
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import GHC.Generics (Generic)
import Shikumi.Error (ShikumiError (ValidationFailure))

data RequestOrigin = RequestOrigin
  { provider :: !Text,
    api :: !B.Api,
    model :: !Text,
    endpoint :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | Endpoints containing query strings or userinfo may contain credentials.
-- Refuse to persist them; callers can restart with a credential-free endpoint.
requestOrigin :: B.Model -> Maybe RequestOrigin
requestOrigin m
  | any T.null [m ^. #provider, m ^. #modelId, m ^. #baseUrl] = Nothing
  | m ^. #api == B.Custom "" = Nothing
  | T.any (`elem` ("?@#" :: String)) (m ^. #baseUrl) = Nothing
  | otherwise = Just (RequestOrigin (m ^. #provider) (m ^. #api) (m ^. #modelId) (m ^. #baseUrl))

-- | Minimal explicit request identity. Credentials and compatibility settings
-- must be supplied by the caller's runtime/router, never by a checkpoint.
originModel :: RequestOrigin -> B.Model
originModel (RequestOrigin p a m e) = B.mkModel a m e & #provider .~ p

opaqueThinking :: B.ThinkingContent -> Bool
opaqueThinking t = isJust (t ^. #signature) || t ^. #redacted || isJust (t ^. #replayState)

hasOpaqueContinuation :: [B.Message] -> Bool
hasOpaqueContinuation = any (\case B.AssistantMessage p -> any block (p ^. #content); _ -> False)
  where
    block (B.AssistantThinking t) = opaqueThinking t
    block _ = False

-- | Exact ordered request projection; only message construction timestamps go.
contextIdentity :: B.Context -> Value
contextIdentity c = object ["system" .= (c ^. #systemPrompt), "tools" .= (c ^. #tools), "messages" .= map messageIdentity (V.toList (c ^. #messages))]
  where
    messageIdentity m = case toJSON m of
      Object fields -> Object (case KM.lookup "contents" fields of Just v -> KM.insert "contents" (dropTimestamp v) fields; Nothing -> fields)
      v -> v
    dropTimestamp (Object fields) = Object (KM.delete "timestamp" fields)
    dropTimestamp v = v

continuationKey :: Text
continuationKey = "shikumi.continuation.v1"

stampContinuation :: Maybe RequestOrigin -> Maybe Value -> B.Options -> B.Options
stampContinuation origin prefix o = o & #metadata .~ Map.insert continuationKey (object ["origin" .= origin, "prefix" .= prefix]) (o ^. #metadata)

stripContinuationMetadata :: B.Options -> B.Options
stripContinuationMetadata o = o & #metadata .~ Map.delete continuationKey (o ^. #metadata)

failure :: Text -> Either ShikumiError a
failure t = Left (ValidationFailure ("ReAct continuation: " <> t <> "; explicitly restart from a caller-approved summary"))

-- | Also check returned Responses replay before tools can execute. Aliases are
-- compared to replay scope, never to optional observed-provider model evidence.
validateReplayOrigin :: B.Model -> [B.Message] -> Either ShikumiError ()
validateReplayOrigin m msgs = mapM_ check [r | B.AssistantMessage p <- msgs, B.AssistantThinking t <- V.toList (p ^. #content), Just r <- [t ^. #replayState]]
  where
    check r = unless (r ^. #replayApi == m ^. #api && r ^. #replayModel == m ^. #modelId) (failure "replay API/model differs from resolved request")

validateRequestContinuation :: B.Model -> B.Context -> B.Options -> Either ShikumiError ()
validateRequestContinuation m c o = do
  let opaque = hasOpaqueContinuation (V.toList (c ^. #messages))
  case Map.lookup continuationKey (o ^. #metadata) of
    Nothing -> unless (not opaque) (failure "opaque history has no origin expectation")
    Just value -> case parseEither (withObject "continuation" (\v -> (,) <$> v .: "origin" <*> v .: "prefix")) value of
      Left _ -> failure "malformed expectation"
      Right (origin, prefix) -> do
        case origin of
          Just expected -> unless (requestOrigin m == Just expected) (failure "provider/API/model/endpoint changed or unresolved")
          Nothing -> unless (not opaque) (failure "opaque history has unknown request origin")
        case prefix of
          Nothing -> unless (not opaque) (failure "opaque history has no protected prefix")
          Just protected -> unless (prefixMatches protected (contextIdentity c)) (failure "protected system/tools/message prefix changed")
  validateReplayOrigin m (V.toList (c ^. #messages))
  where
    prefixMatches (Object old) (Object new) =
      KM.lookup "system" old == KM.lookup "system" new
        && KM.lookup "tools" old == KM.lookup "tools" new
        && case (KM.lookup "messages" old, KM.lookup "messages" new) of
          (Just (Array before), Just (Array after)) -> V.length before <= V.length after && before == V.take (V.length before) after
          _ -> False
    prefixMatches _ _ = False
