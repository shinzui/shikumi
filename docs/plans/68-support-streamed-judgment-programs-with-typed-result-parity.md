---
id: 68
slug: support-streamed-judgment-programs-with-typed-result-parity
title: "Support streamed judgment programs with typed result parity"
kind: exec-plan
intention: "intention_01m6frznqber0vzsp9f35ywj68"
created_at: 2026-11-03T03:58:27Z
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-11-03T03:58:27Z
---


# Support streamed judgment programs with typed result parity

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current. Follow `agents/skills/exec-plan/FRICTION.md` for implementation friction and distill durable decisions into ADRs before completion.

## Purpose / Big Picture


Allow an application to run the same typed judgment program with `streamProgram` or `runProgram` and obtain equal rich results under identical immutable parameters. A judgment is a closed question: `Noul` carries a boolean and its probability, `Choice` carries a selected label and its distribution, and `Score` carries a numerical expectation, derived level, and distribution. TypeSafe returns a complete structured answer atomically, rather than producing incremental text.

Implement [IR-5](../improvement-requests/support-streamed-judgment-programs-with-typed-result-parity.md). Demonstrate the behavior with the released TypeSafe provider against a loopback HTTP server, without paid calls. Preserve the original structured answer separately from locally calibrated results, acknowledge actual-attempt evidence before successful return, and deliver documentation, tests, and a tagged Hackage release. Creation of this plan does not itself implement or publish that release.

## Progress


- [ ] M1: Complete and streamed judgments share request preparation and settings-aware decoding; a real TypeSafe loopback proves default and explicit-settings parity.
- [ ] M2: Structured terminal validation, acknowledged attempt receipts, retries, cancellation, and observer/callback failures satisfy the lifecycle acceptance matrix.
- [ ] M3: Structured stream capture/replay and existing cache policy preserve answers without fresh provider evidence; generative regressions pass.
- [ ] M4: Public documentation and ADRs describe the contract; release gates pass and the tagged Hackage artifact is verified, with downstream acceptance tracked separately.

## Surprises & Discoveries


## Decision Log


2026-11-03: Share prediction preparation rather than copying the complete path into streaming. Rendering, validation, and local calibration must have one definition to prevent future drift.

2026-11-03: Numeric thresholds, weights, and cuts remain local and outside request identity, following ADR-15. “Same settings” means identical local derivation and identical selected decision schemas, not sending calibration numbers to TypeSafe.

2026-11-03: Preserve stream cache bypass. Add replay of recorded atomic structured judgments, without introducing general incremental stream persistence. Keep full attempt receipts separate from the deliberately restricted billing observer.

## Outcomes & Retrospective


## Context and Orientation


`shikumi/src/Shikumi/Program.hs` owns `Params`, `runPredict`, `effectiveSignature`, and `parseResponseWithSettings`. `runPredict` validates each decision setting against the output schema, overlays parameters, chooses ordinary versus probability-evidence rendering, stamps structured input state, and derives the result after the response. `shikumi/src/Shikumi/Decision/Setting.hs` defines `NoulSetting`, `ChoiceSetting`, and `ScoreSetting`; these values never enter the provider request or cache key.

`shikumi/src/Shikumi/Stream.hs` currently rejects decision outputs, renders only ordinary schemas, and decodes with default settings. Its `streamComplete` calls `LLM.stream`, which returns a collected event list, then emits text chunks. This is not a live transport iterator. Its response reconstruction currently accepts an error terminal as a source of partial content and falls back to text when a terminal is absent. Structured judgments must require a successful complete terminal. `shikumi/src/Shikumi/Routing.hs` also refuses decision streams before its otherwise shared `translateForWire`. That translation selects the real model, removes private stamps, selects the judgment schema, and sends one structured `UserData` state with no system prompt or tools.

`shikumi/src/Shikumi/LLM.hs` owns bare and resilient interpreters. `transportAttempt` charges budgets and emits an observation for each transport completion before raising provider errors. `retrying` owns transport retries. `shikumi/src/Shikumi/LLM/Observation.hs` exposes a billing summary, deliberately excluding raw output and full evidence; it cannot by itself acknowledge an application's full provider receipt. `shikumi/src/Shikumi/LLM/Defaults.hs` withholds generation defaults for judgment-only models while preserving explicit settings for provider validation.

`shikumi-testing/src/Shikumi/Testing/SystemOne.hs` supplies a real TypeSafe loopback and isolated registry. `shikumi-testing/src/Shikumi/Testing/DecisionFixtures.hs` supplies `Ticket`, `Assessment`, and its three judgments. `shikumi-tools/test/SystemOneIntegrationSpec.hs` already tests complete-call wire behavior. Extend these fixtures; core cannot depend on the core-dependent testing package. `shikumi-cache/src/Shikumi/Cache.hs` bypasses streams and bypasses cache reads/writes when evidence is requested. `shikumi-trace/src/Shikumi/Trace.hs` currently captures only stream usage, while `shikumi-trace/src/Shikumi/Trace/Replay.hs` rejects every Stream operation. `shikumi-trace/test/DecisionReplaySpec.hs` currently covers only complete replay.

Relevant architecture decisions were read:

[ADR-9](../adr/0009-centralize-offline-harness-and-diverse-fixtures.md) places reusable offline fixtures in shikumi-testing and real provider tests in consumers. [ADR-11](../adr/0011-preserve-provider-errors-and-centralize-retry-policy.md) requires structured provider errors, one retry policy, and unchanged host exceptions/cancellation. [ADR-12](../adr/0012-apply-request-defaults-before-cache-and-observation.md) fixes routing → defaults → cache/trace → transport order and evidence bypass. [ADR-13](../adr/0013-separate-transport-billing-from-logical-usage.md) separates logical results from actual attempts and prohibits fabricated cancellation terminals. [ADR-14](../adr/0014-separate-schema-enforcement-from-tool-calling-capability.md) routes judgment-only models by capability. [ADR-15](../adr/0015-derive-decision-answers-from-probability-evidence.md) retains probability evidence and derives answers locally. ADR-14 and ADR-15 explicitly refuse streaming today; revise those exclusions during implementation.

Dependency discovery used Mori. The provider contract is `mori://shinzui/baikai/docs/typesafe-judgments`; its local guide still mentions an older cohort, so it is not the version authority. Hackage and upstream tags checked on 2026-11-03 agree on core 0.10.0.0 and TypeSafe 0.1.0.1, both tag targets `03140cf60381ac154ebfa86d3bb2208d7df8626c`. Current Cabal bounds already select that cohort. In `mori://shinzui/baikai` (artifact-level source URI pending), project-relative `baikai-typesafe/src/Baikai/Provider/TypeSafe/Api.hs` defines `typesafeStream = liftCompleteToStream completeTypeSafe`. The provider performs one nonstreaming HTTP call and emits `EventStart`, `DataStart`, `DataEnd`, `EventDone`, or failure. `DataContent` retains raw value, distributions, optional confidence, and method. Do not recreate its HTTP client or supervisor.

The downstream consumer is `mori://shinzui/shikigami/plans/80-configure-model-providers-and-agent-launches-through-baikai`, with blocking evidence at `mori://shinzui/shikigami/okf/friction-log/concepts/FRIC-49`. This is a standalone follow-up to the existing decision implementation, not a newly enrolled child of MasterPlan 12.

## Plan of Work


### M1 — Shared preparation and first transport proof


Extract the setting validation and rendering portion of `runPredict` into a shared `preparePredict` in `shikumi/src/Shikumi/Program.hs`, returning the effective signature, context, and options. Keep the existing type constraints and error effect; both runners use this helper and `parseResponseWithSettings (decisionSettings ps)`. Preserve ordinary rendering byte-for-byte where possible. Remove the router's blanket streaming refusal while retaining continuation and judgment-schema validation. Do not merely delete the refusals.

Extend `shikumi-tools/test/SystemOneIntegrationSpec.hs` first with complete/stream runs of the existing Assessment fixture through `routeLLM`, defaults, and the released provider. Capture terminal data at the LLM boundary and outgoing requests below routing. Expect one HTTP call per invocation, equal rich results, equal raw `AssistantData`, and identical provider request bodies. Then add explicit `NoulSetting 0.9`, choice weights billing=5 and technical=1, and `ScoreSetting [0.5,1.6]`. Against probabilities urgent=.83, billing=.2/technical=.8, severity=.1/.3/.6, expect false, Billing, and level 1 respectively; default results are true, Technical, and level 2. Expected score remains 1.5. Raw provider choice remains technical. Assert confidence and method are preserved on the raw carrier and every rich type's supported evidence fields survive.

This first real producer/consumer test must pass before expanding lifecycle variants. Pure `StreamSpec`, `RoutingSpec`, and `DecisionDeriveSpec` tests cover preparation equivalence, invalid settings, native JSON, fallback markers, and generative probability evidence, including mixed decision/free-text outputs on generative models.

### M2 — Atomic success and actual-attempt acknowledgement


Add a checked structured-response reconstruction path in `shikumi/src/Shikumi/Stream.hs`. For decision execution require exactly one successful terminal with a complete assistant payload; reject an error terminal, missing terminal, missing structured data, inconsistent data-end/terminal content, or duplicate/conflicting terminals. Preserve original structured content and terminal evidence when reconstructing `Response`; do not synthesize probabilities or convert data to text. Emit no `StreamFieldChunk` for atomic TypeSafe data. Keep text-only compatibility through the existing public `streamComplete` signature; put decision-specific checked behavior in a helper with `Error ShikumiError` rather than silently adding that constraint to existing callers. `LmEnd` for judgments follows successful decode, and no failed path returns a typed value.

Add `shikumi/src/Shikumi/LLM/Evidence.hs` for an opt-in `AttemptReceipt` and `EvidenceObserver = AttemptReceipt -> IO ()`. A receipt contains the existing process-local call ID and attempt ordinal, call kind, and the original Baikai `ModelCallEvidence`; it is an envelope, not a replacement evidence format. Add an additive bare runner accepting this observer, and an optional evidence observer in `LLMConfig` defaulting to absent. Keep existing runner signatures and billing observations. Supply the callback only when actual provider evidence exists; do not invent missing receipts. A caller requests evidence through existing options/defaults. Receipt observation alone does not silently enable evidence.

Invoke the callback in `transportAttempt` after transport settles and budget charging, before return or provider-error propagation, outside `try @BaikaiError`. Returning normally acknowledges receipt. Observer IO exceptions propagate unchanged, even if they contain Baikai errors, and cannot enter the typed retry catch. Every actual retry keeps one logical call ID with increasing attempt ordinal and its own provider evidence. Evidence-disabled callers remain unchanged. Document the public record compatibility impact for release.

Extend the shared fixture with scripted status/reply sequences and cancellation barriers while keeping its existing convenience function. Test transient failure then success with two HTTP attempts and two receipts, and a blocking acknowledgement callback that prevents typed return until released. Test callback exceptions before dispatch and after completion, evidence observer exceptions on success and failure, malformed/missing distributions, and error/missing/duplicate terminals injected by a third-party LLM interpreter. Cancellation tests must wait for request arrival, cancel the operation, join workers, and prove bounded termination and no returned result. Preserve the provider's existing cancellation contract; do not demand or fabricate an aborted receipt where it supplies none. Test both the new full evidence observer and the existing billing observer failure paths.

### M3 — Capture, replay, and cache preservation


In `shikumi-trace/src/Shikumi/Trace.hs`, capture a successful atomic structured stream's terminal response using the existing response codec and request identity, without creating a second logical call or transport receipt. In `shikumi-trace/src/Shikumi/Trace/Replay.hs`, allow a Stream lookup of such a recorded structured response to produce a deterministic atomic sequence with successful terminal, clearing per-call evidence. Keep ordinary unsupported incremental replay fail-closed. Missing or malformed recordings remain `ReplayDivergence` and never fall through to a provider.

Extend `shikumi-trace/test/DecisionReplaySpec.hs` to record a stream, replay it offline, and rederive under changed settings; also replay a compatible complete recording as an atomic judgment stream. Assert raw value/distributions/confidence/method survive serialization, no provider is invoked, and no new receipt or billing attempt appears. Preserve historical evidence only as recorded history, never as evidence for the replay invocation.

Extend `shikumi-cache/test/Main.hs` with complete decision cache-hit and changed-settings coverage, zero fresh evidence, and evidence-request bypass. A live stream through the cache still dispatches: this plan does not add stream memoization. Verify the response codec preserves structured fields. Run existing generative streaming, validation, evidence-disabled, and native JSON regressions across core and consumers.

### M4 — Documentation and release


Update Haddock in Program, Stream, Routing, and LLM; document the new receipt API, callback ordering, collected-event behavior, atomic TypeSafe semantics, and raw-versus-derived distinction. Update `docs/capabilities/typed-streaming.md`, `docs/capabilities/probability-backed-decisions.md`, `docs/capabilities/persistent-decision-settings.md`, their bundle log/index as required, and affected package changelogs. Revise ADR-14 and ADR-15's refusals and ADR-13's boundary description without weakening billing privacy. Follow the profile workflow in `agents/skills/exec-plan/ADR.md` for changed ADRs.

Use `agents/skills/release/SKILL.md` when implementing the release milestone: compute Haskell PVP versions from actual public changes, align internal dependency bounds and the verified released Baikai cohort, run its gates, publish affected public packages in dependency order, and verify tags and Hackage contents. The new public configuration field requires explicit compatibility review, not an assumed patch bump. Record actual versions, tag commits, registry checks, and test evidence here. Track the downstream consumer gate separately; a successful local fixture or upload does not prove that consumer passed. No downstream source edits or messages are required by this plan.

## Concrete Steps


Run from the repository root `/Users/shinzui/Keikaku/bokuno/shikumi`. Nix supplies GHC 9.12.4; do not use the system GHC or inspect `/nix/store`.

```bash
mori registry search baikai
mori registry show shinzui/baikai --full
mori registry docs shinzui/baikai
mori path mori://shinzui/baikai/docs/typesafe-judgments
curl -fsSL https://hackage.haskell.org/package/baikai.json
curl -fsSL https://hackage.haskell.org/package/baikai-typesafe.json
git ls-remote --tags https://github.com/shinzui/baikai.git 'refs/tags/baikai-0.10.0.0*' 'refs/tags/baikai-typesafe-0.1.0.1*'
```

A stale Mori registry may not resolve the new guide; use the registered project root and its docs manifest to locate it. Check authoritative versions again before changing bounds; do not introduce a checkout override.

```bash
nix develop -c cabal test shikumi-tools:test:shikumi-tools-test --test-options='-p SystemOne'
nix develop -c cabal test shikumi:test:shikumi-test
nix develop -c cabal test shikumi-testing shikumi-cache shikumi-trace
```

The initial new SystemOne stream test should reproduce the current decision-stream refusal. After M1 it must pass using actual HTTP capture; M2 adds lifecycle cases to that group. Register any new test modules in the relevant Cabal file and test Main. Successful Tasty runs exit zero with all selected tests passed; record actual counts rather than predicting them.

```bash
nix fmt
nix develop -c cabal build all
nix develop -c cabal test all
nix develop -c scripts/check-haddock.sh
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
git diff --check
```

Use the release skill's additional package checks at M4. Do not select paid/live suites. Update plan provenance using the bundled script on the first substantive edit in each implementation session. Conventional commits must carry both trailers:

```text
ExecPlan: docs/plans/68-support-streamed-judgment-programs-with-typed-result-parity.md
Intention: intention_01m6frznqber0vzsp9f35ywj68
```

## Validation and Acceptance


M1 passes only when default and nondefault Assessment executions produce equal complete/stream rich results and equal raw structured payloads through the public router and released provider. Inspect exact wire model, typed state, criteria, and questions. Inspect options before provider dispatch to prove private rendering metadata is removed and generation defaults are absent. Numeric calibration stays local. Invalid threshold, wrong setting kind, unknown field/weight, invalid cuts, unsupported generation controls, and free-form judgment-only output each cause zero HTTP requests in both modes.

M2 passes only when one successful stream yields the provider's atomic event order, one HTTP invocation, and one acknowledged terminal receipt before typed return. Observe transport events by interposing the public LLM boundary, not by pretending the program callback receives Baikai events. Retry injection produces separate receipts and increasing ordinals. Every failure/cancellation scenario in M2 returns no successful partial judgment, and observer failure never redispatches. Acknowledgement ordering uses synchronization barriers, not timing guesses. Keep fixture timeouts and worker joins on every exit path.

M3 passes only when structured capture/serialization/replay retains raw answers and supports new local calibration without live calls or new receipts. Cache hits retain data with evidence removed, evidence requests bypass cache, and streams continue to bypass it. Existing text/native/generative and evidence-disabled behavior remains tested.

M4 passes when checks, docs, ADR validation, source distributions, tags, and Hackage artifacts are verified. Record the downstream consumer gate as pending until its released-cohort fixture actually passes; never mark downstream acceptance from local inference.

## Idempotence and Recovery


Tests use isolated registries, dummy credentials, ephemeral loopback ports, bounded actions, and bracketed cleanup. They can run repeatedly without external state. Preserve user changes and use the current branch. Keep request preparation changes additive until complete and streaming parity tests pass. If a failure reveals a missing upstream lifecycle guarantee, record the exact released-source evidence and unmet criterion; do not replace the provider supervisor or add retries locally.

Publishing versions is irreversible: inspect registry and tags before rerunning a failed release step, resume only unfinished uploads, and never overwrite published contents or move tags. There is no data migration. Replay uses existing response encoding; old recordings without usable structured content remain rejected for streaming.

## Interfaces and Dependencies


`streamProgram` continues to return only the typed output and to accept the existing status/text callback. Applications retain raw structured answers using the public LLM event/response boundary or trace capture; the new separate observer retains full actual-attempt evidence. `runProgram`, `Params`, and local decision evidence codecs retain their semantics. Proposed `preparePredict` shares effective-signature preparation between runners; if exported to avoid a module cycle, include it in public API and version review.

`AttemptReceipt` wraps Baikai evidence with Shikumi call/ordinal correlation; billing observations remain unchanged. Add the new module to `shikumi/shikumi.cabal`. Update explicit `LLMConfig` construction sites when adding the optional callback and keep `defaultLLMConfig` evidence observation disabled. Neither replay nor cache invokes it.

Relevant dependency artifacts are `mori://shinzui/baikai/packages/baikai`, `mori://shinzui/baikai/packages/baikai-typesafe`, and `mori://shinzui/baikai/packages/baikai-effectful`. Existing bounds are core >=0.10.0.0 <0.11, TypeSafe >=0.1.0.1 <0.2, and effectful binding >=0.4.0.5 <0.5. Retain them unless implementation evidence requires a different released cohort; verify all changed cohort members against Hackage and upstream tags. No new production transport library is planned. The internal testing package already owns WAI/Warp loopback dependencies and remains unpublished.
