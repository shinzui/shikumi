-- | The in-memory cache backend (EP-6): a process-local @STM@ map from the hex
-- cache key to a 'CachedResponse'. It stores the Haskell value directly (no
-- serialization), so it needs no JSON instances for the baikai 'Response' graph.
-- Build the store with 'newMemoryCache' and discharge the 'Cache' effect with
-- 'runCacheMemory'.
module Shikumi.Cache.Backend.Memory
  ( MemoryCache,
    newMemoryCache,
    runCacheMemory,
  )
where

import Control.Concurrent.STM (TVar, atomically, modifyTVar', newTVarIO, readTVarIO)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Effectful (Eff, IOE, liftIO, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Shikumi.Cache (Cache (..), CacheKey (unCacheKey), CachedResponse)

-- | The in-memory store: a 'TVar' over a map keyed by the hex cache key.
type MemoryCache = TVar (Map Text CachedResponse)

-- | Create a fresh, empty in-memory cache.
newMemoryCache :: IO MemoryCache
newMemoryCache = newTVarIO Map.empty

-- | Discharge the 'Cache' effect against an in-memory store.
runCacheMemory :: (IOE :> es) => MemoryCache -> Eff (Cache : es) a -> Eff es a
runCacheMemory tv = interpret $ \_ -> \case
  LookupCache k -> liftIO (Map.lookup (unCacheKey k) <$> readTVarIO tv)
  StoreCache k v -> liftIO (atomically (modifyTVar' tv (Map.insert (unCacheKey k) v)))
