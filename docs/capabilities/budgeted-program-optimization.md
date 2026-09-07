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
  - Shikumi.Optimize.Structure
  - Shikumi.Optimize.Execution
  - Shikumi.Optimize.Report
  - Shikumi.Optimize.Feedback
  - Shikumi.Optimize.GEPA
  - Shikumi.Optimize.KNN
  - Shikumi.Optimize.Ensemble
requires:
  - CAP-11
  - CAP-14
  - CAP-15
evidence:
  - kind: test
    resource: shikumi-optimize/test/StructureSpec.hs
    proves: Finite typed recipes select on validation, obey shared admission, retain deterministic ties, and restore identical requests and outputs.
  - kind: test
    resource: shikumi-optimize/test/FeedbackSpec.hs
    proves: Failed examples retain positions, node critiques target executed invocations, reflection uses redacted intermediate evidence, and cancellation escapes.
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

GEPA supports explicitly attributed node critiques and indexed failed-execution
evidence. Legacy critiques remain labeled program-scoped. Reflection bounds and
redacts local evidence and retains failed retry lineage, including without JSON
codecs. Output failures are scored by default; budget exhaustion and infrastructure
errors escape unless the latter are explicitly classified.

## Limits

- GEPA capture is sequential. Critic calls and retry expansion are not strictly
  charged by the existing predicted-call budget; split-aware execution and lifecycle
  reports remain future work. Raw returned evidence is not redacted.
- `Embed` is opaque; hidden predictors cannot provide node demonstrations.
- Optimizer quality depends on representative training/evaluation data and the
  chosen metric; held-out tests are still required.
- Structure-changing artifacts such as KNN or ensembles must be loaded against
  the matching compiled template.
- Budget accounting is expressed in LM calls, not currency; provider pricing
  and token totals remain separate runtime observations.

## Configured validation and execution reports

`optimizeWith` and `gepaWith` add separate validation data, named quality/resource
objectives, and versioned diagnostic reports. The configured session atomically
admits Shikumi Complete/Stream operations and bounds active dispatches independently
of candidate batches. Retry and Embed calls share admission with proposal and critic
calls. Incomplete validation cannot win; a stopped search retains its completed
winner or reports an unscored baseline. Legacy opaque strategies expose run-level
accounting with candidate detail explicitly unavailable.

`jitsurei-gepa-objectives` is an offline validation-selected B fixture. Optimizer
regressions exercise contrary training/validation rankings, sentinel exclusion from
reflection, cost ceilings and Pareto ties, budget catches and concurrent contention,
barrier-controlled dispatch width, cancellation cleanup, and report JSON round trips.

These reports are diagnostic, not sealed dataset provenance, promotion authority,
or protected-holdout comparison artifacts. The hard unit is an admitted framework
LLM operation, not provider-internal attempts or dollars. The seed controls candidate
scheduling; concurrent dispatch races and live responses are not deterministic.

Finite typed structure selection is available through `structureSearchWith`. The
caller owns the nonempty recipe registry and implementation revisions; artifacts
restore only through a compatible registry. This experimental API shares actual
operation admission and validation objectives, excludes incomplete candidates,
and returns an explicitly unscored first baseline when necessary. Structure
artifacts are distinct from compiled parameter state and grant no production
promotion authority. See [the workflow](../user/evaluation-and-optimization.md#experimental-finite-structure-search)
and [ADR-8](../adr/0008-restore-typed-structures-through-trusted-recipe-registries.md).
