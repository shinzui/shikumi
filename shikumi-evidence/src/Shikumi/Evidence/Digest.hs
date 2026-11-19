{-# LANGUAGE DataKinds #-}

-- | Content digests and the one sealing rule every evidence envelope shares.
--
-- An envelope's digest is BLAKE3 over the canonical JSON
-- ('Shikumi.Cache.Key.canonicalJSON': sorted keys, no insignificant whitespace)
-- of the whole envelope with its @contentDigest@ field removed. The canonical
-- serializer and the hash are the ones the cache key and replay already depend
-- on, so no second canonicalization exists.
--
-- Digests are verified on the JSON value exactly as it was read, never on a
-- decoded and re-encoded value: re-encoding would silently drop unknown fields.
-- 'decodeEnvelope' additionally refuses a document unless encoding the decoded
-- value yields the same JSON value, so unknown fields and alternative spellings of
-- an absent optional field are rejected rather than ignored.
module Shikumi.Evidence.Digest
  ( -- * Digests
    Digest (..),
    renderDigest,
    parseDigest,
    digestValue,
    digestBytes,

    -- * Envelopes
    envelopeDigest,
    sealEnvelope,
    decodeEnvelope,
    encodeEnvelope,
    canonicalBytes,
    stripDigest,
    finite,

    -- * Flat JSON for nested records
    mergeObjects,
    withoutKeys,
  )
where

import BLAKE3 qualified as B
import Data.Aeson (FromJSON (..), Key, Object, Result (..), ToJSON (..), Value (..), eitherDecode, fromJSON, withText)
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as BL
import Data.Char (isDigit, isHexDigit, isLower)
import Data.Text (Text)
import Data.Text qualified as T
import Shikumi.Cache.Key (canonicalJSON)

-- | A BLAKE3-256 content digest, rendered @blake3:@ followed by 64 lowercase
-- hexadecimal characters.
newtype Digest = Digest Text
  deriving stock (Eq, Ord, Show)

-- | The rendered digest.
renderDigest :: Digest -> Text
renderDigest (Digest t) = t

-- | Accept only the canonical rendering.
parseDigest :: Text -> Either Text Digest
parseDigest t = case T.stripPrefix "blake3:" t of
  Just hex
    | T.length hex == 64 && T.all (\c -> isHexDigit c && (isDigit c || isLower c)) hex -> Right (Digest t)
  _ -> Left ("not a blake3 digest: " <> t)

instance ToJSON Digest where
  toJSON (Digest t) = String t

instance FromJSON Digest where
  parseJSON = withText "Digest" (either (fail . T.unpack) pure . parseDigest)

-- | BLAKE3 of raw bytes.
digestBytes :: ByteString -> Digest
digestBytes bytes = Digest ("blake3:" <> T.pack (show (B.hash Nothing [bytes] :: B.Digest 32)))

-- | BLAKE3 of the canonical JSON of a value.
digestValue :: Value -> Digest
digestValue = digestBytes . BL.toStrict . canonicalJSON

-- | Remove a top-level @contentDigest@ key.
stripDigest :: Value -> Value
stripDigest (Object o) = Object (KM.delete "contentDigest" o)
stripDigest v = v

-- | The digest of an envelope's JSON with its @contentDigest@ field removed.
envelopeDigest :: Value -> Digest
envelopeDigest = digestValue . stripDigest

-- | Compute and store an envelope's digest. The setter receives the digest of
-- the envelope encoded with its digest field removed, so the value of the field
-- before sealing is irrelevant.
sealEnvelope :: (ToJSON a) => (Digest -> a -> a) -> a -> a
sealEnvelope setDigest a = setDigest (envelopeDigest (toJSON a)) a

-- | Canonical JSON bytes of a value.
canonicalBytes :: (ToJSON a) => a -> BL.ByteString
canonicalBytes = canonicalJSON . toJSON

-- | An envelope file: canonical JSON followed by a newline.
encodeEnvelope :: (ToJSON a) => a -> BL.ByteString
encodeEnvelope a = canonicalBytes a <> "\n"

-- | Parse bytes, verify the stored digest against the raw value (when the
-- envelope carries one), decode, and require an exact round trip. Returns the raw
-- value with the typed envelope.
decodeEnvelope :: (FromJSON a, ToJSON a) => Bool -> BL.ByteString -> Either Text (Value, a)
decodeEnvelope digested bytes = do
  raw <- either (Left . ("invalid JSON: " <>) . T.pack) Right (eitherDecode bytes)
  if digested
    then case raw of
      Object o -> case KM.lookup "contentDigest" o of
        Just (String stored)
          | Digest stored == envelopeDigest raw -> Right ()
          | otherwise -> Left ("content digest mismatch: stored " <> stored <> ", computed " <> renderDigest (envelopeDigest raw))
        _ -> Left "envelope has no contentDigest string"
      _ -> Left "envelope is not a JSON object"
    else Right ()
  typed <- case fromJSON raw of
    Success a -> Right a
    Error e -> Left ("envelope does not decode: " <> T.pack e)
  if toJSON typed == raw
    then Right (raw, typed)
    else Left "envelope is not in canonical form: it contains unknown fields or a non-canonical spelling"

-- | A finite floating-point number. Non-finite numbers encode as JSON @null@ and
-- can no longer be told apart afterwards, so they are rejected on typed values.
finite :: Double -> Bool
finite x = not (isNaN x || isInfinite x)

-- | Merge JSON objects into one, for envelopes that nest a record in Haskell
-- but keep its fields at the top level in JSON. Later objects win on a clash;
-- non-objects are ignored.
mergeObjects :: [Value] -> Value
mergeObjects vs = Object (foldr KM.union KM.empty (reverse [o | Object o <- vs]))

-- | An object with some keys removed, as a value to parse a nested record from.
withoutKeys :: [Key] -> Object -> Value
withoutKeys ks o = Object (foldr KM.delete o ks)
