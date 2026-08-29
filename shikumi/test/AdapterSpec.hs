-- | M5: 'Shikumi.Adapter'. Capability selection is a pure function of the model;
-- the fallback adapter renders @[[ ## field ## ]]@ sections and re-parses them
-- into a typed output, with a missing marker producing 'MissingField'. The native
-- path's schema attachment is pending EP-2.
module AdapterSpec (tests) where

import Baikai
  ( Api (..),
    AssistantContent (..),
    Model,
    Response,
    emptyModel,
    emptyResponse,
    emptyTextContent,
  )
import Control.Lens ((&), (.~), (^.))
import Data.Generics.Labels ()
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import Fixtures (Article, Author (..), Sentiment (..), Summary (..), sampleArticle, sampleSummary)
import Shikumi.Adapter
  ( Adapter (..),
    ModelCapability (..),
    capabilityFor,
    fallbackAdapter,
    nativeAdapter,
  )
import Shikumi.Error (ShikumiError (..))
import Shikumi.Schema.Types (field)
import Shikumi.Signature (Demo (..), Signature, mkSignature, setDemos)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

anthropicModel :: Model
anthropicModel = emptyModel & #provider .~ "anthropic" & #api .~ AnthropicMessages

ollamaModel :: Model
ollamaModel = emptyModel & #provider .~ "ollama" & #api .~ Custom "ollama"

sig :: Signature Article Summary
sig = setDemos [Demo sampleArticle sampleSummary] (mkSignature "Summarize the article")

-- | Build a response whose single assistant text block carries the given body.
mkResponse :: Text -> Response
mkResponse t =
  emptyResponse & #message . #content .~ V.singleton (AssistantText (emptyTextContent & #text .~ t))

markerBody :: Text
markerBody =
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

markerBodyNoBullets :: Text
markerBodyNoBullets =
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

sysOf :: Adapter Article Summary -> Text
sysOf adapter = fromMaybe "" (fst (render adapter sig sampleArticle) ^. #systemPrompt)

tests :: TestTree
tests =
  testGroup
    "AdapterSpec"
    [ testCase "capabilityFor: Anthropic messages -> NativeSchema" $
        capabilityFor anthropicModel @?= NativeSchema,
      testCase "capabilityFor: Custom (ollama) host -> PromptFallback" $
        capabilityFor ollamaModel @?= PromptFallback,
      testCase "fallback render: system prompt has the instruction and field markers" $ do
        T.isInfixOf "Summarize the article" (sysOf fallbackAdapter) @?= True
        T.isInfixOf "[[ ## headline ## ]]" (sysOf fallbackAdapter) @?= True,
      testCase "fallback render: a demo becomes a user/assistant message pair" $
        -- one demo (2 messages) + the actual input (1 message)
        V.length (fst (render fallbackAdapter sig sampleArticle) ^. #messages) @?= 3,
      testCase "fallback parse: marker body decodes to the expected Summary" $
        parse fallbackAdapter sig (mkResponse markerBody) @?= Right expectedSummary,
      testCase "fallback parse: a missing marker -> MissingField (located)" $
        parse fallbackAdapter sig (mkResponse markerBodyNoBullets) @?= Left (MissingField "bullets"),
      testCase "native render: system prompt carries the instruction (schema attach pending EP-2)" $
        T.isInfixOf "Summarize the article" (sysOf nativeAdapter) @?= True
    ]
