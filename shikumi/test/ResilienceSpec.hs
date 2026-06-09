-- | The resilience interpreter's observable behaviors: transient failures are
-- retried with backoff until success or exhaustion; non-transient failures are
-- not retried; a budget refuses the call that would cross the ceiling; and a
-- rate limit caps in-flight calls.
module ResilienceSpec (tests) where

import Baikai (flattenAssistantBlocks)
import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM (newTVarIO, readTVarIO)
import Data.IORef (newIORef, readIORef)
import Data.Ratio ((%))
import Effectful (runEff)
import Effectful.Error.Static (runErrorNoCallStack)
import Shikumi.Error (ShikumiError (..))
import Shikumi.LLM
  ( LLMConfig (..),
    RetryPolicy (..),
    complete,
    defaultLLMConfig,
    newRateLimiter,
    runLLMResilient,
  )
import Shikumi.LLM.Budget (newBudget)
import StubProvider
  ( concurrencyStubRegistry,
    costStubRegistry,
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
        assertBool ("observed max concurrency " <> show observedMax <> " should be <= 1") (observedMax <= 1)
    ]
  where
    runText cfg =
      runEff . runErrorNoCallStack @ShikumiError . runLLMResilient cfg $ do
        r <- complete stubModel stubContext stubOptions
        pure (flattenAssistantText (flattenAssistantBlocks r))
