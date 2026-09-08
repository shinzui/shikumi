---
title: "Opt-in typed prediction capture"
type: Capability
description: "Mark individual prediction nodes to retain their typed input and output alongside derived schemas, so downstream tooling can recover per-node examples that ordinary prediction erases."
generated:
  by: claude/opus-5
  at: "2026-09-08T19:15:51Z"
capabilityId: CAP-27
provider: mori://shinzui/shikumi
status: shipped
stability: experimental
since: "0.4.0.0"
packages:
  - shikumi
interface:
  - Shikumi.Module
  - Shikumi.Program
requires:
  - CAP-2
evidence:
  - kind: test
    resource: shikumi/test/ModuleSpec.hs
    proves: A captured node behaves identically to an ordinary prediction while retaining its codec, and every program traversal preserves the codec.
  - kind: test
    resource: shikumi-optimize/test/NodeBootstrapSpec.hs
    proves: Captured nodes yield per-node demonstration pools that decode against the target predictor, and a composite program with uncaptured leaves fails with an actionable error.
  - kind: guide
    resource: docs/user/evaluation-and-optimization.md
    proves: Documents when to reach for predictCaptured, the added ToJSON/ToSchema requirements, and that ordinary predict is unchanged.
---

# Opt-in typed prediction capture

An ordinary `Predict` node erases its input and output types once composed into
a larger program: the surrounding program only knows the node's parameters and
shape. That erasure is what makes programs uniformly composable, but it also
means a tool working on a composed program cannot recover a typed example that
crossed a particular node.

`predictCaptured` builds a node that additionally carries a `CaptureCodec` —
the input and output JSON encoders plus both derived schemas. The node predicts
exactly as it otherwise would; nothing about prediction constraints or parameter
serialization changes. What changes is that a consumer can now recover typed,
schema-tagged examples from that specific node.

Capture is per-node and opt-in precisely because it retains data. A program
author chooses which nodes are worth capturing rather than paying retention
everywhere.

This extends [CAP-2 composable and rewritable program values](composable-program-values.md).
It is the mechanism the node-local bootstrap pools in
[CAP-16 budgeted program optimization](budgeted-program-optimization.md) require
to attribute demonstrations to individual student nodes.

## Limits

- Capture is opt-in per node. An uncaptured node yields nothing, and composite
  bootstrap over a program with uncaptured leaves cannot recover per-node pools.
- `Program` is a public GADT and gained a constructor in this release.
  Exhaustive matches on `Program` written against an earlier version must handle
  `PredictCaptured`.
- The codec retains encoders and schemas, not a transcript. It is not a trace —
  execution history remains [CAP-11](hierarchical-tracing.md)'s job.
- `Embed` stays opaque; capture does not reach inside an embedded program.
