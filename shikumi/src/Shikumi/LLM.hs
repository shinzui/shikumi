{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}

-- | The provider-neutral @LLM@ effect — integration point #1 of the MasterPlan —
-- and its interpreters, layered on the policy-free @Baikai@ transport effect from
-- the @baikai-effectful@ package.
--
-- The effect exposes two operations ('Complete', 'Stream'). The bare interpreters
-- 'runLLM' / 'runLLMWith' map baikai's 'BaikaiError' into 'ShikumiError' and do
-- validate continuation compatibility before transport. The resilient interpreter 'runLLMResilient' adds the production
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
    runLLMWithObserver,

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
    responseError,
  )
import Baikai.Effectful (Baikai, runBaikai, runBaikaiWith)
import Baikai.Effectful qualified as BE
import Baikai.Error (BaikaiError)
import Baikai.Provider.Registry (ProviderRegistry)
import Baikai.Usage qualified as U
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
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text qualified as T
import Data.Time.Clock (getCurrentTime)
import Data.Unique (hashUnique, newUnique)
import Effectful (Dispatch (Dynamic), DispatchOf, Eff, Effect, IOE, liftIO, (:>))
import Effectful.Concurrent (Concurrent, threadDelay)
import Effectful.Concurrent.STM (atomically)
import Effectful.Dispatch.Dynamic (reinterpret_, send)
import Effectful.Error.Static (Error, catchError, throwError)
import Effectful.Exception (bracket_, try)
import Shikumi.Error (ShikumiError (..), fromBaikaiError, isTransient)
import Shikumi.LLM.Budget (Budget, admitCall, recordCost)
import Shikumi.LLM.Continuation
import Shikumi.LLM.Observation qualified as O

-- | The provider-neutral LM effect. 'Complete' is a blocking completion;
-- 'Stream' returns the assembled list of typed events so callers that need
-- deltas can fold them.
--
-- Stream-error contract (all shikumi interpreters): the returned event list
-- never terminates with an @EventError@. A provider failure — which the
-- policy-free @Baikai@ transport surfaces in-band as a terminal @EventError@ — is
-- converted to an out-of-band 'ShikumiError' thrown through @Error ShikumiError@,
-- so 'stream' failures are transient-retryable and reported exactly like
-- 'complete' failures.
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
runLLM = reinterpret_ runBaikai (bareHandler O.noObservation)

-- | Bare interpreter over an explicit registry.
runLLMWith ::
  (IOE :> es, Error ShikumiError :> es) =>
  ProviderRegistry ->
  Eff (LLM : es) a ->
  Eff es a
runLLMWith reg = runLLMWithObserver reg O.noObservation

-- | Observe bare transport calls. Callback exceptions propagate without retries.
runLLMWithObserver :: (IOE :> es, Error ShikumiError :> es) => ProviderRegistry -> O.LLMObserver -> Eff (LLM : es) a -> Eff es a
runLLMWithObserver reg observer = reinterpret_ (runBaikaiWith reg) (bareHandler observer)

-- | The bare handler, shared by both interpreters. It runs in the handler stack
-- (@Baikai : es@), so it can call the @Baikai@ transport effect and throw
-- through the @Error ShikumiError@ effect. The blocking path routes baikai's
-- in-band failure (an error-shaped 'Response') through 'raiseResponseError' — plus
-- a defensive 'try' for any residual thrown 'BaikaiError' — and remaps it; the
-- streaming path collects the events and, via 'raiseStreamError', converts a
-- terminal @EventError@ into the same out-of-band 'ShikumiError' — so callers of
-- 'stream' never receive an in-band error terminal and resilience/decoding treat
-- both operations identically.
bareHandler ::
  (IOE :> es, Baikai :> es, Error ShikumiError :> es) =>
  O.LLMObserver -> LLM (Eff localEs) a -> Eff es a
bareHandler observer op = do
  cid <- liftIO freshCallId
  transportAttempt observer Nothing cid 1 op

freshCallId :: IO T.Text
freshCallId = (T.pack . ("call-" <>) . show . hashUnique) <$> newUnique

-- The callback sits outside the typed transport try; its exceptions cannot
-- become retryable provider errors, even if the callback throws BaikaiError.
transportAttempt ::
  (IOE :> es, Baikai :> es, Error ShikumiError :> es) =>
  O.LLMObserver -> Maybe Budget -> T.Text -> Int -> LLM (Eff localEs) a -> Eff es a
transportAttempt observer mb cid ordinal op = case op of
  Complete m c o -> do
    either throwError pure (validateRequestContinuation m c o)
    start <- liftIO getCurrentTime
    res <- try @BaikaiError (BE.complete m c (stripContinuationMetadata o))
    case res of
      Left be -> do
        emit m O.CompletionCall start (Just (fromBaikaiError be)) Nothing Nothing
        throwError (fromBaikaiError be)
      Right resp -> do
        liftIO (chargeBudget mb resp)
        emit
          m
          O.CompletionCall
          start
          (fromBaikaiError <$> responseError resp)
          (availableUsage (resp ^. #message . #usage))
          (O.observedModelOf (resp ^. #evidence))
        raiseResponseError resp
  Stream m c o -> do
    either throwError pure (validateRequestContinuation m c o)
    start <- liftIO getCurrentTime
    res <- try @BaikaiError (BE.streamCollect m c (stripContinuationMetadata o))
    case res of
      Left be -> do
        emit m O.StreamCall start (Just (fromBaikaiError be)) Nothing Nothing
        throwError (fromBaikaiError be)
      Right evs -> do
        liftIO (chargeBudgetFromEvents mb evs)
        let terminals = [tp | ev <- evs, tp <- case ev of EventDone t -> [t]; EventError t -> [t]; _ -> []]
            terminal = case terminals of t : _ -> Just t; [] -> Nothing
            usage = terminal >>= \t -> case t ^. #message of AssistantMessage p -> availableUsage (p ^. #usage); _ -> Nothing
            err = case [streamTerminalError t | EventError t <- evs] of e : _ -> Just e; [] -> Nothing
        emit m O.StreamCall start err usage (terminal >>= O.observedModelOf . (^. #evidence))
        raiseStreamError evs
  where
    emit m kind start err usage observed = liftIO $ do
      end <- getCurrentTime
      observer
        ( O.LLMObservation
            cid
            ordinal
            kind
            (m ^. #modelId)
            (m ^. #provider)
            observed
            (O.errorClass <$> err)
            (O.UsageRecord <$> usage)
            start
            end
        )

-- Baikai represents thrown transport errors with the additive zero. It carries
-- no observation; a reported zero has availability/basis and is retained.
availableUsage :: U.Usage -> Maybe U.Usage
availableUsage u = if u == U.zeroUsage then Nothing else Just u

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
    -- | 'Nothing' = unlimited cost. Enforcement is optimistic admission, not
    -- reservation: concurrent calls can overshoot the ceiling by up to the sum of
    -- their in-flight costs (see "Shikumi.LLM.Budget").
    budget :: !(Maybe Budget),
    -- | 'Nothing' = unbounded concurrency
    rateLimit :: !(Maybe RateLimiter),
    -- | which baikai registry to dispatch against
    registry :: !ProviderRegistry,
    -- | Optional per-attempt accounting; never charges budgets itself.
    observer :: !(Maybe O.LLMObserver)
  }

-- | A config with default retries, no budget, and no rate limit, dispatching
-- against the given registry. Set 'budget' / 'rateLimit' to opt in.
defaultLLMConfig :: ProviderRegistry -> LLMConfig
defaultLLMConfig reg =
  LLMConfig
    { retryPolicy = defaultRetryPolicy,
      budget = Nothing,
      rateLimit = Nothing,
      registry = reg,
      observer = Nothing
    }

-- | The resilient interpreter. Each operation is wrapped, outermost to
-- innermost, by: budget check → rate-limit acquire → retry loop → the @Baikai@
-- transport call. Budget admission happens once before the attempts; each
-- response or stream terminal is charged before success or failure is raised.
runLLMResilient ::
  (IOE :> es, Concurrent :> es, Error ShikumiError :> es) =>
  LLMConfig ->
  Eff (LLM : es) a ->
  Eff es a
runLLMResilient cfg = reinterpret_ (runBaikaiWith (registry cfg)) $ \op -> do
  cid <- liftIO freshCallId
  withBudget (budget cfg) . withRateLimit (rateLimit cfg) $
    retrying (retryPolicy cfg) (\ordinal -> transportAttempt (fromMaybe O.noObservation (observer cfg)) (budget cfg) cid ordinal op)

-- | Optimistic pre-call budget gate (admission, not reservation). Refuses the
-- call with 'BudgetExceeded' when the recorded running total has already reached
-- the ceiling. Because 'admitCall' holds nothing, @N@ calls admitted concurrently
-- can each pass the gate and overshoot the ceiling by up to the sum of their costs;
-- the first call after the total reaches the ceiling is refused. See
-- "Shikumi.LLM.Budget".
withBudget ::
  (IOE :> es, Error ShikumiError :> es) =>
  Maybe Budget ->
  Eff es a ->
  Eff es a
withBudget Nothing act = act
withBudget (Just b) act = do
  ok <- liftIO (admitCall b)
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
  (Int -> Eff es a) ->
  Eff es a
retrying pol act = go 1
  where
    go attempt =
      act attempt `catchError` \_cs e ->
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

-- | Raise structured terminal failures through the same mapping as blocking
-- calls. Only malformed third-party terminals without errorInfo use the legacy
-- text fallback. Successful event lists pass through unchanged.
raiseStreamError ::
  (Error ShikumiError :> es) => [AssistantMessageEvent] -> Eff es [AssistantMessageEvent]
raiseStreamError evs = case [tp | EventError tp <- evs] of
  (tp : _) -> throwError (streamTerminalError tp)
  [] -> pure evs

-- | Enforce the blocking-error posture, the 'complete' analogue of
-- 'raiseStreamError'. Since baikai 0.3, 'BE.complete' does not throw on
-- provider/registry/CLI failure: it returns an error-shaped 'Response' whose
-- 'responseError' is populated. Convert that in-band failure into the same
-- out-of-band 'ShikumiError' the rest of shikumi consumes, so an error response
-- never masquerades as success and 'runLLMResilient' still retries transient
-- failures (a classified error thrown /inside/ the retry loop). A success
-- passes through unchanged.
raiseResponseError ::
  (Error ShikumiError :> es) => Response -> Eff es Response
raiseResponseError resp = case responseError resp of
  Just be -> throwError (fromBaikaiError be)
  Nothing -> pure resp

-- | Map a terminal 'EventError' payload to a 'ShikumiError'.
streamTerminalError :: TerminalPayload -> ShikumiError
streamTerminalError tp = case tp ^. #errorInfo of
  Just err -> fromBaikaiError err
  Nothing -> ProviderFailure ("stream failed: " <> detail)
  where
    detail = case tp ^. #message of
      AssistantMessage p -> fromMaybe (T.pack (show (tp ^. #reason))) (p ^. #errorMessage)
      _ -> T.pack (show (tp ^. #reason))

-- | Charge a completed streaming call's cost, read from the terminal event's
-- assembled message. Note: an /error/ terminal ('EventError') is charged too — a
-- failed stream may still have consumed billable tokens, and the terminal
-- payload's assembled message carries the usage/cost baikai computed; not charging
-- would silently undercount real spend.
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
