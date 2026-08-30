---
title: "Content-addressed response caching"
type: Capability
description: "Interpose a provider-neutral cache over blocking LM completion calls using versioned canonical request keys, TTL policy, and in-memory or SQLite storage."
generated:
  by: codex/gpt-5
  at: "2026-08-30T20:48:38Z"
capabilityId: CAP-8
provider: mori://shinzui/shikumi
status: shipped
stability: experimental
since: "0.1.0.0"
packages:
  - shikumi-cache
interface:
  - Shikumi.Cache
  - Shikumi.Cache.Key
  - Shikumi.Cache.Backend.Memory
  - Shikumi.Cache.Backend.SQLite
requires:
  - CAP-4
evidence:
  - kind: test
    resource: shikumi-cache/test/Main.hs
    proves: Canonical keys are deterministic and endpoint-complete, memory and SQLite stores round-trip, repeated calls hit, TTL expires, and backend defects degrade safely.
  - kind: guide
    resource: docs/user/caching-tracing-replay.md
    proves: The Cache effect, cachedLLM policy, key versioning, and backend interpreter stack are documented for consumers.
---

# Content-addressed response caching

`shikumi-cache` interposes on the `LLM` effect below a program and memoizes
blocking completions. The key hashes a canonical request including model,
endpoint identity, headers, provider compatibility settings, context, and
options while stripping message-construction timestamps. A version namespace
makes deliberate key-contract changes invalidate old entries.

The package ships a concurrent in-memory backend and a persistent SQLite
backend. `CacheConfig` applies shared entry-TTL policy, and persistent lookup or
store failures can degrade to misses/no-ops so cache infrastructure does not
take down the LM path.

It interposes on the runtime from [CAP-4](resilient-runtime-routing.md).

## Limits

- Only blocking completion calls are cached; transport streams pass through.
- In-band provider error responses are not stored.
- Cached responses intentionally discard original model-call evidence because a
  cache hit did not cross the provider boundary.
- The SQLite backend is process-persistent, but callers still own database-file
  placement and lifecycle.
