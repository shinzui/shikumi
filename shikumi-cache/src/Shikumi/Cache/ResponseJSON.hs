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
--   * 'AssistantPayload' / 'Response' use @defaultOptions@ (matching baikai's
--     @deriving anyclass ToJSON@).
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
    genericToJSON,
    withObject,
    (.:),
  )
import Data.Aeson.Types (Parser)
import Data.Scientific (Scientific)

-- | baikai's 'Usage' field-label scheme: @camelTo2 '_'@ (snake_case).
usageOptions :: Options
usageOptions = defaultOptions {fieldLabelModifier = camelTo2 '_'}

-- | Parse a required object field as 'Scientific' and lift it to 'Rational',
-- inverting baikai's @Rational -> Scientific@ cost encoding.
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
  toJSON = genericToJSON defaultOptions

instance FromJSON Response where
  parseJSON = genericParseJSON defaultOptions
