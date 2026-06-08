---
id: 6
slug: caching-subsystem
title: "Caching subsystem"
kind: exec-plan
created_at: 2026-06-08T02:44:17Z
intention: "intention_01ktjgkp10ef79vpwz1cmajek9"
master_plan: "docs/masterplans/1-shikumi-typed-lm-programming-framework.md"
---

# Caching subsystem

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Shikumi (仕組み — "the mechanism behind how something works") is a Haskell framework for
building language-model (LM) programs that behave like ordinary well-typed software. Every
call shikumi makes to a model provider costs money and takes seconds. This plan adds the
**caching subsystem**: a layer that remembers the answer a provider gave for a request and
returns that stored answer the next time the *exact same request* is made, without calling
the provider again.

After this change, a developer can wrap any program that issues LM calls so that repeated
identical calls are served from a cache. The user-visible behavior is concrete and
testable: if you issue the same request twice, the provider is contacted **once**; the
second call returns the **byte-for-byte identical typed result** instantly. With a
file-backed cache the memory survives process restart — you can run a program, kill the
process, start it again, issue the same request, and get the cached answer with no provider
call. With a server-backed cache (Redis or Postgres) the memory is shared across machines.

You can see it work three ways. First, a unit test that uses a *counting stub provider* (a
fake provider that increments a counter each time it is asked to produce a completion):
after two identical cached calls the counter reads `1`, not `2`. Second, a restart test
that writes a SQLite (an embedded, single-file SQL database) file in one process, opens it
in a second process, and reads the same answer back. Third, a small example program in the
test suite that prints the cache outcome (`HIT` or `MISS`) for each call.

The central artifact this plan owns is the **content-addressed cache key**: a single fixed
identifier (a hash) computed from everything about a request that could change the answer —
the model, the rendered prompt, the temperature, the system instructions, the tool
configuration, and the JSON-schema / response-format. "Content-addressed" means the key
*is* a fingerprint of the content, so identical requests always produce the same key and
different requests almost never collide. This key is shared with a sibling plan,
`docs/plans/7-hierarchical-tracing-observability-and-replay.md` (the tracing and replay
plan), which re-derives the same key to replay recorded calls deterministically. Because
two plans depend on it, this plan defines the key's exact fields, its exact serialization,
and its exact hash function so both agree byte-for-byte.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M0: `shikumi-cache` package skeleton compiles and is added to `cabal.project`.
- [ ] M1: `Shikumi.Cache.Key` — canonical serialization + blake3 hash; golden test pins the
      exact key bytes for a fixed request (the value EP-7 must reproduce).
- [ ] M2: `Shikumi.Cache.Types` (the `CachedResponse` value) + `Shikumi.Cache` effect
      (`lookupCache` / `storeCache`) defined; in-memory STM backend interpreter.
- [ ] M3: Spike — SQLite backend round-trips a `CachedResponse` (write, read) in a throwaway
      `Spec`; Redis backend round-trips against a live server or is skipped when absent.
- [ ] M4: `Shikumi.Cache.Backend.SQLite` promoted to a real backend with the versioned
      keyspace; survives process restart (write in one process, read in another).
- [ ] M5: `cachedLLM` interpreter wraps EP-1's `LLM` effect so `complete` is memoized; the
      counting-stub-provider test shows one provider call for two identical requests.
- [ ] M6: `shikumi-cache-redis` package (Redis backend) builds and round-trips.
- [ ] M7: `shikumi-cache-postgres` package (Postgres backend via hasql) builds and
      round-trips.
- [ ] M8: Cache versioning / invalidation: a key-namespace version constant; bumping it
      makes prior entries unreachable (test asserts a MISS after a bump).


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: The cache key is a BLAKE3 256-bit (32-byte) digest, rendered as 64 lowercase
  hex characters, computed over a canonical byte serialization of the request (defined in
  "The content-addressed cache key" below).
  Rationale: BLAKE3 is available on disk via mori (`mori registry show k0001/hs-blake3`),
  is fast, and offers a simple one-shot pure API `BLAKE3.hash :: Maybe Key -> [bytes] ->
  Digest n`. A 256-bit digest makes accidental collisions negligible. Hex rendering keeps
  the key printable, usable as a SQLite/Redis/Postgres text key, and easy to eyeball in
  traces. EP-7 (`docs/plans/7-hierarchical-tracing-observability-and-replay.md`) reuses the
  identical function, so the choice is documented here authoritatively.
  Date: 2026-06-07.
- Decision: Canonicalize the request to JSON using aeson with **sorted object keys** and no
  insignificant whitespace, then UTF-8 encode, then hash. We do not hash aeson's default
  `encode` output directly because aeson does not guarantee a stable key order across
  versions; we sort keys ourselves so the bytes are stable and EP-7 can reproduce them.
  Rationale: a stable, documented byte sequence is the entire point of a content-addressed
  key shared between two plans. Date: 2026-06-07.
- Decision: Ship the **memory** and **SQLite** backends in the core `shikumi-cache`
  package; ship **Redis** in `shikumi-cache-redis` and **Postgres** in
  `shikumi-cache-postgres` as separate packages.
  Rationale: keep heavy/optional dependencies (the `hedis` Redis client; the `hasql`
  Postgres client) out of the core so that a user who only wants memory + SQLite does not
  pull a Redis or Postgres driver. SQLite via `direct-sqlite` is a thin embedded binding
  with no server, so it belongs in core. This mirrors baikai's package split (a core
  `baikai` plus `baikai-claude`, `baikai-openai`, `baikai-trace-otel`). Date: 2026-06-07.
- Decision: Every stored key is prefixed with a key-namespace version string
  (`shikumi-cache/v1`). A schema or canonicalization change bumps this constant, which
  changes every key, which makes all prior entries unreachable (a clean invalidation
  without deleting rows). Date: 2026-06-07.
- Decision: `Shikumi.Cache` is an `effectful` dynamic effect with two operations
  (`lookupCache`, `storeCache`); the memoizing behavior lives in a separate interpreter
  `cachedLLM` that re-interprets EP-1's `LLM` effect. We keep the cache effect (storage)
  separate from the memoization policy (when to read/write) so a caller can use the cache
  store directly, or compose the policy interpreter, independently.
  Rationale: separation of mechanism (store) from policy (memoize) keeps each testable in
  isolation. Date: 2026-06-07.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This section gives a reader who knows nothing about the repository everything needed to
implement this plan.

### The repository today

The shikumi repository at `/Users/shinzui/Keikaku/bokuno/shikumi` currently contains only
`docs/` (these plans) and `.claude/` (tooling). There is no Haskell code, no
`cabal.project`, and no packages yet. The sibling plan
`docs/plans/1-shikumi-runtime-substrate-and-llm-effect-over-baikai.md` (referred to
throughout as "EP-1") is the **hard dependency** of this plan: it scaffolds the project
(creates `cabal.project`, the core `shikumi` package, and the toolchain) and defines the
two things this plan builds on — the `LLM` effect and the shikumi error type. This plan
assumes EP-1 has landed. If it has not, implement EP-1 first; do not duplicate its work.

### What baikai is (the transport layer underneath everything)

baikai (`/Users/shinzui/Keikaku/bokuno/baikai`, version `0.1.0.0`) is a published Haskell
library that owns the entire provider/transport layer: it dispatches a request to a model
provider (Claude, OpenAI, DeepSeek, OpenRouter, any OpenAI-compatible host) and returns a
response. shikumi sits *on top of* baikai and never reimplements provider dispatch. baikai
is pulled into shikumi's `cabal.project` with a `source-repository-package` stanza (it is
not on Hackage). The baikai types this plan touches are:

```haskell
-- baikai: the request inputs
data Context = Context
  { systemPrompt :: !(Maybe Text)
  , messages     :: !(Vector Message)
  , tools        :: !(Vector Tool)
  }

data Options = Options
  { maxTokens      :: !(Maybe Natural), temperature :: !(Maybe Double)
  , apiKey         :: !(Maybe ApiKeySource), timeoutMs :: !(Maybe Int)
  , headers        :: !(Map Text Text), metadata :: !(Map Text Value)
  , toolChoice     :: !(Maybe ToolChoice), cacheRetention :: !(Maybe CacheRetention)
  , thinking       :: !(Maybe ThinkingLevel)
  }
  -- NOTE: vanilla baikai has NO response-format / JSON-schema field; the sibling plan
  -- docs/plans/2-baikai-native-structured-output-extension.md adds one upstream. This
  -- plan's key serialization includes a response-format slot so it is forward-compatible
  -- whether or not that field exists yet (see "The content-addressed cache key").

data Model = Model
  { modelId :: !Text, name :: !Text, api :: !Api, provider :: !Text, baseUrl :: !Text
  , reasoning :: !Bool, input :: ![InputModality], cost :: !ModelCost
  , contextWindow :: !Natural, maxOutputTokens :: !Natural
  , headers :: !(Map Text Text), compat :: !Compat
  }

-- baikai: the response
data Response = Response
  { message :: !AssistantPayload, model :: !Model, api :: !Api
  , provider :: !Text, responseId :: !(Maybe Text), latencyMs :: !Integer
  }

data Usage = Usage
  { inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens :: !Natural
  , reasoningTokens :: !(Maybe Natural), totalTokens :: !Natural, cost :: !Cost
  }
data Cost = Cost { usd :: !Rational, breakdown :: !CostBreakdown }

data Tool = Tool { name :: !Text, description :: !Text, parameters :: !Value }
data ToolChoice = ToolChoiceAuto | ToolChoiceNone | ToolChoiceRequired
                | ToolChoiceSpecific !Text
```

A "Vector" is `Data.Vector.Vector` (a packed array). A "Value" is `Data.Aeson.Value` (a
parsed JSON value). "Natural" is a non-negative integer. The top module `Baikai` re-exports
the public surface; consult the exact field set by reading
`/Users/shinzui/Keikaku/bokuno/baikai/baikai/src` or running `mori registry docs
shinzui/baikai`. Do not guess field names — read the source.

### What EP-1 gives this plan (the `LLM` effect and error type)

EP-1 (`docs/plans/1-shikumi-runtime-substrate-and-llm-effect-over-baikai.md`) defines an
`effectful` effect named `LLM` that wraps baikai's `completeRequest`. "effectful" is a
Haskell effect-system library: an *effect* is a small interface of operations; an
*interpreter* gives those operations a concrete meaning; a computation's type lists the
effects it needs, e.g. `(LLM :> es) => Eff es Response`. EP-1's effect has (at least) a
completion operation shaped like this (read EP-1 for the exact constructor names — this plan
calls the operation `complete` and adapts if EP-1 named it differently):

```haskell
-- Defined by EP-1 in module Shikumi.LLM (names per EP-1; adapt if they differ).
data LLM :: Effect where
  Complete :: Model -> Context -> Options -> LLM m Response

complete :: (LLM :> es) => Model -> Context -> Options -> Eff es Response
complete model ctx opts = send (Complete model ctx opts)

-- EP-1's enumerated error type, raised via an Error effect. This plan reuses it; it does
-- NOT invent its own error type. Caching adds no new error cases for cache HITs (a hit
-- cannot fail); a corrupt cache row is treated as a MISS and re-fetched (see recovery).
data ShikumiError = ... -- provider failure, decode error, timeout, budget exceeded, ...
```

The critical fact: a single LM call is fully described by the triple `(Model, Context,
Options)`. This plan's cache key is a hash of exactly that triple (plus a response-format
slot and a version prefix). The cache stores the resulting `Response`. The memoizing
interpreter intercepts `Complete model ctx opts`, computes the key, returns a stored
`Response` on a hit, or calls through to EP-1's real interpreter and stores the result on a
miss.

### Terms of art used in this plan

- **Cache key / content-addressed key**: a fixed-length fingerprint (hash) of a request.
  Identical requests → identical key.
- **Canonical serialization**: turning a value into a *unique, stable* byte sequence so the
  same logical request always produces the same bytes (and therefore the same hash). The
  enemy is non-determinism: unsorted map keys, floating-point formatting differences,
  version-dependent encoders.
- **BLAKE3**: a fast cryptographic hash function. We use its Haskell binding `blake3`
  (`mori registry show k0001/hs-blake3`), module `BLAKE3`, function
  `hash :: Maybe (Key) -> [ba] -> Digest n` where `ba` is any `ByteArrayAccess` (a
  `ByteString` qualifies) and the digest length is chosen by a type annotation
  (`Digest 32` = 256 bits). `show` on a `Digest` yields lowercase hex.
- **Backend**: a concrete place the cache stores entries — an in-process map (memory), a
  single SQLite file, a Redis server, or a Postgres database.
- **STM**: Software Transactional Memory (`Control.Concurrent.STM`), Haskell's mechanism
  for safe concurrent in-memory mutation. The memory backend is a `TVar (Map Text
  CachedResponse)`.
- **SQLite**: an embedded SQL database that lives in one file with no server process. We
  use the `direct-sqlite` binding (module `Database.SQLite3`). mori does not have a SQLite
  binding registered (`mori registry search sqlite` returns nothing), so this plan adds
  `direct-sqlite` from Hackage directly; verify the latest version with `cabal info
  direct-sqlite` at implementation time and pin it in `cabal.project`. If `direct-sqlite`
  is unavailable, `sqlite-simple` (which depends on `direct-sqlite`) is an acceptable
  substitute; the schema below is identical.
- **Redis**: an in-memory key-value server. We use the `hedis` binding (`mori registry show
  informatikr/hedis`, module `Database.Redis`): `checkedConnect :: ConnectInfo -> IO
  Connection`, `defaultConnectInfo :: ConnectInfo`, `runRedis :: Connection -> Redis a ->
  IO a`, `get :: ByteString -> Redis (Either Reply (Maybe ByteString))`, `setex ::
  ByteString -> Integer -> ByteString -> Redis (Either Reply Status)`.
- **Postgres / hasql**: a SQL server and its Haskell client `hasql` (`mori registry show
  hasql/hasql`, module `Hasql.Session` / `Hasql.Connection` / `Hasql.Statement`).
- **HIT / MISS**: a *hit* is a key found in the cache (no provider call); a *miss* is a key
  absent (provider called, result stored).


## The content-addressed cache key

This is the load-bearing definition of the plan. It must be specified so precisely that the
sibling replay plan `docs/plans/7-hierarchical-tracing-observability-and-replay.md` can
reproduce the exact same bytes and therefore the exact same key. Implement this in module
`Shikumi.Cache.Key`.

### The fields that go into the key

A cache key is computed from exactly these request fields, and nothing else. Every field
that can change the model's answer is included; every field that cannot (latency, response
ids, wall-clock timestamps, retry counters, API keys, per-call metadata that is not sent to
the model) is excluded.

1. **Key-namespace version** — the literal string `shikumi-cache/v1`. Bumping this
   invalidates all entries (see "Cache versioning").
2. **Model id** — `modelId :: Text` from `Model` (e.g. `"claude-sonnet-4-6"`). We use
   `modelId` plus `provider` and `api` (the routing identity), *not* the full `Model` record
   — pricing/context-window fields do not change the answer and would cause spurious misses
   when baikai updates its catalog.
3. **Provider** — `provider :: Text` from `Model`.
4. **API tag** — `api :: Api` from `Model`, rendered via its `Show`/text form.
5. **System prompt** — `systemPrompt :: Maybe Text` from `Context`.
6. **Messages** — the `messages :: Vector Message` from `Context`, each message reduced to
   its semantic content (role + content blocks: text, thinking, tool calls/results). We
   serialize each message to its canonical JSON (see below). The full ordered sequence is
   included.
7. **Tools** — the `tools :: Vector Tool` from `Context`: for each tool, its `name`,
   `description`, and `parameters` (the JSON-schema `Value`). Order preserved as sent.
8. **Tool choice** — `toolChoice :: Maybe ToolChoice` from `Options`.
9. **Temperature** — `temperature :: Maybe Double` from `Options`.
10. **Max tokens** — `maxTokens :: Maybe Natural` from `Options`.
11. **Thinking level** — `thinking :: Maybe ThinkingLevel` from `Options`.
12. **Response format / JSON schema** — a `Maybe Value` slot. In vanilla baikai this is
    absent, so it is `Nothing`. When the structured-output plan
    `docs/plans/2-baikai-native-structured-output-extension.md` lands and shikumi attaches a
    schema, that schema `Value` goes here. Including the slot now keeps the key stable and
    forward-compatible: a request with no schema hashes identically before and after EP-2
    lands, and a request *with* a schema hashes differently (correctly so — a different
    schema yields a different answer).

Explicitly **excluded** (do not hash): `apiKey`, `timeoutMs`, `headers`, `metadata`,
`cacheRetention`, and everything on `Response` (latency, `responseId`). These do not affect
the model's output. `apiKey` in particular must never enter a key — it is a secret and two
users with different keys must share cache entries for the same logical request.

### The canonical serialization

The request is assembled into a single aeson `Value` (a JSON object), then serialized to a
canonical byte sequence, then hashed. The canonical form is **a JSON object with keys
sorted lexicographically by Unicode code point, no insignificant whitespace, UTF-8
encoded**. The top-level object is exactly:

```json
{
  "api": "AnthropicMessages",
  "maxTokens": 1024,
  "messages": [ ... canonical message values ... ],
  "model": "claude-sonnet-4-6",
  "provider": "anthropic",
  "responseFormat": null,
  "systemPrompt": "You are helpful.",
  "temperature": 0.0,
  "thinking": null,
  "toolChoice": null,
  "tools": [ ... canonical tool values ... ],
  "version": "shikumi-cache/v1"
}
```

Rules that make this reproducible (EP-7 must follow them identically):

- **Object key ordering**: keys are emitted in ascending Unicode code-point order at every
  level (the example above is already sorted). We do not rely on aeson's `encode`, whose key
  order is not contractually stable; instead we build the canonical bytes ourselves with a
  recursive canonicalizer that sorts every `Object`'s keys. A reference implementation:

  ```haskell
  -- Shikumi.Cache.Key
  import qualified Data.Aeson as A
  import qualified Data.Aeson.KeyMap as KM
  import qualified Data.ByteString.Builder as BB
  import qualified Data.ByteString.Lazy as BL
  import           Data.List (sortOn)

  -- Render a Value to canonical JSON bytes: sorted object keys, no extra whitespace.
  canonicalJSON :: A.Value -> BL.ByteString
  canonicalJSON = BB.toLazyByteString . go
    where
      go (A.Object o) =
        let kvs = sortOn fst [ (A.toText k, v) | (k, v) <- KM.toList o ]
        in  BB.char7 '{'
              <> mconcat (intersperse' (BB.char7 ',')
                   [ encodeStr k <> BB.char7 ':' <> go v | (k, v) <- kvs ])
              <> BB.char7 '}'
      go (A.Array xs) =
        BB.char7 '[' <> mconcat (intersperse' (BB.char7 ',') (map go (toList xs)))
          <> BB.char7 ']'
      go v = A.fromEncoding (A.toEncoding v)  -- scalars: aeson's escaping is stable
  ```

  (`intersperse'` is list `intersperse` adapted to `Builder`; the helper is trivial.) The
  point is: **we control object key order; scalars (strings, numbers, bools, null) reuse
  aeson's encoding, whose escaping rules are stable.**

- **Numbers**: `temperature` is a `Double` placed into the JSON as an aeson `Number`. To
  avoid any floating-point formatting ambiguity, temperature is normalized before
  serialization by converting through `Scientific` with a fixed representation: store it as
  the `Scientific` produced by `realToFrac :: Double -> Scientific` and let aeson render it.
  Two requests that differ only in how a `Double` was constructed but are `==` produce the
  same `Scientific` and therefore the same bytes. `maxTokens` and other integral fields are
  emitted as integers (no decimal point).

- **Optional fields**: a `Maybe` that is `Nothing` is emitted as JSON `null` (never omitted)
  so the field set is always identical and the sorted-key output is positionally stable.

- **Messages**: each `Message` is converted to a small canonical object
  `{"role": <text>, "content": <canonical content blocks>}` where content blocks are the
  ordered list of `{"type": "...", ...}` objects for text / thinking / tool-call /
  tool-result. Reuse baikai's existing `ToJSON` for messages if and only if it is stable;
  otherwise build the object explicitly in `Shikumi.Cache.Key`. **Decision for this plan**:
  build it explicitly (do not depend on baikai's wire `ToJSON`, which may change to match a
  provider's API). The explicit builder lives in `messageToCanonical :: Message -> Value`.

- **Tools**: each `Tool` becomes `{"name": ..., "description": ..., "parameters": <schema
  Value>}`. The `parameters` schema `Value` is itself run through `canonicalJSON` ordering
  when the whole top-level value is canonicalized — no special handling needed.

### The hash

The canonical bytes are hashed with BLAKE3 to a 32-byte digest and rendered as 64 lowercase
hex characters. The key type is a `newtype` so it cannot be confused with arbitrary text:

```haskell
-- Shikumi.Cache.Key
import qualified BLAKE3 as B
import qualified Data.ByteString.Lazy as BL

newtype CacheKey = CacheKey { unCacheKey :: Text }
  deriving stock (Eq, Ord, Show)

cacheKey :: Model -> Context -> Options -> Maybe Value -> CacheKey
cacheKey model ctx opts responseFormat =
  let value  = requestToCanonicalValue model ctx opts responseFormat
      bytes  = BL.toStrict (canonicalJSON value)
      digest = B.hash Nothing [bytes] :: B.Digest 32
  in  CacheKey (Text.pack (show digest))   -- show Digest = lowercase hex, 64 chars

-- requestToCanonicalValue builds the JSON object shown above (with the version field).
```

The stored row/value is keyed by `unCacheKey` (the 64-hex string). Because the version
prefix `shikumi-cache/v1` is *inside* the hashed content, the hex string already encodes the
namespace version; backends store the hex key directly without an extra prefix column. (A
backend MAY additionally prefix Redis keys with `shikumi:` for operational namespacing — see
the Redis backend — but that prefix is outside the content hash and does not affect EP-7.)

EP-7's replay engine reuses `Shikumi.Cache.Key.cacheKey` verbatim (it depends on
`shikumi-cache`). The golden test in Milestone 1 pins the exact hex output for a fixed
request so any future drift in canonicalization is caught immediately.


## The cache value (what is stored)

A cache entry stores enough to reconstruct the typed result *and* the accounting, so a HIT
is indistinguishable from a fresh call to downstream consumers (evaluation, cost reporting).
Implement in `Shikumi.Cache.Types`:

```haskell
-- Shikumi.Cache.Types
data CachedResponse = CachedResponse
  { response   :: !Baikai.Response   -- the full provider response (message, usage, cost...)
  , storedAt   :: !UTCTime           -- when this entry was written (operational metadata)
  , keyVersion :: !Text              -- "shikumi-cache/v1": guards against decoding a row
  }                                  --   written under a different schema version
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)
```

`Baikai.Response` must have `ToJSON`/`FromJSON`. If baikai does not export aeson instances
for `Response`/`Usage`/`Cost`/`AssistantPayload`, this plan adds **orphan** instances in
`Shikumi.Cache.Types` (or, preferably, a dedicated `Shikumi.Cache.Orphans` module) deriving
them structurally with `Generic`. Verify by reading baikai's source whether instances exist;
if they do, use them. The serialized form of `CachedResponse` (its JSON, encoded with
aeson's normal `encode`) is the *value* stored in every backend (memory stores the Haskell
value directly; SQLite/Redis/Postgres store the JSON bytes). Decoding a value whose
`keyVersion` does not match the current namespace version is treated as a MISS (defensive:
never return a stale-schema entry).


## The cache effect and the memoizing interpreter

Two separate pieces, in module `Shikumi.Cache`:

```haskell
-- Shikumi.Cache : the storage effect (mechanism, not policy)
data Cache :: Effect where
  LookupCache :: CacheKey -> Cache m (Maybe CachedResponse)
  StoreCache  :: CacheKey -> CachedResponse -> Cache m ()

type instance DispatchOf Cache = Dynamic

lookupCache :: (Cache :> es) => CacheKey -> Eff es (Maybe CachedResponse)
lookupCache = send . LookupCache

storeCache :: (Cache :> es) => CacheKey -> CachedResponse -> Eff es ()
storeCache k v = send (StoreCache k v)
```

Each backend provides an interpreter `runCacheX :: (IOE :> es) => Handle -> Eff (Cache :
es) a -> Eff es a` that discharges the `Cache` effect against its storage.

The memoization *policy* is a re-interpreter of EP-1's `LLM` effect that uses the `Cache`
effect:

```haskell
-- Shikumi.Cache : the policy. Re-interprets LLM so Complete is memoized.
cachedLLM
  :: (Cache :> es, LLM :> es)
  => Eff es a -> Eff es a
cachedLLM = interpose $ \_ -> \case
  Complete model ctx opts -> do
    let key = cacheKey model ctx opts Nothing   -- Nothing until EP-2's schema slot is wired
    hit <- lookupCache key
    case hit of
      Just cr | keyVersion cr == currentKeyVersion -> pure (response cr)
      _ -> do
        resp <- complete model ctx opts          -- delegates to the underlying LLM handler
        now  <- liftIO getCurrentTime
        storeCache key (CachedResponse resp now currentKeyVersion)
        pure resp
```

`interpose` is effectful's combinator for wrapping an already-handled effect (here `LLM`)
with extra behavior while still delegating to the original handler via the captured handler
or by re-`send`ing. The exact spelling (`interpose` vs. `interpret` over a fresh `LLM`)
depends on EP-1's interpreter shape; the milestone's acceptance test (one provider call for
two requests) is the contract, not the spelling. `currentKeyVersion = "shikumi-cache/v1"`.

A program then runs as: `runCacheSQLite handle . cachedLLM . runLLM provider $ program`,
reading inside-out — the real `LLM` interpreter is innermost, `cachedLLM` wraps it,
`runCacheSQLite` provides storage.


## Plan of Work

The work proceeds in nine milestones (M0–M8), each independently verifiable with `cabal
test`. Milestones build strictly on their predecessors. The two riskiest backends (SQLite
and Redis) get an explicit **spike** milestone (M3) before the full interpreter is wired, so
that we prove round-tripping works in isolation before committing the design.

### Milestone M0 — package skeleton

Scope: create the `shikumi-cache` package directory with a `.cabal` file, a `library`
stanza listing modules `Shikumi.Cache`, `Shikumi.Cache.Key`, `Shikumi.Cache.Types`,
`Shikumi.Cache.Backend.Memory`, and `Shikumi.Cache.Backend.SQLite`, and add it to the
repository `cabal.project`. Modules may be empty stubs that compile. At the end, `cabal
build shikumi-cache` succeeds. Acceptance: `cabal build shikumi-cache` exits 0.

Place the package at `/Users/shinzui/Keikaku/bokuno/shikumi/shikumi-cache/`. The `.cabal`
declares `default-language: GHC2024` (matching baikai) and `build-depends` on `base`,
`shikumi` (EP-1's core package), `baikai`, `effectful`, `effectful-core`, `aeson`, `text`,
`bytestring`, `containers`, `stm`, `time`, `scientific`, `blake3`, and `direct-sqlite`.

### Milestone M1 — the cache key (the shared contract)

Scope: implement `Shikumi.Cache.Key` fully: `CacheKey`, `canonicalJSON`,
`requestToCanonicalValue`, `messageToCanonical`, and `cacheKey`. Write a **golden test**
that constructs a fixed `(Model, Context, Options)` (a deterministic literal — a known model
id, a one-message context, temperature `0.0`, no tools) and asserts (a) the canonical JSON
bytes equal a literal expected string, and (b) the resulting `CacheKey` equals a literal
64-hex string. This pins the contract EP-7 must reproduce. At the end, the golden test
passes and the expected hex is recorded in this plan's Concrete Steps.

Acceptance: `cabal test shikumi-cache-test --test-options='--match "/cache key/"'` passes;
the test would fail if anyone reorders fields, changes whitespace, or swaps the hash.

### Milestone M2 — value type, effect, and memory backend

Scope: implement `Shikumi.Cache.Types` (`CachedResponse` + JSON instances, adding baikai
orphan instances if needed), `Shikumi.Cache` (the `Cache` effect, `lookupCache`,
`storeCache`), and `Shikumi.Cache.Backend.Memory` (`runCacheMemory :: (IOE :> es) => TVar
(Map Text CachedResponse) -> Eff (Cache : es) a -> Eff es a`, plus `newMemoryCache :: IO
(TVar (Map Text CachedResponse))`). A test stores a `CachedResponse` under a key and reads
it back; a second lookup under a different key returns `Nothing`.

Acceptance: `cabal test shikumi-cache-test --test-options='--match "/memory backend/"'`
passes (store-then-lookup returns the value; absent key returns `Nothing`).

### Milestone M3 — spike: SQLite and Redis round-trip (PROTOTYPING)

Scope (explicitly labeled prototyping): before wiring the full interpreter, prove the two
risky backends can serialize and round-trip a `CachedResponse`. This milestone is a
throwaway-grade spike — it may use a bare-bones schema and inline connection handling — its
only job is to de-risk the libraries.

For **SQLite**: open a temporary file with `Database.SQLite3.open`, `CREATE TABLE IF NOT
EXISTS cache(key TEXT PRIMARY KEY, value BLOB NOT NULL)`, `INSERT` a serialized
`CachedResponse` under a `CacheKey`, `SELECT` it back, decode it, and assert equality. Use a
temp file from `System.IO.Temp` so the test is hermetic. This proves both the binding works
*and* that the value survives a write/read cycle. As a bonus assertion, close the database
and reopen the same file in the same test to prove durability across handles (a preview of
M4's restart test).

For **Redis**: connect with `checkedConnect defaultConnectInfo`, `setex` the serialized
value under the hex key, `get` it back, decode, assert equality. Because Redis needs a
running server, the test must **skip gracefully** when no server is reachable: catch the
connection exception and mark the test pending (tasty `expectFailBecause`/`pendingWith`-style
skip) rather than failing CI. Document in Concrete Steps how to start a local Redis
(`redis-server --port 6379` or `docker run -p 6379:6379 redis`) to run the test for real.

Acceptance: `cabal test shikumi-cache-spike` passes with SQLite round-tripping; the Redis
case passes when a server is up and is skipped (not failed) when it is down. The spike's
findings (e.g. exact `direct-sqlite` calls, whether to store TEXT vs BLOB) are recorded in
Surprises & Discoveries and promoted into the real backends in M4/M6.

### Milestone M4 — SQLite backend (real) with versioned keyspace and restart durability

Scope: promote the spike into `Shikumi.Cache.Backend.SQLite`: a `runCacheSQLite` interpreter
over an opened database handle, an `openSQLiteCache :: FilePath -> IO SQLiteCache` /
`closeSQLiteCache` pair, schema creation on open, and prepared-statement-based
lookup/store. The schema is:

```sql
CREATE TABLE IF NOT EXISTS shikumi_cache (
  key        TEXT PRIMARY KEY,   -- the 64-hex CacheKey (already version-namespaced via the
                                 --   version field baked into the hash)
  value      BLOB NOT NULL,      -- UTF-8 JSON encoding of CachedResponse
  stored_at  TEXT NOT NULL       -- ISO-8601 UTCTime, for eviction/inspection
);
```

`storeCache` uses `INSERT OR REPLACE` (upsert) so re-storing a key is idempotent.
`lookupCache` selects by key, decodes the BLOB, returns `Nothing` on a decode failure or a
`keyVersion` mismatch (defensive — never serve a stale-schema row). Then the headline test:
a **restart durability** test that, in one process action, opens a fresh temp-file cache,
stores an entry, and closes it; then in a *separate* process opens the same file and reads
the entry back. Use two separate executable invocations (a tiny test driver run twice with
an env var or argument selecting "write" vs "read" phase) or, acceptably, two sequential
`open/close` cycles in one test if a true subprocess is awkward — but a real subprocess is
preferred because it proves nothing lingers in process memory. Concrete Steps shows the
subprocess approach.

Acceptance: `cabal test shikumi-cache-test --test-options='--match "/sqlite restart/"'`
passes: the value written by phase one is read by phase two from disk.

### Milestone M5 — the memoizing interpreter (the headline behavior)

Scope: implement `cachedLLM` in `Shikumi.Cache`. Add a **counting stub provider** to the
test suite: a fake `LLM` interpreter `runLLMCounting :: (IOE :> es) => IORef Int -> Response
-> Eff (LLM : es) a -> Eff es a` that, on each `Complete`, increments the `IORef` and
returns a fixed `Response`. The acceptance test runs a computation that calls `complete`
twice with the *same* `(Model, Context, Options)` under `cachedLLM` plus a memory cache plus
the counting stub, then asserts: the counter is `1` (provider hit once), and both returned
`Response` values are equal. A control test calls `complete` with two *different* requests
and asserts the counter is `2`.

Acceptance: `cabal test shikumi-cache-test --test-options='--match "/memoize/"'` passes:
same request twice → counter `1`, identical outputs; different requests → counter `2`.

### Milestone M6 — `shikumi-cache-redis` package

Scope: a new package `/Users/shinzui/Keikaku/bokuno/shikumi/shikumi-cache-redis/` depending
on `shikumi-cache` and `hedis`, module `Shikumi.Cache.Backend.Redis`. Provide
`openRedisCache :: ConnectInfo -> IO RedisCache` (wrapping `checkedConnect`) and
`runCacheRedis :: (IOE :> es) => RedisCache -> Eff (Cache : es) a -> Eff es a`. Keyspace:
each entry is stored under the Redis string key `"shikumi:cache:" <> unCacheKey` (the
`shikumi:cache:` prefix is operational namespacing, outside the content hash). The value is
the UTF-8 JSON of `CachedResponse`. `storeCache` uses `setex` with a configurable TTL
(time-to-live in seconds; default e.g. 7 days) so Redis can evict old entries; `lookupCache`
uses `get`, decoding the bytes (a `Nothing` from Redis or a decode failure → cache MISS).
The package's test round-trips through a live server and **skips when none is reachable**
(same graceful-skip pattern as M3).

Acceptance: `cabal test shikumi-cache-redis-test` passes against a running Redis (store via
`cachedLLM` + counting stub → one provider call; second process/connection reads the entry);
skipped cleanly when Redis is down.

### Milestone M7 — `shikumi-cache-postgres` package

Scope: a new package `/Users/shinzui/Keikaku/bokuno/shikumi/shikumi-cache-postgres/`
depending on `shikumi-cache` and `hasql`, module `Shikumi.Cache.Backend.Postgres`. Provide
`openPostgresCache :: Hasql.Connection.Settings -> IO PostgresCache` and `runCachePostgres
:: (IOE :> es) => PostgresCache -> Eff (Cache : es) a -> Eff es a`. Schema (created on open,
idempotently):

```sql
CREATE TABLE IF NOT EXISTS shikumi_cache (
  key        text PRIMARY KEY,
  value      jsonb NOT NULL,
  stored_at  timestamptz NOT NULL DEFAULT now()
);
```

`storeCache` is `INSERT ... ON CONFLICT (key) DO UPDATE SET value = excluded.value,
stored_at = excluded.stored_at` (upsert). `lookupCache` selects `value` by key. Use hasql
`Statement`/`Session` with explicit encoders/decoders (text param, jsonb value). The test
round-trips against a Postgres instance and **skips when none is reachable**; document using
the user's `ephemeral-pg` (`mori registry show shinzui/ephemeral-pg`) to spin up a throwaway
database for the test, or a `PG_CONN` env var pointing at a local server.

Acceptance: `cabal test shikumi-cache-postgres-test` passes against a running Postgres
(round-trip via `cachedLLM` + counting stub → one provider call); skipped cleanly when
absent.

### Milestone M8 — cache versioning / invalidation

Scope: make invalidation a first-class, tested behavior. Centralize the namespace version as
`currentKeyVersion :: Text` (= `"shikumi-cache/v1"`) in `Shikumi.Cache.Key`, used both in
the hashed `version` field *and* in `CachedResponse.keyVersion`. Write a test that: stores an
entry computed with `v1`; then re-derives the key as if the version were bumped to `v2`
(parameterize `requestToCanonicalValue` over the version string for the test) and asserts the
lookup under the `v2` key is a MISS — i.e. bumping the version makes prior entries
unreachable without deleting them. Also assert that decoding a `CachedResponse` whose
`keyVersion` field is `"shikumi-cache/v0"` yields a MISS at the interpreter level.

Acceptance: `cabal test shikumi-cache-test --test-options='--match "/versioning/"'` passes:
a version bump turns a former HIT into a MISS.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/shikumi` unless
stated. EP-1 must have created `cabal.project` and the `shikumi` package first.

Create the core cache package and register it:

```bash
mkdir -p shikumi-cache/src/Shikumi/Cache/Backend shikumi-cache/test
# author shikumi-cache/shikumi-cache.cabal (library + test-suite stanzas, deps per M0)
# then add packages: shikumi-cache to cabal.project (alongside shikumi).
cabal build shikumi-cache
```

Expected (M0):

```text
Building library for shikumi-cache-0.1.0.0..
... Linking ...
```

Run the key golden test (M1). After implementing `Shikumi.Cache.Key`, obtain the real
expected hex by running the test once, observing the printed actual key, and pasting it back
into the test literal and into this plan. The transcript should look like:

```text
$ cabal test shikumi-cache-test --test-options='--match "/cache key/"'
cache key
  canonical JSON is byte-stable [✔]
  cacheKey is the pinned 64-hex digest [✔]
```

Record the pinned key here once known (this is the value EP-7 must reproduce):

```text
cacheKey(fixedRequest) = <PASTE 64-hex BLAKE3 digest here after first run>
canonicalJSON(fixedRequest) = {"api":"AnthropicMessages","maxTokens":1024,...}
```

Run the spike (M3), starting a local Redis first if you want the Redis case to run for real:

```bash
redis-server --port 6379 &     # or: docker run --rm -p 6379:6379 redis
cabal test shikumi-cache-spike
```

Expected (M3) when Redis is up:

```text
spike
  sqlite round-trips a CachedResponse [✔]
  sqlite survives close/reopen of the same file [✔]
  redis round-trips a CachedResponse [✔]
```

Expected (M3) when Redis is down — the Redis case is skipped, not failed:

```text
spike
  sqlite round-trips a CachedResponse [✔]
  sqlite survives close/reopen of the same file [✔]
  redis round-trips a CachedResponse [PENDING: no Redis at 127.0.0.1:6379]
```

Run the restart-durability test (M4). The test driver writes in one subprocess and reads in
another against the same temp file:

```bash
cabal test shikumi-cache-test --test-options='--match "/sqlite restart/"'
```

Expected (M4):

```text
sqlite restart
  entry written in phase one is read from disk in phase two [✔]
```

Run the headline memoization test (M5):

```bash
cabal test shikumi-cache-test --test-options='--match "/memoize/"'
```

Expected (M5):

```text
memoize
  same request twice contacts the provider once [✔]
  cached output equals the live output [✔]
  two different requests contact the provider twice [✔]
```

Build and test the optional backends (M6, M7), with servers running:

```bash
cabal build shikumi-cache-redis shikumi-cache-postgres
cabal test shikumi-cache-redis-test       # needs Redis; skips if absent
cabal test shikumi-cache-postgres-test    # needs Postgres; skips if absent
```

Run the versioning test (M8):

```bash
cabal test shikumi-cache-test --test-options='--match "/versioning/"'
```

Expected (M8):

```text
versioning
  bumping the namespace version turns a HIT into a MISS [✔]
  a CachedResponse with a foreign keyVersion is ignored [✔]
```


## Validation and Acceptance

The plan is accepted when all of the following observable behaviors hold, each demonstrated
by a named `cabal test` invocation listed in Concrete Steps:

1. **Memoization (the core promise).** With a counting stub provider, issuing the *same*
   `(Model, Context, Options)` twice through `cachedLLM` results in exactly **one** provider
   call (counter `= 1`) and the two returned `Response` values are equal. Issuing two
   *different* requests results in **two** provider calls (counter `= 2`). This is the M5
   test.
2. **Durable cache survives process restart.** A SQLite-backed cache file written in one OS
   process is read back, with the identical decoded `CachedResponse`, by a second OS process
   opening the same file. This is the M4 test.
3. **Key stability across plans.** The canonical JSON and the BLAKE3 hex key for a fixed
   request are byte-for-byte the pinned literals; this is the contract EP-7
   (`docs/plans/7-hierarchical-tracing-observability-and-replay.md`) reproduces. This is the
   M1 golden test.
4. **All four backends round-trip** a `CachedResponse`: memory (M2), SQLite (M3/M4), Redis
   (M3/M6), Postgres (M7). Server-backed tests skip cleanly when no server is present, so CI
   without a Redis/Postgres remains green while still exercising memory + SQLite fully.
5. **Versioning invalidates.** Bumping the namespace version makes prior entries
   unreachable (M8).

A reviewer can run `cabal test shikumi-cache-test` to exercise items 1, 2, 3, 5 and the
memory/SQLite parts of item 4 with no external services. The Redis/Postgres tests add the
remaining coverage when servers are available.


## Idempotence and Recovery

Every step is safe to repeat. `cabal build` / `cabal test` are naturally idempotent.
Backend schema creation uses `CREATE TABLE IF NOT EXISTS`, so re-opening a cache never
errors. `storeCache` is an upsert (`INSERT OR REPLACE` for SQLite, `ON CONFLICT DO UPDATE`
for Postgres, `setex` for Redis), so writing the same key twice is harmless and just
refreshes the entry.

Cache corruption is non-fatal by design: if a stored value fails to decode, or its
`keyVersion` does not match `currentKeyVersion`, `lookupCache` returns `Nothing`, the
memoizer treats it as a MISS, calls the provider, and overwrites the bad entry. This means a
schema change (bump `currentKeyVersion`) requires no migration and no manual deletion — old
entries simply become unreachable and are eventually overwritten or evicted (Redis TTL,
SQLite/Postgres `stored_at` for an optional future eviction pass).

To recover a clean slate: delete the SQLite file, `FLUSHDB` Redis, or `TRUNCATE
shikumi_cache` in Postgres — none of which any test depends on persisting across runs (tests
use temp files / unique key namespaces).

If the spike (M3) reveals that `direct-sqlite` is unavailable in the toolchain, fall back to
`sqlite-simple` (it re-exports `direct-sqlite`); the schema and round-trip logic are
unchanged. Record the substitution in the Decision Log if made.


## Interfaces and Dependencies

Libraries (all located via mori unless noted; never search `/nix/store` or `/`):

- **`shikumi`** (EP-1's core package): provides the `LLM` effect, `complete`, and the
  shikumi error type. Hard dependency.
- **`baikai`** (`mori registry show shinzui/baikai`): provides `Model`, `Context`,
  `Options`, `Response`, `Usage`, `Cost`, `Message`, `Tool`, `ToolChoice`. Pulled via
  `source-repository-package` in `cabal.project`.
- **`effectful` / `effectful-core`** (`mori registry show effectful/effectful`): the effect
  system (`Effect`, `Eff`, `:>`, `send`, `interpret`, `interpose`, `Dynamic`, `IOE`).
- **`blake3`** (`mori registry show k0001/hs-blake3`, module `BLAKE3`): the hash. Function
  `hash :: ByteArrayAccess ba => Maybe (Key) -> [ba] -> Digest n`; `show (d :: Digest 32)`
  is lowercase hex.
- **`aeson`** (`Value`, `encode`, `ToJSON`, `FromJSON`, `Data.Aeson.KeyMap`),
  **`scientific`** (stable number normalization), **`bytestring`**, **`text`**,
  **`containers`** (`Data.Map`), **`stm`** (`TVar`), **`time`** (`UTCTime`,
  `getCurrentTime`), **`temporary`** (`System.IO.Temp`, test only).
- **`direct-sqlite`** (Hackage; not in mori — confirm version with `cabal info
  direct-sqlite`, module `Database.SQLite3`): embedded SQLite, in core `shikumi-cache`.
- **`hedis`** (`mori registry show informatikr/hedis`, module `Database.Redis`): Redis
  client, only in `shikumi-cache-redis`.
- **`hasql`** (`mori registry show hasql/hasql`, modules `Hasql.Connection`,
  `Hasql.Session`, `Hasql.Statement`): Postgres client, only in `shikumi-cache-postgres`.
  Optionally `shinzui/ephemeral-pg` for hermetic test databases.

Types and signatures that must exist at the end of each milestone (full module paths):

- End of M1 — `Shikumi.Cache.Key`:
  `newtype CacheKey = CacheKey { unCacheKey :: Text }`;
  `cacheKey :: Baikai.Model -> Baikai.Context -> Baikai.Options -> Maybe Aeson.Value ->
  CacheKey`;
  `canonicalJSON :: Aeson.Value -> Data.ByteString.Lazy.ByteString`;
  `requestToCanonicalValue :: Baikai.Model -> Baikai.Context -> Baikai.Options -> Maybe
  Aeson.Value -> Aeson.Value`;
  `currentKeyVersion :: Text`.
- End of M2 — `Shikumi.Cache.Types`:
  `data CachedResponse = CachedResponse { response :: Baikai.Response, storedAt :: UTCTime,
  keyVersion :: Text }` with `ToJSON`/`FromJSON`.
  `Shikumi.Cache`: `data Cache :: Effect` with `LookupCache`/`StoreCache`; `lookupCache ::
  (Cache :> es) => CacheKey -> Eff es (Maybe CachedResponse)`; `storeCache :: (Cache :> es)
  => CacheKey -> CachedResponse -> Eff es ()`.
  `Shikumi.Cache.Backend.Memory`: `newMemoryCache :: IO (TVar (Map Text CachedResponse))`;
  `runCacheMemory :: (IOE :> es) => TVar (Map Text CachedResponse) -> Eff (Cache : es) a ->
  Eff es a`.
- End of M4 — `Shikumi.Cache.Backend.SQLite`:
  `data SQLiteCache`; `openSQLiteCache :: FilePath -> IO SQLiteCache`; `closeSQLiteCache ::
  SQLiteCache -> IO ()`; `runCacheSQLite :: (IOE :> es) => SQLiteCache -> Eff (Cache : es) a
  -> Eff es a`.
- End of M5 — `Shikumi.Cache`:
  `cachedLLM :: (Cache :> es, LLM :> es) => Eff es a -> Eff es a`.
- End of M6 — `Shikumi.Cache.Backend.Redis` (package `shikumi-cache-redis`):
  `data RedisCache`; `openRedisCache :: Database.Redis.ConnectInfo -> IO RedisCache`;
  `runCacheRedis :: (IOE :> es) => RedisCache -> Eff (Cache : es) a -> Eff es a`.
- End of M7 — `Shikumi.Cache.Backend.Postgres` (package `shikumi-cache-postgres`):
  `data PostgresCache`; `openPostgresCache :: Hasql.Connection.Settings -> IO
  PostgresCache`; `runCachePostgres :: (IOE :> es) => PostgresCache -> Eff (Cache : es) a ->
  Eff es a`.
- End of M8 — versioning is centralized in `currentKeyVersion` and exercised by the
  versioning test; no new public type, but the invalidation behavior is guaranteed.


## Revision History

- 2026-06-07: Initial authoring of the full plan from the skeleton. Defined the
  content-addressed cache key (fields, canonical JSON serialization with sorted keys, BLAKE3
  256-bit hex digest, `shikumi-cache/v1` namespace), the `Cache` effect and `cachedLLM`
  memoizing interpreter, the four backends (memory + SQLite in core; Redis and Postgres as
  separate packages), and nine milestones M0–M8 each verifiable with `cabal test`, including
  the M3 SQLite/Redis prototyping spike. Reason: flesh out EP-6 per the MasterPlan and the
  shared research dossier; the key definition is authored here authoritatively because the
  replay plan (`docs/plans/7-hierarchical-tracing-observability-and-replay.md`) reuses it
  byte-for-byte.
