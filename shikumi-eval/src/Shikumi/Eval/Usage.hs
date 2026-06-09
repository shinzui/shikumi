-- | Usage accounting for an evaluation run. 'withUsageTotals' runs an 'Eff'
-- action while accumulating the token usage and cost of every @LLM@ call into a
-- 'UsageTotals', returning both the action's result and the totals.
--
-- The accumulation is a local 'interpose' on EP-1's @LLM@ effect — the same seam
-- EP-6's @cachedLLM@ and EP-7's @tracedLLM@ use. Because @LLM.complete@ returns
-- the full 'Response' (which already carries 'Baikai.Usage.Usage' and
-- 'Baikai.Cost.Cost'), no substrate hook or writer effect is needed; the
-- interposed handler reads usage straight off each response. A shared 'IORef'
-- mutated with 'atomicModifyIORef'' makes the accumulation safe under the bounded
-- concurrency @evaluate@ uses (each pooled worker gets a cloned env that still
-- references the one ref).
module Shikumi.Eval.Usage
  ( withUsageTotals,
  )
where

import Control.Lens ((^.))
import Data.Generics.Labels ()
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Effectful (Eff, IOE, liftIO, (:>))
import Effectful.Dispatch.Dynamic (interpose)
import Shikumi.Eval.Report (UsageTotals (..), emptyUsageTotals)
import Shikumi.LLM (LLM (..), Response, complete, stream)

-- | Run @act@, accumulating every @LLM@ call's usage/cost into a 'UsageTotals'.
withUsageTotals :: (LLM :> es, IOE :> es) => Eff es a -> Eff es (a, UsageTotals)
withUsageTotals act = do
  ref <- liftIO (newIORef emptyUsageTotals)
  result <-
    interpose
      ( \_ -> \case
          Complete m c o -> do
            resp <- complete m c o
            liftIO (atomicModifyIORef' ref (\u -> (u <> usageOf resp, ())))
            pure resp
          Stream m c o -> stream m c o
      )
      act
  totals <- liftIO (readIORef ref)
  pure (result, totals)

-- | Project a response's token usage and cost into a 'UsageTotals'.
usageOf :: Response -> UsageTotals
usageOf resp =
  UsageTotals
    { totalInputTokens = resp ^. #message . #usage . #inputTokens,
      totalOutputTokens = resp ^. #message . #usage . #outputTokens,
      totalTokens = resp ^. #message . #usage . #totalTokens,
      totalCostUsd = resp ^. #message . #usage . #cost . #usd
    }
