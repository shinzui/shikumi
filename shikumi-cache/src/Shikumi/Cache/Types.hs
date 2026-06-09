-- | The value stored in the cache (EP-6): a full provider 'Response' plus the
-- operational metadata needed to age and version-guard an entry.
--
-- The in-memory backend stores this Haskell value directly (no serialization).
-- The persistent backends (SQLite/Redis/Postgres) store its JSON encoding; the
-- @ToJSON@/@FromJSON@ for the baikai 'Response' graph that baikai itself does not
-- ship in full come from "Shikumi.Cache.ResponseJSON" (imported here for their
-- instances). Decoding an entry whose 'keyVersion' does not match the live
-- namespace is treated as a cache MISS, so a version bump never serves a
-- stale-schema row.
module Shikumi.Cache.Types
  ( CachedResponse (..),
  )
where

import Baikai (Response)
import Data.Aeson (FromJSON, ToJSON)
import Data.Text (Text)
import Data.Time.Clock (UTCTime)
import GHC.Generics (Generic)
import Shikumi.Cache.ResponseJSON ()

-- | A cached provider response: the full 'Response' (message, usage, cost), when
-- it was written, and the key-namespace version it was written under.
data CachedResponse = CachedResponse
  { response :: !Response,
    storedAt :: !UTCTime,
    keyVersion :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)
