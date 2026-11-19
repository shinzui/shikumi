-- | The sealed dataset's representation. This module is not exposed: it is the
-- only place holdout examples can be read from a t'SealedDataset', so code outside
-- the package cannot reach them.
module Shikumi.Evidence.Dataset.Internal
  ( SealedDataset (..),
    HoldoutExample (..),
    sealedHoldout,
  )
where

import Data.Text (Text)
import Shikumi.Eval (Example)
import Shikumi.Optimize.Feedback (StoredCritique)

-- | One protected holdout example: labeled examples carry an expected output,
-- unlabeled ones are counted as missing labels and never executed.
data HoldoutExample i o = HoldoutExample
  { holdoutId :: !Text,
    holdoutInput :: !i,
    holdoutExpected :: !(Maybe o)
  }

-- | A validated envelope opened into typed splits.
data SealedDataset i o = SealedDataset
  { trainingExamples :: ![(Text, Example i o)],
    validationExamples :: ![(Text, Example i o)],
    holdoutExamples :: ![HoldoutExample i o],
    storedCritiques :: ![StoredCritique],
    missingTrainingLabels :: !Int,
    missingValidationLabels :: !Int
  }

-- | The protected holdout. Package-internal.
sealedHoldout :: SealedDataset i o -> [HoldoutExample i o]
sealedHoldout s = s.holdoutExamples
