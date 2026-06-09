{-# LANGUAGE DeriveAnyClass #-}

-- | The bundled example: a tiny sentiment-classification task wired into a
-- 'Registry'. This /is/ the user's @main@ from the plan's design — a handful of
-- @register@ calls handing the framework typed values — and it doubles as the
-- offline acceptance fixture. A user wanting the CLI for their own programs writes
-- the same shape around their own types.
module Shikumi.Cli.Example
  ( ReviewInput (..),
    SentimentOutput (..),
    sentiment,
    reviews,
    sentimentMetric,
    canonicalInput,
    exampleResponder,
    exampleRegistry,
  )
where

import Baikai (Context, Response)
import Data.Aeson (ToJSON)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import GHC.Generics (Generic)
import Shikumi.Adapter (ToPrompt)
import Shikumi.Cli.Registry (Registry, Task (..), emptyRegistry, register)
import Shikumi.Cli.Runtime (markerResponse)
import Shikumi.Eval (Dataset, Metric, dataset, exactMatch, example)
import Shikumi.Module (predict)
import Shikumi.Optimize (Optimizer, bootstrapFewShot, defaultBudget, labeledFewShot)
import Shikumi.Program (Program)
import Shikumi.Schema (FromModel, ToSchema)
import Shikumi.Signature (mkSignature)

-- | One product review.
newtype ReviewInput = ReviewInput {reviewText :: Text}
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToSchema, FromModel, ToPrompt, ToJSON)

-- | Its sentiment label ("positive" / "negative").
newtype SentimentOutput = SentimentOutput {label :: Text}
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToSchema, FromModel, ToPrompt, ToJSON)

-- | The program: a single typed prediction from a review to a sentiment label.
sentiment :: Program ReviewInput SentimentOutput
sentiment = predict (mkSignature "Classify the sentiment of the review as positive or negative.")

-- | Four labelled reviews; the constant stub answers "positive", so two pass and
-- two fail — a deterministic, believable mixed Report.
reviews :: Dataset ReviewInput SentimentOutput
reviews =
  dataset
    [ example (ReviewInput "Loved it, would buy again") (SentimentOutput "positive"),
      example (ReviewInput "Total waste of money") (SentimentOutput "negative"),
      example (ReviewInput "Exceeded my expectations") (SentimentOutput "positive"),
      example (ReviewInput "Broke on day one") (SentimentOutput "negative")
    ]

-- | Exact-match on the label.
sentimentMetric :: Metric SentimentOutput
sentimentMetric = exactMatch

-- | The canonical input @trace@/@replay@ run the program on.
canonicalInput :: ReviewInput
canonicalInput = ReviewInput "Loved it, would buy again"

-- | The deterministic offline stub: always answers "positive".
exampleResponder :: Context -> Response
exampleResponder _ctx = markerResponse [("label", "positive")]

-- | The named optimizers this task supports.
optimizers :: Map.Map Text (Optimizer ReviewInput SentimentOutput)
optimizers =
  Map.fromList
    [ ("labeled-fewshot", labeledFewShot 2),
      ("bootstrap-fewshot", bootstrapFewShot sentiment defaultBudget)
    ]

-- | The registry the bundled @shikumi@ executable uses: one task, "sentiment".
-- The deterministic offline stub always answers "positive".
exampleRegistry :: Registry
exampleRegistry =
  register
    "sentiment"
    ( Task
        sentiment
        reviews
        sentimentMetric
        canonicalInput
        exampleResponder
        optimizers
    )
    emptyRegistry
