{-# LANGUAGE DataKinds #-}

-- | Shared record fixtures for the EP-3 specs (schema, signature, adapter,
-- end-to-end). An @Article@ input and a @Summary@ output exercise every supported
-- shape: described 'Field's, a nested record, a list, an enum-like sum, and an
-- optional field, plus a 'Validatable' rule on @Summary@.
module Fixtures
  ( Sentiment (..),
    Author (..),
    Article (..),
    Summary (..),
    sampleArticle,
    sampleSummary,
  )
where

import Data.Text (Text)
import GHC.Generics (Generic)
import Shikumi.Adapter (ToPrompt)
import Shikumi.Schema (FromModel, ToSchema, Validatable (..))
import Shikumi.Schema.Types (Field (..), field)

data Sentiment = Positive | Neutral | Negative
  deriving stock (Generic, Show, Eq)

instance ToSchema Sentiment

instance FromModel Sentiment

newtype Author = Author
  {name :: Field "Author full name" Text}
  deriving stock (Generic, Show, Eq)

instance ToSchema Author

instance FromModel Author

data Article = Article
  { title :: Field "The article's headline" Text,
    body :: Field "The full article text" Text
  }
  deriving stock (Generic, Show, Eq)

instance ToSchema Article

instance FromModel Article

instance ToPrompt Article

data Summary = Summary
  { headline :: Field "A one-line summary" Text,
    bullets :: Field "Three to five key points" [Text],
    author :: Author,
    sentiment :: Sentiment,
    note :: Maybe Text
  }
  deriving stock (Generic, Show, Eq)

instance ToSchema Summary

instance FromModel Summary

instance ToPrompt Summary

-- | A domain rule: a summary must have three to five bullet points.
instance Validatable Summary where
  validate s
    | n < 3 || n > 5 = Left "bullets: must have 3 to 5 items"
    | otherwise = Right s
    where
      n = length (unField (bullets s))

sampleArticle :: Article
sampleArticle =
  Article
    { title = field "Typed LM programs",
      body = field "Shikumi makes LM calls behave like ordinary typed software."
    }

sampleSummary :: Summary
sampleSummary =
  Summary
    { headline = field "Shikumi types LM programs",
      bullets = field ["records in", "records out", "errors are typed"],
      author = Author {name = field "Ada"},
      sentiment = Positive,
      note = Nothing
    }
