{-# OPTIONS_GHC -Wno-orphans #-}

-- | A faithful JSON round-trip for baikai's 'Response' graph (EP-6).
--
-- The persistent cache backends (SQLite/Redis/Postgres) store each cached
-- 'Baikai.Response.Response' as JSON and read it back. baikai's 'Response' graph
-- round-trips only /partially/ out of the box: 'Baikai.Model.Model',
-- 'Baikai.Api.Api', 'Baikai.Content.AssistantContent', and
-- 'Baikai.StopReason.StopReason' have both 'ToJSON' and 'FromJSON'; but
-- 'Baikai.Usage.Usage', 'Baikai.Cost.Cost', and 'Baikai.Cost.CostBreakdown' are
-- 'ToJSON'-only, and 'Baikai.Message.AssistantPayload' and 'Response' have no
-- aeson instances at all.
--
-- This module supplies the missing pieces as __orphan instances__ so a 'Response'
-- can be encoded and decoded losslessly enough for caching. The instances mirror
-- baikai's own encoders exactly:
--
--   * 'Usage' uses @camelTo2 '_'@ field labels (baikai's @usageOptions@), so the
--     'FromJSON' reads the same snake_case keys baikai's 'ToJSON' writes.
--   * 'Cost' / 'CostBreakdown' read the @usd@ / @*_usd@ 'Scientific' fields baikai
--     writes (via @fromRationalRepetendUnlimited@) and lift them back to
--     'Rational' with 'toRational'. This is lossy only for non-terminating
--     repetends; it never affects the typed-output guarantee, which is decoded
--     from the assistant __text__ ('AssistantContent', which round-trips
--     exactly) — cost is metadata.
--   * 'AssistantPayload' uses @defaultOptions@ (matching baikai's
--     @deriving anyclass ToJSON@).
--   * 'Response' is written out by hand with the same keys @defaultOptions@
--     produced, minus @evidence@ — see below.
--
-- __'Response' does not cache its 'Baikai.Evidence.ModelCallEvidence'.__ Since
-- baikai 0.5 a 'Response' may carry the evidence record for the call that
-- produced it. That record describes /one/ crossing of the provider boundary; a
-- cache hit is precisely the case where no such crossing happened, so replaying
-- a stored record would attribute another call's evidence to this one — the
-- exact misattribution the evidence vocabulary exists to prevent. The encoder
-- therefore drops the field and the decoder always yields @evidence = Nothing@.
-- Dropping it also keeps the encoding byte-identical to what pre-0.5 shikumi
-- wrote, so cache entries written by an older build still read back.
--
-- This module is the __single home__ for these orphans across the whole
-- framework. EP-7's @Shikumi.Trace.ResponseJSON@ re-exports them from here rather
-- than defining its own copy, so no module that imports both the cache and the
-- trace package ever sees duplicate instances.
module Shikumi.Cache.ResponseJSON () where

import Baikai.Cost (Cost (..), CostBreakdown (..))
import Baikai.Message (AssistantPayload (..))
import Baikai.Response (Response (..))
import Baikai.Usage (Usage (..))
import Data.Aeson
  ( FromJSON (parseJSON),
    Key,
    Object,
    Options (fieldLabelModifier),
    ToJSON (toJSON),
    camelTo2,
    defaultOptions,
    genericParseJSON,
    object,
    withObject,
    (.:),
    (.:?),
    (.=),
  )
import Data.Aeson.Types (Parser)
import Data.Scientific (Scientific)

-- | baikai's 'Usage' field-label scheme: @camelTo2 '_'@ (snake_case).
usageOptions :: Options
usageOptions = defaultOptions {fieldLabelModifier = camelTo2 '_'}

-- | Parse a required object field as 'Scientific' and lift it to 'Rational',
-- inverting baikai's @Rational -> Scientific@ cost encoding. A synthetic cost
-- with a non-terminating decimal expansion, such as @1 % 3@, does not satisfy
-- 'Eq' after an encode/decode round-trip because baikai's encoder drops the
-- repetend index. Real USD pricing rates are decimal, so real provider costs
-- terminate; do not rely on round-tripped 'CachedResponse' equality for
-- synthetic non-decimal costs.
ratField :: Object -> Key -> Parser Rational
ratField o k = toRational <$> (o .: k :: Parser Scientific)

instance FromJSON Usage where
  parseJSON = genericParseJSON usageOptions

instance FromJSON CostBreakdown where
  parseJSON = withObject "CostBreakdown" $ \o ->
    CostBreakdown
      <$> ratField o "input_usd"
      <*> ratField o "output_usd"
      <*> ratField o "cached_input_usd"
      <*> ratField o "cached_write_usd"

instance FromJSON Cost where
  parseJSON = withObject "Cost" $ \o ->
    Cost <$> ratField o "usd" <*> o .: "breakdown"

instance FromJSON AssistantPayload where
  parseJSON = genericParseJSON defaultOptions

instance ToJSON Response where
  toJSON
    Response
      { message = m,
        model = mdl,
        api = a,
        provider = p,
        responseId = rid,
        latencyMs = ms,
        errorInfo = e,
        evidence = _
      } =
      object
        [ "message" .= m,
          "model" .= mdl,
          "api" .= a,
          "provider" .= p,
          "responseId" .= rid,
          "latencyMs" .= ms,
          "errorInfo" .= e
        ]

instance FromJSON Response where
  parseJSON = withObject "Response" $ \o -> do
    m <- o .: "message"
    mdl <- o .: "model"
    a <- o .: "api"
    p <- o .: "provider"
    rid <- o .:? "responseId"
    ms <- o .: "latencyMs"
    e <- o .:? "errorInfo"
    pure
      Response
        { message = m,
          model = mdl,
          api = a,
          provider = p,
          responseId = rid,
          latencyMs = ms,
          errorInfo = e,
          evidence = Nothing
        }
