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
    cachedLLM,

    -- * Re-exports
    CacheKey (..),
    cacheKey,
    currentKeyVersion,
    CachedResponse (..),
  )
where

import Data.Time.Clock (getCurrentTime)
import Effectful (Dispatch (Dynamic), DispatchOf, Eff, Effect, IOE, liftIO, (:>))
import Effectful.Dispatch.Dynamic (interpose, passthrough, send)
import Shikumi.Cache.Key (CacheKey (..), cacheKey, currentKeyVersion)
import Shikumi.Cache.Types (CachedResponse (..))
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

-- | Memoize EP-1's @LLM@ @complete@ through the 'Cache' effect: on a HIT (a key
-- present whose 'keyVersion' matches the live namespace) return the stored
-- response without contacting the provider; on a MISS delegate to the underlying
-- @LLM@ handler, store the result, and return it. A stale-version entry is
-- treated as a MISS (it is overwritten on re-fetch). The streaming op is passed
-- through unchanged — streams are not cached.
cachedLLM ::
  (Cache :> es, LLM :> es, IOE :> es) =>
  Eff es a ->
  Eff es a
cachedLLM = interpose $ \env -> \case
  Complete model ctx opts -> do
    let key = cacheKey model ctx opts
    hit <- lookupCache key
    case hit of
      Just cr | keyVersion cr == currentKeyVersion -> pure (response cr)
      _ -> do
        resp <- complete model ctx opts
        now <- liftIO getCurrentTime
        storeCache key (CachedResponse resp now currentKeyVersion)
        pure resp
  other -> passthrough env other
