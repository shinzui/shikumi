---
title: "Budgeted program optimization"
type: Capability
description: "Search a Program's instructions, demonstrations, neighbors, and ensembles with multiple optimizers that score typed datasets and stop with the best-so-far candidate at an LM-call budget."
generated:
  by: process:codex
  at: "2026-09-07T14:05:00Z"
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

Bootstrap, RandomSearch, and MIPRO recover demonstrations for a predictor, and
the [user guide](../user/evaluation-and-optimization.md) walks through
configuration and a city/country pipeline.

Four later capabilities grow this one and are released separately, so a consumer
pinned to an earlier `shikumi-optimize` gets this record's provision and not
theirs:

- [CAP-33 validated optimizer execution and lifecycle reports](validated-gepa-execution.md)
  makes budget admission precise and adds versioned diagnostic reports.
- [CAP-34 structure search over finite recipe registries](structure-search.md)
  selects among alternative program structures.
- [CAP-35 failure-aware optimizer feedback](failure-aware-optimizer-feedback.md)
  attributes critiques to the node and invocation that failed.
- [CAP-36 node-local bootstrap demonstration pools](node-local-bootstrap-pools.md)
  recovers demonstrations per node in a composite program.

## Limits

- GEPA capture is sequential. In this record's provision, critic calls and retry
  expansion are not strictly charged by the predicted-call budget and raw
  returned evidence is not redacted; strict admission, lifecycle reports, and
  bounded redacted reflection arrive with
  [CAP-33](validated-gepa-execution.md) and
  [CAP-35](failure-aware-optimizer-feedback.md).
- `Embed` is opaque; hidden predictors cannot provide node demonstrations.
- Optimizer quality depends on representative training/evaluation data and the
  chosen metric; held-out tests are still required.
- Structure-changing artifacts such as KNN or ensembles must be loaded against
  the matching compiled template.
- Budget accounting is expressed in LM calls, not currency; provider pricing
  and token totals remain separate runtime observations.
