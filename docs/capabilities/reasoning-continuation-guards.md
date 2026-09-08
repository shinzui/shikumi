---
title: "Reasoning continuation guards"
type: Capability
description: "Reject resumed language-model calls whose reasoning prefix or request origin does not match the session being continued, before the request reaches a cache or a provider."
generated:
  by: claude/opus-5
  at: "2026-09-08T19:15:51Z"
capabilityId: CAP-25
provider: mori://shinzui/shikumi
status: shipped
stability: experimental
since: "0.4.0.0"
packages:
  - shikumi
interface:
  - Shikumi.LLM.Continuation
requires:
  - CAP-4
evidence:
  - kind: test
    resource: shikumi/test/ContinuationSpec.hs
    proves: Origin and prefix guards accept a matching continuation and reject a mismatched one, and the check runs before cache lookup and before transport.
  - kind: guide
    resource: docs/adr/0009-centralize-offline-harness-and-diverse-fixtures.md
    proves: Records the shared offline harness the continuation checks are exercised under.
---

# Reasoning continuation guards

Providers that carry opaque reasoning state across turns make resumption
dangerous in a specific way: a checkpoint captured against one model, prompt
prefix, or request origin is not valid to continue against another, and the
failure is silent — the provider accepts the call and returns plausible output
derived from mismatched state.

`Shikumi.LLM.Continuation` supplies pure checks for request origin and prompt
prefix that routing, memoization, and transport all share. A continuation that
does not match is rejected as a typed error *before* a cache is consulted and
before any provider call is made, so a mismatch can neither be served from cache
nor billed.

Because the checks are pure and shared, the same rule governs every path that
can resume a call rather than each layer reimplementing it: the guard is part of
the runtime described by
[CAP-4 ambient routing and resilient runtime policies](resilient-runtime-routing.md),
so it applies whether a call is issued directly, through a cache, or by an
agent. This is what makes
the resumable agent sessions in
[CAP-29 resumable ReAct sessions with versioned checkpoints](resumable-react-sessions.md)
safe to restore.

## Limits

- Request identity is a structural check, not provider attestation. It proves
  the request matches the session, not that the provider's stored state is
  intact.
- No credentials are persisted or compared.
- The guard rejects mismatches; it does not repair them. Recovering a diverged
  session means restarting or compacting it, not continuing it.
