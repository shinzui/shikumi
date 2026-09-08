---
title: "Node-local bootstrap demonstration pools"
type: Capability
description: "Recover and validate few-shot demonstrations per predictor node in a composite program, with explicit teacher-to-student mapping, per-node caps, and independent seeded selection."
generated:
  by: claude/opus-5
  at: "2026-09-08T19:15:51Z"
capabilityId: CAP-36
provider: mori://shinzui/shikumi
status: shipped
stability: experimental
since: "0.3.0.0"
packages:
  - shikumi-optimize
interface:
  - Shikumi.Optimize.Bootstrap
requires:
  - CAP-16
  - CAP-27
evidence:
  - kind: test
    resource: shikumi-optimize/test/NodeBootstrapSpec.hs
    proves: Demonstrations are recovered per target node under explicit mappings and per-node caps, each captured value must decode at its target predictor, rejected encodings are reported and never installed, and seeded selection is independent per target.
  - kind: test
    resource: shikumi-optimize/test/BootstrapSpec.hs
    proves: Legacy single-predictor bootstrap and existing BootstrapConfig construction continue to work unchanged.
  - kind: guide
    resource: docs/user/evaluation-and-optimization.md
    proves: Documents capture requirements, target mapping, merge behavior, and the actionable error raised for composite programs with uncaptured leaves.
---

# Node-local bootstrap demonstration pools

Bootstrapping few-shot demonstrations is straightforward for a single predictor
and subtle for a composite program: a demonstration that crossed the second
stage of a pipeline is not a valid demonstration for the first, and installing
it there teaches the wrong thing.

This capability recovers demonstrations *per node*. Matching checks structure
and schemas, or accepts an explicit compatible teacher-to-student path mapping;
several source paths may feed one target only when merging is requested
explicitly. Every captured value must additionally decode against the target
predictor's own `FromModel` instances — rejected custom encodings are reported
and never installed, so a silently mistyped demonstration cannot enter a pool.
Caps apply per node, and seeded selection is independent per target so one
node's pool does not perturb another's.

RandomSearch and MIPRO consume node pools. Existing `BootstrapConfig`
construction and legacy single-predictor bootstrap remain supported;
`bootstrapDemosFor` is the legacy single-node adapter.

Composite bootstrap requires captured leaves — see
[CAP-27 opt-in typed prediction capture](typed-prediction-capture.md) — and a
composite program with uncaptured leaves fails with an actionable error rather
than silently producing empty pools. This is growth of
[CAP-16 budgeted program optimization](budgeted-program-optimization.md).

## Limits

- `bootstrapKeptDemos` is single-node only in this release; composite programs
  use the node-local path.
- `Embed` is opaque. Hidden predictors cannot supply node demonstrations, and a
  boundary can be reported but not entered.
- Unmapped targets receive an empty recovered pool rather than a borrowed one.
- Recovery validates decodability and provenance, not pedagogical value; a
  demonstration can be well-typed and still be a poor example.
