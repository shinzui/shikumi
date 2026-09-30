---
type: Architecture Decision Record
title: Separate schema enforcement from tool-calling capability
description: Derive native-schema routing from Baikai's declared structured-output support while keeping provider-native tool calling on its own first-party table.
docId: ADR-14
status: Accepted
date: 2026-09-30
timestamp: 2026-09-30T17:00:00Z
generated:
  by: agent:anthropic/claude-opus-5-5
  at: 2026-09-30T17:00:00Z
---

# Separate schema enforcement from tool-calling capability

## Context

`Shikumi.Adapter.capabilityFor` chooses between the native-schema adapter and the
marker-prompt fallback. It used to be a fixed `(provider, api)` table. ReAct also reused
it to choose provider-native tool calling. That reuse was sound only while every
schema-native transport also executed tools. Baikai's CLI providers (`claude -p
--json-schema`, `codex exec --output-schema`) now enforce a schema but still drop
`Context.tools`. Baikai declares schema support per transport tag through
`declaredStructuredOutput`. It forwards a schema to any host that speaks a first-party wire
format, but it cannot know whether a third-party host enforces it.

## Decision

`capabilityFor` is a schema-enforcement check only. It returns `NativeSchema` when Baikai
declares `NativeJsonSchema` for the model's `api` and either the `api` is a CLI tag
(`AnthropicMessagesCli`, `OpenAICompletionsCli`) or the `(provider, api)` pair is a
first-party HTTP host: `openai` over Chat Completions or Responses, or `anthropic` over
Messages. A CLI tag is always served by Baikai's own provider, so its declaration is
authoritative. Third-party hosts over a first-party wire format and `Custom` transports use
the fallback. Shikumi does not consult a registry's `ApiProvider.structuredOutput`, because
`capabilityFor` stays a pure function of `Model`.

Provider-native tool calling is a separate capability. `Shikumi.Agent.ReAct` owns a private
first-party table for it and never reuses `capabilityFor`.

The fallback guide adds a compact `JSON shape:` line for object and array output fields.
Scalar fields render exactly as before, so scalar-only prompts and their cache keys stay
stable.

## Consequences

Programs on subscription CLIs get enforced schemas, and lists of records decode. Shikumi
requires the Baikai cohort that forwards schemas to the CLIs (`baikai >=0.7.2.0`,
`baikai-claude` and `baikai-openai >=0.7.1.0`). An older provider package would accept the
native prompt, ignore the schema, and lose the marker fallback. CLI cache entries created
before this change miss once. Adding a new schema-native transport means changing Baikai's
declaration and, for an HTTP host, this table. Enabling native tools for a transport is a
separate ReAct change. Enforcement for third-party or `Custom` hosts remains follow-up work
that needs registry-aware routing.

[Plan 67](../plans/67-enforce-typed-output-schemas-on-cli-providers.md) records the tests and
the release. [ADR-10](0010-use-bounded-schema-guided-xml-fragments.md) still governs the
opt-in XML adapters, which automatic routing never selects.
