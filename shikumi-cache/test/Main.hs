-- | EP-6 acceptance (hermetic core): the content-addressed cache key (integration
-- point #7, golden-pinned), the in-memory backend round-trip, the @cachedLLM@
-- memoizer (the headline one-provider-call behaviour) via a counting stub, and
-- versioning/invalidation. The persistent backends (SQLite/Redis/Postgres) are
-- separate milestones — see the plan.
module Main (main) where

import Baikai (Context, Model, Options, Response, user, _Context, _Model, _Options, _Response)
import Control.Lens ((&), (.~))
import Data.Generics.Labels ()
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Text qualified as T
import Data.Time.Clock (UTCTime)
import Data.Vector qualified as V
import Effectful (Eff, IOE, liftIO, runEff, type (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Shikumi.Cache
  ( CacheKey (..),
    CachedResponse (..),
    cacheKey,
    cachedLLM,
    currentKeyVersion,
    lookupCache,
    storeCache,
  )
import Shikumi.Cache.Backend.Memory (newMemoryCache, runCacheMemory)
import Shikumi.Cache.Key (canonicalJSON, requestToCanonicalValueVersioned)
import Shikumi.LLM (LLM (..), complete)
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------

fixModel :: Model
fixModel = _Model & #modelId .~ "claude-sonnet-4-6" & #provider .~ "anthropic"

fixCtx :: Context
fixCtx =
  _Context
    & #systemPrompt .~ Just "You are helpful."
    & #messages .~ V.singleton (user "ping")

fixOpts :: Options
fixOpts = _Options & #temperature .~ Just 0.0 & #maxTokens .~ Just 1024

-- | The pinned cache key for @(fixModel, fixCtx, fixOpts)@ — the value EP-7 must
-- reproduce. Captured from a first run; any drift in field set, canonical JSON,
-- or hash breaks this test.
pinnedKey :: T.Text
pinnedKey = "30b2015562ec8b5cd4fdb64c7cc671c84f56f80d24891deec6676c521f008113"

stubResponse :: Response
stubResponse = _Response

someTime :: UTCTime
someTime = read "2026-06-08 00:00:00 UTC"

-- | A counting stub interpreter of EP-1's @LLM@: every completion bumps the
-- counter and returns a fixed response. (The streaming op is unused.)
runCountingLLM :: (IOE :> es) => IORef Int -> Response -> Eff (LLM : es) a -> Eff es a
runCountingLLM ref resp = interpret $ \_ -> \case
  Complete {} -> liftIO (modifyIORef' ref (+ 1)) >> pure resp
  Stream {} -> pure []

-- ---------------------------------------------------------------------------
-- Tests
-- ---------------------------------------------------------------------------

main :: IO ()
main =
  defaultMain $
    testGroup
      "shikumi-cache"
      [ keyTests,
        memoryTests,
        memoizeTests,
        versioningTests
      ]

keyTests :: TestTree
keyTests =
  testGroup
    "cache key"
    [ testCase "is a 64-char lowercase hex digest" $ do
        let CacheKey hex = cacheKey fixModel fixCtx fixOpts
        T.length hex @?= 64
        assertBool "all lowercase hex" (T.all (`elem` ("0123456789abcdef" :: String)) hex),
      testCase "is deterministic" $
        cacheKey fixModel fixCtx fixOpts @?= cacheKey fixModel fixCtx fixOpts,
      testCase "matches the pinned digest (the contract EP-7 reproduces)" $ do
        let CacheKey hex = cacheKey fixModel fixCtx fixOpts
        hex @?= pinnedKey,
      testCase "a different request yields a different key" $
        assertBool
          "temperature change must change the key"
          (cacheKey fixModel fixCtx fixOpts /= cacheKey fixModel fixCtx (fixOpts & #temperature .~ Just 0.7))
    ]

memoryTests :: TestTree
memoryTests =
  testGroup
    "memory backend"
    [ testCase "store-then-lookup returns the entry" $ do
        tv <- newMemoryCache
        let key = cacheKey fixModel fixCtx fixOpts
            entry = CachedResponse stubResponse someTime currentKeyVersion
        got <- runEff . runCacheMemory tv $ (storeCache key entry >> lookupCache key)
        got @?= Just entry,
      testCase "an absent key returns Nothing" $ do
        tv <- newMemoryCache
        got <- runEff . runCacheMemory tv $ lookupCache (CacheKey "deadbeef")
        got @?= Nothing
    ]

memoizeTests :: TestTree
memoizeTests =
  testGroup
    "memoize"
    [ testCase "same request twice contacts the provider once with equal outputs" $ do
        tv <- newMemoryCache
        ref <- newIORef 0
        (r1, r2) <-
          runEff . runCacheMemory tv . runCountingLLM ref stubResponse . cachedLLM $ do
            a <- complete fixModel fixCtx fixOpts
            b <- complete fixModel fixCtx fixOpts
            pure (a, b)
        n <- readIORef ref
        n @?= 1
        r1 @?= r2,
      testCase "two different requests contact the provider twice" $ do
        tv <- newMemoryCache
        ref <- newIORef 0
        _ <-
          runEff . runCacheMemory tv . runCountingLLM ref stubResponse . cachedLLM $ do
            _ <- complete fixModel fixCtx fixOpts
            complete fixModel fixCtx (fixOpts & #temperature .~ Just 0.7)
        n <- readIORef ref
        n @?= 2
    ]

versioningTests :: TestTree
versioningTests =
  testGroup
    "versioning"
    [ testCase "a current-version entry is a HIT (no provider call)" $ do
        tv <- newMemoryCache
        ref <- newIORef 0
        let key = cacheKey fixModel fixCtx fixOpts
        runEff . runCacheMemory tv $ storeCache key (CachedResponse stubResponse someTime currentKeyVersion)
        _ <- runEff . runCacheMemory tv . runCountingLLM ref stubResponse . cachedLLM $ complete fixModel fixCtx fixOpts
        n <- readIORef ref
        n @?= 0,
      testCase "an entry with a foreign keyVersion is ignored (MISS, provider called)" $ do
        tv <- newMemoryCache
        ref <- newIORef 0
        let key = cacheKey fixModel fixCtx fixOpts
        runEff . runCacheMemory tv $ storeCache key (CachedResponse stubResponse someTime "shikumi-cache/v0")
        _ <- runEff . runCacheMemory tv . runCountingLLM ref stubResponse . cachedLLM $ complete fixModel fixCtx fixOpts
        n <- readIORef ref
        n @?= 1,
      testCase "bumping the namespace version changes the hashed bytes" $
        assertBool
          "v1 and v2 canonical serializations must differ"
          ( canonicalJSON (requestToCanonicalValueVersioned "shikumi-cache/v1" fixModel fixCtx fixOpts)
              /= canonicalJSON (requestToCanonicalValueVersioned "shikumi-cache/v2" fixModel fixCtx fixOpts)
          )
    ]
