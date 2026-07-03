-- | (9) Multimodal input: an image field the model actually sees.
--
-- A signature /input/ can carry a typed 'Image' field. When the request is
-- rendered, the image lowers to baikai's native inline image block (@UserImage@),
-- the remaining text fields render as a leading text block, and the image field's
-- name is dropped from that text — so the picture is delivered as a picture, not as
-- base64 buried in the prose.
--
-- This example renders an image-bearing request offline and shows that the user
-- turn carries a real image block (the model genuinely receives the picture), then
-- runs the full render -> stub -> parse loop to a typed answer. (An 'Image' is
-- input-only: it has no @ToSchema@, so it cannot appear in an output record — that
-- would be a compile error.)
module Main (main) where

import Baikai
  ( Context,
    ImageContent (..),
    Message (UserMessage),
    Response,
    TextContent (..),
    UserContent (..),
    _Model,
  )
import Control.Lens ((^.))
import Data.ByteString qualified as BS
import Data.Generics.Labels ()
import Data.Text (Text)
import Data.Vector qualified as V
import Effectful (runEff)
import GHC.Generics (Generic)
import Shikumi.Adapter (Adapter (..), ToPrompt, fallbackAdapter)
import Shikumi.Error (ShikumiError)
import Shikumi.Jitsurei.Stub (markerResponse, runStubLLM)
import Shikumi.LLM (complete)
import Shikumi.Multimodal (Image, imageFromBytes)
import Shikumi.Schema (FromModel, ToSchema, Validatable)
import Shikumi.Schema.Types (Field, field)
import Shikumi.Signature (Signature, mkSignature)

-- ---------------------------------------------------------------------------
-- The input carries a picture; the output is an ordinary typed record.
-- ---------------------------------------------------------------------------

data Describe = Describe
  { photo :: !Image, -- an input-only image field
    question :: !(Field "What to ask about the image" Text)
  }
  deriving stock (Generic, Show)
  deriving anyclass (ToPrompt) -- the generic default discovers the image field

newtype Caption = Caption
  {caption :: Field "A short caption answering the question" Text}
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToSchema, FromModel, ToPrompt)

instance Validatable Caption

describeSig :: Signature Describe Caption
describeSig = mkSignature "Answer the question about the image."

-- A tiny stand-in image (the PNG magic bytes — enough to demonstrate the lowering;
-- a real run would use 'imageFromFile' or 'imageFromBase64').
rawPng :: BS.ByteString
rawPng = BS.pack [0x89, 0x50, 0x4e, 0x47]

describeInput :: Describe
describeInput =
  Describe
    { photo = imageFromBytes "image/png" rawPng,
      question = field "What vehicle is shown?"
    }

-- ---------------------------------------------------------------------------
-- Inspecting the rendered request: how many image / text blocks the user turn has.
-- ---------------------------------------------------------------------------

userImageBlocks :: Context -> [ImageContent]
userImageBlocks ctx =
  [ ic
  | UserMessage p <- V.toList (ctx ^. #messages),
    UserImage ic <- V.toList (p ^. #content)
  ]

userTextBlocks :: Context -> [Text]
userTextBlocks ctx =
  [ t
  | UserMessage p <- V.toList (ctx ^. #messages),
    UserText (TextContent t) <- V.toList (p ^. #content)
  ]

-- An image input has no @FromModel@, so this uses the manual render -> call -> parse
-- driver (the same one EP-24's end-to-end test uses) rather than @predict@.
runDescribe :: (Context -> Response) -> IO (Either ShikumiError Caption)
runDescribe responder =
  runEff . runStubLLM responder $ do
    let (ctx, opts) = render fallbackAdapter describeSig describeInput
    resp <- complete _Model ctx opts
    pure (parse fallbackAdapter describeSig resp)

main :: IO ()
main = do
  putStrLn "jitsurei-multimodal: an image input the model actually sees\n"

  let (ctx, _) = render fallbackAdapter describeSig describeInput
  putStrLn $ "rendered request image blocks -> " <> show (length (userImageBlocks ctx))
  putStrLn $ "  (mime: " <> show (map mimeType (userImageBlocks ctx)) <> ")"
  putStrLn $ "user text blocks              -> " <> show (userTextBlocks ctx)
  putStrLn "  (note: the 'photo' field's name is absent — it became an image block, not prose)\n"

  out <- runDescribe (const (markerResponse [("caption", "A red bicycle.")]))
  putStrLn $ "render -> stub -> parse        -> " <> show out
