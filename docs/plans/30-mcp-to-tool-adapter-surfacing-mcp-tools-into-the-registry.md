---
id: 30
slug: mcp-to-tool-adapter-surfacing-mcp-tools-into-the-registry
title: "MCP-to-Tool adapter surfacing MCP tools into the registry"
kind: exec-plan
created_at: 2026-06-27T17:57:56Z
intention: "intention_01kw53nf6hez4va3gyhwbh03zv"
master_plan: "mori://shinzui/baikai/masterplans/6-mcp-support-across-the-agent-stack"
---

# MCP-to-Tool adapter surfacing MCP tools into the registry


This ExecPlan is a living document. Maintain implementation evidence and distill durable decisions into ADRs before completion.

## Purpose / Big Picture


A caller with a live MCP connection will discover remote tools, register them beside typed Haskell tools, and let a ReAct agent invoke them. MCP means Model Context Protocol, the wire protocol through which a tool server advertises schemas and accepts JSON calls. Successful text, structured JSON, mixed content and model-visible errors will survive adaptation. Replacing a server's tool list will never remove another server's tools or silently overwrite a local tool.

This remains child C5 of `mori://shinzui/baikai/masterplans/6-mcp-support-across-the-agent-stack`, with its existing intention. `docs/masterplans/10-dspy-informed-optimizer-and-agent-evolution.md` tracks it as an external workstream; it does not reparent it.

## Progress


- [ ] Verify released Baikai MCP transport/discovery APIs and complete local plan 54's generic tool-output seam.
- [ ] Implement faithful single-tool adaptation and collision validation.
- [ ] Implement owned registry discovery, registration and refresh.
- [ ] Verify complete ReAct invocation and structured/error results, wire package/docs, and distill ADR decisions.

## Surprises & Discoveries


2026-09-06 planning review: no `Baikai.Mcp` implementation was found in the Mori-located Baikai source. The existing plan assumed version bounds `>=0.2 && <0.3`; the actual shikumi-tools bound is `>=0.6 && <0.7`. Implementation remains pending external APIs, rather than being validated by a fake library shim.

2026-09-06 planning review: sanitization and truncation can merge distinct names, and prefix-based deletion cannot establish server ownership. The original collision-free claim was incorrect; explicit ownership and collision rejection replace it.

## Decision Log


Decision (2026-06-27, retained): the adapter forwards native tool names and raw JSON arguments to the server; the model sees adapter-owned `mcp__<server>__<tool>` names and the original input schema. Server validation remains authoritative.

Decision (2026-06-27, retained): a bound connection performs IO through a narrow adapter using `unsafeEff_` because `Program.Embed` only permits `LLM` and `Error ShikumiError`. Live remote actions are not replay-safe. Typed infrastructure errors bubble out; remote model-visible errors remain observations. Cancellation must remain cancellation, not be swallowed as a tool result.

Decision (2026-09-06, supersedes original dynamic-tool implementation ownership): `docs/plans/54-add-structured-resumable-react-history.md` owns generic `ToolOutput`, dynamic tools and rich dispatch. This adapter consumes them and has a hard dependency on that plan. It does not duplicate its output types or modify the legacy text dispatch contract.

Decision (2026-09-06, supersedes original result flattening): preserve structured JSON and all original extension blocks in `ToolOutput`. Its shared projection controls how providers see unsupported rich data; structured-only results must not become empty strings.

Decision (2026-09-06, supersedes original naming/refresh assumptions): reject collisions before changing a registry and retain exact ownership in an opaque MCP registry handle. Truncated names are not evidence of ownership. No fake `Baikai.Mcp` library or inferred release bound is acceptable.

## Outcomes & Retrospective


Implementation has not started. This revision makes the pending dependencies and acceptance contract explicit; no MCP capability is claimed complete.

## Context and Orientation


`shikumi-tools/src/Shikumi/Tool.hs` currently defines typed `Tool i o`, heterogeneous `SomeTool`, a name-keyed `ToolRegistry`, and `runToolCall` returning `Either ToolError Text` in the `LLM`/`Error ShikumiError` effect row. `shikumi-tools/src/Shikumi/Agent/ReAct.hs` dispatches these tools. The completed local plan 54 must first add `Shikumi.Tool.Output.ToolOutput`, a dynamic tool constructor and rich dispatch, while keeping text projections for legacy clients.

Mori identifies the provider dependency as `mori://shinzui/baikai`; curated documentation is `mori://shinzui/baikai/docs/tools`. Core `ToolResult` can carry text/image blocks and an error flag, but current provider mappings reject image tool results. The shared shikumi output representation also stores `structuredContent :: Maybe Value` and `extensionBlocks :: [Value]`. This is why the adapter must not promise universal multimedia delivery. Source artifact URI coverage is pending: the corresponding Baikai files are project-relative `baikai/src/Baikai/Message.hs` and `baikai/src/Baikai/Content.hs` under canonical project `mori://shinzui/baikai`.

Hard external dependencies are `mori://shinzui/baikai/plans/30-mcp-transport-and-json-rpc-client-core` and `mori://shinzui/baikai/plans/31-mcp-tool-discovery-and-invocation`. They own connection lifecycle, tool listing and invocation. Their interfaces are requirements below, not claims that code currently exists. [ADR-1](../adr/0001-use-profile-governed-architecture-decisions.md) now governs decision records: allocate stable ADR-N handles, preserve decision/provenance metadata, update the bundle index/log, and run `just check-adr`. No earlier feature-specific ADR was found during the initial review. Record result ownership, naming and side-effect boundaries as an ADR during implementation.

## Plan of Work


### Milestone 1: verify dependencies and adapt one real tool type


Resolve both external plans with Mori, read their delivered source and verify the package version on Hackage against upstream release tags before selecting any bound. Require actual exported MCP types and functions for connection name, listing, invocation, native name, input schema, optional description, content blocks, optional structured content and error flag. If structured content is absent, report that external dependency as incomplete and do not claim full acceptance. Do not expose production imports that require a test-only shim. Independent pure name/projection helpers can be developed without falsely marking the transport dependency complete.

After local plan 54 is complete, create `shikumi-tools/src/Shikumi/Tool/Mcp.hs`. `mcpToolFor` accepts a server identity, advertised real tool value and a bound invocation closure. Pass original arguments/native names unchanged; use `mkDynTool` for runtime schemas. Map normal content into `ToolOutput`, preserve structured JSON as its own field, keep unsupported original blocks as JSON extension values, and preserve error flags even when content is empty. Remote errors become a rich error result visible to the model; malformed arguments remain `ToolError`. Transport failures become `ShikumiError` without replaying the tool. Add `shikumi-tools/test/McpAdapterSpec.hs` using real dependency types with scripted closures. One successful text result, one structured-only result and one error result must pass the package test command below.

### Milestone 2: checked names and exact ownership


Generate names by ASCII sanitization of server/tool segments, prefixing `mcp__`, and applying a documented 64-character ceiling. Validate the complete discovered set against duplicates, already registered names and existing server identities before constructing any registry. Reject collisions with `McpAdapterError` including both original identities; never silently disambiguate or overwrite. Test servers `a.b` and `a_b`, native names that sanitize identically, names identical after truncation, delimiter-containing names and collisions with manually registered tools.

Introduce opaque `McpRegistry` containing the materialized `ToolRegistry`, immutable local tool set and a map from exact server identity to registered native/public names and tools. Construct it once from an existing registry. Registration and refresh consume/return this handle; expose a read-only `mcpRegistryTools` accessor for the agent. Do not infer ownership from prefixes and do not allow mutation of the materialized registry outside this handle. Run the package tests: a collision returns an error and leaves the caller's previous handle unchanged.

### Milestone 3: discovery and atomic refresh


Implement `mcpToolsFrom` as the connection-free seam over actual advertised types, and `mcpTools` as the listing wrapper. Implement registration and refresh against `McpRegistry`. Discover and validate the complete replacement set before returning a new registry. Refresh replaces only the exact server entry in the ownership map; unrelated tools remain intact. A discovery failure returns an error with the previous handle untouched. Multiple calls with identical discovery produce the same public names and ownership state.

A caller supplies the live connection; this module never opens or closes it. The external runner observes `tools/list_changed` and invokes refresh between agent turns. It may then start a new validated agent session with the new schemas; do not mutate schemas inside a checkpointed ReAct session. Verify removed tools disappear, retained/new tools behave correctly, and similarly named servers and ordinary local tools remain untouched.

### Milestone 4: integration, documentation and consumer contract


Expose `Shikumi.Tool.Mcp`, register McpAdapterSpec in `shikumi-tools/shikumi-tools.cabal` and the existing test entry point, and adjust dependencies only after release verification. Run a real scripted ReAct conversation using the shared rich dispatch/session API: discover `echo` and `add`, invoke prefixed `echo`, inspect its preserved native arguments and structured result in the next model request, and submit a typed answer. Test recoverable server error versus bubbling transport failure and ensure an uncertain failed call executes once.

Document a complete connection-owned usage example and refresh flow under `docs/user/`. Coordinate the handle-returning interface with dependent `mori://shinzui/shikigami/plans/12-per-agent-mcp-server-declaration-in-agent-dhall`; the original proposed bare-registry signature cannot safely support ownership. Record that required consumer adjustment in the external master plan during implementation when that work is authorized. Complete local tests and full build before declaring this adapter ready.

## Concrete Steps


Run from the repository root:

```bash
cd /Users/shinzui/Keikaku/bokuno/shikumi
mori registry show shinzui/baikai --full
mori registry docs shinzui/baikai
mori path mori://shinzui/baikai/plans/30-mcp-transport-and-json-rpc-client-core
mori path mori://shinzui/baikai/plans/31-mcp-tool-discovery-and-invocation
nix develop .#ghc9124 -c cabal build shikumi-tools
nix develop .#ghc9124 -c cabal test shikumi-tools
nix develop .#ghc9124 -c cabal build all
```

Read the resolved dependency sources, check Hackage and release tags, and record the verified release before changing bounds. Planning verification returned artifact-not-found for the external master, C1/C2 plans, and declaration-layer consumer URI. Keep these intended canonical references; their current resolution is unverified. A URI resolution failure may require a registry refresh; it does not authorize guessing an API. Successful tests report the shikumi-tools suite passing including McpAdapterSpec. If MCP source is still absent, record the unmet prerequisite and retain working independent changes without a fake library dependency.

## Validation and Acceptance


A scripted two-tool discovery and complete agent invocation proves the public capability. The model sees prefixed names and original schemas; the server closure receives the native name and identical JSON arguments; the next request contains matching call IDs and nonempty structured-only output. Mixed text, structured JSON, images and unknown extension blocks are preserved locally; provider limitations are explicit and no block is silently dropped.

Collisions from sanitization/truncation, duplicate discovery entries and collisions with local tools all fail before registry replacement. Refresh changes exactly one owner's tools, remains idempotent for identical input, and preserves the old state after failed discovery. Remote `isError` remains model-visible, transport failures bubble once, cancellation propagates, and no adapter-level automatic replay occurs. Legacy typed tools continue passing their existing tests. Passing helper tests alone does not satisfy acceptance while real released MCP APIs remain unavailable.

## Idempotence and Recovery


Registry construction and replacement return new immutable handles. Retain the previous handle until discovery, validation and construction all succeed. Duplicate refresh notifications are harmless. Tool execution itself may have remote side effects and is not idempotent; uncertain outcomes require caller reconciliation rather than automatic retries. A checkpoint cannot prove whether a tool completed during an interrupted exchange. Connection setup and shutdown remain the caller's responsibility.

## Interfaces and Dependencies


The hard local prerequisite is `docs/plans/54-add-structured-resumable-react-history.md`. Consume its `ToolOutput` with `result :: Baikai.ToolResult`, `structuredContent :: Maybe Value`, `extensionBlocks :: [Value]`, `mkDynTool` and `runToolCallOutput`; do not create a second rich-output representation. It owns message projection and typed compatibility.

External C1/C2 must provide an opaque connection, exact server identity, `listTools`, `callTool`, advertised input schema, native names, result content/structuredContent/error flag and typed transport failures. Confirm final symbols against their source rather than treating proposed `Baikai.Mcp.Client`/`Baikai.Mcp.Tool` names as implemented. The adapter must expose `McpAdapterError` for collision, discovery and configuration errors; `mcpToolFor` and `mcpToolsFrom` accept connection-bound calls for hermetic tests.

Delivered lifecycle functions are `newMcpRegistry :: ToolRegistry -> McpRegistry`, `mcpRegistryTools :: McpRegistry -> ToolRegistry`, `registerMcpTools :: McpConnection -> McpRegistry -> IO (Either McpAdapterError McpRegistry)` and `refreshMcpTools` with the same type. `McpConnection` denotes the actual upstream opaque type once delivered. This explicit signature change replaces the original unsafe bare-registry refresh contract. `mcpToolsFrom` returns checked tool descriptors with native/public identities, and `mcpToolFor` returns either an adapter error or a dynamic tool.

Use existing `aeson`, `text`, `containers`, `vector`, `effectful` and Baikai dependencies. Keep arbitrary IO embedding isolated to invoking the caller-owned connection and translate synchronous transport faults consistently; never catch asynchronous cancellation indiscriminately. The external declaration-layer consumer remains `mori://shinzui/shikigami/plans/12-per-agent-mcp-server-declaration-in-agent-dhall`.

Revision (2026-09-06): refreshed the entire pending plan against current source, retained intention and external master identity using canonical Mori URIs, moved generic output ownership to plan 54, preserved structured results, replaced unsafe name/refresh assumptions with explicit ownership, and removed the speculative shim/release-bound pathway.

Revision (2026-09-06): linked the newly bootstrapped ADR bundle and its authoring/check contract; implementation status is unchanged.
