{-# LANGUAGE DataKinds #-}

-- | The content-addressed cache key (EP-6) — the MasterPlan's integration point
-- #7. A 'CacheKey' is a BLAKE3 256-bit digest (64 lowercase hex chars) over a
-- /canonical/ JSON serialization of everything about a request that can change
-- the model's answer: the model routing identity including base URL, model
-- default headers, and compat shim; per-call headers; the rendered prompt with
-- message timestamps excluded; tools; and sampling options. Latency, response
-- ids, API keys, timeouts, and per-call metadata are excluded — they do not
-- affect a successful response's content.
--
-- The serialization is canonical (object keys sorted by Unicode code point, no
-- insignificant whitespace, UTF-8) so the bytes — and therefore the key — are
-- reproducible. Any change to the field set requires bumping
-- 'currentKeyVersion'; a bump invalidates all cache entries and makes previously
-- recorded @shikumi-trace@ files unreplayable, with replay failing closed via
-- @ReplayDivergence@. The replay engine in
-- @docs/plans/7-hierarchical-tracing-observability-and-replay.md@ (EP-7) reuses
-- 'cacheKey' verbatim, so both plans agree byte-for-byte; the golden test in the
-- test suite pins the exact hex for a fixed request to catch any drift.
module Shikumi.Cache.Key
  ( CacheKey (..),
    cacheKey,
    canonicalJSON,
    requestToCanonicalValue,
    requestToCanonicalValueVersioned,
    currentKeyVersion,
    stripMessageTimestamps,
  )
where

import BLAKE3 qualified as B
import Baikai (Context, Model, Options)
import Control.Lens ((^.))
import Data.Aeson (Value (Array, Object, String), object, toJSON, (.=))
import Data.Aeson.Encoding (fromEncoding)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (toEncoding)
import Data.ByteString (ByteString)
import Data.ByteString.Builder qualified as BB
import Data.ByteString.Lazy qualified as BL
import Data.Foldable (toList)
import Data.Generics.Labels ()
import Data.List (intersperse, sortOn)
import Data.Scientific (Scientific)
import Data.Text (Text)
import Data.Text qualified as T

-- | The current cache key-namespace version. Baked into every hashed request
-- (the @version@ field) and into 'Shikumi.Cache.Types.CachedResponse.keyVersion'.
-- Bumping it changes every key, making all prior entries unreachable — a clean
-- invalidation with no row deletion. Because @shikumi-trace@ stores cache keys
-- in trace files and recomputes them during replay, a version bump also makes
-- previously recorded trace files unreplayable; replay fails closed with
-- @ReplayDivergence@ rather than serving stale responses.
currentKeyVersion :: Text
currentKeyVersion = "shikumi-cache/v2"

-- | A content-addressed cache key: the 64-hex BLAKE3 digest of a request's
-- canonical serialization. A @newtype@ so it cannot be confused with arbitrary
-- text.
newtype CacheKey = CacheKey {unCacheKey :: Text}
  deriving stock (Eq, Ord, Show)

-- | The cache key for a request triple @(Model, Context, Options)@. The
-- response-format / JSON-schema slot is read from @Options.responseFormat@
-- (provided by EP-2): a request with no schema and one with a schema hash
-- differently, as they must.
cacheKey :: Model -> Context -> Options -> CacheKey
cacheKey m ctx opts =
  let bytes = BL.toStrict (canonicalJSON (requestToCanonicalValue m ctx opts))
      digest = B.hash Nothing [bytes :: ByteString] :: B.Digest 32
   in CacheKey (T.pack (show digest))

-- | Assemble the canonical request 'Value' for the current namespace version.
requestToCanonicalValue :: Model -> Context -> Options -> Value
requestToCanonicalValue = requestToCanonicalValueVersioned currentKeyVersion

-- | Assemble the canonical request 'Value' under an explicit version string.
-- Exposed so a test can prove that bumping the version changes the key. The
-- top-level object carries exactly the integration-point-#7 field set:
-- @api, baseUrl, compat, maxTokens, messages, model, modelHeaders,
-- optionsHeaders, provider, responseFormat, systemPrompt, temperature,
-- thinking, toolChoice, tools, version@. 'canonicalJSON' sorts the keys, so the
-- listing order here is irrelevant.
requestToCanonicalValueVersioned :: Text -> Model -> Context -> Options -> Value
requestToCanonicalValueVersioned version m ctx opts =
  object
    [ "version" .= version,
      "model" .= (m ^. #modelId),
      "provider" .= (m ^. #provider),
      "api" .= toJSON (m ^. #api),
      "baseUrl" .= (m ^. #baseUrl),
      "modelHeaders" .= toJSON (m ^. #headers),
      "compat" .= toJSON (m ^. #compat),
      "systemPrompt" .= (ctx ^. #systemPrompt),
      "messages" .= stripMessageTimestamps (toJSON (ctx ^. #messages)),
      "tools" .= toJSON (ctx ^. #tools),
      "toolChoice" .= toJSON (opts ^. #toolChoice),
      "temperature" .= (toScientific <$> (opts ^. #temperature)),
      "maxTokens" .= (opts ^. #maxTokens),
      "optionsHeaders" .= toJSON (opts ^. #headers),
      "thinking" .= toJSON (opts ^. #thinking),
      "responseFormat" .= toJSON (opts ^. #responseFormat)
    ]
  where
    -- Normalize the Double through Scientific so two requests that are == in
    -- temperature serialize identically regardless of how the Double was built.
    toScientific :: Double -> Scientific
    toScientific = realToFrac

-- | Delete the payload-level @timestamp@ of every message in a serialized
-- message vector. baikai's 'Baikai.Message.Message' encodes as
-- @{"tag": ..., "contents": {..., "timestamp": ...}}@; the timestamp records
-- when the message value was built, never what the provider sees, so two
-- requests differing only in it must share a cache key. Only the
-- @contents.timestamp@ level is deleted — a @"timestamp"@ key nested inside
-- content blocks or tool arguments is real request data and is preserved.
stripMessageTimestamps :: Value -> Value
stripMessageTimestamps (Array msgs) = Array (fmap stripOne msgs)
  where
    stripOne (Object msg) =
      Object $
        case KM.lookup "contents" msg of
          Nothing -> msg
          Just contents -> KM.insert "contents" (dropTs contents) msg
    stripOne v = v
    dropTs (Object payload) = Object (KM.delete "timestamp" payload)
    dropTs v = v
stripMessageTimestamps v = v

-- | Render a 'Value' to canonical JSON bytes: every object's keys are emitted in
-- ascending Unicode code-point order, with no insignificant whitespace. We do
-- not trust aeson's @encode@ key order (not contractually stable); we sort keys
-- ourselves and reuse aeson's (stable) scalar/string escaping.
canonicalJSON :: Value -> BL.ByteString
canonicalJSON = BB.toLazyByteString . go
  where
    go (Object o) =
      let kvs = sortOn fst [(Key.toText k, v) | (k, v) <- KM.toList o]
       in BB.char7 '{'
            <> mconcat (intersperse (BB.char7 ',') [encStr k <> BB.char7 ':' <> go v | (k, v) <- kvs])
            <> BB.char7 '}'
    go (Array xs) =
      BB.char7 '['
        <> mconcat (intersperse (BB.char7 ',') (map go (toList xs)))
        <> BB.char7 ']'
    go v = fromEncoding (toEncoding v)
    -- Encode an object key as a JSON string (aeson's escaping is stable).
    encStr t = fromEncoding (toEncoding (String t))
