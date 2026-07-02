---
id: 7
slug: cache-trace-and-replay-hardening
title: "Cache, Trace, and Replay Hardening"
kind: master-plan
created_at: 2026-07-02T03:29:36Z
intention: "intention_01kwgdyxm7ehh8yys1pp4wf1zr"
---

# Cache, Trace, and Replay Hardening

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

shikumi ships five observability and caching packages around its typed LM programs: `shikumi-cache` (the content-addressed response cache and the `cachedLLM` memoizer), `shikumi-cache-redis` and `shikumi-cache-postgres` (server-backed cache backends), `shikumi-trace` (hierarchical span capture, on-disk trace files, and deterministic offline replay), and `shikumi-trace-otel` (OpenTelemetry export of finished trace trees). A production-readiness code review of these packages (2026-06, verified against source) found a cluster of correctness gaps: the cache key omits request fields that change model behavior while including message timestamps that do not; the four cache backends disagree on eviction and error posture (one of them crashes the host program on a storage hiccup); replay silently serves one recorded response for several distinct call occurrences; the trace builder corrupts state under concurrent execution; and the OTel exporter leaks its provider on exception, mislabels statuses and response models, and can recurse forever on a corrupt trace file.

After this initiative, the picture is: two deployments that differ only in endpoint or headers never share cache entries, and re-running the same conversation never floods the store with timestamp-distinct copies of one request. Every cache backend has the same contract — best-effort (a storage failure degrades to a MISS or a skipped write, never a crash), no eviction by default, one opt-in TTL knob — and in-band error responses are never memoized. Replay either reproduces a recorded run faithfully or fails closed with a loud, typed divergence; it never silently collapses distinct call occurrences. Trace capture is safe (or loudly unsafe) under `runProgramConc`; second roots, retry counts, sibling ordering past nine children, and old trace-file versions all behave sensibly. OTel export always releases its tracer provider, reports honest span statuses and response models, handles never-closed spans without fabricating durations, and terminates on malformed trees.

In scope: the five packages named above, the `cachedLLM` policy layer, the shared cache-key function, the trace store/replay/render paths, and each package's test suite. Out of scope: CI enforcement of the redis/postgres suites' skip behavior (that belongs to `docs/masterplans/9-ci-and-shared-test-infrastructure.md` — this initiative only makes the skips loud), any change to baikai itself, live-provider behavior, streaming capture/replay (streams remain untraced-in-detail and unreplayable by design), and cache backends beyond the four that exist.


## Decomposition Strategy

The review findings cluster into four functional concerns that touch mostly disjoint code and are independently verifiable, so the initiative decomposes into four ExecPlans rather than one sprawling plan or a per-package split.

The first concern is the identity of a request: what bytes feed the BLAKE3 cache key. That is one function (`requestToCanonicalValueVersioned` in `shikumi-cache/src/Shikumi/Cache/Key.hs`) plus a version constant and two golden tests, but it is the single most load-bearing artifact in the whole area — `cachedLLM`, all four backends, trace capture (`llmAttrs`), and replay (`runLLMReplay`, `replayIndex`) all key off it. Changing it invalidates every stored entry and every recorded trace, so it must be its own plan (EP-40) and it must land before the replay work that pins keys in tests.

The second concern is backend semantics: eviction, error posture, connection hygiene, and the memoizer's storage policy. These findings span four backend modules in three packages plus `cachedLLM`, but they are one decision ("what is the contract of a cache backend?") applied uniformly, so they form one plan (EP-41). Splitting per backend was rejected: the whole point is that the backends must agree, and four tiny plans would each re-litigate the same posture decision.

The third concern is trace/replay fidelity under repetition and concurrency (EP-42): duplicate cache keys in the replay index, non-atomic trace state, and a tail of smaller trace bugs (dropped second roots, dead retry counters, sibling ordering, version policy). These share the `shikumi-trace` package and the replay index data structure, and they must be written against the post-bump key function, hence the hard dependency on EP-40.

The fourth concern is OTel export correctness (EP-43): five localized bugs in `shikumi-trace-otel` that touch no shared artifact except the read-only `TraceTree` type. It is fully parallel to everything else and deliberately last in priority (LOW severity).

An alternative decomposition — one plan per severity tier — was rejected because it would put the key change and the backend change in one plan despite them touching different packages for different reasons, maximizing rather than minimizing coupling.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 40 | Cache Key v2 Endpoint Completeness | docs/plans/40-cache-key-v2-endpoint-completeness.md | None | None | Not Started |
| 41 | Unify Cache Backend Semantics | docs/plans/41-unify-cache-backend-semantics.md | None | EP-40 | Not Started |
| 42 | Replay Divergence Detection and Trace Concurrency Safety | docs/plans/42-replay-divergence-detection-and-trace-concurrency-safety.md | EP-40 | None | Not Started |
| 43 | OTel Export Correctness Tail | docs/plans/43-otel-export-correctness-tail.md | None | None | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-40, EP-42).


## Dependency Graph

EP-40 must complete before EP-42 begins; this is the only hard dependency. The reason is that both plans revolve around the same artifact: the content-addressed cache key computed by `Shikumi.Cache.Key.cacheKey`. EP-40 changes the key's field set and bumps `currentKeyVersion` from `"shikumi-cache/v1"` to `"shikumi-cache/v2"`, which changes every digest the function produces, including the golden digest pinned in both `shikumi-cache/test/Main.hs` and `shikumi-trace/test/Main.hs`. EP-42's replay-divergence detection and its new tests are written directly against key values produced by this function (duplicate-key trees, replay indices keyed by digest). If EP-42 landed first, every one of its pinned expectations would be invalidated the moment EP-40 merged, forcing a second pass. Landing EP-40 first means EP-42 pins post-v2 keys once.

EP-41 has no hard dependency and can proceed in parallel with EP-40. It carries a soft dependency on EP-40 only because both plans edit `shikumi-cache/src/Shikumi/Cache.hs` (EP-40 does not touch `cachedLLM`'s logic, but EP-41 rewrites its documentation and adds a storage guard) and both add tests to `shikumi-cache/test/Main.hs`; whichever lands second rebases trivially. Nothing in EP-41's semantics depends on the v2 key.

EP-43 is fully independent: it touches only `shikumi-trace-otel`, consumes the `TraceTree` type read-only, and can be implemented at any time, in parallel with all other plans.

So the schedule is: EP-40 first (or concurrently with EP-41 and EP-43); EP-42 strictly after EP-40; EP-41 and EP-43 whenever.


## Integration Points

The cache key function. Shared artifact: `Shikumi.Cache.Key.cacheKey`, `requestToCanonicalValueVersioned`, and `currentKeyVersion` in `shikumi-cache/src/Shikumi/Cache/Key.hs`. Involved plans: EP-40 (owner/definer), EP-42 (consumer). This one function is used by `cachedLLM` (`shikumi-cache/src/Shikumi/Cache.hs:63`), by every cache backend test, by trace capture (`llmAttrs` in `shikumi-trace/src/Shikumi/Trace.hs:350` stamps the key onto every LM-call span), and by replay (`shikumi-trace/src/Shikumi/Trace/Replay.hs:65` recomputes the key at replay time; `replayIndex` in `shikumi-trace/src/Shikumi/Trace/Store.hs` maps recorded keys to responses). EP-40 changes the field set and bumps the version; the same golden digest is pinned in `shikumi-cache/test/Main.hs:67` and `shikumi-trace/test/Main.hs:305`, and EP-40 updates both. Consequence EP-42 must respect: a key-version bump invalidates all previously recorded traces (an old trace's stored keys no longer match keys recomputed by the new build, so replay of an old file raises `ReplayDivergence`); EP-42's divergence detection and all its fixtures must be written against the post-bump function.

The `cachedLLM` policy layer. Shared artifact: `cachedLLM` in `shikumi-cache/src/Shikumi/Cache.hs:57-72`. Involved plans: EP-41 (owner), EP-40 (adjacent). EP-41 decides the error posture (best-effort everywhere), adds the never-cache-error-responses guard, introduces the shared `CacheConfig` TTL knob at this layer, and rewrites the module's posture documentation, including documenting the acceptable check-then-act double-fetch race. EP-40 leaves `cachedLLM`'s logic untouched (it only changes what `cacheKey` returns), so the only coordination is textual merge order in `Cache.hs` and in the shared test file `shikumi-cache/test/Main.hs`.

CI enforcement of test skips. Shared concern with another initiative: EP-41 makes the redis/postgres suites' exit-0 skips loud (prominent `SKIPPED` output) but explicitly leaves making CI fail-or-require those suites to `docs/masterplans/9-ci-and-shared-test-infrastructure.md`. EP-41 must not add CI gating; it should leave a marker comment pointing at that master plan.


## Progress

Track milestone-level progress across all child plans. Each entry names the child plan
and the milestone. This section provides an at-a-glance view of the entire initiative.

- [ ] EP-40: M1 — v2 canonical value (endpoint fields in, timestamps out) and version bump
- [ ] EP-40: M2 — shikumi-cache golden digest recaptured and new key-discrimination tests green
- [ ] EP-40: M3 — shikumi-trace pinned digest updated; trace-invalidation consequence documented
- [ ] EP-41: M1 — shared `CacheConfig` and TTL-aware `cachedLLMWith`; never-cache-error guard
- [ ] EP-41: M2 — best-effort posture at all four backends (SQLite no longer crashes); Postgres leak fixed; SQLite WAL/busy_timeout
- [ ] EP-41: M3 — degradation/TTL/corrupt-row tests green; redis/postgres skips loud
- [ ] EP-42: M1 — replay index fails closed on conflicting duplicate keys (tests included)
- [ ] EP-42: M2 — trace state atomic + loud stack-corruption check; concurrency contract documented
- [ ] EP-42: M3 — tail: multi-root rendering, live `bumpRetry`, numeric sibling ordering, v1 trace files accepted
- [ ] EP-43: M1 — provider released on export exception (bracket)
- [ ] EP-43: M2 — status propagation, honest response model, open-span handling, cycle guard
- [ ] EP-43: M3 — four new otel tests green


## Surprises & Discoveries

Document cross-plan insights, dependency changes, scope adjustments, or unexpected
interactions between child plans. Provide concise evidence.

(None yet.)


## Decision Log

Record every decomposition or coordination decision made while working on the master
plan.

- Decision: Decompose the production-readiness review findings for shikumi-cache / shikumi-cache-redis / shikumi-cache-postgres / shikumi-trace / shikumi-trace-otel into four ExecPlans — EP-40 (cache key v2), EP-41 (backend semantics unification), EP-42 (replay divergence + trace concurrency), EP-43 (OTel export tail) — with a single hard edge EP-40 → EP-42.
  Rationale: The findings cluster into four functional concerns with almost disjoint code footprints. The cache key is the one artifact shared across packages (cachedLLM, backends, trace capture, replay), so its change is isolated into the first plan and everything that pins key values (EP-42) is ordered after it; a version bump there invalidates recorded traces and golden digests, which is exactly the kind of silent cross-plan conflict the ordering prevents. Backend posture (EP-41) is one uniform contract decision applied to four modules, so it stays one plan. OTel fixes (EP-43) touch nothing shared and parallelize freely. Per-package and per-severity decompositions were considered and rejected for maximizing coupling.
  Source: production-readiness code review of the cache/trace packages (verified pass).
  Date: 2026-07-01

- Decision: CI enforcement of the redis/postgres test suites' skip behavior is out of scope; EP-41 only makes skips loud.
  Rationale: docs/masterplans/9-ci-and-shared-test-infrastructure.md owns CI policy; duplicating it here would create two owners for one knob.
  Date: 2026-07-01


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original vision.

(To be filled during and after implementation.)
