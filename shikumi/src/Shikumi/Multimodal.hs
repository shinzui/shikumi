{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE UndecidableInstances #-}

-- | Multimodal /input/ field types for signatures (EP-24).
--
-- Shikumi's V1 is text-in, text-out: every input field renders to prompt text.
-- This module adds a typed 'Image' field that lowers to baikai's native inline
-- image block ('Baikai.Content.ImageContent' / 'Baikai.Content.UserImage'), so a
-- provider actually /sees/ the picture instead of receiving base64 buried in the
-- running prose.
--
-- 'Image' stores /decoded/ bytes plus a MIME type. base64 is purely a wire
-- concern that baikai handles itself (its @ToJSON ImageContent@ base64-encodes
-- under a @data@ key), so 'imageToContent' is a direct field copy — no encoding
-- happens here.
--
-- Scope (honesty about provider limits): baikai's @UserContent@ models exactly
-- @UserText@ and @UserImage@ today, so this module ships __image only__. Audio and
-- document fields are upstream-gated on a new @Baikai.Content@ constructor; see the
-- EP-24 plan's "Audio and document: upstream-gated future work" section. An 'Image'
-- is __input-only__: it has no 'Shikumi.Schema.ToSchema' instance, so putting one in
-- an /output/ record is a clean compile error (a model cannot emit raw image bytes
-- through the structured-decode path).
module Shikumi.Multimodal
  ( -- * The image field type
    Image (..),
    imageFromBytes,
    imageFromFile,
    imageFromBase64,

    -- * Lowering to baikai
    imageToContent,

    -- * Generic image-field discovery (drives "Shikumi.Adapter"\'s 'Shikumi.Adapter.ToPrompt' image methods)
    GImageFields (..),
    GImageFieldNames (..),
  )
where

import Baikai (ImageContent (..))
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base64 qualified as Base64
import Data.Kind (Type)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (encodeUtf8)
import GHC.Generics
import Shikumi.Error (ShikumiError (..))
import Shikumi.Schema.Types (Field (..))
import System.FilePath (takeExtension)

-- | A typed image usable as a /signature input/ field. Stores decoded bytes and a
-- MIME type; base64 is a wire detail handled by baikai when the image is sent.
data Image = Image
  { bytes :: !ByteString,
    mime :: !Text
  }
  deriving stock (Eq, Show, Generic)

-- | Build an image from already-decoded bytes and an explicit MIME type. The
-- primitive constructor; the others normalise into it.
imageFromBytes :: Text -> ByteString -> Image
imageFromBytes mime bs = Image {bytes = bs, mime = mime}

-- | Read an image file from disk, inferring the MIME type from the extension.
-- Returns 'Left' a 'SchemaMismatch' if the extension is unrecognised (checked
-- before any read, so an unsupported path never touches the filesystem).
imageFromFile :: FilePath -> IO (Either ShikumiError Image)
imageFromFile fp = case mimeForExtension (takeExtension fp) of
  Nothing ->
    pure (Left (SchemaMismatch ("unsupported image extension: " <> T.pack (takeExtension fp))))
  Just mime -> do
    bs <- BS.readFile fp
    pure (Right (imageFromBytes mime bs))

-- | Decode a base64 string into an image with the given MIME type. Returns 'Left'
-- an 'InvalidJSON' decode error if the base64 is malformed.
imageFromBase64 :: Text -> Text -> Either ShikumiError Image
imageFromBase64 mime b64 =
  imageFromBytes mime
    <$> first (\e -> InvalidJSON ("image base64 decode: " <> T.pack e)) (Base64.decode (encodeUtf8 b64))

-- | Lower an 'Image' into baikai's wire image block. Bytes pass through decoded;
-- baikai base64-encodes them only when serialising to the wire.
imageToContent :: Image -> ImageContent
imageToContent img = ImageContent {imageData = bytes img, mimeType = mime img}

-- | A tiny fixed extension-to-MIME table (case-insensitive). Deliberately not a
-- MIME database: the supported image media types are few and stable.
mimeForExtension :: String -> Maybe Text
mimeForExtension ext = case T.toLower (T.pack ext) of
  ".png" -> Just "image/png"
  ".jpg" -> Just "image/jpeg"
  ".jpeg" -> Just "image/jpeg"
  ".gif" -> Just "image/gif"
  ".webp" -> Just "image/webp"
  _ -> Nothing

-- ---------------------------------------------------------------------------
-- Generic image-field discovery
-- ---------------------------------------------------------------------------
--
-- These generic walks back the 'Shikumi.Adapter.ToPrompt' image methods
-- ('Shikumi.Adapter.imageFields' / 'Shikumi.Adapter.imageFieldNames'): the former
-- collects an input record's 'Image' values (so the adapter lowers them to baikai
-- 'Baikai.Content.UserImage' blocks), the latter names those fields (so the text
-- renderer drops them from the prompt body). A record with no image fields yields
-- @[]@ from both, which is exactly the regression-safe text-only path. The methods
-- live on 'Shikumi.Adapter.ToPrompt' (not a separate class) so that the single
-- @ToPrompt i@ constraint already threaded through @predict@/@Predict@/@adapterFor@
-- carries them with no new constraint anywhere; the generic defaults mean any
-- @Generic@ input record gets both for free.

-- | A leaf field's images: a bare 'Image' is one image, a 'Field'-wrapped 'Image'
-- unwraps, and every other leaf type contributes none. This single check drives
-- both the value collector and the field-name collector.
class ImageLeaf t where
  imageLeaf :: t -> [Image]

instance {-# OVERLAPPABLE #-} ImageLeaf a where
  imageLeaf _ = []

instance ImageLeaf Image where
  imageLeaf img = [img]

instance (ImageLeaf a) => ImageLeaf (Field d a) where
  imageLeaf (Field a) = imageLeaf a

-- | Collect the 'Image' values of a record's generic representation, in field
-- order.
class GImageFields (f :: Type -> Type) where
  gImageFields :: f p -> [Image]

instance (GImageFields cs) => GImageFields (D1 d cs) where
  gImageFields (M1 x) = gImageFields x

instance (GImageFields cs) => GImageFields (C1 c cs) where
  gImageFields (M1 x) = gImageFields x

instance (GImageFields a, GImageFields b) => GImageFields (a :*: b) where
  gImageFields (a :*: b) = gImageFields a ++ gImageFields b

instance GImageFields U1 where
  gImageFields _ = []

instance (ImageLeaf t) => GImageFields (S1 s (K1 R t)) where
  gImageFields (M1 (K1 v)) = imageLeaf v

-- A sum type (an enum, or a tagged union) is never an image carrier: image inputs
-- are records. Defined so the generic default is total for any 'Generic' type.
instance GImageFields (l :+: r) where
  gImageFields _ = []

-- | Collect the /names/ of a record's image fields, in field order. Emits a
-- selector's name iff its field type is an 'Image' (bare or 'Field'-wrapped).
class GImageFieldNames (f :: Type -> Type) where
  gImageFieldNames :: f p -> [Text]

instance (GImageFieldNames cs) => GImageFieldNames (D1 d cs) where
  gImageFieldNames (M1 x) = gImageFieldNames x

instance (GImageFieldNames cs) => GImageFieldNames (C1 c cs) where
  gImageFieldNames (M1 x) = gImageFieldNames x

instance (GImageFieldNames a, GImageFieldNames b) => GImageFieldNames (a :*: b) where
  gImageFieldNames (a :*: b) = gImageFieldNames a ++ gImageFieldNames b

instance GImageFieldNames U1 where
  gImageFieldNames _ = []

instance (Selector s, ImageLeaf t) => GImageFieldNames (S1 s (K1 R t)) where
  gImageFieldNames m@(M1 (K1 v)) = [T.pack (selName m) | not (null (imageLeaf v))]

-- A sum type carries no image field names; see 'GImageFields' for the rationale.
instance GImageFieldNames (l :+: r) where
  gImageFieldNames _ = []
