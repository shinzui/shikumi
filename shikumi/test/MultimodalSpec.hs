-- | EP-24 M1: the 'Image' value type and its lowering to baikai's 'ImageContent'.
-- Hermetic: a known byte string is round-tripped through a file and through
-- base64, and both paths must reach 'ImageContent' with the exact decoded bytes
-- (never base64) and the correct MIME type.
module MultimodalSpec (tests) where

import Baikai (ImageContent (..))
import Data.ByteString qualified as BS
import Data.ByteString.Base64 qualified as Base64
import Data.Text.Encoding (decodeUtf8)
import Shikumi.Multimodal
  ( imageBytes,
    imageFromBase64,
    imageFromFile,
    imageMime,
    imageToContent,
  )
import System.Directory (getTemporaryDirectory, removeFile)
import System.IO (hClose, openTempFile)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "MultimodalSpec"
    [ testCase "imageFromBase64 round-trips decoded bytes into ImageContent" $ do
        let raw = BS.pack [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a] -- PNG magic
            b64 = decodeUtf8 (Base64.encode raw)
        img <- either (assertFailure . show) pure (imageFromBase64 "image/png" b64)
        imageBytes img @?= raw
        let ic = imageToContent img
        imageData ic @?= raw
        mimeType ic @?= "image/png",
      testCase "imageFromFile reads bytes and infers MIME from .png" $ do
        tmp <- getTemporaryDirectory
        (fp, h) <- openTempFile tmp "shikumi-img.png"
        let raw = BS.pack [0x89, 0x50, 0x4e, 0x47]
        BS.hPut h raw
        hClose h
        res <- imageFromFile fp
        img <- either (assertFailure . show) pure res
        imageBytes img @?= raw
        imageMime img @?= "image/png"
        removeFile fp
    ]
