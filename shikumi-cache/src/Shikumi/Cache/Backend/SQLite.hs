-- | The SQLite cache backend (EP-6) — a durable, embedded, single-file store.
--
-- Unlike the in-memory backend (which holds the Haskell 'CachedResponse'
-- directly), SQLite persists the entry as JSON in a file, so a cache written by
-- one process is read back by a later process: run a program, kill it, restart,
-- and an identical request is served from disk with no provider call. The JSON
-- round-trip for baikai's 'Baikai.Response.Response' graph comes from
-- "Shikumi.Cache.ResponseJSON" (re-exported through 'CachedResponse''s
-- 'Data.Aeson.ToJSON'/'Data.Aeson.FromJSON').
--
-- The store is a thin embedded SQLite database (no server) accessed via
-- @direct-sqlite@. A single 'Database.SQLite3.Database' handle is guarded by an
-- 'MVar' so the 'Cache' effect's lookups and stores are serialized (SQLite's
-- default threading mode does not allow concurrent use of one connection). WAL
-- mode and a busy timeout make separate processes cooperate better. Lookup and
-- store failures are best-effort: they degrade to a MISS or no-op.
module Shikumi.Cache.Backend.SQLite
  ( SQLiteCache,
    openSQLiteCache,
    closeSQLiteCache,
    withSQLiteCache,
    runCacheSQLite,
  )
where

import Control.Concurrent.MVar (MVar, newMVar, withMVar)
import Control.Exception (bracket)
import Data.Aeson (decodeStrict', encode)
import Data.ByteString.Lazy qualified as BL
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time.Format.ISO8601 (iso8601Show)
import Database.SQLite3
  ( ColumnIndex (ColumnIndex),
    Database,
    SQLData (SQLText),
    StepResult (Done, Row),
  )
import Database.SQLite3 qualified as SQL
import Effectful (Eff, IOE, liftIO, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Shikumi.Cache (Cache (..), CacheKey (unCacheKey), CachedResponse (..))
import Shikumi.Cache.Backend.Effort (bestEffortIO)

-- | A handle to an open SQLite-backed cache. The 'Database' is behind an 'MVar'
-- so all access through the 'Cache' effect is serialized.
newtype SQLiteCache = SQLiteCache {db :: MVar Database}

-- | The schema. The @key@ is the 64-hex 'CacheKey' (already version-namespaced
-- via the @version@ field baked into the hash). @value@ is the UTF-8 JSON of
-- 'CachedResponse'. @stored_at@ is ISO-8601 for inspection; policy-layer TTL
-- uses the same timestamp inside the JSON value.
createTableSQL :: Text
createTableSQL =
  """
  CREATE TABLE IF NOT EXISTS shikumi_cache
    ( key       TEXT PRIMARY KEY
    , value     TEXT NOT NULL
    , stored_at TEXT NOT NULL
    );
  """

-- | SELECT the JSON value for a key.
selectSQL :: Text
selectSQL =
  """
  SELECT value FROM shikumi_cache WHERE key = ?;
  """

-- | Upsert the JSON value for a key.
insertSQL :: Text
insertSQL =
  """
  INSERT OR REPLACE INTO shikumi_cache (key, value, stored_at)
  VALUES (?, ?, ?);
  """

-- | Open (creating if needed) a SQLite cache at the given file path, ensuring
-- the schema exists. Pass @\":memory:\"@ for a transient in-process database.
openSQLiteCache :: FilePath -> IO SQLiteCache
openSQLiteCache path = do
  db <- SQL.open (T.pack path)
  SQL.exec db createTableSQL
  SQL.exec db "PRAGMA journal_mode=WAL;"
  SQL.exec db "PRAGMA busy_timeout=5000;"
  SQLiteCache <$> newMVar db

-- | Close the underlying database handle.
closeSQLiteCache :: SQLiteCache -> IO ()
closeSQLiteCache (SQLiteCache mv) = withMVar mv SQL.close

-- | Open a SQLite cache, run an action with it, and close it (exception-safe).
withSQLiteCache :: FilePath -> (SQLiteCache -> IO a) -> IO a
withSQLiteCache path = bracket (openSQLiteCache path) closeSQLiteCache

-- | Discharge the 'Cache' effect against the SQLite store. A row that fails to
-- decode is treated as absent (a MISS), so a corrupt or stale-schema entry is
-- simply re-fetched and overwritten — never returned.
runCacheSQLite :: (IOE :> es) => SQLiteCache -> Eff (Cache : es) a -> Eff es a
runCacheSQLite (SQLiteCache mv) = interpret $ \_ -> \case
  LookupCache k -> liftIO (bestEffortIO Nothing (withMVar mv (sqliteLookup k)))
  StoreCache k v -> liftIO (bestEffortIO () (withMVar mv (\db -> sqliteStore db k v)))

-- | SELECT the JSON for a key and decode it; 'Nothing' on absent key or decode
-- failure.
sqliteLookup :: CacheKey -> Database -> IO (Maybe CachedResponse)
sqliteLookup k db =
  bracket (SQL.prepare db selectSQL) SQL.finalize $ \stmt -> do
    SQL.bindText stmt 1 (unCacheKey k)
    res <- SQL.step stmt
    case res of
      Done -> pure Nothing
      Row -> do
        sqlVal <- SQL.column stmt (ColumnIndex 0)
        pure $ case sqlVal of
          SQLText t -> decodeStrict' (TE.encodeUtf8 t)
          _ -> Nothing

-- | Upsert (@INSERT OR REPLACE@) the JSON for a key; idempotent.
sqliteStore :: Database -> CacheKey -> CachedResponse -> IO ()
sqliteStore db k v =
  bracket (SQL.prepare db insertSQL) SQL.finalize $ \stmt -> do
    let json = TE.decodeUtf8 (BL.toStrict (encode v))
        stamp = T.pack (iso8601Show (storedAt v))
    SQL.bind stmt [SQLText (unCacheKey k), SQLText json, SQLText stamp]
    _ <- SQL.step stmt
    pure ()
