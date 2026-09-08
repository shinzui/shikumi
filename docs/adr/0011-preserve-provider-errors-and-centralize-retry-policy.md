---
type: Architecture Decision Record
title: Preserve provider errors and centralize retry policy
description: Preserve structured transport failures and share terminal refusal policy across blocking and streaming calls.
docId: ADR-11
status: Accepted
date: 2026-09-08
timestamp: 2026-09-08T17:13:08Z
generated:
  by: process:codex
  at: 2026-09-08T17:13:08Z
---

# Preserve provider errors and centralize retry policy

## Context

Flattening transport failures into retryable text discarded refusal metadata and
made permanent failures consume every attempt. Released transport stream terminals
already carry the same structured error as blocking responses.

## Decision

`Shikumi.Error` owns the mapping and retry boundary. Preserve `BaikaiError` in
`ProviderError`, except for the established decode, invalid-request and context
mappings. Preserve refusal categories exactly, including unknown strings and
absence. Baikai owns transport classification; `isTransient` delegates typed
provider errors to its retry predicate, which admits only rate limits and transient
failures. Refusals, authentication, unavailable providers, unclassified process
failures and unknown errors are terminal. Never classify from message prose.

Both LLM interpreters map structured stream terminals through the blocking error
mapping. Legacy caller-created `ProviderFailure` and malformed third-party stream
terminals without errorInfo retain text-based, retryable behavior. A failure's
partial response never becomes successful output. Charge reported attempt costs
before raising; errors do not hold aggregate billing. Host exceptions and
cancellation propagate unchanged. The shared renderer prints category, optional
process exit and Baikai's safe-to-log message, without dumping the full record.

## Consequences

Consumers can inspect refusal evidence without parsing diagnostics. Exhaustive
public error matches need a new branch, requiring a PVP major release. Evaluator
failure policies and GEPA infrastructure-abort defaults retain their semantics;
tool observations use the shared renderer. Later billing observers consume this
error contract without introducing another classifier. Legacy unclassified errors
remain potentially retryable until callers adopt typed failures.

[Plan 58](../plans/58-preserve-provider-refusal-classification-and-retry-semantics.md)
contains the category matrix, transport attempt and budget regressions.
[ADR-4](0004-separate-feedback-attribution-from-execution-evidence.md) continues to
govern original evidence and cancellation propagation.
