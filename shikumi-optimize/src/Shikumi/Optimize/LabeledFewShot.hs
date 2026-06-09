-- | M1 — labeled few-shot demo selection, the simplest real optimizer (DSPy's
-- @LabeledFewShot@). Each training example /is/ a candidate demonstration; the
-- search forms several size-@k@ demo sets, scores each by attaching it to every
-- node and evaluating over the training set, and keeps the highest-scoring set.
--
-- No LM calls are made beyond scoring. Candidate sets are enumerated
-- deterministically (all size-@k@ combinations of the training demos, in a fixed
-- order, bounded by the budget) rather than randomly sampled, so the result is
-- reproducible run to run — the tests rely on this.
module Shikumi.Optimize.LabeledFewShot
  ( labeledFewShot,
    labeledCandidateSets,
    withDemos,
  )
where

import Data.Aeson (ToJSON, toJSON)
import Shikumi.Eval (Dataset, Example (..), datasetExamples)
import Shikumi.Optimize.Search (freezeProgram, scoreOn, selectBest)
import Shikumi.Optimize.Types (Optimizer (..), Scored (..), defaultBudget)
import Shikumi.Program (Demo (..), Params (..), Program, mapParams)

-- | Select the best size-@k@ set of labelled demonstrations from the training set.
-- Multi-node programs receive the same demo set at every node (the DSPy default).
labeledFewShot :: (ToJSON i, ToJSON o) => Int -> Optimizer i o
labeledFewShot k = Optimizer $ \train metric prog -> do
  let sets = labeledCandidateSets k train
  best <- selectBest defaultBudget (\ds -> scoreOn train metric (withDemos ds prog)) sets
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
withDemos ds = mapParams (\ps -> ps {demos = ds})

-- | All size-@k@ sub-lists of a list, preserving relative order
-- (@combinations 2 [a,b,c] = [[a,b],[a,c],[b,c]]@).
combinations :: Int -> [a] -> [[a]]
combinations k _ | k <= 0 = [[]]
combinations _ [] = []
combinations k (x : xs) = map (x :) (combinations (k - 1) xs) ++ combinations k xs
