-- | (1) Records in, records out.
--
-- You never write a prompt. You declare the input and output as ordinary records
-- — a one-line description per field via the @Field "desc" a@ wrapper — and
-- 'predict' turns a 'Signature' into a runnable 'Program'. The schema sent to the
-- provider, the decode, and the validation all fall out of the types.
--
-- This example runs against the offline stub to show the outcomes that matter,
-- each a precise, typed value rather than a parse exception buried in a string:
--
--   * a clean decode to a typed 'Summary';
--   * a missing required field -> 'MissingField';
--   * a domain-rule violation -> 'ValidationFailure'. A domain rule can be
--     enforced two ways, both honest. (a) A type's @Validatable@ instance is run
--     by the decode path in /every/ runner — declare @validate@ on the output
--     type and any decoded value that breaks the rule surfaces as a
--     'ValidationFailure', with no combinator required. (b) The 'validate'
--     combinator ('summarizeChecked' below) attaches a rule at the program level,
--     for rules that belong to a particular program rather than to the type. This
--     example keeps the three-to-five-bullets rule on the combinator so the two
--     mechanisms stay visible side by side; declaring the same rule on 'Summary'
--     would make the decode path reject the bad reply before the combinator even
--     ran.
module Main (main) where

import Data.Text (Text)
import GHC.Generics (Generic)
import Shikumi.Adapter (ToPrompt)
import Shikumi.Combinator (validate)
import Shikumi.Jitsurei.Stub (markerResponse, runStub)
import Shikumi.Module (predict)
import Shikumi.Program (Program)
import Shikumi.Schema (FromModel, ToSchema, Validatable)
import Shikumi.Schema.Types (Field, field, unField)
import Shikumi.Signature (Signature, mkSignature)

-- ---------------------------------------------------------------------------
-- The types are the program. A one-line description per field; bare fields
-- (and 'Maybe') need none.
-- ---------------------------------------------------------------------------

data Article = Article
  { title :: !(Field "The article's headline" Text),
    body :: !(Field "The full article text" Text)
  }
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToSchema, FromModel, ToPrompt)

data Sentiment = Positive | Neutral | Negative
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToSchema, FromModel)

newtype Author = Author {name :: Field "Author full name" Text}
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToSchema, FromModel)

data Summary = Summary
  { headline :: !(Field "A one-line summary" Text),
    bullets :: !(Field "Three to five key points" [Text]),
    author :: !Author, -- a nested record
    sentiment :: !Sentiment, -- an enum-like sum
    note :: !(Maybe Text) -- optional
  }
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToSchema, FromModel, ToPrompt)

-- No type-level rule here: this example keeps the 3-to-5-bullets rule on the
-- 'validate' combinator ('summarizeChecked') to contrast the two mechanisms.
-- The decode path would enforce any rule declared here in every runner.
instance Validatable Summary

-- ---------------------------------------------------------------------------
-- Declare the program. One line for the prediction; one combinator to attach a
-- domain rule (a summary must have three to five bullet points).
-- ---------------------------------------------------------------------------

summarize :: Program Article Summary
summarize = predict summarizeSig

summarizeChecked :: Program Article Summary
summarizeChecked =
  validate threeToFiveBullets "bullets: must have 3 to 5 items" summarize
  where
    threeToFiveBullets s = let n = length (unField (bullets s)) in n >= 3 && n <= 5

summarizeSig :: Signature Article Summary
summarizeSig = mkSignature "Summarize the article into a headline and key points."

sampleArticle :: Article
sampleArticle =
  Article
    { title = field "Typed LM programs",
      body = field "Shikumi makes LM calls behave like ordinary typed software."
    }

-- ---------------------------------------------------------------------------
-- Three canned answers: a good one, one missing a required field, and one that
-- decodes cleanly but violates the three-to-five-bullets rule.
-- ---------------------------------------------------------------------------

goodAnswer :: [(Text, Text)]
goodAnswer =
  [ ("headline", "Shikumi types LM programs"),
    ("bullets", "[\"records in\", \"records out\", \"errors are typed\"]"),
    ("author", "{\"name\": \"Ada\"}"),
    ("sentiment", "Positive"),
    ("note", "null")
  ]

missingBulletsAnswer :: [(Text, Text)]
missingBulletsAnswer = filter ((/= "bullets") . fst) goodAnswer

tooFewBulletsAnswer :: [(Text, Text)]
tooFewBulletsAnswer =
  ("bullets", "[\"only one\"]") : filter ((/= "bullets") . fst) goodAnswer

main :: IO ()
main = do
  putStrLn "jitsurei-predict: records in, records out\n"

  good <- runStub (const (markerResponse goodAnswer)) summarize sampleArticle
  putStrLn $ "good response        -> " <> show good

  missing <- runStub (const (markerResponse missingBulletsAnswer)) summarize sampleArticle
  putStrLn $ "missing 'bullets'    -> " <> show missing

  invalid <- runStub (const (markerResponse tooFewBulletsAnswer)) summarizeChecked sampleArticle
  putStrLn $ "one bullet (invalid) -> " <> show invalid
