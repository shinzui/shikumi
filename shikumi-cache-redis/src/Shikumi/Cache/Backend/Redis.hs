-- | The Redis cache backend (EP-6) — a server-backed, cross-machine store.
--
-- Unlike the in-memory (process-local) and SQLite (single-file) backends, a
-- Redis-backed cache is shared by every process that can reach the server, so a
-- response computed on one machine is served to another. Entries live under the
-- string key @shikumi:cache:\<hex\>@ (the @shikumi:cache:@ prefix is operational
-- namespacing, outside the content hash) and are written with @SETEX@ so Redis
-- evicts stale entries after a configurable TTL. The value is the UTF-8 JSON of
-- a 'CachedResponse'; the baikai 'Baikai.Response.Response' round-trip is the one
-- from @shikumi-cache@ ("Shikumi.Cache.ResponseJSON").
module Shikumi.Cache.Backend.Redis
  ( RedisCache,
    defaultRedisTTL,
    openRedisCache,
    openRedisCacheWithTTL,
    closeRedisCache,
    runCacheRedis,
  )
where

import Data.Aeson (decodeStrict', encode)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as BL
import Data.Text.Encoding qualified as TE
import Database.Redis qualified as R
import Effectful (Eff, IOE, liftIO, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Shikumi.Cache (Cache (..), CacheKey (unCacheKey))

-- | An open Redis-backed cache: a connection plus the TTL (seconds) applied to
-- every stored entry.
data RedisCache = RedisCache
  { redisConn :: !R.Connection,
    redisTTL :: !Integer
  }

-- | The default entry TTL: 7 days (in seconds).
defaultRedisTTL :: Integer
defaultRedisTTL = 7 * 24 * 60 * 60

-- | Connect to Redis (verifying the connection eagerly via @checkedConnect@) with
-- the 'defaultRedisTTL'. Throws 'R.ConnectError' if the server is unreachable.
openRedisCache :: R.ConnectInfo -> IO RedisCache
openRedisCache = openRedisCacheWithTTL defaultRedisTTL

-- | As 'openRedisCache' but with an explicit per-entry TTL (seconds).
openRedisCacheWithTTL :: Integer -> R.ConnectInfo -> IO RedisCache
openRedisCacheWithTTL ttl ci = do
  conn <- R.checkedConnect ci
  pure (RedisCache conn ttl)

-- | Close the Redis connection.
closeRedisCache :: RedisCache -> IO ()
closeRedisCache = R.disconnect . redisConn

-- | The operational Redis key for a content-addressed 'CacheKey'.
redisKey :: CacheKey -> ByteString
redisKey k = TE.encodeUtf8 ("shikumi:cache:" <> unCacheKey k)

-- | Discharge the 'Cache' effect against Redis. A missing key, a Redis-level
-- error, or a JSON decode failure all surface as a cache MISS ('Nothing'), so a
-- transient hiccup or a stale-schema value is simply re-fetched.
runCacheRedis :: (IOE :> es) => RedisCache -> Eff (Cache : es) a -> Eff es a
runCacheRedis cache = interpret $ \_ -> \case
  LookupCache k -> liftIO $ do
    r <- R.runRedis (redisConn cache) (R.get (redisKey k))
    pure $ case r of
      Right (Just bs) -> decodeStrict' bs
      _ -> Nothing
  StoreCache k v -> liftIO $ do
    _ <- R.runRedis (redisConn cache) (R.setex (redisKey k) (redisTTL cache) (BL.toStrict (encode v)))
    pure ()
