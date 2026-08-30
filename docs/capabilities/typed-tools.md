---
title: "Typed tool contracts and registry"
type: Capability
description: "Derive provider-visible JSON argument contracts for typed Haskell tools and dispatch calls totally through a heterogeneous registry with structured errors."
generated:
  by: codex/gpt-5
  at: "2026-08-30T20:48:38Z"
capabilityId: CAP-17
provider: mori://shinzui/shikumi
status: shipped
stability: experimental
since: "0.1.0.0"
packages:
  - shikumi-tools
interface:
  - Shikumi.Tool
requires:
  - CAP-1
evidence:
  - kind: test
    resource: shikumi-tools/test/ToolSpec.hs
    proves: Typed tools publish schemas, decode and validate arguments, dispatch through the registry, and return structured errors.
  - kind: test
    resource: shikumi-tools/test/SchemaSpec.hs
    proves: Public request types derive the exact JSON argument schemas exposed to providers.
  - kind: guide
    resource: docs/user/tools-and-agents.md
    proves: Tool construction, wire conversion, registry assembly, and total dispatch are documented for consumers.
---

# Typed tool contracts and registry

A `Tool a` pairs a name and description with a typed request and a handler.
Shikumi derives the provider-visible JSON argument schema from that request,
decodes and validates incoming calls, and returns either an observation or a
structured `ToolError`. `SomeTool` and `ToolRegistry` make differently typed
tools available through one total name-lookup and dispatch surface.

The argument contract reuses the schema and validation capability in
[CAP-1](typed-signatures-and-schemas.md), so tool inputs fail with the same
located errors as predicted outputs.

## Limits

- The registry validates tool names and arguments; it does not make a handler's
  side effects safe or authorized.
- Observations are text at the model boundary even when the request is typed.
- Provider-native tool calling depends on the selected model transport. The
  same registry can instead be rendered through a prompt protocol by an agent.
