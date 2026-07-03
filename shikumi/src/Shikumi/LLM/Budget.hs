-- | A running US-dollar cost ceiling for LM calls.
--
-- The budget is checked /before/ a call by an optimistic 'admitCall' /admission/
-- and updated /after/ each call with 'recordCost', reading baikai's per-response
-- @Usage.cost.usd@ (a 'Rational', always populated). Admission is /not/ a
-- reservation: nothing is held, because baikai exposes no pre-call cost estimate.
-- The honest contract is:
--
--   * a call is admitted while the recorded running total is /strictly under/ the
--     ceiling;
--   * @N@ calls admitted concurrently — all seeing a total under the ceiling before
--     any of them records its cost — are all admitted and all charged, so the total
--     can overshoot the ceiling by up to the sum of those in-flight calls' costs;
--   * once the recorded total reaches (or exceeds) the ceiling, every subsequent
--     admission is refused.
--
-- An unlimited budget (@ceilingUSD == Nothing@) always admits.
module Shikumi.LLM.Budget
  ( Budget (..),
    newBudget,
    admitCall,
    recordCost,
    spentUSD,
  )
where

import Control.Concurrent.STM
  ( TVar,
    atomically,
    modifyTVar',
    newTVarIO,
    readTVar,
    readTVarIO,
  )

-- | A running cost ceiling in US dollars. @ceilingUSD == Nothing@ means
-- "unlimited"; 'spentRef' accumulates the dollars charged so far.
data Budget = Budget
  { ceilingUSD :: !(Maybe Rational),
    spentRef :: !(TVar Rational)
  }

-- | Build a fresh budget with zero spent. Pass 'Nothing' for an unlimited budget.
newBudget :: Maybe Rational -> IO Budget
newBudget c = Budget c <$> newTVarIO 0

-- | Optimistic pre-call admission (not a reservation — nothing is held): 'True'
-- if a call is permitted (the recorded running total is strictly under the
-- ceiling), 'False' once the ceiling is met/exceeded. Because it reserves nothing,
-- @N@ concurrent admissions can each see a sub-ceiling total and all succeed,
-- overshooting by up to the sum of their costs; the first admission after the
-- total reaches the ceiling is refused. An unlimited budget always admits.
admitCall :: Budget -> IO Bool
admitCall b = case ceilingUSD b of
  Nothing -> pure True
  Just cap -> atomically $ do
    s <- readTVar (spentRef b)
    pure (s < cap)

-- | Add the actual cost of a completed call (read from baikai @Usage.cost.usd@).
recordCost :: Budget -> Rational -> IO ()
recordCost b c = atomically $ modifyTVar' (spentRef b) (+ c)

-- | The dollars charged against this budget so far.
spentUSD :: Budget -> IO Rational
spentUSD b = readTVarIO (spentRef b)
