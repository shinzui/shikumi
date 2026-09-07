---
type: Architecture Decision Record
title: Bound recursive sessions at the LLM operation boundary
description: Keep documents and variables private to an invocation and distinguish exact logical subquery admission from optimistic model spending.
docId: ADR-7
status: Accepted
date: 2026-09-07
timestamp: 2026-09-07T04:42:34Z
generated:
  by: process:codex
  at: 2026-09-07T04:42:34Z
---

# Bound recursive sessions at the LLM operation boundary

## Context

Large documents need not fit in an agent's prompt. An agent can inspect named
sources through bounded operations and ask a sub-model about selected excerpts.
The existing CodeInterpreter is stateless, while the Program Embed boundary
already supplies the LLM and ShikumiError effects. We need explicit ownership,
resource bounds and typed completion without arbitrary interpreter execution.

## Decision

The experimental Session and RLM modules in `shikumi-tools` own immutable named
documents and pure invocation-local variables and counters. They grant no file,
process or host-language execution. Each run starts fresh; the store cannot be
shadowed by variables. Search is literal and scan-bounded, and slice positions
count Unicode characters. Serialized observations include their own truncation
metadata in their character allowance. Source slices preserve continuation offsets;
other large values are marked JSON-text prefixes.

All outer and sub-model calls use the existing LLM interpreter. Subqueries have
depth one and execute sequentially. A whole batch reserves logical call slots
before its first dispatch. Over-admission exhausts the run with no batch calls.
Reports count actual logical attempts separately from reservations. Infrastructure
errors propagate through ShikumiError, aborting the invocation and preventing any
remaining batch calls; neither API returns a normal report on this error path.
Slots are never refunded. Interpreter-level transport retries are not new logical
subqueries. The existing dollar budget remains optimistic admission based on
recorded cost, not a strict monetary reservation.

A request ceiling counts system plus user Text characters before every LLM call.
It is not a token, HTTP-byte or provider-envelope limit. Independent bounds cover
context (including names), aggregate serialized stored values and their names,
action UTF-8 bytes, operations, scan size, matches, observations, total retained
observations, subquery prompt characters, and outer iterations. Invalid actions
consume operations. Observation and action history stays bounded; there are no
hidden compaction, extraction or repair calls. The audit retains bounded actions
and observations, including explicit truncation records.

Submit uses the ordinary FromModel and Validatable contracts. Failed submissions
may be corrected within remaining iterations. Exhaustion returns a typed
RLMExhausted SessionLimit and report; the convenience constructor maps that outcome
to the existing BudgetExceeded ShikumiError with the named allowance. No new core
error constructor is required for resource-budget exhaustion.

## Consequences

The runtime needs no subprocess cleanup or global mutable session storage.
Independent concurrent runs cannot share variables or admission counters. Restarting
is an explicit caller decision that can repeat provider work. Returned model text
must still be received before application-level truncation; these bounds do not
promise transport-level allocation limits. Provider output-token settings and
runtime resilience remain interpreter responsibilities.

The API remains experimental. Its acceptance gate is a real scripted Program loop
over a two-megabyte source, concurrent isolation, typed submission and exact batch
admission, covered in `shikumi-tools/test/RLMSpec.hs` and `SessionSpec.hs`. This
establishes bounded mechanics, not quality claims about any live model. Python,
remote interpreters, persistent checkpoints and recursion deeper than one are
outside this decision. See [plan 56](../plans/56-add-bounded-recursive-language-model-sessions.md).
