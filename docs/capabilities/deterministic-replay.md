---
title: "Fail-closed deterministic replay"
type: Capability
description: "Re-run blocking LM programs offline from captured trace responses, rejecting missing requests and conflicting recordings instead of falling through to a live provider."
generated:
  by: codex/gpt-5
  at: "2026-08-30T20:48:38Z"
capabilityId: CAP-12
provider: mori://shinzui/shikumi
status: shipped
stability: experimental
since: "0.1.0.0"
packages:
  - shikumi-trace
interface:
  - Shikumi.Trace.Replay
  - Shikumi.Trace.Store
requires:
  - CAP-8
  - CAP-11
evidence:
  - kind: test
    resource: shikumi-trace/test/Main.hs
    proves: Captured runs replay identical outputs with zero provider calls, missing requests raise ReplayDivergence, and conflicting duplicate keys fail closed.
  - kind: example
    resource: shikumi-jitsurei/app/TraceReplay.hs
    proves: A live-style stub capture is stored and replayed through the public interpreter stack.
---

# Fail-closed deterministic replay

Replay converts the LM-call records in a
[trace](hierarchical-tracing.md) into the same content-addressed request map used
by [CAP-8](content-addressed-response-cache.md), then installs an offline LLM
interpreter. A matching request returns the recorded response without touching a
provider. A missing key raises `ReplayDivergence`, and two different responses
for the same key make index construction fail.

## Limits

- Replay covers blocking completion calls, not transport streams.
- It reproduces provider responses, not arbitrary external effects hidden inside
  an embedded program node.
- Changes to canonical request identity can intentionally invalidate older
  replay keys; the cache key carries its own version namespace.
