-- | EP-6 Redis backend acceptance. Round-trips a @CachedResponse@ through a live
-- Redis over the @cachedLLM@ memoizer + a counting stub provider: the first
-- request is a MISS (provider called once, entry stored), a subsequent request
-- is a HIT served from Redis (no further provider call).
--
-- The test connects to the UNIX socket named by @REDIS_SOCKET@ (set by the dev
-- shell; started by @just services@). When the variable is unset or no server is
-- reachable, the suite __skips cleanly__ (prints a notice and exits 0) so CI
-- without a Redis stays green — exactly the graceful-skip the plan requires.
module Main (main) where

import Baikai (Context, Model, Options, Response, user, _Context, _Model, _Options, _Response)
import Control.Exception (SomeException, try)
import Control.Lens ((&), (.~))
import Control.Monad (void)
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.Text.Encoding qualified as TE
import Data.Vector qualified as V
import Database.Redis qualified as R
import Effectful (Eff, IOE, liftIO, runEff, type (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Shikumi.Cache (CacheKey (unCacheKey), cacheKey, cachedLLM)
import Shikumi.Cache.Backend.Redis (RedisCache, closeRedisCache, openRedisCache, runCacheRedis)
import Shikumi.Effect.Time (runTime)
import Shikumi.LLM (LLM (..), complete)
import System.Environment (lookupEnv)
import System.Exit (exitSuccess)
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

-- | A counting stub interpreter of EP-1's @LLM@: every completion bumps a
-- counter and returns a fixed response.
runCountingLLM :: (IOE :> es) => IORef Int -> Response -> Eff (LLM : es) a -> Eff es a
runCountingLLM ref resp = interpret $ \_ -> \case
  Complete {} -> liftIO (modifyIORef' ref (+ 1)) >> pure resp
  Stream {} -> pure []

main :: IO ()
main = do
  msock <- lookupEnv "REDIS_SOCKET"
  case msock of
    Nothing -> skip "REDIS_SOCKET is not set"
    Just sock -> do
      let ci = R.defaultConnectInfo {R.connectAddr = R.ConnectAddrUnixSocket sock}
      attempt <- try (openRedisCache ci) :: IO (Either SomeException RedisCache)
      case attempt of
        Left _ -> skip ("no Redis reachable at socket " <> sock)
        Right cache -> do
          clearKey ci
          defaultMain (tests cache)
          closeRedisCache cache
  where
    skip reason = do
      putStrLn ("[SKIP] shikumi-cache-redis: " <> reason)
      exitSuccess

-- | Delete any entry a previous run left for the fixed request, via a throwaway
-- connection, so the MISS→HIT counter starts honest.
clearKey :: R.ConnectInfo -> IO ()
clearKey ci = do
  conn <- R.checkedConnect ci
  void $ R.runRedis conn (R.del (redisKeyFor (cacheKey fixModel fixCtx fixOpts) :| []))
  R.disconnect conn

-- | Rebuild the backend's operational key (the backend keeps it private).
redisKeyFor :: CacheKey -> ByteString
redisKeyFor k = TE.encodeUtf8 ("shikumi:cache:" <> unCacheKey k)

tests :: RedisCache -> TestTree
tests cache =
  testGroup
    "shikumi-cache-redis"
    [ testCase "memoize: first request MISS (provider once), repeat is a Redis HIT" $ do
        -- Two identical requests in one run: provider hit exactly once.
        refA <- newIORef 0
        (r1, r2) <-
          runEff . runTime . runCacheRedis cache . runCountingLLM refA stubResponse . cachedLLM $ do
            a <- complete fixModel fixCtx fixOpts
            b <- complete fixModel fixCtx fixOpts
            pure (a, b)
        nA <- readIORef refA
        nA @?= 1
        r1 @?= r2
        -- A fresh run (fresh counter) now finds the entry already in Redis → HIT.
        refB <- newIORef 0
        _ <-
          runEff . runTime . runCacheRedis cache . runCountingLLM refB stubResponse . cachedLLM $
            complete fixModel fixCtx fixOpts
        nB <- readIORef refB
        nB @?= 0
    ]
