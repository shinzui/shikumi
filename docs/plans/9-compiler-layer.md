---
id: 9
slug: compiler-layer
title: "Compiler layer"
kind: exec-plan
created_at: 2026-06-08T02:44:17Z
intention: "intention_01ktjgkp10ef79vpwz1cmajek9"
master_plan: "docs/masterplans/1-shikumi-typed-lm-programming-framework.md"
---

# Compiler layer

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Shikumi (仕組み — "the mechanism behind how something works") lets a Haskell developer
declare a language-model (LM) program as ordinary typed code: `Program i o` where `i` and
`o` are Haskell record types, built from primitives like `predict` (one LM call) and
`chainOfThought` (an LM call that is told to reason step by step first) and combinators
like `Pipeline` (run one program then another), `Parallel`, `Retry`, `Validate`,
`MajorityVote`, and `Ensemble`. Each LM call inside such a program has a small bundle of
**parameters** attached to it — at minimum an *instruction* string and a list of
*demonstrations* (worked input→output examples shown to the model). These parameters are
exactly what good prompting strategies tune: zero-shot says "just an instruction,"
few-shot says "show some examples first," chain-of-thought says "ask the model to reason,"
and retrieval-augmented says "fetch relevant context and put it in front of the model."

This ExecPlan delivers the **compiler layer** (the new package `shikumi-compile`). A
"compiler" here uses the word in the sense made famous by DSPy (Stanford's
"programming, not prompting" framework that inspired shikumi): a **compiler is a pure
program→program transformation that bakes a prompting strategy into a program by setting
its per-node parameters and/or rewriting its structure.** It is emphatically *not* a
search procedure — it never calls the LM to try variations and keep the best (that is the
job of the optimizer, specified separately in `docs/plans/10-optimizer-framework.md`). A
compiler takes a base `Program i o`, walks every LM-call node inside it (including nodes
nested deep inside combinators), and rewrites that node's parameters or wraps that node
according to a fixed recipe.

After this change, a developer can write:

```haskell
import Shikumi.Compile

-- a base program built from EP-4 / EP-5 primitives
qa :: Program Question Answer

-- bake in three static demonstrations at every LM-call node:
qaFewShot :: CompiledProgram Question Answer
qaFewShot = compile (fewShot demos) qa

-- or: ensure every node reasons step-by-step first:
qaCoT :: CompiledProgram Question Answer
qaCoT = compile chainOfThoughtCompiler qa
```

and then run the result. The user-visible behavior they gain: the *same* base program,
transformed by a one-line `compile` call, now sends a *different* prompt to the model — a
prompt that carries the injected demonstrations, the reasoning instruction, or the
retrieved context — at *every* LM-call node in the program, including ones buried inside
`Pipeline`/`Parallel`/`Retry`/etc. You can see this working without spending a cent on
real API calls: this plan ships a **capturing stub adapter** (a fake LM backend that
records the exact prompt it was asked to render and returns a canned answer), so a test
can compile a program, run it against the stub, and assert that the rendered prompt now
contains the injected demonstrations / reasoning cue / retrieved passage. That assertion —
"the prompt the model would have seen actually changed in the way the compiler promises" —
is the acceptance criterion for the whole plan.

This plan also **owns** the type `CompiledProgram i o` (integration point #6 in the
MasterPlan). Two later plans consume it: the optimizer
(`docs/plans/10-optimizer-framework.md`) emits a `CompiledProgram` as the result of its
search, and the CLI (`docs/plans/12-cli-and-developer-experience.md`) loads, runs, and
saves one. So besides the four initial compilers, this plan must pin down precisely what a
`CompiledProgram` *is*, how it relates to a `Program`, and how it serializes to and from
disk.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M0 (prototype): `shikumi-compile` package skeleton builds; `Compiler` newtype and
  `compile`/`CompiledProgram` defined as thin wrappers over EP-4's parameter traversal;
  a no-op `identity` compiler round-trips a program unchanged (asserted by re-running it
  against the capturing stub and observing the same prompt). **Done (2026-06-09).**
- [x] M1: capturing stub adapter + prompt-inspection test harness (`Test.Capture`,
  `Test.Fixtures`); a baseline test renders the *uncompiled* `qaBase` prompt and asserts
  its default instruction is present and no demo content is. **Done.**
- [x] M2: `zeroShot` compiler — sets each node's `instructionOverride`, clears
  `demos`; test asserts the rendered prompt carries the instruction (and the pure
  `foldParams` read shows no demos), at both nodes of a pipeline. **Done.**
- [x] M3: `fewShot`/`fewShotTyped` compiler — injects a static demo list into every
  node's `Params`; `qaBase` test asserts the demos render in the prompt, and the
  `qaPipeline` pure assertion shows `[3,3]` demos per node. **Done.**
- [x] M4: `chainOfThoughtCompiler` — a **structural rewrite** turning each `Predict sig
  ps` into `FMap value (chainOfThoughtRaw sig)` (carrying `ps`); test asserts the
  reasoning cue (`"step by step"`) appears in the prompt at every node. **Done.**
- [x] M5: `Retriever`/`Passage`/`inMemoryRetriever` + `rag` compiler (compile-time
  fallback — EP-4 ships no embed node); tests assert ranking (pure) and that the
  retrieved passage appears in the prompt while non-matching passages do not. **Done.**
- [x] M6: serialization — `encodeCompiled` / `decodeCompiledOnto` reusing EP-4's
  `programParams`/`setProgramParams`; round-trip renders an identical prompt (zero-shot
  pipeline + few-shot single node), and a wrong-shaped template returns `Left`. **Done.**
- [x] M7: documentation pass — Decision Log, Surprises, Outcomes filled; package added to
  `cabal.project`; `cabal test shikumi-compile-test` green (13 tests); `cabal build all`
  green. **Done.**

**Status: EP-9 complete.** `cabal test shikumi-compile-test` is green (13 tests, hermetic,
no network). All four compilers (zero-shot, few-shot, chain-of-thought, RAG), the owned
`CompiledProgram` type, the `Retriever` interface, and parameter-state serialization are
delivered.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

The delivered EP-4 (`Shikumi.Program`) and EP-3/EP-4 surface differed from this plan's
*assumed* contract in several concrete ways; each is recorded here with how the
implementation adapted (the *shapes* held; the names did not).

- **`Params` has no `reasoning` field.** The real type is `Params { instructionOverride
  :: Maybe Text, demos :: [Demo] }` — not the plan's assumed `{ instruction,
  demonstrations, reasoning }`. So `zeroShot` sets `instructionOverride`/`demos` and the
  chain-of-thought "parameter-flip fallback" (flip `reasoning = True`) does **not exist**.
  This forced chain-of-thought to be the *structural rewrite* the Decision Log already
  preferred (see below). Evidence: `Shikumi/Program.hs` lines 99–102.
- **`Demo` is `Shikumi.Program.Demo { demoInput :: Value, demoOutput :: Value }`** — the
  assumed shape, JSON-keyed. `fewShotTyped` builds it from `toJSON` pairs. The signature's
  *typed* demos are a separate `Shikumi.Signature.Demo i o`; the JSON `Params` demos are
  decoded into those at run time by EP-4's `effectiveSignature`.
- **`foldParams :: Program i o -> [Params]`** (returns the ordered list), not the assumed
  `Monoid m => (Params -> m) -> Program i o -> m`. And **EP-4 already ships
  `programParams`/`setProgramParams`/`programShape`** — exactly the parameter-state
  serialization M6 needed. So `Shikumi.Compile.Serialize` is a *thin JSON wrapper* over
  those (`encode (programParams p)` / `setProgramParams <$> eitherDecode`), not the
  hand-rolled `assignInOrder` the plan sketched. The node-count guard and node-order
  contract are EP-4's. No `Shikumi.Compile.Traverse` adapter module was needed — `mapParams`
  is imported from `Shikumi.Program` directly.
- **EP-4 exports the GADT constructors** (`Program(Predict, Compose, FMap, Map, Parallel,
  Retry, RetryWhen, Validate, MajorityVote, Ensemble)`). This is what makes the
  chain-of-thought and RAG *structural* rewrites possible from a downstream package: both
  pattern-match every constructor and rebuild. Per the EP-4/EP-5 rule, a function over the
  GADT must match *all* ten constructors — both rewrites do.
- **EP-4 ships no effectful `embed`/`Embed` node.** The plan's RAG "approach 1" (install a
  runtime retrieval step keyed on the actual input) is therefore impossible; `rag` uses the
  documented fallback — retrieve once at *compile time* against a fixed query (`rag ::
  Retriever -> Text -> Compiler`), run purely via `runPureEff` (the in-memory retriever is
  `forall es. Eff es [Passage]`, so it discharges at `'[]`), and inject the formatted
  passages into each node's *signature instruction* via the structural rewrite (preserving
  the base instruction with `setInstruction (getInstruction sig <> ctx) sig`).
- **Demos render as `Context.messages`, not the system prompt** (the fallback adapter emits
  user/assistant demo pairs). So the capturing harness asserts on the JSON of the *whole*
  `Context` (`encode ctx` — `Context` has `ToJSON`), which contains both the system prompt
  (instruction / reasoning cue / RAG context) and the messages (demos). Capturing only the
  system prompt — as EP-4's own `runRecordingLLM` does — would miss few-shot demos.
- **The few-shot pipeline reach is asserted purely** (`map (length . demos) (foldParams …)
  == [3,3]`), not by running. A single demo pool is type-mismatched at the second
  (`Draft -> Answer`) node, and EP-4's `effectiveSignature` *decodes* demos eagerly, so
  running would throw `MissingField` at the mismatched node before rendering. DSPy's
  `LabeledFewShot` has the same "same pool everywhere" property; the reach guarantee is the
  point, and the pure `foldParams` read proves it without the decode hazard. The strong
  "demos appear in the prompt" assertion uses the single-node `qaBase` where they line up.

The "closures hide nodes" `FMap` hazard the plan flagged did not bite: all fixtures and
compilers build programs by composing `Program` values, never by hiding a sub-program
inside an `FMap` closure, so every node is reachable as data.


## Decision Log

Record every decision made while working on the plan.

- Decision: A `CompiledProgram i o` is represented as a **newtype wrapper around an
  ordinary `Program i o`** — specifically `newtype CompiledProgram i o = CompiledProgram
  { compiledProgram :: Program i o }` — and *not* as a separate "program + side table of
  frozen parameters" structure.
  Rationale: EP-4 (`docs/plans/4-typed-program-representation-and-core-modules.md`) already
  stores each node's parameters *inside* the `Program` GADT node itself (a `Predict` node
  carries its `Params`). A compiler therefore produces a fully-formed `Program` whose nodes
  already hold the baked-in parameters; there is nothing left over to keep in a side table.
  The newtype is a **phantom marker** that says "these parameters are intentional, this
  program is ready to run/serialize/optimize," which (1) lets the optimizer's return type
  and the CLI's load/save type be precise, and (2) prevents a half-built base program from
  being silently treated as compiled. The alternative — `Program` plus an external
  `Map NodePath Params` — was rejected because it duplicates the source of truth for
  parameters (EP-4 already owns it on the node), reintroduces the "which is authoritative?"
  bug class, and complicates serialization (you would have to serialize the program *and*
  reconcile a parameter map against it on load). Date: 2026-06-08.
- Decision: `compile :: Compiler -> Program i o -> CompiledProgram i o` is a **pure
  function** (no `Eff es`, no `IO`).
  Rationale: every initial compiler (zero-shot, few-shot, chain-of-thought, RAG) is a
  deterministic rewrite of node parameters/structure given *statically supplied* data
  (an instruction string, a fixed demo list, a reasoning flag, a retriever value). None of
  them needs to call the LM: calling the LM to *generate* demos or instructions is
  bootstrapping/search and belongs to the optimizer
  (`docs/plans/10-optimizer-framework.md`), which is explicitly out of scope here. Keeping
  `compile` pure makes compilers trivially testable, composable (`compile c2 . unwrap .
  compile c1`), and free of effect-ordering questions. The RAG compiler is the one that
  *looks* like it might need effects, because retrieval fetches data; the resolution
  (see the RAG milestone) is that retrieval happens **at run time inside the program**, not
  at compile time — the compiler only *installs* a retrieval step (which carries the
  `Retriever`), so `compile` stays pure and the actual fetch occurs when `runProgram`
  evaluates the installed step. Date: 2026-06-08.
- Decision: The `Retriever` interface is a **record of one function**,
  `newtype Retriever = Retriever { retrieve :: Text -> Eff '[] [Passage] }` in spirit, but
  concretely defined so retrieval is an *effectful* operation that runs under the program's
  effect stack (see RAG milestone for the exact, effect-polymorphic signature). Shikumi
  ships exactly one implementation: `inMemoryRetriever :: [Passage] -> Retriever`, a
  brute-force keyword-overlap retriever over an in-memory passage list.
  Rationale: the MasterPlan's scope explicitly excludes building a vector store /
  production retriever ("the RAG compiler defines the *interface* and ships a trivial
  in-memory retriever; production retrievers are future work"). A single-function record is
  the minimal interface that a real retriever (Postgres pgvector, an HTTP search service,
  etc.) can later satisfy without changing the compiler. Date: 2026-06-08.
- Decision (to be confirmed during M4): chain-of-thought is implemented as a **structural
  rewrite** that replaces each `Predict sig params` node with the `ChainOfThought` form
  defined by EP-4 (`docs/plans/4-...md`), rather than as a boolean parameter flip on
  `Predict`.
  Rationale: EP-4 already provides `chainOfThought` as a first-class way to add a
  `reasoning` output field and a "reason step by step" instruction; reusing it guarantees
  the compiled program decodes the reasoning field correctly. If EP-4's final design
  instead exposes reasoning as a settable field on `Params` (a `reasoning :: Bool` or a
  thinking level), M4 will flip that field instead and this entry will be updated with the
  reason. Either way the *observable* outcome is identical: the rendered prompt instructs
  the model to reason. Date: 2026-06-08.
- Decision (M4, confirmed 2026-06-09): chain-of-thought **is** the structural rewrite —
  there is no parameter-flip fallback because the delivered `Params` carries **no
  `reasoning` field**. Each `Predict sig ps` becomes `FMap value (mapParams (const ps)
  (chainOfThoughtRaw sig))`, reusing `Shikumi.Module.chainOfThoughtRaw` (which augments the
  output with a `reasoning` field and the "think step by step" instruction) and projecting
  the answer back with `FMap value`. EP-4 ships no `rewriteNodes` helper, so the rewrite is
  spelled out over all ten exported GADT constructors. The node's existing `ps` is carried
  across verbatim; this reproduces `Shikumi.Module.chainOfThought` exactly for the common
  base-program case (`emptyParams`). Caveat documented in `Shikumi.Compile.ChainOfThought`:
  a pre-existing `instructionOverride` still wins at run time (apply CoT before zero-shot),
  and pre-existing demos must be CoT-shaped to decode under the augmented output (apply CoT
  before few-shot). Date: 2026-06-09.
- Decision (M5, 2026-06-09): `rag :: Retriever -> Text -> Compiler` uses the plan's
  **compile-time fallback** (approach 2), because EP-4 ships **no effectful embed node** to
  install a runtime retrieval step (approach 1). Retrieval runs once at compile time against
  the supplied fixed query (purely, via `runPureEff` — the `inMemoryRetriever` is
  `forall es. Eff es [Passage]`), and the formatted passages are injected into every node's
  signature instruction by a structural rewrite that *preserves* the base instruction
  (`setInstruction (getInstruction sig <> "\n\n" <> ctx) sig`). `compile` stays pure. The
  documented limitation: retrieval is independent of the actual program input; true
  per-input runtime retrieval is a TODO that awaits an EP-4 embed node. Date: 2026-06-09.
- Decision (M6, 2026-06-09): serialization is a **thin wrapper over EP-4's already-shipped
  `programParams`/`setProgramParams`**, not the hand-rolled `assignInOrder` the plan
  sketched — EP-4 delivered exactly the parameter-state save/load (with a `ParamCountMismatch`
  guard) M6 needed. `encodeCompiled = encode . programParams . compiledProgram`;
  `decodeCompiledOnto template = setProgramParams <$> eitherDecode`, rendering the
  `ParamCountMismatch` as a human-readable `Left`. Date: 2026-06-09.
- Decision (M0, 2026-06-09): dropped the planned `Shikumi.Compile.Traverse` adapter module
  — EP-4 exports `mapParams`/`foldParams` directly, so the compilers import them from
  `Shikumi.Program` with no adapter. Date: 2026-06-09.


## Outcomes & Retrospective

**EP-9 delivered (2026-06-09).** The new `shikumi-compile` package ships the compiler
layer; `cabal test shikumi-compile-test` is green (13 hermetic tests, no network) and
`cabal build all` is green.

Met, against the Purpose:
- **`compile` is pure** and applies to any program (the rank-2 `Compiler` newtype).
- **All four compilers** work, each verified by the prompt the model would have seen:
  `zeroShot` (instruction set, demos cleared, reaches both pipeline nodes), `fewShot` /
  `fewShotTyped` (injected demos render; `[3,3]` per-node reach), `chainOfThoughtCompiler`
  (the reasoning cue reaches every node via the structural rewrite), and `rag` (the
  retrieved passage appears, non-matching passages do not; the in-memory retriever ranks
  correctly).
- **`CompiledProgram i o`** (integration point #6) is owned here as a newtype over
  `Program`, with `encodeCompiled`/`decodeCompiledOnto` round-tripping the parameter state
  and rejecting a wrong-shaped template.
- The **capturing-stub** strategy made every acceptance assertion an offline, deterministic
  `cabal test`.

Gaps / deferred (clearly bounded, none blocking EP-10):
- **RAG retrieval is compile-time and query-fixed**, the documented fallback, because EP-4
  ships no effectful embed node. True per-input runtime retrieval awaits such a node.
- **Chain-of-thought and RAG preserve a node's existing `instructionOverride`**, which wins
  at run time — so the intended composition order is CoT/RAG *before* `zeroShot`/`fewShot`.
  This is documented in each module and is consistent with applying prompting strategies in
  a sensible order; a future `instructionPrefix`-style param could lift the restriction.

Comparison to vision: the MasterPlan's EP-9 goal — "the same base program, transformed by a
one-line `compile`, sends a different prompt at every node" — holds, demonstrated offline.
EP-10 (optimizer) can now emit `CompiledProgram` values and serialize them; EP-12 (CLI) can
load/run/save them.

Lessons: (1) EP-4's exported GADT constructors + the `programParams`/`setProgramParams`
interface did most of the heavy lifting — the compiler layer is genuinely thin, and the
riskiest milestones (M4 structural rewrite, M6 serialization) reduced to reusing EP-4
primitives. (2) Asserting on the *whole* rendered `Context` JSON (not just the system
prompt) is what lets one harness check instructions, reasoning cues, RAG context, *and*
few-shot demos uniformly.


## Context and Orientation

This section gives a novice everything they need to start, assuming only the current
working tree. Read it fully before editing.

### What exists in the repository

The shikumi repository (`/Users/shinzui/Keikaku/bokuno/shikumi`) is a multi-package
Haskell project. Earlier plans establish the substrate; this plan depends, in particular,
on two of them that are checked into `docs/plans/` and must be read as the authoritative
contract for the interfaces this plan consumes:

- `docs/plans/4-typed-program-representation-and-core-modules.md` (referred to below as
  "the program plan", EP-4) — owns the `Program i o` type and its parameter-traversal
  interface. **This plan hard-depends on it.**
- `docs/plans/5-module-combinators-and-control-flow.md` ("the combinators plan", EP-5) —
  owns the combinators (`Pipeline`, `Parallel`, `Retry`, `Validate`, `MajorityVote`,
  `Ensemble`). **This plan hard-depends on it** because compilers must reach LM-call nodes
  nested inside these combinators.

This plan also coordinates with, but does not depend on:

- `docs/plans/3-generic-derived-signatures-and-structured-io.md` (EP-3) — owns
  `Signature`, the `Params` type (instruction + demonstrations), and the `Adapter` seam
  that renders a request prompt from a signature + params + input.
- `docs/plans/10-optimizer-framework.md` (EP-10) and
  `docs/plans/12-cli-and-developer-experience.md` (EP-12) — consume `CompiledProgram`,
  which this plan owns.

Because the sibling plans may not be implemented yet when this plan is executed, the
implementer must treat the interface descriptions in the next subsection as the contract.
If EP-4/EP-5 are already implemented and their concrete names differ slightly from what is
written here, **adapt to the real names in the code and record the mapping in the Decision
Log** — the *shapes* described here are what matter.

### The interfaces this plan consumes (the EP-4 / EP-5 contract, restated)

A novice will not have EP-4/EP-5 in front of them as code, so here is what this plan relies
on, in plain terms. These are the assumptions; if reality differs, adapt and note it.

**The `Program i o` GADT (from EP-4).** `Program` is a *deep embedding*: it is a data type
whose values *are* programs (program-as-data), so they can be inspected and rewritten, not
just executed. ("GADT" = generalized algebraic data type: a data type whose constructors
each carry their own type indices, here `i` and `o`.) Its constructors are roughly:

```haskell
-- defined by docs/plans/4-...md ; restated here as the contract this plan assumes
data Program i o where
  Predict        :: Signature i o -> Params -> Program i o
  ChainOfThought :: Signature i o -> Params -> Program i o   -- adds a reasoning output field
  Compose        :: Program a b -> Program b c -> Program a c -- "Pipeline": run a-to-b then b-to-c
  FMap           :: (o -> o') -> Program i o -> Program i o'
  Parallel       :: Program i a -> Program i b -> Program i (a, b)
  -- EP-5 adds: Retry, Validate, MajorityVote, Ensemble (each wraps an inner Program)
```

The two leaf constructors that carry tunable prompt parameters are `Predict` and
`ChainOfThought`; both hold a `Params`. Everything else (`Compose`, `FMap`, `Parallel`,
and EP-5's wrappers) is *structural* — it contains inner `Program`s but no `Params` of its
own.

**The `Params` type (from EP-3/EP-4).** The per-node tunable bundle. The fields this plan
reads and writes:

```haskell
-- owned by EP-3 (Shikumi.Signature) / used by EP-4 ; restated as the assumed contract
data Params = Params
  { instruction     :: !(Maybe Text)        -- override the signature's default instruction
  , demonstrations  :: ![Demo]              -- worked input->output examples shown to the model
  , reasoning       :: !Bool                -- whether to ask the model to reason first
  }

data Demo = Demo { demoInput :: !Value, demoOutput :: !Value }   -- aeson Values; field-keyed
```

`Demo` holds an input and an output as aeson `Value`s (JSON), keyed by field name, because
demonstrations must serialize and must work uniformly across signatures. If EP-3 instead
types demos as `(i, o)` per node, this plan will carry a tiny `toDemo :: (ToJSON i, ToJSON
o) => i -> o -> Demo` helper; either way the stored representation is JSON, so it
serializes (see the serialization milestone).

**The parameter-traversal interface (from EP-4 — the load-bearing dependency).** EP-4 owns
*integration point #4* and is required to expose a way to read and rewrite every node's
`Params` *without runtime reflection*. This plan assumes EP-4 provides at least one of:

```haskell
-- owned by docs/plans/4-...md ; this plan consumes whichever shape EP-4 ships.
-- Shape A (a van-Laarhoven traversal over the lens library, preferred):
paramsTraversal :: Traversal' (Program i o) Params

-- Shape B (an explicit map/fold pair, the fallback if the Traversal proves awkward
-- to give for an existential GADT):
mapParams  :: (Params -> Params) -> Program i o -> Program i o
foldParams :: Monoid m => (Params -> m) -> Program i o -> m
```

The contract that matters for this plan: **whichever shape EP-4 ships, it must visit every
`Predict`/`ChainOfThought` node in the tree, recursing through `Compose`, `FMap`,
`Parallel`, and all EP-5 wrappers.** This plan's compilers are written against `mapParams`
(Shape B) for clarity; if EP-4 ships only the `Traversal'` (Shape A), define `mapParams =
over paramsTraversal` and `foldParams f = getConst . paramsTraversal (Const . f)` (or use
`foldMapOf`) in a tiny internal module `Shikumi.Compile.Traverse` and proceed unchanged.
Record which shape you used in the Decision Log.

> **Hazard — "closures hide nodes."** `FMap :: (o -> o') -> Program i o -> Program i o'`
> stores a *function*. A traversal can recurse into the *inner `Program i o`* (it is a
> field of `FMap`), so any `Predict` reachable as data is rewritten. But a `Predict`
> *constructed inside the body of the `(o -> o')` function* is invisible — it only comes
> into existence when the function is applied, which never happens during a pure rewrite.
> EP-4's traversal cannot reach such nodes and neither can this plan's compilers. This is a
> fundamental limit of rewriting a deep embedding, not a bug. Document it (M1 test should
> include a comment), and rely on the convention — which EP-4 establishes — that programs
> are built by *composing* `Program` values, not by hiding sub-programs inside `FMap`
> closures. If a node must be reachable, it must be a structural child, not a closure
> capture.

**Running a program and rendering a prompt (from EP-4/EP-3).** EP-4 exposes
`runProgram :: (LLM :> es) => Program i o -> i -> Eff es o`. Internally, when a
`Predict`/`ChainOfThought` node executes, it asks the `Adapter` (EP-3) to *render* a
request — turning the signature, the node's `Params` (instruction + demos + reasoning),
and the concrete input `i` into a baikai `Context` (system prompt + messages) — and then
issues the LM call through the `LLM` effect (EP-1). The **prompt** a compiler changes is
exactly this rendered `Context`. This plan does not need to know the rendering details; it
only needs the rendered text to *contain* the injected material, which the capturing stub
(below) lets us observe.

**The `LLM` effect + capturing stub (from EP-1, extended here).** EP-1
(`Shikumi.LLM`) defines an `effectful` effect `LLM` with one operation that takes a baikai
request and returns a baikai `Response`. EP-1 ships a real interpreter over baikai and is
expected to ship a deterministic stub interpreter for tests. This plan needs a stub that
*also records the request it was given* so a test can inspect the rendered prompt. If EP-1
already ships such a capturing stub, reuse it; otherwise this plan ships its own in the
test suite (see M1). The stub is the entire reason acceptance can be a pure, offline
`cabal test`.

### Terms defined

- **Compiler (DSPy sense):** a pure `Program -> Program` transformation that bakes a
  prompting strategy into node parameters/structure. Not a search. This plan's central
  artifact.
- **Compilation strategy / prompting strategy:** zero-shot, few-shot, chain-of-thought,
  retrieval-augmented — the four recipes this plan implements.
- **Demonstration (demo):** a worked input→output example included in the prompt so the
  model can imitate it. Stored as JSON (`Demo`).
- **Capturing stub adapter:** a fake `LLM` interpreter that records the rendered request
  (so a test can read the prompt) and returns a canned response. Lives in the test suite.
- **Retriever:** a value that, given a query string, returns relevant passages. Interface
  only; the one shipped implementation is a trivial in-memory keyword matcher.
- **Passage:** a unit of retrievable text (`data Passage = Passage { passageId :: Text,
  passageText :: Text }`).


## Plan of Work

The work is one new package, `shikumi-compile`, with modules under `Shikumi.Compile.*`,
plus a test suite. The package depends on `shikumi` (core: `Program`, `Params`, `Signature`,
`Adapter`, `LLM`), `aeson` (serialization), `text`, `containers`, and `effectful`.
Everything in this package is pure except the *runtime* behavior of the RAG-installed
retrieval step, which runs under the program's effect stack.

The order below is also the milestone order; each milestone ends green under
`cabal test shikumi-compile-test` and is independently verifiable.

### Milestone M0 — package skeleton and the `Compiler` / `CompiledProgram` types (prototype)

Scope: create the package and define the two owned types plus a no-op compiler, proving the
traversal-based rewrite plumbing works end to end before writing any real strategy. This is
labeled a prototype because it validates the riskiest assumption — that EP-4's traversal
lets us rewrite nodes from outside the core package — with the smallest possible change.

What exists at the end: the package builds; `Shikumi.Compile` exports
`Compiler`, `CompiledProgram`, `compile`, `compiledProgram` (the unwrapping accessor), and
`identity :: Compiler`; a test compiles a tiny program with `identity` and confirms it runs
and renders unchanged.

Create `shikumi-compile/shikumi-compile.cabal`:

```cabal
cabal-version:      3.0
name:               shikumi-compile
version:            0.1.0.0
build-type:         Simple

common warnings
    ghc-options: -Wall

library
    import:           warnings
    default-language: GHC2024
    hs-source-dirs:   src
    exposed-modules:  Shikumi.Compile
                      Shikumi.Compile.Types
                      Shikumi.Compile.Traverse
                      Shikumi.Compile.ZeroShot
                      Shikumi.Compile.FewShot
                      Shikumi.Compile.ChainOfThought
                      Shikumi.Compile.RAG
                      Shikumi.Compile.Retriever
                      Shikumi.Compile.Serialize
    build-depends:    base
                    , shikumi
                    , aeson
                    , text
                    , containers
                    , effectful

test-suite shikumi-compile-test
    import:           warnings
    default-language: GHC2024
    type:             exitcode-stdio-1.0
    hs-source-dirs:   test
    main-is:          Main.hs
    other-modules:    Test.Capture
                      Test.Fixtures
    build-depends:    base
                    , shikumi-compile
                    , shikumi
                    , aeson
                    , text
                    , containers
                    , effectful
                    , tasty
                    , tasty-hunit
```

Register the package by adding `shikumi-compile` to the `packages:` stanza in the root
`cabal.project`. (If `cabal.project` lists packages by directory, add the line
`shikumi-compile/`.)

Create `shikumi-compile/src/Shikumi/Compile/Types.hs` defining the two owned types:

```haskell
module Shikumi.Compile.Types
  ( Compiler (..)
  , CompiledProgram (..)
  , compile
  , runCompiled
  ) where

import Shikumi.Program (Program, Params)   -- from EP-4
-- runProgram and the LLM effect come from EP-4 / EP-1:
import Shikumi.Program (runProgram)
import Shikumi.LLM (LLM)
import Effectful (Eff, (:>))

-- A compiler is a pure rewrite of a program. It is parameterised over i/o via
-- rank-2 polymorphism so a single Compiler value can be applied to any Program,
-- which is what lets `compile c` work for every signature.
newtype Compiler = Compiler
  { runCompiler :: forall i o. Program i o -> Program i o }

newtype CompiledProgram i o = CompiledProgram
  { compiledProgram :: Program i o }

compile :: Compiler -> Program i o -> CompiledProgram i o
compile (Compiler f) = CompiledProgram . f

-- Running a compiled program is just running the wrapped program.
runCompiled :: (LLM :> es) => CompiledProgram i o -> i -> Eff es o
runCompiled (CompiledProgram p) = runProgram p
```

The `forall i o.` inside `Compiler` is the key design move: a compiler must apply to *any*
program regardless of its input/output types (few-shot demos are JSON, so they are
type-agnostic; the reasoning flag is type-agnostic; an instruction string is
type-agnostic). Making `Compiler` a rank-2 newtype lets `identity`, `zeroShot`, `fewShot`,
etc. all be single `Compiler` values usable everywhere. (This requires the
`RankNTypes` extension, which is on by default in `GHC2024`.)

Create `shikumi-compile/src/Shikumi/Compile/Traverse.hs` adapting EP-4's traversal to the
`mapParams`/`foldParams` shape the rest of this package uses:

```haskell
module Shikumi.Compile.Traverse
  ( mapParams
  , foldParams
  ) where

import Shikumi.Program (Program, Params)
-- If EP-4 ships mapParams/foldParams directly, re-export them. If EP-4 ships only a
-- Traversal' (Program i o) Params, define them here in terms of it:
--   import Control.Lens (over, foldMapOf)
--   import Shikumi.Program (paramsTraversal)
--   mapParams  = over paramsTraversal
--   foldParams = foldMapOf paramsTraversal
mapParams :: (Params -> Params) -> Program i o -> Program i o
mapParams = Shikumi.Program.mapParams      -- re-export; adapt if EP-4 differs

foldParams :: Monoid m => (Params -> m) -> Program i o -> m
foldParams = Shikumi.Program.foldParams    -- re-export; adapt if EP-4 differs
```

The no-op compiler lives in `Shikumi/Compile/Types.hs` or the umbrella module:

```haskell
identity :: Compiler
identity = Compiler id
```

Create the umbrella `shikumi-compile/src/Shikumi/Compile.hs` re-exporting everything users
need:

```haskell
module Shikumi.Compile
  ( -- types
    Compiler (..), CompiledProgram (..), compile, runCompiled, identity
    -- strategies
  , zeroShot, fewShot, chainOfThoughtCompiler, rag
    -- retrieval
  , Retriever (..), Passage (..), inMemoryRetriever
    -- serialization
  , encodeCompiled, decodeCompiled
  ) where
```

Acceptance for M0: `cabal build shikumi-compile` succeeds, and the M0 test (added in M1's
harness, or a stub here) compiles `identity` over a one-node program and runs it through
the capturing stub, observing it still produces a request. Concretely, M0 is "green" once
`cabal test shikumi-compile-test` passes with at least the identity round-trip test.

### Milestone M1 — capturing stub adapter and the prompt-inspection harness

Scope: build the offline test infrastructure that every later milestone asserts against.
Nothing in `src/` changes; all work is in `test/`. At the end, a test can take any
`Program i o` and a concrete input `i`, run it through a fake LM that records the rendered
request, and return the captured request text for inspection.

Create `shikumi-compile/test/Test/Capture.hs`:

```haskell
module Test.Capture
  ( CapturedRequest (..)
  , runWithCapture
  , renderedText
  ) where

import Shikumi.LLM (LLM, runLLMPure)   -- EP-1 stub interpreter; see note below
import Shikumi.Program (Program, runProgram)
import Effectful (Eff, runPureEff, runEff)
import Data.IORef
import qualified Data.Text as T

-- A capturing stub: it intercepts each LM request, records it, and returns a fixed,
-- valid-shaped response. The exact baikai Context type comes from EP-1/baikai; we
-- store its rendered text plus the raw Context for assertions.
data CapturedRequest = CapturedRequest
  { capturedSystemPrompt :: !(Maybe T.Text)
  , capturedMessagesText :: !T.Text   -- all message text concatenated, for substring asserts
  }

-- runWithCapture runs the program, returning the program's output (if decodable)
-- and the list of requests captured (one per LM-call node executed).
runWithCapture
  :: Program i o
  -> i
  -> IO ([CapturedRequest], Either String o)
runWithCapture prog input = do
  ref <- newIORef []
  -- Provide a capturing LLM interpreter. If EP-1 already exposes a hook to record the
  -- request and supply a canned response, use it. Otherwise define one here that:
  --   1. appends a CapturedRequest (built from the baikai Context) to `ref`
  --   2. returns a canned baikai Response whose body decodes to a default `o`
  -- The canned response must be schema-valid enough for EP-3's decoder to succeed,
  -- OR the test only inspects captured requests and ignores the Either o (see below).
  result <- runCaptureLLM ref (runProgram prog input)
  reqs <- reverse <$> readIORef ref
  pure (reqs, result)

renderedText :: CapturedRequest -> T.Text
renderedText r = maybe "" id (capturedSystemPrompt r) <> "\n" <> capturedMessagesText r
```

Two practical notes the implementer must resolve against the real EP-1/EP-3 code:

1. **Where to hook.** The cleanest hook is the `LLM` effect's single operation. EP-1's
   stub interpreter should be reusable; if it is not capturing, write `runCaptureLLM` in
   this test module as a fresh `interpret` of the `LLM` effect that writes to the `IORef`
   and returns the canned `Response`. Because the rendering (signature+params+input →
   `Context`) happens *before* the `LLM` call, intercepting at the `LLM` boundary captures
   the fully rendered prompt — exactly what we want to assert on.
2. **Decoding the canned response.** Some tests assert on the *output* `o`; most assert
   only on the *captured prompt*. To keep the harness robust, `runWithCapture` returns
   `Either String o` so a test that only cares about the prompt can ignore it. For tests
   that need a real `o`, the canned `Response` must carry a JSON body matching `o`'s
   schema; `Test/Fixtures.hs` provides a fixture `o` and the matching canned JSON.

Create `shikumi-compile/test/Test/Fixtures.hs` with a minimal signature pair and a base
program reused by all milestones:

```haskell
module Test.Fixtures where

import GHC.Generics (Generic)
import Data.Text (Text)
import Shikumi.Signature (Signature, mkSignature)   -- EP-3
import Shikumi.Module (predict)                     -- EP-4: predict :: Program i o
import Shikumi.Program (Program, Compose ((:>>)))    -- EP-4: Compose constructor / operator
-- import combinators from EP-5 as needed for the nested-node test

data Question = Question { question :: Text } deriving (Generic)
data Answer   = Answer   { answer :: Text }   deriving (Generic)
data Draft    = Draft    { draft :: Text }    deriving (Generic)

-- a single-node base program
qaBase :: Program Question Answer
qaBase = predict   -- EP-4 derives the Signature from Question/Answer

-- a TWO-node base program: Question -> Draft -> Answer, so we can prove the
-- compiler reaches a node nested inside a Pipeline (Compose).
qaPipeline :: Program Question Answer
qaPipeline = predict @Question @Draft `compose` predict @Draft @Answer
  where compose = (...)   -- EP-4's Pipeline/Compose; adapt to its real spelling
```

The exact spellings (`mkSignature`, `predict`, `compose`/`:>>`) come from EP-3/EP-4; adapt
to the real names and record any mapping in the Decision Log. The *shape* — a one-node
program and a two-node pipeline — is what each later milestone needs.

The M1 baseline test renders `qaBase`'s prompt *before any compilation* and asserts a
sanity fact (e.g. it contains the signature's default instruction, and contains *no* demo
markers). This baseline is what M2–M5 diff against.

Acceptance for M1: `cabal test shikumi-compile-test` passes; the baseline test prints (on
failure) the captured prompt so a human can read it.

### Milestone M2 — the zero-shot compiler

Scope: `zeroShot` sets a single instruction on every node and removes all demonstrations.
This is the simplest real compiler and exercises the `mapParams` path for the first time.

What exists at the end: `Shikumi.Compile.ZeroShot.zeroShot :: Text -> Compiler` (and a
no-arg `zeroShot'` that keeps each node's existing/default instruction but clears demos, if
useful). A test asserts the rendered prompt carries the given instruction and carries no
demonstrations.

```haskell
module Shikumi.Compile.ZeroShot (zeroShot) where

import Data.Text (Text)
import Shikumi.Program (Params (..))
import Shikumi.Compile.Types (Compiler (..))
import Shikumi.Compile.Traverse (mapParams)

-- Set the instruction, clear demos at every node. (reasoning left as-is.)
zeroShot :: Text -> Compiler
zeroShot instr = Compiler $ \p ->
  mapParams (\params -> params { instruction = Just instr, demonstrations = [] }) p
```

Test (in `test/Main.hs`): `compile (zeroShot "Answer concisely.") qaBase`, run through the
capturing stub, assert `renderedText` *contains* `"Answer concisely."` and does *not*
contain any demo marker. Then do the same with `qaPipeline` and assert the instruction
appears for *both* nodes (the captured request list has length 2 and both contain the
instruction) — this is the first proof that the traversal reaches nested nodes.

Acceptance for M2: the zero-shot test fails before `zeroShot` is wired (the baseline prompt
lacks the custom instruction) and passes after.

### Milestone M3 — the few-shot compiler

Scope: `fewShot` injects a *static* list of demonstrations into every node's `Params`. This
is the canonical compiler from the spec and the headline acceptance test of the plan.

What exists at the end:
`Shikumi.Compile.FewShot.fewShot :: [Demo] -> Compiler`, plus a typed convenience
`fewShotTyped :: (ToJSON i, ToJSON o) => [(i, o)] -> Compiler` that builds `Demo`s from
typed pairs. A test asserts every node now renders the injected demos.

```haskell
module Shikumi.Compile.FewShot (fewShot, fewShotTyped) where

import Data.Aeson (ToJSON, toJSON)
import Shikumi.Program (Params (..), Demo (..))
import Shikumi.Compile.Types (Compiler (..))
import Shikumi.Compile.Traverse (mapParams)

-- Inject demos at every node. We REPLACE rather than append, so re-compiling is
-- idempotent (compiling twice yields the same demos, not duplicates). If appending
-- is wanted, expose a separate addDemos; default is replace. (See Idempotence.)
fewShot :: [Demo] -> Compiler
fewShot demos = Compiler $ \p ->
  mapParams (\params -> params { demonstrations = demos }) p

fewShotTyped :: (ToJSON i, ToJSON o) => [(i, o)] -> Compiler
fewShotTyped pairs = fewShot
  [ Demo { demoInput = toJSON i, demoOutput = toJSON o } | (i, o) <- pairs ]
```

A subtlety the implementer must handle: a `Demo` is JSON keyed by field name, and different
nodes in a pipeline have different signatures (e.g. `Question->Draft` vs `Draft->Answer`).
A demo authored for one node will not render meaningfully at a node with a different
signature. For the *static* few-shot compiler this is acceptable and matches DSPy's
`LabeledFewShot`, which attaches the same demo pool everywhere and lets each predictor
render what it can; the rendering layer (EP-3 adapter) renders the fields it recognizes.
The headline test uses the single-node `qaBase` (so demos line up exactly) for the strong
assertion, and additionally uses `qaPipeline` to assert that *both* nodes received *some*
non-empty demo list (proving traversal reach) without asserting field-perfect rendering at
the mismatched node. Note this in the Decision Log if EP-3's renderer errors (rather than
ignoring) on unknown demo fields — in that case `fewShotTyped` should be the recommended
path and tests should use per-node demo pools via a future `fewShotAt` (out of scope here).

Test (the acceptance centerpiece): build three demos, `compile (fewShot demos) qaBase`, run
through the capturing stub, assert `renderedText` contains each demo's rendered
input and output text. Compare against the M1 baseline, which had *no* demos. Then assert
`foldParams (\ps -> [length (demonstrations ps)]) (compiledProgram qaCompiled)` equals
`[3, 3]` for the pipeline — a pure, no-LM assertion that the parameters changed at *every*
node exactly as promised.

Acceptance for M3: the few-shot test fails before (baseline prompt has no demos) and passes
after; the per-node demo-count assertion passes for the pipeline.

### Milestone M4 — the chain-of-thought compiler

Scope: `chainOfThoughtCompiler` ensures every LM-call node reasons step by step before
answering. Per the Decision Log seed, the preferred implementation is a **structural
rewrite** that turns each `Predict sig params` into EP-4's `ChainOfThought sig params`
(which adds a `reasoning` output field and a "think step by step" instruction); the
fallback is flipping `Params.reasoning = True` at every node via `mapParams`.

What exists at the end:
`Shikumi.Compile.ChainOfThought.chainOfThoughtCompiler :: Compiler`. A test asserts the
rendered prompt now contains the reasoning cue at every node.

```haskell
module Shikumi.Compile.ChainOfThought (chainOfThoughtCompiler) where

import Shikumi.Program (Params (..))
import Shikumi.Compile.Types (Compiler (..))
import Shikumi.Compile.Traverse (mapParams)

-- Fallback (parameter-flip) form. Works for any EP-4 design that renders a reasoning
-- cue when reasoning == True.
chainOfThoughtCompiler :: Compiler
chainOfThoughtCompiler = Compiler $ \p ->
  mapParams (\params -> params { reasoning = True }) p

-- Structural-rewrite form (preferred IF EP-4 exposes a node-level rewrite that turns
-- a Predict into a ChainOfThought). EP-4 may provide:
--     rewriteNodes :: (forall a b. Program a b -> Program a b) -> Program i o -> Program i o
-- in which case:
--   chainOfThoughtCompiler = Compiler $ rewriteNodes $ \node -> case node of
--       Predict sig ps -> ChainOfThought sig ps
--       other          -> other
-- Choose whichever EP-4 actually supports; record the choice in the Decision Log.
```

Why two forms are spelled out: this plan cannot know which EP-4 ships until EP-4 is
implemented. The parameter-flip form needs only `mapParams` (which EP-4 guarantees), so it
is the safe default and the one the test targets first. If EP-4 ships a node-level
structural rewrite, switch to it (it gives a correctly-typed `reasoning` output field) and
update the test to also assert the decoded output carries a reasoning field.

Test: `compile chainOfThoughtCompiler qaBase`, run through the stub, assert the rendered
prompt contains the reasoning cue (the exact phrase EP-3's renderer emits for reasoning —
e.g. `"step by step"` or the `reasoning` field marker). Assert it for *both* nodes of
`qaPipeline`. Also a pure assertion: `foldParams (\ps -> [reasoning ps]) compiled == [True,
True]` (parameter-flip form), or `foldParams isChainOfThought compiled` is all-`True`
(structural form).

Acceptance for M4: fails before (baseline has reasoning off / nodes are plain `Predict`) and
passes after.

### Milestone M5 — the `Retriever` interface, in-memory retriever, and RAG compiler

Scope: define the minimal retrieval interface, ship a trivial in-memory retriever, and an
`rag` compiler that installs a retrieval step in front of the program so that, at run time,
retrieved context is threaded into the program's input and thus into the rendered prompt.
This is the milestone where "compile is pure but retrieval is effectful" is resolved.

What exists at the end: `Shikumi.Compile.Retriever` (`Retriever`, `Passage`,
`inMemoryRetriever`) and `Shikumi.Compile.RAG.rag :: Retriever -> Compiler`. A test asserts
a retrieved passage appears in the rendered prompt.

First, the retriever interface and trivial implementation:

```haskell
module Shikumi.Compile.Retriever
  ( Passage (..)
  , Retriever (..)
  , inMemoryRetriever
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import Data.List (sortOn)
import Data.Ord (Down (..))

data Passage = Passage
  { passageId   :: !Text
  , passageText :: !Text
  } deriving (Eq, Show)

-- The minimal interface: given a query, return passages, ranked best-first.
-- It is effect-polymorphic so a real retriever can do IO (HTTP, DB) under the
-- program's effect stack. The trivial in-memory one ignores effects.
newtype Retriever = Retriever
  { retrieve :: forall es. Text -> Eff es [Passage] }
-- NOTE: requires `import Effectful (Eff)`. If a retriever needs IOE/specific effects,
-- a real implementation will newtype its own Retriever variant; this minimal one is
-- pure and runs in any es.

-- Trivial in-memory retriever: rank passages by count of shared (lowercased) word
-- tokens with the query; return top-k. NOT production quality (no embeddings, no
-- stemming); this is the documented placeholder. Production retrievers are out of
-- scope for this plan (see MasterPlan "Out of scope").
inMemoryRetriever :: Int -> [Passage] -> Retriever
inMemoryRetriever k corpus = Retriever $ \query ->
  let qWords = wordSet query
      score p = length (filter (`elem` qWords) (wordList (passageText p)))
  in pure (take k (sortOn (Down . score) corpus))
  where
    wordList = T.words . T.toLower
    wordSet  = wordList
```

Then the RAG compiler. The design resolves the purity question: `rag` does **not** fetch at
compile time. It produces a program that, when run, *first* retrieves passages for the
input and *then* makes them available to the downstream LM nodes. The cleanest typed way to
express "thread retrieved context into the input" using EP-4/EP-5 constructs is to
**prepend a retrieval step** that augments the program's input type with a context field.
There are two viable shapes; the plan picks the one that needs the least from EP-4/EP-5:

```haskell
module Shikumi.Compile.RAG (rag, WithContext (..)) where

import Data.Text (Text)
import qualified Data.Text as T
import Shikumi.Compile.Types (Compiler (..))
import Shikumi.Compile.Retriever (Retriever (..), Passage (..))
import Shikumi.Program (Program)
-- EP-4 is expected to expose `liftEff` / an `Embed` constructor letting an arbitrary
-- effectful function become a Program node:
--   embed :: (i -> Eff es o) -> Program i o          -- if EP-4 provides it
-- and a way to inject context into params (the simplest, most portable approach).

-- Approach chosen: rag appends the retrieved passages to EVERY node's instruction at
-- RUN time by installing a pre-step that retrieves and stashes context, then has each
-- node's render include it. Because compile must stay pure and not depend on the input,
-- the portable implementation is: install a retrieval pre-node using EP-4's `embed`,
-- producing the original input enriched with a `context :: [Passage]` the renderer
-- reads. Concretely, rag rewrites `p :: Program i o` into:
--     Compose (embed (\i -> do ps <- retrieve r (queryOf i); pure (WithContext ps i)))
--             (adaptInput p)
-- where `WithContext` carries retrieved passages alongside the original input and the
-- renderer (EP-3) is configured to render `context` passages into the prompt.

data WithContext i = WithContext { wcPassages :: ![Passage], wcInput :: !i }

rag :: Retriever -> Compiler
rag _r = Compiler $ \p -> p   -- replaced by the real installation below; see notes
```

This milestone is the one most dependent on EP-4/EP-5 specifics, so the plan gives the
implementer a decision procedure rather than pretending to know the final API:

1. **If EP-4 exposes a way to embed an arbitrary `i -> Eff es o` as a `Program` node**
   (call it `embed`/`liftEff`/an `Embed` GADT constructor — the program plan,
   `docs/plans/4-...md`, is expected to, because `runProgram` needs an escape hatch), then
   implement `rag` as: prepend an `embed` step that calls `retrieve r` on a query extracted
   from the input, wrap the input as `WithContext`, and `Compose` it with an
   input-adapted copy of `p`. The downstream nodes render the passages because the
   `WithContext` input includes them and EP-3's renderer is told (via a `Params` field or a
   signature input field named `context`) to include them.
2. **If EP-4 has no embed node** but `Params` can carry static prefix text, fall back to a
   *degenerate* RAG for the test: retrieve at compile time against a *fixed sample query*
   supplied to `rag` (`rag :: Retriever -> Text -> Compiler`), and inject the top passages
   as a static instruction prefix at every node via `mapParams`. This is less faithful
   (retrieval is query-independent) but keeps `compile` pure and still demonstrates the
   thread-into-prompt behavior. Mark it clearly as the fallback in the Decision Log and as
   a TODO to upgrade once EP-4's embed lands.

The plan's *acceptance* only requires the observable behavior — "a retrieved passage
appears in the rendered prompt" — which both approaches satisfy. Prefer approach 1; record
which was used and why.

Test: build a corpus of three passages, one clearly matching the test query; build
`inMemoryRetriever 1 corpus`; `compile (rag retriever) qaBase` (approach 1) or
`compile (rag retriever "what is shikumi?") qaBase` (fallback); run the compiled program
with a `Question` whose text matches the target passage; assert `renderedText` contains the
target passage's text and does *not* contain the non-matching passages. Add a pure unit
test of `inMemoryRetriever` ranking: `retrieve (inMemoryRetriever 1 corpus) "shikumi
mechanism"` returns the passage about shikumi, run via `runPureEff` (it is pure).

Acceptance for M5: the RAG test fails before (baseline prompt has no passage) and passes
after; the retriever ranking unit test passes.

### Milestone M6 — serialization of `CompiledProgram`

Scope: a `CompiledProgram` must serialize so the optimizer and CLI can save/load it. Since a
`CompiledProgram` is a newtype over `Program`, and EP-4 owns `Program`'s serialization of
parameter state, this milestone reuses that and adds the thin wrapper.

What exists at the end: `Shikumi.Compile.Serialize.encodeCompiled :: CompiledProgram i o ->
ByteString` and `decodeCompiled :: ... -> Either String (CompiledProgram i o)`. A test
asserts a compiled→serialized→deserialized program renders the *identical* prompt to the
in-memory compiled one.

EP-4 is expected to provide serialization of a program's *parameter state* (integration
point #4 says `Program` must be "serializable so compiled/optimized programs can be saved
and replayed"). The program's *structure* (which constructors, in what order) is not
generally serializable for free because `FMap` holds an opaque function and GADT type
indices are not reflected at runtime. The pragmatic, well-scoped contract this plan adopts —
matching DSPy's `dump_state`/`load_state`, which serialize *parameters* against a *known
program shape*, not the program structure itself — is:

- Serialization is **parameter-state serialization against a fixed program value.**
  `encodeCompiled` walks the compiled program with `foldParams` and emits an ordered JSON
  array of each node's `Params` (instruction, demos, reasoning).
- `decodeCompiled` takes the *base* program (the structural template) plus the JSON and
  re-applies the saved params in node order, producing a `CompiledProgram` — i.e. the
  signature is `decodeCompiledOnto :: Program i o -> ByteString -> Either String
  (CompiledProgram i o)`. This mirrors `load_state(program)`.

```haskell
module Shikumi.Compile.Serialize
  ( encodeCompiled
  , decodeCompiledOnto
  ) where

import Data.Aeson (encode, eitherDecode, toJSON, fromJSON, Result (..), Value)
import Data.ByteString.Lazy (ByteString)
import Shikumi.Program (Program, Params)
import Shikumi.Compile.Types (CompiledProgram (..))
import Shikumi.Compile.Traverse (foldParams)
-- plus a paramwise reassembly helper from EP-4 (assignParamsInOrder) or mapParams+State.

-- Emit each node's Params in traversal order as a JSON array. Requires ToJSON Params
-- (owned by EP-3/EP-4; if absent, this plan defines an orphan-free wrapper).
encodeCompiled :: CompiledProgram i o -> ByteString
encodeCompiled (CompiledProgram p) =
  encode (foldParams (\ps -> [toJSON ps]) p)   -- [Value], in node order

-- Re-apply saved params onto a structural template, in node order. Implemented with a
-- State traversal: zip the decoded [Params] against the nodes mapParams visits.
decodeCompiledOnto :: Program i o -> ByteString -> Either String (CompiledProgram i o)
decodeCompiledOnto template bs = do
  vals <- eitherDecode bs :: Either String [Value]
  paramsList <- traverse decodeOne vals
  -- assignInOrder threads paramsList through the template's nodes via mapParams+State,
  -- erroring if counts mismatch. (Helper spelled out in the milestone body.)
  prog <- assignInOrder paramsList template
  pure (CompiledProgram prog)
  where
    decodeOne v = case fromJSON v of { Success ps -> Right ps; Error e -> Left e }
```

The `assignInOrder` helper is the only non-trivial piece: it walks the template with a
stateful `mapParams`, popping the next saved `Params` for each node and failing if the
saved-count and node-count disagree (which would mean the template does not match the saved
program). Implement it with `Control.Monad.State` inside `mapParams`'s function, or with
EP-4's helper if it provides an indexed traversal. Document the node-order contract
(traversal order is stable and structural) so save/load are consistent.

Why parameter-state (not whole-structure) serialization: it is exactly what the optimizer
and CLI need (they always have the base program available as code, and want to persist the
*tuned parameters*), it sidesteps the impossible-in-general task of serializing GADT
structure and `FMap` closures, and it matches the established DSPy model the user is
porting. Record this clearly in the Decision Log — it is the most likely point of
confusion for a reader who expected "serialize the whole program."

Test: take `compile (fewShot demos) qaPipeline`; `encodeCompiled` it; `decodeCompiledOnto
qaPipeline` the bytes; run both the original compiled and the round-tripped one through the
capturing stub on the same input; assert the captured prompts are byte-identical. Also a
negative test: `decodeCompiledOnto qaBase` (wrong template, 1 node) against a 2-node
payload returns `Left` with a count-mismatch message.

Acceptance for M6: round-trip test passes; mismatch test returns the expected `Left`.

### Milestone M7 — documentation, exports, and green build

Scope: finalize. Ensure `Shikumi.Compile` re-exports the full surface (M0 list);
`cabal.project` includes the package; the Decision Log records the EP-4-shape choices
actually made; Surprises captures anything learned (especially the FMap-closure hazard and
the chain-of-thought structural-vs-flag choice); Outcomes summarizes against the Purpose.

Acceptance for M7: `cabal build all` and `cabal test shikumi-compile-test` are both green;
a reader can `import Shikumi.Compile` and use all four compilers plus `compile`,
`runCompiled`, `encodeCompiled`, `decodeCompiledOnto`, and `inMemoryRetriever`.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/shikumi` unless
stated otherwise.

Scaffold and first build (M0):

```bash
mkdir -p shikumi-compile/src/Shikumi/Compile shikumi-compile/test/Test
# create shikumi-compile.cabal and the modules listed in M0, then:
cabal build shikumi-compile
```

Expected (first successful build):

```text
Building library for shikumi-compile-0.1.0.0..
[ 1 of 8] Compiling Shikumi.Compile.Types
...
Linking ...
```

Run the test suite after each milestone:

```bash
cabal test shikumi-compile-test
```

Expected once M2–M6 are in (tasty summary):

```text
shikumi-compile-test
  M1 baseline prompt:                OK
  M2 zero-shot instruction present:  OK
  M2 zero-shot reaches both nodes:   OK
  M3 few-shot demos in prompt:       OK
  M3 few-shot per-node demo counts:  OK
  M4 chain-of-thought reasoning cue: OK
  M5 retriever ranking:              OK
  M5 rag passage in prompt:          OK
  M6 serialize round-trip identical: OK
  M6 mismatched template -> Left:    OK

All N tests passed
```

To see a single failing-then-passing milestone (e.g. M3), comment out the `fewShot`
rewrite body so it returns the program unchanged, run the test, observe the few-shot
assertions FAIL (the prompt lacks demos), restore the body, and observe them PASS. This is
the fail-before/pass-after evidence the spec requires; paste the two transcripts into the
Surprises section as evidence when implementing.


## Validation and Acceptance

The plan is accepted when, from the repository root, `cabal test shikumi-compile-test`
passes and the following observable behaviors hold, each phrased as input→output:

- **Zero-shot:** `compile (zeroShot "Answer concisely.") qaBase` run on `Question
  "..."` produces a captured request whose rendered text *contains* `"Answer concisely."`
  and contains *no* demonstration. The same holds for *both* nodes of `qaPipeline`.
- **Few-shot (headline):** with three static demos, `compile (fewShot demos) qaBase`
  produces a captured request whose rendered text *contains* each demo's input and output
  text, whereas the uncompiled `qaBase` (M1 baseline) does not. For `qaPipeline`, the pure
  assertion `foldParams (\ps -> [length (demonstrations ps)]) (compiledProgram (compile
  (fewShot demos) qaPipeline)) == [3, 3]` holds — every node carries the injected demos.
- **Chain-of-thought:** `compile chainOfThoughtCompiler qaBase` produces a captured
  request whose rendered text *contains* the reasoning cue, at every node, whereas the
  baseline does not; and the pure assertion that every node now has reasoning enabled (or
  is a `ChainOfThought` node) holds.
- **RAG:** with a 3-passage corpus and `inMemoryRetriever 1`, `compile (rag retriever)
  qaBase` run on a `Question` matching one passage produces a captured request containing
  that passage's text and not the others; and `retrieve (inMemoryRetriever 1 corpus)
  "shikumi mechanism"` (run purely) returns the shikumi passage first.
- **Serialization:** `decodeCompiledOnto qaPipeline (encodeCompiled (compile (fewShot
  demos) qaPipeline))` renders a byte-identical prompt to the in-memory compiled program;
  and decoding onto a wrong-shaped template returns `Left`.

The decisive point is that every assertion is about the *prompt the model would have seen*
or the *parameters now stored on the nodes* — not "a type was added." The capturing stub
makes all of this an offline, deterministic `cabal test` with no API key and no network.


## Idempotence and Recovery

Scaffolding is idempotent: re-running the `mkdir -p` and re-creating files overwrites
cleanly; `cabal build` and `cabal test` are safe to repeat. The compilers themselves are
deliberately **idempotent rewrites**: `zeroShot` and `chainOfThoughtCompiler` set fields to
fixed values, and `fewShot` *replaces* (not appends) the demo list, so `compile c (compile
c p `unwrapped`)` equals `compile c p` — compiling twice yields the same program. (This is
why few-shot replaces rather than appends; if append semantics are ever wanted, that is a
separate `addDemos` combinator, explicitly out of scope here, and it would not be
idempotent.) If a milestone's test fails, the recovery path is to comment the rewrite body
to the identity (returning the program unchanged), confirm the *baseline* still passes, then
reintroduce the rewrite — isolating whether the failure is in the rewrite or the harness.
No step is destructive; no migrations or external state are involved.


## Interfaces and Dependencies

Libraries used and why: `shikumi` (core — provides `Program`, `Params`, `Demo`,
`Signature`, the `Adapter`, the `LLM` effect, `runProgram`, and the parameter traversal;
this plan is a thin layer over it); `aeson` (serialize `Params`/`Demo` and the
`CompiledProgram` parameter state); `effectful` (`Eff`, `(:>)`, used by `runCompiled` and
the effect-polymorphic `Retriever`); `text` and `containers` (data); `tasty` +
`tasty-hunit` (tests). No new heavy dependency is introduced.

The types and signatures that must exist at the end of each milestone, by full module path:

- End of **M0** — `Shikumi.Compile.Types`:
  `newtype Compiler = Compiler { runCompiler :: forall i o. Program i o -> Program i o }`;
  `newtype CompiledProgram i o = CompiledProgram { compiledProgram :: Program i o }`;
  `compile :: Compiler -> Program i o -> CompiledProgram i o`;
  `runCompiled :: (LLM :> es) => CompiledProgram i o -> i -> Eff es o`;
  `identity :: Compiler`. `Shikumi.Compile.Traverse`:
  `mapParams :: (Params -> Params) -> Program i o -> Program i o` and
  `foldParams :: Monoid m => (Params -> m) -> Program i o -> m` (re-exported/adapted from
  EP-4). Umbrella `Shikumi.Compile` re-exporting the public surface.
- End of **M1** — test modules `Test.Capture`
  (`CapturedRequest`, `runWithCapture :: Program i o -> i -> IO ([CapturedRequest], Either
  String o)`, `renderedText :: CapturedRequest -> Text`) and `Test.Fixtures` (`Question`,
  `Answer`, `Draft`, `qaBase :: Program Question Answer`, `qaPipeline :: Program Question
  Answer`).
- End of **M2** — `Shikumi.Compile.ZeroShot.zeroShot :: Text -> Compiler`.
- End of **M3** — `Shikumi.Compile.FewShot.fewShot :: [Demo] -> Compiler` and
  `fewShotTyped :: (ToJSON i, ToJSON o) => [(i, o)] -> Compiler`.
- End of **M4** — `Shikumi.Compile.ChainOfThought.chainOfThoughtCompiler :: Compiler`.
- End of **M5** — `Shikumi.Compile.Retriever`
  (`data Passage = Passage { passageId :: Text, passageText :: Text }`;
  `newtype Retriever = Retriever { retrieve :: forall es. Text -> Eff es [Passage] }`;
  `inMemoryRetriever :: Int -> [Passage] -> Retriever`) and
  `Shikumi.Compile.RAG.rag :: Retriever -> Compiler` (approach 1) or
  `rag :: Retriever -> Text -> Compiler` (fallback), plus
  `data WithContext i = WithContext { wcPassages :: [Passage], wcInput :: i }` if approach 1.
- End of **M6** — `Shikumi.Compile.Serialize.encodeCompiled :: CompiledProgram i o ->
  ByteString` and `decodeCompiledOnto :: Program i o -> ByteString -> Either String
  (CompiledProgram i o)`.
- End of **M7** — `Shikumi.Compile` re-exports all of the above; `cabal.project` includes
  `shikumi-compile/`.

Dependencies on sibling plans, by path and what is consumed:

- `docs/plans/4-typed-program-representation-and-core-modules.md` (hard): `Program i o`
  GADT and constructors (`Predict`, `ChainOfThought`, `Compose`/Pipeline, `FMap`,
  `Parallel`); `Params` and `Demo`; `runProgram`; the parameter traversal
  (`mapParams`/`foldParams` or `paramsTraversal`); ideally an `embed`/`Embed` escape hatch
  (for RAG approach 1) and `Params`/program parameter-state serialization (for M6). If any
  concrete name differs, adapt and log the mapping.
- `docs/plans/5-module-combinators-and-control-flow.md` (hard): the combinator constructors
  (`Retry`, `Validate`, `MajorityVote`, `Ensemble`) — needed only so the traversal's
  reach-every-node guarantee is meaningful and so a nested-combinator fixture can be added
  to the reach test if desired.
- `docs/plans/3-generic-derived-signatures-and-structured-io.md` (coordination): `Signature`,
  `Params` fields, and the `Adapter` rendering whose output the capturing stub inspects.
- Owned by this plan and consumed downstream: `CompiledProgram i o` (integration point #6),
  consumed by `docs/plans/10-optimizer-framework.md` (emits it) and
  `docs/plans/12-cli-and-developer-experience.md` (loads/runs/saves it).


## Revision Notes

- 2026-06-08: Initial authoring of the full ExecPlan from the skeleton. Defined the owned
  `CompiledProgram` representation (newtype over `Program`), established `compile` as pure,
  specified the four initial compilers (zero-shot, few-shot, chain-of-thought, RAG) against
  EP-4's parameter traversal, introduced the capturing-stub acceptance strategy, the minimal
  `Retriever` interface with a trivial in-memory implementation, and parameter-state
  serialization mirroring DSPy's `dump_state`/`load_state`. Seven milestones (M0–M7), each
  independently verifiable via `cabal test shikumi-compile-test`. Reason: flesh out EP-9 per
  the MasterPlan and PLANS.md so a novice can implement the compiler layer end to end from
  this file alone. Sibling plans referenced by path only; their interface contracts restated
  here for self-containment because they were skeletons at authoring time.
