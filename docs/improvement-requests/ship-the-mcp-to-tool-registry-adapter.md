---
type: Improvement Request
title: Ship the MCP-to-ToolRegistry adapter
description: >-
  Implement and release Shikumi's planned dynamic-tool adapter so Baikai MCP tools enter the same
  bounded ToolRegistry and ReAct dispatch path as native tools.
timestamp: 2026-07-30T14:36:35Z
generated:
  by: human:nadeem
  at: "2026-07-30T14:36:35Z"
requestId: IR-1
status: proposed
origin: mori://shinzui/shikigami
---

# Improvement Request: Ship the MCP-to-ToolRegistry Adapter

## Status

Proposed. This is the Shikumi-owned blocker for Shikigami plan 12 runtime milestones 3–5.

## Context

Shikumi plan 30 defines the C5 adapter, but current released source contains no MCP registry
adapter. MCP input schemas arrive at runtime, so Shikigami cannot truthfully coerce them into the
existing statically typed `Tool i o` representation or maintain a downstream fork of the registry.

## Requested Change

Implement plan 30's dynamic-tool arm and public MCP adapter against the released Baikai MCP
contract. Preserve native server tool names for calls while exposing collision-safe
`mcp__<server>__<tool>` registry names. Keep tool-result errors model-visible and protocol/transport
failures in Shikumi's infrastructure error channel. Support idempotent refresh when a server's tool
list changes.

## Acceptance

1. A hermetic two-tool stub registers two prefixed tools and a scripted ReAct loop calls one.
2. Runtime JSON schema and argument values are passed faithfully without invented Haskell types.
3. Duplicate/colliding names, result errors, transport failures, and list refresh have deterministic
   tests.
4. Existing typed tools and registry behavior remain source/behavior compatible.
5. The adapter ships in a tagged release bounded to the released Baikai MCP package.

## Requested Deliverables

- Public dynamic-tool and MCP adapter modules.
- Hermetic registry/ReAct tests and documentation.
- Tagged release.
