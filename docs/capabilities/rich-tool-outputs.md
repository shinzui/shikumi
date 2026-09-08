---
title: "Rich tool outputs and runtime tool registration"
type: Capability
description: "Return structured content and extension blocks from a tool alongside its text projection, and register tools whose argument schema is only known at runtime."
generated:
  by: claude/opus-5
  at: "2026-09-08T19:15:51Z"
capabilityId: CAP-28
provider: mori://shinzui/shikumi
status: shipped
stability: experimental
since: "0.4.0.0"
packages:
  - shikumi-tools
interface:
  - Shikumi.Tool.Output
  - Shikumi.Tool
requires:
  - CAP-17
evidence:
  - kind: test
    resource: shikumi-tools/test/ToolOutputSpec.hs
    proves: Structured content and extension blocks survive dispatch and project to the exact text a provider sees, with the text projection unchanged for text-only outputs.
  - kind: test
    resource: shikumi-tools/test/ResponsesIntegrationSpec.hs
    proves: Runtime-schema tools built with mkDynTool register in the same registry as typed tools and dispatch through the same name lookup and error surface against released provider wire formats.
  - kind: guide
    resource: docs/user/resumable-react-sessions.md
    proves: Documents mkDynTool's runtime name, description, schema and body, and that runToolCallOutput preserves structuredContent and extensionBlocks where runToolCall projects to text.
---

# Rich tool outputs and runtime tool registration

Two related additions to the tool surface.

`ToolOutput` lets a handler return structured content and extension blocks in
addition to text. The local result is lossless — a caller that wants the
structure gets the structure — while `renderToolOutput` and
`toolOutputMessage` define exactly one text projection for the model boundary.
Existing text-only tools keep their previous rendering, so the projection is
backwards compatible in the way that matters: the bytes the provider sees do not
move.

`mkDynTool` registers a tool whose argument schema is a runtime `Value` rather
than a Haskell type. This is what a consumer needs when tools arrive from
configuration, from an MCP-style server, or from another process. Dynamic tools
share the registry, the name lookup, and the structured `ToolError` surface with
typed tools, so an agent driving the registry cannot tell them apart.

This is growth of [CAP-17 typed tool contracts and registry](typed-tools.md).

## Limits

- `SomeTool` is exported with its constructors and gained `DynTool` in this
  release; exhaustive matches written against an earlier version must handle it.
- A dynamic tool trades the typed argument contract for runtime flexibility. Its
  schema is not checked against a Haskell type, so argument validity is only as
  good as the supplied schema.
- Rich output is lossless locally, not at the model boundary. The provider still
  receives a text projection.
- The registry validates names, schemas, and arguments; it does not make a
  handler's side effects safe or authorized.
