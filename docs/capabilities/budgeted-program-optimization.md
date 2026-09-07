---
title: "Budgeted program optimization"
type: Capability
description: "Search a Program's instructions, demonstrations, neighbors, and ensembles with multiple optimizers that score typed datasets and stop with the best-so-far candidate at an LM-call budget."
generated:
  by: process:codex
  at: "2026-09-07T02:26:32Z"
capabilityId: CAP-16
provider: mori://shinzui/shikumi
status: shipped
stability: experimental
since: "0.1.0.0"
packages:
  - shikumi-optimize
interface:
  - Shikumi.Optimize
  - Shikumi.Optimize.LabeledFewShot
  - Shikumi.Optimize.Bootstrap
  - Shikumi.Optimize.Instruction
  - Shikumi.Optimize.RandomSearch
  - Shikumi.Optimize.COPRO
  - Shikumi.Optimize.MIPRO
  - Shikumi.Optimize.GEPA
  - Shikumi.Optimize.KNN
  - Shikumi.Optimize.Ensemble
requires:
  - CAP-11
  - CAP-14
  - CAP-15
evidence:
  - kind: test
    resource: shikumi-optimize/test/NodeBootstrapSpec.hs
    proves: Heterogeneous capture pipelines recover node-local demos, reject incompatible mappings before calls, and restore parameters onto their template.
  - kind: test
    resource: shikumi-optimize/test/AcceptanceSpec.hs
    proves: Multiple strategies improve held-out score and change only the intended prediction nodes.
  - kind: test
    resource: shikumi-optimize/test/Miprov2Spec.hs
    proves: Joint instruction and demonstration search respects one shared call budget and returns serializable state.
  - kind: test
    resource: shikumi-optimize/test/GepaSpec.hs
    proves: Node-correlated feedback drives reflective mutation, improves held-out score, respects the budget gate, and round-trips.
  - kind: example
    resource: shikumi-jitsurei/app/Optimize.hs
    proves: An optimizer runs completely offline against a typed dataset and emits a reusable compiled program.
---

# Budgeted program optimization

`shikumi-optimize` treats node parameters exposed by a typed program as the
search space and evaluation scores as the objective. It ships labeled and
bootstrapped few-shot selection, instruction and random search, COPRO, MIPROv2,
GEPA, KNN, Pareto helpers, and ensemble search. Shared budget metering predicts
the next scoring/proposal cost before spending and returns the best candidate
already found when the next step would exceed the ceiling.

It composes [evaluation](typed-evaluation.md), shape-safe
[compilation](pure-program-compilation.md), and node-correlated
[trace feedback](hierarchical-tracing.md).

Bootstrap, RandomSearch, and MIPRO recover demonstrations per predictor. Composite
programs require `predictCaptured` leaves; matching checks structure and schemas,
or accepts an explicit compatible teacher-to-student path mapping. Captured demos
must decode at the target node. Rejected attempts are excluded and seeded selection
is independent per target. See the [user guide](../user/evaluation-and-optimization.md)
for configuration and a city/country pipeline.

## Limits

- `Embed` is opaque; hidden predictors cannot provide node demonstrations.
- Optimizer quality depends on representative training/evaluation data and the
  chosen metric; held-out tests are still required.
- Structure-changing artifacts such as KNN or ensembles must be loaded against
  the matching compiled template.
- Budget accounting is expressed in LM calls, not currency; provider pricing
  and token totals remain separate runtime observations.
