-- | The evaluation data model — MasterPlan integration point #5. The optimizer
-- (@docs/plans/10-optimizer-framework.md@) and the CLI
-- (@docs/plans/12-cli-and-developer-experience.md@) /consume/ these types and
-- must not redefine them.
--
-- A 'Score' is a 'Double' clamped to the closed interval @[0, 1]@ at
-- construction, so downstream ranking code can assume @0 <= s <= 1@ without
-- re-checking (a @Bool@ metric maps @True -> 1@, @False -> 0@). An 'Example' is
-- one labelled datum (input + expected output); a 'Dataset' is a list of them. A
-- 'Prediction' is a program's actual output for one example, carrying a primary
-- output plus the non-empty set of sampled outputs (a single-output program
-- yields a one-element 'Prediction'), so agreement-rewarding metrics
-- (majority-vote, ensemble) can inspect every sample.
module Shikumi.Eval.Types
  ( -- * Scores
    Score,
    mkScore,
    scoreZero,
    scoreOne,
    boolScore,
    unScore,

    -- * Examples and datasets
    Example (..),
    example,
    Dataset (..),
    dataset,
    datasetExamples,
    datasetSize,

    -- * Predictions (program outputs)
    Prediction (..),
    prediction,
    predictionPrimary,
    predictionSamples,
  )
where

import Data.Aeson (Value)
import Data.List.NonEmpty (NonEmpty (..))

-- | A metric score, always in the closed interval @[0, 1]@.
newtype Score = Score Double
  deriving stock (Eq, Ord, Show)

-- | Clamp any 'Double' into @[0, 1]@.
mkScore :: Double -> Score
mkScore d = Score (max 0 (min 1 d))

-- | The two interval endpoints as scores.
scoreZero, scoreOne :: Score
scoreZero = Score 0
scoreOne = Score 1

-- | Map a boolean outcome to a score: @True -> 1@, @False -> 0@.
boolScore :: Bool -> Score
boolScore True = scoreOne
boolScore False = scoreZero

-- | Project the underlying 'Double' (always in @[0, 1]@).
unScore :: Score -> Double
unScore (Score d) = d

-- | One labelled datum: an input of type @i@ and its expected output of type @o@.
data Example i o = Example
  { input :: !i,
    expected :: !o
  }
  deriving stock (Eq, Show)

-- | Build an 'Example' from an input and its expected output.
example :: i -> o -> Example i o
example = Example

-- | A typed evaluation dataset.
newtype Dataset i o = Dataset [Example i o]
  deriving stock (Eq, Show)

-- | Build a 'Dataset' from a list of examples.
dataset :: [Example i o] -> Dataset i o
dataset = Dataset

-- | The examples of a dataset, in order.
datasetExamples :: Dataset i o -> [Example i o]
datasetExamples (Dataset xs) = xs

-- | The number of examples in a dataset.
datasetSize :: Dataset i o -> Int
datasetSize (Dataset xs) = length xs

-- | A program's actual output for one example. Carries a primary output and the
-- non-empty set of sampled outputs (a single-output program yields one sample).
-- An optional raw JSON @detail@ lets adapters or judges attach structure.
data Prediction o = Prediction
  { primary :: !o,
    samples :: !(NonEmpty o),
    detail :: !(Maybe Value)
  }
  deriving stock (Eq, Show)

-- | Build a single-sample prediction (primary output, one sample, no detail).
prediction :: o -> Prediction o
prediction o = Prediction o (o :| []) Nothing

-- | The designated primary output of a prediction.
predictionPrimary :: Prediction o -> o
predictionPrimary = primary

-- | The non-empty set of sampled outputs.
predictionSamples :: Prediction o -> NonEmpty o
predictionSamples = samples
