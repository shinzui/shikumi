{-# LANGUAGE DataKinds #-}

module XmlAdapterSpec (tests) where

import Baikai
  ( AssistantContent (..),
    Context,
    Message (..),
    Response,
    TextContent (..),
    emptyResponse,
    emptyTextContent,
  )
import Control.Lens ((&), (.~), (^.))
import Data.Aeson (ToJSON, object, (.=))
import Data.Generics.Labels ()
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import Fixtures (Article, Author (..), Sentiment (..), Summary (..), sampleArticle, sampleSummary)
import GHC.Generics (Generic)
import Shikumi.Adapter (Adapter (..), ToPrompt, nestedXmlAdapter, xmlAdapter)
import Shikumi.Error (ShikumiError (..))
import Shikumi.Schema (FromModel, ToSchema (..), Validatable)
import Shikumi.Schema.Types (Constrained, Constraint (..), field)
import Shikumi.Signature (Demo (..), Signature, mkSignature, setDemos)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))

sig :: Signature Article Summary
sig = setDemos [Demo sampleArticle sampleSummary] (mkSignature "Summarize the article")

-- | Build a response whose single assistant text block carries the given body.
mkResponse :: Text -> Response
mkResponse t =
  emptyResponse & #message . #content .~ V.singleton (AssistantText (emptyTextContent & #text .~ t))

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
    [ nestedTests,
      testCase "xml render: system prompt has the instruction and an XML tag" $ do
        T.isInfixOf "Summarize the article" (sysOf xmlAdapter) @?= True
        T.isInfixOf "<headline>" (sysOf xmlAdapter) @?= True,
      testCase "xml parse: tagged body decodes to the expected Summary" $
        parse xmlAdapter sig (mkResponse xmlBody) @?= Right expectedSummary,
      testCase "xml parse: a missing tag -> MissingField (located)" $
        parse xmlAdapter sig (mkResponse xmlBodyNoBullets) @?= Left (MissingField "bullets")
    ]

-- Separate fixtures keep the richer codec independent of ToPrompt flattening.
data Person = Person {label :: Text, count :: Int}
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToJSON, ToSchema, FromModel)

newtype Meta = Meta {optional :: Maybe Text}
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToJSON, ToSchema, FromModel)

data Envelope = Envelope
  { people :: [Person],
    matrix :: [[Int]],
    metadata :: Meta,
    literal :: Text,
    maybeText :: Maybe Text,
    flag :: Bool,
    ratio :: Double
  }
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToJSON, ToSchema, FromModel, Validatable)

newtype Limited = Limited {value :: Constrained '[ 'MinLen 3] Text}
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToPrompt, ToSchema, FromModel, Validatable)

-- A hand-written union is outside the generated-schema subset and uses JSON.
newtype Manual = Manual {manual :: Text}
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToJSON, FromModel, Validatable)

instance ToSchema Manual where
  toSchema _ = object ["type" .= ("object" :: Text), "properties" .= object ["manual" .= object ["anyOf" .= [object ["type" .= ("string" :: Text)], object ["type" .= ("integer" :: Text)]]]]]

envelopeSig :: Signature Article Envelope
envelopeSig = mkSignature "Encode all nested fields"

example :: Envelope
example = Envelope [Person "Ada & </author>" 2, Person "Lin" 3] [[1, 2], [], [3]] (Meta Nothing) "null" (Just "null") True 1.25

assistantBodies :: Context -> [Text]
assistantBodies ctx = [T.concat [t | AssistantText (TextContent t) <- V.toList (p ^. #content)] | AssistantMessage p <- V.toList (ctx ^. #messages)]

rendered :: Envelope -> [Text]
rendered value = assistantBodies (fst (render nestedXmlAdapter (setDemos [Demo sampleArticle value] envelopeSig) sampleArticle))

decodeEnvelope :: Text -> Either ShikumiError Envelope
decodeEnvelope = parse nestedXmlAdapter envelopeSig . mkResponse

nestedBody :: Text
nestedBody = T.replace "{\"name\": \"Ada\"}" "<name>Ada</name>" $ T.replace "[\"records in\", \"records out\", \"errors are typed\"]" "<item>records in</item><item>records out</item><item>errors are typed</item>" xmlBody

nestedTests :: TestTree
nestedTests =
  testGroup
    "nested codec"
    [ testCase "nested record and list agree with legacy JSON containers" $
        parse xmlAdapter sig (mkResponse nestedBody) @?= Right expectedSummary,
      testCase "same-name nesting balances and unknown properties are ignored" $
        parse xmlAdapter sig (mkResponse (T.replace "<author>" "<author><author/>" nestedBody)) @?= Right expectedSummary,
      testCase "first complete duplicate wins, unknown top-level ignored, prose allowed" $
        parse xmlAdapter sig (mkResponse ("Here is the answer & details. <unknown/>" <> nestedBody <> "<headline>wrong</headline>")) @?= Right expectedSummary,
      testCase "nested occurrence cannot satisfy missing outer field" $
        parse xmlAdapter sig (mkResponse (T.replace "<author>" "<author><bullets/>" (T.replace "{\"name\": \"Ada\"}" "<name>Ada</name>" xmlBodyNoBullets))) @?= Left (MissingField "bullets"),
      testCase "missing nested field retains path" $
        parse xmlAdapter sig (mkResponse (T.replace "<name>Ada</name>" "" nestedBody)) @?= Left (MissingField "author.name"),
      testCase "record validation still executes" $
        parse xmlAdapter sig (mkResponse (T.replace "<item>records in</item>" "" nestedBody)) @?= Left (ValidationFailure "bullets: must have 3 to 5 items"),
      testCase "declared field constraints execute" $
        parse xmlAdapter (mkSignature "Validate" :: Signature Article Limited) (mkResponse "<value>x</value>") @?= Left (ValidationFailure "value: minLength 3 violated"),
      testCase "nested demos round-trip records, matrices, null strings and numeric/boolean scalars" $
        mapM_
          ( \v -> case rendered v of
              [body] -> decodeEnvelope body @?= Right v
              bodies -> assertFailure (show bodies)
          )
          [example, example {people = [], matrix = [], literal = "", maybeText = Nothing, flag = False, ratio = -2.5}, example {literal = "a ]]> b & <tag>  c\nd", maybeText = Just ""}],
      testCase "manual union schemas use escaped JSON fallback" $ do
        let manualSig = setDemos [Demo sampleArticle (Manual "a < b")] (mkSignature "Manual")
            ctx = fst (render nestedXmlAdapter manualSig sampleArticle)
        assistantBodies ctx @?= ["<manual>\"a &lt; b\"</manual>\n"]
        map (parse nestedXmlAdapter manualSig . mkResponse) (assistantBodies ctx) @?= [Right (Manual "a < b")],
      testCase "renderer preserves top-level order and distinguishes null spellings" $
        case rendered example of
          [body] -> do
            T.isPrefixOf "<people>" body @?= True
            T.isInfixOf "<literal>null</literal>" body @?= True
            T.isInfixOf "<maybeText><![CDATA[null]]></maybeText>" body @?= True
            T.isInfixOf "<item><count>2</count><label>" body @?= True
          bodies -> assertFailure (show bodies),
      testCase "guide contains nested fields and repeated items" $ do
        let guide = fromMaybe "" (fst (render nestedXmlAdapter envelopeSig sampleArticle) ^. #systemPrompt)
        T.isInfixOf "<people><item><count>" guide @?= True
        T.isInfixOf "<![CDATA[null]]>" guide @?= True,
      testCase "nullable omission, self-closing empty object, comments and entities" $
        decodeEnvelope "<people/><matrix/><metadata/><!-- ok --><literal>&amp;&lt;&gt;&quot;&apos;&#65;&#x1F600;</literal><flag>false</flag><ratio>2</ratio>"
          @?= Right (Envelope [] [] (Meta Nothing) "&<>\"'A😀" Nothing False 2),
      testCase "CDATA stays literal and preserves inner whitespace" $
        decodeEnvelope "<people/><matrix/><metadata/><literal><![CDATA[a < b  & c]]></literal><maybeText><![CDATA[null]]></maybeText><flag>true</flag><ratio>1</ratio>"
          @?= Right (Envelope [] [] (Meta Nothing) "a < b  & c" (Just "null") True 1),
      testCase "nested scalar errors carry record and array indices" $ do
        let prefix = "<people><item><label>Ada</label><count>wrong</count></item></people>"
        decodeEnvelope prefix @?= Left (SchemaMismatch "people.[0].count: expected integer, got string")
        decodeEnvelope "<people/><matrix><item><item>1</item><item>wrong</item></item></matrix>" @?= Left (SchemaMismatch "matrix.[0].[1]: expected integer, got string"),
      testCase "depth 64 accepted; 65 rejected" $ do
        parse xmlAdapter sig (mkResponse (T.replicate 64 "<x>" <> T.replicate 64 "</x>" <> nestedBody)) @?= Right expectedSummary
        xmlFailure "depth limit 64" (T.replicate 65 "<x>" <> T.replicate 65 "</x>"),
      testCase "size limit counts Unicode code points" $ do
        let body = nestedBody <> T.replicate (1048576 - T.length nestedBody) "😀"
        parse xmlAdapter sig (mkResponse body) @?= Right expectedSummary
        xmlFailure "input length limit 1048576" (body <> "😀"),
      testGroup
        "malformed fragments fail with located XML errors"
        [ testCase (T.unpack bad) (xmlFailure "" bad)
        | bad <-
            [ "<author><name>Ada</author></name>",
              "<headline>unfinished",
              "<x/",
              "</x>",
              "<!DOCTYPE x>",
              "<?xml version='1.0'?>",
              "<x a='b'/>",
              "<ns:x/>",
              "<x>&bogus;</x>",
              "<x>&amp</x>",
              "<x>&#xD800;</x>",
              "<x>&#0;</x>",
              "<x>&#x110000;</x>",
              "<x>&#9999999999999999999999;</x>",
              "<x>&#;</x>",
              "<!-- unclosed",
              "<!-- bad -- comment -->",
              "<x><![CDATA[unfinished</x>",
              "<x>]]></x>",
              "<author>mixed<name>Ada</name></author>",
              "<bullets><wrong/></bullets>"
            ]
        ]
    ]
  where
    xmlFailure expected body = case parse xmlAdapter sig (mkResponse body) of
      Left (SchemaMismatch msg) -> do
        T.isPrefixOf "XML: offset " msg @?= True
        T.isInfixOf expected msg @?= True
      result -> assertFailure (show result)
