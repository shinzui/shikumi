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

newtype CacheConfig = CacheConfig
  { entryTTL :: Maybe NominalDiffTime
  }

defaultCacheConfig :: CacheConfig       -- entryTTL = Nothing
cachedLLM          :: (Cache :> es, LLM :> es, Time :> es, Error ShikumiError :> es) => Eff es a -> Eff es a
cachedLLMWith      :: (Cache :> es, LLM :> es, Time :> es, Error ShikumiError :> es) => CacheConfig -> Eff es a -> Eff es a
```

`Cache` is the *storage mechanism*; `cachedLLM` is the *memoizing policy* that uses it. On a
`Complete` call, `cachedLLM` computes the key, looks it up; a version-matching hit returns the
cached response, a miss delegates to the provider, stores a successful result, and returns it.
`Stream` calls pass through unchanged (not cached), and in-band provider error responses are
not cached. Note the constraint: `cachedLLM` needs `Time :> es` (to stamp entries and check
TTL), **not** `IOE` — see [Effects & the runtime](./effects-and-runtime.md#the-time-effect).
`cachedLLM` is `cachedLLMWith defaultCacheConfig`; use `cachedLLMWith` when you want a
uniform policy-layer TTL across every backend. The default is no expiry.

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
defines the request: a version string, model id, provider, API kind, base URL, model default
headers, compatibility shim, system prompt, messages, tools, tool choice, temperature, max
tokens, per-call headers, speed, thinking, and response format. Message construction timestamps are
stripped before hashing because they are local bookkeeping, not provider-visible prompt
content. API keys, timeouts, response ids, latency, and per-call metadata are excluded.
Canonical means object keys sorted by Unicode code point, no insignificant whitespace, UTF-8.
So **identical calls produce identical keys** and are served from the cache; any meaningful
change to the request changes the key.

### Versioning

```haskell
currentKeyVersion :: Text     -- "shikumi-cache/v2"
```

The version is baked into every hashed request. Bumping it invalidates all prior entries
*without deleting rows* — stale entries simply never match and are treated as misses. Because
trace files also store cache keys and replay recomputes them, a key-version bump makes old
trace files unable to satisfy replay; replay fails closed rather than serving stale responses.

### Backends: same effect, different interpreter

You swap backends by swapping the interpreter that discharges `Cache`. The `cachedLLM` policy
is backend-agnostic.

| Backend | Package | Constructor | Interpreter |
|---|---|---|---|
| In-memory (STM map) | `shikumi-cache` | `newMemoryCache :: IO MemoryCache` | `runCacheMemory` *(needs `Concurrent`)* |
| SQLite | `shikumi-cache` | `openSQLiteCache` / `withSQLiteCache` | `runCacheSQLite` |
| Redis (optional server TTL) | `shikumi-cache-redis` | `openRedisCache` / `openRedisCacheWithTTL` | `runCacheRedis` |
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
exception. Store errors on the best-effort backends are swallowed, while asynchronous
exceptions such as thread cancellation are rethrown. Redis no longer applies a server-side TTL
by default; pass `openRedisCacheWithTTL` if you want Redis to evict entries independently of
the policy-layer `CacheConfig`. The DB interpreters are where `IOE` legitimately lives.

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
(`gen_ai.request.model`, `gen_ai.usage.input_tokens`, cost, latency, …) plus — when the tree was
produced by `runProgramTraced` (below) — `shikumi.node_path`.

For a **live** collector, `Shikumi.Trace.LiveExport` wraps the same `exportTree`:

```haskell
exportTreeWith :: MonadIO m => SpanProcessor -> Text -> TraceTree -> m ()  -- factored seam
exportTreeLive :: MonadIO m => Text -> TraceTree -> m ()                   -- OTLP/HTTP
```

`exportTreeLive name tree` builds the OTLP/HTTP exporter from the standard OTel environment
variables (`OTEL_EXPORTER_OTLP_ENDPOINT`, default `http://localhost:4318`), wraps it in a batch
processor, exports, and flushes on shutdown. This is what `shikumi trace <id> --otel` calls (see
the [CLI guide](./cli.md)); start any OTLP collector on `:4318` and the recorded program shows up
as a nested span tree.

### Node-correlated tracing & the feedback channel

`runProgram`'s spans tell you *that* an LM call happened, not *which* program node issued it.
`runProgramTraced` (in `Shikumi.Trace.Program`) is an additive entry point — same semantics as
`runProgram`, but it opens a span per node and tags each LM-call span with a `NodePath`:

```haskell
runProgramTraced :: (LLM :> es, Trace :> es, CurrentNode :> es, Error ShikumiError :> es)
                 => Program i o -> i -> Eff es o
```

A `NodePath` (from `Shikumi.Trace.Node`) is a node's structural position, enumerated by
`programNodePaths` in the *same* order as `foldParams`/`mapParamsAt` — so the node a path points
at is the node a parameter edit `n` touches. `nodeFields :: Program i o -> [(NodePath, NodeFields)]`
recovers each node's input/output field names. Stack it like `tracedLLM`, but use the node-aware
capture and add `runCurrentNode`:

```haskell
runEff . runPrim . runTime . runTrace . runCurrentNode
  . runLLMResilient cfg . tracedNodeLLM
  $ runProgramTraced program input
```

A sibling `Shikumi.Trace.Feedback` lets a metric or judge attach a short textual critique to a
node (`attachFeedback path text`, kept *out* of the serialized trace) and an optimizer read it
back (`feedbackFor path log`), keyed by the same `NodePath`. (Adding the optional `nodePath` span
attribute bumped the trace `formatVersion` to 2.)

---

## Deterministic replay

A stored trace is enough to **re-run a whole program with zero provider calls**.

```haskell
replayIndex  :: TraceTree -> Either Text (Map CacheKey Value)
              -- every LM-call span's key -> response JSON, unless duplicate keys conflict
runLLMReplay :: Map CacheKey Value -> Eff (LLM : es) a -> Eff es a
```

`replayIndex` first checks the trace for determinism: duplicate cache keys are accepted only
when every occurrence recorded the same response. Conflicting duplicate responses return
`Left`. `runLLMReplay` is then a drop-in alternative interpreter of the `LLM` effect: it
computes the cache key for each `Complete` call and looks it up in the index. A hit returns the
recorded response; a **miss raises `ReplayDivergence`** with the missing key, model id, and a
redacted prompt summary — it is *fail-closed and loud*. An unrecorded request is an error,
never a silent network call or a fabricated answer. (Streaming completions are not replayable.)
Note it requires no `IOE` — the lookup is pure and divergence is a pure exception.

```haskell
Right tree <- readTraceFile "run.json"
Right idx <- pure (replayIndex tree)
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

## Defaults and evidence requests

Compose `cachedLLM . withRequestDefaults defaults . routeLLM` above the base
interpreter. Routing happens first, defaults second, and cache lookup third.
Equivalent explicit and defaulted options share keys; changes in speed or thinking
produce different keys. Reversing defaults and cache can reuse an entry before
the changed defaults are seen. See the
[compiled defaults example](../../shikumi-jitsurei/app/RequestDefaults.hs) for a
complete stack including tracing.

Any `Options.evidence = Just request` bypasses both cache reads and writes,
including warm entries and evidence supplied through defaults. A cached response
omits evidence and cannot establish a new provider crossing. Ordinary calls retain
memoization; streams remain uncached. Continuation validation runs before lookup
or evidence bypass. Trace above cache observes logical calls including hits; a
transport-attempt observer belongs below cache. Replay remains explicitly offline
and cannot create fresh provider evidence.

## Billing observations and observed model identity

For a run with billing detail, create `newBillingCollectorWithLimit n` from
`Shikumi.LLM.Observation` and set `LLMConfig.observer = Just observer`. Compose
wrappers in this request order: routing, continuation validation, fill-only
defaults, logical tracing, cache, then the observer-aware runtime. In Haskell
function composition the inner wrappers receive the operation first:

```haskell
runLLMResilient cfg
  . cachedLLM
  . tracedLLM
  . withRequestDefaults defaults
  . routeLLM
```

Supply the existing routing, cache, error, time and trace interpreters outside
that fragment. Enclose the sequential trace capture in `withSpan ProgramSpan`
so exported logical calls have a real shared root. The compiled composition is
in `shikumi-trace-otel/test/BillingSpec.hs`. The collector is thread-safe; the
existing sequential trace builder must not be shared across concurrent workers.

After capture, `Shikumi.Trace.attachBillingSummary billing tree` attaches the
whole-run snapshot. Trace format **3** persists this optional section separately
from program spans and reads formats 1 and 2 with missing billing fields. Attempt
records contain call ID, ordinal, request identity, observed model when available,
terminal classification, timing and optional usage. They have no prompt, response
text, opaque reasoning, cache key, or structural node parent. They never enter the
replay index. IDs identify invocations within a process, not globally durable runs.

Blocking and streaming logical spans carry optional billing quality. Streaming
usage comes from the terminal payload; it does not make streaming replayable.
The response model comes only from actual evidence; the request `Model` echoed
in `Response.model` is not such evidence. Cache hits clear evidence even in the
memory backend. Evidence-requesting calls continue to bypass cache reads and writes.

The OpenTelemetry exporter labels `shikumi.accounting.scope` as `logical-call`,
`transport-attempt`, or `transport-summary`. Filter by scope when summing numeric
costs. Attempt spans export `shikumi.call_id`, `shikumi.attempt`, classification as
error status, available token/cost values, and optional canonical JSON in
`shikumi.cost.basis` and `shikumi.usage.availability`. Summary spans export counts,
unknown-usage counts and truncation, without another numeric spending series.
An absent usage block does not become a numeric zero observation. The stored
`UsageRecord` supplements canonical usage JSON with exact rational costs; OTel
numeric costs remain floating point.

## Responses example: logical usage versus transport billing

The [compiled Responses workflow](../../shikumi-jitsurei/app/Responses.hs) combines
request defaults, native schema routing, a run-local bounded observer, completed
session checkpoints and explicit billing attachment to its trace. Its default
loopback run prints a validated Paris answer, one tool execution, 75 logical
tokens and three completed transport attempts. The fixture's zero USD value is
not a claim of free or exact billing: its quality output identifies missing
cache-write usage, absent service-tier evidence and unavailable pricing. Inspect
quality metadata alongside totals.

The HTTP regression also scripts one transient failure followed by success and
checks two attempt observations. A separate cache regression performs two logical
calls with only one HTTP request and one transport observation. These tests put
the observer below the cache; the example requests evidence and does not add a
cache. Replay and cached answers must never manufacture fresh billing attempts or
provider evidence. Normal CI uses a dummy key and retains no real opaque payloads.
