---
title: "Validated optimizer execution and lifecycle reports"
type: Capability
description: "Run optimizer candidates under a shared, validated execution budget that admits only real language-model operations, and read back versioned diagnostic reports of what each candidate cost and why it was accepted or rejected."
generated:
  by: claude/opus-5
  at: "2026-09-08T19:15:51Z"
capabilityId: CAP-33
provider: mori://shinzui/shikumi
status: shipped
stability: experimental
since: "0.3.0.0"
packages:
  - shikumi-optimize
interface:
  - Shikumi.Optimize.Execution
  - Shikumi.Optimize.Report
requires:
  - CAP-16
evidence:
  - kind: test
    resource: shikumi-optimize/test/ExecutionSpec.hs
    proves: Only admitted language-model operations are counted against the budget, bounded candidate execution stops at the ceiling, and interrupted candidates are marked unscored rather than scored zero.
  - kind: test
    resource: shikumi-optimize/test/GepaSpec.hs
    proves: GEPA drives candidates through the shared execution path and emits lifecycle events for accepted and rejected candidates.
  - kind: example
    resource: shikumi-jitsurei/app/GepaObjectives.hs
    proves: A runnable optimization selects a named objective and prints the resulting lifecycle report.
  - kind: guide
    resource: docs/user/evaluation-and-optimization.md
    proves: Documents named objective selection, the operation-admission rule, and how to read a lifecycle report.
---

# Validated optimizer execution and lifecycle reports

Optimization budgets are only meaningful if what they count is well defined.
This capability factors candidate execution and accounting out of any particular
mutation strategy: candidates run through one shared path that admits only
genuine language-model operations against the budget, so cached hits and
bookkeeping do not silently consume it, and a ceiling actually bounds provider
spend.

Failure handling is explicit. A candidate interrupted before it finished is
recorded as **unscored** rather than scored zero — the distinction matters,
because a zero is evidence that a candidate is bad while an interruption is
evidence of nothing, and conflating them teaches the optimizer the wrong lesson.

Alongside execution, versioned lifecycle reports record what happened: which
candidates were proposed, admitted, accepted, or rejected, what each consumed,
and optional candidate identity metadata. Objectives are selected by name rather
than by position.

Reports are diagnostic metadata only. They carry **no prompts, no examples, and
no executable closures**, so a report can be logged or shipped to a dashboard
without carrying training data with it.

This is growth of
[CAP-16 budgeted program optimization](budgeted-program-optimization.md), whose
budget semantics it makes precise.

## Limits

- Diagnostics describe the search, not the resulting program. A report will not
  tell you what a winning candidate's prompt says.
- Admission counts language-model operations; wall-clock time and local compute
  are not budgeted.
- Report format is versioned and experimental; fields may move before 1.0.
- Legacy entry points remain supported, but results produced by an interrupted
  legacy run are unscored, not zero.
