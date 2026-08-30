---
title: "Ambient routing and resilient runtime policies"
type: Capability
description: "Install an effectful LM runtime that supplies ambient models and applies retry, rate-limit, budget, and error-normalization policies beneath unchanged Program values."
generated:
  by: codex/gpt-5
  at: "2026-08-30T20:48:38Z"
capabilityId: CAP-4
provider: mori://shinzui/shikumi
status: shipped
stability: experimental
since: "0.1.0.0"
packages:
  - shikumi
interface:
  - Shikumi.LLM
  - Shikumi.LLM.Budget
  - Shikumi.Routing
  - Shikumi.Effect.Time
requires:
  - CAP-2
evidence:
  - kind: test
    resource: shikumi/test/ResilienceSpec.hs
    proves: Transient retries, exhaustion, budget admission and charging, concurrency limits, and streamed-call failure handling are exercised hermetically.
  - kind: test
    resource: shikumi/test/RoutingSpec.hs
    proves: Ambient model identity, request translation, metadata stripping, and per-sample temperatures reach blocking and streaming wire calls.
  - kind: guide
    resource: docs/user/effects-and-runtime.md
    proves: Consumers can assemble minimal and resilient effect stacks with explicit narrow capabilities.
---

# Ambient routing and resilient runtime policies

Shikumi exposes provider calls as an `LLM` effect. Interpreters install the
actual `mori://shinzui/baikai` transport and can wrap it with ambient model routing, transient
retry, rate limiting, and usage/cost budgets. Program definitions remain free of
provider configuration and can run under a deterministic stub or a live backend
without changing their type.

The runtime normalizes transport failures into `ShikumiError`, distinguishes
context-window exhaustion, applies the same routing translation to blocking and
streaming calls, and charges a failed stream from its terminal usage before
surfacing the error. Time, primitive state, and concurrency are represented as
separate effects rather than hidden behind unrestricted `IO`.

This runtime executes the program values described by
[CAP-2](composable-program-values.md).

## Limits

- Budget admission is optimistic: concurrent calls can collectively overshoot
  a ceiling because no reservation is held for an in-flight request.
- Retry policy only retries errors classified as transient; validation and
  configuration failures escape immediately.
- Provider implementations and credentials come from
  `mori://shinzui/baikai` and its backend packages, not from shikumi itself.
