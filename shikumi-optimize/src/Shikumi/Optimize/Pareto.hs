-- | The Pareto-frontier bookkeeping for GEPA (EP-22): a pure, effect-free module so
-- the frontier logic is trivially testable and reproducible. A 'Candidate' is a
-- program identified by its node-parameter vector, carrying its per-example score
-- vector and aggregate. Keeping the /frontier/ (rather than one global best)
-- preserves candidates that win on some examples even if not best on average — the
-- room reflective evolution needs to escape local optima.
module Shikumi.Optimize.Pareto
  ( Candidate (..),
    dominates,
    paretoFrontier,
    sampleParent,
  )
where

import Shikumi.Program (Params)

-- | A candidate program, identified by its @foldParams@-order node parameters, with
-- its per-example scores (dataset order) and their mean.
data Candidate = Candidate
  { candParams :: ![Params],
    candPerExample :: ![Double],
    candAggregate :: !Double
  }
  deriving stock (Eq, Show)

-- | @a@ dominates @b@ when @a >= b@ on every example and @a > b@ on at least one.
-- Equal vectors are NOT domination, so equal candidates coexist on the frontier.
dominates :: Candidate -> Candidate -> Bool
dominates a b =
  let pa = candPerExample a
      pb = candPerExample b
   in length pa == length pb && and (zipWith (>=) pa pb) && or (zipWith (>) pa pb)

-- | The non-dominated subset, preserving input order (so the frontier is
-- reproducible). A candidate is kept iff no other candidate dominates it.
paretoFrontier :: [Candidate] -> [Candidate]
paretoFrontier cs = [c | c <- cs, not (any (`dominates` c) cs)]

-- | Deterministically sample a parent from the frontier, biased toward candidates
-- that achieve the best score on more examples (the "pareto" selection strategy).
-- Pure: takes an explicit 'Int' seed and returns the chosen candidate plus the next
-- seed, so the search threads RNG state with no IO. A simple LCG drives the choice.
sampleParent :: Int -> [Candidate] -> Maybe (Candidate, Int)
sampleParent _ [] = Nothing
sampleParent seed cands@(c0 : _) = Just (go r (zip cands weights), seed')
  where
    cols = length (candPerExample c0)
    colMax j = maximum [candPerExample c !! j | c <- cands]
    weightOf c = max 1 (length [() | j <- [0 .. cols - 1], (candPerExample c !! j) >= colMax j])
    weights = map weightOf cands
    total = max 1 (sum weights)
    seed' = lcg seed
    r = seed' `mod` total
    go _ [] = c0
    go k ((c, w) : rest) = if k < w then c else go (k - w) rest

-- | A small linear congruential generator (glibc constants), kept in-house so runs
-- are reproducible with no IO entropy. Returns a non-negative pseudo-random 'Int'.
lcg :: Int -> Int
lcg x = (1103515245 * abs x + 12345) `mod` 2147483648
