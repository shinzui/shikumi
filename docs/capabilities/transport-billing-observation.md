---
title: "Per-attempt transport billing observation"
type: Capability
description: "Observe every provider attempt made by a program run and collect exact per-attempt cost and token accounting separately from logical usage, without exposing prompts, outputs, or credentials."
generated:
  by: claude/opus-5
  at: "2026-09-08T19:15:51Z"
capabilityId: CAP-23
provider: mori://shinzui/shikumi
status: shipped
stability: experimental
since: "0.4.0.0"
packages:
  - shikumi
interface:
  - Shikumi.LLM.Observation
requires:
  - CAP-4
evidence:
  - kind: test
    resource: shikumi/test/ResilienceSpec.hs
    proves: Observers see each transport attempt including retried and failed ones, observer exceptions propagate without triggering a retry or an extra budget charge, and cancellation emits no synthetic terminal.
  - kind: test
    resource: shikumi-trace-otel/test/BillingSpec.hs
    proves: Collected attempt billing survives into trace export as separately scoped transport counters distinct from logical usage.
  - kind: guide
    resource: docs/adr/0013-separate-transport-billing-from-logical-usage.md
    proves: Records why transport billing is counted per attempt rather than folded into a run's logical usage totals.
---

# Per-attempt transport billing observation

A run installs an observer on the bare or resilient runtime and receives one
observation per *transport attempt*. A retried call therefore reports every
attempt it made, not just the one that succeeded, so cost and token accounting
reflects what the provider actually billed rather than what the program
logically asked for.

Observations carry identity and accounting only. They never carry prompts,
completions, credentials, or provider error messages, so an observer can be
attached to a run handling sensitive input without becoming a second copy of
that input. The bundled collector is bounded and thread-safe, persists exact
rational costs, and marks usage explicitly unknown rather than guessing zero.

This extends the runtime policies in
[CAP-4 ambient routing and resilient runtime policies](resilient-runtime-routing.md);
the retry and budget behavior it observes is unchanged by observing it.

## Limits

- A collector is run-local. Create a separate collector per run; it does not
  aggregate across concurrent independent runs for you.
- Observer IO exceptions propagate outside provider retry classification — an
  observer that throws will fail the run rather than be retried.
- Cost is only as exact as the provider's reported usage. Where a provider
  reports no usage, the observation says unknown; it does not estimate.
- Observation is accounting, not tracing. Node-level structure and lineage come
  from [CAP-11](hierarchical-tracing.md), not from this interface.
