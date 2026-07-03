-- | The Redis cache backend (EP-6) — a server-backed, cross-machine store.
--
-- Unlike the in-memory (process-local) and SQLite (single-file) backends, a
-- Redis-backed cache is shared by every process that can reach the server, so a
-- response computed on one machine is served to another. Entries live under the
-- string key @shikumi:cache:\<hex\>@ (the @shikumi:cache:@ prefix is operational
-- namespacing, outside the content hash). By default entries have no Redis-side
-- expiry; callers that want Redis to bound storage can opt into @SETEX@ with
-- 'openRedisCacheWithTTL'. The value is the UTF-8 JSON of a 'CachedResponse';
-- the baikai 'Baikai.Response.Response' round-trip is the one from
-- @shikumi-cache@ ("Shikumi.Cache.ResponseJSON").
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
import Shikumi.Cache.Backend.Effort (bestEffortIO)

-- | An open Redis-backed cache: a connection plus an optional server-side TTL
-- (seconds) applied to stored entries.
data RedisCache = RedisCache
  { conn :: !R.Connection,
    ttl :: !(Maybe Integer)
  }

-- | The historical Redis storage TTL: 7 days (in seconds). It is no longer
-- applied by default; pass it to 'openRedisCacheWithTTL' to restore the old
-- Redis-side expiry behavior.
defaultRedisTTL :: Integer
defaultRedisTTL = 7 * 24 * 60 * 60

-- | Connect to Redis (verifying the connection eagerly via @checkedConnect@)
-- with no Redis-side expiry. Throws 'R.ConnectError' if the server is
-- unreachable.
openRedisCache :: R.ConnectInfo -> IO RedisCache
openRedisCache ci = do
  conn <- R.checkedConnect ci
  pure (RedisCache conn Nothing)

-- | As 'openRedisCache' but with an explicit Redis-side per-entry TTL (seconds).
-- This bounds Redis storage independently of the policy-layer 'CacheConfig'
-- expiry in @shikumi-cache@.
openRedisCacheWithTTL :: Integer -> R.ConnectInfo -> IO RedisCache
openRedisCacheWithTTL ttl ci = do
  conn <- R.checkedConnect ci
  pure (RedisCache conn (Just ttl))

-- | Close the Redis connection.
closeRedisCache :: RedisCache -> IO ()
closeRedisCache = R.disconnect . conn

-- | The operational Redis key for a content-addressed 'CacheKey'.
redisKey :: CacheKey -> ByteString
redisKey k = TE.encodeUtf8 ("shikumi:cache:" <> unCacheKey k)

-- | Discharge the 'Cache' effect against Redis. A missing key, a Redis-level
-- error, thrown connection failure, or JSON decode failure all surface as a
-- cache MISS ('Nothing'), so a transient hiccup or stale-schema value is simply
-- re-fetched. Store failures are swallowed for the same best-effort posture.
runCacheRedis :: (IOE :> es) => RedisCache -> Eff (Cache : es) a -> Eff es a
runCacheRedis cache = interpret $ \_ -> \case
  LookupCache k -> liftIO . bestEffortIO Nothing $ do
    r <- R.runRedis (conn cache) (R.get (redisKey k))
    pure $ case r of
      Right (Just bs) -> decodeStrict' bs
      _ -> Nothing
  StoreCache k v -> liftIO . bestEffortIO () $ do
    let bytes = BL.toStrict (encode v)
    _ <-
      R.runRedis (conn cache) $
        case ttl cache of
          Just seconds -> () <$ R.setex (redisKey k) seconds bytes
          Nothing -> () <$ R.set (redisKey k) bytes
    pure ()
