---
id: 40
slug: cache-key-v2-endpoint-completeness
title: "Cache Key v2 Endpoint Completeness"
kind: exec-plan
created_at: 2026-07-02T03:30:16Z
intention: "intention_01kwgdyxm7ehh8yys1pp4wf1zr"
master_plan: "docs/masterplans/7-cache-trace-and-replay-hardening.md"
---

# Cache Key v2 Endpoint Completeness

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

shikumi caches LM responses under a content-addressed key: a BLAKE3 hash of a canonical JSON serialization of "everything about a request that can change the model's answer". Today that claim is false in both directions. The key omits the model's endpoint identity (`baseUrl`), the model's default headers, the model's compatibility shim, and the per-call headers — so two deployments pointing the same model id at different endpoints (say, the real Anthropic API and a local proxy), or two calls differing only in an `anthropic-beta` header that changes model behavior, silently share cache entries and can serve each other's answers. In the other direction, the key includes each message's creation timestamp — so a program that builds messages with real clock times (baikai's `userNow`/`userAt`, or any multi-turn conversation containing real assistant replies) never hits the cache at all: every run hashes to a fresh key, which is both a guaranteed cache miss and unbounded growth of the store.

After this change, the key hashes the full routing identity (model id, provider, api, base URL, model headers, compat shim, per-call headers) and ignores message timestamps, under a new key-namespace version `"shikumi-cache/v2"` so that no v1 entry is ever mistaken for a v2 one. You can see it working by running the `shikumi-cache` test suite: new tests prove a `baseUrl` change or a header change produces a different key, and two requests differing only in message timestamps produce the same key.

One consequence must be understood up front: the trace/replay system in `shikumi-trace` reuses this exact key function, so bumping the version invalidates every previously recorded trace file (replaying an old trace under the new build raises `ReplayDivergence`, its loud fail-closed error). This plan updates the trace package's pinned digest and documents that consequence; the follow-on plan `docs/plans/42-replay-divergence-detection-and-trace-concurrency-safety.md` is ordered strictly after this one for that reason.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M1: extend `requestToCanonicalValueVersioned` with `baseUrl`, `modelHeaders`, `compat`, `optionsHeaders`; strip message timestamps
- [ ] M1: bump `currentKeyVersion` to `"shikumi-cache/v2"`; correct the false module-header claim in `Key.hs`
- [ ] M2: recapture the pinned golden digest in `shikumi-cache/test/Main.hs`; fix the versioning test's hard-coded version pair
- [ ] M2: add discrimination tests (baseUrl, model headers, options headers, compat) and the timestamp-insensitivity test
- [ ] M2: add the over-stripping guard test (a `"timestamp"` key inside tool-call arguments still changes the key)
- [ ] M3: update the pinned digest in `shikumi-trace/test/Main.hs`; document trace invalidation in `Key.hs` and in this plan
- [ ] M4: document the lossy `Cost` JSON round-trip in `shikumi-cache/src/Shikumi/Cache/ResponseJSON.hs`
- [ ] Full test suite green (`just test-one shikumi-cache`, `just test-one shikumi-trace`, `just test`)


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Include `Model.baseUrl`, `Model.headers`, `Model.compat`, and `Options.headers` in the hashed field set; keep `Options.apiKey`, `Options.timeoutMs`, and `Options.metadata` excluded.
  Rationale: The included four all change what the provider returns (endpoint routing, behavior-altering headers like `anthropic-beta`, and the compat shim that rewrites requests per host). API keys select credentials, timeouts select failure behavior, and metadata is shikumi's private side channel — none change a successful response's content, and hashing an API key into cache keys would also be a mild secret-handling smell.
  Source: production-readiness code review (verified against baikai's `Model`/`Options` records).
  Date: 2026-07-01

- Decision: Exclude message timestamps by post-processing the messages' JSON (deleting the `timestamp` field of each message payload object) rather than by changing baikai's `ToJSON` instances.
  Rationale: baikai's encoding is shared by persistence and the wire; the cache key is the only consumer that must ignore timestamps. A local, surgical strip of exactly the payload-level `timestamp` field keeps the change in one function and cannot affect other consumers. Deleting `"timestamp"` keys recursively at all depths was rejected because tool-call arguments are free-form JSON that may legitimately contain a `timestamp` field the model must see.
  Date: 2026-07-01

- Decision: Do not change `Cost`'s `Eq` or its JSON round-trip; document the lossiness instead.
  Rationale: baikai encodes `Rational` costs via `fromRationalRepetendUnlimited` and shikumi-cache decodes them with `toRational`, which is exact only for terminating decimals. Real per-token USD rates are decimal (denominators are powers of ten), so real costs terminate; the lossy case needs a non-decimal rational, which only synthetic values produce. Cost is metadata — it never feeds the typed-output guarantee — so a documentation note is the proportionate fix.
  Date: 2026-07-01


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This repository is a cabal multi-package Haskell project. All build and test commands run inside the Nix dev shell: from the repository root, enter it with `nix develop .#ghc9124`. Tests for a single package run with `just test-one <package>` (a thin wrapper over `cabal test <package>`; the `Justfile` is at the repository root).

The cache key lives in `shikumi-cache/src/Shikumi/Cache/Key.hs`. A `CacheKey` is the 64-character lowercase hex BLAKE3-256 digest of a canonical JSON document describing a request. "Canonical" means: object keys sorted by Unicode code point, no insignificant whitespace, UTF-8 — implemented by `canonicalJSON` (lines 103-117 of that file), which the plan does not change. The document itself is assembled by `requestToCanonicalValueVersioned` (lines 77-97), which currently emits exactly these fields: `version`, `model`, `provider`, `api`, `systemPrompt`, `messages`, `tools`, `toolChoice`, `temperature`, `maxTokens`, `thinking`, `responseFormat`. The version string baked into every hash is `currentKeyVersion` (lines 48-49), currently `"shikumi-cache/v1"`; bumping it changes every key, which is the designed invalidation mechanism. The module header (lines 3-15) currently claims "headers … are excluded — they do not affect the output", which is the false claim this plan corrects.

The request triple `(Model, Context, Options)` comes from baikai, the provider-abstraction library this repo depends on. Its source is on disk in a sibling checkout; locate it with `mori registry show baikai --full` (path: `/Users/shinzui/Keikaku/bokuno/baikai`; never search `/nix/store`). The relevant records, so you do not need to leave this document:

- `Baikai.Model.Model` (baikai `baikai/src/Baikai/Model.hs`, lines 96-111) has fields `modelId`, `name`, `api`, `provider`, `baseUrl :: Text`, `reasoning`, `input`, `cost`, `contextWindow`, `maxOutputTokens`, `headers :: Map Text Text`, `compat :: Compat`. `Compat` (same file) is a three-constructor sum (`CompatNone` / `CompatOpenAICompletions` / `CompatAnthropicMessages`) describing per-host request-rewriting shims; it has `ToJSON`. `baseUrl`, `headers`, and `compat` all change provider behavior and are all currently missing from the key.
- `Baikai.Options.Options` (baikai `baikai/src/Baikai/Options.hs`) has, besides the fields already hashed, `apiKey`, `timeoutMs`, `headers :: Map Text Text`, `metadata`, `cacheRetention`. Only `headers` joins the key (see Decision Log).
- `Baikai.Message.Message` (baikai `baikai/src/Baikai/Message.hs`) is a three-constructor sum — `UserMessage UserPayload`, `AssistantMessage AssistantPayload`, `ToolResultMessage ToolResultPayload` — and every payload record carries a `timestamp :: UTCTime`. The smart constructor `user` uses a fixed fixture timestamp (`2000-01-01`), which is why the existing golden test is deterministic; but `userAt`/`userNow` and every real assistant turn carry wall-clock times. All three `Message` constructors derive `ToJSON` generically with default options, so a message serializes as `{"tag":"UserMessage","contents":{...payload fields including "timestamp"...}}` — the payload object is under the `"contents"` key. That shape is what the timestamp strip in this plan relies on (and what a new test locks down behaviorally).

Two golden tests pin the digest of a fixed request and will both change:

- `shikumi-cache/test/Main.hs` line 67: `pinnedKey = "30b2015562ec8b5cd4fdb64c7cc671c84f56f80d24891deec6676c521f008113"`, asserted at lines 145-147. The same file's versioning test (lines 247-252) compares the serializations for hard-coded versions `"shikumi-cache/v1"` and `"shikumi-cache/v2"`.
- `shikumi-trace/test/Main.hs` line 305 pins the identical digest (asserted at lines 184-187) to prove the trace package reproduces the cache package's key byte-for-byte.

Consumers of the key besides `cachedLLM` (`shikumi-cache/src/Shikumi/Cache.hs:63`): trace capture stamps `Key.cacheKey m c o` onto every LM-call span (`shikumi-trace/src/Shikumi/Trace.hs:350`) and also embeds `requestToCanonicalValue m c o` as the span's `prompt` attribute (line 343); replay recomputes the key per call (`shikumi-trace/src/Shikumi/Trace/Replay.hs:65`) and looks it up in the index built from recorded spans (`shikumi-trace/src/Shikumi/Trace/Store.hs:83-91`). Because recorded keys are stored as text inside trace files and replay recomputes keys with the live function, any change to the function makes old trace files unreplayable — replay raises its `ReplayDivergence` error. That is the correct, fail-closed behavior; this plan documents it rather than mitigating it.

One adjacent lossiness to document while in this package: `shikumi-cache/src/Shikumi/Cache/ResponseJSON.hs` (lines 61-77) decodes baikai's cost fields with `ratField o k = toRational <$> (o .: k :: Parser Scientific)`, inverting baikai's `ratToSci = fst . fromRationalRepetendUnlimited` (baikai `baikai/src/Baikai/Cost.hs`). For a `Rational` with a non-terminating decimal expansion (e.g. `1 % 3`), `fromRationalRepetendUnlimited` returns a finite `Scientific` plus a repetend index, and taking `fst` drops the repetend — so `toRational` of it does not equal the original, and a `CachedResponse` containing such a cost fails `Eq` after a JSON round-trip. See the Decision Log: this plan documents it, it does not change behavior.


## Plan of Work

### Milestone 1: the v2 canonical value

Scope: `shikumi-cache/src/Shikumi/Cache/Key.hs` only. At the end of this milestone the canonical document contains the four endpoint fields and no message timestamps, the namespace version is v2, and the module header tells the truth. The package still compiles; its golden test fails (expected — fixed in M2).

Edit `requestToCanonicalValueVersioned` (currently lines 77-97) to emit four new fields and to filter the messages' serialization. The field names below are final — `canonicalJSON` sorts keys, so insertion order is irrelevant, but the names themselves are hashed and must not drift afterwards. `modelHeaders` and `optionsHeaders` are kept as separate fields (rather than merged) so the document states exactly where each header came from; `Map Text Text` serializes as a JSON object, which `canonicalJSON` key-sorts, so map ordering cannot leak into the hash.

```haskell
requestToCanonicalValueVersioned :: Text -> Model -> Context -> Options -> Value
requestToCanonicalValueVersioned version m ctx opts =
  object
    [ "version" .= version,
      "model" .= (m ^. #modelId),
      "provider" .= (m ^. #provider),
      "api" .= toJSON (m ^. #api),
      "baseUrl" .= (m ^. #baseUrl),
      "modelHeaders" .= toJSON (m ^. #headers),
      "compat" .= toJSON (m ^. #compat),
      "systemPrompt" .= (ctx ^. #systemPrompt),
      "messages" .= stripMessageTimestamps (toJSON (ctx ^. #messages)),
      "tools" .= toJSON (ctx ^. #tools),
      "toolChoice" .= toJSON (opts ^. #toolChoice),
      "temperature" .= (toScientific <$> (opts ^. #temperature)),
      "maxTokens" .= (opts ^. #maxTokens),
      "optionsHeaders" .= toJSON (opts ^. #headers),
      "thinking" .= toJSON (opts ^. #thinking),
      "responseFormat" .= toJSON (opts ^. #responseFormat)
    ]
```

Add the strip helper to the same module (not exported is fine, but exporting it makes the over-stripping test below cleaner — export it). It deletes exactly the payload-level `timestamp` field of each element of the messages array, relying on aeson's default tagged-object sum encoding described in Context and Orientation. It deliberately does not recurse: a `"timestamp"` key nested deeper (inside content blocks or tool-call arguments) is model-visible data and must keep affecting the key.

```haskell
-- | Delete the payload-level @timestamp@ of every message in a serialized
-- message vector. baikai's 'Baikai.Message.Message' encodes as
-- @{"tag": ..., "contents": {..., "timestamp": ...}}@; the timestamp records
-- when the message value was built, never what the provider sees, so two
-- requests differing only in it must share a cache key. Only the
-- @contents.timestamp@ level is deleted — a @"timestamp"@ key nested inside
-- content blocks or tool arguments is real request data and is preserved.
stripMessageTimestamps :: Value -> Value
stripMessageTimestamps (Array msgs) = Array (fmap stripOne msgs)
  where
    stripOne (Object msg) = Object (KM.adjust dropTs "contents" msg)
    stripOne v = v
    dropTs (Object payload) = Object (KM.delete "timestamp" payload)
    dropTs v = v
stripMessageTimestamps v = v
```

`KM` is already imported (`Data.Aeson.KeyMap qualified as KM`); `Array` and `Object` are already imported from `Data.Aeson`.

Bump the namespace (lines 48-49):

```haskell
currentKeyVersion :: Text
currentKeyVersion = "shikumi-cache/v2"
```

Rewrite the module header's exclusion sentence (lines 6-8). It must now say: the key covers the model routing identity including `baseUrl`, model default headers, and the compat shim; per-call `Options.headers`; the rendered prompt with message timestamps excluded; the tools; and the sampling options — while latency, response ids, API keys, timeouts, and per-call metadata remain excluded because they do not change a successful response's content. Add one sentence stating that any change to the field set requires bumping `currentKeyVersion` and that a bump invalidates all cache entries and makes previously recorded `shikumi-trace` files unreplayable (replay fails closed with `ReplayDivergence`).

Acceptance for M1: `cabal build shikumi-cache` succeeds; `just test-one shikumi-cache` fails only on the pinned-digest assertion (and possibly the versioning-pair test), which is the expected signal that the bytes changed.

### Milestone 2: shikumi-cache tests — recapture the golden digest, add discrimination and insensitivity tests

Scope: `shikumi-cache/test/Main.hs`. At the end, the suite is green and the new behaviors are locked down.

First recapture the pin. Run the suite; the failing test prints the actual digest:

```text
    matches the pinned digest (the contract EP-7 reproduces): FAIL
      expected: "30b2015562ec8b5cd4fdb64c7cc671c84f56f80d24891deec6676c521f008113"
       but got: "<64 hex chars — the new v2 digest>"
```

Copy the `but got` value into `pinnedKey` at line 67. (The fixture request `(fixModel, fixCtx, fixOpts)` at lines 51-61 uses `user "ping"`, whose fixture timestamp is fixed, so the new digest is again fully deterministic.)

Fix the versioning test at lines 247-252: it hard-codes `"shikumi-cache/v1"` vs `"shikumi-cache/v2"` as the "current vs hypothetical next" pair. Change it to compare `currentKeyVersion` against `"shikumi-cache/v3"` so it never goes stale on a future bump.

Then extend `keyTests` (the `testGroup "cache key"` starting at line 136) with five cases, following the exact style of the existing "a different request yields a different key" case (lens updates on the fixtures; `Data.Generics.Labels` is already imported, as are `(&)` and `(.~)`; you will additionally need `Data.Map.Strict qualified as Map`, `Baikai (userAt)`, and `Shikumi.Cache.Key (stripMessageTimestamps)` — plus `Data.Time.Clock (UTCTime)` is already there):

1. baseUrl discrimination: `cacheKey (fixModel & #baseUrl .~ "https://proxy.internal") fixCtx fixOpts /= cacheKey fixModel fixCtx fixOpts`.
2. Model-headers discrimination: `fixModel & #headers .~ Map.singleton "anthropic-beta" "context-1m-2025-08-07"` changes the key.
3. Options-headers discrimination: `fixOpts & #headers .~ Map.singleton "anthropic-beta" "output-128k-2025-02-19"` changes the key.
4. Compat discrimination: `fixModel & #compat .~ CompatAnthropicMessages ...` changes the key versus `CompatNone` (import the compat constructor and a record value from `Baikai`; if constructing a compat record is noisy, discriminating on `baseUrl`+`compat` together is acceptable, but prefer the direct field).
5. Timestamp insensitivity: build two contexts identical except for message timestamps —

```haskell
testCase "message timestamps do not affect the key" $ do
  let t1 = read "2026-01-01 00:00:00 UTC" :: UTCTime
      t2 = read "2026-06-30 12:34:56 UTC" :: UTCTime
      ctxAt t = fixCtx & #messages .~ V.singleton (userAt t "ping")
  cacheKey fixModel (ctxAt t1) fixOpts @?= cacheKey fixModel (ctxAt t2) fixOpts
```

Also assert the fixture context (built with `user`, fixture timestamp) and `ctxAt t1` agree — proving `user`-built and `userAt`-built messages now coincide.

6. The over-stripping guard: two requests whose assistant tool-call arguments differ only in a `"timestamp"` argument must produce different keys. The lightest honest version tests the helper directly on a hand-built `Value` shaped like a serialized message vector:

```haskell
testCase "stripMessageTimestamps removes only the payload-level timestamp" $ do
  let msg inner =
        object
          [ "tag" .= ("UserMessage" :: T.Text),
            "contents"
              .= object
                [ "timestamp" .= ("2026-01-01T00:00:00Z" :: T.Text),
                  "content" .= [object ["args" .= object ["timestamp" .= inner]]]
                ]
          ]
      stripped x = stripMessageTimestamps (toJSON [msg (x :: T.Text)])
  assertBool "nested timestamps still discriminate" (stripped "a" /= stripped "b")
  stripped "a" @?= stripped "a"
```

Acceptance for M2: `just test-one shikumi-cache` is fully green; temporarily reverting the M1 edit to `requestToCanonicalValueVersioned` makes tests 1-5 fail (failing-before/passing-after demonstrated).

### Milestone 3: propagate to shikumi-trace

Scope: `shikumi-trace/test/Main.hs` line 305 — set `pinnedKey` to the same new digest as in M2 (the two files intentionally duplicate the constant to prove byte-for-byte agreement; the assertion is at lines 184-187). No source change in `shikumi-trace` is needed: `llmAttrs` and `runLLMReplay` call the key function, so they follow automatically, and the trace suite's replay tests record and replay within one process under one key version.

Also add, to the `Key.hs` haddock for `currentKeyVersion`, the sentence about trace invalidation written in M1, and record in this plan's Surprises section anything the trace suite reveals.

Acceptance for M3: `just test-one shikumi-trace` is green.

### Milestone 4: document the Cost round-trip

Scope: `shikumi-cache/src/Shikumi/Cache/ResponseJSON.hs`. The module comment (lines 20-25) already says the round-trip "is lossy only for non-terminating repetends"; strengthen it next to `ratField` (lines 61-62) with the concrete consequence: a `CachedResponse` whose cost holds a rational with a non-terminating decimal expansion (denominator with prime factors other than 2 and 5, e.g. `1 % 3`) will not satisfy `Eq` after an encode/decode round-trip; real USD pricing rates are decimal so real responses terminate; do not rely on `Eq` of round-tripped responses for synthetic costs. No behavior change (see Decision Log).

Acceptance for M4: comment-only diff; `just test-one shikumi-cache` still green.


## Concrete Steps

All commands run from the repository root, inside the dev shell.

```bash
cd /path/to/shikumi        # the repo root (contains Justfile and cabal.project)
nix develop .#ghc9124
```

Build and test loop while editing:

```bash
cabal build shikumi-cache
just test-one shikumi-cache
```

Expected transcript after M1 (before M2 recaptures the pin) — the only failures are digest-related:

```text
shikumi-cache
  cache key
    is a 64-char lowercase hex digest:                          OK
    is deterministic:                                           OK
    matches the pinned digest (the contract EP-7 reproduces):   FAIL
    a different request yields a different key:                 OK
  ...
```

After M2 and M3, all green:

```bash
just test-one shikumi-cache
just test-one shikumi-trace
```

```text
All N tests passed (...)
```

Finish with the whole workspace to catch any other consumer of the key or the pinned digest:

```bash
just test
```

(The `shikumi-cache-redis` suite prints a skip notice and exits 0 when no Redis is reachable; the `shikumi-cache-postgres` suite starts its own throwaway server via ephemeral-pg. Neither pins the digest, so neither should change in this plan. If you want the Redis suite to actually run, start local services first with `just services-up` — the dev shell exports `REDIS_SOCKET` for it — and stop them with `just services-down`.)

Commit at each milestone boundary with a conventional-commit subject and the mandatory trailers, e.g.:

```text
feat(cache): hash endpoint identity and ignore message timestamps (key v2)

MasterPlan: docs/masterplans/7-cache-trace-and-replay-hardening.md
ExecPlan: docs/plans/40-cache-key-v2-endpoint-completeness.md
Intention: intention_01kwgdyxm7ehh8yys1pp4wf1zr
```

Every commit in this plan carries those same three trailers.


## Validation and Acceptance

Behavioral acceptance, all observable through `just test-one shikumi-cache`:

1. Two `Model` values identical except `baseUrl` produce different `cacheKey`s (fails before M1, passes after).
2. Adding an `anthropic-beta` header via `Model.headers` or `Options.headers` changes the key (fails before, passes after).
3. Two requests identical except message timestamps (`userAt t1` vs `userAt t2`) produce the same key (fails before, passes after) — this is the fix for guaranteed-miss/unbounded-growth behavior.
4. The pinned digest test passes with a new 64-hex constant, and the identical constant passes in `shikumi-trace`'s "cacheKey reproduces EP-6's pinned digest" test — proving the two packages still agree byte-for-byte.
5. `stripMessageTimestamps` preserves nested `"timestamp"` keys (the guard test).
6. Storing under v2: run the existing memoize test group — a HIT requires `keyVersion cr == currentKeyVersion` (`shikumi-cache/src/Shikumi/Cache.hs:66`), and the existing "foreign keyVersion is ignored" test (which stores under `"shikumi-cache/v0"`) still passes unchanged, demonstrating v1-era entries are unreachable under v2 both by key bytes and by the version guard.

Beyond compilation, the end-to-end story: with a memory-backed `cachedLLM` and a counting stub provider (exactly the harness in `memoizeTests`), issue the same logical request built with two different wall-clock timestamps and observe one provider call — before this plan it was two.


## Idempotence and Recovery

Every step is a source edit plus a test run; all are safely repeatable. The digest recapture is self-correcting: if you mis-paste the pin, the test fails and prints the correct value again. If the v2 field set needs another adjustment after landing (a forgotten field), the recovery path is the designed one — adjust the field set, bump to `"shikumi-cache/v3"`, recapture both pins — never edit the field set without a version bump, because same-version entries with different byte layouts would corrupt HIT semantics. No data migration is needed at any point: stale-version cache rows are simply unreachable and get overwritten lazily, and old trace files fail closed on replay.


## Interfaces and Dependencies

Libraries already in place: `aeson` (canonical value assembly; `Data.Aeson.KeyMap` for the strip), `blake3` (hashing, untouched), `lens` + `generic-lens` labels (field access), `tasty`/`tasty-hunit` (tests). baikai is consumed read-only; its source is at the path given by `mori registry show baikai --full`.

Signatures that must hold at the end (all in `Shikumi.Cache.Key`, module file `shikumi-cache/src/Shikumi/Cache/Key.hs`):

```haskell
currentKeyVersion :: Text                                      -- "shikumi-cache/v2"
cacheKey :: Model -> Context -> Options -> CacheKey            -- unchanged shape
requestToCanonicalValue :: Model -> Context -> Options -> Value
requestToCanonicalValueVersioned :: Text -> Model -> Context -> Options -> Value
stripMessageTimestamps :: Value -> Value                       -- newly exported
```

The canonical top-level field set for v2, sorted as `canonicalJSON` emits it: `api`, `baseUrl`, `compat`, `maxTokens`, `messages`, `model`, `modelHeaders`, `optionsHeaders`, `provider`, `responseFormat`, `systemPrompt`, `temperature`, `thinking`, `toolChoice`, `tools`, `version`.

Downstream interface consumers that must not need code changes (verify by building): `Shikumi.Cache.cachedLLM`, `Shikumi.Trace.llmAttrs`, `Shikumi.Trace.Replay.runLLMReplay`, `Shikumi.Trace.Store.replayIndex`, and the backend test suites in `shikumi-cache-redis`/`shikumi-cache-postgres`. Plan `docs/plans/42-replay-divergence-detection-and-trace-concurrency-safety.md` builds on the post-bump function; it must not start before this plan is complete.
