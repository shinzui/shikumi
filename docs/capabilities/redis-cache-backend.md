---
title: "Redis response-cache backend"
type: Capability
description: "Run shikumi's response-cache effect against Redis with connection lifecycle helpers, optional Redis-side TTL, and best-effort failure behavior."
generated:
  by: codex/gpt-5
  at: "2026-08-30T20:48:38Z"
capabilityId: CAP-9
provider: mori://shinzui/shikumi
status: shipped
stability: experimental
since: "0.1.0.0"
packages:
  - shikumi-cache-redis
interface:
  - Shikumi.Cache.Backend.Redis
requires:
  - CAP-8
evidence:
  - kind: test
    resource: shikumi-cache-redis/test/Main.hs
    proves: A repeated request becomes a Redis hit, closed connections degrade safely, and opt-in SETEX differs from the no-expiry default.
  - kind: guide
    resource: docs/user/caching-tracing-replay.md
    proves: Redis is documented as a swappable interpreter of the same Cache effect.
---

# Redis response-cache backend

This optional package supplies a Redis interpreter for the cache contract in
[CAP-8](content-addressed-response-cache.md). It opens and closes Redis
connections, stores the same versioned `CachedResponse` values, and offers
explicit Redis-side TTL configuration in addition to the shared policy layer.

## Limits

- Redis availability and durability are deployment concerns outside shikumi.
- The default storage command sets no Redis expiry; callers opt into a storage
  TTL with `openRedisCacheWithTTL`.
- Lookup and store failures are best-effort misses/no-ops, so operational
  monitoring must detect a degraded cache hit rate.
