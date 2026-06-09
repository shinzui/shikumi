{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}

-- | The provider-neutral @LLM@ effect — integration point #1 of the MasterPlan —
-- and its interpreters, layered on the policy-free @Baikai@ transport effect from
-- the @baikai-effectful@ package.
--
-- The effect exposes two operations ('Complete', 'Stream'). The bare interpreters
-- 'runLLM' / 'runLLMWith' map baikai's 'BaikaiError' into 'ShikumiError' and do
-- nothing else. The resilient interpreter 'runLLMResilient' adds the production
-- features baikai deliberately omits: retries with exponential backoff, an
-- in-flight rate limit, and a US-dollar budget ceiling.
--
-- Every interpreter is written /in terms of/ the @Baikai@ effect
-- ('Baikai.Effectful.complete' / 'Baikai.Effectful.streamCollect') rather than
-- calling baikai's 'IO' functions directly, so shikumi's framework code never
-- carries 'IOE' — only the bottom @Baikai@ interpreter does. Later plans
-- (caching, tracing) re-interpret the same @LLM@ operations, so they must sit
-- above 'runLLMResilient' in the effect stack.
module Shikumi.LLM
  ( -- * The effect
    LLM (..),
    complete,
    stream,

    -- * Bare interpreters
    runLLM,
    runLLMWith,

    -- * Resilience
    RetryPolicy (..),
    defaultRetryPolicy,
    RateLimiter,
    newRateLimiter,
    LLMConfig (..),
    defaultLLMConfig,
    runLLMResilient,

    -- * Re-exports of the baikai request/response vocabulary used at call sites
    Model,
    Context,
    Options,
    Response,
    AssistantMessageEvent,
  )
where

import Baikai
  ( AssistantMessageEvent (..),
    Context,
    Message (..),
    Model,
    Options,
    Response,
    TerminalPayload,
  )
import Baikai.Effectful (Baikai, runBaikai, runBaikaiWith)
import Baikai.Effectful qualified as BE
import Baikai.Error (BaikaiError)
import Baikai.Provider.Registry (ProviderRegistry)
import Control.Concurrent.STM
  ( TVar,
    modifyTVar',
    newTVarIO,
    readTVar,
    retry,
    writeTVar,
  )
import Control.Lens ((^.))
import Data.Generics.Labels ()
import Data.Maybe (mapMaybe)
import Effectful (Dispatch (Dynamic), DispatchOf, Eff, Effect, IOE, liftIO, (:>))
import Effectful.Concurrent (Concurrent, threadDelay)
import Effectful.Concurrent.STM (atomically)
import Effectful.Dispatch.Dynamic (reinterpret_, send)
import Effectful.Error.Static (Error, catchError, throwError)
import Effectful.Exception (bracket_, try)
import Shikumi.Error (ShikumiError (..), fromBaikaiError, isTransient)
import Shikumi.LLM.Budget (Budget, recordCost, tryReserve)

-- | The provider-neutral LM effect. 'Complete' is a blocking completion;
-- 'Stream' returns the assembled list of typed events so callers that need
-- deltas can fold them.
data LLM :: Effect where
  Complete :: Model -> Context -> Options -> LLM m Response
  Stream :: Model -> Context -> Options -> LLM m [AssistantMessageEvent]

type instance DispatchOf LLM = 'Dynamic

-- | Issue a blocking completion. This is integration point #1 — the call every
-- later plan makes. The argument order mirrors baikai's @completeRequest@.
complete :: (LLM :> es) => Model -> Context -> Options -> Eff es Response
complete m c o = send (Complete m c o)

-- | Issue a streaming completion, returning the assembled event list.
stream :: (LLM :> es) => Model -> Context -> Options -> Eff es [AssistantMessageEvent]
stream m c o = send (Stream m c o)

-- ---------------------------------------------------------------------------
-- Bare interpreters
-- ---------------------------------------------------------------------------

-- | Bare interpreter over baikai's process-global registry. Maps 'BaikaiError'
-- into 'ShikumiError' and adds no policy. Use 'runLLMWith' for an isolated
-- registry (tests do this).
runLLM ::
  (IOE :> es, Error ShikumiError :> es) =>
  Eff (LLM : es) a ->
  Eff es a
runLLM = reinterpret_ runBaikai bareHandler

-- | Bare interpreter over an explicit registry.
runLLMWith ::
  (IOE :> es, Error ShikumiError :> es) =>
  ProviderRegistry ->
  Eff (LLM : es) a ->
  Eff es a
runLLMWith reg = reinterpret_ (runBaikaiWith reg) bareHandler

-- | The bare handler, shared by both interpreters. It runs in the handler stack
-- (@Baikai : es@), so it can call the @Baikai@ transport effect and throw
-- through the @Error ShikumiError@ effect. The blocking path catches baikai's
-- 'BaikaiError' (thrown by 'BE.complete') and remaps it; the streaming path
-- surfaces failures in-band as a terminal @EventError@, so it does not catch.
bareHandler ::
  (Baikai :> es, Error ShikumiError :> es) =>
  LLM (Eff localEs) a ->
  Eff es a
bareHandler = \case
  Complete m c o -> do
    res <- try @BaikaiError (BE.complete m c o)
    either (throwError . fromBaikaiError) pure res
  Stream m c o -> BE.streamCollect m c o

-- ---------------------------------------------------------------------------
-- Resilience: retries, rate limiting, budget
-- ---------------------------------------------------------------------------

-- | Exponential-backoff retry policy.
data RetryPolicy = RetryPolicy
  { -- | total tries including the first (>= 1)
    maxAttempts :: !Int,
    -- | first backoff delay, in milliseconds
    baseDelayMs :: !Int,
    -- | cap on any single backoff delay, in milliseconds
    maxDelayMs :: !Int
  }
  deriving stock (Eq, Show)

-- | A sensible default: up to three tries, 200ms base, capped at 5s.
defaultRetryPolicy :: RetryPolicy
defaultRetryPolicy = RetryPolicy {maxAttempts = 3, baseDelayMs = 200, maxDelayMs = 5000}

-- | A simple in-flight rate limiter: a counter of available permits. Build it
-- once with 'newRateLimiter' and store it in the 'LLMConfig' (not per call).
newtype RateLimiter = RateLimiter (TVar Int)

-- | Create a rate limiter that allows at most @n@ concurrent calls.
newRateLimiter :: Int -> IO RateLimiter
newRateLimiter n = RateLimiter <$> newTVarIO n

-- | Interpretation-time policy for 'runLLMResilient'.
data LLMConfig = LLMConfig
  { retryPolicy :: !RetryPolicy,
    -- | 'Nothing' = unlimited cost
    budget :: !(Maybe Budget),
    -- | 'Nothing' = unbounded concurrency
    rateLimit :: !(Maybe RateLimiter),
    -- | which baikai registry to dispatch against
    registry :: !ProviderRegistry
  }

-- | A config with default retries, no budget, and no rate limit, dispatching
-- against the given registry. Set 'budget' / 'rateLimit' to opt in.
defaultLLMConfig :: ProviderRegistry -> LLMConfig
defaultLLMConfig reg =
  LLMConfig
    { retryPolicy = defaultRetryPolicy,
      budget = Nothing,
      rateLimit = Nothing,
      registry = reg
    }

-- | The resilient interpreter. Each operation is wrapped, outermost to
-- innermost, by: budget check → rate-limit acquire → retry loop → the @Baikai@
-- transport call. The budget is reserved once before the attempts and charged
-- once after success; retries re-run only the transport call.
runLLMResilient ::
  (IOE :> es, Concurrent :> es, Error ShikumiError :> es) =>
  LLMConfig ->
  Eff (LLM : es) a ->
  Eff es a
runLLMResilient cfg = reinterpret_ (runBaikaiWith (registry cfg)) $ \case
  Complete m c o ->
    withBudget mb . withRateLimit mr . retrying rp $ do
      res <- try @BaikaiError (BE.complete m c o)
      case res of
        Left be -> throwError (fromBaikaiError be)
        Right resp -> do
          liftIO (chargeBudget mb resp)
          pure resp
  Stream m c o ->
    withBudget mb . withRateLimit mr . retrying rp $ do
      evs <- BE.streamCollect m c o
      liftIO (chargeBudgetFromEvents mb evs)
      pure evs
  where
    mb = budget cfg
    mr = rateLimit cfg
    rp = retryPolicy cfg

-- | Optimistic pre-call budget gate. Refuses the call with 'BudgetExceeded' when
-- the running total has already reached the ceiling.
withBudget ::
  (IOE :> es, Error ShikumiError :> es) =>
  Maybe Budget ->
  Eff es a ->
  Eff es a
withBudget Nothing act = act
withBudget (Just b) act = do
  ok <- liftIO (tryReserve b)
  if ok then act else throwError (BudgetExceeded "cost ceiling reached")

-- | Bound concurrency to the limiter's permits, releasing on every exit path.
withRateLimit ::
  (Concurrent :> es) =>
  Maybe RateLimiter ->
  Eff es a ->
  Eff es a
withRateLimit Nothing act = act
withRateLimit (Just (RateLimiter tv)) act =
  bracket_ acquire release act
  where
    acquire = atomically $ do
      n <- readTVar tv
      if n <= 0 then retry else writeTVar tv (n - 1)
    release = atomically (modifyTVar' tv (+ 1))

-- | Retry a transient-failing action with exponential backoff. Non-transient
-- errors (per 'isTransient') propagate immediately without consuming a retry.
retrying ::
  (Concurrent :> es, Error ShikumiError :> es) =>
  RetryPolicy ->
  Eff es a ->
  Eff es a
retrying pol act = go 1
  where
    go attempt =
      act `catchError` \_cs e ->
        if isTransient e && attempt < maxAttempts pol
          then do
            threadDelay (backoffMicros pol attempt)
            go (attempt + 1)
          else throwError e

-- | Backoff for the @n@-th attempt (1-based), in microseconds, capped by the
-- policy's 'maxDelayMs'.
backoffMicros :: RetryPolicy -> Int -> Int
backoffMicros pol attempt =
  1000 * min (maxDelayMs pol) (baseDelayMs pol * (2 ^ (attempt - 1)))

-- | Charge a completed blocking call's cost against the budget, reading baikai's
-- per-response @Usage.cost.usd@.
chargeBudget :: Maybe Budget -> Response -> IO ()
chargeBudget Nothing _ = pure ()
chargeBudget (Just b) resp = recordCost b (responseCostUSD resp)

-- | The US-dollar cost baikai computed for a response.
responseCostUSD :: Response -> Rational
responseCostUSD resp = resp ^. #message . #usage . #cost . #usd

-- | Charge a completed streaming call's cost, read from the terminal event's
-- assembled message.
chargeBudgetFromEvents :: Maybe Budget -> [AssistantMessageEvent] -> IO ()
chargeBudgetFromEvents Nothing _ = pure ()
chargeBudgetFromEvents (Just b) evs =
  case mapMaybe eventCostUSD evs of
    (c : _) -> recordCost b c
    [] -> pure ()

-- | The cost carried by a terminal streaming event ('EventDone' / 'EventError'),
-- if any.
eventCostUSD :: AssistantMessageEvent -> Maybe Rational
eventCostUSD = \case
  EventDone tp -> terminalCostUSD tp
  EventError tp -> terminalCostUSD tp
  _ -> Nothing

-- | Pull @usage.cost.usd@ out of a terminal payload's assembled message.
terminalCostUSD :: TerminalPayload -> Maybe Rational
terminalCostUSD tp = case tp ^. #message of
  AssistantMessage payload -> Just (payload ^. #usage . #cost . #usd)
  _ -> Nothing
