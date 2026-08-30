---
title: "Program-level typed streaming"
type: Capability
description: "Observe ordered field chunks and node, tool, and LM status events while a Program executes, then receive the same fully decoded typed result as the blocking path."
generated:
  by: codex/gpt-5
  at: "2026-08-30T20:48:38Z"
capabilityId: CAP-5
provider: mori://shinzui/shikumi
status: shipped
stability: experimental
since: "0.1.0.0"
packages:
  - shikumi
interface:
  - Shikumi.Stream
requires:
  - CAP-2
  - CAP-3
  - CAP-4
evidence:
  - kind: test
    resource: shikumi/test/StreamSpec.hs
    proves: Program streaming emits ordered field and status events, preserves typed decoding, validates outputs, and accounts for terminal usage.
  - kind: test
    resource: shikumi/test/RoutingSpec.hs
    proves: Routed streams carry the resolved model and translated wire options rather than internal placeholders.
  - kind: example
    resource: shikumi-jitsurei/app/Streaming.hs
    proves: A complete offline program exposes progress events and returns its typed answer.
---

# Program-level typed streaming

`streamProgram` is an additive execution surface over a normal `Program i o`.
The caller supplies an effectful callback that receives ordered `StreamEvent`
values as execution proceeds, and the call still returns the validated typed
output `o` when complete. Field chunks describe incremental output; status
events bracket program nodes, tool work, and model calls.

The surface uses the same provider-aware adapters and resilient routing as the
blocking runner, including native JSON decoding and terminal usage charging.
It builds on [CAP-2](composable-program-values.md),
[CAP-3](structured-output-adapters.md), and
[CAP-4](resilient-runtime-routing.md).

## Limits

- Field-level chunks are promised for a prediction node on the raw-text/fallback
  path. Native whole-JSON responses may only become meaningful once complete.
- Composite and opaque nodes emit status rather than fabricated field chunks.
- Cache and replay interpreters pass transport-level streaming through; they
  cache and replay blocking completion calls only.
