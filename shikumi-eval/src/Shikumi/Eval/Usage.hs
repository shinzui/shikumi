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

import Baikai (AssistantMessageEvent (..), AssistantPayload, Message (..), TerminalPayload (..))
import Control.Lens ((^.))
import Data.Generics.Labels ()
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpose)
import Effectful.Prim.IORef (Prim, atomicModifyIORef', newIORef, readIORef)
import Shikumi.Eval.Report (UsageTotals (..), emptyUsageTotals)
import Shikumi.LLM (LLM (..), Response, complete, stream)

-- | Run @act@, accumulating every @LLM@ call's usage/cost into a 'UsageTotals'.
withUsageTotals :: (LLM :> es, Prim :> es) => Eff es a -> Eff es (a, UsageTotals)
withUsageTotals act = do
  ref <- newIORef emptyUsageTotals
  result <-
    interpose
      ( \_ -> \case
          Complete m c o -> do
            resp <- complete m c o
            atomicModifyIORef' ref (\u -> (u <> usageOf resp, ()))
            pure resp
          Stream m c o -> do
            events <- stream m c o
            atomicModifyIORef' ref (\u -> (u <> streamUsage events, ()))
            pure events
      )
      act
  totals <- readIORef ref
  pure (result, totals)

-- | Project a response's token usage and cost into a 'UsageTotals'.
usageOf :: Response -> UsageTotals
usageOf resp = usageOfAssistant (resp ^. #message)

-- | Project an assistant message's token usage and cost into a 'UsageTotals'.
usageOfMessage :: Message -> UsageTotals
usageOfMessage (AssistantMessage msg) = usageOfAssistant msg
usageOfMessage _ = emptyUsageTotals

-- | Project an assistant payload's token usage and cost into a 'UsageTotals'.
usageOfAssistant :: AssistantPayload -> UsageTotals
usageOfAssistant msg =
  UsageTotals
    { totalInputTokens = msg ^. #usage . #inputTokens,
      totalOutputTokens = msg ^. #usage . #outputTokens,
      totalTokens = msg ^. #usage . #totalTokens,
      totalCostUsd = msg ^. #usage . #cost . #usd
    }

-- | The usage of one streamed call: read off terminal events. Baikai streams
-- emit exactly one 'EventDone' or 'EventError' carrying the assembled message
-- with final usage; deltas carry no usage.
streamUsage :: [AssistantMessageEvent] -> UsageTotals
streamUsage evs =
  mconcat
    [ usageOfMessage msg
    | ev <- evs,
      msg <- case ev of
        EventDone TerminalPayload {message = m} -> [m]
        EventError TerminalPayload {message = m} -> [m]
        _ -> []
    ]
