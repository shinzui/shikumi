-- | EP-26 M1: 'Shikumi.Adapter.xmlAdapter'. A third wire format on the typed seam.
-- @render@ asks for @<field>…</field>@ tags; @parse@ reads them back into the
-- typed output via the same 'sectionsToObject' + decode path the fallback adapter
-- uses, so a missing tag yields the same located 'MissingField'.
module XmlAdapterSpec (tests) where

import Baikai
  ( AssistantContent (..),
    Response,
    _Response,
    _TextContent,
  )
import Control.Lens ((&), (.~), (^.))
import Data.Generics.Labels ()
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import Fixtures (Article, Author (..), Sentiment (..), Summary (..), sampleArticle, sampleSummary)
import Shikumi.Adapter (Adapter (..), xmlAdapter)
import Shikumi.Error (ShikumiError (..))
import Shikumi.Schema.Types (field)
import Shikumi.Signature (Demo (..), Signature, mkSignature, setDemos)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

sig :: Signature Article Summary
sig = setDemos [Demo sampleArticle sampleSummary] (mkSignature "Summarize the article")

-- | Build a response whose single assistant text block carries the given body.
mkResponse :: Text -> Response
mkResponse t =
  _Response & #message . #content .~ V.singleton (AssistantText (_TextContent & #text .~ t))

-- | A hand-written XML reply wrapping each 'Summary' field in tags.
xmlBody :: Text
xmlBody =
  T.intercalate
    "\n"
    [ "<headline>",
      "Shikumi types LM programs",
      "</headline>",
      "<bullets>",
      "[\"records in\", \"records out\", \"errors are typed\"]",
      "</bullets>",
      "<author>",
      "{\"name\": \"Ada\"}",
      "</author>",
      "<sentiment>",
      "Positive",
      "</sentiment>",
      "<note>",
      "null",
      "</note>"
    ]

-- | The same body with the @<bullets>@ tag omitted (required field missing).
xmlBodyNoBullets :: Text
xmlBodyNoBullets =
  T.intercalate
    "\n"
    [ "<headline>",
      "Shikumi types LM programs",
      "</headline>",
      "<author>",
      "{\"name\": \"Ada\"}",
      "</author>",
      "<sentiment>",
      "Positive",
      "</sentiment>",
      "<note>",
      "null",
      "</note>"
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

sysOf :: Adapter Article Summary -> Text
sysOf adapter = fromMaybe "" (fst (render adapter sig sampleArticle) ^. #systemPrompt)

tests :: TestTree
tests =
  testGroup
    "XmlAdapterSpec"
    [ testCase "xml render: system prompt has the instruction and an XML tag" $ do
        T.isInfixOf "Summarize the article" (sysOf xmlAdapter) @?= True
        T.isInfixOf "<headline>" (sysOf xmlAdapter) @?= True,
      testCase "xml parse: tagged body decodes to the expected Summary" $
        parse xmlAdapter sig (mkResponse xmlBody) @?= Right expectedSummary,
      testCase "xml parse: a missing tag -> MissingField (located)" $
        parse xmlAdapter sig (mkResponse xmlBodyNoBullets) @?= Left (MissingField "bullets")
    ]
