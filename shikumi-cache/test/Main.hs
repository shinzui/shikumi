-- | EP-6 acceptance: the content-addressed cache key (integration point #7,
-- golden-pinned), the in-memory backend round-trip, the SQLite backend
-- round-trip and cross-process restart durability, the @cachedLLM@ memoizer (the
-- headline one-provider-call behaviour) via a counting stub, and
-- versioning/invalidation. The server-backed Redis/Postgres backends are tested
-- in their own packages (@shikumi-cache-redis@/@shikumi-cache-postgres@).
--
-- The SQLite restart test re-executes this binary as a subprocess in a "write"
-- and a "read" phase against the same temp file (selected by the
-- @SHIKUMI_SQLITE_PHASE@ / @SHIKUMI_SQLITE_FILE@ env vars), proving the entry
-- survives on disk across OS processes — not merely across handles in one
-- process.
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
import Shikumi.Cache.Backend.SQLite (runCacheSQLite, withSQLiteCache)
import Shikumi.Cache.Key (canonicalJSON, requestToCanonicalValueVersioned)
import Shikumi.LLM (LLM (..), complete)
import System.Environment (getEnvironment, getExecutablePath, lookupEnv)
import System.Exit (ExitCode (ExitSuccess), exitFailure, exitSuccess)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (CreateProcess (env), proc, readCreateProcessWithExitCode)
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

-- | The fixed key/entry the SQLite restart test writes and reads back. Both the
-- write and read subprocess phases derive them identically from the fixtures.
restartKey :: CacheKey
restartKey = cacheKey fixModel fixCtx fixOpts

restartEntry :: CachedResponse
restartEntry = CachedResponse stubResponse someTime currentKeyVersion

main :: IO ()
main = do
  -- The SQLite restart test re-executes this binary with SHIKUMI_SQLITE_PHASE
  -- set, so a "write" then a "read" run hit the same on-disk file as distinct
  -- OS processes. These short-circuit before tasty runs.
  phase <- lookupEnv "SHIKUMI_SQLITE_PHASE"
  case phase of
    Just "write" -> sqliteWritePhase
    Just "read" -> sqliteReadPhase
    _ ->
      defaultMain $
        testGroup
          "shikumi-cache"
          [ keyTests,
            memoryTests,
            sqliteTests,
            memoizeTests,
            versioningTests
          ]

-- | Subprocess phase: store the fixed entry into the SQLite file named by
-- @SHIKUMI_SQLITE_FILE@, then exit. Nothing lingers in this process's memory.
sqliteWritePhase :: IO ()
sqliteWritePhase = do
  file <- requireEnv "SHIKUMI_SQLITE_FILE"
  withSQLiteCache file $ \c ->
    runEff . runCacheSQLite c $ storeCache restartKey restartEntry
  exitSuccess

-- | Subprocess phase: open the same file fresh and read the entry back; exit 0
-- iff it decodes to exactly the written entry.
sqliteReadPhase :: IO ()
sqliteReadPhase = do
  file <- requireEnv "SHIKUMI_SQLITE_FILE"
  got <- withSQLiteCache file $ \c -> runEff . runCacheSQLite c $ lookupCache restartKey
  if got == Just restartEntry then exitSuccess else exitFailure

requireEnv :: String -> IO String
requireEnv name =
  lookupEnv name >>= maybe (error ("missing env var: " <> name)) pure

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

sqliteTests :: TestTree
sqliteTests =
  testGroup
    "sqlite"
    [ testCase "store-then-lookup round-trips a CachedResponse" $
        withSystemTempDirectory "shikumi-sqlite" $ \dir -> do
          let file = dir </> "cache.db"
          got <-
            withSQLiteCache file $ \c ->
              runEff . runCacheSQLite c $ (storeCache restartKey restartEntry >> lookupCache restartKey)
          got @?= Just restartEntry,
      testCase "an absent key returns Nothing" $
        withSystemTempDirectory "shikumi-sqlite" $ \dir -> do
          let file = dir </> "cache.db"
          got <- withSQLiteCache file $ \c -> runEff . runCacheSQLite c $ lookupCache (CacheKey "deadbeef")
          got @?= Nothing,
      testCase "restart: an entry written by one OS process is read by another from disk" $
        withSystemTempDirectory "shikumi-sqlite" $ \dir -> do
          let file = dir </> "restart.db"
          exe <- getExecutablePath
          baseEnv <- getEnvironment
          let runPhase ph =
                readCreateProcessWithExitCode
                  (proc exe []) {env = Just (baseEnv ++ [("SHIKUMI_SQLITE_PHASE", ph), ("SHIKUMI_SQLITE_FILE", file)])}
                  ""
          (wc, _, werr) <- runPhase "write"
          assertBool ("write phase failed: " <> werr) (wc == ExitSuccess)
          (rc, _, rerr) <- runPhase "read"
          assertBool ("read phase did not find the on-disk entry: " <> rerr) (rc == ExitSuccess)
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
