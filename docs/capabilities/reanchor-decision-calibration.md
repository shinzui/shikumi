---
title: "ReAnchor decision calibration"
type: Capability
description: "Fit persistent decision thresholds, cuts and weights through budgeted response replay, retaining only strict improvements accepted by held-out folds."
generated:
  by: openai/codex
  at: "2026-11-03T01:52:53Z"
capabilityId: CAP-41
provider: mori://shinzui/shikumi
status: shipped
stability: experimental
since: "0.3.1.0"
packages:
  - shikumi-optimize
interface:
  - Shikumi.Optimize.ReAnchor
  - Shikumi.Optimize.ReAnchor.Fit
  - Shikumi.Optimize.ReAnchor.Replay
requires:
  - CAP-40
  - CAP-33
evidence:
  - kind: test
    resource: shikumi-optimize/test/ReAnchorSpec.hs
    proves: Threshold, score and choice fitting replays evidence, rejects fold failures, preserves accepted settings under budget stops and supports generative evidence.
---

# ReAnchor decision calibration

`reAnchor` and `reAnchorWith` fit per-field decision settings while retaining
instructions and demonstrations. Candidate trials share run-local response
replay inside search-session admission; new requests consume the operation
budget. The strategy retains strict training improvements only when held-out
fold checks accept them. Rejected trials restore absent settings.

Reports include retained settings, score summaries, observed evidence ranges
and fold counters. `setSelectedCandidate` lets a strategy pin the accepted
candidate so an unaccepted trial cannot become the reported winner.

Builds on [CAP-40 persistent decision settings](persistent-decision-settings.md), [CAP-33 validated optimizer execution](validated-gepa-execution.md).

## Limits

- Requires a nonempty training dataset and rich decision outputs; it does not
  calibrate arbitrary free-form outputs or opaque embedded nodes.
- Candidate and operation limits can stop fitting before all fields improve.
- Optional validation is report-only and does not select the fitted settings.
- Fold acceptance is empirical evidence, not a guarantee on unseen inputs.
