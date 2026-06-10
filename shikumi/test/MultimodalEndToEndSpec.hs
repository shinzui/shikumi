{-# LANGUAGE DataKinds #-}

-- | EP-24 M3: the full render -> stub -> parse loop for an image-bearing
-- signature. A capturing 'LLM' interpreter records the 'Context' it is handed so
-- the test can prove the model genuinely received a @UserImage@ block, then
-- returns a canned @[[ ## answer ## ]]@ body that decodes into a typed 'Answer'.
-- A second test locks in the regression invariant: an image-free input renders a
-- 'Context' with no image blocks and the unchanged text-only user turn.
module MultimodalEndToEndSpec (tests) where

import Baikai
  ( AssistantContent (..),
    Context,
    ImageContent (..),
    Message (UserMessage),
    Model,
    Response,
    TextContent (..),
    UserContent (..),
    _Model,
    _Response,
    _TextContent,
  )
import Control.Lens ((&), (.~), (^.))
import Data.ByteString qualified as BS
import Data.Generics.Labels ()
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import Effectful (Eff, IOE, liftIO, runEff, type (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Fixtures (Article, sampleArticle)
import GHC.Generics (Generic)
import Shikumi.Adapter (Adapter (..), ToPrompt, fallbackAdapter, toPrompt)
import Shikumi.Error (ShikumiError)
import Shikumi.LLM (LLM (..), complete)
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

-- | Interpret 'LLM' by capturing the request 'Context' into an 'IORef' and
-- returning a fixed canned response. Runs under 'IOE' (the suite uses 'runEff').
runCapturingLLM :: (IOE :> es) => IORef (Maybe Context) -> Response -> Eff (LLM : es) a -> Eff es a
runCapturingLLM capture canned = interpret $ \_ -> \case
  Complete _ ctx _ -> do
    liftIO (writeIORef capture (Just ctx))
    pure canned
  Stream _ _ _ -> pure []

-- | render -> call (captured) model -> parse.
runSig :: (LLM :> es) => Adapter i o -> Signature i o -> i -> Eff es (Either ShikumiError o)
runSig adapter signature i = do
  let (ctx, opts) = render adapter signature i
  resp <- complete (_Model :: Model) ctx opts
  pure (parse adapter signature resp)

mkResponse :: Text -> Response
mkResponse t =
  _Response & #message . #content .~ V.singleton (AssistantText (_TextContent & #text .~ t))

cannedAnswer :: Response
cannedAnswer =
  mkResponse $
    T.intercalate
      "\n"
      [ "[[ ## answer ## ]]",
        "A red bicycle.",
        "[[ ## completed ## ]]"
      ]

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

rawPng :: BS.ByteString
rawPng = BS.pack [0x89, 0x50, 0x4e, 0x47]

tests :: TestTree
tests =
  testGroup
    "MultimodalEndToEndSpec"
    [ testCase "Describe with an image: model receives a UserImage block; answer decodes" $ do
        capture <- newIORef Nothing
        let img = imageFromBytes "image/png" rawPng
            input = Describe {image = img, question = field "What vehicle is shown?"}
            sig = mkSignature "Answer the question about the image" :: Signature Describe Answer
        out <-
          runEff . runCapturingLLM capture cannedAnswer $
            runSig fallbackAdapter sig input
        out @?= Right (Answer {answer = field "A red bicycle."})
        Just ctx <- readIORef capture
        userImageBlocks ctx @?= [ImageContent {imageData = rawPng, mimeType = "image/png"}]
        any (T.isInfixOf "What vehicle is shown?") (userTextBlocks ctx) @?= True,
      testCase "image-free input renders the unchanged text-only Context" $ do
        capture <- newIORef Nothing
        let sig = mkSignature "Summarize" :: Signature Article Answer
        _ <-
          runEff . runCapturingLLM capture cannedAnswer $
            runSig fallbackAdapter sig sampleArticle
        Just ctx <- readIORef capture
        userImageBlocks ctx @?= []
        userTextBlocks ctx @?= [toPrompt sampleArticle]
    ]
