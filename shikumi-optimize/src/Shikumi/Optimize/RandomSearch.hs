-- | Bootstrap few-shot with random search (EP-23, DSPy's
-- @BootstrapFewShotWithRandomSearch@): run V1's 'bootstrapFewShot' several times with
-- different deterministic seeds — each shuffling the trainset and picking a random
-- demo count — score each resulting program, and keep the best. A zero-shot baseline
-- candidate is always included, so the search can never do worse than zero-shot.
--
-- This is a /wrapper/ over V1's bootstrap, not a re-implementation (MasterPlan
-- integration point #4). Randomness is a deterministic LCG (glibc constants),
-- mirroring "Shikumi.Optimize.Ensemble", so runs are reproducible with no IO entropy.
module Shikumi.Optimize.RandomSearch
  ( bootstrapRandomSearch,
    bootstrapRandomSearchWith,
    RandomSearchConfig (..),
    defaultRandomSearchConfig,
  )
where

import Control.Lens ((&), (.~))
import Data.Aeson (ToJSON)
import Data.Generics.Labels ()
import Data.List (sortBy)
import Data.Ord (comparing)
import Shikumi.Eval (Dataset, dataset, datasetExamples)
import Shikumi.Optimize.Bootstrap (bootstrapKeptDemos, defaultBootstrapConfig)
import Shikumi.Optimize.LabeledFewShot (withDemos)
import Shikumi.Optimize.Search (freezeProgram, meteredScore, newBudgetMeter, selectBestMetered)
import Shikumi.Optimize.Types (Budget (..), Optimizer (..), Scored (..))
import Shikumi.Program (Program)

-- | Random-search tunables. (The bootstrap pass threshold is left at
-- 'defaultBootstrapConfig'\'s @1.0@ — keep only exactly-correct teacher runs.)
data RandomSearchConfig = RandomSearchConfig
  { -- | lower bound on the per-seed random demo count
    minDemos :: !Int,
    -- | upper bound on the per-seed random demo count
    maxDemos :: !Int
  }
  deriving stock (Eq, Show)

-- | Demo count between 1 and 4.
defaultRandomSearchConfig :: RandomSearchConfig
defaultRandomSearchConfig = RandomSearchConfig {minDemos = 1, maxDemos = 4}

-- | A deterministic linear-congruential stream (glibc constants), duplicated by
-- intent from "Shikumi.Optimize.Ensemble" (which keeps it module-private).
lcg :: Int -> [Int]
lcg s0 = drop 1 (iterate step s0)
  where
    step s = (1103515245 * s + 12345) `mod` 2147483648

-- | A deterministic seed-dependent permutation of the trainset (each example seen at
-- most once), so different seeds give different bootstrap subsets.
shuffle :: Int -> Dataset i o -> Dataset i o
shuffle seed train =
  let exs = datasetExamples train
      keys = take (length exs) (lcg (seed + 1))
   in dataset (map snd (sortBy (comparing fst) (zip keys exs)))

-- | The per-seed demo count, in @[minDemos .. maxDemos]@.
sizeFor :: RandomSearchConfig -> Int -> Int
sizeFor cfg seed =
  let lo = minDemos cfg
      hi = max lo (maxDemos cfg)
      span' = hi - lo + 1
   in case lcg seed of
        (x : _) -> lo + (x `mod` span')
        [] -> lo

-- | 'bootstrapRandomSearch' with explicit tunables.
bootstrapRandomSearchWith ::
  (ToJSON i, ToJSON o) =>
  RandomSearchConfig ->
  -- | teacher
  Program i o ->
  -- | numCandidates: random seeds to try
  Int ->
  Budget ->
  Optimizer i o
bootstrapRandomSearchWith cfg teacher numCandidates budget = Optimizer $ \train metric student -> do
  meter <- newBudgetMeter budget
  let seeds = [1 .. max 1 numCandidates]
      candidateFor seed = do
        let cfg' = defaultBootstrapConfig & #maxBootstrappedDemos .~ sizeFor cfg seed
        demos <- bootstrapKeptDemos cfg' meter teacher (shuffle seed train) metric
        pure (withDemos demos student)
  seeded <- mapM candidateFor seeds
  let cands = student : seeded -- zero-shot baseline first
  best <- selectBestMetered meter (\p -> meteredScore meter train metric p) cands
  pure $ case best of
    Nothing -> freezeProgram student
    Just sc -> freezeProgram (candidate sc)

-- | Run V1 bootstrap over @numCandidates@ random seeds plus a zero-shot baseline,
-- score each on the dataset, and keep the best-scoring 'CompiledProgram'.
bootstrapRandomSearch ::
  (ToJSON i, ToJSON o) =>
  Program i o ->
  Int ->
  Budget ->
  Optimizer i o
bootstrapRandomSearch = bootstrapRandomSearchWith defaultRandomSearchConfig
