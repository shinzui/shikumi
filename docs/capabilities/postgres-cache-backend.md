---
title: "PostgreSQL response-cache backend"
type: Capability
description: "Run shikumi's response-cache effect against PostgreSQL with table initialization, connection lifecycle, and best-effort lookup and storage."
generated:
  by: codex/gpt-5
  at: "2026-08-30T20:48:38Z"
capabilityId: CAP-10
provider: mori://shinzui/shikumi
status: shipped
stability: experimental
since: "0.1.0.0"
packages:
  - shikumi-cache-postgres
interface:
  - Shikumi.Cache.Backend.Postgres
requires:
  - CAP-8
evidence:
  - kind: test
    resource: shikumi-cache-postgres/test/Main.hs
    proves: An ephemeral PostgreSQL instance initializes storage, memoizes a repeated request, and degrades safely after the connection is released.
  - kind: guide
    resource: docs/user/caching-tracing-replay.md
    proves: PostgreSQL is documented as a swappable interpreter of the same Cache effect.
---

# PostgreSQL response-cache backend

This optional package supplies a Hasql-backed PostgreSQL interpreter for the
cache contract in [CAP-8](content-addressed-response-cache.md). It owns table
initialization plus lookup, store, and connection cleanup helpers and preserves
the core cache's versioned key and response representation.

## Limits

- Schema placement, database provisioning, retention, replication, and backup
  remain deployment responsibilities.
- Lookup and store failures degrade to misses/no-ops. A closed connection does
  not take down model execution, but it also does not make cache degradation
  observable without surrounding metrics.
