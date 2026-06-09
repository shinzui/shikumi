# Caching, tracing & replay — under the covers

Caching, tracing, and replay are each an **`interpose` over the same `LLM` effect**. You opt
into them by stacking interpreters; the program code never changes. This guide explains the
content-addressed cache key, the span tree, deterministic replay, and how to swap cache
backends.

The packages: `shikumi-cache` (the `Cache` effect, in-memory + SQLite), `shikumi-cache-redis`,
`shikumi-cache-postgres`, `shikumi-trace` (the `Trace` effect + replay), `shikumi-trace-otel`.

---

## The interpose pattern

Both `cachedLLM` and `tracedLLM` re-handle the `LLM` effect's operations and delegate
downward. Stacked above `runLLMResilient`, a cache hit short-circuits before the transport
ever runs; a miss falls through. The same `LLM :> es` constraint that the program already has
is all they need — they add `Cache :> es` / `Trace :> es` to the row.

```
runProgram → cachedLLM → tracedLLM → runLLMResilient → Baikai → IO
              │            │
              │            └─ opens an LlmCallSpan per Complete, fills attrs from req+resp
              └─ on Complete: lookup by cache key; hit → return; miss → delegate, store
```

---

## Caching

### The `Cache` effect (mechanism) vs. `cachedLLM` (policy)

```haskell
data Cache :: Effect where
  LookupCache :: CacheKey -> Cache m (Maybe CachedResponse)
  StoreCache  :: CacheKey -> CachedResponse -> Cache m ()

cachedLLM :: (Cache :> es, LLM :> es, Time :> es) => Eff es a -> Eff es a
```

`Cache` is the *storage mechanism*; `cachedLLM` is the *memoizing policy* that uses it. On a
`Complete` call, `cachedLLM` computes the key, looks it up; a version-matching hit returns the
cached response, a miss delegates to the provider, stores the result, and returns it. `Stream`
calls pass through unchanged (not cached). Note the constraint: `cachedLLM` needs `Time :> es`
(to stamp entries), **not** `IOE` — see [Effects & the runtime](./effects-and-runtime.md#the-time-effect).

```haskell
data CachedResponse = CachedResponse
  { response   :: Response
  , storedAt   :: UTCTime
  , keyVersion :: Text        -- namespace version baked into the key
  }
```

### The cache key: content-addressed over the canonical request

```haskell
newtype CacheKey = CacheKey { unCacheKey :: Text }   -- 64-char hex BLAKE3 digest
cacheKey :: Model -> Context -> Options -> CacheKey
```

The key is a **BLAKE3 256-bit digest over a canonical JSON serialization** of everything that
defines the request: a version string, model, provider, api, system prompt, messages, tools,
tool choice, temperature, max tokens, thinking, response format. Canonical means object keys
sorted by Unicode code point, no insignificant whitespace, UTF-8. So **identical calls produce
identical keys** and are served from the cache; any meaningful change to the request changes
the key.

### Versioning

```haskell
currentKeyVersion :: Text     -- "shikumi-cache/v1"
```

The version is baked into every hashed request. Bumping it invalidates all prior entries
*without deleting rows* — stale entries simply never match and are treated as misses.

### Backends: same effect, different interpreter

You swap backends by swapping the interpreter that discharges `Cache`. The `cachedLLM` policy
is backend-agnostic.

| Backend | Package | Constructor | Interpreter |
|---|---|---|---|
| In-memory (STM map) | `shikumi-cache` | `newMemoryCache :: IO MemoryCache` | `runCacheMemory` *(needs `Concurrent`)* |
| SQLite | `shikumi-cache` | `openSQLiteCache` / `withSQLiteCache` | `runCacheSQLite` |
| Redis (TTL eviction) | `shikumi-cache-redis` | `openRedisCache` / `openRedisCacheWithTTL` | `runCacheRedis` |
| Postgres (jsonb, upsert) | `shikumi-cache-postgres` | `openPostgresCache` | `runCachePostgres` |

```haskell
-- in-memory
cache <- newMemoryCache
runEff . runErrorNoCallStack @ShikumiError . runConcurrent . runTime
  . runCacheMemory cache . cachedLLM . runLLMResilient cfg
  $ runProgram summarize article

-- persistent: swap exactly one line (SQLite's interpreter is IOE-based)
withSQLiteCache ".shikumi/cache.db" $ \cache ->
  runEff . … . runCacheSQLite cache . cachedLLM . runLLMResilient cfg $ …
```

`runConcurrent` appears because both `runCacheMemory` (STM) and `runLLMResilient` (rate
limiter) require `Concurrent`; the persistent backends' interpreters require `IOE` instead.

The persistent backends are **fail-soft on reads**: a missing key, a backend error, or a
JSON decode failure is treated as a *miss* (it falls through to the provider), never an
exception. Store errors on the best-effort backends are swallowed. The DB interpreters are
where `IOE` legitimately lives.

---

## Tracing

### The `Trace` effect and the span tree

```haskell
data Trace :: Effect where
  WithSpan      :: SpanKind -> Text -> m a -> Trace m a
  CurrentSpanId :: Trace m (Maybe SpanId)
  BumpRetry     :: Trace m ()
  RecordToolCall:: ToolCallRecord -> Trace m ()
  AnnotateSpan  :: (SpanAttrs -> SpanAttrs) -> Trace m ()

runTrace :: (Prim :> es, Time :> es) => Eff (Trace : es) a -> Eff es (a, TraceTree)
```

`runTrace` produces the result paired with a finished `TraceTree`. It builds the tree in
in-process mutable cells and stamps span times from the clock — so it needs `Prim` and
`Time`, **not** `IOE`. A span is a node with a
kind (`ProgramSpan` / `ModuleSpan` / `CombinatorSpan` / `LlmCallSpan`), a label, start/end
times, a parent, and rich attributes (model, provider, prompt + response JSON, latency, token
counts, cost, retries, tool calls, cache key). `withSpan` nests; the tree records children in
creation order.

### Capturing LM calls automatically

```haskell
tracedLLM :: (Trace :> es, LLM :> es) => Eff es a -> Eff es a
```

Interposing on the `LLM` effect, `tracedLLM` opens an `LlmCallSpan` leaf for each `Complete`
call and fills its attributes from the request and response — you get a span per provider call
with no manual instrumentation.

### Rendering & persisting

```haskell
renderTree     :: TraceTree -> Text                       -- indented outline: kind, label, duration, tokens, cost
writeTraceFile :: FilePath -> TraceTree -> IO ()          -- atomic (.tmp then rename), versioned
readTraceFile  :: FilePath -> IO (Either Text TraceTree)  -- rejects version mismatches
```

```haskell
putStr (T.unpack (renderTree tree))
writeTraceFile "run.json" tree
```

### OpenTelemetry export

`shikumi-trace-otel` exposes `exportTree :: MonadIO m => Tracer -> TraceTree -> m ()`, which
walks a finished tree and creates nested OTel spans preserving parent/child nesting (via
explicit context, so it works post-hoc). Structural nodes map to `Internal` spans; LM-call
nodes map to `Client` spans and carry GenAI semantic-convention attributes
(`gen_ai.request.model`, `gen_ai.usage.input_tokens`, cost, latency, …). *(The CLI's live OTel
export is the one piece still planned — see the [README status table](../../README.md#implementation-status).)*

---

## Deterministic replay

A stored trace is enough to **re-run a whole program with zero provider calls**.

```haskell
replayIndex  :: TraceTree -> Map CacheKey Value        -- every LM-call span's key → response JSON
runLLMReplay :: Map CacheKey Value -> Eff (LLM : es) a -> Eff es a
```

`runLLMReplay` is a drop-in alternative interpreter of the `LLM` effect: it computes the cache
key for each `Complete` call and looks it up in the index. A hit returns the recorded response;
a **miss raises `ReplayDivergence`** — it is *fail-closed and loud*. An unrecorded request is an
error, never a silent network call or a fabricated answer. (Streaming completions are not
replayable.) Note it requires no `IOE` — the lookup is pure and divergence is a pure exception.

```haskell
Right tree <- readTraceFile "run.json"
let idx = replayIndex tree
result <- runEff . runErrorNoCallStack @ShikumiError . runLLMReplay idx
            $ runProgram summarize article    -- identical output, 0 provider calls
```

This is what powers the CLI's `replay` subcommand and the golden tests.

---

## See it run

```bash
cabal run jitsurei-trace-replay
```

One program demonstrated three ways: cached (in-memory), traced (span tree rendered and
persisted), then replayed from the stored trace fail-closed.
