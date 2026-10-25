{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE UndecidableInstances #-}

-- | Prompt records and typed leaves, shared by ordinary and decision rendering.
module Shikumi.Adapter.Prompt (ToPrompt (..), PromptValue (..)) where

import Data.Aeson (Value (..), toJSON)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Kind (Type)
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Generics
import Shikumi.Multimodal (GImageFieldNames (..), GImageFields (..), Image)
import Shikumi.Schema.Types (Constrained (..), Field (..))

class ToPrompt a where
  toPromptFields :: a -> [(Text, Text)]
  default toPromptFields :: (Generic a, GToPromptFields (Rep a)) => a -> [(Text, Text)]
  toPromptFields = gToPromptFields . from

  toPrompt :: a -> Text
  toPrompt = T.intercalate "\n" . map (\(k, v) -> k <> ": " <> v) . toPromptFields

  -- | Structured fields for decision state. Unlike prompt text, strings such as
  -- @"null"@ or @"123"@ stay strings, and numbers, lists and optional values keep
  -- their JSON types. Override for a custom input representation.
  toPromptJSON :: a -> Value
  default toPromptJSON :: (Generic a, GToPromptFields (Rep a)) => a -> Value
  toPromptJSON = Object . KM.fromList . gToPromptJSON . from

  -- | Demonstration JSON retaining rich decision evidence when available.
  toEvidenceJSON :: a -> Value
  default toEvidenceJSON :: (Generic a, GToPromptFields (Rep a)) => a -> Value
  toEvidenceJSON = Object . KM.fromList . gToEvidenceJSON . from

  -- | The 'Image' values an /input/ record carries, in field order (EP-24). The
  -- adapter lowers these to baikai @UserImage@ blocks in @userTurn@. The generic
  -- default walks the record, so any 'Generic' input gets it for free; a record
  -- with no image field yields @[]@ and renders byte-for-byte as before. A
  -- hand-written instance whose fields are polymorphic (e.g.
  -- "Shikumi.Module".@WithReasoning@) cannot be walked generically and overrides
  -- this to @[]@.
  imageFields :: a -> [Image]
  default imageFields :: (Generic a, GImageFields (Rep a)) => a -> [Image]
  imageFields = gImageFields . from

  -- | The names of an input record's image fields, in field order (EP-24). The
  -- text renderer in @userTurn@ drops these so an image is not also rendered as
  -- prose. Same defaulting story as 'imageFields'.
  imageFieldNames :: a -> [Text]
  default imageFieldNames :: (Generic a, GImageFieldNames (Rep a)) => a -> [Text]
  imageFieldNames = gImageFieldNames . from

class GToPromptFields (f :: Type -> Type) where
  gToPromptFields :: f p -> [(Text, Text)]
  gToPromptJSON :: f p -> [(Key.Key, Value)]
  gToEvidenceJSON :: f p -> [(Key.Key, Value)]

instance (GToPromptFields cs) => GToPromptFields (D1 d cs) where
  gToPromptFields (M1 x) = gToPromptFields x
  gToPromptJSON (M1 x) = gToPromptJSON x
  gToEvidenceJSON (M1 x) = gToEvidenceJSON x

instance (GToPromptFields cs) => GToPromptFields (C1 c cs) where
  gToPromptFields (M1 x) = gToPromptFields x
  gToPromptJSON (M1 x) = gToPromptJSON x
  gToEvidenceJSON (M1 x) = gToEvidenceJSON x

instance (GToPromptFields a, GToPromptFields b) => GToPromptFields (a :*: b) where
  gToPromptFields (a :*: b) = gToPromptFields a ++ gToPromptFields b
  gToPromptJSON (a :*: b) = gToPromptJSON a ++ gToPromptJSON b
  gToEvidenceJSON (a :*: b) = gToEvidenceJSON a ++ gToEvidenceJSON b

instance (Selector s, PromptValue t) => GToPromptFields (S1 s (K1 R t)) where
  gToPromptFields m@(M1 (K1 v)) = [(T.pack (selName m), promptValue v)]
  gToPromptJSON m@(M1 (K1 v)) = [(Key.fromString (selName m), promptValueJSON v)]
  gToEvidenceJSON m@(M1 (K1 v)) = [(Key.fromString (selName m), promptEvidenceJSON v)]

-- | Render a leaf value to text. Text stays as-is; lists join with commas;
-- 'Maybe' renders its contents or @""@; a 'Shikumi.Schema.Types.Field' unwraps;
-- everything else falls back to 'Show'.
class PromptValue a where
  promptValue :: a -> Text

  -- | JSON counterpart of the prompt leaf. Custom structured leaves should
  -- override this instead of encoding JSON through 'Show'.
  promptValueJSON :: a -> Value
  promptValueJSON = String . promptValue

  -- | Full demonstration evidence; ordinary leaves keep their structured value.
  promptEvidenceJSON :: a -> Value
  promptEvidenceJSON = promptValueJSON

instance {-# OVERLAPPABLE #-} (Show a) => PromptValue a where
  promptValue = T.pack . show

instance PromptValue Text where
  promptValue = id

instance PromptValue Bool where
  promptValue = T.pack . show
  promptValueJSON = toJSON

instance PromptValue Int where
  promptValue = T.pack . show
  promptValueJSON = toJSON

instance PromptValue Integer where
  promptValue = T.pack . show
  promptValueJSON = toJSON

instance PromptValue Double where
  promptValue = T.pack . show
  promptValueJSON = toJSON

instance (PromptValue a) => PromptValue [a] where
  promptValue = T.intercalate ", " . map promptValue
  promptValueJSON = toJSON . map promptValueJSON

instance (PromptValue a) => PromptValue (Maybe a) where
  promptValue = maybe "" promptValue
  promptValueJSON = maybe Null promptValueJSON

-- Preserve the existing textual representation of described fields. Decision
-- state uses the unwrapped JSON value without changing legacy prompts.
instance (Show a, PromptValue a) => PromptValue (Field d a) where
  promptValue = T.pack . show
  promptValueJSON = promptValueJSON . unField
  promptEvidenceJSON = promptEvidenceJSON . unField

-- | A t'Constrained' field renders as its inner value (the constraint is a
-- compile-time/decode-time concern, not a prompt concern). EP-26.
instance (PromptValue a) => PromptValue (Constrained cs a) where
  promptValue = promptValue . unConstrained
  promptValueJSON = promptValueJSON . unConstrained
  promptEvidenceJSON = promptEvidenceJSON . unConstrained
