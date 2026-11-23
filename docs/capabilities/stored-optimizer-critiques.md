---
title: "Stored critiques for optimizer feedback"
type: Capability
description: "Feed stored critiques keyed by stable example IDs into GEPA with human, model, or inferred provenance and node or program scope."
generated:
  by: agent:openai/codex
  at: "2026-11-23T17:41:12Z"
capabilityId: CAP-46
provider: mori://shinzui/shikumi
status: shipped
stability: experimental
since: "0.4.0.0"
packages:
  - shikumi-optimize
interface:
  - Shikumi.Optimize.Feedback
requires:
  - CAP-35
evidence:
  - kind: test
    resource: shikumi-optimize/test/FeedbackSpec.hs
    proves: Stored critiques retain their provenance, attach to executed nodes or the program, survive scored failures, and respect the reflection text budget.
---

# Stored critiques for optimizer feedback

A GEPA caller can supply a `storedCritiqueFeedback` callback with stable
example IDs in dataset order, stored critiques, and an evaluation metric.
Matching critiques attach during [CAP-35 failure-aware optimizer
feedback](failure-aware-optimizer-feedback.md). Their provenance distinguishes
human adjudication, model feedback, and inferences from operational outcomes.
The callback attaches critiques on failed executions and applies the configured
feedback bounds and redaction before reflection.

## Limits

- Node-scoped critiques require an observed, non-opaque node that executed.
- At most one program-scoped critique is retained per example. The reflection
  prompt only renders it when `includeProgramCritique` is enabled.
- The caller supplies and orders the IDs and stores the critiques.
