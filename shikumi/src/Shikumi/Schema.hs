{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE UndecidableInstances #-}

-- | The schema engine: derive a provider JSON Schema from a Haskell record
-- ('ToSchema' / 'deriveSchema'), and totally decode a provider JSON reply back
-- into a record ('FromModel' / 'parseOutput'), where every failure becomes a
-- precise, located 'Shikumi.Error.ShikumiError'.
--
-- Both directions are hand-rolled on 'GHC.Generics' (the schema we emit is the
-- small subset OpenAI/Anthropic structured-output endpoints accept). Per-field
-- descriptions flow from the 'Field' wrapper's type-level 'Symbol'.
module Shikumi.Schema
  ( -- * Forward: record -> JSON Schema
    ToSchema (..),
    deriveSchema,

    -- * Inverse: JSON -> record (total)
    FromModel (..),
    fromModel,
    fromModelChecked,
    parseOutput,

    -- * Validation hook
    Validatable (..),

    -- * Field-metadata traversal (shared with "Shikumi.Signature")
    GFieldMetas (..),
    fieldMetasOf,

    -- * Re-exports
    module Shikumi.Schema.Types,
  )
where

import Control.Applicative ((<|>))
import Data.Aeson (Object, Value (..), eitherDecodeStrict)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Bifunctor (first)
import Data.Kind (Type)
import Data.Proxy (Proxy (..))
import Data.Scientific qualified as Sci
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (encodeUtf8)
import Data.Vector (Vector)
import Data.Vector qualified as V
import GHC.Generics
import GHC.TypeLits (KnownSymbol, symbolVal)
import Shikumi.Error (ShikumiError (..))
import Shikumi.Schema.Types

-- ---------------------------------------------------------------------------
-- Forward direction: ToSchema
-- ---------------------------------------------------------------------------

-- | Types that can describe themselves as a provider JSON Schema. Records get a
-- generic default; leaves and containers have explicit instances.
class ToSchema a where
  toSchema :: Proxy a -> Value
  default toSchema :: (GToSchema (Rep a)) => Proxy a -> Value
  toSchema _ = gToSchema (Proxy @(Rep a))

-- | The JSON Schema for @a@.
deriveSchema :: forall a. (ToSchema a) => Value
deriveSchema = toSchema (Proxy @a)

instance ToSchema Text where toSchema _ = stringSchema

instance ToSchema Int where toSchema _ = integerSchema

instance ToSchema Integer where toSchema _ = integerSchema

instance ToSchema Double where toSchema _ = numberSchema

instance ToSchema Bool where toSchema _ = boolSchema

instance (ToSchema a) => ToSchema [a] where toSchema _ = arraySchema (toSchema (Proxy @a))

instance (ToSchema a) => ToSchema (Vector a) where toSchema _ = arraySchema (toSchema (Proxy @a))

instance (ToSchema a) => ToSchema (Maybe a) where toSchema _ = nullableSchema (toSchema (Proxy @a))

-- | The description is attached at the record-field layer ('FieldSchema'), not
-- here, so this instance stays composable (e.g. a nested @Field@).
instance (ToSchema a) => ToSchema (Field d a) where toSchema _ = toSchema (Proxy @a)

-- | Generic schema walk. A single record constructor becomes an object schema; a
-- sum of nullary constructors becomes a string @enum@.
class GToSchema (f :: Type -> Type) where
  gToSchema :: Proxy f -> Value

instance (GToSchema cs) => GToSchema (D1 d cs) where
  gToSchema _ = gToSchema (Proxy @cs)

instance (GRecordFields fs) => GToSchema (C1 ('MetaCons n fx 'True) fs) where
  gToSchema _ = uncurry objectSchema (gRecordFields (Proxy @fs))

instance (GEnumNames (l :+: r)) => GToSchema (l :+: r) where
  gToSchema _ = enumSchema (gEnumNames (Proxy @(l :+: r)))

-- | Collect @(name, schema)@ properties and the required-name list for a record.
class GRecordFields (f :: Type -> Type) where
  gRecordFields :: Proxy f -> ([(Text, Value)], [Text])

instance (GRecordFields a, GRecordFields b) => GRecordFields (a :*: b) where
  gRecordFields _ = gRecordFields (Proxy @a) <> gRecordFields (Proxy @b)

instance (Selector s, FieldSchema t) => GRecordFields (S1 s (K1 R t)) where
  gRecordFields _ =
    let nm = T.pack (selName (undefined :: S1 s (K1 R t) ()))
        (sch, req) = fieldSchema (Proxy @t)
     in ([(nm, sch)], [nm | req])

-- | Per-field schema and whether the field is required. The general
-- (overlappable) case is "required, no description"; 'Maybe' is optional/nullable;
-- 'Field' attaches the description and preserves the inner required-ness.
class FieldSchema t where
  fieldSchema :: Proxy t -> (Value, Bool)

instance {-# OVERLAPPABLE #-} (ToSchema a) => FieldSchema a where
  fieldSchema _ = (toSchema (Proxy @a), True)

instance (ToSchema a) => FieldSchema (Maybe a) where
  fieldSchema _ = (nullableSchema (toSchema (Proxy @a)), False)

instance (KnownSymbol d, FieldSchema a) => FieldSchema (Field d a) where
  fieldSchema _ =
    let (s, req) = fieldSchema (Proxy @a)
     in (withDescription (T.pack (symbolVal (Proxy @d))) s, req)

-- | Constructor names of a sum of nullary constructors.
class GEnumNames (f :: Type -> Type) where
  gEnumNames :: Proxy f -> [Text]

instance (GEnumNames a, GEnumNames b) => GEnumNames (a :+: b) where
  gEnumNames _ = gEnumNames (Proxy @a) ++ gEnumNames (Proxy @b)

instance (Constructor c) => GEnumNames (C1 c U1) where
  gEnumNames _ = [T.pack (conName (undefined :: C1 c U1 ()))]

-- ---------------------------------------------------------------------------
-- Inverse direction: FromModel (total decode)
-- ---------------------------------------------------------------------------

-- | Types decodable from provider JSON, totally. The path-carrying 'fromModelP'
-- threads a breadcrumb so every error is located; 'fromModel' starts at the root.
class FromModel a where
  fromModelP :: FieldPath -> Value -> Either ShikumiError a
  default fromModelP :: (Generic a, GFromModel (Rep a)) => FieldPath -> Value -> Either ShikumiError a
  fromModelP path v = to <$> gFromModel path v

-- | Decode from a JSON 'Value' (no validation).
fromModel :: (FromModel a) => Value -> Either ShikumiError a
fromModel = fromModelP []

-- | Decode then run the type's 'Validatable' rule, locating a failure as a
-- 'ValidationFailure'.
fromModelChecked :: (FromModel a, Validatable a) => Value -> Either ShikumiError a
fromModelChecked v = do
  a <- fromModel v
  first ValidationFailure (validate a)

-- | Parse a raw response body to JSON (mapping a parse failure to 'InvalidJSON'),
-- decode it, and validate.
parseOutput :: forall a. (FromModel a, Validatable a) => Text -> Either ShikumiError a
parseOutput body = case eitherDecodeStrict (encodeUtf8 body) of
  Left e -> Left (InvalidJSON (T.pack e))
  Right v -> fromModelChecked v

instance FromModel Text where
  fromModelP path = \case String t -> Right t; v -> mismatch path "string" v

instance FromModel Int where
  fromModelP path = \case
    Number n -> maybe (mismatch path "integer" (Number n)) Right (Sci.toBoundedInteger n)
    v -> mismatch path "integer" v

instance FromModel Integer where
  fromModelP path = \case
    Number n -> case Sci.floatingOrInteger n :: Either Double Integer of
      Right i -> Right i
      Left _ -> mismatch path "integer" (Number n)
    v -> mismatch path "integer" v

instance FromModel Double where
  fromModelP path = \case Number n -> Right (Sci.toRealFloat n); v -> mismatch path "number" v

instance FromModel Bool where
  fromModelP path = \case Bool b -> Right b; v -> mismatch path "boolean" v

instance (FromModel a) => FromModel [a] where
  fromModelP path = \case
    Array arr -> traverse (\(i, x) -> fromModelP (pushIndex i path) x) (zip [0 ..] (V.toList arr))
    v -> mismatch path "array" v

instance (FromModel a) => FromModel (Vector a) where
  fromModelP path v = V.fromList <$> (fromModelP path v :: Either ShikumiError [a])

instance (FromModel a) => FromModel (Maybe a) where
  fromModelP _ Null = Right Nothing
  fromModelP path v = Just <$> fromModelP path v

instance (FromModel a) => FromModel (Field d a) where
  fromModelP path v = Field <$> fromModelP path v

-- | Generic decode walk, mirroring 'GToSchema'.
class GFromModel (f :: Type -> Type) where
  gFromModel :: FieldPath -> Value -> Either ShikumiError (f p)

instance (GFromModel cs) => GFromModel (D1 d cs) where
  gFromModel path v = M1 <$> gFromModel path v

instance (GFromRecord fs) => GFromModel (C1 ('MetaCons n fx 'True) fs) where
  gFromModel path = \case
    Object o -> M1 <$> gFromRecord path o
    v -> mismatch path "object" v

instance (GEnumParse (l :+: r)) => GFromModel (l :+: r) where
  gFromModel path = \case
    String t -> case gEnumParse t of
      Just x -> Right x
      Nothing ->
        Left
          ( SchemaMismatch
              (renderPath path <> ": expected one of [" <> T.intercalate ", " (gEnumNamesP (Proxy @(l :+: r))) <> "]")
          )
    v -> mismatch path "string" v

-- | Decode a record object field by field, threading the path.
class GFromRecord (f :: Type -> Type) where
  gFromRecord :: FieldPath -> Object -> Either ShikumiError (f p)

instance (GFromRecord a, GFromRecord b) => GFromRecord (a :*: b) where
  gFromRecord path o = (:*:) <$> gFromRecord path o <*> gFromRecord path o

instance (Selector s, FromField t) => GFromRecord (S1 s (K1 R t)) where
  gFromRecord path o =
    let nm = T.pack (selName (undefined :: S1 s (K1 R t) ()))
     in M1 . K1 <$> fromField (pushField nm path) nm o

-- | Look a field up in the JSON object. The general (overlappable) case requires
-- the field; 'Maybe' and a missing key succeed as 'Nothing'; 'Field' delegates.
class FromField t where
  fromField :: FieldPath -> Text -> Object -> Either ShikumiError t

instance {-# OVERLAPPABLE #-} (FromModel t) => FromField t where
  fromField path nm o = case KM.lookup (Key.fromText nm) o of
    Nothing -> Left (MissingField (renderPath path))
    Just v -> fromModelP path v

instance (FromModel a) => FromField (Maybe a) where
  fromField path nm o = case KM.lookup (Key.fromText nm) o of
    Nothing -> Right Nothing
    Just Null -> Right Nothing
    Just v -> Just <$> fromModelP path v

instance (FromField a) => FromField (Field d a) where
  fromField path nm o = Field <$> fromField path nm o

-- | Parse a string against the constructor names of an enum-like sum.
class GEnumParse (f :: Type -> Type) where
  gEnumParse :: Text -> Maybe (f p)
  gEnumNamesP :: Proxy f -> [Text]

instance (GEnumParse a, GEnumParse b) => GEnumParse (a :+: b) where
  gEnumParse t = (L1 <$> gEnumParse t) <|> (R1 <$> gEnumParse t)
  gEnumNamesP _ = gEnumNamesP (Proxy @a) ++ gEnumNamesP (Proxy @b)

instance (Constructor c) => GEnumParse (C1 c U1) where
  gEnumParse t
    | t == nm = Just (M1 U1)
    | otherwise = Nothing
    where
      nm = T.pack (conName (undefined :: C1 c U1 ()))
  gEnumNamesP _ = [T.pack (conName (undefined :: C1 c U1 ()))]

-- ---------------------------------------------------------------------------
-- Validation hook
-- ---------------------------------------------------------------------------

-- | A domain rule applied after a successful decode. Defaults to "always valid";
-- override per output type to enforce rules (e.g. "bullets has 3-5 elements").
class Validatable a where
  validate :: a -> Either Text a
  validate = Right

-- | Default "always valid" for any type without an explicit rule.
instance {-# OVERLAPPABLE #-} Validatable a

-- ---------------------------------------------------------------------------
-- Shared field-metadata traversal (also used by Shikumi.Signature)
-- ---------------------------------------------------------------------------

-- | Collect 'FieldMeta' (name + optional description) for every record field of a
-- type, recovering descriptions from 'Field' wrappers.
fieldMetasOf :: forall a. (GFieldMetas (Rep a)) => [FieldMeta]
fieldMetasOf = gFieldMetas (Proxy @(Rep a))

-- | Generic field-metadata walk.
class GFieldMetas (f :: Type -> Type) where
  gFieldMetas :: Proxy f -> [FieldMeta]

instance (GFieldMetas cs) => GFieldMetas (D1 d cs) where
  gFieldMetas _ = gFieldMetas (Proxy @cs)

instance (GFieldMetas fs) => GFieldMetas (C1 c fs) where
  gFieldMetas _ = gFieldMetas (Proxy @fs)

instance (GFieldMetas a, GFieldMetas b) => GFieldMetas (a :*: b) where
  gFieldMetas _ = gFieldMetas (Proxy @a) ++ gFieldMetas (Proxy @b)

instance GFieldMetas U1 where
  gFieldMetas _ = []

instance (Selector s, FieldDoc t) => GFieldMetas (S1 s (K1 R t)) where
  gFieldMetas _ =
    [ FieldMeta
        { fieldName = T.pack (selName (undefined :: S1 s (K1 R t) ())),
          fieldDesc = fieldDoc (Proxy @t)
        }
    ]

-- | The description of a field's type, if it is a 'Field' wrapper.
class FieldDoc t where
  fieldDoc :: Proxy t -> Maybe Text

instance {-# OVERLAPPABLE #-} FieldDoc a where
  fieldDoc _ = Nothing

instance (KnownSymbol d) => FieldDoc (Field d a) where
  fieldDoc _ = Just (T.pack (symbolVal (Proxy @d)))

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

mismatch :: FieldPath -> Text -> Value -> Either ShikumiError a
mismatch path expected got =
  Left (SchemaMismatch (renderPath path <> ": expected " <> expected <> ", got " <> jsonTypeOf got))

jsonTypeOf :: Value -> Text
jsonTypeOf = \case
  String {} -> "string"
  Number {} -> "number"
  Bool {} -> "boolean"
  Null -> "null"
  Array {} -> "array"
  Object {} -> "object"
