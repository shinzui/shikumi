-- | A running US-dollar cost ceiling for LM calls.
--
-- The budget is enforced /before/ a call by an optimistic 'tryReserve' check and
-- updated /after/ each successful call with 'recordCost', reading baikai's
-- per-response @Usage.cost.usd@ (a 'Rational', always populated). The semantics
-- are deliberately simple: the budget refuses the /next/ call once the running
-- total has reached the ceiling. A single in-flight call is never clipped
-- mid-stream (baikai exposes no streaming cost preview), but once it pushes the
-- total to/over the cap, every subsequent call fails fast.
module Shikumi.LLM.Budget
  ( Budget (..),
    newBudget,
    tryReserve,
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

-- | Optimistic pre-call check: 'True' if a call is permitted (the running total
-- has not yet reached the ceiling), 'False' once the ceiling is met/exceeded.
-- An unlimited budget always permits.
tryReserve :: Budget -> IO Bool
tryReserve b = case ceilingUSD b of
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
