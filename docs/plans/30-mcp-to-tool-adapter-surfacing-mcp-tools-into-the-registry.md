---
id: 30
slug: mcp-to-tool-adapter-surfacing-mcp-tools-into-the-registry
title: "MCP-to-Tool adapter surfacing MCP tools into the registry"
kind: exec-plan
created_at: 2026-06-27T17:57:56Z
intention: "intention_01kw53nf6hez4va3gyhwbh03zv"
master_plan: "shinzui/baikai:docs/masterplans/6-mcp-support-across-the-agent-stack.md"
---

# MCP-to-Tool adapter surfacing MCP tools into the registry

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Today a `shikumi` agent can only call tools that were written by hand in Haskell as a
typed `Tool i o` value (a named function whose input and output are ordinary record
types). It cannot reach the large external ecosystem of **MCP servers**. "MCP" is the
Model Context Protocol: a standardized way for a program to connect to a separate tool
server (for GitHub, Notion, a filesystem, a database, etc.) over the network, ask it
"what tools do you have?", and then call those tools by name with a JSON argument
object. The wider industry already publishes hundreds of such servers.

After this change, a caller who holds a live MCP connection (an `McpConnection` value
produced by the `baikai` library) can run one function and receive a list of ready-to-use
`shikumi` tools — one per tool the server advertises — and drop them straight into the
same `ToolRegistry` a ReAct agent already uses. From that moment the model can call a
remote MCP tool mid-run exactly as if it were a hand-written local tool: it appears in
the tool menu, the model selects it with arguments, the adapter forwards the call over
the connection, and the server's result flows back into the conversation as the next
observation.

The user-visible behavior you will be able to demonstrate at the end: given a connection
to an MCP server that advertises two tools (say `echo` and `add`), calling the adapter
registers two tools named `mcp__<server>__echo` and `mcp__<server>__add`, and a ReAct
agent driven by a scripted model that asks to call `mcp__<server>__echo` with
`{"text":"hi"}` receives back the observation text the server produced. This is proven by
an automated test that needs no network and no real server — it runs against an in-memory
stub of the connection.

This plan is child **C5** of the cross-repo MasterPlan
`shinzui/baikai:docs/masterplans/6-mcp-support-across-the-agent-stack.md` ("MCP support
across the agent stack"). That MasterPlan splits MCP into a `baikai` core that *speaks*
the protocol, a `shikumi` adapter (this plan) that *runs* MCP tools, and a `shikigami`
declaration layer that *declares* MCP servers per agent. This plan owns exactly the middle
seam: turning a `baikai` MCP connection into registered `shikumi` tools.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] Milestone 1 — Dynamic-tool path: add `DynTool` and the `SomeDynTool` arm to
      `Shikumi.Tool`, extend every `SomeTool` accessor, and prove a hand-built dynamic
      tool runs inside a ReAct loop against the mock LM.
- [ ] Milestone 2 — Single MCP tool adapter: `Shikumi.Tool.Mcp.mcpToolFor` maps one
      `McpTool` + a bound `callTool` into a `SomeTool`, applying the `mcp__<server>__<tool>`
      name, the raw input schema, JSON argument pass-through, and result/error mapping.
- [ ] Milestone 3 — Discovery + registry registration: `mcpTools` / `registerMcpTools`
      call `listTools`, prefix every tool, and merge into a `ToolRegistry`; a stub
      connection with two tools registers two `mcp__stub__*` tools and a ReAct agent
      invokes one end to end.
- [ ] Milestone 4 — Refresh on `tools/list_changed`: `replaceServerTools` /
      `refreshMcpTools` idempotently rebuild the registry's slice for one server.
- [ ] Cabal wiring: `Shikumi.Tool.Mcp` exposed, test module added, `baikai` bound moved
      to the version that ships `Baikai.Mcp.*`.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: MCP tools surface as a **dynamically-typed** tool (raw JSON in, text out),
  added as a new existential arm `SomeDynTool` on `Shikumi.Tool.SomeTool`, rather than as
  a typed `Tool i o`.
  Rationale: a typed `Tool i o` derives its JSON Schema *from the Haskell type* `i`
  (`toolSchemaOf t = toSchema (Proxy @i)` in `shikumi-tools/src/Shikumi/Tool.hs`). An MCP
  tool's schema is runtime data delivered by the server (`McpTool.inputSchema`), so there
  is no Haskell type whose `ToSchema` instance can produce it. A dynamic arm that carries
  its own schema `Value` and a `Value -> Eff es (Either ToolError Text)` body is the only
  faithful representation. It keeps `ToolRegistry`, `runToolCall`, and the entire ReAct
  loop unchanged, because both arms are still `SomeTool`.
  Date: 2026-06-27

- Decision: the MCP tool body performs its network call through
  `Effectful.Dispatch.Static.unsafeEff_ :: IO a -> Eff es a` rather than by widening the
  effect row with `IOE` or a new `Mcp` effect.
  Rationale: a ReAct agent is a `Program` whose embedded body is constrained by
  `Shikumi.Program.Embed` to *exactly* `(LLM :> es, Error ShikumiError :> es)` — `IOE` is
  deliberately excluded (see `shikumi/src/Shikumi/Program.hs`, the `Embed` constructor
  doc, integration point #4). Adding `IOE`/`Mcp` to the body would force a change to the
  `Program` core type and `runProgram`, which is out of scope for an adapter plan and
  would ripple through every shikumi program. `unsafeEff_` embeds the already-established
  connection's request/response IO into the narrow row without changing any signature. The
  accepted trade-off: MCP tool calls are genuinely impure side effects that are *not*
  tracked by the effect system and are therefore *not* replayable or content-addressable
  the way pure typed tools are — this is inherent to calling a live external server and is
  documented as a known limitation.
  Date: 2026-06-27

- Decision: the `mcp__<server>__<tool>` naming convention is owned **here**, in this
  adapter; `baikai` keeps each tool's native server-side name.
  Rationale: the MasterPlan's contract assigns native names to `baikai` and the
  collision-avoidance prefix to the consumer. The adapter prepends
  `mcp__<sanitized-server>__<sanitized-tool>` to form the registry key and the name the
  model sees, while the body forwards the **native** name back to `callTool`. The double
  underscore delimiter matches the de-facto MCP tool-naming convention used across the
  ecosystem.
  Date: 2026-06-27

- Decision: arguments are passed through to the server as raw JSON with no
  adapter-side schema validation; the server validates against its own `inputSchema`.
  Rationale: the adapter has no typed `i` to decode into and the authoritative schema lives
  on the server. Re-implementing JSON-Schema validation here would duplicate the server's
  job and risk divergence. The schema is still surfaced to the model (so the model produces
  well-shaped arguments) and a server that rejects bad arguments returns an error result,
  which the adapter maps to a model-visible `ToolError` so the model can correct itself.
  Date: 2026-06-27

- Decision: result and error mapping splits cleanly into two channels. A successful
  `McpToolResult` with `isError = False` becomes `Right <rendered content text>`. A result
  with `isError = True` becomes `Left (ToolRunFailed <prefixed name> <rendered content>)` —
  a model-visible observation the agent can recover from. A transport/protocol failure
  (the `callTool` IO action returns `Left McpError`) becomes
  `throwError (ProviderFailure ...)` in shikumi's `ShikumiError` channel — an
  infrastructure fault that bubbles out of the loop, mirroring how `Shikumi.Error`
  classifies provider/transport failures.
  Rationale: it preserves shikumi's existing discipline — `ToolError` is a recoverable
  value the model sees, `ShikumiError` is an infrastructure fault — and it never throws a
  raw exception to the caller.
  Date: 2026-06-27

- Decision: the adapter exposes a connection-free seam (`mcpToolsFrom`, taking a server
  label plus a bound `callTool` closure and a `[McpTool]` list) underneath the
  connection-level `mcpTools`.
  Rationale: it lets the test suite build MCP tools from pure stub closures with no real
  `McpConnection` and no network, which is essential because `baikai`'s `Baikai.Mcp.*`
  modules (children C1/C2) are not yet implemented. The connection-level functions are thin
  wrappers that bind `mcpServerName`, `listTools`, and `callTool` to the seam.
  Date: 2026-06-27


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This section assumes you have never seen this repository. Read it before touching code.

### What `shikumi` is and where tools live

`shikumi` (the repository at `/Users/shinzui/Keikaku/bokuno/shikumi`, mori name
`shinzui/shikumi`) is a Haskell framework for typed, evaluable language-model programs. It
is a Cabal multi-package project; the package relevant here is **`shikumi-tools`**, whose
source lives under `shikumi-tools/src/Shikumi/`. The two files you will spend all your time
in or around are:

- `shikumi-tools/src/Shikumi/Tool.hs` — the typed tool abstraction, the registry, and the
  wire round-trip.
- `shikumi-tools/src/Shikumi/Agent/ReAct.hs` — the ReAct agent loop that offers tools to a
  model and dispatches the ones it picks.

A **`Tool i o`** (defined in `Shikumi.Tool`) is a named function from an input record `i`
to an output `o`, with an effectful body:

```haskell
data Tool i o = Tool
  { name :: !Text,
    description :: !Text,
    run :: !(forall es. (LLM :> es, Error ShikumiError :> es) => i -> Eff es o)
  }
```

`Eff es` is the monad of the **`effectful`** library; `(LLM :> es, Error ShikumiError :> es)`
means "this code runs in any effect stack `es` that provides the `LLM` capability (call a
sub-model) and the `Error ShikumiError` capability (signal a typed failure)". Crucially the
row does **not** include `IOE` (the capability to run arbitrary `IO`) — that exclusion is
deliberate and is the central constraint this plan must work within (see below).

Tools are made heterogeneous by an **existential** so a registry can hold tools of
different `i`/`o`:

```haskell
data SomeTool where
  SomeTool ::
    (ToSchema i, FromModel i, Validatable i, ToJSON o) =>
    Tool i o ->
    SomeTool
```

`ToSchema i` derives the JSON Schema of the input from the *type* `i`; `FromModel i`
decodes a JSON arguments object into `i`; `ToJSON o` encodes the result. A
**`ToolRegistry`** is `newtype ToolRegistry = ToolRegistry (Map Text SomeTool)` — a
name-keyed map. The relevant exported functions are `mkRegistry :: [SomeTool] ->
ToolRegistry`, `registryLookup`, `registryTools :: ToolRegistry -> [SomeTool]`,
`registryBaikai` (lower every tool to the wire form for the model), and the dispatch entry
point `runToolCall :: (LLM :> es, Error ShikumiError :> es) => ToolRegistry -> ToolCall ->
Eff es (Either ToolError Text)`.

The error vocabulary is a value type, never an exception. `ToolError` (in `Shikumi.Tool`)
has `ToolNotFound`, `ToolArgsInvalid name msg`, and `ToolRunFailed name msg`; the ReAct
loop renders it to observation text and feeds it back to the model. Infrastructure faults
instead use `ShikumiError` (in `shikumi/src/Shikumi/Error.hs`), whose constructors include
`ProviderFailure Text`, `Timeout Text`, and `SchemaMismatch Text`; these bubble up through
the `Error ShikumiError` channel.

### Why MCP tools cannot be typed `Tool i o` values

A typed tool derives its parameter schema from its Haskell type:
`lowerTool t = _Tool & #name .~ ... & #parameters .~ toolSchemaOf t`, and
`toolSchemaOf _ = toSchema (Proxy @i)`. An MCP server, by contrast, hands you a *raw JSON
Schema value at runtime* (the `inputSchema` field of each advertised tool). There is no
Haskell type whose `ToSchema` instance reproduces an arbitrary runtime schema. Therefore an
MCP tool must surface as a **dynamically-typed tool**: a tool that carries its own schema
`Value`, accepts a raw JSON arguments `Value`, and returns text — with no compile-time
`i`/`o`. This plan adds that as a second arm of `SomeTool` named `SomeDynTool`, so MCP
tools live in the *same* `ToolRegistry` and dispatch through the *same* `runToolCall` as
typed tools, but skip the type-derived schema/decode machinery.

### Why the network call uses `unsafeEff_`

A ReAct agent is built as a `Program i o` (the deep embedding in
`shikumi/src/Shikumi/Program.hs`) via `embed (reactLoop ...)`. The `Embed` constructor
fixes its body's effect row to *exactly* `(LLM :> es, Error ShikumiError :> es)` — no
`IOE`. `runProgram` then runs that body. This means a tool body executing inside a ReAct
agent has no `IOE` in its row and cannot directly run `IO`. An MCP tool, however, must make
a network request. The resolution is `Effectful.Dispatch.Static.unsafeEff_ :: IO a -> Eff
es a`, the sanctioned `effectful` escape hatch that embeds an `IO` action into any row
without an `IOE` constraint. The adapter captures the connection-bound `callTool` IO action
in the tool's closure at registration time and invokes it via `unsafeEff_` at dispatch
time. This keeps `Tool`, `SomeTool` dispatch, `ToolRegistry`, and `react` signatures
**unchanged**. The cost — MCP tool calls are not tracked, replayed, or cached by the effect
system — is inherent to calling a live external server and is recorded in the Decision Log.

### The cross-repo `baikai` MCP surface this consumes

`baikai` (repository `/Users/shinzui/Keikaku/bokuno/baikai`, mori name `shinzui/baikai`) is
the LLM-provider and wire-protocol library `shikumi` already depends on. Its existing
untyped wire tool is `Baikai.Tool.Tool { name :: Text, description :: Text, parameters ::
Value }` (in `baikai/src/Baikai/Tool.hs`), which `shikumi` lowers typed tools to. The MCP
client is a **new** `Baikai.Mcp` namespace delivered by two MasterPlan children that this
plan depends on:

- `shinzui/baikai:docs/plans/30-mcp-transport-and-json-rpc-client-core.md` (child **C1**):
  the transport, JSON-RPC 2.0 framing, and `initialize` handshake. It defines
  `Baikai.Mcp.Client.McpConnection` (an opaque live-connection handle) and `connectMcp`
  (establish one). The server's name — used for the `mcp__<server>__` prefix — is read from
  the connection via `Baikai.Mcp.Client.mcpServerName :: McpConnection -> Text`.

- `shinzui/baikai:docs/plans/31-mcp-tool-discovery-and-invocation.md` (child **C2**):
  `Baikai.Mcp.Tool`, defining the wire tool record `McpTool` (with `name`, an optional
  `description`, and `inputSchema :: Value`), the call/result records `McpToolCall` and
  `McpToolResult` (content plus an `isError` flag), and the two operations `listTools` and
  `callTool`.

Because C1 and C2 are not yet implemented (both are skeleton plans at the time of writing),
this plan states the exact shapes it consumes in "Interfaces and Dependencies" as the
**shared contract**, and is built to be unit-testable against stub closures so the adapter
logic can be developed and validated before — or in parallel with — the real `baikai`
modules.

### Build tooling

The project builds with Cabal under a Nix dev shell. `cabal.project` lists every package
(including `shikumi-tools`) and pins GHC 9.12.4 via `flake.nix` (the system `ghc` is the
wrong version — you **must** build inside `nix develop`). The `Justfile` provides
`just build` (`cabal build all`), `just test` (`cabal test all`), and `just test-one <pkg>`
(`cabal test <pkg>`). The `shikumi-tools` test suite is `shikumi-tools-test`, a
`tasty`/`tasty-hunit` suite under `shikumi-tools/test/`, with a deterministic mock LM in
`shikumi-tools/test/MockLLM.hs` (`runEffMock`, `runAgent`, `mkTextResponse`,
`mkToolCallResponse`) that runs the agent in `Eff '[LLM, Error ShikumiError, IOE]` over
`IO` — note `IOE` is already present at the bottom of the test stack, so `unsafeEff_` works
under it.


## Plan of Work

The work proceeds in four milestones plus a cabal-wiring step. Each milestone is
independently verifiable with `cabal test shikumi-tools` (run inside `nix develop`) and
adds an automated test that fails before the milestone's code exists and passes after.

### Milestone 1 — The dynamic-tool path in `Shikumi.Tool`

Scope: teach `Shikumi.Tool` to hold a tool whose schema, decode, and run are all runtime
data instead of type-derived. At the end, a hand-built dynamic tool (no MCP yet) can be put
in a `ToolRegistry` and invoked by a ReAct agent against the mock LM.

In `shikumi-tools/src/Shikumi/Tool.hs`, add a record for a dynamically-typed tool and a
second arm of the `SomeTool` existential. Place this near the existing `SomeTool`
definition:

```haskell
-- | A dynamically-typed tool: a raw JSON arguments object in, observation text out,
-- carrying its /own/ JSON Schema rather than deriving one from a Haskell type. This is
-- what an MCP tool becomes — see "Shikumi.Tool.Mcp". The body returns the same
-- @Either ToolError Text@ shape that 'runErased' produces for typed tools, so dispatch
-- is uniform; an infrastructure fault is signalled on the @Error ShikumiError@ channel.
data DynTool = DynTool
  { dynName :: !Text,
    dynDescription :: !Text,
    dynSchema :: !Value,
    dynRun ::
      !( forall es.
         (LLM :> es, Error ShikumiError :> es) =>
         Value ->
         Eff es (Either ToolError Text)
       )
  }

-- | Smart constructor: build an erased dynamic tool.
mkDynTool ::
  Text ->
  Text ->
  Value ->
  (forall es. (LLM :> es, Error ShikumiError :> es) => Value -> Eff es (Either ToolError Text)) ->
  SomeTool
mkDynTool nm desc schema body =
  SomeDynTool (DynTool {dynName = nm, dynDescription = desc, dynSchema = schema, dynRun = body})
```

Change the existential to two arms (this requires `GADTs`, already enabled):

```haskell
data SomeTool where
  SomeTool ::
    (ToSchema i, FromModel i, Validatable i, ToJSON o) =>
    Tool i o ->
    SomeTool
  SomeDynTool :: DynTool -> SomeTool
```

Extend every function that pattern-matches `SomeTool` to handle `SomeDynTool` — the
package builds with `-Wall`/`-Wincomplete-patterns`, so a missed arm is a build error:

```haskell
someToolName (SomeDynTool d) = dynName d
someToolDescription (SomeDynTool d) = dynDescription d
someToolSchema (SomeDynTool d) = dynSchema d

lowerSomeTool (SomeDynTool d) =
  _Tool & #name .~ dynName d & #description .~ dynDescription d & #parameters .~ dynSchema d

runErased (SomeDynTool d) args = dynRun d args
```

`runToolCall`, `mkRegistry`, `registryLookup`, `registryBaikai`, `registryNames`, and
`registryTools` need **no** change: they operate on the registry map or call the accessors
above. Export `DynTool (..)` and `mkDynTool` from the module's export list.

Verification: add `shikumi-tools/test/DynToolSpec.hs` with a test that builds
`mkDynTool "echo" "echoes" schema (\v -> pure (Right (encodeText v)))`, registers it,
drives a `react` agent with `runAgent` and a scripted native tool-call response selecting
`echo`, and asserts the trajectory's observation equals the echoed JSON. Acceptance: the
test passes; `ToolSpec` (the existing typed-tool tests) still passes unchanged.

### Milestone 2 — Single MCP tool adapter

Scope: a function that converts one `McpTool` plus a connection-bound `callTool` closure
into a `SomeTool`, applying the prefix, schema, argument pass-through, and result/error
mapping. At the end this is provable for a single tool with stub closures, no registry yet.

Create a new module `shikumi-tools/src/Shikumi/Tool/Mcp.hs`. Define the prefix helper and
the per-tool adapter:

```haskell
-- | The collision-free registry name for an MCP tool: @mcp__<server>__<tool>@. Both
-- segments are sanitized to the characters providers accept in a tool name
-- (@[A-Za-z0-9_-]@), other characters becoming @_@, and the whole name is capped at 64
-- characters (the tool-name length most providers accept).
mcpToolName :: Text -> Text -> Text
mcpToolName server tool =
  T.take 64 ("mcp__" <> sanitize server <> "__" <> sanitize tool)
  where
    sanitize = T.map (\c -> if isAllowed c then c else '_')
    isAllowed c = isAsciiUpper c || isAsciiLower c || isDigit c || c == '_' || c == '-'

-- | Convert one advertised MCP tool into a shikumi tool. @call@ is the connection-bound
-- invocation: @\\mtc -> callTool conn mtc@. The body forwards the model's raw JSON
-- arguments under the tool's /native/ name (baikai keeps native names; the prefix is only
-- the registry key and the name the model sees), runs the call via 'unsafeEff_', and maps
-- the result: a normal result to @Right text@, an @isError@ result to a model-visible
-- @ToolError@, and a transport failure to a bubbling @ShikumiError@.
mcpToolFor ::
  Text ->                                            -- server label
  (McpToolCall -> IO (Either McpError McpToolResult)) -> -- callTool bound to the connection
  McpTool ->
  SomeTool
mcpToolFor server call mt =
  mkDynTool
    (mcpToolName server (mcpToolNativeName mt))
    (fromMaybe "" (mcpToolDescription mt))
    (mcpToolInputSchema mt)
    ( \args -> do
        res <- unsafeEff_ (call (mkMcpToolCall (mcpToolNativeName mt) args))
        case res of
          Left err ->
            throwError (ProviderFailure ("MCP tool call failed: " <> renderMcpError err))
          Right result
            | mcpResultIsError result ->
                pure (Left (ToolRunFailed (mcpToolName server (mcpToolNativeName mt)) (renderMcpResult result)))
            | otherwise ->
                pure (Right (renderMcpResult result))
    )
```

`renderMcpResult :: McpToolResult -> Text` flattens the result's content blocks to text:
concatenate the text of every text block; for non-text blocks (image/resource) emit a
compact JSON rendering so nothing is silently dropped. `renderMcpError :: McpError -> Text`
produces a human-readable message. (The exact `McpToolResult`/`McpError` field accessors
are baikai's; see "Interfaces and Dependencies" for the assumed shape and adjust the
renderers to the records C2 ships.)

Verification: in a new `shikumi-tools/test/McpAdapterSpec.hs`, build a stub `McpTool`
record and a stub `call` closure that returns a fixed `McpToolResult`, apply `mcpToolFor
"stub" stubCall stubTool`, and assert (a) `someToolName` is `mcp__stub__echo`, (b)
`someToolSchema` equals the stub's `inputSchema`, and (c) running it via `runErased` with a
JSON args object yields the expected `Right` text. Also assert an `isError = True` stub maps
to `Left (ToolRunFailed ...)`. Acceptance: the spec passes.

### Milestone 3 — Discovery and registry registration

Scope: discover all of a connection's tools and register them. At the end, a stub
connection advertising two tools registers two `mcp__stub__*` tools and a ReAct agent
invokes one end to end.

Add to `Shikumi.Tool.Mcp` the connection-free seam and the connection-level wrappers:

```haskell
-- | Build shikumi tools from an explicit server label, a bound 'callTool', and an
-- already-listed set of MCP tools. The test seam: no 'McpConnection' or network needed.
mcpToolsFrom ::
  Text ->
  (McpToolCall -> IO (Either McpError McpToolResult)) ->
  [McpTool] ->
  [SomeTool]
mcpToolsFrom server call = map (mcpToolFor server call)

-- | Discover a connection's tools and surface each as a shikumi 'SomeTool'. Calls
-- baikai's 'listTools'; on a transport failure returns @Left McpError@ (registration is
-- an explicit IO step owned by the runner, so a discovery failure is a value here, not an
-- exception).
mcpTools :: McpConnection -> IO (Either McpError [SomeTool])
mcpTools conn = do
  listed <- listTools conn
  pure (fmap (mcpToolsFrom (mcpServerName conn) (callTool conn)) listed)

-- | Discover and merge into an existing registry (existing tools kept; MCP tools added).
registerMcpTools :: McpConnection -> ToolRegistry -> IO (Either McpError ToolRegistry)
registerMcpTools conn reg = do
  built <- mcpTools conn
  pure (fmap (\sts -> mkRegistry (registryTools reg <> sts)) built)
```

`mkRegistry` is last-wins on a name clash; appending the MCP tools after the existing ones
means an MCP tool wins only if it duplicates a name, which the prefix makes effectively
impossible. Verification: in `McpAdapterSpec`, build a stub connection-like value
exercising the `mcpToolsFrom` seam with two tools, build a registry, assert
`registryNames` contains exactly `mcp__stub__echo` and `mcp__stub__add`, then run a `react`
agent (via `runAgent`) scripted to call `mcp__stub__echo` and assert the final observation
matches the stub's result. Acceptance: two tools registered; the agent's trajectory shows
the MCP observation.

### Milestone 4 — Refresh on `tools/list_changed`

Scope: support an MCP server that changes its tool list mid-session (the protocol's
`notifications/tools/list_changed`). At the end, re-listing replaces exactly that server's
slice of the registry, idempotently.

A `ToolRegistry` is immutable, so "refresh" means producing a new registry with one
server's tools swapped. Add:

```haskell
-- | Drop every tool whose name belongs to @server@ (prefix @mcp__<server>__@) and add the
-- given replacements. Idempotent: re-running with the same inputs yields the same registry.
replaceServerTools :: Text -> [SomeTool] -> ToolRegistry -> ToolRegistry
replaceServerTools server new reg =
  mkRegistry (filter (not . belongsTo) (registryTools reg) <> new)
  where
    prefix = "mcp__" <> sanitizeServer server <> "__"
    belongsTo st = prefix `T.isPrefixOf` someToolName st

-- | Re-discover @conn@'s tools and replace that server's slice of @reg@. Call this when
-- the runner observes the server's @tools/list_changed@ notification.
refreshMcpTools :: McpConnection -> ToolRegistry -> IO (Either McpError ToolRegistry)
refreshMcpTools conn reg = do
  built <- mcpTools conn
  pure (fmap (\sts -> replaceServerTools (mcpServerName conn) sts reg) built)
```

`sanitizeServer` must apply the *same* sanitization as `mcpToolName`'s server segment so
the prefix matches. Observing the notification itself is `baikai`'s and the runner's job
(child C6 wires it); the adapter's contribution is the deterministic rebuild. Verification:
in `McpAdapterSpec`, register two tools, then `replaceServerTools "stub" [oneNewTool]` and
assert the registry now has exactly the one new `mcp__stub__*` tool (the old slice removed,
unrelated typed tools untouched). Acceptance: the slice swap is exact and leaves non-MCP
tools in place.

### Cabal wiring

In `shikumi-tools/shikumi-tools.cabal`, add `Shikumi.Tool.Mcp` to the library's
`exposed-modules`, add `DynToolSpec` and `McpAdapterSpec` to the test suite's
`other-modules`, and — when `baikai`'s `Baikai.Mcp.*` modules ship — move the `baikai`
version bound (currently `>=0.2 && <0.3`) to the published version that includes them. Until
that version exists the adapter is developed against the contract types documented below
(optionally mirrored locally as a throwaway shim to compile the logic; delete the shim when
the real modules land — see Idempotence and Recovery).


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/shikumi` inside
the Nix dev shell (the system GHC is the wrong version). Enter the shell once:

```bash
cd /Users/shinzui/Keikaku/bokuno/shikumi
nix develop
```

Build only the package you are changing, for a fast loop:

```bash
cabal build shikumi-tools
```

Expected first build after Milestone 1 (the existential gained an arm; the accessors now
cover it):

```text
Building library for shikumi-tools-0.1.0.1...
[ 1 of N] Compiling Shikumi.Tool ( src/Shikumi/Tool.hs, ... )
...
```

Run the package's tests:

```bash
cabal test shikumi-tools
```

or equivalently `just test-one shikumi-tools`. Expected transcript once all milestones land
(suite names are illustrative — match them to the `tasty` group names you give the new
specs):

```text
shikumi-tools-test
  ToolSpec:        OK (existing typed-tool tests)
  ReActSpec:       OK
  DynToolSpec:     OK   (M1: dynamic tool runs in a ReAct loop)
  McpAdapterSpec:
    mcpToolName prefixes mcp__stub__echo:           OK
    surfaces inputSchema verbatim:                  OK
    maps normal result to Right text:               OK
    maps isError result to ToolRunFailed:           OK
    registers two mcp__stub__* tools:               OK
    ReAct agent invokes mcp__stub__echo end-to-end: OK
    replaceServerTools swaps one server's slice:    OK

All N tests passed
```

If `baikai`'s `Baikai.Mcp.*` modules are not yet available, the import of
`Baikai.Mcp.Client`/`Baikai.Mcp.Tool` will fail to resolve; in that case follow the local
shim path in Idempotence and Recovery to develop the logic, and remove the shim once the
real modules ship.


## Validation and Acceptance

Acceptance is phrased as observable behavior, all provable by `cabal test shikumi-tools`
with no network and no real MCP server.

1. **A dynamic tool is callable in a real agent.** After Milestone 1, `DynToolSpec` builds
   `mkDynTool "echo" ...`, registers it, and runs a `react` agent against the mock LM
   scripted to select `echo`. Observed: the recorded `Trajectory` contains a `CallTool
   "echo"` step whose `observation` is the echoed arguments JSON. This proves the new
   `SomeDynTool` arm dispatches through the unchanged `runToolCall`/ReAct path.

2. **One MCP tool maps faithfully.** After Milestone 2, given a stub `McpTool` named `echo`
   with `inputSchema = {"type":"object","properties":{"text":{"type":"string"}}}` and a
   stub `callTool` that returns the text it was sent: `someToolName` is `mcp__stub__echo`;
   `someToolSchema` equals that `inputSchema` verbatim; invoking it with `{"text":"hi"}`
   yields `Right "hi"`; and a stub returning `isError = True` yields
   `Left (ToolRunFailed "mcp__stub__echo" ...)`.

3. **Two tools register and one is invoked end to end (the headline acceptance).** After
   Milestone 3, given a stub connection seam advertising `echo` and `add`,
   `registryNames` on the produced registry is exactly
   `["mcp__stub__add", "mcp__stub__echo"]` (map order), and a `react` agent scripted to
   call `mcp__stub__echo` with `{"text":"hi"}` finishes with the stub's observation text in
   its trajectory. This is the user-visible behavior from the Purpose section, demonstrated
   without any real server.

4. **Refresh is exact and idempotent.** After Milestone 4, calling `replaceServerTools
   "stub" [echoOnly]` on a registry that held `echo`, `add`, and an unrelated typed tool
   leaves exactly `echo` (under `mcp__stub__echo`) plus the typed tool; re-running it
   yields an identical registry.

5. **Existing behavior is unbroken.** `ToolSpec` and `ReActSpec` continue to pass
   unchanged, proving the additive existential arm did not disturb the typed-tool path.

The change is effective beyond compilation because acceptance #3 runs a full
propose→dispatch→observe agent loop and observes an MCP-sourced result flowing back into
the conversation.


## Idempotence and Recovery

Every function this plan adds is pure with respect to the registry: `mcpTools`,
`registerMcpTools`, `replaceServerTools`, and `refreshMcpTools` produce a new value and
never mutate in place, so they can be run repeatedly. `replaceServerTools` and
`refreshMcpTools` are idempotent for a fixed server tool set — running them twice yields the
same registry — which makes recovery from a missed or duplicated `tools/list_changed`
notification trivial: just refresh again.

Discovery and invocation return `Either McpError ...` / `Either ToolError Text` rather than
throwing, so a transient transport failure does not corrupt state; the caller retries the
IO step. A transport failure during a tool call surfaces as a bubbling `ShikumiError
(ProviderFailure ...)` that the agent's outer error handling already knows how to treat as
transient (`Shikumi.Error.isTransient` classifies `ProviderFailure` as retryable).

Recovery path when `baikai`'s `Baikai.Mcp.*` modules are not yet published: add a throwaway
module `shikumi-tools/test/McpContractShim.hs` (test-only, never in the library) that
defines local `McpTool`, `McpToolCall`, `McpToolResult`, `McpError` mirrors matching the
contract below, and develop/validate Milestones 1–4 against it. When C1/C2 ship, switch
`Shikumi.Tool.Mcp` to `import Baikai.Mcp.Client` / `import Baikai.Mcp.Tool`, delete the
shim, bump the `baikai` bound, and re-run `cabal test shikumi-tools`. Because the adapter
depends only on the small set of fields named in the contract, this switch is a mechanical
import change.


## Interfaces and Dependencies

### Consumed from `baikai` (the shared contract — defined by C1/C2)

These are the exact shapes `Shikumi.Tool.Mcp` imports. They are owned by the `baikai`
children; this plan depends on them and adjusts field accessors to whatever those plans
finalize. Hard dependencies:

- `shinzui/baikai:docs/plans/30-mcp-transport-and-json-rpc-client-core.md` (C1) — the
  connection lifecycle. Required surface, module `Baikai.Mcp.Client`:

  ```haskell
  data McpConnection                          -- opaque live-connection handle
  connectMcp    :: McpConfig -> IO (Either McpError McpConnection)  -- config shape owned by C1/C3
  mcpServerName :: McpConnection -> Text       -- server label, used for the prefix
  ```

- `shinzui/baikai:docs/plans/31-mcp-tool-discovery-and-invocation.md` (C2) — tool discovery
  and invocation. Required surface, module `Baikai.Mcp.Tool`:

  ```haskell
  data McpTool                                 -- name, optional description, inputSchema :: Value
  data McpToolCall                             -- target tool name + arguments :: Value
  data McpToolResult                           -- content blocks + isError :: Bool
  data McpError                                -- transport/protocol failure

  listTools :: McpConnection -> IO (Either McpError [McpTool])
  callTool  :: McpConnection -> McpToolCall -> IO (Either McpError McpToolResult)
  ```

  The adapter uses these accessors (rename to C2's final field names if they differ): the
  native tool name, an optional description, the raw `inputSchema :: Value`, an
  `McpToolResult`'s content list and its `isError` flag, and a constructor for
  `McpToolCall` from a native name and an arguments `Value`. The adapter forwards the
  **native** name to `callTool`; `baikai` does not apply the `mcp__` prefix.

### Delivered by this plan (in `shikumi-tools`)

Additive surface in `Shikumi.Tool` (module
`shikumi-tools/src/Shikumi/Tool.hs`):

```haskell
data DynTool = DynTool
  { dynName :: !Text,
    dynDescription :: !Text,
    dynSchema :: !Value,
    dynRun ::
      !(forall es. (LLM :> es, Error ShikumiError :> es) => Value -> Eff es (Either ToolError Text))
  }

mkDynTool ::
  Text -> Text -> Value ->
  (forall es. (LLM :> es, Error ShikumiError :> es) => Value -> Eff es (Either ToolError Text)) ->
  SomeTool

-- SomeTool gains the arm  SomeDynTool :: DynTool -> SomeTool
```

New module `Shikumi.Tool.Mcp` (file `shikumi-tools/src/Shikumi/Tool/Mcp.hs`):

```haskell
mcpToolName        :: Text -> Text -> Text
mcpToolFor         :: Text -> (McpToolCall -> IO (Either McpError McpToolResult)) -> McpTool -> SomeTool
mcpToolsFrom       :: Text -> (McpToolCall -> IO (Either McpError McpToolResult)) -> [McpTool] -> [SomeTool]
mcpTools           :: McpConnection -> IO (Either McpError [SomeTool])
registerMcpTools   :: McpConnection -> ToolRegistry -> IO (Either McpError ToolRegistry)
replaceServerTools :: Text -> [SomeTool] -> ToolRegistry -> ToolRegistry
refreshMcpTools    :: McpConnection -> ToolRegistry -> IO (Either McpError ToolRegistry)
```

### Libraries used and why

- `effectful` — the effect monad. `Effectful.Dispatch.Static.unsafeEff_` embeds the
  connection's `callTool` IO into the narrow ReAct body row (see Context for why this is
  necessary). `Effectful.Error.Static.throwError` raises infrastructure faults on the
  `Error ShikumiError` channel.
- `aeson` — `Value` for the raw schema, arguments, and result content; reuse the module's
  existing `encodeText`.
- `text`, `containers`, `vector` — text munging for the prefix, the `Map` behind
  `ToolRegistry`, and result content handling. All already in `shikumi-tools.cabal`.
- `baikai` — the `Baikai.Mcp.*` surface above (hard dependency on C1+C2) and the existing
  `Baikai.Tool` wire record (already a dependency).

### Dependents

- `shinzui/shikigami:docs/plans/12-per-agent-mcp-server-declaration-in-agent-dhall.md`
  (child **C6**) consumes this adapter: it reads an `mcpServers` field from an agent's Dhall
  declaration, calls `connectMcp` per server, then `registerMcpTools` (and wires
  `refreshMcpTools` to the server's `tools/list_changed` notification) before the agent's
  behavior runs. This plan must keep `registerMcpTools` / `refreshMcpTools` stable for C6.

### Shared integration contract (must match exactly)

Consumes `Baikai.Mcp.{Client,Tool}`; produces shikumi `SomeTool` values in the existing
`Shikumi.Tool.ToolRegistry`; names every surfaced tool `mcp__<server>__<tool>` with the
server segment read from `mcpServerName` and the tool segment the server's native name.
