-- | M1 — labeled few-shot demo selection, the simplest real optimizer (DSPy's
-- @LabeledFewShot@). Each training example /is/ a candidate demonstration; the
-- search forms several size-@k@ demo sets, scores each by attaching it to every
-- node and evaluating over the training set, and keeps the highest-scoring set.
--
-- No LM calls are made beyond scoring. Candidate sets are enumerated
-- deterministically (all size-@k@ combinations of the training demos, in a fixed
-- order) rather than randomly sampled. 'labeledFewShotWith' reserves one scoring
-- cost per candidate before evaluation and stops at the shared 'Budget'; the
-- default 'labeledFewShot' uses 'defaultBudget'.
module Shikumi.Optimize.LabeledFewShot
  ( labeledFewShot,
    labeledFewShotWith,
    labeledCandidateSets,
    withDemos,
  )
where

import Control.Lens ((&), (.~))
import Data.Aeson (ToJSON, toJSON)
import Data.Generics.Labels ()
import Shikumi.Eval (Dataset, Example (..), datasetExamples)
import Shikumi.Optimize.Search (freezeProgram, meteredScore, newBudgetMeter, selectBestMetered)
import Shikumi.Optimize.Types (Budget, Optimizer (..), Scored (..), defaultBudget)
import Shikumi.Program (Demo (..), Program, mapParams)

-- | Select the best size-@k@ set of labelled demonstrations from the training set.
-- Multi-node programs receive the same demo set at every node (the DSPy default).
labeledFewShot :: (ToJSON i, ToJSON o) => Int -> Optimizer i o
labeledFewShot = labeledFewShotWith defaultBudget

-- | Select the best size-@k@ labelled demo set under an explicit budget.
labeledFewShotWith :: (ToJSON i, ToJSON o) => Budget -> Int -> Optimizer i o
labeledFewShotWith budget k = Optimizer $ \train metric prog -> do
  meter <- newBudgetMeter budget
  let sets = labeledCandidateSets k train
  best <- selectBestMetered meter (\ds -> meteredScore meter train metric (withDemos ds prog)) sets
  pure $ case best of
    Nothing -> freezeProgram prog
    Just sc -> freezeProgram (withDemos (candidate sc) prog)

-- | The candidate demo sets a 'labeledFewShot' search considers: every size-@k@
-- combination of the training examples (each turned into a JSON 'Demo'), in
-- deterministic enumeration order. Exposed so tests can reproduce the exact set of
-- candidates the optimizer scored.
labeledCandidateSets :: (ToJSON i, ToJSON o) => Int -> Dataset i o -> [[Demo]]
labeledCandidateSets k train = combinations k allDemos
  where
    allDemos =
      [ Demo {input = toJSON i, output = toJSON o}
      | Example i o <- datasetExamples train
      ]

-- | Attach a demo set to every node, leaving each node's instruction untouched.
withDemos :: [Demo] -> Program i o -> Program i o
withDemos ds = mapParams (\ps -> ps & #demos .~ ds)

-- | All size-@k@ sub-lists of a list, preserving relative order
-- (@combinations 2 [a,b,c] = [[a,b],[a,c],[b,c]]@).
combinations :: Int -> [a] -> [[a]]
combinations k _ | k <= 0 = [[]]
combinations _ [] = []
combinations k (x : xs) = map (x :) (combinations (k - 1) xs) ++ combinations k xs
