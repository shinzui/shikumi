{-# LANGUAGE DataKinds #-}

-- | EP-24 M2: the schema/adapter seam recognises an image input field and
-- 'Shikumi.Adapter.render' lowers it to a baikai @UserImage@ block alongside the
-- text fields, with the image field's name dropped from the prompt text. An
-- image-free control input produces no image blocks (the regression-safe path).
module MultimodalAdapterSpec (tests) where

import Baikai
  ( Context,
    ImageContent (..),
    Message (UserMessage),
    TextContent (..),
    UserContent (..),
  )
import Control.Lens ((^.))
import Data.ByteString qualified as BS
import Data.Generics.Labels ()
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import Fixtures (Article, sampleArticle)
import GHC.Generics (Generic)
import Shikumi.Adapter (Adapter (..), ToPrompt, fallbackAdapter, toPrompt)
import Shikumi.Multimodal (Image, imageFromBytes)
import Shikumi.Schema (FromModel, ToSchema, Validatable)
import Shikumi.Schema.Types (Field, field)
import Shikumi.Signature (Signature, mkSignature)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

data Describe = Describe
  { image :: Image,
    question :: Field "What to ask about the image" Text
  }
  deriving stock (Generic, Show)
  deriving anyclass (ToPrompt)

newtype Answer = Answer
  {answer :: Field "A short answer to the question" Text}
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToSchema, FromModel, ToPrompt)

instance Validatable Answer

-- | Every 'ImageContent' carried by a user message in the context, in order.
userImageBlocks :: Context -> [ImageContent]
userImageBlocks ctx =
  [ ic
  | UserMessage p <- V.toList (ctx ^. #messages),
    UserImage ic <- V.toList (p ^. #content)
  ]

-- | Every user text block's text, in order.
userTextBlocks :: Context -> [Text]
userTextBlocks ctx =
  [ t
  | UserMessage p <- V.toList (ctx ^. #messages),
    UserText (TextContent t) <- V.toList (p ^. #content)
  ]

rawPng :: BS.ByteString
rawPng = BS.pack [0x89, 0x50, 0x4e, 0x47]

describeInput :: Describe
describeInput =
  Describe
    { image = imageFromBytes "image/png" rawPng,
      question = field "What vehicle is shown?"
    }

describeSig :: Signature Describe Answer
describeSig = mkSignature "Answer the question about the image"

articleSig :: Signature Article Answer
articleSig = mkSignature "Summarise"

tests :: TestTree
tests =
  testGroup
    "MultimodalAdapterSpec"
    [ testCase "render lowers an image field to a UserImage block with the right bytes" $ do
        let (ctx, _) = render fallbackAdapter describeSig describeInput
        userImageBlocks ctx @?= [ImageContent {imageData = rawPng, mimeType = "image/png"}],
      testCase "render keeps the text fields and drops the image field name" $ do
        let (ctx, _) = render fallbackAdapter describeSig describeInput
            texts = userTextBlocks ctx
        any (T.isInfixOf "What vehicle is shown?") texts @?= True
        -- the image field's name must not leak into the prompt text
        any (T.isInfixOf "image:") texts @?= False,
      testCase "image-free input produces no image blocks (text path unchanged)" $ do
        let (ctx, _) = render fallbackAdapter articleSig sampleArticle
        userImageBlocks ctx @?= []
        userTextBlocks ctx @?= [toPrompt sampleArticle]
    ]
