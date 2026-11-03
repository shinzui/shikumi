---
title: "Acknowledged provider attempt evidence"
type: Capability
description: "Handle exact provider-built evidence before retries, classified failures or successful return through an effectful observer."
generated:
  by: codex-cli/gpt-6.1-sol
  at: "2026-11-03T04:46:53Z"
capabilityId: CAP-43
provider: mori://shinzui/shikumi
status: shipped
stability: experimental
since: "0.5.1.0"
packages:
  - shikumi
interface:
  - Shikumi.LLM.Evidence
  - Shikumi.LLM
  - Shikumi.LLM.Defaults
requires:
  - CAP-23
  - CAP-24
evidence:
  - kind: test
    resource: shikumi/test/AttemptEvidenceSpec.hs
    proves: Both operations acknowledge records in order with truthful retry provenance, fail closed on observer errors and isolate concurrent calls.
---

# Acknowledged provider attempt evidence

Install `runLLMResilientWithEvidence` or `runLLMWithEvidence`. Request evidence
separately through options, defaults or `withEvidenceRuns`. Normal observer return
acknowledges the receipt. Each retry retains its logical run ID, increments the
caller's base attempt, and supersedes the last provider-built call ID.

Settlement order is budget charge, billing, evidence acknowledgement, then failure
or return. Typed observer failures become `EvidenceObserverFailed` exceptions, so
program and transport retry cannot redispatch. Other exceptions propagate.

## Limits

Observers must be thread-safe. No cancellation record exists on the current
collection path; upstream work is tracked at
`mori://shinzui/baikai/okf/improvement-requests/concepts/IR-13`.
No receipt is fabricated for budget refusals, rate-limit waiters, cache or replay.
A strict pre-dispatch refusal can deliver a real receipt without HTTP. Best-effort
evidence can be absent. Full error messages can contain provider response text;
AttemptReceipt has no JSON instances, and applications own persistence/redaction.

This extends [CAP-23](transport-billing-observation.md), [CAP-24](scoped-request-defaults.md).
