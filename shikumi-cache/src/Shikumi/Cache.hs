{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}

-- | The cache storage effect and the memoizing interpreter (EP-6).
--
-- 'Cache' is a small @effectful@ dynamic effect with two operations —
-- 'lookupCache' and 'storeCache' — interpreted by a backend (memory, SQLite, …).
-- The /policy/ is separate: 'cachedLLM' re-interprets EP-1's @LLM@ effect so that
-- 'Shikumi.LLM.complete' is memoized — identical requests contact the provider
-- once. Keeping mechanism (storage) and policy (when to read/write) apart lets a
-- caller use the store directly, or compose the memoizer, independently.
module Shikumi.Cache
  ( -- * The storage effect
    Cache (..),
    lookupCache,
    storeCache,

    -- * The memoizing policy
    CacheConfig (..),
    defaultCacheConfig,
    cachedLLM,
    cachedLLMWith,

    -- * Re-exports
    CacheKey (..),
    cacheKey,
    currentKeyVersion,
    CachedResponse (..),
  )
where

import Baikai (Response, StopReason (ErrorReason))
import Control.Lens ((^.))
import Control.Monad (when)
import Data.Generics.Labels ()
import Data.Maybe (isNothing)
import Data.Time.Clock (NominalDiffTime, diffUTCTime)
import Effectful (Dispatch (Dynamic), DispatchOf, Eff, Effect, (:>))
import Effectful.Dispatch.Dynamic (interpose, passthrough, send)
import GHC.Generics (Generic)
import Shikumi.Cache.Key (CacheKey (..), cacheKey, currentKeyVersion)
import Shikumi.Cache.Types (CachedResponse (..))
import Shikumi.Effect.Time (Time, getCurrentTime)
import Shikumi.LLM (LLM (..), complete)

-- | The cache storage effect: look an entry up by key, or store one.
data Cache :: Effect where
  LookupCache :: CacheKey -> Cache m (Maybe CachedResponse)
  StoreCache :: CacheKey -> CachedResponse -> Cache m ()

type instance DispatchOf Cache = 'Dynamic

-- | Look up a cached response by key (a backend MISS is 'Nothing').
lookupCache :: (Cache :> es) => CacheKey -> Eff es (Maybe CachedResponse)
lookupCache = send . LookupCache

-- | Store a cached response under a key (idempotent upsert at every backend).
storeCache :: (Cache :> es) => CacheKey -> CachedResponse -> Eff es ()
storeCache k v = send (StoreCache k v)

-- | Policy knobs for 'cachedLLMWith', shared by every backend.
--
-- 'entryTTL' is the maximum age of a usable entry, measured against
-- 'CachedResponse.storedAt' at lookup time. 'Nothing' (the default) means
-- entries never expire, which is the uniform default across Memory, SQLite,
-- Redis, and Postgres. Expiry is enforced here, at the policy layer, so it
-- behaves identically no matter which backend interprets the 'Cache' effect; an
-- expired entry is treated as a MISS and overwritten by the fresh response.
newtype CacheConfig = CacheConfig
  { entryTTL :: Maybe NominalDiffTime
  }
  deriving stock (Eq, Show, Generic)

-- | No expiry.
defaultCacheConfig :: CacheConfig
defaultCacheConfig = CacheConfig {entryTTL = Nothing}

-- | Memoize EP-1's @LLM@ @complete@ through the 'Cache' effect: on a HIT (a key
-- present whose 'keyVersion' matches the live namespace and whose age satisfies
-- 'defaultCacheConfig') return the stored response without contacting the
-- provider; on a MISS delegate to the underlying @LLM@ handler, store the
-- result if it is successful, and return it. Cache backends are best-effort:
-- lookup failures are MISSes and store failures are no-ops. Entries never
-- expire unless 'entryTTL' is set via 'cachedLLMWith'. In-band error responses
-- are never cached. Under concurrent identical requests both callers may miss
-- and call the provider; this accepted check-then-act race is harmless because
-- stores are idempotent upserts keyed by content. The streaming op is passed
-- through unchanged — streams are not cached.
cachedLLM ::
  (Cache :> es, LLM :> es, Time :> es) =>
  Eff es a ->
  Eff es a
cachedLLM = cachedLLMWith defaultCacheConfig

-- | A configured variant of 'cachedLLM'. See 'CacheConfig' for the shared TTL
-- policy.
cachedLLMWith ::
  (Cache :> es, LLM :> es, Time :> es) =>
  CacheConfig ->
  Eff es a ->
  Eff es a
cachedLLMWith cfg = interpose $ \env -> \case
  Complete model ctx opts -> do
    let key = cacheKey model ctx opts
    hit <- lookupCache key
    now <- getCurrentTime
    case hit of
      Just cr
        | keyVersion cr == currentKeyVersion,
          fresh (entryTTL cfg) now (storedAt cr) ->
            pure (response cr)
      _ -> do
        resp <- complete model ctx opts
        stored <- getCurrentTime
        when (cacheable resp) $
          storeCache key (CachedResponse resp stored currentKeyVersion)
        pure resp
  other -> passthrough env other
  where
    fresh Nothing _ _ = True
    fresh (Just ttl) now written = diffUTCTime now written <= ttl

-- | Only successful responses are memoized. An in-band error response reports a
-- transient provider failure; caching it would replay the outage as the
-- permanent answer.
cacheable :: Response -> Bool
cacheable resp =
  (resp ^. #message . #stopReason) /= ErrorReason
    && isNothing (resp ^. #errorInfo)
