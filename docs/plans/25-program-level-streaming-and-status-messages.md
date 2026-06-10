---
id: 25
slug: program-level-streaming-and-status-messages
title: "Program-level streaming and status messages"
kind: exec-plan
created_at: 2026-06-09T22:35:42Z
intention: "intention_01ktq812wfebgvf1dtbvg3v826"
master_plan: "docs/masterplans/4-shikumi-richer-io-and-multimodal.md"
---

# Program-level streaming and status messages

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Today a Shikumi program runs to completion behind a single blocking call. You hand
`runProgram` a typed input, it issues one or more language-model (LM) requests, waits for
each whole answer, and finally hands you back a typed output. While the program is running you
see nothing: no partial text as the model writes it, no signal that a sub-step started or
finished. This is fine for batch jobs but poor for anything a person watches — a chatbot, an
agent, a long generation — where you want to print tokens as they arrive and show "calling
the model…", "model finished…".

The transport layer underneath Shikumi (the `baikai` library) already supports this. Its
streaming operation `StreamEach` hands you each incremental event — a chunk of text, a
"block started", a "done" — as the provider produces it. Shikumi's own `LLM` effect even
declares a `Stream` operation. But nothing above the transport exposes streaming at the level
a program author can use: `runProgram` only ever calls the blocking `complete`, and the
`Stream` operation is dead weight — defined but never wired into program execution.

After this change a Shikumi user can do something they cannot do today: run a program through
a **new, additive streaming entry point** — `streamProgram` — and receive a sequence of
**events** as the program executes. Each event is one of:

  * a **field chunk** — a piece of one of the program's output fields, as the model writes it
    (for the headline single-`Predict` case, the output field's text, delivered in the order
    the provider streamed it); or
  * a **status message** — a human-readable signal that a phase started or ended: "LM call
    started", "LM call finished", and (for programs that call tools) "tool started", "tool
    finished".

The caller supplies a callback; `streamProgram` invokes it once per event, in order, as
events arrive, and **still returns the fully-decoded typed output** — identical to what
`runProgram` would have returned for the same input. Streaming is purely additive: it does not
change `runProgram`, `runProgramConc`, or any existing type. The blocking contract that the
rest of the framework relies on (MasterPlan integration point #4) is untouched.

You can see it working without any network. Under a hermetic stub that scripts the streaming
events `["Hel", "lo"]` followed by a terminal "done", running a one-field `Predict` program
through `streamProgram` makes the callback receive, in order: a status event "LM call
started", a field chunk `"Hel"`, a field chunk `"lo"`, a status event "LM call finished"; and
`streamProgram` returns the same typed value `runProgram` would return for that response.

This plan deliberately scopes the **field-chunk** path to where chunking is honest and
achievable — a single `Predict` node (or a straight chain of them) whose output is read as
raw text — and is explicit about where it is not (native whole-JSON structured output, where
the field arrives all-at-once). Status messages, by contrast, can bracket every node,
including composites and tool calls. The headline demo is the single-`Predict` field stream;
multi-node behavior is documented honestly as "status messages bracket sub-nodes; field chunks
come from the leaf LM call".


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1: Add `StreamEvent`, `StatusPhase`, `FieldChunk` types and a `streamComplete` helper
      that drives the `LLM` effect's `Stream` op and folds baikai `AssistantMessageEvent`s
      into `StreamEvent`s, in a new module `Shikumi.Stream`. New test module `StreamSpec`
      proves a scripted stub LLM emitting `["Hel","lo"]` yields the expected `StreamEvent`s.
- [x] M2: Add `streamProgram` for a single `Predict` node: emit `LmStart`, stream the output
      field's chunks (via the fallback/raw text path), emit `LmEnd`, and return the typed
      `o` equal to `runProgram`'s result. Extend `StreamSpec` with the headline acceptance.
- [x] M3: Bracket sub-nodes and tool calls with status messages through composite programs
      (`Compose`, `FMap`, `Embed`, etc.), reusing trace span-kinds as the phase vocabulary,
      with field chunks attributed to leaf `Predict` calls. Document multi-node honesty.
      Extend `StreamSpec` with a chained-`Predict` acceptance.
- [x] Wire `StreamSpec` into `shikumi/test/Main.hs` and the cabal `other-modules`.
- [x] Final audit: `cabal test shikumi` green (117 tests); `cabal test all` green;
      Progress/Decision Log/Outcomes updated.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **`Response.message` is an `AssistantPayload`, but the terminal event's `message`
  is a `Message`.** Reassembling a `Response` from a stream's terminal event means
  matching `EventDone (TerminalPayload _ (AssistantMessage payload))` to pull the
  `AssistantPayload` out of the `Message`, then `_Response & #message .~ payload`.
  (`Baikai.Response.Response.message :: AssistantPayload`;
  `Baikai.Message.Message = … | AssistantMessage AssistantPayload | …`.) `reassemble`
  in `Shikumi.Stream` does exactly this, with a `synthResponse` fallback built from
  the first `TextEnd` content if no terminal assistant message is present.
- **`Validatable o` is a redundant constraint anywhere `adapterFor` is called.**
  Because `Shikumi.Schema` ships a universal `instance {-# OVERLAPPABLE #-}
  Validatable a`, `Validatable o` is always dischargeable, so GHC's
  `-Wredundant-constraints` flags it on a helper like `streamPredict` even though
  `adapterFor`'s own signature lists it. Dropped from `streamPredict`'s context
  (the wire path still validates via `fromModelChecked` inside the adapter's
  `parse`). No behavior change.
- **`FieldChunk.fieldName` collides with `FieldMeta.fieldName`.** Both are record
  selectors named `fieldName` (DuplicateRecordFields is on workspace-wide), so
  `Shikumi.Stream` imports `Shikumi.Schema.Types` qualified (`ST`) and writes
  `ST.fieldName` when reading a signature's output-field names, keeping its own
  `FieldChunk.fieldName` selector unambiguous.
- **`streamProgram`'s `Predict` overlay had to be replicated.** `runProgram`'s
  internal `effectiveSignature`/`runPredict` are not exported from
  `Shikumi.Program`, so `Shikumi.Stream` re-implements the small `Params` overlay
  (`effectiveSig`: instruction override + JSON-demo decode). It reuses the exported
  `retryWith`/`acceptOrReject` for the `Retry`/`RetryWhen`/`Validate` branches so
  those nodes' semantics match `runProgram` exactly while still streaming their leaf
  predicts.
- **Tool-status is demonstrated at the callback boundary, as scoped.** An `Embed`
  body is opaque to `streamProgram` (it runs blocking with `NodeStart`/`NodeEnd`
  only), so `ToolStart`/`ToolEnd` cannot be auto-surfaced from inside a ReAct loop
  yet. The acceptance proves the *event variants flow through the callback in
  order* by emitting them directly — matching the plan's honest scoping; a future
  agent integration threads the callback into the loop.


## Decision Log

Record every decision made while working on the plan.

- Decision: Use a **callback-per-event** entry point
  (`streamProgram :: ... => Program i o -> i -> (StreamEvent -> Eff es ()) -> Eff es o`)
  rather than a materialized `[StreamEvent]` result.
  Rationale: it mirrors baikai's `StreamEach :: ... -> (AssistantMessageEvent -> m ()) -> ...`
  higher-order shape exactly; it preserves incrementality (events reach the caller as they
  arrive, not after buffering); the caller's callback runs in their own `Eff es`, so they may
  print, accumulate into an `IORef`, or push to a channel; and it still returns the typed `o`
  so the streamed run and the blocking run are interchangeable.
  Date: 2026-06-09.
- Decision: Model the event as a sum `StreamEvent = StreamFieldChunk FieldChunk | StreamStatus
  Status`, mirroring DSPy's `StreamResponse` (field chunk: `predict_name`,
  `signature_field_name`, `chunk`, `is_last_chunk`) and `StatusMessage`.
  Rationale: it is the smallest type that surfaces both of DSPy's streaming concepts in one
  callback, and keeps the two cleanly distinguishable for the caller.
  Date: 2026-06-09.
- Decision: Scope the **field-chunk** headline to a single `Predict` node (and chains of them)
  whose output the **fallback / raw-text** path can attribute to a field; do not promise
  field-level chunking for the **native whole-JSON** path.
  Rationale: baikai streams text deltas, but native structured output arrives as one JSON blob
  that is only parseable once whole — per-field chunking there would require partial-JSON
  parsing (DSPy does this with `jiter`; we do not have that machinery and the dossier records
  `attachSchema` as a no-op, so the native path is not even exercised on the wire yet). The
  fallback `[[ ## field ## ]]` adapter and raw single-field outputs chunk naturally. We deliver
  what is honest and document the rest.
  Date: 2026-06-09.
- Decision: Reuse the streaming machinery on top of the **existing** `LLM` effect `Stream`
  operation (`Stream :: Model -> Context -> Options -> LLM m [AssistantMessageEvent]`) rather
  than adding a new effect operation in M1; M3 evaluates whether a per-event `StreamEach`-shaped
  `LLM` operation is needed and records the outcome.
  Rationale: the dossier (section D.2, J.6) confirms the `Stream` op exists but is unused by
  `runProgram`; reusing it keeps the change additive and avoids touching the effect's
  constructor set (which would ripple into every interpreter). The materializing `Stream` op
  delivers all events; M1 folds that list into `StreamEvent`s and replays them through the
  callback, preserving order. See Surprises if this proves to lose incrementality and must be
  revisited.
  Date: 2026-06-09.
- Decision: Borrow the phase vocabulary from the trace layer's `SpanKind`
  (`ProgramSpan | ModuleSpan | CombinatorSpan | LlmCallSpan`, per dossier section G.1) for
  status messages where natural, but keep `StatusPhase` a small self-contained enum in this
  plan's module so `Shikumi.Stream` does not take a hard dependency on the `shikumi-trace`
  package.
  Rationale: the streaming surface should stand alone; trace is a sibling package, and adding a
  build edge to it for a four-constructor enum is not worth the coupling.
  Date: 2026-06-09.
- Decision (M3 outcome): Do **not** add a per-event, `StreamEach`-shaped operation
  to the `LLM` effect; keep building on the existing materializing `Stream` op.
  Rationale: adding `StreamEach :: Model -> Context -> Options ->
  (AssistantMessageEvent -> m ()) -> LLM m ()` would be additive to the `LLM`
  constructor set but would force *every* interpreter (`runLLM`, `runLLMWith`,
  `runLLMResilient`, the test mocks, the routing/cache/trace re-interpreters) to
  pattern-match it — a broad ripple for no behavioral gain in the hermetic and
  current live paths, where `Stream` already delivers every event and
  `streamComplete` folds the list into ordered callbacks. The materialize-then-replay
  shape preserves event order (the helper's contract) and is sufficient for finite
  scripted streams and for a single provider call. If true incremental delivery
  against a live provider becomes necessary, the per-event op can be added later as a
  separate, additive change. Recorded here per the plan's M3 instruction.
  Date: 2026-06-09.
- Decision: Soft-depend on EP-14 (ambient routing,
  `docs/plans/14-ambient-model-routing-and-live-native-structured-output.md`) only for the
  live demo; build and verify everything against a hermetic stub streaming LM first.
  Rationale: MasterPlan integration point #4 marks routing as a soft edge; the streaming
  machinery is demonstrable end-to-end against a scripted event source with no network and no
  routing. The live path against a real model is a clearly-labeled optional extension.
  Date: 2026-06-09.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

**Delivered (2026-06-09).** All milestones complete; `cabal test shikumi` green
(117 tests, +5 `StreamSpec`) and `cabal test all` green. Against the Purpose:

- **A new, additive streaming entry point exists.** `streamProgram :: (LLM :> es,
  Error ShikumiError :> es) => Program i o -> i -> (StreamEvent -> Eff es ()) -> Eff
  es o` in the new module `Shikumi.Stream`, plus the lower-level `streamComplete`
  for one LM call. `runProgram`/`runProgramConc` and the `LLM` effect are unchanged
  (integration point #4 honored) — streaming is parallel surface over the same decode.
- **Field chunks and status messages both reach the caller.** A single `Predict`
  streams its first output field's text deltas as `StreamFieldChunk`s bracketed by
  `LmStart`/`LmEnd`; composites bracket with `NodeStart`/`NodeEnd`. A chained
  `predict >>> predict` streams both leaves' fields in order. The decisive fidelity
  proof — the streamed return value asserted **equal** to `runProgram`'s for the same
  scripted events — passes for both the single-`Predict` and the chained case.
- **Scope is honest.** Field chunks are delivered on the prompt-fallback/raw-text
  path (the exercised path, since the placeholder model maps to the fallback
  adapter); native whole-JSON field chunking is explicitly not promised. Aggregating
  combinators (`Map`/`Parallel`/`MajorityVote`/`Ensemble`) and opaque `Embed` bodies
  stream status only. The chunk text is the raw provider delta. All of this is stated
  in the `Shikumi.Stream` module haddock.

**Gaps / known limitations (by design):**

- Tool-level status from inside an `Embed`/ReAct body is not auto-surfaced (the body
  is opaque); the `ToolStart`/`ToolEnd` variants exist and are proven to flow through
  the callback, ready for a future agent integration that threads the callback in.
- Delivery is materialize-then-replay over the existing `Stream` op (event order
  preserved); a per-event `StreamEach` `LLM` op was evaluated and deliberately not
  added (see Decision Log).
- The optional live demo against a real model (soft-dep on MP-2 EP-14 routing) is not
  implemented; everything is verified hermetically, and the live path is a clearly
  network-gated future extension.

**Lessons.** The main friction was baikai's payload shapes (terminal `Message`
vs. `Response.message :: AssistantPayload`) and three workspace-wide ergonomics
(`DuplicateRecordFields` selector collision on `fieldName`; the universal
`Validatable` instance making that constraint redundant; non-exported `runPredict`
internals needing a small replicated overlay). All recorded in Surprises & Discoveries.


## Context and Orientation

This section assumes you know nothing about this repository. Read it fully before editing.

Shikumi is a Haskell framework for writing typed programs that call language models. It is a
Cabal project; the core library lives under `shikumi/src/Shikumi/` and its tests under
`shikumi/test/`. All builds and tests run inside a Nix development shell — see Concrete Steps.

The terms below are used throughout. Each is defined here because the plan relies on them.

**Effect / `Eff es`.** Shikumi uses the `effectful` library. An effectful computation has type
`Eff es a`, where `es` is a type-level list of capabilities ("effects") the computation may
use. A constraint like `(LLM :> es)` reads "the effect row `es` includes the `LLM`
capability". You interpret (run) an effect by peeling it off the row with an interpreter
function. You do not need to understand `effectful` deeply; copy the patterns shown here.

**The `LLM` effect.** Defined in `shikumi/src/Shikumi/LLM.hs`. It is the provider-neutral
language-model capability every program uses. Its two operations are:

```haskell
data LLM :: Effect where
  Complete :: Model -> Context -> Options -> LLM m Response
  Stream :: Model -> Context -> Options -> LLM m [AssistantMessageEvent]
```

and the two call-site helpers:

```haskell
complete :: (LLM :> es) => Model -> Context -> Options -> Eff es Response
stream :: (LLM :> es) => Model -> Context -> Options -> Eff es [AssistantMessageEvent]
```

`Complete` blocks and returns one whole `Response`. `Stream` returns the **assembled list** of
streaming events (it does not call back per event; it folds the stream into a list). The
crucial fact this plan acts on: **`runProgram` only ever calls `complete`; nothing calls
`stream` during program execution.** The `Stream` operation is defined but unused by program
runs. (Confirmed in `shikumi/src/Shikumi/LLM.hs` lines 84–97 and `shikumi/src/Shikumi/Program.hs`
`runPredict`, which calls `complete`.)

**`Model`, `Context`, `Options`, `Response`.** These are baikai request/response types,
re-exported from `Shikumi.LLM`. `Context` carries a system prompt and a list of messages.
`Options` carries request knobs (max tokens, temperature, …). `Response` carries the
assistant's reply. You build them via Shikumi's adapter, never by hand, in program code.

**`AssistantMessageEvent`.** The streaming event algebra, defined in
`baikai/baikai/src/Baikai/Stream/Event.hs` and re-exported from `Shikumi.LLM`. A streaming call
emits a sequence of these. The shape, copied from source, is:

```haskell
data AssistantMessageEvent
  = EventStart StartPayload          -- first event; carries an empty message skeleton
  | TextStart IndexPayload           -- a text block is about to receive deltas
  | TextDelta DeltaPayload           -- a chunk of text appended to a text block
  | TextEnd BlockEndPayload          -- a text block closed; carries the full concatenated text
  | ThinkingStart IndexPayload       -- (reasoning blocks; same shape as text)
  | ThinkingDelta DeltaPayload
  | ThinkingEnd BlockEndPayload
  | ToolCallStart IndexPayload       -- a tool-call block is about to receive argument chunks
  | ToolCallDelta DeltaPayload       -- a chunk of the tool call's arguments JSON
  | ToolCallEnd ToolCallEndPayload   -- a tool-call block closed; carries the parsed ToolCall
  | EventDone TerminalPayload        -- terminal success; carries the fully assembled message
  | EventError TerminalPayload       -- terminal failure; carries whatever was assembled + error
```

The payloads carry the data you need:

```haskell
newtype StartPayload      = StartPayload { partial :: Message }
newtype IndexPayload      = IndexPayload { contentIndex :: Int }
data    DeltaPayload      = DeltaPayload { contentIndex :: !Int, delta :: !Text }
data    BlockEndPayload   = BlockEndPayload { contentIndex :: !Int, content :: !Text }
data    ToolCallEndPayload = ToolCallEndPayload { contentIndex :: !Int, toolCall :: !ToolCall }
data    TerminalPayload   = TerminalPayload { reason :: !StopReason, message :: !Message }

isTerminal :: AssistantMessageEvent -> Bool   -- True for EventDone / EventError
```

The contract (from the module's haddock): a stream **begins** with one `EventStart`,
**interleaves** per-block `…Start` / `…Delta` / `…End` events keyed by `contentIndex`, and
**terminates** with exactly one `EventDone` or `EventError`. The terminal event carries the
fully assembled message, so a consumer that only matches the terminal still gets a correct
response. **A text field's incremental content is exactly the sequence of `TextDelta.delta`
strings for that block, in order; `TextEnd.content` is their concatenation.** This is the hook
the field-chunk path uses.

**`baikai-effectful`'s `StreamEach`.** Defined in
`baikai/baikai-effectful/src/Baikai/Effectful.hs`. It is the per-event streaming operation at
the transport layer:

```haskell
StreamEach :: Model -> Context -> Options -> (AssistantMessageEvent -> m ()) -> Baikai m ()
streamEach :: (Baikai :> es) => Model -> Context -> Options
           -> (AssistantMessageEvent -> Eff es ()) -> Eff es ()
```

It hands each event, in order, to a caller-supplied callback that runs inside `Eff`. This is
the shape `streamProgram` mirrors at the program level. The dossier (integration point #3,
section I.6, J.6) records that this exists at the transport layer but **was never exposed at the
program level** — closing that gap is the whole point of this plan.

**The `Program` GADT and `runProgram`.** Defined in `shikumi/src/Shikumi/Program.hs`. A
`Program i o` is a tree of typed nodes (deep embedding). The relevant constructors:

```haskell
data Program i o where
  Predict :: (FromModel i, FromModel o, ToSchema o, Validatable o, ToPrompt i, ToPrompt o)
          => Signature i o -> Params -> Program i o
  Compose :: Program a b -> Program b c -> Program a c
  FMap    :: (o -> o') -> Program i o -> Program i o'
  Map     :: Int -> Program a b -> Program [a] [b]
  Parallel :: Program i a -> Program i b -> Program i (a, b)
  Retry    :: Int -> Program i o -> Program i o
  RetryWhen :: (ShikumiError -> Bool) -> Int -> Program i o -> Program i o
  Validate :: (o -> Either Text o) -> Program i o -> Program i o
  MajorityVote :: (Eq o) => Int -> TempSchedule -> Program i o -> Program i o
  Ensemble :: [Program i r] -> ([r] -> o) -> Program i o
  Embed :: (forall es. (LLM :> es, Error ShikumiError :> es) => i -> Eff es o) -> Program i o
```

A `Predict` node is the only one that issues an LM call directly; everything else either
composes children (`Compose`, `Map`, `Parallel`, …), post-processes purely (`FMap`), or runs an
opaque embedded body (`Embed`, which is how the ReAct agent and tool loops are built — see
dossier section H.4). `runProgram` and `runProgramConc` interpret the tree:

```haskell
runProgram :: (LLM :> es, Error ShikumiError :> es) => Program i o -> i -> Eff es o
runProgramConc :: (LLM :> es, Error ShikumiError :> es, Concurrent :> es) => Program i o -> i -> Eff es o
```

**This plan must not change `runProgram` / `runProgramConc` or their signatures** (MasterPlan
integration point #4). Streaming is a brand-new function alongside them.

How a single `Predict` runs (in `runPredict`, lines 278–290 of `Program.hs`): it overlays the
node's optimizable `Params` onto the `Signature` to get an effective signature, selects an
`Adapter` for the model, calls `render adapter sig' i` to get a `(Context, Options)`, calls
`complete model ctx opts` to get a `Response`, then calls `parse adapter sig' resp` to decode
the typed `o`. The streaming version replaces `complete` with `stream` (or the per-event
helper), surfaces deltas as field chunks, then **reassembles the whole response from the
terminal event and runs the exact same `parse`** to produce the typed `o`. That last point is
how `streamProgram` returns a value equal to `runProgram`'s.

**The `Adapter` seam.** Defined in `shikumi/src/Shikumi/Adapter.hs`. An
`Adapter i o = Adapter { render :: Signature i o -> i -> (Context, Options), parse :: Signature
i o -> Response -> Either ShikumiError o }`. Two adapters ship: `nativeAdapter` (the provider
returns JSON, parsed as one whole value) and `fallbackAdapter` (the model is asked for
`[[ ## field ## ]]` sections, then parsed by splitting on those markers). `adapterFor model`
picks one via `capabilityFor`. Shikumi's `defaultModel` is the neutral `_Model`, which
`capabilityFor` maps to **`PromptFallback`** — so the **fallback adapter is the exercised path**
in all hermetic tests (dossier section C.3 and the note in `Program.hs` `defaultModel`). This
matters: the fallback path emits the output field as plain text inside `[[ ## field ## ]]`
markers, which is exactly the text the streaming deltas carry — so field-chunk attribution is
natural there. Native whole-JSON is not exercised on the wire (dossier J.5: `attachSchema` is a
no-op), reinforcing the decision to scope field chunking to the fallback/raw path.

**Trace span kinds (vocabulary only).** Defined in `shikumi-trace/src/Shikumi/Trace.hs`:
`data SpanKind = ProgramSpan | ModuleSpan | CombinatorSpan | LlmCallSpan`. This plan reuses the
*idea* (a small set of phase kinds) for status messages but defines its own self-contained enum
to avoid a build dependency on the trace package (see Decision Log).

**Existing test scaffolding you will reuse.** Under `shikumi/test/`:

  * `ProgramFixtures.hs` defines record types `Topic`, `Outline`, `Draft`, `Cell` (each with
    `ToSchema`/`FromModel`/`ToPrompt`/`Validatable` instances), signatures
    `topicToOutline :: Signature Topic Outline`, `outlineToDraft :: Signature Outline Draft`,
    `cellSig :: Signature Cell Cell`, a `markerBody :: [(Text, Text)] -> Text` helper that
    renders a fallback-style `[[ ## field ## ]]` response body, and `mkResponse :: Text ->
    Response` that wraps text as a single assistant text block. Reuse these verbatim.
  * `Shikumi/LLM/Mock.hs` (`runMockLLM`, `runMockLLMCounting`) is a scripted `LLM` interpreter
    that pops canned `Response`s for `Complete` and currently returns `[]` for `Stream`. This
    plan adds a streaming counterpart (a `Stream`-scripting interpreter) in the new test
    module.
  * `StubProvider.hs` builds isolated baikai registries and already defines
    `stubEvents :: Text -> [AssistantMessageEvent]` — a valid `EventStart`, `TextStart`,
    `TextDelta`, `TextEnd`, `EventDone` sequence for a piece of text. This is the canonical
    shape of a scripted stream; the new test interpreter scripts these directly.
  * `Main.hs` wires every spec into one `tasty` `defaultMain`. You will add the new spec here.

Nothing about embeddings, optimizers, compilation, or multimodal input is touched by this plan.


## Plan of Work

The work is three milestones, each independently verifiable against a hermetic stub streaming
LM (a scripted interpreter of the `LLM` effect's `Stream` operation). Everything is additive:
no existing function signature changes.

A new library module **`Shikumi.Stream`** (file `shikumi/src/Shikumi/Stream.hs`) holds the new
types and entry points. A new test module **`StreamSpec`** (file `shikumi/test/StreamSpec.hs`)
holds the acceptance tests. Both are registered in the cabal file and `Main.hs`.

### Milestone M1 — the event types and a `streamComplete` helper

**Scope.** Introduce the streaming vocabulary and a single function that turns one LM streaming
call into a sequence of `StreamEvent`s delivered to a callback. No `Program` involvement yet —
this milestone proves the event-folding logic in isolation.

**What exists at the end.** In `Shikumi/Stream.hs`:

```haskell
-- | A piece of one output field's text, as the model writes it. Mirrors DSPy's
-- StreamResponse { predict_name, signature_field_name, chunk, is_last_chunk }.
data FieldChunk = FieldChunk
  { fieldName :: !Text       -- which output field this chunk belongs to ("" if not attributed)
  , chunk     :: !Text       -- the text delta
  , isLast    :: !Bool       -- True on the final chunk of this field
  }
  deriving stock (Eq, Show, Generic)

-- | The phase a status message marks. Borrowed in spirit from the trace SpanKind.
data StatusPhase
  = LmStart        -- an LM call is about to begin
  | LmEnd          -- an LM call finished
  | ToolStart      -- a tool call is about to begin
  | ToolEnd        -- a tool call finished
  | NodeStart      -- a (sub-)program node started
  | NodeEnd        -- a (sub-)program node finished
  deriving stock (Eq, Show, Generic)

-- | A human-readable status signal. Mirrors DSPy's StatusMessage, plus the phase.
data Status = Status
  { phase   :: !StatusPhase
  , message :: !Text
  }
  deriving stock (Eq, Show, Generic)

-- | One streaming event handed to the caller's callback, in order.
data StreamEvent
  = StreamFieldChunk !FieldChunk
  | StreamStatus !Status
  deriving stock (Eq, Show, Generic)
```

and the helper:

```haskell
-- | Drive one streaming LM call, folding baikai events into StreamEvents delivered
-- to the callback in order, and return the fully assembled Response (reassembled
-- from the terminal event) so the caller can parse it into a typed value exactly as
-- the blocking path would.
streamComplete ::
  (LLM :> es) =>
  Text ->                              -- ^ the output field name to attribute chunks to
  Model -> Context -> Options ->
  (StreamEvent -> Eff es ()) ->        -- ^ per-event callback, runs in the caller's Eff
  Eff es Response
```

**How `streamComplete` works.** It calls `stream model ctx opts` (the existing `LLM` op) to get
`[AssistantMessageEvent]`, then walks the list in order:

  * On each `TextDelta (DeltaPayload _ d)` it invokes the callback with
    `StreamFieldChunk (FieldChunk fieldNameArg d False)`.
  * On `TextEnd`, it knows the text block closed; it does not emit a chunk for the `TextEnd`
    itself (the deltas already carried the text) but records that the next text content is a new
    field. (For the single-field headline case there is one text block.)
  * It tracks the **last** `TextDelta` so it can mark `isLast = True`. Practically: collect the
    text deltas first, emit all but the last with `isLast = False`, and emit the last with
    `isLast = True`. If there are no text deltas (e.g. a cached whole response arrived as a
    single `TextEnd` with no deltas), synthesize one `FieldChunk` carrying `TextEnd.content`
    with `isLast = True`, so the caller still sees the field.
  * On the terminal `EventDone`/`EventError`, it reassembles a `Response` from the terminal
    payload's `message` (the fully assembled assistant message). `EventError` additionally means
    the call failed; `streamComplete` surfaces that as the assembled (possibly-partial) response
    — the caller's `parse` will then fail with a `ShikumiError`, matching the blocking path's
    behavior where a bad response fails to decode.

The reassembled `Response` is built the same way the test fixtures build one: from the terminal
`TerminalPayload.message`. (See `StubProvider.stubEvents` for the canonical event shape; the
terminal `EventDone` carries `message = AssistantMessage (stubPayloadWith t)`, whose text is the
whole field.) The exact lens path to set the message on a fresh `_Response` mirrors
`ProgramFixtures.mkResponse` / `StubProvider.stubResponse`.

> Implementation note on the materialize-then-replay shape. M1 uses the materializing `stream`
> op, so technically all events are produced before the callback fires. This is acceptable for
> the hermetic stub (events are scripted and finite) and keeps the change additive. If a later
> milestone needs true incremental delivery against a live provider, M3 introduces a per-event
> path built on a `StreamEach`-shaped operation; this is recorded as a decision and the helper's
> contract (events delivered in order) is preserved either way. Record any incrementality
> finding in Surprises & Discoveries.

**Acceptance.** A new `StreamSpec` test scripts an `LLM` interpreter whose `Stream` returns
`stubEvents`-shaped events for the deltas `["Hel","lo"]` (i.e. two `TextDelta`s carrying
`"Hel"` and `"lo"`, bracketed by `EventStart`/`TextStart`/`TextEnd`/`EventDone`). Calling
`streamComplete "answer" model ctx opts cb` where `cb` appends each event to an `IORef [StreamEvent]`
must produce, in order:

```text
StreamFieldChunk (FieldChunk "answer" "Hel" False)
StreamFieldChunk (FieldChunk "answer" "lo"  True)
```

and the returned `Response`'s assistant text must equal `"Hello"`.

**Verify:** `cabal test shikumi` (the new `StreamSpec` group passes).

### Milestone M2 — `streamProgram` for a single `Predict` node

**Scope.** Add the program-level entry point for the headline case: a single `Predict` node.
Emit an `LmStart` status, stream the output field's chunks, emit an `LmEnd` status, and return
the typed `o` equal to `runProgram`'s result.

**What exists at the end.** In `Shikumi/Stream.hs`:

```haskell
streamProgram ::
  (LLM :> es, Error ShikumiError :> es) =>
  Program i o ->
  i ->
  (StreamEvent -> Eff es ()) ->
  Eff es o
```

This is the new public entry point. Its effect row is **exactly `runProgram`'s row plus the
callback** — note it adds no new effect to the caller, so a streamed program runs under the same
interpreters as a blocking one. (The callback runs in the caller's `Eff es`, so the caller may
emit to an `IORef`, a channel, or stdout.)

**How `streamProgram` works for `Predict`.** It mirrors `runPredict` (Program.hs lines 278–290)
but swaps the blocking `complete` for `streamComplete`:

1. Compute the effective signature by overlaying the node's `Params` (reuse the same logic
   `runPredict` uses; if that helper is not exported, replicate the small overlay here — it
   substitutes the instruction override and decodes the JSON demos, throwing a `ShikumiError`
   on a bad demo).
2. Select the adapter (`adapterFor defaultModel`) and render `(ctx, opts) = render adapter sig'
   i`. `defaultModel` is the neutral `_Model`, so this is the **fallback adapter** — the output
   field is requested as a `[[ ## field ## ]]` section, and the streamed text deltas carry that
   field's text.
3. Determine the field name to attribute chunks to: the program's **first output field name**,
   via `Shikumi.Signature.outputFields sig'` then `Shikumi.Schema.Types.fieldName`. (The dossier
   notes there is no per-node signature accessor at the `Program` level, but inside this
   `Predict` case we hold the `Signature` directly from the constructor, so the field names are
   available here.)
4. Emit `StreamStatus (Status LmStart "LM call started")` via the callback.
5. Call `resp <- streamComplete fieldNm defaultModel ctx opts callback`. This delivers the field
   chunks during the call.
6. Emit `StreamStatus (Status LmEnd "LM call finished")` via the callback.
7. `either throwError pure (parse adapter sig' resp)` — the **identical** parse the blocking
   path runs, producing the typed `o`. Because the reassembled `Response` carries the same whole
   text the blocking path would have received, this returns a value **equal to** `runProgram`'s
   result for the same scripted response.

For non-`Predict` constructors, M2 provides a minimal fallback: run the node via `runProgram`
(no field chunks, but correct value) bracketed by `NodeStart`/`NodeEnd` status events. M3
generalizes this to recurse into composites so sub-`Predict`s stream. Document this clearly in
the module haddock: "M2 streams field chunks for a single `Predict`; other shapes fall back to
blocking execution with node-boundary status messages until M3."

**Acceptance — the headline.** Build a one-node program `predict topicToOutline` is not ideal
(its output field `points` is a list); instead use a single-text-field signature. The simplest
is a `Cell -> Cell` or a fresh one-text-field record. Concretely, script the stub `Stream` to
emit deltas spelling a `[[ ## field ## ]]`-wrapped value. For the dossier's exact acceptance
("under a stub that emits `["Hel","lo"]` then done"), use a single-output-field record whose
field is `answer :: Text`, a signature `qToAnswer :: Signature Question Answer`, and script the
deltas so the assembled text is the fallback body `[[ ## answer ## ]]\nHello\n[[ ## completed ## ]]`
delivered as the chunks `"Hel"`, `"lo"` over the answer's text region. Running:

```haskell
streamProgram (predict qToAnswer) (Question "…") cb
```

with `cb` recording events must yield a sequence containing, in order:

```text
StreamStatus (Status LmStart "LM call started")
StreamFieldChunk (FieldChunk "answer" "Hel" False)
StreamFieldChunk (FieldChunk "answer" "lo"  True)
StreamStatus (Status LmEnd "LM call finished")
```

and `streamProgram` must **return** `Answer "Hello"` — the same value
`runProgram (predict qToAnswer) (Question "…")` returns when its `complete` is fed the same
assembled response. The test asserts both: the recorded event list and the equality of the
returned value with the blocking run's value.

> Honesty note for the field text. The fallback adapter wraps the field in markers, so the raw
> streamed text includes the `[[ ## answer ## ]]` marker lines. The simplest, most honest M2
> delivers the **raw text deltas** as field chunks (chunk text is exactly what the model
> streamed, marker lines included), with the field name attributed from the signature. Trimming
> marker boilerplate out of the chunk stream (as DSPy's `StreamListener` does with its buffered
> end-identifier detection) is an optional refinement recorded for M3; do not block M2 on it.
> The acceptance above scripts the deltas to fall on the value region so the test reads cleanly;
> the module haddock states plainly that chunk text is the raw provider delta.

**Verify:** `cabal test shikumi`.

### Milestone M3 — status messages bracketing sub-nodes and tool calls

**Scope.** Make `streamProgram` recurse through composite constructors so that (a) every node is
bracketed by `NodeStart`/`NodeEnd` status messages, (b) each leaf `Predict` streams its field
chunks (as M2), and (c) tool calls inside an `Embed` body (the ReAct/agent path) can surface
`ToolStart`/`ToolEnd` status messages. A final assembled typed `o` is returned, equal to
`runProgram`'s.

**What exists at the end.** `streamProgram` handles the composite constructors:

  * `Compose f g`: bracket with `NodeStart`/`NodeEnd`; stream `f` to produce the intermediate,
    then stream `g`. Field chunks come from whichever leaf `Predict` is currently executing.
  * `FMap k p`: bracket; stream `p`; apply `k` purely to the result (no chunks for the pure map).
  * `Map`, `Parallel`, `MajorityVote`, `Ensemble`, `Retry`, `RetryWhen`, `Validate`: for M3,
    bracket each with `NodeStart`/`NodeEnd` and run its children via `streamProgram` where a
    single linear result is well-defined (`Retry`, `RetryWhen`, `Validate`), or via blocking
    `runProgram` where concurrency/aggregation makes per-field streaming ambiguous (`Map`,
    `Parallel`, `MajorityVote`, `Ensemble`) — emitting node-boundary status only. Document this
    split honestly: **field chunks come from leaf `Predict` calls on the single-result path;
    aggregating combinators stream status, not field chunks.** This matches the MasterPlan's
    instruction to "scope the headline to a single-`Predict` (or chain of predicts) program and
    document multi-node streaming honestly (status messages can still bracket sub-nodes; field
    chunks come from the leaf LM call)".
  * `Embed body`: bracket with `NodeStart`/`NodeEnd`. The body is an opaque closure constrained
    to `(LLM :> es, Error ShikumiError :> es)`, so `streamProgram` cannot see inside it to stream
    its internal `Predict`s. Run it via the body itself (as `runProgram` does). For tool-bearing
    agents (ReAct), `ToolStart`/`ToolEnd` status emission requires the body to call back; M3
    documents that tool-level status from inside `Embed` is **not** automatically surfaced
    (the body is opaque) and provides the hook shape a future agent integration would use: an
    optional callback the agent loop can be threaded. Keep M3's tool-status delivery to what is
    demonstrable: a hand-built test program that emits `ToolStart`/`ToolEnd` around a simulated
    tool call to prove the event type and ordering carry through the callback.

**Decision to record in M3.** Evaluate whether to add a per-event, `StreamEach`-shaped operation
to the `LLM` effect (e.g. `StreamEach :: Model -> Context -> Options -> (AssistantMessageEvent ->
m ()) -> LLM m ()`) so live providers deliver true incremental chunks rather than the
materialize-then-replay of M1. If added, it is **additive** to the `LLM` constructor set and
every interpreter must pattern-match it (the dossier flags this ripple). Record the decision and
rationale in the Decision Log; do not let it block the hermetic acceptance, which works with the
materializing `Stream` op.

**Acceptance — a chain of predicts.** Build `predict topicToOutline >>> predict outlineToDraft`
(using `ProgramFixtures`' signatures and `Shikumi.Combinator.(>>>)`). Script the stub `Stream`
to return one event sequence per `Predict` (outline, then draft). Running `streamProgram` with a
recording callback must produce, in order: a `NodeStart` for the compose, an `LmStart`, the
outline field chunks, an `LmEnd`, then an `LmStart`, the draft field chunks, an `LmEnd`, and a
closing `NodeEnd`; and the **returned value** must equal
`runProgram (predict topicToOutline >>> predict outlineToDraft) topic` for the same scripted
responses. A separate, smaller test builds a hand-rolled program that emits `ToolStart`/`ToolEnd`
status to prove those event variants flow through the callback in order.

**Verify:** `cabal test shikumi`.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/shikumi` **inside the
Nix dev shell**. Enter the shell once:

```bash
nix develop .#ghc9124
```

Everything below assumes you are inside that shell (GHC 9.12.4). Formatting uses `fourmolu` with
2-space indentation (the repository default); run it on any file you touch.

1. Create the library module `shikumi/src/Shikumi/Stream.hs` with the types and functions
   described in M1–M3. Add `Shikumi.Stream` to the `exposed-modules` list of the `library`
   stanza in `shikumi/shikumi.cabal` (the list currently ends at `Shikumi.Signature`).

2. Create the test module `shikumi/test/StreamSpec.hs`. It defines a scripted streaming `LLM`
   interpreter, e.g.:

   ```haskell
   runStreamingLLM :: (IOE :> es) => [[AssistantMessageEvent]] -> Eff (LLM : es) a -> Eff es a
   runStreamingLLM scripts = interpret $ \_ -> \case
     Complete _ _ _ -> ...     -- assemble a Response from the next script's terminal event
     Stream   _ _ _ -> ...     -- pop and return the next event list
   ```

   so the same scripted events drive both the blocking and streaming runs (this is how the
   "equal to `runProgram`" assertion is made: feed `runProgram` a `Complete` that returns the
   `Response` reassembled from the same script). Reuse `StubProvider.stubEvents`-shaped builders
   and `ProgramFixtures` records/signatures. Add `StreamSpec` to the `other-modules` of the
   `test-suite shikumi-test` stanza in `shikumi/shikumi.cabal` and import/add
   `StreamSpec.tests` into the `testGroup "shikumi"` list in `shikumi/test/Main.hs`.

3. Build and test:

   ```bash
   cabal build shikumi
   cabal test shikumi
   ```

   Expected tail of a green run (names will match your `describe`/`it` labels):

   ```text
   shikumi
     ...
     StreamSpec
       streamComplete folds deltas into field chunks:      OK
       streamProgram streams a single Predict's field:      OK
       streamProgram returns the same value as runProgram:  OK
       streamProgram brackets a chain with status messages: OK

   All N tests passed
   ```

4. Run the broader suite to confirm nothing regressed:

   ```bash
   cabal test all
   ```

5. Format any touched files:

   ```bash
   fourmolu -i shikumi/src/Shikumi/Stream.hs shikumi/test/StreamSpec.hs shikumi/test/Main.hs
   ```

6. Commit. Every commit on this plan carries the MasterPlan / ExecPlan / Intention trailers
   (the repository convention; see other commits and the MasterPlan's Decision Log). Use a
   Conventional Commits subject, for example:

   ```text
   feat(shikumi): program-level streaming entry point and status messages (EP-25 M1)

   MasterPlan: docs/masterplans/4-shikumi-richer-io-and-multimodal.md
   ExecPlan: docs/plans/25-program-level-streaming-and-status-messages.md
   Intention: intention_01ktq812wfebgvf1dtbvg3v826
   ```

   Commit at each milestone boundary (M1, M2, M3) and whenever tests are green.


## Validation and Acceptance

The behavior is validated entirely hermetically — no network, no API key, no routing — through
`StreamSpec`. The acceptance criteria, phrased as observable behavior:

  * **M1.** Given a scripted `Stream` returning the deltas `["Hel","lo"]` (bracketed by the
    standard `EventStart`/`TextStart`/`TextEnd`/`EventDone`), `streamComplete "answer" …` invokes
    the callback with exactly `StreamFieldChunk (FieldChunk "answer" "Hel" False)` then
    `StreamFieldChunk (FieldChunk "answer" "lo" True)`, and returns a `Response` whose assistant
    text is `"Hello"`.

  * **M2 (headline).** Given the same scripted stream wrapped as a fallback `[[ ## answer ## ]]`
    body, `streamProgram (predict qToAnswer) input cb` invokes `cb` with, in order:
    `StreamStatus (Status LmStart …)`, the two field chunks, `StreamStatus (Status LmEnd …)`; and
    **returns `Answer "Hello"`**, which equals `runProgram (predict qToAnswer) input` fed the same
    assembled response. The test asserts both the event list and the returned-value equality.

  * **M3.** For `predict topicToOutline >>> predict outlineToDraft`, the callback receives node
    and LM status messages bracketing two field streams in order, and the returned value equals
    the blocking `runProgram` result for the same scripted responses. A separate test proves
    `ToolStart`/`ToolEnd` status events flow through the callback in order.

The decisive proof that streaming is **additive and faithful**: in every acceptance the streamed
return value is asserted **equal** to the value the existing `runProgram` produces for the same
scripted LM responses. This shows `runProgram`'s blocking contract is untouched (integration
point #4) and that streaming is a parallel path over the same decode.

The test commands and expected output are in Concrete Steps. A failing assertion prints the
mismatched event list or value; success prints `OK` per test and `All N tests passed`.

**Optional live extension (soft-dep on EP-14).** Once ambient routing
(`docs/plans/14-ambient-model-routing-and-live-native-structured-output.md`) lands, a live spec
analogous to the existing `LiveSpec.hs` (gated on an environment variable like `SHIKUMI_LIVE`)
can run `streamProgram` against a real model and assert a non-empty stream of field chunks. This
is not required for the plan to be complete and must remain network-gated so the default
`cabal test all` stays hermetic.


## Idempotence and Recovery

Every step is additive and safe to repeat. Creating `Shikumi/Stream.hs` and `StreamSpec.hs` is a
file write; re-running it overwrites with the same content. Editing the cabal `exposed-modules` /
`other-modules` lists and `Main.hs` is idempotent if you guard against duplicate entries (the
module name must appear exactly once in each list). Re-running `cabal build` / `cabal test` is
safe. No migration, no destructive operation, no shared mutable state is introduced. If a build
fails midway, fix the reported module and re-run `cabal build shikumi`; nothing else needs
undoing. Because no existing function is modified, reverting this plan is simply deleting the two
new files and their three registrations (cabal library list, cabal test list, `Main.hs`).


## Interfaces and Dependencies

**New library module `Shikumi.Stream`** (`shikumi/src/Shikumi/Stream.hs`). Public surface at
plan completion:

```haskell
data FieldChunk = FieldChunk { fieldName :: !Text, chunk :: !Text, isLast :: !Bool }
data StatusPhase = LmStart | LmEnd | ToolStart | ToolEnd | NodeStart | NodeEnd
data Status = Status { phase :: !StatusPhase, message :: !Text }
data StreamEvent = StreamFieldChunk !FieldChunk | StreamStatus !Status

streamComplete ::
  (LLM :> es) =>
  Text -> Model -> Context -> Options ->
  (StreamEvent -> Eff es ()) -> Eff es Response

streamProgram ::
  (LLM :> es, Error ShikumiError :> es) =>
  Program i o -> i -> (StreamEvent -> Eff es ()) -> Eff es o
```

All four type names derive `Eq, Show, Generic` so tests can compare event lists.

**Depended-on modules (all already in the package; no new build-depends).**

  * `Shikumi.LLM` — the `LLM` effect, `stream`, and re-exports `Model`, `Context`, `Options`,
    `Response`, `AssistantMessageEvent`. The plan uses the existing `Stream` operation; it adds
    **no** new constructor to the `LLM` effect in M1/M2. (M3 may, by recorded decision, add a
    per-event operation; if so it is additive and every interpreter must match it.)
  * `Shikumi.Program` — `Program`, its constructors (`Predict`, `Compose`, `FMap`, `Embed`, …),
    `runProgram`. The plan pattern-matches the GADT exactly as `runProgram` does. It does **not**
    modify `runProgram` or `runProgramConc`.
  * `Shikumi.Adapter` — `Adapter (..)`, `adapterFor`, `ToPrompt`. Used to `render` the request
    and `parse` the reassembled response, identically to `runPredict`.
  * `Shikumi.Signature` — `Signature`, `outputFields` (to get field names), plus the demo/instr
    overlay helpers `getInstruction`/`setInstruction`/`setDemos` if the effective-signature
    overlay is replicated (it is small; see `runPredict`).
  * `Shikumi.Schema` / `Shikumi.Schema.Types` — `FromModel`, `ToSchema`, `Validatable`,
    `fromModel`, and `fieldName` (for the output-field name).
  * `Shikumi.Error` — `ShikumiError` and `throwError` via `Effectful.Error.Static`.
  * `Baikai.Stream.Event` types are reached through the `AssistantMessageEvent` re-export from
    `Shikumi.LLM`; the payload accessors (`delta`, `content`, `message`, …) come from the baikai
    types already in scope via that re-export and the `baikai` dependency.

**baikai transport (consumed indirectly).** `baikai-effectful`'s `StreamEach`/`streamEach`
(integration point #3) is the conceptual model `streamProgram` mirrors and the path a live
provider would use; the hermetic build reaches streaming through the `LLM` effect's `Stream`
operation, which the bottom interpreter already maps to baikai's stream. No change to
`baikai` or `baikai-effectful` is required by this plan.

**Soft dependency.** EP-14 (`docs/plans/14-ambient-model-routing-and-live-native-structured-output.md`)
supplies a real ambient model for the optional live extension only. The plan is fully verifiable
without it.

**What must NOT change.** `runProgram` / `runProgramConc` signatures and behavior (MasterPlan
integration point #4); the `LLM` effect's existing `Complete`/`Stream` operations; any adapter
or schema type. Streaming is delivered as new, additive surface.
