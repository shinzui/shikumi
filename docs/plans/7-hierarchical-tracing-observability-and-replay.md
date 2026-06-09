---
id: 7
slug: hierarchical-tracing-observability-and-replay
title: "Hierarchical tracing observability and replay"
kind: exec-plan
created_at: 2026-06-08T02:44:17Z
intention: "intention_01ktjgkp10ef79vpwz1cmajek9"
master_plan: "docs/masterplans/1-shikumi-typed-lm-programming-framework.md"
---

# Hierarchical tracing observability and replay

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Today, when you run a multi-step language-model (LM) program in shikumi — say a two-stage
pipeline that first drafts an answer and then critiques it — you get the final answer and
nothing else. You cannot see *which* sub-call produced *which* intermediate value, how long
each step took, what each step cost, or how the steps nest inside one another. The
underlying transport library, **baikai** (the user's published "媒介 / mediation" Haskell
library that shikumi sits on top of, located at `/Users/shinzui/Keikaku/bokuno/baikai`),
emits only a *flat* list of per-call trace events with no notion of a parent or a child.
Two provider calls that belong to the same pipeline look exactly like two calls that have
nothing to do with each other.

After this ExecPlan is implemented, a shikumi user gains two concrete, demonstrable
capabilities:

1. **Hierarchical (nested) tracing.** Running any program inside the new
   `Shikumi.Trace` effect produces a *tree* of spans. A "span" here means one timed,
   attributed record of a unit of work — a whole program run, a module such as `predict`,
   a combinator such as `Pipeline`, or a single LM call. Each span records its parent, so a
   two-stage pipeline yields a root span with two child spans (each itself containing the
   actual LM call as a grandchild). Each span captures model, prompt, response, latency,
   token counts, dollar cost, retry count, tool calls, and its parent's identifier. The user
   can pretty-print this tree to the terminal and immediately see the structure of their
   program's execution. There is also an OpenTelemetry (OTel) adapter that emits the same
   tree as properly-nested OTel spans, so the tree shows up in tools like Jaeger or
   Honeycomb with real parent/child nesting (not the flat one-span-per-call that baikai's
   own OTel adapter produces).

2. **Deterministic replay.** The tree can be *serialized to disk* as a self-contained trace
   file. Given that file, the user can re-run the exact same program with the network
   physically disabled and get byte-for-byte identical typed outputs, because every LM call
   is served from the recorded response instead of hitting a provider. This is the
   foundation for reproducible debugging ("re-run yesterday's failing pipeline offline"),
   regression tests that need no API keys or budget, and golden-output testing. If the
   program asks for an LM call that is *not* present in the trace (a "divergence" — the
   replayed program tried to do something the recording never saw), replay reports exactly
   which call diverged, in plain language, rather than silently hitting the network or
   returning a wrong answer.

How to see it working, in one sentence: run the example program `shikumi-trace-demo`, watch
it print a nested trace tree for a two-stage pipeline, watch it write `trace.json`, then run
it again in `--replay trace.json` mode with `SHIKUMI_OFFLINE=1` set and observe the same
final output produced with zero provider calls (the provider registry is wired to a handler
that throws if invoked, proving the network was never touched).


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M0 (spike): `shikumi-trace` package skeleton stood up and added to `cabal.project`;
      the **interpose-plus-span-stack** mechanism is proven by `Shikumi.Trace.Internal.Spike.runSpike`
      — two LM calls nested under two distinct span ids come back tagged with the id that was on
      top of the stack when each ran. **Done (2026-06-08).** Mechanism changed from the planned
      baikai-`TraceSink` capture to an `interpose` over EP-1's `LLM` effect (EP-1 exposes no sink
      seam; `LLM.complete` returns the full `Response`) — see Decision Log. `cabal test
      shikumi-trace --test-options='-p spike'` green (1 test).
- [x] M1: the `Shikumi.Trace` effect and in-memory hierarchical `TraceTree` are delivered —
      `SpanKind`/`SpanId`/`SpanAttrs`/`Span`/`TraceTree`, `withSpan`/`currentSpanId`/`bumpRetry`/
      `recordToolCall`/`annotateSpan`, `runTrace :: Eff (Trace : es) a -> Eff es (a, TraceTree)`,
      `childrenOf`, and `renderTree`. LM-call leaves are captured by `tracedLLM` (interpose on
      `LLM`), which fills each leaf from the returned `Response` (model, provider, latency,
      tokens, cost, tool calls, response JSON, and the EP-6 `cacheKey`). The
      `Shikumi.Trace.ResponseJSON` orphan instances (faithful `Response` round-trip) landed here
      since `tracedLLM` needs `toJSON resp`. **Done (2026-06-08).** `cabal test shikumi-trace
      --test-options='-p tree'` green: one root, two module children, one LM-call leaf each, and
      `renderTree` shows the model lines indented under their modules.
- [x] M2: `Shikumi.Trace.Store` delivered — `TraceFile { formatVersion, tree }` (versioned,
      single JSON document), atomic `writeTraceFile` (write `.tmp` + rename), `readTraceFile`
      (`Left` on parse error / foreign `formatVersion`), and `replayIndex :: TraceTree -> Map
      CacheKey Value` (each LM-call span's `cacheKey` → recorded `response`). **Done
      (2026-06-08).** `cabal test shikumi-trace --test-options='-p store'` green (5 tests): a
      100-case JSON round-trip property over random trees, an on-disk round-trip, a
      foreign-version `Left`, the `replayIndex` projection, and **the cache-key golden — which
      reproduces EP-6's pinned digest `30b2…8113` byte-for-byte, fixing integration point #7 by
      reuse** (the key is imported from `shikumi-cache`, not copied).
- [x] M3: `Shikumi.Trace.Replay` delivered — `ReplayDivergence` (typed, `Exception`) and
      `runLLMReplay :: Map CacheKey Value -> Eff (LLM : es) a -> Eff es a`, an alternative
      interpreter of EP-1's `LLM` effect that answers each `complete` from the replay index by
      EP-6 cache key, decoding the recorded `Response` via `ResponseJSON`; a miss raises
      `ReplayDivergence` (fail-closed, names the key + model + redacted summary). **Done
      (2026-06-08).** `cabal test shikumi-trace --test-options='-p replay'` green: a two-stage
      *dependent* pipeline captured live, persisted, reloaded, and replayed offline yields
      byte-identical outputs with the provider counter at **0**; a mutated request raises
      `ReplayDivergence`.
- [ ] M4: `shikumi-trace-otel` package emitting one nested OTel span per tree node with
      GenAI semantic-convention attributes; in-memory-exporter test asserting parent/child
      nesting.
- [ ] M5: the `shikumi-trace-demo` executable tying it together (live trace → persist →
      offline replay) and the documented acceptance transcript.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **EP-1's `LLM` interpreters expose no `TraceSink` seam (2026-06-08).** `Shikumi.LLM`
  ships `runLLM` / `runLLMWith` / `runLLMResilient`, all of which `reinterpret_` straight
  over `baikai-effectful`'s `runBaikai*` with no sink parameter. So the plan's preferred
  "shape 1" (`runLLMWithSink`) does not exist. *But* `LLM.complete :: Model -> Context ->
  Options -> Eff es Response` returns the full baikai `Response`, which already carries
  `latencyMs`, `message.usage` (tokens + `cost.usd`), and the assistant content blocks
  (tool calls included) — strictly **more** than baikai's flat `TraceEvent`
  (`CallFinished` only has latency/tokens/usd). So I capture LM-call spans by
  **interposing on `LLM`** (the exact seam EP-6's `cachedLLM` uses) and reading the
  returned `Response`. This drops the `streamly-core` / baikai-`Trace` dependency from the
  core trace package and removes the M0 async-timing risk entirely (interpose wraps the
  call synchronously). See Decision Log.
- **EP-6 has landed, so the cache key is *imported*, not copied (2026-06-08).** The plan
  said to ship a verbatim copy of `Shikumi.Cache.Key` until EP-6 lands. EP-6's hermetic
  core (including `Shikumi.Cache.Key.cacheKey`) is delivered, so `shikumi-trace` depends on
  `shikumi-cache` and imports `cacheKey` directly — integration point #7 is satisfied by
  reuse, not duplication. The M2 golden test reproduces EP-6's pinned digest
  `30b2015562ec8b5cd4fdb64c7cc671c84f56f80d24891deec6676c521f008113`.
- **The `Response` JSON round-trip is EP-7's to build — it is the same gap EP-6 deferred
  (2026-06-08).** Replay serializes each `Response` into the trace file and decodes it
  back. baikai's `Response` graph round-trips only partially: `Model` / `Api` /
  `AssistantContent` / `StopReason` have both `ToJSON` and `FromJSON`, but `Usage` / `Cost`
  / `CostBreakdown` are `ToJSON`-only (and `Cost` maps `Rational → Scientific` lossily via
  `fromRationalRepetendUnlimited`), and `AssistantPayload` / `Response` have no `FromJSON`
  (Evidence: `grep ToJSON\|FromJSON baikai/src/Baikai/{Usage,Cost,Message,Response}.hs`).
  EP-7 owns the faithful round-trip in `Shikumi.Trace.ResponseJSON` (orphan `FromJSON` for
  `Usage`/`Cost`/`CostBreakdown`/`AssistantPayload` + `ToJSON`/`FromJSON Response`). The
  decisive point for the **replay typed-output guarantee**: the typed output is decoded
  from the assistant *text* (`AssistantContent`, which round-trips), so usage/cost
  imprecision never affects replayed outputs. EP-6's future persistent backends can reuse
  these instances.


## Decision Log

Record every decision made while working on the plan.

- Decision: Build the span hierarchy in shikumi by maintaining an explicit *call-stack of
  span identifiers* inside the `Shikumi.Trace` effect, and **consume** baikai's flat
  `TraceEvent` stream rather than reimplementing per-call event emission. Each shikumi span
  pushes its id; when baikai fires its flat `CallStarted`/`CallFinished`/`CallFailed`
  events, the shikumi interpreter attaches them as a *leaf* under whatever span id is
  currently on top of the stack.
  Rationale: baikai owns per-call event generation (it already times the call, computes
  cost, and summarizes the prompt — see `/Users/shinzui/Keikaku/bokuno/baikai/baikai/src/Baikai/Trace.hs`).
  Duplicating that would diverge cost accounting. baikai has no parent/child concept, so the
  hierarchy is purely shikumi's responsibility and the call-stack is the minimal mechanism
  that produces it without touching baikai.
  Date: 2026-06-07.

- Decision: The on-disk trace format is newline-delimited JSON is **rejected** in favor of a
  single JSON document holding the whole tree plus a format-version integer. A pretty trace
  is a tree, and trees serialize naturally as nested JSON; line-delimited events would force
  the reader to re-derive the hierarchy that we worked to build.
  Rationale: the tree is the product; persisting it as a tree keeps replay simple (look up a
  response by key) and keeps the file human-inspectable with `jq`.
  Date: 2026-06-07.

- Decision: Replay keys each recorded LM call by the **EP-6 content-addressed cache key**
  (defined in `docs/plans/6-caching-subsystem.md`), reproduced byte-for-byte here as a
  consumer. A replayed request is hashed with the identical algorithm; the matching recorded
  response is returned. This guarantees that the cache (EP-6) and the replay store (EP-7)
  agree on identity, so a trace recorded with caching on replays identically.
  Rationale: integration point #7 of the master plan requires EP-6 and EP-7 to agree on the
  key exactly; reusing it (rather than inventing a parallel key) is the only way replay and
  cache stay consistent.
  Date: 2026-06-07.

- Decision: Replay-divergence policy is **fail-closed and loud**. A request whose key is not
  in the trace raises a typed `ReplayDivergence` error carrying the offending key, the model
  id, and a redacted prompt summary; it never falls through to the network and never
  fabricates a response. An optional "lenient" mode (record-or-replay) is explicitly out of
  scope for this plan and noted as future work.
  Rationale: the whole value of replay is determinism and offline safety; a silent network
  fallthrough would defeat both and could leak budget. A loud error is the behavior a novice
  can verify.
  Date: 2026-06-07.

- Decision: The OTel adapter is its own package, `shikumi-trace-otel`, mirroring baikai's
  `baikai-trace-otel` exactly (same dependency set, same in-memory-exporter test strategy),
  so that pulling in the heavy `hs-opentelemetry-*` dependency tree is opt-in.
  Rationale: matches baikai's established package split and keeps the core `shikumi-trace`
  dependency-light.
  Date: 2026-06-07.

- Decision (impl, 2026-06-08): **Capture LM-call spans by `interpose` over EP-1's `LLM`
  effect, not by installing a baikai `TraceSink`.** The plan offered two shapes;
  investigation showed EP-1 exposes no sink seam (shape 1 is impossible) and, more
  importantly, that interposing on `LLM` is strictly *better* than the sink: the returned
  `Response` carries everything a span needs (model, provider, latency, input/output
  tokens, `cost.usd`, and the assistant content blocks for tool calls) — a superset of
  baikai's flat `TraceEvent`. The shikumi `Trace` effect still owns the parent/child
  hierarchy via a span-id stack; the interpose (`tracedLLM`) opens an `LlmCallSpan` under
  the active span and fills its attributes from the `Response`. Consequence: `shikumi-trace`
  does **not** depend on `streamly-core` or `Baikai.Trace.*`, and the M0 spike's
  async-event-timing concern is moot (interpose is synchronous around the call). The
  promotion/discard criterion in the plan's M0 is met by the interpose path; the
  sink-correlation fallback is not needed.

- Decision (impl, 2026-06-08): **Import `Shikumi.Cache.Key` from `shikumi-cache`; do not
  copy it.** EP-6's hermetic core (which owns `cacheKey`, integration point #7) is
  delivered, so `shikumi-trace` build-depends on `shikumi-cache` and reuses `cacheKey`
  verbatim. This is stronger than the plan's "ship a local reference copy until EP-6 lands"
  — there is exactly one implementation, so the two plans cannot drift. The M2 golden test
  still pins EP-6's digest as a regression guard.

- Decision (impl, 2026-06-08): **`runLLMReplay` needs no `IOE`** — the plan sketched
  `(IOE :> es) =>`, but the lookup and `fromJSON` decode are pure and `ReplayDivergence` is
  raised with @effectful@'s pure-in-`Eff` `throwIO`, so the delivered signature is the
  strictly weaker `Map CacheKey Value -> Eff (LLM : es) a -> Eff es a`. The "zero provider
  calls" guarantee is therefore *structural* (there is no registry in this interpreter at
  all), not merely policy — the M3 test still asserts a provider counter stays at 0 as a
  regression guard.

- Decision (impl, 2026-06-08): **EP-7 owns the faithful `Response` JSON round-trip** in
  `Shikumi.Trace.ResponseJSON` (orphan instances). baikai ships no `FromJSON` for the
  `Response`/`AssistantPayload`/`Usage`/`Cost` graph. Rather than store a lossy projection,
  EP-7 adds orphan `FromJSON` for `Usage`/`Cost`/`CostBreakdown`/`AssistantPayload` and
  `ToJSON`/`FromJSON Response`, reusing baikai's existing instances for `Model`/`Api`/
  `AssistantContent`/`StopReason`. Rationale: the trace file is shikumi's own format, so we
  are free to encode `Cost`'s `Rational` faithfully; and replay must rebuild a real
  `Response`. The typed-output guarantee rests only on `AssistantContent` (already
  round-tripping), so cost imprecision is harmless. These instances are the bounded work
  EP-6 deferred for its persistent backends and can move to a shared home later.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This section assumes you know nothing about this repository, baikai, `effectful`, or
OpenTelemetry. Read it fully before editing anything.

### The repository

The shikumi repository lives at `/Users/shinzui/Keikaku/bokuno/shikumi`. It is a multi-package
Haskell project that, at the time this plan begins, contains a `cabal.project` at the root, a
core package named `shikumi`, and (from the plan at `docs/plans/6-caching-subsystem.md`) a
package named `shikumi-cache`. You will add a new package, `shikumi-trace`, and a second
package, `shikumi-trace-otel`. Commands in this plan are run from the repository root,
`/Users/shinzui/Keikaku/bokuno/shikumi`, unless stated otherwise.

If `cabal.project` does not yet list your new packages, you must add them (see Concrete
Steps). The build tool is `cabal`; you build everything with `cabal build all` and test with
`cabal test all`. The GHC language edition across this project is `GHC2024` (the same as
baikai), and the shared default extensions match baikai's: `DeriveAnyClass`,
`DuplicateRecordFields`, `OverloadedLabels`, `OverloadedStrings`.

### What baikai gives us, and what it does not

baikai is the transport layer: it knows how to call Anthropic, OpenAI, and OpenAI-compatible
providers, and it returns a typed `Response`. The shikumi packages this plan depends on wrap
baikai in the `effectful` effect system (described next). The two parts of baikai that
matter here are its tracing module and its data records.

baikai's tracing is **flat**. Its source is at
`/Users/shinzui/Keikaku/bokuno/baikai/baikai/src/Baikai/Trace.hs`,
`/Users/shinzui/Keikaku/bokuno/baikai/baikai/src/Baikai/Trace/Event.hs`, and
`/Users/shinzui/Keikaku/bokuno/baikai/baikai/src/Baikai/Trace/Sink.hs`. The core type is:

```haskell
-- From Baikai.Trace.Event (reproduced for self-containment; do not redefine).
data TraceEvent
  = CallStarted
      { eventId :: !Text, timestamp :: !UTCTime, provider :: !Text, model :: !Text
      , maxTokens :: !Natural, promptSummary :: !Text }
  | CallFinished
      { eventId :: !Text, timestamp :: !UTCTime, provider :: !Text, model :: !Text
      , latencyMs :: !Integer, inputTokens :: !(Maybe Natural)
      , outputTokens :: !(Maybe Natural), usd :: !(Maybe Scientific) }
  | CallFailed
      { eventId :: !Text, timestamp :: !UTCTime, provider :: !Text, model :: !Text
      , latencyMs :: !Integer, errorMessage :: !Text }
```

A `CallStarted` and its later `CallFinished`/`CallFailed` share an `eventId :: Text`, which
is the *only* correlation baikai provides. There is **no** parent/child relationship: if
your program makes three calls, you get three independent `eventId`s and no way, from baikai
alone, to know that calls one and two were the two halves of a pipeline while call three was
a retry of call one.

Events are delivered to a **sink**, which is a streamly fold:

```haskell
-- From Baikai.Trace.Sink (reproduced; do not redefine).
newtype TraceSink = TraceSink { runSink :: Fold IO TraceEvent () }
```

A "streamly fold" (`Streamly.Data.Fold.Fold IO TraceEvent ()`) is a left-fold over a stream
of `TraceEvent` values running in `IO`, producing `()`. baikai ships `silent`, `stdoutSink`,
`fileSink`, and `multiSink` (fan-out), and a separate package `baikai-trace-otel` ships
`otelSink`. You attach a sink to a call with baikai's `withTrace`:

```haskell
-- From Baikai.Trace (reproduced; do not redefine).
withTrace :: MonadUnliftIO m => TraceSink -> Model -> Context -> Options -> m Response
```

The crucial mechanism for this plan: **a `TraceSink` is just a fold you control.** shikumi
will provide a sink whose fold *captures* each baikai event and routes it into the shikumi
trace tree under the currently-active span. baikai does the timing/cost/prompt-summary work;
shikumi supplies the hierarchy. This is the seam we build on, and we do **not** reimplement
baikai's `withTrace` plumbing.

baikai's own OTel adapter, for reference and as the template for ours, is at
`/Users/shinzui/Keikaku/bokuno/baikai/baikai-trace-otel/src/Baikai/Trace/Sink/OpenTelemetry.hs`.
It opens one OTel span per `eventId` and closes it on finish/fail, using a `Map Text Span`
keyed by `eventId` as the fold's state. It produces flat spans (every span is a root) and
uses the GenAI semantic-convention attribute helpers from
`hs-opentelemetry-semantic-conventions` (e.g. `SC.genAi_provider_name`,
`SC.genAi_request_model`, `SC.genAi_usage_inputTokens`) plus `baikai.`-prefixed custom
attributes. Our adapter mirrors this but produces *nested* spans.

### The `effectful` library and the `LLM` effect (from EP-1)

`effectful` is a Haskell effect system. The key ideas a novice needs:

- An *effect* is a capability declared as an empty data type. A function's type lists the
  effects it needs via the constraint `(SomeEffect :> es)`, where `es` is the list of effects
  in scope and `Eff es a` is a computation in that list returning `a`.
- A *dynamic effect* is interpreted by a handler. You define operations with
  `Effectful.Dispatch.Dynamic.send`, and you provide behavior with `interpret`.
- `IOE :> es` means "this computation may perform arbitrary `IO`". `MonadUnliftIO` lets you
  call baikai's `IO`-typed functions (like `withTrace`) from inside `Eff`.

The runtime substrate plan, `docs/plans/1-shikumi-runtime-substrate-and-llm-effect-over-baikai.md`,
owns the **`LLM` effect** and the **shikumi error type**. This plan depends on both. Because
EP-1's exact surface is what this plan consumes, this plan pins the consumed shape here so it
is self-contained; if EP-1's final code differs in spelling, adjust the imports but keep the
behavior. The consumed surface from `Shikumi.LLM` (module `Shikumi.LLM` in the `shikumi`
package) is:

```haskell
-- Provided by EP-1 (docs/plans/1-...). Reproduced as the contract this plan consumes.
data LLM :: Effect

-- The single provider-neutral call this plan must intercept for replay. It takes a baikai
-- request (model + context + options) and returns a baikai Response or a shikumi error.
complete :: (LLM :> es) => Model -> Context -> Options -> Eff es Response

-- EP-1 also exposes the interpreter that actually dispatches to baikai. This plan provides an
-- ALTERNATIVE interpreter of the same effect for replay (see Milestone 3).
runLLM :: (IOE :> es) => Eff (LLM : es) a -> Eff es a
```

The shikumi error type from EP-1 (module `Shikumi.Error`) is an enumerated sum; this plan
adds one constructor's worth of meaning via a *new* error type for replay divergence rather
than editing EP-1's type, to avoid coupling (see Interfaces and Dependencies). The baikai
records `Model`, `Context`, `Options`, `Response`, and `Usage` are re-exported through
`Shikumi.LLM` / `Shikumi.Prelude`; their fields are listed in the API map below.

### baikai data records this plan reads

You will read fields off baikai's records to populate spans. The relevant fields (names are
record selectors usable with `OverloadedLabels`, e.g. `resp ^. #latencyMs`):

```haskell
data Response = Response
  { message :: !AssistantPayload, model :: !Model, api :: !Api
  , provider :: !Text, responseId :: !(Maybe Text), latencyMs :: !Integer }

data Model = Model
  { modelId :: !Text, name :: !Text, provider :: !Text, baseUrl :: !Text, {- ... -} }

data Usage = Usage
  { inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens :: !Natural
  , reasoningTokens :: !(Maybe Natural), totalTokens :: !Natural, cost :: !Cost }

data Cost = Cost { usd :: !Rational, breakdown :: !CostBreakdown }
```

The assistant turn's `Usage` is reachable as `(resp ^. #message) ^. #usage`, exactly as in
baikai's own `Baikai.Trace.assistantUsage`. Tool calls are reachable from the assistant
content blocks via `Baikai.flattenAssistantBlocks resp`, whose `AssistantToolCall` entries
carry `ToolCall { id_ :: Text, name :: Text, arguments :: Value }`.

### The EP-6 content-addressed cache key (integration point #7)

The caching plan, `docs/plans/6-caching-subsystem.md`, owns a content-addressed key derived
from a baikai request. "Content-addressed" means the key is a cryptographic hash of the
request's meaningful content, so identical requests produce the identical key regardless of
when or where they run. The master plan's integration point #7 requires EP-6 and EP-7 to
agree on this key **byte-for-byte**. This plan therefore specifies the key contract from the
*consumer* side and pins the exact algorithm so replay and cache cannot drift:

EP-6 (`docs/plans/6-caching-subsystem.md`) is the **sole owner** of the key's exact field
set, canonical serialization, and hash function. To avoid two definitions drifting apart,
this plan does NOT restate a competing algorithm: it defers to EP-6 verbatim. The contract,
copied from EP-6 so this plan stands alone, is:

- The key is a **BLAKE3 256-bit digest rendered as 64 lowercase hex characters**, wrapped as
  `newtype CacheKey = CacheKey Text`, under the namespace/version tag `shikumi-cache/v1`.
- It is computed from a single canonical JSON object whose keys are **sorted lexicographically
  by Unicode code point, with no insignificant whitespace, UTF-8 encoded**, then hashed. The
  object contains exactly these fields and nothing else (the names and shape are EP-6's):
  `api`, `maxTokens`, `messages`, `model`, `provider`, `responseFormat`, `systemPrompt`,
  `temperature`, `thinking`, `toolChoice`, `tools`, and `version`. The `responseFormat` slot
  is `null` until `docs/plans/2-baikai-native-structured-output-extension.md` lands, and
  carries the attached schema thereafter. Excluded (never hashed): `apiKey`, `timeoutMs`,
  `headers`, `metadata`, `cacheRetention`, and everything on `Response`.

```haskell
-- EP-6 owns the production copy in Shikumi.Cache.Key. shikumi-trace ships a VERBATIM copy
-- of EP-6's implementation until EP-6 lands, then deletes it and imports EP-6's:
--   import Shikumi.Cache.Key (CacheKey(..), cacheKey)
newtype CacheKey = CacheKey Text
  deriving stock (Eq, Ord, Show)

-- cacheKey :: Model -> Context -> Options -> CacheKey
-- BLAKE3 (256-bit) of EP-6's canonical sorted-key JSON, rendered as lowercase hex.
-- The canonical-value builder and the blake3 binding are specified in EP-6; this plan
-- must use that exact code, not a re-derivation.
```

The single fact both plans must guarantee: given the same `(Model, Context, Options)`,
`cacheKey` returns the same `CacheKey Text`. Milestone 2 enforces this with a golden fixture
whose expected hex is taken from EP-6's golden test, so a divergence in either plan fails
loudly.

### Terms defined

- **Span**: one timed, attributed record of a unit of work. In this plan a span is a node in
  the trace tree, identified by a `SpanId` (a fresh `Text`), carrying a `parent :: Maybe
  SpanId`, a kind (program / module / combinator / llm-call), timing, and attributes.
- **Trace tree**: the in-memory tree of spans for one program run, rooted at the
  `runProgram` span.
- **Trace file**: the serialized JSON form of a trace tree on disk.
- **Replay**: re-running a program where every LM call is answered from a trace file instead
  of a provider.
- **Divergence**: during replay, an LM request whose cache key is absent from the trace
  file.
- **GenAI semantic conventions**: the OpenTelemetry-standardized attribute names for
  generative-AI spans (e.g. `gen_ai.request.model`), provided by the
  `hs-opentelemetry-semantic-conventions` package.


## Plan of Work

The work is six milestones. M0 is a de-risking spike (the hierarchy mechanism is the one
genuinely novel piece, since baikai gives us no nesting); M1–M5 build the shippable feature.
Each milestone ends with a command you can run and an output you can compare.

### Milestone 0 (spike) — prove the sink-capture-plus-call-stack mechanism

Scope: create the `shikumi-trace` package skeleton and a throwaway test that proves the one
risky idea — that a baikai `TraceSink` (a `Fold IO TraceEvent ()`) can be handed to baikai's
`withTrace` from inside an `Eff` computation, capture the flat events into an `IORef`, and
that a manually-maintained stack of span ids lets us tag each captured event with the
"currently active" span. At the end of this milestone, nothing is production-shaped, but the
mechanism that the rest of the plan relies on is demonstrated.

What will exist: `shikumi-trace/shikumi-trace.cabal`, a module `Shikumi.Trace.Internal.Spike`
exposing a function that runs two fake baikai calls nested under two different span-ids and
returns the list of `(SpanId, TraceEvent)` pairs, and a test asserting the events are tagged
with the expected enclosing span-ids.

The mechanism: build a `TraceSink` whose fold appends each event, *paired with the current
top-of-stack span id read from a shared `IORef [SpanId]`*, into a result `IORef`. Push a span
id before a (fake) call and pop it after. Because baikai pushes `CallStarted` synchronously
before the first stream event and `CallFinished` synchronously at the terminal event (see
`/Users/shinzui/Keikaku/bokuno/baikai/baikai/src/Baikai/Trace.hs`, `withTraceStream`), the
event lands in the fold while the correct span id is still on top of the stack. The spike
uses baikai's `liftCompleteToStream` with a stub provider registered under a `Custom` api tag
(exactly as baikai's own test does in
`/Users/shinzui/Keikaku/bokuno/baikai/baikai-trace-otel/test/Main.hs`) so no network is
touched.

Commands and acceptance:

```bash
cabal build shikumi-trace
cabal test shikumi-trace --test-options='-p spike'
```

Acceptance: the spike test passes, printing that two captured `CallFinished` events carry the
two distinct span ids that were on the stack when each fake call ran. If the events come back
tagged with the *wrong* or a *missing* span id, the call-stack timing assumption is wrong and
must be revisited before proceeding — record that in Surprises & Discoveries.

Promotion/discard criterion: if the spike passes, promote the `IORef`-stack idea into the
real effect interpreter in M1. If baikai's events turn out to arrive asynchronously (off the
stack), fall back to correlating by `eventId`: the shikumi `withSpan` would, instead, record
the set of `eventId`s observed during its dynamic extent. Document whichever path is taken.

### Milestone 1 — the `Shikumi.Trace` effect and the in-memory hierarchical tree

Scope: the real, production effect. At the end, a user can wrap any computation in
`withSpan`, nest those calls arbitrarily, have baikai's per-call events automatically
attached as leaf spans under the active span, retrieve the finished `TraceTree`, and
pretty-print it to the terminal.

What will exist, in module `Shikumi.Trace` (package `shikumi-trace`):

The span and tree data types. A `SpanKind` distinguishes the four node sorts. A `Span`
carries identity, parent, kind, a human label, start/end timestamps, and an *attribute*
record holding the spec-mandated fields (model, prompt, response, latency, token counts,
cost, retries, tool calls). The tree is held flat as a `Map SpanId Span` plus the root id, so
serialization and lookup are trivial and reconstructing the nesting is a `parent`-pointer
walk; a `TraceTree` also exposes a `children :: SpanId -> [SpanId]` view derived once.

```haskell
data SpanKind = ProgramSpan | ModuleSpan | CombinatorSpan | LlmCallSpan
  deriving stock (Eq, Show, Generic)

newtype SpanId = SpanId Text deriving stock (Eq, Ord, Show, Generic)

data SpanAttrs = SpanAttrs
  { model        :: !(Maybe Text)      -- model id, for llm-call spans
  , provider     :: !(Maybe Text)
  , prompt       :: !(Maybe Value)     -- the request: canonical JSON of (system,messages,tools,opts)
  , response     :: !(Maybe Value)     -- the response payload as JSON (for replay + inspection)
  , latencyMs    :: !(Maybe Integer)
  , inputTokens  :: !(Maybe Natural)
  , outputTokens :: !(Maybe Natural)
  , costUsd      :: !(Maybe Scientific)
  , retries      :: !Int               -- how many times this span retried its body
  , toolCalls    :: ![ToolCallRecord]  -- name + arguments of each tool call observed
  , cacheKey     :: !(Maybe Text)      -- EP-6 content-addressed key, present on llm-call spans
  } deriving stock (Eq, Show, Generic)

data ToolCallRecord = ToolCallRecord { name :: !Text, arguments :: !Value }
  deriving stock (Eq, Show, Generic)

data Span = Span
  { spanId    :: !SpanId
  , parent    :: !(Maybe SpanId)
  , kind      :: !SpanKind
  , label     :: !Text
  , startedAt :: !UTCTime
  , endedAt   :: !(Maybe UTCTime)
  , attrs     :: !SpanAttrs
  } deriving stock (Eq, Show, Generic)

data TraceTree = TraceTree
  { root  :: !SpanId
  , spans :: !(Map SpanId Span)
  } deriving stock (Eq, Show, Generic)
```

The effect itself. `Trace` is a dynamic effect with two operations: `withSpan` opens a span
of a given kind and label around an inner computation (pushing its id, timing it, and on exit
recording the finished span), and `currentSpanId` reads the active span id (so the LLM
interpreter and combinators can attach data to it). The retry count is surfaced by an
operation `bumpRetry` that the `Retry` combinator (from `docs/plans/5-module-combinators-and-control-flow.md`)
or the EP-1 retry machinery can call; if those are not present yet, `bumpRetry` is still
exported and simply increments the active span's counter.

```haskell
data Trace :: Effect

withSpan       :: (Trace :> es) => SpanKind -> Text -> Eff es a -> Eff es a
currentSpanId  :: (Trace :> es) => Eff es (Maybe SpanId)
bumpRetry      :: (Trace :> es) => Eff es ()
recordToolCall :: (Trace :> es) => ToolCallRecord -> Eff es ()
```

The interpreter, `runTrace`, holds the mutable building state (the `Map SpanId Span` under
construction, the current stack of span ids, and the captured-events buffer) in `IORef`s, and
crucially **installs the baikai-capturing sink** so that LM calls made through the EP-1 `LLM`
interpreter get their flat events folded into the active span as `LlmCallSpan` leaves. There
are two integration shapes for "installing the sink":

1. Preferred: EP-1's `runLLM` accepts a `TraceSink` (EP-1 already wraps baikai's `withTrace`,
   which takes a sink). `runTrace` builds the capturing sink and passes it down. This plan
   pins this as the expected EP-1 contract: `runLLMWithSink :: (IOE :> es) => TraceSink ->
   Eff (LLM : es) a -> Eff es a`. If EP-1 does not expose a sink parameter, use shape 2.

2. Fallback: `runTrace` runs the whole computation with baikai's *global* sink temporarily
   set via baikai's `multiSink`, or—if baikai has no settable global—`runTrace` re-implements
   the thin `withTrace` drain around EP-1's `complete` by interposing its own LLM
   interpreter. The plan documents shape 1 as the target and shape 2 as the safety net; pick
   based on EP-1's actual surface and record the choice in the Decision Log.

When a baikai `CallFinished` event is captured, the interpreter creates a child `LlmCallSpan`
under the active span, populating `attrs` from the event (latency, tokens, cost) and from the
`Response` (model, provider, response JSON, tool calls). The request prompt and the
`cacheKey` are computed at the call site (the LLM interpreter knows the `Model`/`Context`/
`Options`) and threaded in; see Milestone 3 for where exactly the key is computed so the same
key serves both replay-store keys and span attributes.

A pretty-printer, `renderTree :: TraceTree -> Text`, walks from the root and prints an
indented outline, one line per span: indentation by depth, then kind, label, latency, tokens,
and cost. Example expected shape for a two-stage pipeline:

```text
● program  summarize-and-critique         412ms
  ├─ combinator  Pipeline                  410ms
  │  ├─ module  predict:Draft              210ms
  │  │  └─ llm-call  anthropic/claude...   205ms  in=812 out=143  $0.0041
  │  └─ module  predict:Critique           198ms
  │     └─ llm-call  anthropic/claude...   193ms  in=970 out=88   $0.0039
```

Commands and acceptance:

```bash
cabal test shikumi-trace --test-options='-p tree'
```

Acceptance: a test runs a two-`withSpan` nest containing two stubbed LM calls (stub provider,
no network) and asserts (a) the tree has exactly one root, (b) the root has two module
children, (c) each module child has exactly one `LlmCallSpan` child, and (d) `renderTree`
contains both model lines indented under their modules. This is the user-visible "I can see
the structure" behavior.

### Milestone 2 — serialize the tree to a stable on-disk format keyed by the cache key

Scope: persist a `TraceTree` to a JSON file and read it back, with a versioned, stable
schema, and prove the round-trip and the cache-key agreement.

What will exist, in module `Shikumi.Trace.Store` (package `shikumi-trace`):

A `TraceFile` wrapper carrying a `formatVersion :: Int` (start at `1`) and the `TraceTree`,
with `ToJSON`/`FromJSON` instances using aeson generic deriving with `omitNothingFields`-style
options so absent attributes do not bloat the file. Functions:

```haskell
data TraceFile = TraceFile { formatVersion :: !Int, tree :: !TraceTree }
  deriving stock (Eq, Show, Generic)

writeTraceFile :: FilePath -> TraceTree -> IO ()
readTraceFile  :: FilePath -> IO (Either Text TraceTree)   -- Left on version mismatch / parse error
```

Additionally, a *replay index* view derived from a tree: a `Map CacheKey Value` mapping each
`LlmCallSpan`'s `cacheKey` to its recorded `response` JSON. This is what replay consults.

```haskell
replayIndex :: TraceTree -> Map CacheKey Value
```

This milestone also pins the EP-6 cache-key contract: include `Shikumi.Cache.Key` (the local
reference copy described in Context) and a golden test. The golden test serializes a fixed
`(Model, Context, Options)` fixture, computes `cacheKey`, and asserts it equals a hard-coded
expected hex string committed in the test. EP-6's plan must contain the identical fixture and
expected string; when EP-6 lands, delete the local copy, import `Shikumi.Cache.Key`, and
re-run the golden test to confirm byte-for-byte agreement.

Commands and acceptance:

```bash
cabal test shikumi-trace --test-options='-p store'
```

Acceptance: (a) a property test generates random small trees, writes then reads them, and
asserts equality (round-trip); (b) the golden cache-key test passes; (c) reading a file whose
`formatVersion` differs returns `Left` with a message naming the version. The written file is
human-inspectable: `jq '.tree.spans | length' trace.json` returns the span count.

### Milestone 3 — deterministic replay interpreter for the `LLM` effect

Scope: the headline capability. Provide an interpreter of the EP-1 `LLM` effect that serves
every `complete` call from a stored trace, returning the recorded `Response`, and that raises
a precise divergence error when a request is not in the trace. Prove it offline.

What will exist, in module `Shikumi.Trace.Replay` (package `shikumi-trace`):

```haskell
data ReplayDivergence = ReplayDivergence
  { divergedKey   :: !CacheKey
  , divergedModel :: !Text
  , promptSummary :: !Text     -- redacted, like baikai's summarizeContext
  } deriving stock (Eq, Show, Generic)
  deriving anyclass (Exception)

-- Interpret the LLM effect by lookup in a replay index instead of calling a provider.
runLLMReplay
  :: (IOE :> es)
  => Map CacheKey Value          -- from replayIndex on a loaded TraceTree
  -> Eff (LLM : es) a
  -> Eff es a
```

How it plugs into the `LLM` effect: `runLLMReplay` interprets the same `complete :: Model ->
Context -> Options -> Eff es Response` operation that EP-1's `runLLM` interprets. Where
`runLLM` dispatches to baikai, `runLLMReplay` computes `cacheKey model ctx opts`, looks it up
in the supplied index, decodes the stored `Value` back into a baikai `Response` (via the
`FromJSON Response` instance baikai provides, or a shikumi-side decoder if baikai lacks one —
the plan notes baikai `Response` has aeson instances; if not, serialize the minimal fields
needed to rebuild a `Response` and reconstruct it). On a hit, it returns the `Response`
without any `IO` beyond the pure lookup. On a miss, it throws `ReplayDivergence` with the key,
the model id, and a redacted prompt summary (reuse baikai's `summarizeContext` for the
summary so it matches what spans show).

Because `runLLMReplay` is a drop-in replacement at the *same* effect boundary, the *rest of
the program is unchanged*: `runProgram`, the modules, the combinators all run exactly as in
live mode; only the leaf LM calls are redirected. This is what guarantees identical typed
outputs — the same decoding, the same combinator logic, applied to the same recorded
responses.

The offline guarantee is enforced in the acceptance test by registering, under the test's
`Custom` api tag, a baikai provider handler that `throwIO`s if it is ever called (mirroring
the live demo's `SHIKUMI_OFFLINE=1` wiring). If replay touches the network, the handler fires
and the test fails loudly.

Commands and acceptance:

```bash
cabal test shikumi-trace --test-options='-p replay'
```

Acceptance, phrased as observable behavior: a test (1) runs a two-stage pipeline against a
stub provider, capturing a `TraceTree`; (2) writes it to a temp file; (3) reads it back and
builds the replay index; (4) registers a *throwing* provider so any real call fails; (5) runs
the *same* pipeline under `runLLMReplay`; (6) asserts the replayed final output equals the
live final output, and (7) asserts the throwing provider was never invoked (an `IORef`
counter stays at zero). A second test mutates the pipeline's first stage so it issues a
different prompt, runs replay, and asserts a `ReplayDivergence` is thrown naming the new key.

### Milestone 4 — `shikumi-trace-otel`: nested OTel spans

Scope: a second package that turns a finished `TraceTree` into OpenTelemetry spans preserving
parent/child nesting, with GenAI semantic-convention attributes plus shikumi cost/latency.
This mirrors baikai's `baikai-trace-otel` but, unlike it, produces a real tree.

What will exist: `shikumi-trace-otel/shikumi-trace-otel.cabal` and module
`Shikumi.Trace.OpenTelemetry` exposing:

```haskell
exportTree :: (MonadUnliftIO m) => Otel.Tracer -> TraceTree -> m ()
```

Mechanism: walk the tree from the root depth-first. For each node, open an OTel span using
`OpenTelemetry.Trace.Core.createSpan` with the span's recorded `startedAt` as the start time
and the node's `endedAt` as the end time, and—critically for nesting—create each child span
with a `Context` that has the parent's span inserted (`OpenTelemetry.Context.insertSpan
parentSpan ctx`). This is the explicit-context approach documented in the OTel "inSpan"
guide for cases where the parent/child relationship is reconstructed rather than discovered
from the dynamic call stack: we are replaying a recorded tree, so we set parents explicitly.
Attributes on `LlmCallSpan` nodes use the GenAI helpers from
`hs-opentelemetry-semantic-conventions` exactly as baikai's adapter does
(`SC.genAi_provider_name`, `SC.genAi_operation_name`, `SC.genAi_request_model`,
`SC.genAi_usage_inputTokens`, `SC.genAi_usage_outputTokens`, `SC.genAi_response_model`) plus
shikumi-specific keys with a `shikumi.` prefix (`shikumi.latency_ms`, `shikumi.cost.usd`,
`shikumi.span_kind`, `shikumi.retries`, `shikumi.tool_calls`). Non-LLM nodes (program,
module, combinator) get just the `shikumi.span_kind` and timing. End each span at its
`endedAt` (falling back to "now" for any span left open).

The package's dependencies and test strategy mirror baikai's `baikai-trace-otel.cabal`
exactly: `hs-opentelemetry-api`, `hs-opentelemetry-semantic-conventions` for the library, and
`hs-opentelemetry-sdk` plus `hs-opentelemetry-exporter-in-memory` for the test (the in-memory
exporter captures emitted spans so a test can assert on them without a collector). The test
follows the pattern in `/Users/shinzui/Keikaku/bokuno/baikai/baikai-trace-otel/test/Main.hs`:
create a tracer over `inMemoryListExporter`, export a fixed two-stage tree, read the captured
`ImmutableSpan`s, and assert the nesting.

Commands and acceptance:

```bash
cabal test shikumi-trace-otel
```

Acceptance: the test exports a fixed two-stage-pipeline `TraceTree` and asserts (a) the right
number of spans were emitted, (b) the two `LlmCallSpan`s carry `gen_ai.request.model`, and
(c) each child span's parent (read via the span's parent `SpanContext` / `spanId` linkage on
the captured `ImmutableSpan`) equals the expected parent span — i.e. the nesting survived. If
the SDK's in-memory span does not expose the parent linkage directly, assert nesting via the
shared trace id plus distinct parent span ids, and document the assertion approach.

### Milestone 5 — the `shikumi-trace-demo` executable and end-to-end acceptance

Scope: a small runnable program proving the whole story: live trace → pretty-print →
persist → offline replay with identical output and zero provider calls.

What will exist: an executable stanza `shikumi-trace-demo` (in `shikumi-trace.cabal` or a tiny
`shikumi-trace-demo` package — keep it in `shikumi-trace.cabal` as an `executable` to avoid a
new package). It defines a two-stage pipeline program: stage one drafts a one-line summary of
a fixed input article; stage two critiques the draft. The provider is wired by environment:

- Default (live): if real API keys are present, it calls a real provider; otherwise it uses a
  deterministic *stub* provider registered under a `Custom` api tag that returns canned
  responses, so the demo runs with no keys and no network. The stub makes the demo
  reproducible in CI and on a novice's laptop.
- `--replay PATH`: load the trace at `PATH`, build the replay index, and run under
  `runLLMReplay`.
- `SHIKUMI_OFFLINE=1`: register a *throwing* provider so any actual provider call aborts the
  program — used to prove replay never touches the network.

Behavior: with no arguments, it runs the pipeline, prints `renderTree` to stdout, writes
`trace.json`, and prints the final critique. With `--replay trace.json` and
`SHIKUMI_OFFLINE=1`, it loads the trace, runs the pipeline under replay, and prints the same
final critique, plus a line confirming "provider calls: 0".

Commands and acceptance (run from repo root):

```bash
cabal run shikumi-trace-demo
# ... prints a nested tree and "FINAL: <critique>", writes trace.json

SHIKUMI_OFFLINE=1 cabal run shikumi-trace-demo -- --replay trace.json
# ... prints the SAME "FINAL: <critique>" and "provider calls: 0"
```

Acceptance: the two `FINAL:` lines are byte-identical, the replay run prints `provider calls:
0`, and the replay run does not error. A test (`-p e2e`) automates this by running the demo's
core function in-process: capture tree → write temp file → replay with the throwing provider
→ assert equal outputs and zero calls. This is the master plan's stated acceptance for EP-7.


## Concrete Steps

Run everything from the repository root, `/Users/shinzui/Keikaku/bokuno/shikumi`.

First, create the package directories and register them. Create `shikumi-trace/` and
`shikumi-trace-otel/` with the standard `src/` and `test/` subdirectories, and add both to
`cabal.project`'s `packages:` stanza so cabal discovers them:

```bash
mkdir -p shikumi-trace/src/Shikumi/Trace shikumi-trace/test
mkdir -p shikumi-trace-otel/src/Shikumi/Trace shikumi-trace-otel/test
```

Add to `cabal.project` (append under the existing `packages:` list):

```cabal
packages:
  shikumi
  shikumi-cache
  shikumi-trace
  shikumi-trace-otel
```

Author `shikumi-trace/shikumi-trace.cabal` mirroring baikai's cabal conventions (the
`common-options` block with `GHC2024` and the four default extensions). The library exposes
`Shikumi.Trace`, `Shikumi.Trace.Store`, `Shikumi.Trace.Replay`, and (internal)
`Shikumi.Trace.Internal.Spike` during M0. Library `build-depends` include `base`, `baikai`,
`shikumi` (for the `LLM` effect and re-exported baikai records), `effectful`,
`effectful-core`, `aeson`, `containers`, `text`, `time`, `scientific`, `vector`,
`blake3` (the BLAKE3 hash binding EP-6 selects for the cache key; pin the same library and
version so the key bytes match — see `docs/plans/6-caching-subsystem.md`), `streamly-core` (for the `Fold`-shaped sink), `lens`
and `generic-lens` (for `OverloadedLabels` access to baikai records), and `unliftio-core`.
The test stanza adds `tasty`, `tasty-hunit`, `tasty-quickcheck`, and `temporary` (for temp
trace files).

Author `shikumi-trace-otel/shikumi-trace-otel.cabal` mirroring
`/Users/shinzui/Keikaku/bokuno/baikai/baikai-trace-otel/baikai-trace-otel.cabal`: library
depends on `shikumi-trace`, `hs-opentelemetry-api`,
`hs-opentelemetry-semantic-conventions`, `unordered-containers`, `containers`, `text`,
`time`, `unliftio-core`; the test adds `hs-opentelemetry-sdk` and
`hs-opentelemetry-exporter-in-memory`, `tasty`, `tasty-hunit`.

Then implement milestones in order. After each milestone, run its test selector and compare
to the expected acceptance described above:

```bash
cabal build all
cabal test shikumi-trace --test-options='-p spike'   # M0
cabal test shikumi-trace --test-options='-p tree'    # M1
cabal test shikumi-trace --test-options='-p store'   # M2
cabal test shikumi-trace --test-options='-p replay'  # M3
cabal test shikumi-trace-otel                         # M4
cabal test shikumi-trace --test-options='-p e2e'     # M5
```

Commit after each milestone with a Conventional Commit subject and the three mandatory
trailers. Example for M1:

```text
feat(shikumi-trace): hierarchical trace tree over baikai TraceSink

MasterPlan: docs/masterplans/1-shikumi-typed-lm-programming-framework.md
ExecPlan: docs/plans/7-hierarchical-tracing-observability-and-replay.md
Intention: intention_01ktjgkp10ef79vpwz1cmajek9
```


## Validation and Acceptance

The plan is complete when all of the following hold and a reviewer can reproduce them:

- `cabal build all` succeeds with no warnings beyond the project baseline.
- `cabal test shikumi-trace` and `cabal test shikumi-trace-otel` both pass.
- The hierarchy is visible: the M1 `-p tree` test asserts the root→module→llm-call nesting
  and `renderTree` shows LM-call lines indented under their modules.
- The trace persists and round-trips: the M2 `-p store` property test passes and a written
  `trace.json` is inspectable with `jq`.
- The cache key agrees with EP-6: the M2 golden test matches the committed hex; once EP-6
  lands, the local copy is deleted, `Shikumi.Cache.Key` is imported, and the golden test
  still passes (byte-for-byte agreement, integration point #7).
- Deterministic replay works offline: the M3 `-p replay` test (and the M5 `-p e2e` test)
  produce identical outputs to the live run while a throwing provider proves zero provider
  calls occurred; a mutated request raises `ReplayDivergence` naming the missing key.
- OTel nesting survives: the M4 test asserts child spans reference their parents (shared
  trace id, correct parent span ids) and that LM spans carry GenAI attributes.
- The headline end-to-end story runs by hand:

```bash
cabal run shikumi-trace-demo
SHIKUMI_OFFLINE=1 cabal run shikumi-trace-demo -- --replay trace.json
```

  and the two `FINAL:` lines are byte-identical while the replay run prints `provider calls:
  0`.


## Idempotence and Recovery

All steps are safe to repeat. Creating directories with `mkdir -p` and re-adding packages to
`cabal.project` is idempotent (ensure no duplicate package lines; cabal errors on duplicates,
so de-duplicate if a line already exists). `writeTraceFile` overwrites its target atomically
(write to a temp path in the same directory, then `renameFile`) so a crash mid-write never
leaves a half-written `trace.json`; on a corrupt or truncated file, `readTraceFile` returns
`Left` and replay refuses to start rather than producing wrong outputs. Re-running tests is
free of side effects (temp files via the `temporary` package are cleaned up). If a milestone's
test fails, the prior milestones' artifacts remain valid; fix and re-run only the failing
selector. The OTel package is fully optional: if its dependency tree fails to resolve in an
environment, remove `shikumi-trace-otel` from `cabal.project` and the rest of the plan still
builds and passes.


## Interfaces and Dependencies

Libraries and why: **baikai** (`Baikai.Trace`, `Baikai.Trace.Event`, `Baikai.Trace.Sink`,
`Baikai.summarizeContext`) supplies the flat `TraceEvent`/`TraceSink` we consume and the
prompt-summary helper; we do not modify it. **shikumi** core (`Shikumi.LLM`, `Shikumi.Error`,
`Shikumi.Prelude`) supplies the `LLM` effect we intercept and the baikai record re-exports;
owned by `docs/plans/1-shikumi-runtime-substrate-and-llm-effect-over-baikai.md`. **shikumi-cache**
(`Shikumi.Cache.Key`) owns the content-addressed `CacheKey`/`cacheKey`; owned by
`docs/plans/6-caching-subsystem.md`; this plan ships an identical local reference copy until
that lands, then imports it. **effectful** supplies the effect system. **streamly-core**
supplies the `Fold` shape baikai's `TraceSink` requires. **aeson**/**containers** for
serialization and the tree. The `blake3` library (the same one EP-6 picks) for the key.
**hs-opentelemetry-api** and **hs-opentelemetry-semantic-conventions** for the OTel adapter;
**hs-opentelemetry-sdk** and **hs-opentelemetry-exporter-in-memory** for its test.

Types and signatures that must exist at the end of each milestone, by full module path:

- End of M0 — `shikumi-trace`, module `Shikumi.Trace.Internal.Spike`: a function
  `runSpike :: IO [(SpanId, TraceEvent)]` demonstrating sink-capture-plus-call-stack, and
  the type `newtype SpanId = SpanId Text`.

- End of M1 — module `Shikumi.Trace`: `data Trace :: Effect`; `data SpanKind`; `data Span`;
  `data SpanAttrs`; `data ToolCallRecord`; `data TraceTree`; `withSpan :: (Trace :> es) =>
  SpanKind -> Text -> Eff es a -> Eff es a`; `currentSpanId :: (Trace :> es) => Eff es (Maybe
  SpanId)`; `bumpRetry :: (Trace :> es) => Eff es ()`; `recordToolCall :: (Trace :> es) =>
  ToolCallRecord -> Eff es ()`; `runTrace :: (IOE :> es) => Eff (Trace : es) a -> Eff es
  (a, TraceTree)`; `renderTree :: TraceTree -> Text`. Plus the consumed EP-1 contract
  `runLLMWithSink :: (IOE :> es) => Baikai.Trace.Sink.TraceSink -> Eff (LLM : es) a -> Eff es
  a` (target shape; document the fallback if EP-1 differs).

- End of M2 — module `Shikumi.Trace.Store`: `data TraceFile`; `writeTraceFile :: FilePath ->
  TraceTree -> IO ()`; `readTraceFile :: FilePath -> IO (Either Text TraceTree)`;
  `replayIndex :: TraceTree -> Map CacheKey Value`. Module `Shikumi.Cache.Key` (local
  reference until EP-6 lands): `newtype CacheKey = CacheKey Text`; `cacheKey :: Model ->
  Context -> Options -> CacheKey`.

- End of M3 — module `Shikumi.Trace.Replay`: `data ReplayDivergence` (with an `Exception`
  instance); `runLLMReplay :: (IOE :> es) => Map CacheKey Value -> Eff (LLM : es) a -> Eff es
  a`.

- End of M4 — `shikumi-trace-otel`, module `Shikumi.Trace.OpenTelemetry`: `exportTree ::
  (MonadUnliftIO m) => OpenTelemetry.Trace.Core.Tracer -> TraceTree -> m ()`.

- End of M5 — executable `shikumi-trace-demo` with a testable core function, e.g. `demoMain
  :: [String] -> IO ()` and an in-process `runDemoPipeline :: (LLM :> es, Trace :> es) => Eff
  es Text` used by both the live path and the `-p e2e` test.
