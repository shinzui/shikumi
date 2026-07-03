-- | The resilience interpreter's observable behaviors: transient failures are
-- retried with backoff until success or exhaustion; non-transient failures are
-- not retried; a budget refuses the call that would cross the ceiling; and a
-- rate limit caps in-flight calls.
module ResilienceSpec (tests) where

import Baikai (AssistantMessageEvent (..), flattenAssistantBlocks)
import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM (newTVarIO, readTVarIO)
import Data.IORef (newIORef, readIORef)
import Data.Ratio ((%))
import Effectful (runEff)
import Effectful.Concurrent (runConcurrent)
import Effectful.Concurrent.Async (mapConcurrently)
import Effectful.Error.Static (runErrorNoCallStack)
import Shikumi.Error (ShikumiError (..))
import Shikumi.LLM
  ( LLMConfig (..),
    RetryPolicy (..),
    complete,
    defaultLLMConfig,
    newRateLimiter,
    runLLMResilient,
    stream,
  )
import Shikumi.LLM.Budget (newBudget, spentUSD)
import StubProvider
  ( budgetBarrierStubRegistry,
    concurrencyStubRegistry,
    costStubRegistry,
    failingStreamCostStubRegistry,
    failingStreamStubRegistry,
    failingStubRegistry,
    flattenAssistantText,
    invalidStubRegistry,
    stubContext,
    stubModel,
    stubOptions,
  )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "ResilienceSpec"
    [ testCase "retry recovers after 2 failures" $ do
        ref <- newIORef 0
        reg <- failingStubRegistry ref 2 "ok"
        let cfg = (defaultLLMConfig reg) {retryPolicy = RetryPolicy 3 1 5}
        res <- runText cfg
        res @?= Right "ok"
        n <- readIORef ref
        n @?= 3,
      testCase "retry exhausts after maxAttempts" $ do
        ref <- newIORef 0
        reg <- failingStubRegistry ref 2 "ok"
        let cfg = (defaultLLMConfig reg) {retryPolicy = RetryPolicy 2 1 5}
        res <- runText cfg
        case res of
          Left (ProviderFailure _) -> pure ()
          other -> assertFailure ("expected Left (ProviderFailure ...), got " <> show other)
        n <- readIORef ref
        n @?= 2,
      testCase "non-transient error not retried" $ do
        ref <- newIORef 0
        reg <- invalidStubRegistry ref
        let cfg = (defaultLLMConfig reg) {retryPolicy = RetryPolicy 5 1 5}
        res <- runText cfg
        case res of
          Left (SchemaMismatch _) -> pure ()
          other -> assertFailure ("expected Left (SchemaMismatch ...), got " <> show other)
        n <- readIORef ref
        n @?= 1,
      testCase "budget refuses the second call" $ do
        reg <- costStubRegistry (1 % 100) "ok"
        b <- newBudget (Just (1 % 100))
        let cfg = (defaultLLMConfig reg) {budget = Just b}
        res1 <- runText cfg
        res1 @?= Right "ok"
        res2 <- runText cfg
        case res2 of
          Left (BudgetExceeded _) -> pure ()
          other -> assertFailure ("expected Left (BudgetExceeded ...), got " <> show other),
      testCase "EP-35: budget admission is optimistic — N concurrent calls overshoot the ceiling" $ do
        -- The barrier stub keeps all four calls in flight (each already past
        -- admitCall) until none has recorded its cost, pinning the documented
        -- overshoot: admission is not reservation.
        arrived <- newTVarIO 0
        reg <- budgetBarrierStubRegistry arrived 4 (1 % 100) "ok"
        b <- newBudget (Just (1 % 100)) -- ceiling = a single call's cost
        let cfg = (defaultLLMConfig reg) {budget = Just b}
        results <-
          runEff . runConcurrent . runErrorNoCallStack @ShikumiError . runLLMResilient cfg $
            mapConcurrently (const (complete stubModel stubContext stubOptions)) [1 .. 4 :: Int]
        case results of
          Right rs -> length rs @?= 4 -- all four admitted together (overshoot)
          other -> assertFailure ("expected all four concurrent calls to succeed, got " <> show other)
        spent <- spentUSD b
        assertBool "total overshot the ceiling" (spent > (1 % 100))
        -- the ceiling is now consumed; a subsequent call is refused
        res5 <- runText cfg
        case res5 of
          Left (BudgetExceeded _) -> pure ()
          other -> assertFailure ("expected Left (BudgetExceeded ...) once the ceiling is consumed, got " <> show other),
      testCase "rate limit caps concurrency at 1" $ do
        cur <- newTVarIO 0
        mx <- newTVarIO 0
        reg <- concurrencyStubRegistry cur mx "ok"
        rl <- newRateLimiter 1
        let cfg = (defaultLLMConfig reg) {rateLimit = Just rl}
        v1 <- newEmptyMVar
        v2 <- newEmptyMVar
        _ <- forkIO (runText cfg >>= putMVar v1)
        _ <- forkIO (runText cfg >>= putMVar v2)
        r1 <- takeMVar v1
        r2 <- takeMVar v2
        r1 @?= Right "ok"
        r2 @?= Right "ok"
        observedMax <- readTVarIO mx
        assertBool ("observed max concurrency " <> show observedMax <> " should be <= 1") (observedMax <= 1),
      testCase "EP-34: stream retry recovers after 2 failures" $ do
        -- A stream that fails twice (terminal EventError) then succeeds. The
        -- interpreter now raises the in-band error out-of-band, so retrying fires.
        ref <- newIORef 0
        reg <- failingStreamStubRegistry ref 2 "ok"
        let cfg = (defaultLLMConfig reg) {retryPolicy = RetryPolicy 3 1 5}
        res <- runStream cfg
        case res of
          Right evs -> assertBool "successful stream ends with EventDone" (any isEventDone evs)
          other -> assertFailure ("expected Right events, got " <> show other)
        n <- readIORef ref
        n @?= 3,
      testCase "EP-34: a permanently failing stream surfaces a transient ProviderFailure" $ do
        ref <- newIORef 0
        reg <- failingStreamStubRegistry ref 5 "ok" -- more failures than attempts
        let cfg = (defaultLLMConfig reg) {retryPolicy = RetryPolicy 3 1 5}
        res <- runStream cfg
        case res of
          Left (ProviderFailure _) -> pure ()
          other -> assertFailure ("expected Left (ProviderFailure ...), got " <> show other)
        n <- readIORef ref
        n @?= 3, -- retried up to maxAttempts
      testCase "EP-34: a failed stream still charges the budget (charge precedes the throw)" $ do
        -- First call: budget gate passes, stream fails after charging its cost, so
        -- the failure surfaces AND the cost is recorded. Second call: the gate now
        -- refuses because the first (failed) call already consumed the ceiling.
        reg <- failingStreamCostStubRegistry (1 % 100)
        b <- newBudget (Just (1 % 100))
        let cfg = (defaultLLMConfig reg) {budget = Just b, retryPolicy = RetryPolicy 1 1 5}
        res1 <- runStream cfg
        case res1 of
          Left (ProviderFailure _) -> pure ()
          other -> assertFailure ("expected Left (ProviderFailure ...), got " <> show other)
        res2 <- runStream cfg
        case res2 of
          Left (BudgetExceeded _) -> pure ()
          other -> assertFailure ("expected Left (BudgetExceeded ...) after the failed call charged, got " <> show other)
    ]
  where
    runText cfg =
      runEff . runConcurrent . runErrorNoCallStack @ShikumiError . runLLMResilient cfg $ do
        r <- complete stubModel stubContext stubOptions
        pure (flattenAssistantText (flattenAssistantBlocks r))
    runStream cfg =
      runEff . runConcurrent . runErrorNoCallStack @ShikumiError . runLLMResilient cfg $
        stream stubModel stubContext stubOptions
    isEventDone = \case EventDone _ -> True; _ -> False
