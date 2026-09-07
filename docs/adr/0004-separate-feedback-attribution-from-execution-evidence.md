---
type: Architecture Decision Record
title: Separate feedback attribution from execution evidence
description: Preserve indexed failed executions while requiring explicit node attribution and bounded redacted reflection evidence.
docId: ADR-4
status: Accepted
date: 2026-09-07
timestamp: 2026-09-07T02:48:16Z
generated:
  by: process:codex
  at: 2026-09-07T02:48:16Z
---

# Separate feedback attribution from execution evidence

## Context

An outer program score does not establish which predictor caused an error.
Broadcasting a program critique to every predictor misrepresents attribution.
Aborting capture on a malformed output also prevents comparison across a stable
set of dataset positions. Failed and rejected retry invocations are useful for
reflection even though they are unsuitable as bootstrap demonstrations.

## Decision

The optimizer owns example-indexed `EvaluationEvidence` and `FeedbackResult`.
Evidence retains the typed root result, ordered observations, and provider-reported
execution usage. `NodeFeedback` names the example, structural node path, optional
invocation ordinal, critique, and producer provenance. Validate targets against
both the executable program and that example's actual nonopaque observations.
Caller and Model provenance identify producers; neither implies human approval.
LegacyProgram critiques remain program-scoped and cannot assert node attribution.

The evaluator owns `scoreExecution`, a generic checked-error boundary parameterized
by runner, root projection, metric, and failure classifier. Ordinary evaluation
retains its prior failure policy. GEPA scores malformed JSON, missing fields,
schema mismatch, and validation failures by default; its caller can configure the
score or abort, and can explicitly classify infrastructure errors. BudgetExceeded
always escapes GEPA capture. Host exceptions and cancellation are never caught.
Critic failures retain their separate MetricError classification. Invalid feedback
configuration escapes instead of being scored as a candidate failure.

Observed capture runs sequentially and constructs one indexed envelope per input.
It retains original errors and rejected retry lineage. Reflection may use failed
observations, but must label rejection. Missing JSON codecs use rendered fields;
opaque Embed interiors are never invented. Token/cost summaries include only usage
acknowledged by the execution provider, not estimates of failed transport calls.

Reflection chooses deterministically among executed paths with relevant critiques.
Program critique is a separately labeled opt-in field, enabled by the legacy GEPA
wrapper. The legacy FeedbackLog projection stores program critique once at the
root key with a scope label; rich consumers use EvaluationEvidence instead.
The unchanged ReflectIn interface carries bounded local evidence in its feedback
field. Redaction runs before truncation and before any proposer request; returned
raw evidence remains the caller's responsibility. Zero bounds suppress critique
or reflection, negative bounds fail preflight, and truncation uses an in-budget
Unicode marker. The example bound counts invocation samples, including retries.

## Consequences

Legacy callers keep their function signatures and single-predictor optimization.
Multi-node callers must use explicit attribution to claim node-local blame. Raw
feedback/evidence is ephemeral and introduces no trace or parameter migration.
Shared failure machinery avoids a dependency from evaluation to optimization or
trace. This contract does not implement split-aware search, actual critic-call
budget metering, concurrent capture, or lifecycle reports; those remain plan 53.

[Plan 52](../plans/52-capture-failure-aware-node-feedback-for-gepa.md) records the
regressions and integration validation. [ADR-2](0002-keep-capture-codecs-in-templates-and-isolate-observations.md)
continues to govern codec ownership and isolated observation storage.
