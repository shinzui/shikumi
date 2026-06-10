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
  )
where

import Baikai (ImageContent (..))
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base64 qualified as Base64
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (encodeUtf8)
import GHC.Generics (Generic)
import Shikumi.Error (ShikumiError (..))
import System.FilePath (takeExtension)

-- | A typed image usable as a /signature input/ field. Stores decoded bytes and a
-- MIME type; base64 is a wire detail handled by baikai when the image is sent.
data Image = Image
  { imageBytes :: !ByteString,
    imageMime :: !Text
  }
  deriving stock (Eq, Show, Generic)

-- | Build an image from already-decoded bytes and an explicit MIME type. The
-- primitive constructor; the others normalise into it.
imageFromBytes :: Text -> ByteString -> Image
imageFromBytes mime bs = Image {imageBytes = bs, imageMime = mime}

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
imageToContent img = ImageContent {imageData = imageBytes img, mimeType = imageMime img}

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
