-- | The Postgres cache backend (EP-6) — a server-backed, cross-machine store
-- with a durable SQL table.
--
-- Like the Redis backend it is shared by every process that can reach the
-- server, but it persists entries in a @jsonb@ column rather than an evicting
-- key-value store, so entries live until explicitly removed or the policy layer
-- treats them as expired via 'Shikumi.Cache.CacheConfig'. The value column holds
-- the JSON of a 'CachedResponse' (the baikai 'Baikai.Response.Response'
-- round-trip is @shikumi-cache@'s "Shikumi.Cache.ResponseJSON"). Access goes
-- through @hasql@; the single 'Connection' is guarded by an 'MVar' so the
-- 'Cache' effect's lookups and stores are serialized.
module Shikumi.Cache.Backend.Postgres
  ( PostgresCache,
    openPostgresCache,
    closePostgresCache,
    runCachePostgres,
  )
where

import Control.Concurrent.MVar (MVar, modifyMVar_, newMVar, withMVar)
import Control.Exception (throwIO)
import Data.Aeson (Result (Error, Success), Value, fromJSON, toJSON)
import Data.Functor.Contravariant ((>$<))
import Data.Text (Text)
import Effectful (Eff, IOE, liftIO, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Hasql.Connection (Connection)
import Hasql.Connection qualified as Connection
import Hasql.Connection.Settings (Settings)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Session (statement)
import Hasql.Statement (Statement, preparable, unpreparable)
import Shikumi.Cache (Cache (..), CacheKey (unCacheKey))
import Shikumi.Cache.Backend.Effort (bestEffortIO)

-- | An open Postgres-backed cache: a single connection behind an 'MVar' (hasql
-- connections are not safe for concurrent use), with the schema ensured at
-- open. The connection becomes 'Nothing' after 'closePostgresCache' so accidental
-- use-after-close degrades without touching a released libpq pointer.
newtype PostgresCache = PostgresCache (MVar (Maybe Connection))

-- | Connect using the given hasql settings (e.g. @EphemeralPg.connectionSettings@
-- for tests, or @Hasql.Connection.Settings@ builders in production), ensuring the
-- @shikumi_cache@ table exists. Throws on a connection or schema-creation error.
openPostgresCache :: Settings -> IO PostgresCache
openPostgresCache settings = do
  res <- Connection.acquire settings
  case res of
    Left err -> throwIO (userError ("shikumi-cache-postgres: connection failed: " <> show err))
    Right conn -> do
      r <- Connection.use conn (statement () createTableStmt)
      case r of
        Left e -> do
          Connection.release conn
          throwIO (userError ("shikumi-cache-postgres: schema creation failed: " <> show e))
        Right () -> PostgresCache <$> newMVar (Just conn)

-- | Release the connection.
closePostgresCache :: PostgresCache -> IO ()
closePostgresCache (PostgresCache mv) =
  modifyMVar_ mv $ \case
    Nothing -> pure Nothing
    Just conn -> do
      Connection.release conn
      pure Nothing

-- | Discharge the 'Cache' effect against Postgres. A missing row, a session
-- error, or a JSON decode failure all surface as a MISS ('Nothing'); a store
-- error is swallowed (best-effort caching — the next call simply re-fetches).
runCachePostgres :: (IOE :> es) => PostgresCache -> Eff (Cache : es) a -> Eff es a
runCachePostgres (PostgresCache mv) = interpret $ \_ -> \case
  LookupCache k -> liftIO . bestEffortIO Nothing . withMVar mv $ \case
    Nothing -> pure Nothing
    Just conn -> do
      r <- Connection.use conn (statement (unCacheKey k) lookupStmt)
      pure $ case r of
        Right (Just v) -> case fromJSON v of
          Success cr -> Just cr
          Error _ -> Nothing
        _ -> Nothing
  StoreCache k v -> liftIO . bestEffortIO () . withMVar mv $ \case
    Nothing -> pure ()
    Just conn -> do
      _ <- Connection.use conn (statement (unCacheKey k, toJSON v) storeStmt)
      pure ()

-- | @CREATE TABLE IF NOT EXISTS@ (unpreparable — it is a utility statement).
createTableStmt :: Statement () ()
createTableStmt =
  unpreparable
    """
    CREATE TABLE IF NOT EXISTS shikumi_cache
      ( key       text PRIMARY KEY
      , value     jsonb NOT NULL
      , stored_at timestamptz NOT NULL DEFAULT now()
      )
    """
    mempty
    D.noResult

-- | SELECT the jsonb value for a key (NULL row → 'Nothing').
lookupStmt :: Statement Text (Maybe Value)
lookupStmt =
  preparable
    """
    SELECT value FROM shikumi_cache WHERE key = $1
    """
    (E.param (E.nonNullable E.text))
    (D.rowMaybe (D.column (D.nonNullable D.jsonb)))

-- | Upsert the jsonb value for a key (idempotent).
storeStmt :: Statement (Text, Value) ()
storeStmt =
  preparable
    """
    INSERT INTO shikumi_cache (key, value) VALUES ($1, $2)
    ON CONFLICT (key) DO UPDATE SET value = excluded.value, stored_at = now()
    """
    ( (fst >$< E.param (E.nonNullable E.text))
        <> (snd >$< E.param (E.nonNullable E.jsonb))
    )
    D.noResult
