---
title: "Isolated node observation with rejection lineage"
type: Capability
description: "Run a program once and recover structured per-node evidence, including failed attempts and why each rejected output was rejected, isolated from concurrent runs."
generated:
  by: claude/opus-5
  at: "2026-09-08T19:15:51Z"
capabilityId: CAP-32
provider: mori://shinzui/shikumi
status: shipped
stability: experimental
since: "0.3.0.0"
packages:
  - shikumi-trace
interface:
  - Shikumi.Trace.Observation
requires:
  - CAP-11
evidence:
  - kind: test
    resource: shikumi-trace/test/ObservationSpec.hs
    proves: runProgramObserved returns per-node observations retaining rejected attempts with their rejection reason, and concurrent outer executions do not observe each other's nodes.
  - kind: guide
    resource: docs/user/evaluation-and-optimization.md
    proves: Documents runProgramObserved as the evidence source for failure-aware optimization feedback.
---

# Isolated node observation with rejection lineage

`runProgramObserved` executes a program once and returns, alongside the result,
a `NodeObservation` per prediction node. Unlike a trace tree — which records
what happened for a human or an exporter to read — an observation is structured
evidence intended to be *consumed programmatically*, and it deliberately retains
what a successful-path trace discards: the attempts that failed, and the reason
each rejected output was rejected.

That rejection lineage is the input the failure-aware optimizer feedback in
[CAP-16 budgeted program optimization](budgeted-program-optimization.md) needs.
An optimizer improving a node has to know not merely that the node scored badly
but that, say, its third attempt decoded but failed validation on a named field.

Observation is isolated per execution. Concurrent outer executions use separate
storage and cannot see each other's nodes, so an observed run inside a
parallel evaluation reports only its own evidence.

This shares traced control flow with
[CAP-11 hierarchical, node-correlated tracing](hierarchical-tracing.md); running
observed does not change what the program computes.

## Limits

- Sequential within one execution. Isolation is between outer executions, not a
  claim that a single observed run parallelizes internally.
- `Embed` remains opaque. Nodes inside an embedded program are not observed.
- Observations are evidence, not a replayable transcript; deterministic replay
  remains [CAP-12](deterministic-replay.md)'s job.
