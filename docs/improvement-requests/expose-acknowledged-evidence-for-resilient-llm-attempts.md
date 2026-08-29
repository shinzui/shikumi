---
type: Improvement Request
title: Expose acknowledged evidence for every resilient LLM attempt
description: >-
  Add a released, call-scoped Shikumi seam that supplies fresh Baikai evidence provenance and
  acknowledges every provider attempt before retrying or returning.
timestamp: 2026-08-22T19:11:51Z
generated:
  by: openai/gpt-5
  at: "2026-08-22T19:11:51Z"
requestId: IR-3
status: proposed
origin: mori://shinzui/kioku
targetPlan: mori://shinzui/kioku/plans/16-add-distillation-replay-metadata
reviews:
  - kind: model
    reviewer: openai/gpt-5
    reviewed_at: "2026-08-22T19:11:51Z"
    document_timestamp: "2026-08-22T19:11:51Z"
    scope: technical-accuracy
    outcome: commented
    context: >-
      Compared with the current Shikumi resilient interpreter, Baikai model-call evidence guide
      and API, and the originating Kioku ExecPlan; no independent acceptance decision was made.
    provider: openai
    model: gpt-5
    effort: unspecified
---

# Improvement Request: Expose Acknowledged Evidence for Every Resilient LLM Attempt

## Status

Proposed. This is the Shikumi-owned prerequisite for
`mori://shinzui/kioku/masterplans/4-secure-and-accountable-distillation-evidence` and
`mori://shinzui/kioku/plans/16-add-distillation-replay-metadata`.


## Context

Baikai 0.5 provides `EvidenceRequest`, `ModelCallEvidence`, strict pre-dispatch evidence
requirements, and a `CallEvidence` trace event. Baikai deliberately does not own retries: the
caller supplies the one-based `attempt` and previous call ID in `supersedes`.

Shikumi's `runLLMResilient` owns the retry loop for both blocking and streaming LLM operations.
It currently sends the same `Options` on every attempt and maps an error-shaped response or
terminal stream event to `ShikumiError` inside that loop. A caller above the interpreter can see
only the final outcome, while a layer below it cannot assign correct retry provenance. Failed
attempt evidence can therefore disappear before an application such as Kioku can durably account
for the provider call.

This lifecycle gap cannot be closed by copying Shikumi's retry loop downstream or by inferring
provider evidence from a `ShikumiError`. The resilient interpreter must expose the attempt
lifecycle it already owns.


## Requested Change

Add a policy-neutral, call-scoped evidence seam to the public resilient LLM interpreter. The
caller supplies:

- one opaque Baikai run ID for the logical provider invocation;
- the desired `EvidenceStrictness`; and
- an effectful attempt observer whose successful return acknowledges that the evidence was
  handled.

For each actual Baikai dispatch, Shikumi must create a fresh `EvidenceRequest` using the same run
ID, increment the one-based attempt number, and set `supersedes` to the immediately preceding
attempt's Baikai call ID. Shikumi must deliver the exact provider-built `ModelCallEvidence`; it
must not reconstruct endpoint, model, usage, status, commitment, or error fields from Shikumi
configuration or results.

The seam must cover both `Complete` and `Stream` operations. It may be a new interpreter,
configuration layer, or scoped effect, provided callers can install an observer in their ordinary
Effectful stack and existing evidence-disabled callers remain source- and behavior-compatible.


## Ordering and Failure Semantics

The observer runs exactly once for every evidence-bearing attempt, including:

- provider success;
- an error-shaped provider response;
- transport or provider failure;
- strict pre-dispatch refusal; and
- streaming success, terminal failure, or consumer abort.

Shikumi waits for the observer to acknowledge an attempt before it retries, maps the result to
`ShikumiError`, or returns success. An observer failure is terminal and is not a transient
provider failure: it must not trigger another paid provider call or allow a successful result to
escape. When evidence is required but no record can be delivered, the call fails rather than
silently succeeding without the requested evidence.

A Shikumi budget refusal, rate-limit failure before dispatch, cache hit, or deterministic replay
is not a provider attempt and emits no new provider evidence. Concurrent resilient invocations
must maintain independent run, attempt, and supersession state.


## Required Tests

Add hermetic fake-provider tests proving:

1. a transient first failure followed by success produces attempts 1 and 2 under one run ID, with
   attempt 2 superseding attempt 1's call ID;
2. the first observer acknowledgement completes before the second dispatch begins;
3. successful blocking output is returned only after its evidence is acknowledged;
4. terminal blocking failure is observed before `ShikumiError` is returned;
5. strict pre-dispatch refusal produces evidence without invoking the provider;
6. streaming success, terminal failure, and abort each deliver their exact evidence once;
7. observer failure is terminal, returns no successful output, and leaves the provider invocation
   count at one even when the provider error would otherwise be retryable;
8. budget refusal, pre-dispatch rate-limit failure, cache, and replay paths produce no fabricated
   provider attempt;
9. concurrent calls do not share attempt counters or supersession links; and
10. the existing evidence-disabled `runLLMResilient` path preserves its API, behavior, and
    no-evidence overhead contract.


## Acceptance

A caller can run a blocking or streaming Shikumi program through the released resilient
interpreter, request Baikai evidence, and durably handle every provider attempt before Shikumi can
retry or return. A two-attempt fixture demonstrates correct one-based attempt and supersession
provenance. A failing observer demonstrates fail-closed ordering and proves that no second paid
call occurs.

The public API, lifecycle semantics, and integration example are documented and included in a
tagged Hackage release. If exposing the complete lifecycle requires a trace-aware addition to
`mori://shinzui/baikai/packages/baikai-effectful`, release and bound that package coherently rather
than introducing a downstream registry wrapper or a second retry loop.


## Requested Deliverables

- A public effectful attempt-evidence API in `mori://shinzui/shikumi/packages/shikumi`.
- Blocking and streaming integration with `mori://shinzui/baikai/packages/baikai` evidence.
- Hermetic ordering, retry-provenance, refusal, abort, failure, and concurrency tests.
- User documentation and changelog entries describing compatibility and failure semantics.
- A tagged Hackage release consumable without a source override.


## Non-goals

This request does not add a database, evidence retention policy, artifact-provenance schema, or
Kioku-specific type to Shikumi. It does not move retry ownership into Baikai, treat cache/replay
hits as provider calls, retain prompts or responses, or make Shikumi decide what evidence strength
an application requires. Applications remain responsible for persistence, redaction, access
control, retention, and linking acknowledged call IDs to their own artifacts.
