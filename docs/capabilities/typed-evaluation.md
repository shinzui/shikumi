---
title: "Typed evaluation and reporting"
type: Capability
description: "Evaluate a typed Program over typed datasets with pure or model-backed metrics, bounded concurrency, per-example timeouts, usage accounting, reports, and golden-test helpers."
generated:
  by: codex/gpt-5
  at: "2026-08-30T20:48:38Z"
capabilityId: CAP-14
provider: mori://shinzui/shikumi
status: shipped
stability: experimental
since: "0.1.0.0"
packages:
  - shikumi-eval
interface:
  - Shikumi.Eval
  - Shikumi.Eval.Evaluate
  - Shikumi.Eval.Metric
  - Shikumi.Eval.Report
  - Shikumi.Eval.Golden
  - Shikumi.Eval.Usage
requires:
  - CAP-2
  - CAP-4
evidence:
  - kind: test
    resource: shikumi-eval/test/EvaluateSpec.hs
    proves: Bounded evaluation preserves example order, records failures instead of aborting, applies timeouts, and accounts for usage and latency.
  - kind: test
    resource: shikumi-eval/test/MetricSpec.hs
    proves: Exact, normalized, thresholded, weighted, and inverted metric combinators return bounded Scores.
  - kind: test
    resource: shikumi-eval/test/ReportSpec.hs
    proves: Aggregates, counts, latency sums, usage monoids, and text rendering match the documented report contract.
  - kind: example
    resource: shikumi-jitsurei/app/Evaluate.hs
    proves: A complete offline evaluation runs a typed program over a typed dataset and renders a report.
---

# Typed evaluation and reporting

`shikumi-eval` connects the same typed program used in production to datasets of
typed examples and `Metric` values. It supports exact and string metrics,
embedding similarity, model judges, metric combinators, bounded concurrent
execution, optional per-example deadlines, usage and latency accounting, stable
result order, rendered reports, and tasty golden helpers.

Failures become per-example results instead of aborting the entire dataset, so a
report can distinguish poor predictions from provider or decoding failures. The
capability evaluates the programs from [CAP-2](composable-program-values.md)
under the runtime policies in [CAP-4](resilient-runtime-routing.md).

## Limits

- Model-backed metrics inherit the cost, latency, and nondeterminism of their LM
  calls; pure metrics remain the reproducible baseline.
- Concurrent report latency is explicitly a sum of per-example latencies, not
  wall-clock elapsed time.
- A metric defines the meaning of quality; the framework enforces `Score` bounds
  but cannot validate domain fitness.
