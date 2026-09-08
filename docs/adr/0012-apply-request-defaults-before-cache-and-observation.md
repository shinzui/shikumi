---
type: Architecture Decision Record
title: Apply request defaults before cache and observation
description: Fill a finite set of invocation-scoped request preferences after routing and bypass memoization whenever evidence is requested.
docId: ADR-12
status: Accepted
date: 2026-09-08
timestamp: 2026-09-08T18:09:43Z
generated:
  by: process:codex
  at: 2026-09-08T18:09:43Z
---

# Apply request defaults before cache and observation

## Context

Typed programs create additional calls for agents, summaries, repairs and recursive
subqueries. Copying preferences into each constructor risks inconsistent behavior.
Cache keys and observers must see the same effective options as transport.
Requested settings cannot establish what a provider actually executed.

## Decision

`Shikumi.LLM.Defaults` owns only optional thinking level, speed, output-token ceiling
and a complete evidence request. It fills missing fields on both LLM operations.
Explicit call settings win, then the innermost default scope, then outer scopes.
Empty defaults are identity. The layer validates a configured zero token ceiling
with the existing terminal `ValidationFailure`, before executing the scoped action.
The pure merge does not validate; it is intended for validated configuration.

Models, temperatures, schemas, tool policy, authentication and private continuation
metadata are excluded from this vocabulary. Defaults never introduce calls or
mutable global configuration and are not serialized in Program or Params.
Providers retain ownership of unsupported-option translation and evidence strength.

Request execution order is routing and continuation validation, default filling,
cache/trace observation, final continuation validation and metadata stripping, then
transport. In composition notation use base interpreter composed with cache/trace,
then `withRequestDefaults`, then `routeLLM`; the rightmost wrapper handles the call
first. Trace can surround cache to record logical cache hits. Transport-attempt
billing must observe below cache. Defaults do not change routing's existing model
replacement policy; a recursive sub-model remains intact when defaults are used
without the ambient model router.

Any evidence request bypasses memoizer reads and writes, including warm entries.
Cached responses omit evidence and cannot prove a new provider crossing. Streams
continue to bypass caching. Ordinary calls share entries according to effective
options, regardless of whether those options were explicit or defaulted.

## Consequences

Wrapper order is part of the public runtime contract. A misplaced cache can hide
changed defaults; consumer regressions retain this counterexample. Callers must
compose the layers as shown in `shikumi-jitsurei/app/RequestDefaults.hs`.
The internal testing harness owns a reusable request-capture wrapper. Core, tools
and cache suites verify precedence, streaming, summaries, subqueries, concurrent
isolation and evidence bypass. No test equates requested preferences with observed
model execution. Existing replay remains an explicit caller-selected interpreter;
this decision changes memoization, not replay into a live evidence source.
