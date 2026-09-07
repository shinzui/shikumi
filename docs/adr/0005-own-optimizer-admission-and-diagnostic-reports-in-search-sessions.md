---
type: Architecture Decision Record
title: Own optimizer admission and diagnostic reports in search sessions
description: Separate shared operation admission and candidate lifecycle from search algorithms and validation objective selection.
docId: ADR-5
status: Accepted
date: 2026-09-07
timestamp: 2026-09-07T03:49:40Z
generated:
  by: process:codex
  at: 2026-09-07T03:49:40Z
---

# Own optimizer admission and diagnostic reports in search sessions

## Context

Predicted node counts cannot enforce a hard ceiling around retries, critics, or
opaque embedded programs. Training feedback and selection evidence also serve
different purposes. A shared driver is needed by both parameter optimizers and
future structure search, without introducing a dependency on GEPA mutation logic.

## Decision

`Shikumi.Optimize.Execution` owns an explicit `SearchSession es`. Configured
optimizers quantify over the same effect row as their session. `runSearchSession`
returns the original typed error alongside a diagnostic report; `optimizeWith`
propagates infrastructure errors, with terminal metadata available to the observer.
Opaque legacy adapters receive run-level accounting and explicitly unavailable
candidate detail. Compiled parameter serialization remains independent of reports.

Atomically admit every Shikumi Complete/Stream before dispatch. Admitted failures
consume a slot. A session latch distinguishes its own admission stop from ordinary
caller BudgetExceeded errors, and prevents a caught denial from making a partial
candidate eligible. An exception-safe dispatch semaphore is independent of the
bounded candidate scheduler, so a recursive evaluator never holds a permit while
waiting for nested calls. Candidate examples run sequentially in isolated usage
and latency collectors. Provider transport retries and dollars are different units.

Reserve opaque candidate identities before scheduling. Identities belong to one
session and execute once. Candidate and selection folds use creation order, even
when workers finish in reverse order. A seed determines parent scheduling, not live
model responses or which concurrent worker reaches the final dispatch slot first.
Serializing every operation across opaque callbacks would prevent barrier-dependent
workers from making progress, so physical dispatch order is not promised.

Reports own versioned metadata, declared objective policy, actual admission counts,
separate predicted work, indexed scalar scores, objective aggregates, frontier,
selection reason and terminal candidate states. Events contain no raw requests,
datasets, tool payloads or exception messages. CandidateEnded carries an explicit
completed, failed or incomplete state. Synchronous observer exceptions are counted
without changing scores; cancellation propagates with structured cleanup. Observers
are trusted callbacks and must not indefinitely block.

GEPA reflects only on bounded training evidence. A minibatch screens execution;
it does not reject a candidate solely for a training-score regression, because
validation may rank it higher. Every validation position is required for eligibility.
Explicit empty validation is invalid; omission is labeled training-as-validation.
Caller callbacks are trusted code, not isolated by a security sandbox.

Named objectives declare units, direction, deterministic aggregation, missing-value
policy and optional bounds. Nonfinite/missing-required metrics fail candidates;
bounds exclude them before Pareto selection. Primary objective, ordered ties and
creation order choose one frontier member. Unscored baselines and partial validation
are never represented as completed winners. A budget stop retains an eligible
completed winner, otherwise the original student.

## Consequences

New search algorithms reuse admission, evaluation and reports without importing
GEPA. Generation width one preserves adaptive single-child scheduling; wider
search uses a frontier snapshot between generations. Reports remain diagnostic:
they do not authorize promotion, seal datasets, or evaluate a protected final holdout.

[Plan 53](../plans/53-add-validated-multi-objective-gepa-execution-and-lifecycle-events.md)
records offline objective, split, counter, concurrency, lifecycle and compatibility
regressions. [ADR-4](0004-separate-feedback-attribution-from-execution-evidence.md)
continues to govern execution evidence, feedback attribution and failure policy.
