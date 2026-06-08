---
id: 11
slug: typed-tools-and-react-agents
title: "Typed tools and ReAct agents"
kind: exec-plan
created_at: 2026-06-08T02:44:17Z
intention: "intention_01ktjgkp10ef79vpwz1cmajek9"
master_plan: "docs/masterplans/1-shikumi-typed-lm-programming-framework.md"
---

# Typed tools and ReAct agents

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Today, if you want a language model (an "LM" — the text-completion service behind providers
like Anthropic Claude or OpenAI GPT) to *use tools* — call a function, look something up,
do arithmetic — you must hand the provider a raw JSON Schema describing the tool's
arguments, then hand-decode whatever JSON the model sends back, dispatch to the right
Haskell function, and feed a text result back into the conversation. Every one of those
steps is untyped and easy to get wrong: a typo in the schema, a missing field in the
model's arguments, or a mismatch between the schema you advertised and the function you
actually call all surface as runtime surprises, not compile errors.

After this ExecPlan, a Haskell developer can write a *typed tool* as an ordinary function
over record types and let shikumi do the rest:

```haskell
data WeatherReq = WeatherReq { city :: Text, units :: Text }
  deriving stock (Generic, Show)

data WeatherResp = WeatherResp { tempC :: Double, summary :: Text }
  deriving stock (Generic, Show)

weatherTool :: Tool WeatherReq WeatherResp
weatherTool =
  mkTool "get_weather" "Look up the current weather for a city."
    (\req -> pure (lookupWeather req))   -- the body runs in Eff es
```

From `weatherTool` shikumi derives the JSON Schema for `WeatherReq` automatically (reusing
the Generic schema generator owned by the signatures plan,
`docs/plans/3-generic-derived-signatures-and-structured-io.md`), lowers the typed tool down
to baikai's untyped wire tool `Baikai.Tool { name, description, parameters :: Value }`,
decodes the model's argument JSON into a typed `WeatherReq` (or returns a *typed error*, not
a crash, when the arguments are malformed), runs the function, and encodes the typed result
back into a `Baikai.ToolResult` for the next turn of the conversation.

On top of typed tools this ExecPlan delivers a *ReAct agent*. ReAct ("Reason + Act") is a
loop in which the model alternates between thinking and acting: at each step it produces a
short *thought*, then either selects a tool and supplies arguments, or declares it is
*finished*. The runtime executes the selected tool, records the result as an *observation*,
appends it to the conversation, and asks the model again — until the model finishes, or a
configured iteration/budget bound is hit. Then a final *extract* step asks the model to
produce the typed answer the caller actually wanted. The whole agent is expressed as a
`Program i o` value (the typed program-as-data representation owned by
`docs/plans/4-typed-program-representation-and-core-modules.md`) so it remains inspectable,
traceable, and optimizable like any other shikumi program.

You can see it work end-to-end with `cabal test shikumi-tools-test`. The acceptance test
defines `weatherTool`, builds `react @AnswerWeatherQuestion [SomeTool weatherTool]`, runs it
against a *mock LM* (a deterministic stand-in for a real provider that emits a scripted tool
call and then a finish), and observes three things: the typed final answer is returned, a
structured *trajectory* (the recorded sequence of thought/action/observation steps) is
attached, the derived JSON Schema for the tool exactly matches the expected schema, and
feeding deliberately malformed arguments yields a typed `ToolError`, not an exception that
tears down the process.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M0 (spike): `shikumi-tools` package skeleton compiles and links against `shikumi`,
      `baikai`, `aeson`, `effectful`; a trivial `Tool` value can be constructed and its
      derived schema printed.
- [ ] M1: `Tool i o` type, `mkTool`/`mkToolIO`, schema derivation, and lowering to
      `Baikai.Tool` implemented and unit-tested (schema snapshot test).
- [ ] M1: `SomeTool` existential + `ToolRegistry` + typed decode/dispatch/encode round-trip
      (`runToolCall`) implemented; malformed-arguments test yields a typed `ToolError`.
- [ ] M2: `Trajectory`/`Step`/`Action` data model and the ReAct signature extension
      (`ReActState`, `Thought`, `ToolPick`) implemented.
- [ ] M2: `react` builds a `Program i o` whose loop runs propose → dispatch → observe until
      finish/budget, then extracts the typed output; mock-LM end-to-end test passes.
- [ ] M3: Native-vs-prompt tool-protocol seam wired: `ToolProtocol` selector, native path
      using baikai `Context.tools`/`Options.toolChoice` (+ EP-2 `response_format` for
      extract), prompt fallback path; both paths covered by tests.
- [ ] M4: Acceptance test green: typed tool + ReAct + mock LM → typed answer + recorded
      trajectory + schema assertion + bad-args typed error. `cabal test all` passes.
- [ ] Decision Log, Surprises, Outcomes updated; masterplan Progress checkboxes for EP-11
      ticked.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Represent a heterogeneous tool set with an **existential `SomeTool` wrapper plus
  a `ToolRegistry` keyed by tool name**, rather than (a) a heterogeneous list type / HList,
  (b) a single closed sum type the user must declare, or (c) a typeclass-per-tool.
  Rationale: a ReAct agent must hold tools of *different* `i`/`o` types in one collection and
  dispatch to them by the name the model emits at runtime. An existential `SomeTool` erases
  the `i`/`o` indices while *retaining*, inside the wrapper, the `FromJSON`/schema/`ToJSON`
  dictionaries needed to decode arguments and encode results — so the type information is not
  lost, just hidden behind a uniform interface (`toolName`, `toolSchema`, `runErased`). A
  registry (`Map Text SomeTool`) gives O(log n) dispatch by name and a single place to lower
  every tool to baikai's `Context.tools`. An HList would force the agent's type to enumerate
  every tool, defeating the point of runtime selection; a user-declared closed sum is boilerplate
  the Generic machinery should remove; a typeclass-per-tool cannot be put in a homogeneous
  container without the same existential. Date: 2026-06-08.

- Decision: The **native provider tool-calling path is preferred when available; a
  prompt-based tool protocol is the fallback**, selected by an explicit `ToolProtocol` value
  threaded into `react` (defaulting to `ProtocolAuto`). Rationale: provider-native function
  calling (baikai already models it: `Context.tools :: Vector Tool`, `Options.toolChoice`,
  and assistant `ToolCall` blocks) is more reliable than coaxing the model to emit a parseable
  action with prompt formatting, and reuses baikai's round-trip helpers (`appendToolResult`).
  But baikai's CLI providers (`AnthropicMessagesCli`, `OpenAICompletionsCli`) silently ignore
  tools, and some models lack good native support; for those we need a prompt fallback that
  renders an explicit action grammar and parses the model's text. Keeping the choice explicit
  (rather than auto-detecting silently) makes test runs deterministic and lets the same agent
  program be exercised against either seam. The native path also leans on the structured-output
  field added in `docs/plans/2-baikai-native-structured-output-extension.md` for the final
  *extract* step; until that lands, extract uses the prompt fallback. Date: 2026-06-08.

- Decision: **Loop termination is bounded by three independent guards, checked in this
  order: an explicit `finish` action from the model, a `maxIters` hard cap, and a `budget`
  (token/cost) cap.** Reaching `maxIters` or `budget` without a `finish` does *not* throw;
  it stops the loop and proceeds to the extract step with whatever trajectory was gathered,
  and records a `terminationReason` in the trajectory. Rationale: an unbounded agent loop is
  the classic failure mode; making all three guards explicit and non-fatal means the agent
  always returns a typed result (possibly a best-effort one) plus a trajectory explaining why
  it stopped, which is exactly what an evaluator/optimizer needs to score it. Date: 2026-06-08.

- Decision: **Tool execution errors are values, not exceptions.** A tool body returns
  `Eff es o` and may fail; decode failures, unknown-tool-name, and body exceptions are all
  caught and converted to a `ToolError` that is fed back to the model as a
  `toolResultErrorText` observation (so the model can recover) *and* recorded in the
  trajectory. The agent program as a whole only fails (`Left ShikumiError`) for
  infrastructure faults (provider/transport errors from baikai surfaced via the `LLM`
  effect), never for an individual bad tool call. Rationale: the masterblan integration point
  #1 mandates the shared shikumi error type and totality at the program boundary; a single bad
  argument from the model must not crash a multi-step agent. Date: 2026-06-08.

- Decision: ...
  Rationale: ...
  Date: ...


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This section assumes you know nothing about this repository. Read it fully before editing.

**The repositories.** You are working in the shikumi repository at
`/Users/shinzui/Keikaku/bokuno/shikumi`. Shikumi is a Haskell framework for building
language-model programs that behave like ordinary typed software. It is built *on top of* a
separate published Haskell library called **baikai**, at
`/Users/shinzui/Keikaku/bokuno/baikai`, which provides the entire provider/transport layer
(how a request reaches Anthropic/OpenAI/etc. and how the response comes back). Shikumi never
re-implements transport; it adds typed layers above it. To find baikai's source and docs on
disk, run `mori registry show shinzui/baikai --full` and `mori registry docs shinzui/baikai`
(the `mori` tool is the dependency-lookup utility configured in this environment; do not
guess baikai APIs from memory — read its source). Never traverse `/nix/store` or the
filesystem root.

**Where this plan sits.** This is EP-11 in a twelve-plan master plan at
`docs/masterplans/1-shikumi-typed-lm-programming-framework.md`. It is in Phase 4 (Agents &
DX). It **hard-depends** on two sibling plans that must be implemented first:
`docs/plans/4-typed-program-representation-and-core-modules.md` (which defines the
`Program i o` GADT and `runProgram`) and
`docs/plans/5-module-combinators-and-control-flow.md` (which defines combinators like
`Pipeline`/`Compose`, `Retry`, and `Validate`). It **soft-depends** on
`docs/plans/2-baikai-native-structured-output-extension.md` (native structured output added
to baikai) — soft meaning this plan can begin with a prompt-based fallback and switch to the
native path once EP-2 lands. It also relies on `docs/plans/1-...` (the `LLM` effect and the
shikumi error type) and `docs/plans/3-...` (the Generic JSON-schema generator). Because those
sibling plans may not yet be implemented when you read this, this Context section restates
the *exact* interfaces this plan depends on, in this plan's own words, and the Plan of Work
includes thin local shims you can drop in if a dependency is not yet present, so this plan is
self-contained.

**This plan owns integration point #8** from the master plan: `Tool i o` and its lowering to
`Baikai.Tool`. No other plan defines `Tool i o`; the CLI plan
(`docs/plans/12-cli-and-developer-experience.md`) will consume it for agent demos.

**Key terms used throughout, defined plainly.**

- *Tool*: a named capability the model can invoke during a conversation by emitting a
  structured "tool call" (a name plus a JSON arguments object). In baikai a tool is the
  untyped record `Baikai.Tool { name :: Text, description :: Text, parameters :: Value }`,
  where `parameters` is a JSON Schema carried as an `aeson` `Value` (the generic JSON type
  from the `aeson` library). Shikumi adds a *typed* tool `Tool i o` on top.

- *JSON Schema*: a JSON document that describes the shape of other JSON (object with these
  fields, of these types, these required). Providers use it to constrain or validate the
  arguments the model emits for a tool. We never write these by hand; the Generic generator
  from `docs/plans/3-...` produces them from a Haskell record type.

- *`aeson` `Value`*: the type `Data.Aeson.Value` — a tree of JSON (`Object`, `Array`,
  `String`, `Number`, `Bool`, `Null`). `ToJSON`/`FromJSON` are the encode/decode typeclasses.

- *`effectful` / `Eff es a`*: shikumi's runtime substrate is the `effectful` library. `Eff es
  a` is a computation returning `a` that requires the capabilities listed in the type-level
  list `es`. A capability is an *effect*; `LLM :> es` means "this computation may make
  language-model calls." `IOE :> es` means it may do arbitrary IO. We run effects with
  interpreters; we send operations with `Effectful.Dispatch.Dynamic.send`.

- *`LLM` effect*: defined by `docs/plans/1-...` in module `Shikumi.LLM`. It exposes a single
  provider-neutral call that wraps baikai's `completeRequest`. For this plan, the only thing
  we need is an operation that takes a baikai `Context` and `Options` and yields a baikai
  `Response` inside `Eff es`, mapping any `BaikaiError` into the shikumi error type. The exact
  shape this plan relies on is restated in Interfaces and Dependencies.

- *shikumi error type*: defined by `docs/plans/1-...` as `Shikumi.Error.ShikumiError`, an
  enumerated sum (invalid JSON, missing field, schema mismatch, validation failure, provider
  failure, timeout, budget exceeded). This plan adds *no* new top-level error constructors;
  tool-specific failures are a separate `ToolError` value carried *inside* the trajectory, and
  only infrastructure faults bubble up as `ShikumiError`.

- *`Signature i o`*: defined by `docs/plans/3-...`. A signature declares input fields,
  output fields, per-field descriptions, and an *instruction* (the natural-language task
  description) derived generically from records `i` and `o`. The instruction and any
  demonstrations are the *optimizable parameters*. ReAct in this plan *extends* a signature
  with trajectory fields, exactly as the master plan's integration point #3 anticipates.

- *`Program i o`*: defined by `docs/plans/4-...`. A typed GADT (generalized algebraic data
  type — a data type whose constructors carry their own type indices) that *is* the program
  represented as inspectable data. `runProgram :: (LLM :> es) => Program i o -> i -> Eff es
  o` interprets it. The GADT has constructors like `Predict :: Signature i o -> Params ->
  Program i o`, `Compose :: Program a b -> Program b c -> Program a c`, and `FMap :: (o ->
  o') -> Program i o -> Program i o'`. EP-4 also exposes a parameter-traversal interface so
  optimizers can read/rewrite per-node parameters. This plan adds ReAct *as a program* so it
  inherits all of that.

- *ReAct*: the agent loop described in Purpose. *Thought* = the model's short reasoning
  string for a step. *Action* = either "call tool X with these args" or "finish". *Observation*
  = the tool's result text fed back to the model. *Trajectory* = the recorded list of
  (thought, action, observation) steps plus a termination reason. *Extract* = a final
  model call that turns the finished trajectory into the typed output `o`.

**Current repository state.** When this plan is implemented, the canonical package layout
(established by `docs/plans/1-...`) will already exist: a `cabal.project` at the repo root, a
core `shikumi` package, and several satellite packages. This plan adds one new package,
`shikumi-tools`, with two modules: `Shikumi.Tool` and `Shikumi.Agent.ReAct`. If you open the
repo and find no Haskell yet (only `docs/` and `.claude/`), that means EP-1 has not run; you
must not start EP-11 before its hard dependencies exist. The first milestone below verifies
the prerequisites are present and fails loudly if they are not.


## Plan of Work

The work proceeds in five milestones. M0 is a spike that proves the package wires up against
its dependencies. M1 builds typed tools and the heterogeneous registry (this plan's owned
integration point). M2 builds the ReAct loop as a `Program`. M3 adds the native-vs-prompt
seam. M4 is the end-to-end acceptance test. Each milestone is independently verifiable with a
`cabal` command and a concrete observable result.

Throughout, all new files live under `shikumi-tools/`. The package exposes modules
`Shikumi.Tool` (the `Tool i o` type, registry, and lowering) and `Shikumi.Agent.ReAct` (the
agent). Tests live in `shikumi-tools/test/`. We never edit baikai in this plan; we only call
it.

### Dependency restatement and local shims

Because the hard-dependency plans may be partially implemented, this plan depends on a small,
*named* surface from each. Before M1, verify each symbol below exists by compiling a tiny probe
(M0). If a symbol is missing, the dependency plan is incomplete and you must complete it first;
do not stub the real `LLM` effect or the real `Program` GADT here — those are owned elsewhere
and shimming them would create two sources of truth. The *only* shim permitted in this package
is `Shikumi.Tool.SchemaShim` (described in M1), a thin re-export that lets schema derivation be
swapped between the real EP-3 generator and a minimal local generator *for tests of this package
in isolation*, retired the moment EP-3's generator is confirmed present.

The surface this plan consumes:

- From `Shikumi.Schema` (owner: `docs/plans/3-...`): a function that produces a JSON Schema
  `Value` from a type via `Generic`, and a total decoder from `Value` to that type with a
  precise error. This plan expects them under names equivalent to
  `toSchema :: forall a. (Generic a, GToSchema (Rep a)) => Proxy a -> Value` and
  `decodeSchema :: forall a. (Generic a, GFromValue (Rep a)) => Value -> Either Text a`.
  The exact constraint names belong to EP-3; this plan refers to the *capability* and binds to
  whatever EP-3 exports via a single import list in `Shikumi.Tool`, so a rename is a one-line
  change here.

- From `Shikumi.LLM` (owner: `docs/plans/1-...`): the `LLM` effect and an operation to run a
  baikai request. This plan expects `complete :: (LLM :> es) => Baikai.Context ->
  Baikai.Options -> Eff es Baikai.Response` (or `send (Complete ctx opts)` against the effect's
  GADT). It also expects `ShikumiError` and that infrastructure faults arrive as `Left
  ShikumiError` when the program is run with the error-handling interpreter.

- From `Shikumi.Signature` (owner: `docs/plans/3-...`): the `Signature i o` type with
  replaceable `instruction :: Text` and a way to add extra output fields (for the ReAct
  thought/action fields). This plan expects an `extendSignature` helper or equivalent; if EP-3
  exposes only the raw record, this plan adds a *local* combinator over the public fields, not a
  new type.

- From `Shikumi.Program` (owner: `docs/plans/4-...`): the `Program i o` GADT, `runProgram ::
  (LLM :> es) => Program i o -> i -> Eff es o`, the `predict` smart constructor, and the
  parameter-traversal interface. This plan expects a way to embed an *effatomic* (effectful but
  opaque) step into a `Program` so the tool loop can run inside `runProgram` while staying a
  node in the program tree. EP-4 must provide a constructor for this; the master plan calls the
  GADT "the single most important integration point" and lists EP-11 as a consumer, so this is
  expected. This plan refers to that constructor as `Embed` / `liftEff`; bind to EP-4's actual
  name in one import.

- From baikai (owner: the baikai repo): `Baikai.Tool`, `Baikai.ToolCall`, `Baikai.ToolResult`,
  `Baikai.ToolChoice`, `Baikai.Context`, `Baikai.Options`, `Baikai.Response`, the constructors
  `toolResultText`/`toolResultErrorText`, the helpers `appendToolResult`/`appendToolResultText`,
  `flattenAssistantBlocks`, `responseMessage`, and the lens-style record updates from
  `Baikai.Prelude` (`(&)`, `(.~)`, `#field`). Read `baikai/docs/user/tools.md` for the exact
  round-trip; this plan restates the essentials in M2.

- From `docs/plans/2-...` (soft): the new baikai `Options` field carrying a JSON schema /
  `response_format` for native structured output, plus how the structured response surfaces.
  Used only by the native extract path in M3. Until present, extract uses the prompt fallback.

### Milestone M0 — Spike: package skeleton compiles against dependencies

Scope: create the `shikumi-tools` package and prove it links. At the end of M0 there is a
buildable package exporting an empty-but-typed `Shikumi.Tool` module and a probe that
constructs a baikai `Tool` value and prints a Generic-derived schema, confirming every
dependency import resolves.

Create `shikumi-tools/shikumi-tools.cabal` declaring library modules `Shikumi.Tool` and
`Shikumi.Agent.ReAct`, depending on `base`, `shikumi`, `baikai`, `baikai-claude`,
`baikai-openai` (only if the native path needs a concrete provider in tests; otherwise omit
until M3), `aeson`, `effectful`, `text`, `containers`, `vector`, `lens`, `generic-lens`. Set
`default-language: GHC2024` and the same default extensions baikai uses (`DeriveAnyClass`,
`DuplicateRecordFields`, `OverloadedLabels`, `OverloadedStrings`), plus `GADTs`,
`ExistentialQuantification`, `ScopedTypeVariables`, `TypeApplications`, `DataKinds`,
`DerivingStrategies`. Add the package to the root `cabal.project` `packages:` stanza.

Write a temporary probe `shikumi-tools/app/Probe.hs` (an executable stanza you delete after
M0, or keep behind a flag) that imports the consumed surface and forces a Generic schema
derivation for a tiny record, printing it. Building the probe is the M0 acceptance: it proves
the schema generator, the `LLM` effect, the `Program` GADT, and baikai's tool types all
import and that the GHC2024/extension set is right.

Acceptance command, run from the repo root:

```bash
cabal build shikumi-tools
```

Expected: it compiles. If any consumed symbol is missing, the error names exactly which
dependency plan is incomplete — fix that plan first.

### Milestone M1 — Typed tools, schema lowering, and the heterogeneous registry

Scope: implement `Shikumi.Tool` fully. At the end of M1 you can define a `Tool WeatherReq
WeatherResp`, derive its argument schema, lower it to a `Baikai.Tool`, and round-trip a
`Baikai.ToolCall` (decode args → run → encode result) — with malformed arguments yielding a
typed `ToolError` instead of a crash. This is the milestone that delivers integration point
#8.

The typed tool type carries the function plus the dictionaries needed to derive the schema and
to decode/encode at the wire boundary:

```haskell
-- Shikumi.Tool

-- | A typed tool: a named function from input record @i@ to output @o@,
--   runnable in any effect stack that has the listed effects.
data Tool i o = Tool
  { toolName        :: !Text
  , toolDescription :: !Text
  , toolRun         :: !(forall es. (IOE :> es) => i -> Eff es o)
  }
```

The `forall es. (IOE :> es) =>` rank-2 field lets a tool body do IO (and, via additional
constraints discussed below, call the LM) while the tool itself stays a plain value the
registry can hold. To keep M1 simple and the registry homogeneous, the *minimal* tool body
runs in `IOE :> es`; a richer variant that also requires `LLM :> es` is offered as
`mkToolLLM` for tools that themselves call the model. The schema/encode/decode capabilities are
*not* stored as record fields but captured at construction time into the existential wrapper
(below), because storing them as `Tool` fields would force `Tool i o`'s type to mention the
`ToJSON`/`FromJSON`/schema constraints everywhere it is used.

Smart constructors capture the per-type dictionaries:

```haskell
-- | Build a tool from a pure-ish effectful function. Captures the
--   Generic schema for @i@, the decoder for @i@, and the encoder for @o@.
mkTool
  :: forall i o.
     ( Generic i, GToSchema (Rep i), GFromValue (Rep i), ToJSON o )
  => Text                                   -- ^ name
  -> Text                                   -- ^ description
  -> (forall es. (IOE :> es) => i -> Eff es o)
  -> Tool i o

-- | Convenience for tools whose body is plain IO.
mkToolIO :: (...) => Text -> Text -> (i -> IO o) -> Tool i o
```

The argument schema is derived once from `i`:

```haskell
toolSchemaOf :: forall i o. (Generic i, GToSchema (Rep i)) => Tool i o -> Value
```

and lowering produces baikai's wire tool by putting that schema into `parameters`:

```haskell
lowerTool :: forall i o. (Generic i, GToSchema (Rep i)) => Tool i o -> Baikai.Tool
lowerTool t =
  Baikai._Tool
    & #name        .~ toolName t
    & #description  .~ toolDescription t
    & #parameters  .~ toolSchemaOf t
```

(Use baikai's empty-base `_Tool` and generic-lens labels, matching `baikai/docs/user/tools.md`.)

**Heterogeneity — the existential and the registry.** A ReAct agent holds many tools with
different `i`/`o`. We erase the indices with an existential wrapper that *retains* the
capabilities needed at the wire boundary:

```haskell
-- | A tool with its input/output types hidden, but with the dictionaries
--   needed to (a) derive its schema, (b) decode args from JSON, and
--   (c) encode its result to text — all captured at wrap time.
data SomeTool where
  SomeTool
    :: ( Generic i, GToSchema (Rep i), GFromValue (Rep i), ToJSON o )
    => Tool i o
    -> SomeTool

-- Uniform accessors that work on the erased tool:
someToolName   :: SomeTool -> Text
someToolSchema :: SomeTool -> Value
lowerSomeTool  :: SomeTool -> Baikai.Tool

-- | Run an erased tool against a raw JSON arguments object: decode to the
--   hidden @i@, run the body, encode the @o@ to text. Total: returns
--   Left ToolError for bad args or a body failure, never throws to the caller.
runErased
  :: (IOE :> es)
  => SomeTool -> Value -> Eff es (Either ToolError Text)
```

A registry is just a name-keyed map plus its lowered baikai vector:

```haskell
newtype ToolRegistry = ToolRegistry (Map Text SomeTool)

mkRegistry        :: [SomeTool] -> ToolRegistry
registryLookup    :: Text -> ToolRegistry -> Maybe SomeTool
registryBaikai    :: ToolRegistry -> Vector Baikai.Tool   -- for Context.tools
registryNames     :: ToolRegistry -> [Text]
```

The typed error and the wire round-trip:

```haskell
data ToolError
  = ToolNotFound     !Text                 -- model named a tool we don't have
  | ToolArgsInvalid  !Text !Text           -- toolName, decode error message
  | ToolRunFailed    !Text !Text           -- toolName, exception text from the body
  deriving stock (Show, Eq)

-- | Top-level entry the ReAct loop uses: find the tool, decode, run, encode.
runToolCall
  :: (IOE :> es)
  => ToolRegistry -> Baikai.ToolCall -> Eff es (Either ToolError Text)
runToolCall reg tc =
  case registryLookup (Baikai.name tc) reg of
    Nothing  -> pure (Left (ToolNotFound (Baikai.name tc)))
    Just st  -> runErased st (Baikai.arguments tc)
```

Decoding inside `runErased` uses EP-3's `decodeSchema :: Value -> Either Text i`; a `Left`
becomes `ToolArgsInvalid`. Running the body is wrapped in `Effectful.Exception.try` (or
`UnliftIO.tryAny`) so a thrown exception in user code becomes `ToolRunFailed` rather than
propagating. Encoding the result to the observation text uses `ToJSON o` then a compact
encode; tools that want richer result blocks can later return via a variant that produces a
`Baikai.ToolResult` directly, but text is sufficient for the loop and for the acceptance test.

**Schema snapshot test.** Add `shikumi-tools/test/SchemaSpec.hs`. Define `WeatherReq { city
:: Text, units :: Text }`, build `weatherTool`, and assert `toolSchemaOf weatherTool`
equals the expected schema `Value`:

```json
{
  "type": "object",
  "properties": {
    "city":  { "type": "string" },
    "units": { "type": "string" }
  },
  "required": ["city", "units"]
}
```

Because EP-3 owns the exact rendering (e.g. whether it emits `additionalProperties`, field
order, descriptions), this test must assert on the *normalized* schema (compare after sorting
object keys and `required`) and the assertion's expected value must be written to match EP-3's
actual generator output — capture the real output once with the probe from M0 and freeze it.
Document in Surprises any difference between the idealized schema above and EP-3's real output.

**Bad-args test.** Assert that `runToolCall reg badCall` (where `badCall` has
`arguments = object ["city" .= "Paris"]`, missing `units`) returns
`Left (ToolArgsInvalid "get_weather" _)` and that the process does not throw. Also assert an
unknown name yields `Left (ToolNotFound "nope")`.

Acceptance command:

```bash
cabal test shikumi-tools-test --test-options="--match Schema"
cabal test shikumi-tools-test --test-options="--match Tool"
```

Expected: schema snapshot matches; malformed/unknown-tool calls return `Left ToolError`.

### Milestone M2 — ReAct as a `Program`, driven by a mock LM

Scope: implement `Shikumi.Agent.ReAct`. At the end of M2 you can write `react @Sig registry`
to get a `Program i o`, and `runProgram` it against a *mock LM* that scripts a tool call then a
finish, observing the typed answer and the recorded trajectory.

**The trajectory data model.** These are ordinary records (Generic, so EP-3 can render any that
appear as signature fields):

```haskell
-- Shikumi.Agent.ReAct

data Action
  = CallTool !Text !Value     -- tool name + raw arguments object the model proposed
  | Finish                    -- model declares it has enough to answer
  deriving stock (Show, Eq, Generic)

data Step = Step
  { thought     :: !Text
  , action      :: !Action
  , observation :: !(Maybe Text)   -- Nothing for Finish; tool result/ToolError text otherwise
  } deriving stock (Show, Eq, Generic)

data Termination
  = TerminatedFinish
  | TerminatedMaxIters !Int
  | TerminatedBudget
  deriving stock (Show, Eq, Generic)

data Trajectory = Trajectory
  { steps       :: !(Vector Step)
  , termination :: !Termination
  } deriving stock (Show, Eq, Generic)
```

**The ReAct configuration** carries the bounds and the protocol seam (M3 fills in the
protocol; M2 uses the prompt fallback so it can run against the mock LM without EP-2):

```haskell
data ReActConfig = ReActConfig
  { maxIters     :: !Int
  , protocol     :: !ToolProtocol         -- defined in M3; default ProtocolAuto
  , budget       :: !(Maybe Budget)       -- token/cost cap; reuses EP-1's budget if present
  }

defaultReActConfig :: ReActConfig
```

**Signature extension.** A ReAct agent's propose step is a `predict` over a *propose signature*
that takes the task input fields plus the trajectory-so-far and outputs `(thought, action)`.
The extract step is a `predict`/`chainOfThought` over the original output signature plus the
final trajectory. We build these by extending the user's `Signature i o`:

```haskell
-- Inputs of the propose call: original i fields + serialized trajectory + tool menu.
data ProposeIn  = ProposeIn  { task :: !Value, trajectory :: !Trajectory, tools :: ![ToolDoc] }
data ProposeOut = ProposeOut { thought :: !Text, action :: !Action }

-- Inputs of the extract call: original i + finished trajectory.
data ExtractIn  i = ExtractIn  { task :: !i, trajectory :: !Trajectory }
-- ExtractOut is the user's original o.

data ToolDoc = ToolDoc { name :: !Text, description :: !Text, schema :: !Value }
```

**The smart constructor and loop.** `react` produces a `Program i o`. The loop itself is an
effectful computation embedded into the program via EP-4's embed/lift constructor, so the agent
is one node in the program tree (and thus traversable/optimizable) yet runs inside
`runProgram`:

```haskell
react
  :: forall i o.
     ( Generic i, ToJSON i, Generic o, GFromValue (Rep o), GToSchema (Rep o) )
  => Signature i o
  -> ToolRegistry
  -> ReActConfig
  -> Program i o
```

Internally `react sig reg cfg = liftEff (\i -> reactLoop sig reg cfg i)` where `liftEff` is
EP-4's constructor for embedding an `(i -> Eff es o)` as a `Program i o` node, and:

```haskell
reactLoop
  :: (LLM :> es, IOE :> es)
  => Signature i o -> ToolRegistry -> ReActConfig -> i -> Eff es (o, Trajectory)
```

Note `reactLoop` returns `(o, Trajectory)`. To keep `react :: Program i o` while still exposing
the trajectory, provide two surface constructors: `react` (returns `o`, dropping the
trajectory) and `reactWithTrajectory :: ... -> Program i (o, Trajectory)`. The acceptance test
uses `reactWithTrajectory` so it can assert on the recorded steps; `react` is the ergonomic
default. Optimizers/evaluators that want the trajectory use the `(o, Trajectory)` form.

The loop, in prose: start with an empty `Trajectory`. Repeat, with `iter` from `0`:

1. If `iter >= maxIters cfg`, set `termination = TerminatedMaxIters iter` and break to extract.
   If `budget` is set and exceeded (consulting EP-1's budget accounting via the `LLM` effect),
   set `TerminatedBudget` and break.
2. Render the propose call (M3 decides native vs prompt). Issue it through the `LLM` effect.
   Parse `(thought, action)`.
3. If `action == Finish`, append a `Step thought Finish Nothing`, set `termination =
   TerminatedFinish`, break to extract.
4. Otherwise `action == CallTool name args`: run `runToolCall reg (ToolCall ... name args)`.
   On `Right obs`, append `Step thought (CallTool name args) (Just obs)`. On `Left toolErr`,
   append `Step thought (CallTool name args) (Just (renderToolError toolErr))` — the error text
   becomes the observation so the model can recover — and continue. Increment `iter`, loop.
5. Extract: render the extract call (original `i` + finished `Trajectory`), issue it through the
   `LLM` effect, decode the result into `o` with EP-3's `decodeSchema`. A decode failure here
   is an infrastructure-shaped failure of the agent's *final* answer; surface it as the shikumi
   error type (the loop has exhausted recovery), not as a `ToolError`.

**The mock LM.** To test without a provider, supply an interpreter for the `LLM` effect that
returns scripted baikai `Response` values. Add `shikumi-tools/test/MockLLM.hs`:

```haskell
-- A script is a list of canned responses, consumed in order.
runMockLLM :: [Baikai.Response] -> Eff (LLM : es) a -> Eff es a
```

The script for the acceptance scenario is: response #1 is an assistant message whose content is
a single `AssistantToolCall (ToolCall "1" "get_weather" (object ["city" .= "Paris", "units" .=
"c"]))` (native path) *or*, on the prompt path, an assistant text block containing the rendered
action grammar (M3). Response #2 (after the observation is appended) is an assistant text/tool
that yields `Finish`. Response #3 is the extract answer, an assistant message whose text/JSON
decodes into `WeatherResp`. The mock simply hands these out in sequence; the loop's own logic
decides when to call which.

**M2 end-to-end test.** Add `shikumi-tools/test/ReActSpec.hs`. Build `reactWithTrajectory
weatherSignature registry defaultReActConfig`, run it with `runMockLLM script` over the input
`AnswerWeatherQuestion { question = "What's the weather in Paris?" }`, and assert: the returned
`o` is the expected `WeatherResp`; the trajectory has two steps (one `CallTool "get_weather"`,
one `Finish`); the `CallTool` step's `observation` is `Just` the encoded weather; and
`termination == TerminatedFinish`. Add a second test with `maxIters = 1` and a script that
never finishes, asserting `termination == TerminatedMaxIters 1` and that a (best-effort) `o`
still comes back from extract.

Acceptance command:

```bash
cabal test shikumi-tools-test --test-options="--match ReAct"
```

Expected: both ReAct tests pass; you see a typed `WeatherResp` and a two-step trajectory.

### Milestone M3 — The native-vs-prompt tool-protocol seam

Scope: make the propose/extract rendering pluggable between provider-native function calling
and a prompt-based protocol, with explicit selection. At the end of M3 the same `react` program
runs under either seam, and the choice is a value, not a recompile.

The selector and the seam:

```haskell
data ToolProtocol
  = ProtocolNative    -- use baikai Context.tools + Options.toolChoice; parse ToolCall blocks
  | ProtocolPrompt    -- render an action grammar into the prompt; parse the model's text
  | ProtocolAuto      -- prefer Native when the model/provider supports tools, else Prompt
```

`ProtocolAuto` resolves at run time by inspecting the baikai `Model`/`Api` reachable through
the `LLM` effect: CLI APIs (`AnthropicMessagesCli`, `OpenAICompletionsCli`) and any model
without tool support resolve to `ProtocolPrompt`; everything else to `ProtocolNative`. Document
that resolution is conservative — when in doubt, prompt — because a silently-dropped native
tool set (which baikai does for CLI providers) would make the agent loop forever proposing
tools that never execute.

**Native path.** For the propose step, set `Context.tools = registryBaikai reg` and
`Options.toolChoice`. On the *first* propose turn use `ToolChoiceAuto` (let the model decide to
act or finish); model "finish" is expressed natively by the model emitting an assistant text
answer with *no* tool call, which we map to `Finish`. A tool call block maps to `CallTool name
arguments`, taking `arguments` straight from `ToolCall.arguments` (already parsed JSON — no
re-parsing). The observation is appended using baikai's `appendToolResult` /
`appendToolResultText` (read `baikai/docs/user/tools.md`): these pull the assistant's tool-call
blocks out of the response, run a dispatcher per call, and return a new `Context` with the
assistant message and one `ToolResultMessage` per call appended. The dispatcher we pass is `\tc
-> toolResultOf <$> runToolCall reg tc`, where `toolResultOf` turns `Right obs` into
`toolResultText obs` and `Left err` into `toolResultErrorText (renderToolError err)`. This is
precisely the round-trip from baikai's docs, with our typed decode/dispatch in the middle.

For the *extract* step on the native path, prefer EP-2's structured output: attach the JSON
schema derived from the output type `o` (via `toSchema (Proxy @o)`) to the request's
`response_format`/schema `Options` field (the field shape owned by `docs/plans/2-...`), set
`toolChoice = ToolChoiceNone` so the model answers instead of calling tools, and decode the
structured response into `o`. If EP-2 is not yet present, fall back to the prompt-based extract
(below). This is the soft dependency seam: the native extract is strictly better but optional.

**Prompt path.** When EP-2 is absent or the model lacks native tools, render a textual protocol.
The propose prompt lists the tool menu (`registryNames` + each `ToolDoc.schema`) and instructs
the model to reply with exactly one fenced JSON object of the form:

```json
{ "thought": "…", "action": { "tool": "get_weather", "args": { "city": "Paris", "units": "c" } } }
```

or, to finish:

```json
{ "thought": "…", "action": { "finish": true } }
```

Parsing extracts the JSON, decodes `thought` and `action` (mapping `{tool,args}` to `CallTool`
and `{finish:true}` to `Finish`). A parse failure on the propose step is treated like a tool
error: append a corrective observation ("Your reply was not valid action JSON; reply with …")
and let the model retry on the next iteration, still bounded by `maxIters`. The extract prompt
asks for a fenced JSON object matching `o`'s schema and decodes it with `decodeSchema`.

The renderers are two implementations of one internal interface so the loop body is
protocol-agnostic:

```haskell
data ProtocolImpl = ProtocolImpl
  { renderPropose :: ProposeIn  -> (Baikai.Context, Baikai.Options)
  , parsePropose  :: Baikai.Response -> Either Text ProposeOut
  , appendObs     :: Baikai.Context -> Baikai.Response -> ToolRegistry -> IO Baikai.Context
  , renderExtract :: ExtractIn i -> (Baikai.Context, Baikai.Options)
  , parseExtract  :: Baikai.Response -> Either Text o
  }

resolveProtocol :: ToolProtocol -> Baikai.Model -> ProtocolImpl i o
```

`reactLoop` calls only this interface, so M2's loop is unchanged; M3 only adds the two
implementations and the resolver.

**M3 tests.** Duplicate the M2 ReAct test twice: once forcing `protocol = ProtocolNative` with
a script of native tool-call/finish responses, once forcing `protocol = ProtocolPrompt` with a
script of text responses carrying the action JSON. Assert both produce the same typed
`WeatherResp` and an equivalent two-step trajectory. Add a test that `resolveProtocol
ProtocolAuto cliModel` selects the prompt impl (using a baikai model whose `Api` is
`AnthropicMessagesCli`).

Acceptance command:

```bash
cabal test shikumi-tools-test --test-options="--match Protocol"
```

Expected: native and prompt paths both yield the typed answer; `ProtocolAuto` picks prompt for
a CLI model.

### Milestone M4 — Acceptance: the full scenario, plus `cabal test all`

Scope: assemble the headline acceptance test and confirm the whole workspace builds and tests.
At the end of M4 the package is feature-complete for this plan.

Add `shikumi-tools/test/AcceptanceSpec.hs` that mirrors Purpose exactly: define `WeatherReq`,
`WeatherResp`, `AnswerWeatherQuestion` (the agent input) with its output type; build
`weatherTool` and `mkRegistry [SomeTool weatherTool]`; build `reactWithTrajectory
answerWeatherSignature registry defaultReActConfig`; run it with the mock LM script (tool call
→ finish → extract) under both protocols; assert (1) the typed `WeatherResp` final answer, (2)
the recorded `Trajectory` with the expected steps and `TerminatedFinish`, (3)
`toolSchemaOf weatherTool` equals the frozen expected schema, and (4) a separate run feeding
malformed arguments produces `Left ToolError` recorded as an observation and the agent still
returns (the model recovers), with *no* exception escaping.

Acceptance command, run from the repo root:

```bash
cabal test all
```

Expected: all packages build; `shikumi-tools-test` reports every spec passing, including the
acceptance spec. The acceptance is the observable behavior described in Purpose, demonstrated
without any live provider call.

After M4, update this plan's Progress, Surprises, Decision Log, and Outcomes, and tick the
masterplan's EP-11 Progress checkbox
(`docs/masterplans/1-shikumi-typed-lm-programming-framework.md`).


## Concrete Steps

Run everything from the shikumi repo root `/Users/shinzui/Keikaku/bokuno/shikumi` unless
stated otherwise.

First confirm the prerequisites exist (their absence means a hard dependency is unimplemented):

```bash
ls docs/plans/4-typed-program-representation-and-core-modules.md
ls docs/plans/5-module-combinators-and-control-flow.md
cabal build shikumi          # the core package must already build (EP-1/EP-3/EP-4/EP-5)
```

Expected: the core `shikumi` package builds. If it does not, stop and complete the depended-on
plans first.

Locate baikai's source/docs to read exact APIs (do not guess):

```bash
mori registry show shinzui/baikai --full
mori registry docs shinzui/baikai
```

Create the package and add it to the workspace, then drive each milestone with the acceptance
commands listed above:

```bash
# M0
cabal build shikumi-tools

# M1
cabal test shikumi-tools-test --test-options="--match Schema"
cabal test shikumi-tools-test --test-options="--match Tool"

# M2
cabal test shikumi-tools-test --test-options="--match ReAct"

# M3
cabal test shikumi-tools-test --test-options="--match Protocol"

# M4
cabal test all
```

A passing M4 run looks roughly like:

```text
shikumi-tools-test
  Schema
    derives WeatherReq argument schema [✔]
  Tool
    decodes valid args and runs the body [✔]
    returns ToolArgsInvalid for missing field [✔]
    returns ToolNotFound for unknown name [✔]
  ReAct
    runs tool then finish; returns typed answer + trajectory [✔]
    stops at maxIters with TerminatedMaxIters [✔]
  Protocol
    native and prompt paths agree on the typed answer [✔]
    ProtocolAuto picks prompt for a CLI model [✔]
  Acceptance
    typed tool + ReAct + mock LM end-to-end [✔]
    malformed args become a recorded ToolError, no crash [✔]

All N tests passed.
```


## Validation and Acceptance

The plan is accepted when, from the repo root, `cabal test all` passes and the
`shikumi-tools-test` suite demonstrates the behavior from Purpose. Concretely, the acceptance
spec must show all four observable facts: a typed `WeatherResp` is returned from a ReAct run
driven by a mock LM (no live provider); the returned `Trajectory` records the tool call and the
finish with `TerminatedFinish`; `toolSchemaOf weatherTool` equals the frozen expected JSON
Schema for `WeatherReq`; and a run with malformed tool arguments yields a `Left ToolError`
captured as an observation while the agent still returns a typed value and throws nothing.

Beyond compilation, the value is demonstrated by the failing-before/passing-after property:
before M1, no `Tool i o` exists and there is nothing to test; after M1 the schema/round-trip
tests pass; before M2 there is no agent; after M2 the mock-LM end-to-end test passes; M3 proves
both protocol seams reach the same typed answer; M4 ties it together. Each milestone's
acceptance command above produces the named passing spec, which is the human-verifiable
behavior.

To exercise it manually against a real provider (optional, not part of CI), swap `runMockLLM`
for the real `LLM` interpreter from `docs/plans/1-...` configured with a baikai `Model` (e.g.
`Models.anthropic_claude_sonnet_4_6` or `Models.openai_gpt_4o_mini`) and a real API key via
baikai's `ApiKeySource`, force `ProtocolNative`, and run the same `react` program over a real
weather question; you should observe a tool call, a real observation, and a decoded
`WeatherResp`.


## Idempotence and Recovery

All steps are additive and safe to repeat. Re-running `cabal build` / `cabal test` is
idempotent. Creating the package is idempotent if you guard file creation (the `.cabal` and
module files are written once; re-running edits is fine). The temporary `app/Probe.hs` from M0
can be deleted at any time after M0; if you keep it behind a cabal flag it does not affect the
library or tests. The schema snapshot's expected value is *frozen from EP-3's real output*; if
EP-3's generator changes its rendering later, the snapshot test will fail loudly — re-capture
the expected value with the probe and record the change in Surprises. No step is destructive; no
migrations or external services are involved (the mock LM removes any network dependency from
CI). If a milestone half-completes, the Progress checklist records exactly which sub-step is
done, and re-running that milestone's acceptance command shows the current state.


## Interfaces and Dependencies

Libraries and why: `baikai` (the wire `Tool`/`ToolCall`/`ToolResult`, the round-trip helpers
`appendToolResult`/`appendToolResultText`, `flattenAssistantBlocks`, `responseMessage`, and
`Context`/`Options`/`Response`/`Model`/`Api`/`ToolChoice`); `shikumi` core (the `LLM` effect and
`ShikumiError` from `Shikumi.LLM`/`Shikumi.Error` owned by `docs/plans/1-...`; the Generic
schema generator and total decoder from `Shikumi.Schema` and the `Signature i o` from
`Shikumi.Signature`, both owned by `docs/plans/3-...`; the `Program i o` GADT, `runProgram`,
`predict`, the parameter-traversal interface, and the embed/lift constructor from
`Shikumi.Program`/`Shikumi.Module` owned by `docs/plans/4-...`; combinators from
`Shikumi.Combinator` owned by `docs/plans/5-...`); `effectful` (the `Eff es`/`IOE`/effect
machinery); `aeson` (`Value`, `ToJSON`/`FromJSON`, encode); `containers` (`Map` for the
registry); `vector` (baikai's `Context.tools`/`messages` are `Vector`); `text`; `lens` +
`generic-lens` (baikai's record-update style, re-exported by `Baikai.Prelude`).

Types and signatures that must exist at the end of each milestone (full module paths):

- End of M0: package `shikumi-tools` builds; modules `Shikumi.Tool` and `Shikumi.Agent.ReAct`
  exist (may be near-empty); `shikumi-tools` is listed in the root `cabal.project`.

- End of M1, in `Shikumi.Tool`: `data Tool i o`; `mkTool`, `mkToolIO` (and optionally
  `mkToolLLM`); `toolName`, `toolDescription`, `toolSchemaOf`; `lowerTool :: Tool i o ->
  Baikai.Tool`; `data SomeTool` (existential) with `someToolName`, `someToolSchema`,
  `lowerSomeTool`, `runErased`; `newtype ToolRegistry` with `mkRegistry`, `registryLookup`,
  `registryBaikai :: ToolRegistry -> Vector Baikai.Tool`, `registryNames`; `data ToolError =
  ToolNotFound Text | ToolArgsInvalid Text Text | ToolRunFailed Text Text`; `runToolCall ::
  (IOE :> es) => ToolRegistry -> Baikai.ToolCall -> Eff es (Either ToolError Text)`;
  `renderToolError :: ToolError -> Text`.

- End of M2, in `Shikumi.Agent.ReAct`: `data Action = CallTool Text Value | Finish`; `data
  Step`; `data Termination`; `data Trajectory`; `data ReActConfig` with `defaultReActConfig`;
  `react :: (...) => Signature i o -> ToolRegistry -> ReActConfig -> Program i o`;
  `reactWithTrajectory :: (...) => Signature i o -> ToolRegistry -> ReActConfig -> Program i (o,
  Trajectory)`; the internal `reactLoop :: (LLM :> es, IOE :> es) => Signature i o ->
  ToolRegistry -> ReActConfig -> i -> Eff es (o, Trajectory)`. In `shikumi-tools/test/`:
  `MockLLM.runMockLLM :: [Baikai.Response] -> Eff (LLM : es) a -> Eff es a`.

- End of M3, in `Shikumi.Agent.ReAct`: `data ToolProtocol = ProtocolNative | ProtocolPrompt |
  ProtocolAuto`; `data ProtocolImpl i o`; `resolveProtocol :: ToolProtocol -> Baikai.Model ->
  ProtocolImpl i o`; the native and prompt implementations wired into `reactLoop`. The native
  extract path attaches the schema from `toSchema (Proxy @o)` to the EP-2 `response_format`
  `Options` field when present, else falls back to the prompt extract.

- End of M4: `shikumi-tools/test/AcceptanceSpec.hs` exercising the full Purpose scenario; `cabal
  test all` green.

Integration-point contract restated for downstream consumers: this plan *owns* integration
point #8. `Tool i o` is defined only here. `lowerTool`/`lowerSomeTool` are the single sanctioned
way to turn a typed tool into a `Baikai.Tool`; the argument schema in `Baikai.Tool.parameters`
always comes from EP-3's generator applied to `i`. The CLI plan
(`docs/plans/12-cli-and-developer-experience.md`) consumes `Tool`, `SomeTool`, `ToolRegistry`,
and `react`/`reactWithTrajectory` for agent demos; it must not redefine any of them.
