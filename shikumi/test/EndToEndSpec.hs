-- | M6: the full path tied together against a fake 'LLM' interpreter (no
-- network): input record -> rendered request -> canned response -> parsed output
-- record, plus the error path. The real @predict@ belongs to EP-4; this defines a
-- tiny local @runSig@ driver.
module EndToEndSpec (tests) where

import Baikai
  ( AssistantContent (..),
    Model,
    Response,
    _Model,
    _Response,
    _TextContent,
  )
import Control.Lens ((&), (.~))
import Data.Generics.Labels ()
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import Effectful (Eff, runEff, type (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Fixtures (Article, Author (..), Sentiment (..), Summary (..), sampleArticle, sampleSummary)
import Shikumi.Adapter (Adapter (..), fallbackAdapter)
import Shikumi.Error (ShikumiError (..))
import Shikumi.LLM (LLM (..), complete)
import Shikumi.Schema.Types (field)
import Shikumi.Signature (Demo (..), Signature, mkSignature, setDemos)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

-- | Interpret the 'LLM' effect by returning a fixed canned response, ignoring the
-- request entirely.
runFakeLLM :: Response -> Eff (LLM : es) a -> Eff es a
runFakeLLM canned = interpret $ \_ -> \case
  Complete _ _ _ -> pure canned
  Stream _ _ _ -> pure []

-- | A minimal @predict@-like driver: render, call the (fake) model, parse.
runSig :: (LLM :> es) => Adapter i o -> Signature i o -> i -> Eff es (Either ShikumiError o)
runSig adapter signature i = do
  let (ctx, opts) = render adapter signature i
  resp <- complete (_Model :: Model) ctx opts
  pure (parse adapter signature resp)

mkResponse :: Text -> Response
mkResponse t =
  _Response & #message . #content .~ V.singleton (AssistantText (_TextContent & #text .~ t))

sig :: Signature Article Summary
sig = setDemos [Demo sampleArticle sampleSummary] (mkSignature "Summarize the article")

goodResponse :: Response
goodResponse =
  mkResponse $
    T.intercalate
      "\n"
      [ "[[ ## headline ## ]]",
        "Shikumi types LM programs",
        "[[ ## bullets ## ]]",
        "[\"records in\", \"records out\", \"errors are typed\"]",
        "[[ ## author ## ]]",
        "{\"name\": \"Ada\"}",
        "[[ ## sentiment ## ]]",
        "Positive",
        "[[ ## note ## ]]",
        "null",
        "[[ ## completed ## ]]"
      ]

malformedResponse :: Response
malformedResponse =
  mkResponse $
    T.intercalate
      "\n"
      [ "[[ ## headline ## ]]",
        "Shikumi types LM programs",
        "[[ ## author ## ]]",
        "{\"name\": \"Ada\"}",
        "[[ ## sentiment ## ]]",
        "Positive",
        "[[ ## note ## ]]",
        "null",
        "[[ ## completed ## ]]"
      ]

expectedSummary :: Summary
expectedSummary =
  Summary
    { headline = field "Shikumi types LM programs",
      bullets = field ["records in", "records out", "errors are typed"],
      author = Author {name = field "Ada"},
      sentiment = Positive,
      note = Nothing
    }

tests :: TestTree
tests =
  testGroup
    "EndToEndSpec"
    [ testCase "good response decodes to a Summary through the fake LLM" $ do
        out <- runEff . runFakeLLM goodResponse $ runSig fallbackAdapter sig sampleArticle
        out @?= Right expectedSummary,
      testCase "malformed response -> MissingField bullets" $ do
        out <- runEff . runFakeLLM malformedResponse $ runSig fallbackAdapter sig sampleArticle
        out @?= Left (MissingField "bullets")
    ]
