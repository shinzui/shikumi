---
id: 41
slug: unify-cache-backend-semantics
title: "Unify Cache Backend Semantics"
kind: exec-plan
created_at: 2026-07-02T03:30:16Z
intention: "intention_01kwgdyxm7ehh8yys1pp4wf1zr"
master_plan: "docs/masterplans/7-cache-trace-and-replay-hardening.md"
---

# Unify Cache Backend Semantics

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

shikumi's response cache has one effect (`Cache`, with `lookupCache`/`storeCache`), one memoizing policy (`cachedLLM`), and four interchangeable storage backends: in-memory, SQLite, Redis, Postgres. They are supposed to be drop-in replacements for each other, but today they disagree on the two contracts a caller most needs to trust. Eviction: Redis silently expires every entry after 7 days while Memory, SQLite, and Postgres keep entries forever (SQLite even writes a `stored_at` column "for eviction" that nothing reads). Error posture: Redis and Postgres swallow storage failures and degrade to a MISS or a skipped write, while SQLite lets `SQLite3` exceptions fly and crashes the host program — a cache, an optimization layer, can take the application down. On top of that, the Postgres backend leaks its database connection when schema creation fails, SQLite is unprepared for multi-process use (no WAL, no busy timeout), and the policy layer `cachedLLM` happily memoizes in-band *error* responses, so a transient provider failure can be replayed as the "cached answer" forever.

After this plan, a cache backend has one contract: best-effort (storage failure degrades to MISS/no-op, never an exception), no eviction unless the caller opts in, and one shared TTL knob (`CacheConfig`) that behaves identically over every backend. `cachedLLM` never stores an error response and documents its (acceptable) concurrent double-fetch race. You can see it working by running the test suites: killing the storage under a backend now yields a MISS instead of a crash, a corrupt SQLite row decodes to a MISS, an expired entry re-contacts the provider, and an error response is fetched twice rather than served from cache.

This plan also makes the redis/postgres suites' "skip when no server" behavior loud (a prominent `SKIPPED` banner) — but deliberately stops there: making CI *fail or require* those suites belongs to the CI initiative, `docs/masterplans/9-ci-and-shared-test-infrastructure.md`.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M1: `CacheConfig` type + `defaultCacheConfig`; `cachedLLMWith`; never-cache-error guard; race documented
- [ ] M2: `bestEffortIO` helper; SQLite handlers degrade instead of throwing; SQLite WAL + busy_timeout pragmas
- [ ] M2: Redis default TTL removed (opt-in via `openRedisCacheWithTTL`); Redis lookup/store best-effort against thrown exceptions
- [ ] M2: Postgres connection released on schema failure
- [ ] M3: new tests — error-response non-caching, TTL expiry, SQLite corrupt-row MISS, SQLite dropped-table degradation, Redis/Postgres closed-handle degradation, Redis storage-TTL knob
- [ ] M3: loud SKIPPED banners in redis/postgres suites (CI gating deferred to masterplan 9)
- [ ] Full suites green: `just test-one shikumi-cache`, `just test-one shikumi-cache-redis` (with services up), `just test-one shikumi-cache-postgres`


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: One error posture for all backends — best-effort. A lookup failure is a MISS, a store failure is a silent no-op; only asynchronous exceptions are re-thrown.
  Rationale: The cache is an optimization; correctness never depends on it (`cachedLLM` falls back to the provider on any MISS). Redis and Postgres already behave this way; SQLite crashing the program on a locked file is strictly worse than a cache miss. The alternative (propagate everywhere) would force every caller to wrap cache use in handlers, defeating the drop-in design. Asynchronous exceptions (thread cancellation, timeouts) must still propagate or `withAsync`/timeout machinery breaks.
  Source: production-readiness code review recommendation, verified against the four backends.
  Date: 2026-07-01

- Decision: Uniform default is "no eviction"; TTL is opt-in and enforced at the policy layer (`cachedLLMWith` + `CacheConfig`), with Redis's server-side `SETEX` retained only as an explicit extra knob (`openRedisCacheWithTTL`).
  Rationale: Enforcing TTL where the `Time` effect already lives (the policy layer) gives identical expiry semantics over all four backends with one implementation, including Memory (whose interpreter has no IO clock access). Server-side expiry in Redis remains useful for bounding storage, but it stops being a silent default because a 7-day default made Redis semantically different from every other backend.
  Date: 2026-07-01

- Decision: `cachedLLM` never stores a response whose `stopReason` is `ErrorReason` or whose `errorInfo` is set; the check-then-act double fetch under concurrency is documented as accepted, not fixed.
  Rationale: An in-band error response is a failure report, not an answer; memoizing it converts a transient outage into a permanent wrong answer. The double fetch (two concurrent identical requests both miss, both call the provider, both store) is benign: stores are idempotent upserts of equal-keyed data, and the cost is one redundant provider call in a rare window — cheaper than adding cross-process locking to four backends.
  Date: 2026-07-01

- Decision: Make redis/postgres suite skips loud but keep exit code 0; CI enforcement is out of scope.
  Rationale: The CI initiative (docs/masterplans/9-ci-and-shared-test-infrastructure.md) owns when a skip should fail a pipeline. Two owners of one knob would conflict.
  Date: 2026-07-01


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This repository is a cabal multi-package Haskell project; build and test inside the Nix dev shell (`nix develop .#ghc9124` from the repo root). `just test-one <pkg>` runs one package's tests. Local Redis/Postgres services for the Redis suite are managed by process-compose: `just services-up` starts them detached (the dev shell exports `REDIS_SOCKET`, a UNIX socket path), `just services-down` stops them. The Postgres suite does not need them — it boots a throwaway server itself via the `ephemeral-pg` library (the dev shell provides the postgres binaries).

The pieces, all named by repository-relative path:

- `shikumi-cache/src/Shikumi/Cache.hs` — the `Cache` effect (an `effectful` dynamic effect with `LookupCache`/`StoreCache` operations) and the policy `cachedLLM` (lines 57-72). `cachedLLM` interposes on the `LLM` effect: on `Complete` it computes the request's cache key, does `lookupCache`; a hit with matching `keyVersion` returns the stored response; otherwise it calls the provider, then `storeCache`s the result unconditionally — including error responses — and there is no TTL concept anywhere. The lookup-then-store sequence is also a check-then-act race under concurrent identical requests (both miss, both fetch); accepted, to be documented (Decision Log).
- `shikumi-cache/src/Shikumi/Cache/Types.hs` — `CachedResponse { response, storedAt :: UTCTime, keyVersion :: Text }`. `storedAt` is exactly what TTL needs and is already persisted by every backend.
- `shikumi-cache/src/Shikumi/Cache/Backend/Memory.hs` — a `TVar (Map Text CachedResponse)`; never evicts, cannot fail.
- `shikumi-cache/src/Shikumi/Cache/Backend/SQLite.hs` — a `direct-sqlite` database behind an `MVar`. Opens at lines 77-81 with no pragmas. The interpreter (lines 94-97) calls `sqliteLookup` (101-112) and `sqliteStore` (115-122) with no exception handler anywhere, so any `Database.SQLite3.SQLError` (locked database, dropped table, disk error) propagates and kills the program. A row that fails JSON decode is already a MISS (documented at lines 91-93 — currently untested). `stored_at` is written (line 119) but never read; the schema comment (lines 47-49) says "for inspection/eviction" though no eviction exists.
- `shikumi-cache-redis/src/Shikumi/Cache/Backend/Redis.hs` — a hedis connection plus `ttl :: Integer`. `defaultRedisTTL` is 7 days (lines 37-39) and `openRedisCache` applies it, so entries silently vanish after a week; `StoreCache` uses `SETEX` (line 71). Lookup/store swallow *reply-level* errors (the `Either` from `runRedis`, lines 63-72) but a thrown exception (e.g. hedis's `ConnectionLostException` when the server goes away mid-connection) still escapes.
- `shikumi-cache-postgres/src/Shikumi/Cache/Backend/Postgres.hs` — a hasql connection behind an `MVar`. `openPostgresCache` (lines 42-51): if schema creation fails (line 50) it `throwIO`s *without* `Connection.release conn` — the acquired connection leaks. The interpreter (lines 60-71) already degrades session errors and decode failures to MISS/no-op (hasql's `Connection.use` returns `Either`, it does not throw for session errors).
- Tests: `shikumi-cache/test/Main.hs` (fixtures `fixModel`/`fixCtx`/`fixOpts`, a counting stub `runCountingLLM`, memory/SQLite/memoize/versioning groups); `shikumi-cache-redis/test/Main.hs` (skips via `skip` helper at lines 67-70 when `REDIS_SOCKET` is unset or unreachable, printing one `[SKIP]` line and exiting 0); `shikumi-cache-postgres/test/Main.hs` (skips at lines 53-55 when ephemeral-pg cannot start).

Terms: "MISS" is `lookupCache` returning `Nothing`; "best-effort" means storage failures produce a MISS or skipped write rather than an exception; "TTL" (time-to-live) is a maximum entry age, after which the entry is treated as absent; "in-band error response" is a successfully returned `Baikai.Response` that *reports* a failure — its `message.stopReason` is `ErrorReason` and/or its `errorInfo :: Maybe BaikaiError` is set (baikai returns these instead of throwing for provider-level errors).

Coordination note: `docs/plans/40-cache-key-v2-endpoint-completeness.md` also edits `shikumi-cache/src/Shikumi/Cache/Key.hs` and `shikumi-cache/test/Main.hs`. Nothing here depends on it (this plan never touches the key function); whichever lands second just rebases the shared test file.


## Plan of Work

### Milestone 1: policy layer — `CacheConfig`, TTL at lookup, never cache errors

Scope: `shikumi-cache/src/Shikumi/Cache.hs` (plus its export list and haddocks). At the end, `cachedLLMWith` exists, `cachedLLM` is its no-TTL specialization, error responses are never stored, and the double-fetch race is documented. Verifiable with the new tests in M3, but the package compiles and existing tests stay green now.

Add the config type (in `Shikumi.Cache` itself, since it configures the policy, not a backend):

```haskell
-- | Policy knobs for 'cachedLLMWith', shared by every backend.
--
-- 'entryTTL' is the maximum age of a usable entry, measured against
-- 'CachedResponse.storedAt' at lookup time. 'Nothing' (the default) means
-- entries never expire — the uniform default across Memory, SQLite, Redis,
-- and Postgres. Expiry is enforced here, at the policy layer, so it behaves
-- identically no matter which backend interprets the 'Cache' effect; an
-- expired entry is treated as a MISS and overwritten by the fresh response.
newtype CacheConfig = CacheConfig
  { entryTTL :: Maybe NominalDiffTime
  }
  deriving stock (Eq, Show, Generic)

-- | No expiry.
defaultCacheConfig :: CacheConfig
defaultCacheConfig = CacheConfig {entryTTL = Nothing}
```

(Imports: `Data.Time.Clock (NominalDiffTime, diffUTCTime)`, `GHC.Generics (Generic)`.)

Replace the body of `cachedLLM` with a configured variant and re-express `cachedLLM` in terms of it:

```haskell
cachedLLM :: (Cache :> es, LLM :> es, Time :> es) => Eff es a -> Eff es a
cachedLLM = cachedLLMWith defaultCacheConfig

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
        when (cacheable resp) $
          storeCache key (CachedResponse resp now currentKeyVersion)
        pure resp
  other -> passthrough env other
  where
    fresh Nothing _ _ = True
    fresh (Just ttl) now written = diffUTCTime now written <= ttl

-- | Only successful responses are memoized. An in-band error response
-- (stopReason 'ErrorReason' or a populated 'errorInfo') reports a transient
-- failure; caching it would replay the outage as the permanent answer.
cacheable :: Response -> Bool
cacheable resp =
  (resp ^. #message . #stopReason) /= ErrorReason
    && isNothing (resp ^. #errorInfo)
```

Imports needed: `Control.Monad (when)`, `Data.Maybe (isNothing)`, `Control.Lens ((^.))`, `Data.Generics.Labels ()`, and from `Baikai`: `Response`, `StopReason (ErrorReason)` (if the umbrella `Baikai` module does not re-export `StopReason`, import `Baikai.StopReason (StopReason (ErrorReason))` directly — check `Baikai`'s export list in the baikai checkout, found via `mori registry show baikai --full`). Export `CacheConfig (..)`, `defaultCacheConfig`, and `cachedLLMWith` from the module.

Extend the `cachedLLM`/module haddock with the posture contract, in roughly these words: lookups and stores are best-effort at every backend (failure is a MISS/no-op); entries never expire unless `entryTTL` is set; error responses are never stored; and under concurrent identical requests both callers may miss and both may call the provider — an accepted race, harmless because stores are idempotent upserts keyed by content.

### Milestone 2: backend unification

Scope: the three persistent backends. At the end, no backend can throw from `lookupCache`/`storeCache` (async exceptions excepted), Redis has no default expiry, Postgres does not leak, and SQLite is multi-process ready.

First, one shared helper so the posture is written once. Add a new module `shikumi-cache/src/Shikumi/Cache/Backend/Effort.hs` (add it to `exposed-modules` in `shikumi-cache/shikumi-cache.cabal`; the redis package depends on `shikumi-cache` and can import it):

```haskell
-- | The one error posture every persistent cache backend shares: best-effort.
-- A failed storage action degrades to its fallback (a MISS for lookups, a
-- no-op for stores) instead of throwing. Asynchronous exceptions (thread
-- cancellation, timeouts) are re-thrown — swallowing those would break
-- structured concurrency.
module Shikumi.Cache.Backend.Effort (bestEffortIO) where

import Control.Exception (SomeAsyncException (..), SomeException, catch, fromException, throwIO)

bestEffortIO :: a -> IO a -> IO a
bestEffortIO fallback act =
  act `catch` \(e :: SomeException) ->
    case fromException e of
      Just (SomeAsyncException _) -> throwIO e
      Nothing -> pure fallback
```

(Enable `ScopedTypeVariables` if the package's default extensions do not already cover it — check `shikumi-cache.cabal`'s `default-extensions`.)

SQLite (`shikumi-cache/src/Shikumi/Cache/Backend/SQLite.hs`): wrap both interpreter arms (lines 94-97):

```haskell
runCacheSQLite (SQLiteCache mv) = interpret $ \_ -> \case
  LookupCache k -> liftIO (bestEffortIO Nothing (withMVar mv (sqliteLookup k)))
  StoreCache k v -> liftIO (bestEffortIO () (withMVar mv (\db -> sqliteStore db k v)))
```

and in `openSQLiteCache` (lines 77-81), immediately after `SQL.exec db createTableSQL`, set the multi-process pragmas (WAL lets a reader and a writer coexist across processes; `busy_timeout` makes a locked database wait instead of failing):

```haskell
SQL.exec db "PRAGMA journal_mode=WAL;"
SQL.exec db "PRAGMA busy_timeout=5000;"
```

Note `PRAGMA journal_mode` returns a row; `SQL.exec` with direct-sqlite tolerates statements that return rows, but if it complains, run it via prepare/step/finalize like `sqliteLookup` does. Update the module haddock: lookups/stores are best-effort; a corrupt row is a MISS; WAL + busy timeout make the file safe for concurrent processes. Also correct the `stored_at` comment (lines 47-49): it exists for inspection and for the policy-layer TTL (`storedAt` round-trips inside the JSON value; the column is a human-readable duplicate).

Redis (`shikumi-cache-redis/src/Shikumi/Cache/Backend/Redis.hs`): change `ttl` to `Maybe Integer`; `openRedisCache` passes `Nothing` (no expiry — the new uniform default); `openRedisCacheWithTTL ttl` passes `Just ttl` and its haddock now describes it as the opt-in server-side storage bound, distinct from and composable with the policy-layer `CacheConfig`. Keep `defaultRedisTTL` exported (convenience constant for callers of `openRedisCacheWithTTL`) but no longer applied anywhere by default — note the behavior change in its haddock. Store picks the command by the knob, and both arms gain the thrown-exception guard (hedis throws `ConnectionLostException` and IO errors for dead sockets; the `Either` reply handling already present covers only reply-level errors):

```haskell
runCacheRedis cache = interpret $ \_ -> \case
  LookupCache k -> liftIO . bestEffortIO Nothing $ do
    r <- R.runRedis (conn cache) (R.get (redisKey k))
    pure $ case r of
      Right (Just bs) -> decodeStrict' bs
      _ -> Nothing
  StoreCache k v -> liftIO . bestEffortIO () $ do
    let bytes = BL.toStrict (encode v)
    _ <- R.runRedis (conn cache) $ case ttl cache of
      Just seconds -> () <$ R.setex (redisKey k) seconds bytes
      Nothing -> () <$ R.set (redisKey k) bytes
    pure ()
```

(Add `shikumi-cache`'s `Shikumi.Cache.Backend.Effort` import; `R.set` returns a different reply type than `R.setex`, hence the `() <$` normalization inside the case.)

Postgres (`shikumi-cache-postgres/src/Shikumi/Cache/Backend/Postgres.hs`): fix the leak in `openPostgresCache` (lines 47-51) — release before throwing:

```haskell
Right conn -> do
  r <- Connection.use conn (statement () createTableStmt)
  case r of
    Left e -> do
      Connection.release conn
      throwIO (userError ("shikumi-cache-postgres: schema creation failed: " <> show e))
    Right () -> PostgresCache <$> newMVar conn
```

The interpreter already degrades (hasql returns `Either`), but wrap both arms in `bestEffortIO` anyway so the posture is uniform even if a future hasql call throws. Update the module haddock's "entries live until explicitly removed" sentence to reference the policy-layer TTL.

### Milestone 3: tests and loud skips

Scope: the three test suites. Each new test is phrased to fail before its M1/M2 change and pass after.

In `shikumi-cache/test/Main.hs`:

1. Never-cache-error (fails before M1: counter would be 1). Build an error response from the existing `stubResponse` (`_Response`), run the memoize harness twice, expect two provider calls and nothing served from cache:

```haskell
testCase "an in-band error response is not memoized" $ do
  tv <- newMemoryCache
  ref <- newIORef 0
  let errResp = stubResponse & #message . #stopReason .~ ErrorReason
  _ <-
    runEff . runConcurrent . runTime . runCacheMemory tv . runCountingLLM ref errResp . cachedLLM $ do
      _ <- complete fixModel fixCtx fixOpts
      complete fixModel fixCtx fixOpts
  n <- readIORef ref
  n @?= 2
```

(Import `StopReason (ErrorReason)` as in M1.)

2. TTL expiry (fails before M1: `cachedLLMWith` does not exist). Pre-store an entry with an ancient `storedAt` (the file already has `someTime = read "2026-06-08 ..."`, comfortably older than an hour by the real clock this test runs under), then run with a one-hour TTL and expect a provider call; run again immediately and expect a hit (the refetch stored a fresh `storedAt`):

```haskell
testCase "an entry older than entryTTL is a MISS; the refetched entry is a HIT" $ do
  tv <- newMemoryCache
  ref <- newIORef 0
  let key = cacheKey fixModel fixCtx fixOpts
      cfg = defaultCacheConfig {entryTTL = Just 3600}
  runEff . runConcurrent . runCacheMemory tv $
    storeCache key (CachedResponse stubResponse someTime currentKeyVersion)
  _ <- runEff . runConcurrent . runTime . runCacheMemory tv . runCountingLLM ref stubResponse . cachedLLMWith cfg $ complete fixModel fixCtx fixOpts
  _ <- runEff . runConcurrent . runTime . runCacheMemory tv . runCountingLLM ref stubResponse . cachedLLMWith cfg $ complete fixModel fixCtx fixOpts
  n <- readIORef ref
  n @?= 1
```

3. SQLite corrupt-row MISS (the documented-but-untested path at `SQLite.hs:91-93`): open a cache on a temp file, use a *separate* raw `Database.SQLite3` connection to the same file to `INSERT OR REPLACE` a garbage `value` (e.g. `"not json"`) under a known key, then `lookupCache` through the backend and expect `Nothing`.

4. SQLite error degradation (fails before M2 with an uncaught `SQLError`): open a cache on a temp file, then via a second raw connection `DROP TABLE shikumi_cache;`, then through the backend run `lookupCache` (expect `Nothing`) and `storeCache` (expect it to return `()` without throwing).

In `shikumi-cache-redis/test/Main.hs` (runs only with services up — see Concrete Steps):

5. Closed-handle degradation (fails before M2 with a `ConnectionLostException`): open a second `RedisCache` to the same socket, `closeRedisCache` it, then through `runCacheRedis` expect `lookupCache` → `Nothing` and `storeCache` → `()`.

6. The TTL knob: with `openRedisCacheWithTTL 60 ci`, store an entry and assert (via a raw hedis `R.ttl` on the operational key, pattern from the existing `clearKey`/`redisKeyFor` helpers) that the key's TTL is positive; with the default `openRedisCache`, store and assert `R.ttl` returns `-1` (Redis's "exists, no expiry"). The second half fails before M2 (default was SETEX 7 days → positive TTL).

In `shikumi-cache-postgres/test/Main.hs`:

7. Released-connection degradation: open a second `PostgresCache` against the same ephemeral server, `closePostgresCache` it, then expect `lookupCache` → `Nothing` and `storeCache` → `()` through it.

Loud skips (same milestone): in `shikumi-cache-redis/test/Main.hs` replace the `skip` helper body (lines 68-70) so the notice cannot be missed in scrolled CI logs, keeping exit code 0:

```haskell
skip reason = do
  let banner = replicate 72 '='
  mapM_
    putStrLn
    [ banner,
      "== SKIPPED: shikumi-cache-redis test suite ran ZERO tests",
      "== reason: " <> reason,
      "== to run for real: `just services-up` inside `nix develop .#ghc9124`",
      "== CI enforcement of this skip is owned by docs/masterplans/9-ci-and-shared-test-infrastructure.md",
      banner
    ]
  exitSuccess
```

Mirror the same banner (with the package name `shikumi-cache-postgres` and reason `Pg.renderStartError err`, and the hint "the dev shell provides the postgres binaries ephemeral-pg needs") in `shikumi-cache-postgres/test/Main.hs` lines 53-55. Do not change exit codes and do not add CI configuration — that is masterplan 9's decision.


## Concrete Steps

All commands from the repository root, inside the dev shell:

```bash
nix develop .#ghc9124
cabal build shikumi-cache shikumi-cache-redis shikumi-cache-postgres
just test-one shikumi-cache
```

The Redis suite skips (loudly, after M3) unless a Redis is listening on `$REDIS_SOCKET`. Start the local services first; process-compose runs Redis and Postgres on UNIX sockets and the dev shell wires the env vars:

```bash
just services-up          # start Redis+Postgres detached (process-compose)
just test-one shikumi-cache-redis
just services-down        # stop them when done
```

Expected tail when the server is up:

```text
shikumi-cache-redis
  memoize: first request MISS (provider once), repeat is a Redis HIT: OK
  a closed connection degrades to MISS / no-op:                       OK
  storage TTL knob: opt-in SETEX vs default no-expiry:                OK
All 3 tests passed
```

And when it is not up (after M3), the suite prints the `====` `SKIPPED` banner and exits 0.

The Postgres suite is hermetic (ephemeral-pg starts its own server; no `just services-up` needed, though the dev shell must be active so `initdb`/`postgres` are on PATH):

```bash
just test-one shikumi-cache-postgres
```

Commit per milestone with conventional-commit subjects (e.g. `fix(cache-sqlite): degrade storage errors to MISS and enable WAL`, `feat(cache): CacheConfig TTL and error-response guard`, `fix(cache-postgres): release connection on schema failure`, `test(cache): loud SKIPPED banners for server-backed suites`), each carrying the trailers:

```text
MasterPlan: docs/masterplans/7-cache-trace-and-replay-hardening.md
ExecPlan: docs/plans/41-unify-cache-backend-semantics.md
Intention: intention_01kwgdyxm7ehh8yys1pp4wf1zr
```


## Validation and Acceptance

Acceptance is behavioral, per contract clause:

- Error posture: with a SQLite cache whose table was dropped out from under it, `lookupCache` returns `Nothing` and `storeCache` returns `()` — before this plan the process died with an `SQLError`. With a disconnected Redis handle, same degradation — before, `ConnectionLostException`. Run: `just test-one shikumi-cache` (SQLite cases) and `just test-one shikumi-cache-redis` with services up.
- Eviction: by default no backend expires anything (Redis `R.ttl` reports `-1` on a stored key — before, ~604800). With `cachedLLMWith (defaultCacheConfig {entryTTL = Just 3600})`, an entry written with an old `storedAt` triggers a provider call, and the immediately following identical request is a HIT. The TTL test encodes exactly this and must fail if you revert the M1 change.
- Error responses: the never-cache-error test observes two provider calls for two identical requests when the stub answers with `stopReason = ErrorReason` — before this plan it observed one (the outage was memoized).
- Hygiene: the Postgres leak fix is validated by code inspection plus the existing suite staying green (`openPostgresCache` failure paths are exercised only when schema creation fails, which the ephemeral server does not produce; the observable claim is "release is now called on every exit path", visible in the diff).
- Skips: run `REDIS_SOCKET= just test-one shikumi-cache-redis` (empty var) and observe the multi-line `SKIPPED` banner with exit code 0 (`echo $?` prints `0`).


## Idempotence and Recovery

All edits are source-level and re-runnable. The SQLite pragmas are idempotent per connection (WAL persists in the file; re-issuing is harmless). The Redis default-TTL change alters behavior for existing deployments (entries stop auto-expiring); the recovery knob is explicit — `openRedisCacheWithTTL defaultRedisTTL` restores the old behavior verbatim, and the haddock must say so. Tests that mutate shared state (the Redis suite's fixed key) already clear it up front via `clearKey`; keep new tests self-cleaning the same way (delete the keys they write, or use per-test keys derived from distinct fixtures). If `just services-up` leaves stale services, `just services-down` then re-up; state lives under `.dev/` in the repo and can be deleted wholesale when the services are down.


## Interfaces and Dependencies

Existing dependencies suffice: `effectful` (effects), `aeson`, `direct-sqlite`, `hedis`, `hasql`, `ephemeral-pg` (tests), `tasty`/`tasty-hunit`, `time`. One new internal module and these signatures must exist at the end:

```haskell
-- shikumi-cache, module Shikumi.Cache
newtype CacheConfig = CacheConfig { entryTTL :: Maybe NominalDiffTime }
defaultCacheConfig :: CacheConfig
cachedLLM     :: (Cache :> es, LLM :> es, Time :> es) => Eff es a -> Eff es a
cachedLLMWith :: (Cache :> es, LLM :> es, Time :> es) => CacheConfig -> Eff es a -> Eff es a

-- shikumi-cache, new module Shikumi.Cache.Backend.Effort
bestEffortIO :: a -> IO a -> IO a

-- shikumi-cache-redis, module Shikumi.Cache.Backend.Redis
openRedisCache        :: R.ConnectInfo -> IO RedisCache            -- now: no expiry
openRedisCacheWithTTL :: Integer -> R.ConnectInfo -> IO RedisCache -- opt-in SETEX seconds
defaultRedisTTL       :: Integer                                    -- constant only; not applied by default
```

`runCacheMemory`, `runCacheSQLite`, `runCacheRedis`, `runCachePostgres` keep their exact signatures — the posture change is internal, which is what makes the backends drop-in interchangeable. The `Cache` effect itself and `CachedResponse` are unchanged. Cross-plan interface note: `docs/plans/40-cache-key-v2-endpoint-completeness.md` owns `Shikumi.Cache.Key`; this plan must not modify that module.
