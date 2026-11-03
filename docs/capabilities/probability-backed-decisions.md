---
title: "Probability-backed typed decisions"
type: Capability
description: "Declare closed Boolean, choice and ordered-score outputs, retrieve probability evidence and derive typed answers locally on judgment-only or generative models."
generated:
  by: openai/codex
  at: "2026-11-03T01:52:53Z"
capabilityId: CAP-39
provider: mori://shinzui/shikumi
status: shipped
stability: experimental
since: "0.5.0.0"
packages:
  - shikumi
interface:
  - Shikumi.Decision
  - Shikumi.Decision.Runtime
  - Shikumi.Adapter
  - Shikumi.Routing
requires:
  - CAP-1
  - CAP-3
evidence:
  - kind: test
    resource: shikumi-testing/test/DecisionSpec.hs
    proves: Closed schemas, typed state, judgment routing, local derivation and preflight refusals agree with the upstream judgment compiler.
  - kind: test
    resource: shikumi-testing/test/DecisionEvidenceSpec.hs
    proves: Native JSON and marker evidence yield the same rich decisions with strict validation and refusal before streaming.
---

# Probability-backed typed decisions

`NoulWith`/`Noul`, `Choice` and `Score` describe closed decisions with
probability evidence. Answers are derived locally, rather than copied from the
provider's selected value. Judgment-only models receive typed input and demo
state; generative models receive closed evidence schemas through native JSON or
marker prompts. Generative outputs can mix decisions and free-form fields.

Structured prompt methods preserve primitive JSON types and demonstration
evidence. Transport implementations remain owned by `mori://shinzui/baikai`.

Builds on [CAP-1 typed signatures](typed-signatures-and-schemas.md), [CAP-3 structured-output adapters](structured-output-adapters.md).

## Limits

- Decisions support blocking prediction only; streaming refuses before dispatch.
- Judgment-only models refuse free-form output fields and generation controls.
- Score domains have 2 to 10 levels. Nested decision containers, recursive
  sessions and ReAct decision submissions are outside this provision.
- Probability evidence is range-checked but is not a guarantee of calibration;
  distributions need not sum to one.
