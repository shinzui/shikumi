---
type: Architecture Decision Record
title: Separate transport billing from logical usage
description: Observe bounded run-local transport attempts independently of logical call usage and preserve billing uncertainty without inventing attribution.
docId: ADR-13
status: Accepted
date: 2026-09-08
timestamp: 2026-09-08T18:32:33Z
generated:
  by: process:codex
  at: 2026-09-08T18:32:33Z
---

# Separate transport billing from logical usage

## Context

Evaluation and program tracing see returned logical calls, including cache hits.
They cannot observe intermediate runtime retries or terminal failures raised before
a response returns. Summing that view together with transport attempts would count
some spending twice. Provider usage can be incomplete and calculated cost can be
estimated, even when its numeric component is zero.

## Decision

Core owns `Shikumi.LLM.Observation`. Bare and resilient runners observe each completed
transport attempt after effective request configuration and budget charging, before
raising the classified error. Cache hits have no attempt. Call identifiers are
process-local invocation identities; attempt ordinals are one-based. Timing is the
actual transport interval, excluding admission and backoff. Cancellation has no
synthetic terminal. Callback exceptions propagate outside provider classification
and are never retried. Observers never charge budgets.

Observations retain requested provider/model identity, separately observed model
identity, terminal error classification, and optional full usage. They omit raw
error text, prompts, outputs, credentials and opaque replay. The application still
receives the original typed runtime error. An unannotated additive zero, including
the synthetic usage on a thrown transport error, is absent accounting. A reported
zero with availability or cost basis remains an observation. Unknown counts include
missing, partial, inconsistent and legacy unannotated usage.

A fresh collector belongs to one run. Atomic accumulation preserves exact Rational
amounts and the dependency's union of cost sources, estimate reasons and usage
facts. Detail retention defaults to zero and is explicitly bounded when enabled;
counts and totals continue after truncation. This bounds the number of retained
attempts, not arbitrary strings or distinct provider facts. `UsageRecord` has a
local decoder and an exact rational cost supplement, avoiding competing orphan
instances and nonterminating-decimal loss. Provider pricing remains owned by
`mori://shinzui/baikai`.

Reports explicitly attach whole-run transport summaries alongside logical returned
usage. Neither view is added to the other. GEPA's existing `UsageTotals` projection
inherits logical quality without introducing node attribution. Trace format 3 adds
optional run billing and span quality; formats 1 and 2 remain readable. Billing
attempts have no cache keys or replay responses. Exported logical calls and
transport attempts have distinct accounting scopes; summary spans carry counts,
not another numeric spending series. Attempts carry call/ordinal correlation and
no invented structural program parent. Observed model identity comes only from
evidence, never from the response's echoed request model. All cache hits clear
provider evidence, including the memory backend.

## Consequences

A collector remains readable when an evaluation aborts. Its bounded detail may be
insufficient to reconstruct all attempts; aggregates explicitly report truncation.
Applications select the appropriate accounting scope in telemetry queries. Exact
amounts survive local persistence; OTel numeric attributes remain floating point.
Whole-run collection is concurrency-safe, while the existing sequential trace
builder still requires sequential capture and a real enclosing program span.
Public record additions require a PVP major review when publishing packages.
[Plan 61](../plans/61-expose-billing-quality-and-failed-call-usage-in-reports-and-traces.md)
contains acceptance evidence and composition examples.
