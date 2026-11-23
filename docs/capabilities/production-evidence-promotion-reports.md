---
title: "Production-evidence optimization and promotion reports"
type: Capability
description: "Optimize a typed program on a sealed dataset of production evidence and receive a digested candidate plus a baseline-versus-candidate report, decided on a protected holdout as Improved, Regressed, Inconclusive or Invalid and reproducible by replay."
generated:
  by: agent:anthropic/claude-opus-5-5
  at: "2026-11-19T00:33:39Z"
capabilityId: CAP-45
provider: mori://shinzui/shikumi
status: shipped
stability: experimental
since: "0.1.0.0"
packages:
  - shikumi-evidence
interface:
  - Shikumi.Evidence
  - Shikumi.Evidence.Dataset
  - Shikumi.Evidence.Artifact
  - Shikumi.Evidence.Policy
  - Shikumi.Evidence.Report
  - Shikumi.Evidence.Recording
  - Shikumi.Evidence.Driver
requires:
  - CAP-12
  - CAP-33
  - CAP-46
evidence:
  - kind: test
    resource: shikumi-evidence/test/DatasetDigestSpec.hs
    proves: Dataset digests change with examples, provenance, split policy, ordering, schema or redaction policy, and edited or extended envelopes are rejected.
  - kind: test
    resource: shikumi-evidence/test/SplitSpec.hs
    proves: Duplicates and grouped examples cannot cross splits, and hand-edited envelopes that move them are rejected.
  - kind: test
    resource: shikumi-evidence/test/HoldoutIsolationSpec.hs
    proves: No optimization request, proposer request or candidate parameter contains holdout text, and the proposer never sees validation text.
  - kind: test
    resource: shikumi-evidence/test/ConclusionSpec.hs
    proves: A quality gain with a safety, cost, latency or completion violation is Regressed, and insufficient or contaminated evidence is never Improved.
  - kind: test
    resource: shikumi-evidence/test/ReplaySpec.hs
    proves: Replayed recordings reproduce candidate and report digests, missing or surplus outcomes diverge, retries and provider timeouts replay faithfully, and unrecordable calls are refused.
  - kind: test
    resource: shikumi-evidence/test/BindingSpec.hs
    proves: Changing any bound baseline, candidate, dataset, policy or source digest invalidates report binding.
  - kind: test
    resource: shikumi-evidence/test/Uc7Spec.hs
    proves: The checked-in UC-7 fixture yields a held-out improvement and rejects a candidate that costs four times as much.
  - kind: example
    resource: shikumi-jitsurei/app/Evidence.hs
    proves: A runnable replay of the UC-7 fixture verifies bindings and prints Improved and Regressed without a provider.
  - kind: guide
    resource: docs/user/evaluation-and-optimization.md
    proves: Documents the three artifacts, the split rules, the four conclusions and the example command.
---

# Production-evidence optimization and promotion reports

An optimizer can make a program score better, but a promotion decision needs proof
that someone who was not there can check. This capability turns optimization into an
auditable comparison. A trusted job supplies a sealed dataset of production evidence,
a baseline program artifact, an optimizer with a budget and a declared metric policy.
It receives a candidate program artifact and a comparison report whose conclusion is
exactly one of **Improved**, **Regressed**, **Inconclusive** or **Invalid**.

The dataset is split deterministically into training examples the optimizer may
inspect, validation examples that may only rank candidates, and a protected holdout
used once for the final comparison. Records that share a group or an identical input
stay in one split. Human, model and inferred labels and critiques keep their kind all
the way into the reflection prompt, and a redaction policy rewrites prohibited text
before sealing and fails the build if any remains.

The comparison runs baseline and candidate under the same evaluator, examples, routes
and policy. A quality gain that comes with a safety, cost, latency or completion
violation is **Regressed**; contaminated, insufficient or exhausted evidence is never
**Improved**. Cost and latency come from the recorded provider responses, so a replay
of the job's recordings reproduces the candidate and report digests exactly. Every
artifact carries a BLAKE3 content digest, and `verifyReportBinding` checks that a
report is about precisely the baseline, candidate, dataset, policy and source
revisions a verifier holds.

This grows [CAP-33 validated optimizer execution](validated-gepa-execution.md) and
uses [CAP-46 stored critiques for optimizer feedback](stored-optimizer-critiques.md).
Recording reuses [CAP-12 deterministic replay](deterministic-replay.md)'s divergence
semantics.

## Limits

- The package decides the comparison only. It never activates a candidate, holds no
  credential and performs no file access; durable exposure counting and approval
  belong to the caller.
- Evidence jobs run sequentially. Streamed calls and calls that request provider
  evidence cannot be recorded and are refused.
- Promotion-gate measures are pure functions of output and execution evidence. A
  language-model judge cannot be a gate.
- Candidates must keep the baseline template's structure; structure-changing
  candidates are reported Invalid.
- Envelope formats are versioned and experimental. Bumping the cache key version
  makes existing recordings unreplayable by design.
