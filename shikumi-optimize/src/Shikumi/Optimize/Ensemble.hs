-- | M4 — ensemble search. Run an inner optimizer several times on different
-- /bootstrap resamples/ of the training set (sampling with replacement, the
-- classic bagging trick that makes the resulting candidates complementary),
-- collect the candidate programs, and combine them into one program with EP-5's
-- 'Shikumi.Combinator.ensemble' combinator under a majority-vote reducer. The
-- ensemble runs all members on the input and returns their modal answer, which is
-- correct more often than any single member when the members err on different
-- inputs.
--
-- Resampling is deterministic (a fixed linear-congruential stream seeded by the
-- member index), so the search is reproducible run to run.
module Shikumi.Optimize.Ensemble
  ( ensembleSearch,
    majorityReducer,
  )
where

import Data.Vector qualified as V
import Shikumi.Combinator (ensemble)
import Shikumi.Compile.Types (compiledProgram)
import Shikumi.Eval (Dataset, dataset, datasetExamples)
import Shikumi.Optimize.Search (freezeProgram)
import Shikumi.Optimize.Types (Optimizer (..))

-- | Build an @size@-member ensemble: run @inner@ on @size@ bootstrap resamples of
-- the training set and combine the resulting programs by majority vote.
ensembleSearch :: (Eq o) => Int -> Optimizer i o -> Optimizer i o
ensembleSearch size inner = Optimizer $ \train metric student -> do
  let seeds = [1 .. max 1 size]
  members <-
    mapM
      (\seed -> compiledProgram <$> runOptimizer inner (resample seed train) metric student)
      seeds
  pure (freezeProgram (ensemble members majorityReducer))

-- | Sample a dataset with replacement, deterministically, seeded by @seed@. An
-- empty dataset is returned unchanged.
resample :: Int -> Dataset i o -> Dataset i o
resample seed ds =
  let exs = V.fromList (datasetExamples ds)
      m = V.length exs
   in if m == 0
        then ds
        else dataset [exs V.! (i `mod` m) | i <- take m (lcg seed)]

-- | A simple linear-congruential pseudo-random stream (glibc constants). Pure and
-- deterministic — there is no @Math.random@ in this environment, and reproducible
-- sampling is what the test relies on.
lcg :: Int -> [Int]
lcg s0 = drop 1 (iterate step s0)
  where
    step s = (1103515245 * s + 12345) `mod` 2147483648

-- | The modal value of a non-empty list under 'Eq': most frequent, ties broken by
-- first appearance. This is the ensemble's default vote. (EP-4's @modal@ is not
-- exported, so it is reproduced here.)
majorityReducer :: (Eq o) => [o] -> o
majorityReducer items = case counts of
  [] -> error "Shikumi.Optimize.Ensemble.majorityReducer: empty member list"
  (c : cs) -> fst (foldl' (\best cur -> if snd cur > snd best then cur else best) c cs)
  where
    counts = [(v, length (filter (== v) items)) | v <- distinct items]
    distinct = go []
      where
        go _ [] = []
        go seen (y : ys)
          | any (== y) seen = go seen ys
          | otherwise = y : go (seen ++ [y]) ys
