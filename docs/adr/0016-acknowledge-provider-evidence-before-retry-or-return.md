---
type: Architecture Decision Record
title: Acknowledge provider evidence before retry or return
description: Deliver original attempt evidence through a separate effectful acknowledgement boundary before retry, failure or successful return.
docId: ADR-16
status: Accepted
date: 2026-11-03
timestamp: 2026-11-03T04:40:49Z
generated:
  by: agent:openai/gpt-6.1-sol
  at: 2026-11-03T04:40:49Z
---

# Acknowledge provider evidence before retry or return

## Context

An application above the resilient interpreter sees only the final response.
Intermediate failed attempts disappear before it can durably handle their
provider-built evidence. Billing observations intentionally exclude full records
and provider error text, so they cannot serve that persistence boundary.

## Decision

Expose additive bare and resilient runners with an effectful EvidenceObserver.
Keep LLMConfig and existing runner signatures unchanged. Observers acknowledge
by returning normally; their effects are installed outside the interpreter.
They do not request evidence. Options, defaultEvidence or withEvidenceRuns do.
withEvidenceRuns mints a run ID per logical operation above the retry loop;
explicit requests win. Each retry retains that run and increments the caller's
base attempt, superseding the last actual record's Baikai callId. This state is
local to a logical call, including concurrent programs.

Settle attempts in order: budget charging, billing observation, evidence
acknowledgement, then provider error propagation or return. Convert typed
ShikumiError failures at the evidence observer boundary into the exception
EvidenceObserverFailed. This prevents both transport retry and Program Retry
from redispatching on persistence failure. Host exceptions propagate unchanged.
A thrown transport error under EvidenceRequired fails closed with a stable
classification and no provider text, because that path cannot supply a record.

Deliver only exact provider-built records, including strict pre-dispatch refusals.
Receipts do not prove HTTP dispatch. Budget refusals, rate-limit waiters, cache
hits and replay create no receipt. Cancellation currently has no record on the
Baikai effectful collection path; do not synthesize one. The upstream exposure
request is `mori://shinzui/baikai/okf/improvement-requests/concepts/IR-13`.

## Consequences

Applications control persistence and redaction. AttemptReceipt has no JSON
instances: ModelCallEvidence error messages can include provider response text.
Process-local logicalCallId correlates billing; the enclosed Baikai callId is
the durable attempt identity. Concurrent observers must be thread-safe, and
worker-local State changes do not propagate to a parent. Billing privacy stays
as specified by [ADR-13](0013-separate-transport-billing-from-logical-usage.md).

[Plan 68](../plans/68-support-streamed-judgment-programs-with-typed-result-parity.md)
and shikumi/test/AttemptEvidenceSpec.hs carry the acceptance matrix.
