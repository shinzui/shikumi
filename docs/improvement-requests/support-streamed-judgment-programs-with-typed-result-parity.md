---
type: Improvement Request
title: Support streamed judgment programs with typed result parity
description: >-
  Support decision outputs through the public streaming runner and router while
  preserving complete-call derivation settings, structured answers, and acknowledged attempt evidence.
timestamp: "2026-11-03T12:51:45Z"
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-11-03T03:54:05Z"
requestId: IR-5
status: completed
completedAt: "2026-11-03T12:51:45Z"
resolution: >-
  Implemented by docs/plans/68-support-streamed-judgment-programs-with-typed-result-parity.md
  and released as shikumi 0.5.1.0, shikumi-cache 0.2.1.1, shikumi-tools 0.4.2.1
  and shikumi-trace 0.3.2.0. Typed stream parity, acknowledged attempt evidence
  and structured replay pass hermetic and released TypeSafe loopback fixtures.
  Tagged Hackage artifacts and GitHub releases are verified; downstream acceptance
  remains the consuming repository's separate gate.
reviews:
  - kind: model
    reviewer: openai/gpt-6.1-sol
    reviewed_at: "2026-11-03T04:46:53Z"
    document_timestamp: "2026-11-03T04:46:53Z"
    scope: technical-accuracy
    outcome: commented
    context: >-
      Verified implementation against the released TypeSafe loopback, attempt-evidence
      barriers and cache/replay suites; release and downstream acceptance remain pending.
    provider: openai
    model: gpt-6.1-sol
    effort: unspecified
origin: mori://shinzui/shikigami
targetPlan: mori://shinzui/shikigami/plans/80-configure-model-providers-and-agent-launches-through-baikai
---

# Improvement Request: Support Streamed Judgment Programs with Typed Result Parity

## Status

Completed on 2026-11-03 by [plan 68](../plans/68-support-streamed-judgment-programs-with-typed-result-parity.md).
The tagged [shikumi 0.5.1.0](https://hackage.haskell.org/package/shikumi-0.5.1.0)
and [shikumi-trace 0.3.2.0](https://hackage.haskell.org/package/shikumi-trace-0.3.2.0)
releases are published, together with cache 0.2.1.1 and tools 0.4.2.1. Every tag
points to `7b96ecf06364b37de44b15c4f58b2528b5a3e0f5`; Hackage source archives
match the inspected release bytes and public Haddock documentation is verified.

The core suite includes 31 acknowledged-attempt tests. The 21 SystemOne tests
exercise the released TypeSafe provider over loopback HTTP: default and explicit
calibration parity, exact raw answers and wire bodies, atomic event order,
acknowledgement barriers, retry provenance, cancellation cleanup and failure
boundaries. Trace and cache tests retain structured data without fresh receipts.
All 13 Cabal suites, build, formatting, flake, Haddock and package checks pass,
with Redis's existing integration skip and paid/live calls disabled.

The Shikigami downstream acceptance gate remains pending its own released-cohort
fixture. This completed supplier request does not claim consumer acceptance.

## Context

Shikigami is adopting the released Shikumi 0.5.0.0 and Baikai 0.10.0.0 cohort in
`mori://shinzui/shikigami/plans/80-configure-model-providers-and-agent-launches-through-baikai`.
Its complete-call fixture already runs a typed judgment program through the public
Shikumi router and Baikai TypeSafe provider. It retains the raw structured answer,
the locally derived `Noul`, `Choice`, and `Score` results, and the acknowledged
provider receipt.

The corresponding public streaming path is blocked before transport. In the
Shikumi 0.5.0.0 release (tag commit
`b9b7a73f276ec022a72d00a447d320eade1cb741`):

- [streamPredict](../../shikumi/src/Shikumi/Stream.hs) rejects a nonempty
  `evidenceFields @o (decisionSettings ps)` with
  `ValidationFailure "decision outputs do not support streaming"`.
- The `Stream` branch of [routeLLM](../../shikumi/src/Shikumi/Routing.hs) rejects
  `DecisionOnly` models or requests carrying decision metadata with the same
  error. An application provider wrapper cannot handle a request that never
  reaches it.
- `streamPredict` finishes with `parseResponse`, whose default settings differ
  from the complete path's `parseResponseWithSettings (decisionSettings ps)`.
  Removing the two refusals alone would not establish local derivation parity.

The downstream evidence is recorded at
`mori://shinzui/shikigami/okf/friction-log/concepts/FRIC-49`.
Baikai already documents atomic structured judgment streaming in
`mori://shinzui/baikai/docs/typesafe-judgments`. The missing integration belongs
in Shikumi's public runner and router.

## Requested Change

Allow judgment programs to run through `Shikumi.Stream.streamProgram` and
`Shikumi.Routing.routeLLM` using the public Baikai structured stream contract.
Use the same effective signature, decision field schemas, default settings,
explicit immutable `Params`, request validation, and local derivation semantics
as `runProgram`.

For TypeSafe, consume Baikai's synthetic atomic `DataStart`/`DataEnd` events and
terminal response. Do not represent an atomic judgment as incremental prose or
invent partial probability distributions. Return the typed result only after
the complete structured answer and successful terminal event have been
validated and the attempt evidence has been acknowledged.

Preserve the rich `Noul`, `Choice`, and `Score` values, their distributions, and
optional provider confidence/method fields. Keep the provider's raw answer
distinct from the locally derived value: a weighted choice may deliberately
differ from the provider's highest-probability choice. Explicit thresholds,
choice weights, score cuts, and their defaults must produce the same result in
complete and streaming execution.

Unsupported generation controls, incompatible output schemas, and invalid
decision settings must fail before provider IO under the same policy as the
complete path. Provider failure, malformed structured output, cancellation,
consumer failure, or evidence-observer failure must not return a successful
partial judgment.

## Attempt and Evidence Semantics

A successful synthetic TypeSafe stream represents one actual provider
invocation and one terminal attempt receipt. Preserve the resilient
interpreter's retry provenance and acknowledgement ordering; each retry is a
separate actual attempt. Cancellation must settle the provider operation under
the existing public cancellation contract.

Cache hits and deterministic replay must retain structured values without
fabricating a new provider attempt or receipt. An evidence observer failure is
terminal and must not trigger a second provider call or permit successful
output to escape. This request extends the existing lifecycle to judgment
streams rather than introducing a second retry loop.

## Required Tests

Add deterministic tests through the public runner, router, and released Baikai
TypeSafe provider, with a loopback HTTP fixture and no paid model calls:

1. Execute the same typed `Noul`/`Choice`/`Score` program in complete and stream
   modes. Assert equal rich typed results and equal raw structured answers,
   including optional confidence/method fields.
2. Use explicit settings that differ from defaults. Include a weighted choice
   whose local winner differs from the provider's highest-probability choice,
   plus a predicate threshold and score cuts that affect derivation. Assert
   settings are applied identically in both modes.
3. Inspect the exact TypeSafe request: the same decision schema/settings and
   effective model reach the provider, private routing metadata is consumed,
   and unsupported generation defaults are absent.
4. Assert atomic structured event ordering, one HTTP invocation, and one
   acknowledged terminal receipt before successful typed return. Exercise
   retry provenance separately when a retryable failure is injected.
5. Exercise malformed or missing structured data, terminal stream failure,
   cancellation, callback failure, and evidence-observer failure. None may
   produce a successful partial result; observer failure must not redispatch.
6. Assert invalid settings, incompatible schemas, and unsupported generation
   controls refuse before HTTP. Assert cache/replay preserves the structured
   answer and emits no fresh provider evidence.
7. Retain regression coverage for existing generative streaming, native JSON
   output, validation, and evidence-disabled callers.

The existing [decision derivation tests](../../shikumi/test/DecisionDeriveSpec.hs),
[stream tests](../../shikumi/test/StreamSpec.hs), and
[routing tests](../../shikumi/test/RoutingSpec.hs) provide useful regression
boundaries; a scripted text interpreter alone does not qualify the TypeSafe
transport integration.

## Acceptance and Deliverables

A downstream application can use the public `streamProgram` and `routeLLM`
APIs with a judgment-only model, receive the same typed result as `runProgram`
under the same settings, and retain the exact structured answer and
acknowledged actual-attempt evidence. The integration requires no downstream
copy of Shikumi's router, parser, retry loop, or provider supervisor.

Ship the implementation, deterministic transport and lifecycle tests, public
API documentation, and changelog in a tagged Hackage release of
`mori://shinzui/shikumi/packages/shikumi`. Bound the release to a coherent
Baikai cohort and document the atomic nature of TypeSafe streaming. The
Shikigami complete/stream acceptance gate remains open until that released
integration passes its consumer fixture.
