---
type: Architecture Decision Record
title: Centralize offline harness and diverse fixtures
description: Own reusable offline LLM interpreters and nontrivial fixture shapes in an internal package below consumer libraries and tests.
docId: ADR-9
status: Accepted
date: 2026-09-07
timestamp: 2026-09-07T22:32:18Z
generated:
  by: process:codex
  at: 2026-09-07T22:32:18Z
---

# Centralize offline harness and diverse fixtures

## Context

The CLI, worked examples and tools tests copied deterministic LLM interpreters and
response builders. Copies drifted as agent tests gained retry injection and
multiple native tool calls. Simple fixtures also hid validation, instruction,
composition and parameter boundary behavior.

## Decision

The internal `shikumi-testing` package owns response builders, responder-driven
and scripted LLM interpreters, counting and error injection, and ready-made effect
stacks. It depends on core `shikumi` and transport/effect libraries, never on
consumer packages such as `shikumi-tools` or `shikumi-trace`. Shared fixtures include
nonempty instructions, fallible output validation, a two-stage program, distinct
temperatures and varied glob patterns. Extend these fixtures instead of copying
them. Consumer suites own behavioral regressions; the harness suite proves the
fixture properties.

`Shikumi.Jitsurei.Stub` remains a compatibility re-export. CLI trace recording and
replay remain CLI-owned. Script exhaustion returns an empty text turn; streaming
returns no chunks; injected completion errors do not consume scripted responses.
Marker responses preserve the existing 18 input tokens, 5 output tokens and 4 ms
latency used by trace assertions.

## Consequences

The harness is not published to Hackage. Published packages may use it only in
test suites, so downstream tarball test builds need a local harness checkout.
Library consumers are internal CLI and example packages. Cache backend tests may
adopt the counting interpreter separately; their existing copies are excluded
from [plan 49](../plans/49-shared-test-harness-and-fixture-diversification.md) to
keep the backend CI work independent.
