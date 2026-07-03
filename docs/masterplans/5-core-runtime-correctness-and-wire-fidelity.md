---
id: 5
slug: core-runtime-correctness-and-wire-fidelity
title: "Core Runtime Correctness and Wire Fidelity"
kind: master-plan
created_at: 2026-07-02T03:29:36Z
intention: "intention_01kwjfe4dhetqa7m7g3n6zq03a"
---

# Core Runtime Correctness and Wire Fidelity

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

Shikumi's core promise is that a language-model program declared as typed records behaves
like ordinary typed software: the declared validation rules run, the wire request matches
what the model is told to do, streaming and blocking execution produce the same typed
result under the same interpreters, and the combinator surface does what its documentation
says. A production-readiness code review of the core `shikumi` package found that promise
broken in four distinct ways, and this initiative closes all four before production use.

After the initiative is complete: (1) a user-supplied `Validatable` rule on an output type
reliably surfaces as a `ValidationFailure` through every runner — `runProgram`,
`runProgramConc`, `streamProgram`, and the derived modules such as `chainOfThought` —
instead of being silently skipped in favor of a catch-all "always valid" instance;
(2) the native structured-output path is coherent — native JSON parse errors are reported
instead of a misleading marker-parser error, the prompt sent to a native-capable model
describes the JSON reply it is forced to produce (not `[[ ## marker ## ]]` sections), demos
are rendered in the format the model is asked to reply in, and the derived JSON Schemas
satisfy OpenAI strict mode (required-but-nullable optional fields, typed enums);
(3) `streamProgram` works under routing against real providers — the router rewrites the
`Stream` operation exactly as it rewrites `Complete`, the streaming predict path reuses the
blocking path's signature overlay and dual-format parser instead of divergent copies, and
stream failures surface out-of-band as typed transient errors so retry policies and budget
accounting behave coherently; (4) the combinator and budget tail is honest —
`majorityVoteBy` applies its temperature schedule, the budget gate's optimistic (reserve
nothing) semantics are named and tested, and the exported partial functions (`modal`,
`chain`, `parseBound`, unclamped `spreadTemps`, advice-failure abort in `refine`) are made
total or their failure mode made deliberate and observable.

In scope: the `shikumi` package's runtime modules (`Shikumi.Program`, `Shikumi.Schema`,
`Shikumi.Schema.Types`, `Shikumi.Adapter`, `Shikumi.Routing`, `Shikumi.Stream`,
`Shikumi.LLM`, `Shikumi.LLM.Budget`, `Shikumi.Module`, `Shikumi.Combinator`,
`Shikumi.Refine`), plus the mechanical downstream updates in the other in-repo packages
(`shikumi-tools`, `shikumi-trace`, `shikumi-compile`, `shikumi-jitsurei`, and test fixtures
across packages) that the breaking `Validatable` and `MajorityVote` changes force.

Out of scope: optimizer and evaluation correctness (owned by
`docs/masterplans/6-optimizer-and-evaluation-correctness.md`), cache/trace/replay hardening
(master plan 7), tools/agents/CLI hardening (master plan 8), CI (master plan 9), any change
to the `baikai` transport library itself (all fixes stay on shikumi's side of the `LLM`
effect), and per-node XML adapter selection through the `Program` GADT (explicitly deferred;
see EP-33's Decision Log).


## Decomposition Strategy

The review findings cluster into four functional concerns, and each concern is one child
plan: validation dispatch (EP-32), native wire fidelity and schema shape (EP-33), streaming
routing and resilience (EP-34), and the combinator/budget semantics tail (EP-35). The
decomposition follows functional behavior rather than files: several plans touch the same
files (`Shikumi/Program.hs`, `Shikumi/Stream.hs`, `Shikumi/Routing.hs`), but each plan owns
one independently demonstrable behavior with its own failing-before/passing-after tests, so
each can be verified without the others being complete.

Principles applied: severity-first ordering (the HIGH-severity `Validatable` dispatch bug is
EP-32 and has no dependencies, so it can start immediately); dependency minimization (all
inter-plan relationships are soft or integration dependencies — no plan's code fails to
compile without another's artifacts, because each plan carries its own constraint and
signature changes); and independent verifiability (EP-32 is proven by validation tests
through every runner, EP-33 by wire-shape assertions against a capturing stub router, EP-34
by routed-streaming and stream-retry tests, EP-35 by combinator/budget unit and concurrency
tests).

Alternatives considered and rejected. A single monolithic ExecPlan was rejected: the work
spans four separable behaviors, more than ten files, and two breaking API changes whose
migrations are easier to review in isolation. Splitting by file (one plan per module) was
rejected because the behaviors cross module boundaries — e.g. validation dispatch spans
`Schema.hs`, `Program.hs`, `Stream.hs`, `Module.hs`, and every downstream package. Merging
EP-33 and EP-34 (both touch the parse/render seam) was rejected because native wire
fidelity is demonstrable entirely on the blocking path while streaming unification is
demonstrable entirely against scripted event streams; keeping them separate lets the
MEDIUM-severity streaming work proceed even if the adapter-channel design in EP-33 takes
longer. Folding the small EP-35 items into the other plans was rejected because they share
no behavior with them and would blur each plan's acceptance criteria.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 32 | Fix Validatable Dispatch in Program Runners | docs/plans/32-fix-validatable-dispatch-in-program-runners.md | None | None | Complete |
| 33 | Native Adapter Path and Strict-Mode Schemas | docs/plans/33-native-adapter-path-and-strict-mode-schemas.md | None | EP-32 | Complete |
| 34 | Route and Unify Program Streaming | docs/plans/34-route-and-unify-program-streaming.md | None | EP-32, EP-33 | Complete |
| 35 | Combinator and Budget Semantics Cleanup | docs/plans/35-combinator-and-budget-semantics-cleanup.md | None | None | Complete |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-32).


## Dependency Graph

There are no hard dependencies: every plan compiles and is testable on its own, because each
plan makes its own constraint and signature changes rather than consuming another plan's new
types. The soft dependencies express merge-order preference, not blockage.

EP-32 should land first. It deletes the catch-all `instance {-# OVERLAPPABLE #-}
Validatable a` in `shikumi/src/Shikumi/Schema.hs` and adds `Validatable` constraints to
`runPredict` (`shikumi/src/Shikumi/Program.hs`) and `streamPredict`
(`shikumi/src/Shikumi/Stream.hs`). EP-33 and EP-34 edit the same functions (`parseResponse`,
`runPredict`, `streamPredict`); if they land before EP-32 the code still works, but the
constraint rows they write will be rewritten by EP-32, so EP-32-first minimizes rebasing.

EP-34 is soft-dependent on EP-33 in one substantive way: EP-33 changes `parseResponse`
(`shikumi/src/Shikumi/Program.hs:330-339`) to keep the native JSON parse error, and EP-34
makes `streamPredict` call `parseResponse` instead of a single adapter's `parse`. EP-34 works
against either version of `parseResponse` — it consumes the function's surface, not its new
behavior — but if EP-34 lands first, streamed native-path parse errors keep the old
misleading `MissingField` shape until EP-33 lands. EP-33's router-side render swap in
`translateForWire` also flows to the streaming path for free once EP-34 routes the `Stream`
operation through the same translation.

EP-35 is independent of the other three and can proceed in parallel at any time. Its only
coupling is mechanical: its `MajorityVote` constructor change touches pattern matches in
`shikumi/src/Shikumi/Stream.hs`, `shikumi-trace/src/Shikumi/Trace/Program.hs`,
`shikumi-trace/src/Shikumi/Trace/Node.hs`, `shikumi-compile/src/Shikumi/Compile/RAG.hs`, and
`shikumi-compile/src/Shikumi/Compile/ChainOfThought.hs` — trivially re-resolvable against the
other plans' edits.

Parallelization guidance: EP-32 and EP-35 can start immediately and in parallel (they touch
`Shikumi/Program.hs` in disjoint regions: constraints/instances vs. the `MajorityVote`
constructor and temperature helpers). EP-33 can start in parallel with EP-32 if the
implementer accepts a rebase of `parseResponse`'s constraint row. EP-34 should start after
EP-33's `translateForWire` signature settles, or coordinate on integration point 3 below.


## Integration Points

Integration point 1 — `runPredict` / `parseResponse` in `shikumi/src/Shikumi/Program.hs`.
Involved: EP-32 and EP-33. EP-32 owns the constraint rows (it adds `Validatable o` to
`runPredict`, currently lines 304-311, and keeps it on `parseResponse`). EP-33 owns the
behavior of both functions (native-error fidelity in `parseResponse`; stamping the native
render alternative onto the metadata channel in `runPredict`) and additionally exports them
for EP-34. Whichever lands second rebases onto the other's edits; the functions' names,
module, and argument order must not change in either plan.

Integration point 2 — `streamPredict` and the `MajorityVote` match in
`shikumi/src/Shikumi/Stream.hs`. Involved: EP-32, EP-34, EP-35. EP-34 owns the final shape of
`streamPredict` (delete the duplicated `effectiveSig`, reuse `Shikumi.Program`'s exported
`effectiveSignature` and `parseResponse`, add `attachSchema`). EP-32 only adds the
`Validatable o` constraint to whatever `streamPredict` signature exists at the time. EP-35
only re-arities the `MajorityVote _ _ _` pattern (line 230) when the constructor gains its
reducer field.

Integration point 3 — `routeLLM` / `translateForWire` in `shikumi/src/Shikumi/Routing.hs`.
Involved: EP-33 and EP-34. EP-33 owns `translateForWire`: it widens the function from
`Model -> Options -> Options` to `Model -> Context -> Options -> (Context, Options)` so the
router can swap the system prompt and demo turns for native-capable models. EP-34 adds the
`Stream` case to `routeLLM` and must call whatever `translateForWire` exists — the plan is
written to work against either the old or the widened signature, and must not fork a second
translation function.

Integration point 4 — the reserved metadata keys in `shikumi/src/Shikumi/Adapter.hs`.
Involved: EP-33 (defines `metaNativePromptKey` and `metaNativeDemosKey` next to the existing
`metaResponseSchemaKey` / `metaTemperatureKey`) and EP-34 (its routed `Stream` path must
strip and honor exactly the same key set via `translateForWire`; it defines no keys of its
own). EP-33 is the single source of truth for key names and payload shapes.

Integration point 5 — the pinned schema shape. Involved: EP-33 (changes
`expectedSummarySchema` in `shikumi/test/SchemaSpec.hs` and `enumSchema` /
`objectSchema`-required behavior in `shikumi/src/Shikumi/Schema.hs` and
`shikumi/src/Shikumi/Schema/Types.hs`). Any other plan or package that pins a derived schema
(e.g. `shikumi/test/RoutingSpec.hs` compares `responseFormat` against `deriveSchema`,
which self-updates) consumes EP-33's shape; no other plan may edit the schema constructors.

Cross-initiative note: `docs/masterplans/6-optimizer-and-evaluation-correctness.md`'s EP-39
(`docs/plans/39-evaluation-accounting-and-api-tail.md`) touches stream usage accounting in
`shikumi-eval` and consumes the routed `Stream` operation delivered by EP-34 (soft
dependency: EP-39 can proceed against unrouted streams, but its usage-accounting assertions
only become meaningful for real providers once EP-34 lands). Coordinate the stream-error
posture EP-34 defines (terminal `EventError` becomes an out-of-band `ShikumiError`, budget
charged from the terminal payload before throwing) with EP-39's accounting expectations.

Cross-initiative note 2 — shared test fixtures. `docs/masterplans/9-ci-and-shared-test-infrastructure.md`'s
EP-49 (`docs/plans/49-shared-test-harness-and-fixture-diversification.md`) introduces an
internal `shikumi-testing` package whose `Shikumi.Testing.Fixtures` module exports a
rule-carrying output type (`Answer`, with a failing-able `validate`) mirroring EP-32's
package-local `Verdict` fixture. EP-32 deliberately keeps `Verdict` in `shikumi/test`
because `shikumi-testing` depends on the `shikumi` library and the core suite consuming it
would invert the repository's layering. The fixture shapes are intentionally aligned;
whichever plan lands second checks for drift and records any in Surprises & Discoveries.


## Progress

Track milestone-level progress across all child plans. Each entry names the child plan
and the milestone. This section provides an at-a-glance view of the entire initiative.

- [x] EP-32: M1 — catch-all `Validatable` instance deleted, constraints threaded, all packages migrated and building (2026-07-03)
- [x] EP-32: M2 — validation failures proven through `runProgram`, `runProgramConc`, `streamProgram`, and `chainOfThought` (2026-07-03)
- [x] EP-32: M3 — migration documented (haddocks, jitsurei example prose, CHANGELOG) (2026-07-03)
- [x] EP-33: M1 — `parseResponse` keeps the native error for JSON bodies (2026-07-03)
- [x] EP-33: M2 — strict-mode schema shape (required-but-nullable `Maybe`, typed enums) with goldens deliberately updated (2026-07-03)
- [x] EP-33: M3 — native render channel: router swaps guide and demos for native-capable models; native demos rendered as JSON (2026-07-03)
- [x] EP-34: M1 — `routeLLM` rewrites the `Stream` operation (model, metadata translation, stripping) (2026-07-03)
- [x] EP-34: M2 — `streamPredict` reuses `effectiveSignature`, `attachSchema`, and `parseResponse` (2026-07-03)
- [x] EP-34: M3 — stream errors surface out-of-band; retries fire; budget charging documented and tested (2026-07-03)
- [x] EP-35: M1 — `MajorityVote` carries its reducer; `majorityVoteBy` applies its `TempSchedule`; `modal` total (2026-07-03)
- [x] EP-35: M2 — budget admission gate renamed/documented with a concurrent overshoot test (2026-07-03)
- [x] EP-35: M3 — partial-function tail (`chain`, `parseBound`, `spreadTemps` clamp, refine advice failure) closed (2026-07-03)


## Surprises & Discoveries

Document cross-plan insights, dependency changes, scope adjustments, or unexpected
interactions between child plans. Provide concise evidence.

- EP-32 (2026-07-03): the compile-driven migration touched more types than the
  survey enumerated — notably `WeatherResp` in `shikumi-tools/test/Fixtures.hs`,
  which is a tool *result* type but is also used as a `Predict` output in the
  Compaction/Acceptance/Protocol/ReAct specs, so it needed a `Validatable`
  instance. Downstream plans that add `Predict` output types must remember the
  now-mandatory instance. Full list in EP-32's Surprises & Discoveries.
- EP-32 (2026-07-03): fixture-drift check against EP-49's planned
  `Shikumi.Testing.Fixtures` (integration point / cross-initiative note): the
  `shikumi-testing` package does not yet exist in the tree, so `Verdict` had
  nothing to diverge from. When EP-49 lands its `Answer` fixture, whoever lands
  second should confirm the two rule shapes still align (`Verdict`'s rule is
  "score ≤ 10", surfaced as `ValidationFailure "score: must be at most 10"`).
- EP-32 (2026-07-03): integration points 1 and 2 left clean for EP-33/EP-34 — only
  constraint rows were added to `runPredict` (`Program.hs`) and `streamPredict`
  (`Stream.hs`); their bodies are untouched, so EP-33/EP-34 rebase onto a
  `(FromModel i, FromModel o, ToSchema o, Validatable o, ToPrompt i, ToPrompt o)`
  row without body conflicts.
- EP-33 (2026-07-03): integration point 3 delivered — `translateForWire` is now
  `Model -> Context -> Options -> (Context, Options)` and `routeLLM`'s `Complete`
  case threads the rewritten `Context`. EP-34's routed `Stream` case must call this
  same widened function (not a second translation path). Integration point 4
  delivered — EP-33 defined `metaNativePromptKey` / `metaNativeDemosKey` next to the
  existing schema/temperature keys; EP-34's `Stream` path must strip and honor the
  same four-key set via `translateForWire` and define none of its own.
- EP-33 (2026-07-03): two deviations for EP-34 to note. (1) `nativeRenderPieces`
  ships as `(ToSchema o, ToPrompt o) => Signature i o -> (Text, [Text])` — the
  planned `ToPrompt i` was dropped as redundant. (2) `parseResponse` (which EP-34
  reuses on the streaming path) now branches on `assistantJSON resp`: JSON body →
  native parser (keeps the located error), non-JSON → fallback parser. It also
  gained no new arguments, so EP-34 consumes the same surface.
- EP-33 (2026-07-03): reusable fact for EP-34 and EP-39 — signature-level demos set
  via `setDemos` are dropped by `effectiveSignature` (it overwrites a node's demos
  with the JSON-decoded `Params.demos`). Tests that need demos on the wire must
  supply them through the node's `Params` channel, as EP-33's native-demos router
  test does.
- EP-34 (2026-07-03): the pinned baikai (baikai 0.1.x / 0.1.2.0) contradicts the
  Decision Log's assumption that a terminal payload carries a structured
  `errorInfo :: Maybe BaikaiError`. Its `TerminalPayload` is `{reason, message}`
  only; stream-failure detail lives in the assembled message's `errorMessage` and
  `stopReason`. So EP-34's stream-error posture maps every terminal `EventError` to
  a transient `ProviderFailure` (still `isTransient`, so retries fire) rather than
  dispatching through `fromBaikaiError`. Cross-initiative note for EP-39
  (`docs/plans/39-evaluation-accounting-and-api-tail.md`): the routed `Stream`
  operation now sends the real model id and strips metadata, and stream failures are
  out-of-band `ProviderFailure`s (never in-band `EventError`) with budget charged
  from the terminal before the throw — EP-39's usage-accounting assertions should
  align to this posture.
- EP-34 (2026-07-03): integration points 2, 3, 4 all honored — `streamPredict`
  reuses `Shikumi.Program`'s exported `effectiveSignature`/`parseResponse` and the
  same `attachSchema`/`attachNativeRender` stamps as `runPredict` (no forked
  translation, no second parser); `routeLLM`'s `Stream` case calls the same widened
  `translateForWire` EP-33 delivered and strips the same four metadata keys.
- EP-35 (2026-07-03): integration point 2 (shared `Program.hs`/`Stream.hs`) resolved
  cleanly — EP-35's `MajorityVote` constructor and temperature-helper edits were
  disjoint from EP-32's constraint rows and EP-34's `streamPredict` body, and rebased
  mechanically. The arity change reached two consumers the plan did not enumerate
  (`Refine.hs`'s two `sampleTemps` calls; test-side `RefineStub`/`CombinatorSpec`) —
  found by `cabal build all`. Fixture-drift note (EP-49, master plan 9): the shared
  `shikumi-testing` package still does not exist in the tree, so EP-32's local
  `Verdict` fixture had nothing to diverge from across the whole initiative.
- Process (2026-07-03): mid-implementation an external `git checkout 2a12176`
  detached HEAD and reset the working tree, appearing to wipe all work; the commits
  were intact on `master` (recovered via `git checkout master`). Only uncommitted
  EP-34 M1/M2 edits were lost and redone. Lesson applied for the rest of the
  initiative: commit each milestone immediately after its tests pass.


## Decision Log

- Decision: Decompose the production-readiness review findings for the core `shikumi`
  package into four ExecPlans by functional concern — EP-32 validation dispatch (HIGH),
  EP-33 native adapter path and strict-mode schemas (MEDIUM), EP-34 streaming routing and
  unification (MEDIUM), EP-35 combinator/budget semantics tail (MEDIUM-LOW) — with no hard
  dependencies, soft ordering EP-32 → EP-33 → EP-34, and EP-35 free-floating.
  Rationale: each cluster is one independently demonstrable behavior with its own
  failing-before/passing-after tests; the two breaking API changes (deleting the catch-all
  `Validatable` instance; generalizing the `MajorityVote` constructor) are isolated in
  EP-32 and EP-35 respectively so their cross-package migrations can be reviewed alone; the
  shared files (`Program.hs`, `Stream.hs`, `Routing.hs`) are governed by the Integration
  Points section rather than by merging plans, keeping every plan under three milestones.
  Source: production-readiness code review of the `shikumi` package.
  Date: 2026-07-01

- Decision: All findings' fixes stay on shikumi's side of the `LLM`/`Baikai` effect seam; no
  change to the `baikai` repository is in scope.
  Rationale: `baikai-effectful`'s `streamCollect` already surfaces provider failures in-band
  as a terminal `EventError` by design (`baikai-effectful/src/Baikai/Effectful.hs:68-71`),
  and `Baikai.Context` has `ToJSON` but no `FromJSON`, so designs requiring cross-repo
  changes (e.g. stamping a whole alternative `Context` into request metadata) were rejected
  in favor of designs expressible with the existing baikai surface.
  Date: 2026-07-01


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original vision.

Complete — all four child plans landed, closing every one of the four review
findings the initiative set out to fix. Measured against the Vision & Scope's four
promises:

1. Validation dispatch (EP-32): the catch-all `Validatable` instance is gone and a
   user rule surfaces as `ValidationFailure` through `runProgram`, `runProgramConc`,
   `streamProgram`, and `chainOfThought` — proven by four failing-before/passing-after
   cases. The breaking opt-in migration was carried across every in-repo package.
2. Native wire fidelity and strict-mode schemas (EP-33): `parseResponse` keeps the
   located native error for JSON bodies; a routed native-capable model receives a
   JSON-shaped prompt and JSON demos (native render channel); derived schemas satisfy
   OpenAI strict mode (required-but-nullable `Maybe`, typed enums).
3. Streaming routing and resilience (EP-34): `routeLLM` rewrites `Stream` exactly as
   `Complete`; `streamPredict` reuses the blocking path's overlay, stamps, and parser;
   stream failures surface out-of-band as transient `ProviderFailure`s that retry, with
   budget charged from the terminal first.
4. Combinator/budget tail (EP-35): `majorityVoteBy` applies its `TempSchedule`; the
   budget gate is honestly named `admitCall` with a pinned overshoot test; the
   partial-function tail (`chain`, `modal`, `sampleTemps`, `parseBound`, `spreadTemps`,
   `refine` advice) is closed.

Final state: `cabal build all && cabal test all` is green; the shikumi suite grew from
~120 to 141 tests. The only remaining warnings are pre-existing and in other master
plans' packages (`shikumi-cache-postgres` → MP7, `shikumi-eval` → MP6). All commits
carry the `MasterPlan:`/`ExecPlan:`/`Intention:` trailers.

Decomposition held up: the four plans were genuinely independently verifiable, the
soft ordering EP-32 → EP-33 → EP-34 paid off (EP-33 settled `translateForWire` and
`parseResponse` before EP-34 consumed them), and EP-35 floated free. The main surprise
was a dependency-version mismatch: the pinned baikai lacks the structured
`errorInfo`/`FromJSON` surfaces some plans assumed, which pushed EP-34's stream-error
mapping to `ProviderFailure` (posture unchanged) — a reminder to verify the pinned
dependency, not the working-tree sibling, when a plan cites transport internals.


## Revision Notes

- 2026-07-01: Added the cross-initiative integration note on shared test fixtures
  (EP-49's `Shikumi.Testing.Fixtures` under `docs/masterplans/9-ci-and-shared-test-infrastructure.md`
  versus this initiative's package-local fixtures). Reason: master plan 9 and its
  children were authored in parallel with this plan, so the fixture seam was documented
  on only one side; the affected child plans carry matching Decision Log entries.
