{-# LANGUAGE DataKinds #-}

-- | M2 (schema derivation) + M3 (total decode and the failure taxonomy) for
-- "Shikumi.Schema". Schema equality is compared as an aeson 'Value' (key order
-- does not matter); every failing input asserts the exact located 'ShikumiError'.
module SchemaSpec (tests) where

import Data.Aeson (Value, object, (.=))
import Data.Text (Text)
import Fixtures (Author (..), Sentiment (..), Summary (..))
import Shikumi.Error (ShikumiError (..))
import Shikumi.Schema (deriveSchema, parseOutput)
import Shikumi.Schema.Types (field)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))

-- | The schema we expect @deriveSchema \@Summary@ to produce.
expectedSummarySchema :: Value
expectedSummarySchema =
  object
    [ "type" .= s "object",
      "properties"
        .= object
          [ "headline" .= object ["type" .= s "string", "description" .= s "A one-line summary"],
            "bullets"
              .= object
                [ "type" .= s "array",
                  "items" .= object ["type" .= s "string"],
                  "description" .= s "Three to five key points"
                ],
            "author"
              .= object
                [ "type" .= s "object",
                  "properties"
                    .= object
                      ["name" .= object ["type" .= s "string", "description" .= s "Author full name"]],
                  "required" .= ["name" :: Text],
                  "additionalProperties" .= False
                ],
            "sentiment" .= object ["enum" .= (["Positive", "Neutral", "Negative"] :: [Text])],
            "note" .= object ["anyOf" .= [object ["type" .= s "string"], object ["type" .= s "null"]]]
          ],
      "required" .= (["headline", "bullets", "author", "sentiment"] :: [Text]),
      "additionalProperties" .= False
    ]
  where
    s = id :: Text -> Text

-- | A valid provider reply.
goodBody :: Text
goodBody =
  "{\"headline\":\"H\",\"bullets\":[\"a\",\"b\",\"c\"],\
  \\"author\":{\"name\":\"Ada\"},\"sentiment\":\"Positive\",\"note\":null}"

decode :: Text -> Either ShikumiError Summary
decode = parseOutput

tests :: TestTree
tests =
  testGroup
    "SchemaSpec"
    [ testCase "deriveSchema @Summary matches the expected JSON Schema" $
        deriveSchema @Summary @?= expectedSummarySchema,
      testCase "good provider JSON decodes to the expected Summary" $
        decode goodBody
          @?= Right
            Summary
              { headline = field "H",
                bullets = field ["a", "b", "c"],
                author = Author {name = field "Ada"},
                sentiment = Positive,
                note = Nothing
              },
      testCase "missing required field -> MissingField (located)" $
        decode "{\"bullets\":[\"a\",\"b\",\"c\"],\"author\":{\"name\":\"Ada\"},\"sentiment\":\"Positive\"}"
          @?= Left (MissingField "headline"),
      testCase "wrong JSON type -> SchemaMismatch (located)" $
        decode "{\"headline\":\"H\",\"bullets\":\"oops\",\"author\":{\"name\":\"Ada\"},\"sentiment\":\"Positive\"}"
          @?= Left (SchemaMismatch "bullets: expected array, got string"),
      testCase "bad enum value -> SchemaMismatch listing the choices" $
        decode "{\"headline\":\"H\",\"bullets\":[\"a\",\"b\",\"c\"],\"author\":{\"name\":\"Ada\"},\"sentiment\":\"Angry\"}"
          @?= Left (SchemaMismatch "sentiment: expected one of [Positive, Neutral, Negative]"),
      testCase "validation rule violation -> ValidationFailure" $
        decode "{\"headline\":\"H\",\"bullets\":[\"a\"],\"author\":{\"name\":\"Ada\"},\"sentiment\":\"Positive\"}"
          @?= Left (ValidationFailure "bullets: must have 3 to 5 items"),
      testCase "non-JSON body -> InvalidJSON" $
        case decode "not json" of
          Left (InvalidJSON _) -> pure ()
          other -> assertFailure ("expected Left (InvalidJSON ...), got " <> show other)
    ]
