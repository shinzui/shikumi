-- | EP-6 Postgres backend acceptance. Round-trips a @CachedResponse@ through a
-- real PostgreSQL via the @cachedLLM@ memoizer + a counting stub provider: the
-- first request is a MISS (provider called once, row upserted), a subsequent
-- request is a HIT served from Postgres (no further provider call).
--
-- The database is a throwaway instance started by @ephemeral-pg@ (its own
-- @initdb@/@postgres@ over a private socket), so the test is hermetic and needs
-- no external server. If the cluster cannot be started (e.g. no postgres binary
-- on PATH), the suite __skips cleanly__ (prints a notice and exits 0), unless
-- @SHIKUMI_REQUIRE_BACKENDS@ is set (CI sets it), in which case the skip becomes
-- a failure.
module Main (main) where

import Baikai (Context, Model, Options, Response, user, _Context, _Model, _Options, _Response)
import Control.Exception (finally)
import Control.Lens ((&), (.~))
import Data.Generics.Labels ()
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Text qualified as T
import Data.Time.Clock (UTCTime)
import Data.Vector qualified as V
import Effectful (Eff, IOE, liftIO, runEff, type (:>))
import Effectful.Dispatch.Dynamic (interpret)
import EphemeralPg qualified as Pg
import Shikumi.Cache (CachedResponse (..), cacheKey, cachedLLM, currentKeyVersion, lookupCache, storeCache)
import Shikumi.Cache.Backend.Postgres (PostgresCache, closePostgresCache, openPostgresCache, runCachePostgres)
import Shikumi.Effect.Time (runTime)
import Shikumi.LLM (LLM (..), complete)
import System.Environment (lookupEnv)
import System.Exit (exitFailure, exitSuccess)
import System.IO (hPutStrLn, stderr)
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

fixModel :: Model
fixModel = _Model & #modelId .~ "claude-sonnet-4-6" & #provider .~ "anthropic"

fixCtx :: Context
fixCtx = _Context & #systemPrompt .~ Just "You are helpful." & #messages .~ V.singleton (user "ping")

fixOpts :: Options
fixOpts = _Options & #temperature .~ Just 0.0 & #maxTokens .~ Just 1024

stubResponse :: Response
stubResponse = _Response

someTime :: UTCTime
someTime = read "2026-06-08 00:00:00 UTC"

entry :: CachedResponse
entry = CachedResponse stubResponse someTime currentKeyVersion

-- | A counting stub interpreter of EP-1's @LLM@: every completion bumps a
-- counter and returns a fixed response.
runCountingLLM :: (IOE :> es) => IORef Int -> Response -> Eff (LLM : es) a -> Eff es a
runCountingLLM ref resp = interpret $ \_ -> \case
  Complete {} -> liftIO (modifyIORef' ref (+ 1)) >> pure resp
  Stream {} -> pure []

main :: IO ()
main = do
  started <- Pg.start Pg.defaultConfig
  case started of
    Left err -> skip (T.unpack (Pg.renderStartError err))
    Right db -> do
      cache <- openPostgresCache (Pg.connectionSettings db)
      defaultMain (tests (openPostgresCache (Pg.connectionSettings db)) cache)
        `finally` (closePostgresCache cache >> Pg.stop db)
  where
    skip reason = do
      required <- lookupEnv "SHIKUMI_REQUIRE_BACKENDS"
      if maybe False (`notElem` ["", "0"]) required
        then do
          hPutStrLn stderr ("[FAIL] shikumi-cache-postgres: SHIKUMI_REQUIRE_BACKENDS is set but ephemeral-pg failed to start: " <> reason)
          exitFailure
        else do
          let banner = replicate 72 '='
          mapM_
            putStrLn
            [ banner,
              "== SKIPPED: shikumi-cache-postgres test suite ran ZERO tests",
              "== reason: " <> reason,
              "== to run for real: the dev shell provides the postgres binaries ephemeral-pg needs",
              "== CI enforcement of this skip is owned by docs/masterplans/9-ci-and-shared-test-infrastructure.md",
              banner
            ]
          exitSuccess

-- Keep a reference to `cacheKey` so the import is exercised even though the
-- backend computes keys internally (documents the integration-point-#7 reuse).
tests :: IO PostgresCache -> PostgresCache -> TestTree
tests openCache cache =
  let _key = cacheKey fixModel fixCtx fixOpts
   in testGroup
        "shikumi-cache-postgres"
        [ testCase "memoize: first request MISS (provider once), repeat is a Postgres HIT" $ do
            refA <- newIORef 0
            (r1, r2) <-
              runEff . runTime . runCachePostgres cache . runCountingLLM refA stubResponse . cachedLLM $ do
                a <- complete fixModel fixCtx fixOpts
                b <- complete fixModel fixCtx fixOpts
                pure (a, b)
            nA <- readIORef refA
            nA @?= 1
            r1 @?= r2
            -- A fresh run (fresh counter) now finds the row already in Postgres → HIT.
            refB <- newIORef 0
            _ <-
              runEff . runTime . runCachePostgres cache . runCountingLLM refB stubResponse . cachedLLM $
                complete fixModel fixCtx fixOpts
            nB <- readIORef refB
            nB @?= 0,
          testCase "a released connection degrades to MISS / no-op" $ do
            closed <- openCache
            closePostgresCache closed
            got <- runEff . runCachePostgres closed $ lookupCache (cacheKey fixModel fixCtx fixOpts)
            got @?= Nothing
            runEff . runCachePostgres closed $
              storeCache (cacheKey fixModel fixCtx fixOpts) entry
        ]
