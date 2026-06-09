{-# LANGUAGE DataKinds #-}
{-# LANGUAGE KindSignatures #-}

-- | Shared vocabulary for the schema engine: the per-field description wrapper
-- 'Field', the derived 'FieldMeta' record, JSON-Schema smart constructors (the
-- small subset OpenAI/Anthropic structured-output endpoints accept), and the
-- field-path breadcrumb used to locate decode errors.
--
-- This module is owned by EP-3 (integration point #3). The user-facing error
-- type is 'Shikumi.Error.ShikumiError' (owned by EP-1); decode errors render a
-- 'FieldPath' breadcrumb into that type's @Text@ payloads.
module Shikumi.Schema.Types
  ( -- * Field description wrapper
    Field (..),
    field,

    -- * Derived field metadata
    FieldMeta (..),

    -- * Field-path breadcrumbs
    FieldPath,
    pushField,
    pushIndex,
    renderPath,

    -- * JSON-Schema smart constructors
    objectSchema,
    stringSchema,
    integerSchema,
    numberSchema,
    boolSchema,
    arraySchema,
    enumSchema,
    nullableSchema,
    withDescription,
  )
where

import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Generics (Generic)
import GHC.TypeLits (Symbol)

-- | A field carrying a compile-time description as a type-level 'Symbol'. A
-- single 'GHC.Generics' traversal recovers both the field name (from the record
-- selector) and its description (from @desc@), so the two cannot drift. The
-- wrapper is opt-in per field: a bare @Text@ field simply has no description.
newtype Field (desc :: Symbol) a = Field {unField :: a}
  deriving stock (Eq, Show)

-- | Smart constructor mirroring 'unField'.
field :: a -> Field desc a
field = Field

-- | Per-field metadata recovered by the generic walk (used by 'Shikumi.Signature'
-- and the prompt adapters).
data FieldMeta = FieldMeta
  { fieldName :: !Text,
    fieldDesc :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic)

-- | A breadcrumb trail to a location inside a decoded value, e.g.
-- @["bullets", "[2]"]@. Rendered into 'Shikumi.Error.ShikumiError' messages.
type FieldPath = [Text]

-- | Extend a path with a named record field.
pushField :: Text -> FieldPath -> FieldPath
pushField name p = p ++ [name]

-- | Extend a path with an array index.
pushIndex :: Int -> FieldPath -> FieldPath
pushIndex i p = p ++ ["[" <> T.pack (show i) <> "]"]

-- | Render a path to a single dotted breadcrumb (@"bullets.[2]"@). The empty path
-- renders as @"(root)"@ so a top-level error is still legible.
renderPath :: FieldPath -> Text
renderPath [] = "(root)"
renderPath p = T.intercalate "." p

-- | An object schema from @(name, schema)@ properties and a required-name list.
objectSchema :: [(Text, Value)] -> [Text] -> Value
objectSchema props required =
  object
    [ "type" .= ("object" :: Text),
      "properties" .= object [Key.fromText k .= v | (k, v) <- props],
      "required" .= required,
      "additionalProperties" .= False
    ]

-- | @{"type":"string"}@.
stringSchema :: Value
stringSchema = object ["type" .= ("string" :: Text)]

-- | @{"type":"integer"}@.
integerSchema :: Value
integerSchema = object ["type" .= ("integer" :: Text)]

-- | @{"type":"number"}@.
numberSchema :: Value
numberSchema = object ["type" .= ("number" :: Text)]

-- | @{"type":"boolean"}@.
boolSchema :: Value
boolSchema = object ["type" .= ("boolean" :: Text)]

-- | @{"type":"array","items":<items>}@.
arraySchema :: Value -> Value
arraySchema items = object ["type" .= ("array" :: Text), "items" .= items]

-- | @{"enum":[...]}@ for an enum-like sum of nullary constructors.
enumSchema :: [Text] -> Value
enumSchema names = object ["enum" .= names]

-- | Permit JSON @null@ in addition to the wrapped schema. The @anyOf@ form is
-- used (more portable across providers than @"type":["T","null"]@).
nullableSchema :: Value -> Value
nullableSchema s = object ["anyOf" .= [s, object ["type" .= ("null" :: Text)]]]

-- | Attach a @"description"@ key to a schema object (no-op on a non-object).
withDescription :: Text -> Value -> Value
withDescription desc (Object o) = Object (KM.insert "description" (String desc) o)
withDescription _ v = v
