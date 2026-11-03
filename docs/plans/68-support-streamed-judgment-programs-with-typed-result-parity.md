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
  reviews:
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-11-03T04:11:05Z
      verdict: "changes-requested"
      note: "API review against Shikumi and released Baikai source: retry evidence provenance false, generative streams refused by proposed check, signatures unpinned, replay needs pure helpers; fixes applied in the same-session revision"
  revisions:
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-11-03T04:11:05Z
      mode: "update"
      note: "Pin public API signatures, add per-attempt evidence provenance, separate terminal integrity from answer validity, set 0.6.0.0"
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-11-03T04:34:22Z
      mode: "implement"
      note: "Implement streamed judgment parity, acknowledged attempt evidence, and structured replay"
---


# Support streamed judgment programs with typed result parity

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current. Follow `agents/skills/exec-plan/FRICTION.md` for implementation friction and distill durable decisions into ADRs before completion.

## Purpose / Big Picture


Allow an application to run the same typed judgment program with `streamProgram` or `runProgram` and obtain equal rich results under identical immutable parameters. A judgment is a closed question: `Noul` carries a boolean and its probability, `Choice` carries a selected label and its distribution, and `Score` carries a numerical expectation, derived level, and distribution. TypeSafe returns a complete structured answer atomically, rather than producing incremental text.

Implement [IR-5](../improvement-requests/support-streamed-judgment-programs-with-typed-result-parity.md). Demonstrate the behavior with the released TypeSafe provider against a loopback HTTP server, without paid calls. Preserve the original structured answer separately from locally calibrated results, acknowledge actual-attempt evidence before successful return, and deliver documentation, tests, and a tagged Hackage release. Creation of this plan does not itself implement or publish that release.

Also implement [IR-3](../improvement-requests/expose-acknowledged-evidence-for-resilient-llm-attempts.md), except for evidence on a cancelled attempt. After this plan, an application can install an effectful observer on the resilient or bare interpreter, request evidence, and handle each attempt's exact Baikai record before Shikumi retries, raises, or returns, for blocking and streaming calls alike. Only Baikai can build the record for a cancelled attempt, so that part is requested separately in `mori://shinzui/baikai/okf/improvement-requests/concepts/IR-13`. IR-3 stays open for that one item until the Baikai release is consumed.

## Progress


- [x] M1 (2026-11-03; real TypeSafe parity, wire and preflight tests pass): Complete and streamed judgments share request preparation and settings-aware decoding; a real TypeSafe loopback proves default and explicit-settings parity.
- [x] M2 (2026-11-03; 31 AttemptEvidence tests pass for both operations, including barriers and concurrency): An effectful attempt observer and truthful per-attempt evidence work for blocking and streaming calls; hermetic tests cover IR-3's required cases other than cancelled-attempt evidence.
- [x] M3 (2026-11-03; 21 SystemOne tests plus malformed-terminal and mixed generative regression tests pass): Structured terminal validation, acknowledged receipts, retries, cancellation, and observer/callback failures satisfy the lifecycle acceptance matrix for streamed judgments through the released TypeSafe provider.
- [x] M4 (2026-11-03; 37 trace and 36 cache tests pass, including cross-mode replay and evidence bypass): Structured stream capture/replay and existing cache policy preserve answers without fresh provider evidence; generative regressions pass.
- [x] M5 (2026-11-03): Documentation, ADRs, release gates, four tagged Hackage packages and matching GitHub releases are complete. Published source archives match the verified release bytes, public Haddock pages are verified, and all remote tags point to `7b96ecf06364b37de44b15c4f58b2528b5a3e0f5`. Downstream acceptance is explicitly pending.

All milestones are complete. The released cohort is `shikumi 0.5.1.0`,
`shikumi-cache 0.2.1.1`, `shikumi-tools 0.4.2.1`, and `shikumi-trace 0.3.2.0`.
IR-5 is completed. IR-3 remains open only for cancelled-attempt evidence, which
requires the upstream Baikai addition. Shikigami and Kioku consumer gates remain
pending their own released-cohort fixtures; no downstream source changes or
messages were made.


## Surprises & Discoveries


2026-11-03: Unchanged options would make retried evidence false. `transportAttempt` in `shikumi/src/Shikumi/LLM.hs` sends the same `Options` on every attempt, and Baikai's `prepareEvidenceAt` copies `attempt` and `supersedes` straight from that request. A second attempt would report `attempt = 1` and no `supersedes`, next to a receipt whose ordinal is 2. M2 therefore rewrites the evidence request for each retry.

2026-11-03: Neither `streamPredict` nor `runLLMReplay` has `IOE` in its effect row, so Baikai's `reassembleResponse` (a `Fold IO`) and `liftCompleteToStream` (a `Stream IO`) cannot be used in either place. Converting between events and a `Response` needs pure helpers, which also gives downstream interposers one shared definition.

2026-11-03: `Shikumi.Stream.reassemble` starts from `emptyResponse`, so it discards model, api, provider, response ID, latency, and evidence. Its result is enough to decode but not to record or to compare with a complete call.

2026-11-03: `shikumi-cache/src/Shikumi/Cache/ResponseJSON.hs` deliberately omits evidence from every encoded `Response`, so a recorded response has no historical evidence to preserve. Only span attributes such as `observedModel` keep that history.

2026-11-03: `ModelCallEvidence` has `ToJSON` but no `FromJSON`, so unlike `LLMObservation` an `AttemptReceipt` cannot round-trip JSON without an orphan decoder.

2026-11-03: `ModelCallEvidence` is not safe to persist whole. `mori://shinzui/kioku/plans/16-add-distillation-replay-metadata` records that HTTP errors can include up to 300 characters of the provider's response body in `BaikaiError.message`. `AttemptReceipt` therefore has no JSON instance at all, and the Haddock says so.

2026-11-03: An effectful observer that calls `throwError` could cause a second paid call in two places: `catchError` in `retrying`, and `retryWith` in `shikumi/src/Shikumi/Program.hs`, which a `Retry` node reaches with `const True`. Restructuring `retrying` would fix only the first, so M2 converts the typed failure to an exception at the observer boundary instead.

2026-11-03: Cancelled-attempt evidence cannot be built in Shikumi. `baikai-effectful`'s `streamCollect` is `Stream.toList (streamRequestWith ...)`, which has no abort record. Only `finalizeTrace` in Baikai builds a `CallAborted` record, and `baikai-effectful` does not reach it. In `mori://shinzui/baikai` (artifact-level source URI pending), project-relative `baikai-openai/test/ResponsesEvidenceSpec.hs` shows that the traced path already delivers exactly one such record when cancelled, so the gap is one of exposure.

2026-11-03: Baikai's strict failures are already terminal. `missingEvidenceError` has category `OtherError` and `refusalError` has `InvalidRequest`, and neither is retryable. Only a thrown `BaikaiError` can be retried without a record, so M2 needs just that one fail-closed change.

## Decision Log


2026-11-03: Share prediction preparation rather than copying the complete path into streaming. Rendering, validation, and local calibration must have one definition to prevent future drift.

2026-11-03: Numeric thresholds, weights, and cuts remain local and outside request identity, following ADR-15. “Same settings” means identical local derivation and identical selected decision schemas, not sending calibration numbers to TypeSafe.

2026-11-03: Preserve stream cache bypass. Add replay of recorded atomic structured judgments, without introducing general incremental stream persistence. Keep full attempt receipts separate from the deliberately restricted billing observer.

2026-11-03: Select the checked decision path from the output type, not the model. `streamPredict` only ever holds the placeholder model; the real one is known only inside `routeLLM`. Any output whose schema declares a judgment takes the checked path on every provider.

2026-11-03: Split terminal integrity from answer validity. `responseFromEvents` checks the event sequence and accepts text or data, because generative decision models answer with evidence JSON in text. Missing or malformed answers are rejected by `parseResponseWithSettings`, the parser the complete path uses, so both modes fail identically. This replaces a blanket "reject missing structured data" rule that would have refused every generative decision stream.

2026-11-03: Decision outputs emit no `StreamFieldChunk` on any provider. On generative models the text is probability JSON rather than a field's prose, and `LLM.stream` collects all events before any chunk is delivered, so suppressing chunks costs no liveness. Callers see `LmStart` and `LmEnd` only.

2026-11-03: Keep `StreamEvent` and the `streamProgram` signature unchanged. A new constructor would break exhaustive matches in existing callers. Raw answers are read at the LLM boundary with `responseFromEvents`.

2026-11-03 (scope superseded below): Per-attempt `attempt` and `supersedes` are in scope because IR-5 requires retry provenance to be preserved. [IR-3](../improvement-requests/expose-acknowledged-evidence-for-resilient-llm-attempts.md) stays open: its effectful, call-scoped observer and its consumer-abort evidence are not delivered here.

2026-11-03: Settle each attempt in the order budget charge, billing observer, evidence observer, then error propagation or return. The billing collector only updates memory, while an evidence observer may perform durable IO and is the likelier to fail, so this order loses the least accounting.

2026-11-03: A strict pre-dispatch refusal delivers a receipt, because Baikai builds a real record for it and IR-3 asks for that record. A receipt therefore does not prove that HTTP occurred; callers read that from the evidence record.

2026-11-03 (superseded below): Add `evidenceObserver` to `LLMConfig` and release `shikumi` as 0.6.0.0. A new field changes the exported constructor's arity, which is a PVP major change. The 0.4.0.0 release set this precedent when it added `observer`. Every in-repository site uses `defaultLLMConfig` with record update, so no source edits are needed beyond that function, but dependents' `^>=0.5.0.0` bounds must move.

2026-11-03: Expand this plan to implement IR-3, except evidence on a cancelled attempt. That item needs a Baikai release, so it moves to `mori://shinzui/baikai/okf/improvement-requests/concepts/IR-13` and a later Shikumi follow-up. Nothing in this plan waits on it.

2026-11-03: The evidence observer is effectful, `AttemptReceipt -> Eff es ()`, as IR-3 asks, and it is passed as a runner argument because `LLMConfig` has no `es` parameter. This subsumes `IO`, since plain callers pass `liftIO . persist`. The observer's effects must be installed outside the interpreter, which also means it cannot call `LLM` and recurse. The billing observer stays in `LLMConfig`, an accepted inconsistency.

2026-11-03: A typed observer failure becomes the exception `EvidenceObserverFailed`, rather than a `Left` from `runErrorNoCallStack`. Neither `catchError` handles it, so neither the retry loop nor a `Retry` node can redispatch, and it behaves like an observer exception does today. `retrying` is unchanged.

2026-11-03: Add `withEvidenceRuns`, which mints one run ID per `LLM` operation. `defaultEvidence` gives every call in its scope one run ID, so a multi-`Predict` program would produce several "attempt 1" records under the same run, which Kioku's plan calls ambiguous. It sits above the retry loop, so retries keep their run ID.

2026-11-03: Under `EvidenceRequired`, a thrown `BaikaiError` is terminal instead of retried, because that attempt can never be accounted for. The call fails with a non-transient `ValidationFailure` naming only the stable `errorClass`, so no provider text is carried.

2026-11-03 (implementation): Actual exported types and signatures confirm an
additive core release at 0.5.1.0 and structured replay growth at trace 0.3.2.0.
Cache 0.2.1.1 and tools 0.4.2.1 carry test-only integration changes and require
core 0.5.1.0 in their release cohort. Existing dependent bounds admit these
versions without a repository-wide release. CAP-42–44 record the material growth
without moving older capabilities' since versions.

2026-11-03: The public API change is now additive, so the expected release is `shikumi` 0.5.1.0, to be confirmed by the release step's review of the actual diff. A PVP major bump is approved if that review finds one is needed.

## Outcomes & Retrospective


2026-11-03: M1–M4 are implemented and verified. Real TypeSafe HTTP fixtures prove
calibrated typed/raw parity, exact atomic event order, acknowledged retry evidence,
preflight refusals, cancellation cleanup and observer/callback failure. Pure
structured replay supports both capture modes and both replay modes; cache policy
continues to bypass streams and evidence requests. ADR-13–15 were revised and
ADR-16 records the acknowledged evidence boundary.

Final-candidate `cabal build all` and `cabal test all` pass. The 13 test suites
include 819 tests; Redis reports its existing zero-test skip, and paid/live tests
remain disabled. Relevant suite counts are core 300 (31 AttemptEvidence), tools
159 (21 SystemOne), harness 37, trace 37 and cache 36. `scripts/check-haddock.sh`
passes for all packages after removing a stale quoted parse reference in Stream.
`nix fmt`, `nix flake check`, the 44-record capability catalog, 16-record ADR bundle,
and four release-package `cabal check` runs pass. Hackage confirms Baikai core
0.10.0.0 and TypeSafe 0.1.0.1; upstream annotated tags peel to
`03140cf60381ac154ebfa86d3bb2208d7df8626c`. No dependency override was introduced.

FRIC-1 in `docs/friction-log/` is accepted: strict improvement-request validation
still reports missing historical review metadata on three unchanged requests;
current IR-5 technical verification is recorded without inventing old reviews.
This is separate from the passing release capability and ADR gates. FRIC-2 is
accepted: enter the dev shell at the repository root and change directories
inside the command when checking packages. Newly generated unused package-local
database clusters were moved to a temporary recovery directory.

The user approved the prepared versions on 2026-11-03. Release commit
`7b96ecf06364b37de44b15c4f58b2528b5a3e0f5` was pushed to origin/master. All four
annotated package tags were pushed and verified through `git ls-remote`; every
tag peels to that release commit. Source packages and Haddock archives were
published in dependency order, checking each registry entry and source archive
before proceeding to dependents. Matching GitHub releases are public and their
notes were verified against the approved package changelogs.

Published packages are [shikumi 0.5.1.0](https://hackage.haskell.org/package/shikumi-0.5.1.0),
[shikumi-cache 0.2.1.1](https://hackage.haskell.org/package/shikumi-cache-0.2.1.1),
[shikumi-tools 0.4.2.1](https://hackage.haskell.org/package/shikumi-tools-0.4.2.1), and
[shikumi-trace 0.3.2.0](https://hackage.haskell.org/package/shikumi-trace-0.3.2.0).
Each source archive downloaded from Hackage is byte-identical to the inspected
local distribution. Their SHA-256 values are:

```text
shikumi-0.5.1.0        a42d0f036318e52556439feff4ff1be22219ac770b6782fd310da54cfb7b7c3c
shikumi-cache-0.2.1.1  1f27370801f064aa959e7aa6f70d7799d8f558407cc37d5dcc1238fbe25d0f14
shikumi-tools-0.4.2.1  330a6e49ebfe92de8986b1c3351b14eb30944af794810ac60bb026b52e3a61e9
shikumi-trace-0.3.2.0  01282ab6427a012d5be3684ddbce96e6a556cc979363eb83e1435014f8b55094
```

Public module documentation matches the uploaded HTML after accounting for
Hackage's injected synopsis CSS. Core's Evidence API, cache, ReAct and trace
Replay pages all resolve. The offline `cabal run jitsurei-responses` example also
passes: three acknowledged receipts, three completed transport attempts, one
tool execution, a validated Paris answer and a preserved opaque continuation. GitHub releases use the corresponding package tags at
`https://github.com/shinzui/shikumi/releases/tag/<package>-<version>`. IR-5 is
completed; IR-3's sole remaining item is cancelled-attempt evidence. Shikigami
and Kioku acceptance are separately pending. No downstream acceptance is inferred
from publication or local tests.


## Context and Orientation


The following orientation describes the baseline at plan creation; the completed
implementation and release evidence are recorded above.

`shikumi/src/Shikumi/Program.hs` owns `Params`, `runPredict`, `effectiveSignature`, and `parseResponseWithSettings`. `runPredict` validates each decision setting against the output schema, overlays parameters, chooses ordinary versus probability-evidence rendering, stamps structured input state, and derives the result after the response. `shikumi/src/Shikumi/Decision/Setting.hs` defines `NoulSetting`, `ChoiceSetting`, and `ScoreSetting`; these values never enter the provider request or cache key.

`shikumi/src/Shikumi/Stream.hs` currently rejects decision outputs, renders only ordinary schemas, and decodes with default settings. Its `streamComplete` calls `LLM.stream`, which returns a collected event list, then emits text chunks. This is not a live transport iterator. Its response reconstruction currently accepts an error terminal as a source of partial content and falls back to text when a terminal is absent. Structured judgments must require a successful complete terminal. `shikumi/src/Shikumi/Routing.hs` also refuses decision streams before its otherwise shared `translateForWire`. That translation selects the real model, removes private stamps, selects the judgment schema, and sends one structured `UserData` state with no system prompt or tools.

`shikumi/src/Shikumi/LLM.hs` owns bare and resilient interpreters. `transportAttempt` charges budgets and emits an observation for each transport completion before raising provider errors. `retrying` owns transport retries. `shikumi/src/Shikumi/LLM/Observation.hs` exposes a billing summary, deliberately excluding raw output and full evidence; it cannot by itself acknowledge an application's full provider receipt. `shikumi/src/Shikumi/LLM/Defaults.hs` withholds generation defaults for judgment-only models while preserving explicit settings for provider validation.

`shikumi-testing/src/Shikumi/Testing/SystemOne.hs` supplies a real TypeSafe loopback and isolated registry. `shikumi-testing/src/Shikumi/Testing/DecisionFixtures.hs` supplies `Ticket`, `Assessment`, and its three judgments. `shikumi-tools/test/SystemOneIntegrationSpec.hs` already tests complete-call wire behavior. Extend these fixtures; core cannot depend on the core-dependent testing package. `shikumi-cache/src/Shikumi/Cache.hs` bypasses streams and bypasses cache reads/writes when evidence is requested. `shikumi-trace/src/Shikumi/Trace.hs` currently captures only stream usage, while `shikumi-trace/src/Shikumi/Trace/Replay.hs` rejects every Stream operation. `shikumi-trace/test/DecisionReplaySpec.hs` currently covers only complete replay. `shikumi-testing/test/DecisionEvidenceSpec.hs` currently asserts that decision streaming is refused before dispatch; that test must be inverted, not deleted.

[IR-3](../improvement-requests/expose-acknowledged-evidence-for-resilient-llm-attempts.md) is an open request from a different consumer, `mori://shinzui/kioku/plans/16-add-distillation-replay-metadata`, for acknowledged evidence on every resilient attempt. That consumer calls blocking operations only, generates one Baikai run ID per provider invocation across its retries, persists each attempt before accepting output, and fails closed if persistence fails. A run ID is the caller's opaque label for one logical invocation; `ModelCallEvidence` also carries a fresh `callId` per attempt. This plan implements all of IR-3 except evidence on a cancelled attempt, which `mori://shinzui/baikai/okf/improvement-requests/concepts/IR-13` requests from Baikai. Do not mark IR-3 complete.

`shikumi/test/StubProvider.hs` supplies the stub registries behind `shikumi/test/ResilienceSpec.hs`. `fixtureEvidence` in `shikumi-trace-otel/test/BillingSpec.hs` shows how to build a record with Baikai's public `baseEvidence`.

Relevant architecture decisions were read:

[ADR-9](../adr/0009-centralize-offline-harness-and-diverse-fixtures.md) places reusable offline fixtures in shikumi-testing and real provider tests in consumers. [ADR-11](../adr/0011-preserve-provider-errors-and-centralize-retry-policy.md) requires structured provider errors, one retry policy, and unchanged host exceptions/cancellation. [ADR-12](../adr/0012-apply-request-defaults-before-cache-and-observation.md) fixes routing → defaults → cache/trace → transport order and evidence bypass. [ADR-13](../adr/0013-separate-transport-billing-from-logical-usage.md) separates logical results from actual attempts and prohibits fabricated cancellation terminals. [ADR-14](../adr/0014-separate-schema-enforcement-from-tool-calling-capability.md) routes judgment-only models by capability. [ADR-15](../adr/0015-derive-decision-answers-from-probability-evidence.md) retains probability evidence and derives answers locally. ADR-14 and ADR-15 explicitly refuse streaming today; revise those exclusions during implementation.

Dependency discovery used Mori. The provider contract is `mori://shinzui/baikai/docs/typesafe-judgments`, which the current registry does not yet resolve; in `mori://shinzui/baikai` (artifact-level source URI pending) it is project-relative `docs/capabilities/typesafe-judgments.md`. Its local guide still mentions an older cohort, so it is not the version authority. Hackage and upstream tags checked on 2026-11-03 agree on core 0.10.0.0 and TypeSafe 0.1.0.1, both tag targets `03140cf60381ac154ebfa86d3bb2208d7df8626c`. Current Cabal bounds already select that cohort. In `mori://shinzui/baikai` (artifact-level source URI pending), project-relative `baikai-typesafe/src/Baikai/Provider/TypeSafe/Api.hs` defines `typesafeStream = liftCompleteToStream completeTypeSafe`. The provider performs one nonstreaming HTTP call and emits `EventStart`, `DataStart`, `DataEnd`, `EventDone`, or failure. `DataContent` retains raw value, distributions, optional confidence, and method. Do not recreate its HTTP client or supervisor.

The downstream consumer is `mori://shinzui/shikigami/plans/80-configure-model-providers-and-agent-launches-through-baikai`, with blocking evidence at `mori://shinzui/shikigami/okf/friction-log/concepts/FRIC-49`. This is a standalone follow-up to the existing decision implementation, not a newly enrolled child of MasterPlan 12.

## Plan of Work


### M1 — Shared preparation and first transport proof


Extract the setting validation and rendering portion of `runPredict` into a shared `preparePredict` in `shikumi/src/Shikumi/Program.hs`, with the signature given in Interfaces and Dependencies. Both runners use this helper and `parseResponseWithSettings (decisionSettings ps)`. Run it before `LmStart`, so an invalid request emits no status and no HTTP. Preserve ordinary rendering byte-for-byte where possible. Remove both refusals: the check at the top of `streamPredict`, and the `Stream` branch check in `routeLLM`. The router's `translateForWire` and continuation validation stay, and they are what still refuse free-form output on judgment-only models. Invert the refusal test in `shikumi-testing/test/DecisionEvidenceSpec.hs`.

Extend `shikumi-tools/test/SystemOneIntegrationSpec.hs` first with complete/stream runs of the existing Assessment fixture through `routeLLM`, defaults, and the released provider. Capture terminal data at the LLM boundary and outgoing requests below routing. Expect one HTTP call per invocation, equal rich results, equal raw `AssistantData`, and identical provider request bodies. Then add explicit `NoulSetting 0.9`, choice weights billing=5 and technical=1, and `ScoreSetting [0.5,1.6]`. Against probabilities urgent=.83, billing=.2/technical=.8, severity=.1/.3/.6, expect false, Billing, and level 1 respectively; default results are true, Technical, and level 2. Expected score remains 1.5. Raw provider choice remains technical. Assert confidence and method are preserved on the raw carrier and every rich type's supported evidence fields survive.

This first real producer/consumer test must pass before expanding lifecycle variants. Pure `StreamSpec`, `RoutingSpec`, and `DecisionDeriveSpec` tests cover preparation equivalence, invalid settings, native JSON, fallback markers, and generative probability evidence, including mixed decision/free-text outputs on generative models.

### M2 — Attempt evidence seam


This milestone delivers the observer for both blocking and streaming calls and proves it with hermetic stub providers, before any TypeSafe lifecycle work. At the end, `nix develop -c cabal test shikumi:test:shikumi-test --test-options='-p AttemptEvidence'` passes every case below.

Add `shikumi/src/Shikumi/LLM/Evidence.hs`, with the types given in Interfaces and Dependencies. `Shikumi.LLM` imports this module, so it must not import `Shikumi.LLM`. A receipt is an envelope around the original Baikai `ModelCallEvidence`, not a replacement evidence format. Add the runners `runLLMWithEvidence` and `runLLMResilientWithEvidence`, and implement the existing runners by passing an observer that does nothing. Keep existing runner signatures, `LLMConfig`, and billing observations. Deliver a receipt only when a provider-built record exists, and never invent one. A caller requests evidence through existing options, `defaultEvidence`, or `withEvidenceRuns`, and installing an observer alone does not enable it. Under `EvidenceBestEffort` a success may therefore produce no receipt. A caller that needs a guarantee requests `EvidenceRequired`, which Baikai enforces by turning a successful terminal without a record into a non-retryable error terminal. Say this in the Haddock.

Settle each attempt in `transportAttempt` in this order: budget charge, billing observer, evidence observer, then provider-error propagation or return, all outside `try @BaikaiError`. The handler runs on `Baikai : es`, so call the observer with `raise` through this wrapper, which needs no unlifting:

```haskell
acknowledge :: (IOE :> es, Error ShikumiError :> es) => EvidenceObserver es -> AttemptReceipt -> Eff es ()
acknowledge observe receipt =
  observe receipt `catchError` \_ e -> liftIO (throwIO (EvidenceObserverFailed e))
```

Returning normally acknowledges receipt. A typed failure becomes `EvidenceObserverFailed`, and any other exception propagates unchanged, so no observer failure can enter `retrying` or a `Retry` node. The observer is shared by all calls under one interpreter. Under `runProgramConc` it runs on worker threads, so it must be safe for concurrent use, and writes to local `State` do not reach the parent. Document both.

Make retried evidence truthful. When the options carry an evidence request, the first attempt sends it unchanged. Each retry sends `attempt = base + ordinal - 1`, where `base` is the caller's value, and `supersedes` set to the Baikai `callId` of the latest attempt that produced a record, falling back to the caller's value. Hold that call ID in an `IORef` created per logical call beside `freshCallId`, and only when evidence is requested, so concurrent calls share no state and evidence-disabled calls allocate nothing. `retrying` itself is unchanged. Evidence is excluded from `cacheKey`, so this does not alter request identity, and evidence-disabled callers send identical options.

In the `Left be` branch of `transportAttempt`, after billing, fail with a non-transient `ValidationFailure` when the request has `EvidenceRequired`, naming only `O.errorClass`. Other callers keep today's retry behavior.

Add `withEvidenceRuns` to `shikumi/src/Shikumi/LLM/Defaults.hs`. For each `LLM` operation whose options have no evidence request, it runs the caller's action to mint a run ID and fills a request with the given strictness. A per-call value wins. Compose it where `withRequestDefaults` goes, which is above the interpreter's retry loop, so one operation's retries keep one run ID.

Add `shikumi/test/AttemptEvidenceSpec.hs` and register it in `shikumi/shikumi.cabal` and the test `Main`. Extend `shikumi/test/StubProvider.hs` with a stub that builds its record from the request's evidence options with `baseEvidence`. Run each case below through both `Complete` and `Stream` where the case applies. A transient first failure followed by success produces attempts 1 and 2 under one run ID, with attempt 2 superseding attempt 1's `callId`, and the receipts share one `logicalCallId` with ordinals 1 and 2. A blocked first acknowledgement holds back the second dispatch, and a blocked acknowledgement holds back a successful return. A terminal failure is observed before its `ShikumiError` is raised. A strict refusal delivers one receipt without invoking the provider. A streaming success and a terminal failure each deliver their exact record once.

An observer that throws an exception, and one that calls `throwError` with a transient `ProviderFailure`, each return no output and leave the provider count at one, including under a `Retry` node. Budget refusal delivers no receipt and no dispatch. So does cancelling a call that is waiting for a rate-limit permit, since that limiter blocks rather than fails. Concurrent calls under `runProgramConc` keep independent attempt and supersession state. Under `withEvidenceRuns`, a two-`Predict` `Compose` produces two run IDs, and a retried call keeps one. A thrown `BaikaiError` under `EvidenceRequired` fails without a retry. With no evidence request, an interpreter with an observer sends identical options and delivers no receipt, and existing `runLLMResilient` results and billing observations are unchanged.

### M3 — Atomic success and streamed judgment lifecycle


Add the pure `responseFromEvents` to `shikumi/src/Shikumi/Stream.hs`. It requires exactly one terminal, as the last event, and that terminal must be `EventDone` with an assistant message. Every `DataEnd` payload must equal the corresponding `AssistantData` block of the terminal message, in order. An error terminal maps to the same `ShikumiError` as `streamTerminalError` in `shikumi/src/Shikumi/LLM.hs`, which this plan exports for that purpose. A missing, duplicate, misplaced, or inconsistent terminal is a non-transient `SchemaMismatch`, because `ProviderFailure` is classified as transient and would make a malformed stream retryable. The returned `Response` takes model, api, and provider from the argument; message, response ID, and evidence from the terminal; and latency from the start and terminal timestamps when both exist, otherwise zero. It never synthesizes probabilities or converts data to text.

In `streamPredict`, an output whose schema declares any judgment takes the checked path: `LmStart`, `stream`, `responseFromEvents`, `parseResponseWithSettings`, then `LmEnd` after a successful decode. It emits no field chunks. Every other output keeps today's path through `streamComplete`, including its signature, chunks, and `LmEnd` timing. No failed path returns a typed value.

Prove the M2 seam through the released provider by extending the shared fixture with scripted status/reply sequences and cancellation barriers while keeping its existing convenience function; `withResponsesFixture` in `shikumi-testing/src/Shikumi/Testing/Responses.hs` shows the scripted-reply and worker-cleanup pattern to follow. Test transient failure then success with two HTTP attempts and two receipts, and assert that the receipts share one `logicalCallId`, have ordinals 1 and 2, and that the second record has `attempt = 2` and `supersedes` equal to the first record's `callId`. Test a blocking acknowledgement callback that prevents typed return until released, and a first-attempt acknowledgement that must complete before the second HTTP request arrives. Test that an interpreter with an observer but no evidence request sends the same bytes and delivers no receipt, and that a strict request above the provider's declared strength makes zero HTTP requests and delivers one receipt. Test callback exceptions before dispatch and after completion, evidence observer exceptions on success and failure, malformed/missing distributions, and error/missing/duplicate terminals injected by a third-party LLM interpreter. Cancellation tests must wait for request arrival, cancel the operation, join workers, and prove bounded termination and no returned result. Preserve the provider's existing cancellation contract; do not demand or fabricate an aborted receipt, because a cancelled attempt has no record on this path until `mori://shinzui/baikai/okf/improvement-requests/concepts/IR-13` is released and consumed. Test both the new full evidence observer and the existing billing observer failure paths.

### M4 — Capture, replay, and cache preservation


In `shikumi-trace/src/Shikumi/Trace.hs`, when `responseFromEvents` succeeds and the terminal holds an `AssistantData` block, record the response through the existing `llmAttrs`, without creating a second logical call or transport receipt. Generative text streams keep today's usage-only capture, and a `Left` leaves the span unrecorded rather than failing the call, because tracing must not change the outcome. In `shikumi-trace/src/Shikumi/Trace/Replay.hs`, have a `Stream` lookup decode the recorded response and return `atomicEventsFromResponse`. The signature of `runLLMReplay` keeps its row without `IOE`. A recording without structured data, like a missing or malformed one, raises `ReplayDivergence` and never falls through to a provider.

`cacheKey` does not distinguish the two operations, so one recording answers both. Extend `shikumi-trace/test/DecisionReplaySpec.hs` to record a stream, replay it offline, and rederive under changed settings. Also replay a complete recording as a stream and a stream recording as a complete call. Assert raw value/distributions/confidence/method survive serialization, no provider is invoked, and no new receipt or billing attempt appears. Replayed terminals carry no evidence because the response codec omits it; span attributes such as `observedModel` remain the only recorded history and are never evidence for the replay invocation.

Extend `shikumi-cache/test/Main.hs` with complete decision cache-hit and changed-settings coverage, zero fresh evidence, and evidence-request bypass. A live stream through the cache still dispatches: this plan does not add stream memoization. Verify the response codec preserves structured fields. Run existing generative streaming, validation, evidence-disabled, and native JSON regressions across core and consumers.

### M5 — Documentation and release


Update Haddock in Program, Stream, Routing, LLM, Defaults, and Evidence; document the new receipt API, callback ordering, collected-event behavior, atomic TypeSafe semantics, and raw-versus-derived distinction. The `AttemptReceipt` Haddock must warn that `ModelCallEvidence` error messages can contain provider response text, so an application should choose what to persist. Update `docs/capabilities/typed-streaming.md`, `docs/capabilities/probability-backed-decisions.md`, `docs/capabilities/persistent-decision-settings.md`, `docs/capabilities/deterministic-replay.md`, `docs/capabilities/transport-billing-observation.md`, `docs/capabilities/scoped-request-defaults.md`, their bundle log/index as required, `docs/user/effects-and-runtime.md`, `docs/user/caching-tracing-replay.md`, and affected package changelogs. The "Limits" sections of `typed-streaming.md` and `deterministic-replay.md` currently say replay covers only blocking calls, and those claims become false. Add the IR-3 integration example by moving `shikumi-jitsurei/app/Responses.hs` onto `runLLMResilientWithEvidence`. Revise ADR-14 and ADR-15's refusals and ADR-13's boundary description without weakening billing privacy, and add an ADR for the attempt evidence seam covering acknowledgement order, retry provenance, and observer failure. Follow the profile workflow in `agents/skills/exec-plan/ADR.md` for changed ADRs.

Update the improvement-request bundle. Mark IR-5 complete. Keep IR-3 open, and change its Status section and the bundle log to state that only cancelled-attempt evidence remains, citing `mori://shinzui/baikai/okf/improvement-requests/concepts/IR-13`.

Use `agents/skills/release/SKILL.md` when implementing the release milestone: compute Haskell PVP versions from actual public changes, align internal dependency bounds and the verified released Baikai cohort, run its gates, publish affected public packages in dependency order, and verify tags and Hackage contents. Expect `shikumi` 0.5.1.0, since the API change is additive and `LLMConfig` is unchanged; a major version is approved if the release review finds a breaking change, and internal dependents' `^>=0.5.0.0` bounds must then be updated to admit it. Record actual versions, tag commits, registry checks, and test evidence here. Track the downstream consumer gates, Shikigami's and Kioku's, separately; a successful local fixture or upload does not prove that either consumer passed. No downstream source edits or messages are required by this plan.

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

The initial new SystemOne stream test should reproduce the current decision-stream refusal. After M1 it must pass using actual HTTP capture; M3 adds lifecycle cases to that group. M2's hermetic cases run in the `AttemptEvidence` group of `shikumi:test:shikumi-test`. Register any new test modules in the relevant Cabal file and test Main. Successful Tasty runs exit zero with all selected tests passed; record actual counts rather than predicting them.

```bash
nix fmt
nix develop -c cabal build all
nix develop -c cabal test all
nix develop -c scripts/check-haddock.sh
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
git diff --check
```

Use the release skill's additional package checks at M5. Do not select paid/live suites. Update plan provenance using the bundled script on the first substantive edit in each implementation session. Conventional commits must carry both trailers:

```text
ExecPlan: docs/plans/68-support-streamed-judgment-programs-with-typed-result-parity.md
Intention: intention_01m6frznqber0vzsp9f35ywj68
```

## Validation and Acceptance


M1 passes only when default and nondefault Assessment executions produce equal complete/stream rich results and equal raw structured payloads through the public router and released provider. Inspect exact wire model, typed state, criteria, and questions. Inspect options before provider dispatch to prove private rendering metadata is removed and generation defaults are absent. Numeric calibration stays local. Invalid threshold, wrong setting kind, unknown field/weight, invalid cuts, unsupported generation controls, and free-form judgment-only output each cause zero HTTP requests in both modes.

M2 passes only when every case in its test group passes for each operation it applies to. A caller can install an effectful observer on both runners and read each attempt's exact record, in order, before Shikumi retries, raises, or returns. A two-attempt run shows attempts 1 and 2 under one run ID with a correct `supersedes` link. A failing observer, whether by exception or by `throwError`, leaves the provider count at one, including under a `Retry` node. Evidence-disabled callers see identical requests and results. A cancelled attempt delivers no receipt, and this limit is documented.

M3 passes only when one successful stream yields the provider's atomic event order, one HTTP invocation, and one acknowledged terminal receipt before typed return. Observe transport events by interposing the public LLM boundary, not by pretending the program callback receives Baikai events. Retry injection produces separate receipts with increasing ordinals, and each provider record states its own `attempt` and the `supersedes` link to the previous record. A generative decision stream, including mixed decision and free-text outputs, decodes to the same result as its complete call and emits no field chunks. Every failure/cancellation scenario in M3 returns no successful partial judgment, and observer failure never redispatches. Acknowledgement ordering uses synchronization barriers, not timing guesses. Keep fixture timeouts and worker joins on every exit path.

M4 passes only when structured capture/serialization/replay retains raw answers and supports new local calibration without live calls or new receipts. Cache hits retain data with evidence removed, evidence requests bypass cache, and streams continue to bypass it. Existing text/native/generative and evidence-disabled behavior remains tested.

M5 passes when checks, docs, ADR validation, source distributions, tags, and Hackage artifacts are verified, IR-5 is complete, and IR-3 states its single remaining item. Record each downstream consumer gate as pending until its released-cohort fixture actually passes; never mark downstream acceptance from local inference.

## Idempotence and Recovery


Tests use isolated registries, dummy credentials, ephemeral loopback ports, bounded actions, and bracketed cleanup. They can run repeatedly without external state. Preserve user changes and use the current branch. Keep request preparation changes additive until complete and streaming parity tests pass. If a failure reveals a missing upstream lifecycle guarantee, record the exact released-source evidence and unmet criterion; do not replace the provider supervisor or add retries locally.

Publishing versions is irreversible: inspect registry and tags before rerunning a failed release step, resume only unfinished uploads, and never overwrite published contents or move tags. There is no data migration. Replay uses existing response encoding; old recordings without usable structured content remain rejected for streaming.

## Interfaces and Dependencies


These signatures are the public contract of this plan. `streamProgram`, `streamComplete`, `StreamEvent`, `runProgram`, `Params`, `runLLM`, `runLLMWith`, `runLLMWithObserver`, `runLLMResilient`, `LLMConfig`, `defaultLLMConfig`, `withRequestDefaults`, `runLLMReplay`, `LLMObservation`, and the local decision evidence codecs keep their current types and semantics, except that `streamProgram` now accepts decision outputs.

```haskell
-- shikumi/src/Shikumi/Program.hs: new export. Stream imports Program, and
-- Program owns Params, so this cannot live in a hidden module. It joins the
-- existing helpers exported for Stream, such as effectiveSignature and retryWith.
preparePredict ::
  forall i o es.
  (FromModel i, FromModel o, ToSchema o, Validatable o, ToPrompt i, ToPrompt o, Error ShikumiError :> es) =>
  Signature i o ->
  Params ->
  i ->
  Eff es (Signature i o, Context, Options)

-- shikumi/src/Shikumi/Stream.hs: new exports, both pure.
responseFromEvents :: Model -> [AssistantMessageEvent] -> Either ShikumiError Response
-- Nothing unless the response holds an AssistantData block and no error.
atomicEventsFromResponse :: Response -> Maybe [AssistantMessageEvent]

-- shikumi/src/Shikumi/LLM/Evidence.hs: new exposed module.
data AttemptReceipt = AttemptReceipt
  { -- | Same across retries; equals LLMObservation.callId. Process-local, so
    -- persist evidence's own callId, not this value, as a durable identity.
    logicalCallId :: !Text,
    -- | One-based within the logical call; equals LLMObservation.attempt.
    attemptOrdinal :: !Int,
    callKind :: !CallKind,
    -- | The exact provider-built record, with its own per-attempt callId.
    evidence :: !ModelCallEvidence
  }
  deriving stock (Eq, Show, Generic)

-- | Returning normally acknowledges the receipt. Must be safe for concurrent use.
type EvidenceObserver es = AttemptReceipt -> Eff es ()

-- | A typed observer failure. An exception, so that neither the retry loop nor
-- a Retry node can catch it and dispatch again.
newtype EvidenceObserverFailed = EvidenceObserverFailed ShikumiError
  deriving stock (Show)
  deriving anyclass (Exception)

-- shikumi/src/Shikumi/LLM.hs: additive runners and one new export.
runLLMWithEvidence ::
  (IOE :> es, Error ShikumiError :> es) =>
  ProviderRegistry -> O.LLMObserver -> EvidenceObserver es -> Eff (LLM : es) a -> Eff es a
runLLMResilientWithEvidence ::
  (IOE :> es, Concurrent :> es, Error ShikumiError :> es) =>
  EvidenceObserver es -> LLMConfig -> Eff (LLM : es) a -> Eff es a
streamTerminalError :: TerminalPayload -> ShikumiError

-- shikumi/src/Shikumi/LLM/Defaults.hs: new export. The action mints one run ID
-- per LLM operation that has no evidence request of its own.
withEvidenceRuns ::
  (LLM :> es) => EvidenceStrictness -> Eff es Text -> Eff es a -> Eff es a
```

The receipt fields are named `logicalCallId` and `attemptOrdinal` because the enclosed record has its own `callId` and `attempt` with different meanings: Baikai's `callId` changes on every attempt, and its `attempt` starts from the caller's value. `AttemptReceipt` has no JSON instances: `ModelCallEvidence` has no `FromJSON`, and its encoding can include provider response text in error messages. Billing observations remain unchanged. Add the new module to the exposed modules in `shikumi/shikumi.cabal`. Neither replay nor cache invokes the observer.

A cancelled attempt delivers no receipt, because no record exists for it. `mori://shinzui/baikai/okf/improvement-requests/concepts/IR-13` requests one; consuming it would raise this plan's `baikai-effectful` upper bound and is follow-up work, so this plan does not wait for it.

`streamProgram` returns only the typed output, so an application retains the raw answer by interposing on the `LLM` effect, in the same way for both operations. This requires no copy of Shikumi's router or parser:

```haskell
retainRaw :: (LLM :> es, IOE :> es) => IORef (Maybe Response) -> Eff es a -> Eff es a
retainRaw ref = interpose $ \_ -> \case
  Complete m c o -> do
    r <- complete m c o
    liftIO (writeIORef ref (Just r))
    pure r
  Stream m c o -> do
    evs <- stream m c o
    liftIO (writeIORef ref (either (const Nothing) Just (responseFromEvents m evs)))
    pure evs
```

Relevant dependency artifacts are `mori://shinzui/baikai/packages/baikai`, `mori://shinzui/baikai/packages/baikai-typesafe`, and `mori://shinzui/baikai/packages/baikai-effectful`. Existing bounds are core >=0.10.0.0 <0.11, TypeSafe >=0.1.0.1 <0.2, and effectful binding >=0.4.0.5 <0.5. Retain them unless implementation evidence requires a different released cohort; verify all changed cohort members against Hackage and upstream tags. No new production transport library is planned. The internal testing package already owns WAI/Warp loopback dependencies and remains unpublished.

Revision note, 2026-11-03: An API review pinned exact signatures and resolved decisions the plan had left open. It added per-attempt evidence provenance, separated terminal integrity from answer validity so generative decision streams are not refused, added pure event/response helpers because the relevant effect rows have no `IOE`, corrected the replay evidence claim, and set the release to 0.6.0.0.

Revision note, 2026-11-03: Expanded the scope to implement IR-3 except cancelled-attempt evidence, which moved to Baikai's IR-13. A new M2 holds the attempt evidence seam, and later milestones moved down by one. The observer became effectful and a runner argument, so `LLMConfig` is unchanged and the expected release is now 0.5.1.0. Added `withEvidenceRuns` and fail-closed behavior for thrown errors under `EvidenceRequired`, and removed `ToJSON` from `AttemptReceipt` because evidence can contain provider response text.
