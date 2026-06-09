---
id: 4
slug: typed-program-representation-and-core-modules
title: "Typed program representation and core modules"
kind: exec-plan
created_at: 2026-06-08T02:44:16Z
intention: "intention_01ktjgkp10ef79vpwz1cmajek9"
master_plan: "docs/masterplans/1-shikumi-typed-lm-programming-framework.md"
---

# Typed program representation and core modules

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Shikumi (仕組み — "the mechanism behind how something works") lets a Haskell developer
build language-model (LM) programs that behave like ordinary, well-typed software instead
of collections of prompt strings. This ExecPlan delivers the **keystone** of that
framework: a typed representation of an LM program, written as a value that you can do
three different things with at once. After this plan is complete, a developer can:

1. **Declare** a program whose input and output are ordinary Haskell record types. For
   example, given a record `Question` and a record `Answer`, they write
   `qa :: Program Question Answer` and `qa = predict @QASig` and the compiler guarantees
   `qa` consumes a `Question` and produces an `Answer`.

2. **Compose** programs end-to-end with the pipeline operator so that the *types must line
   up* — `pipeline stage1 stage2` only compiles when `stage1` produces exactly what
   `stage2` consumes. A type error here is a *design* error caught at compile time, which is
   the whole point of doing this in Haskell rather than Python.

3. **Run** the program against a (mock or real) language model through the project's effect
   stack: `runProgram qa question` returns a fully typed `Answer` (or a typed error),
   never a raw string the caller must parse.

4. **Inspect and rewrite** the program *as data*. A later optimizer (a separate plan,
   `docs/plans/10-optimizer-framework.md`) needs to walk the program, find each node's
   tunable parameters — its instruction text and its few-shot demonstrations — read them,
   and replace them with better ones, all *without running the program and without runtime
   reflection*. This plan defines and proves the exact traversal interface that makes that
   possible.

5. **Serialize** an optimized program so it can be saved to disk and replayed later.

The single observable behavior that defines "done": a test file defines two record-typed
signatures, builds a two-stage program with `predict` and `pipeline`, runs it through the
effect stack against a *stub* language model (no network), and gets back a typed value;
and a second test walks that same program value, replaces one node's instruction and
demonstrations with new ones, and observes — by both re-reading the parameters and by
running the modified program against the stub and seeing the new instruction in the
captured prompt — that the change took effect. Both are runnable with `cabal test`.

This plan does **not** add control-flow combinators such as retry, validation, parallel
execution, majority vote, or ensembles — those live in
`docs/plans/5-module-combinators-and-control-flow.md` and are deliberately built *on top
of* the representation this plan establishes. This plan delivers the minimal but complete
core (`Predict`, `Pipeline`, `FMap`) plus the two foundational modules (`predict`,
`chainOfThought`) and the parameter interface every later plan consumes.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M0 (prototyping spike) — done 2026-06-08: minimal `Program` GADT with `Predict` +
  `Compose` + `FMap`, pure `runProgram` over a stub "model", and `paramsTraversal` +
  `foldParams`/`mapParams`; demonstrated on `predict`, a chain-of-thought-style node, and a
  two-stage pipeline in `shikumi/test/SpikeSpec.hs` (5 cases, all green; 40 total). The
  existential-`Compose` traversal typechecks and the instruction rewrite is observable in
  `runProgram` output. **Design promoted as-is** (see Decision Log). Spike is throwaway —
  removed after M1.
- [x] M1 — done 2026-06-08: `Shikumi.Program` (exposed in the cabal lib) — the full
  `Program i o` GADT (`Predict` with existentially-captured adapter/decode constraints,
  `Compose`, `FMap`), `Params`/`Demo`/`emptyParams`, `pipeline`, and `runProgram :: (LLM :>
  es, Error ShikumiError :> es) => Program i o -> i -> Eff es o`. `runProgram`'s `Predict`
  case overlays `Params` onto the signature and runs EP-3's `render → LLM.complete → parse`.
  `ProgramSpec` "M1" runs a single node through a scripted fake `LLM` to a typed `Outline`.
- [x] M2 — done 2026-06-08: the parameter interface — `paramsTraversal` (source of truth),
  `foldParams`/`mapParams` (via `Const`/`Identity`), `mapParamsAt` (polymorphic-recursion
  index walk). `ProgramSpec` proves stage-order folding, single-node edits, out-of-range
  identity, and the **ordering law** as a QuickCheck property (`foldParams . mapParamsAt n f
  == adjust n f . foldParams`, 100 cases green).
- [x] M3 — done 2026-06-08: serialization — `ProgramShape` (closure-free; `Predict` labeled
  by joined output-field names) with aeson instances, `programParams`/`setProgramParams`
  (ordered get/set, `ParamCountMismatch` on length mismatch), JSON round-trip. `SerializeSpec`
  covers the round-trip, re-apply, shape stability across param changes, and the reject case.
- [x] M4 — done 2026-06-08: `Shikumi.Module` — `predict`, `chainOfThought`/`chainOfThoughtRaw`,
  and `WithReasoning` with **hand-written** `ToSchema`/`FromModel`/`ToPrompt` (the polymorphic
  `value :: o` field cannot go through the overlappable generic instances) and a local
  `withReasoningField`. `ModuleSpec` runs a CoT node to a `WithReasoning` value and projects
  the bare output; the CoT node's params are reachable via `mapParamsAt 0`.
- [x] M5 — done 2026-06-08: `ProgramAcceptanceSpec` — Behavior 1 (typed `Topic→Outline→Draft`
  pipeline returns a `Draft`), Behavior 2 as data (rewrite touches only node 0) and on the
  wire (the recording fake `LLM` captures `"NEW INSTRUCTION"` in the first-stage prompt).
  Full suite: **59 tests green** via `cabal test shikumi`.
- [x] M0 spike removed after promotion (`refactor(program): remove promoted spike`).
- [x] Decision Log, Surprises, and Outcomes kept current at each milestone.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **M0 (2026-06-08):** the existential-witness `Compose` traversal compiles with no extra
  annotations — `paramsTraversal h (Compose f g) = Compose <$> paramsTraversal h f <*>
  paramsTraversal h g` typechecks because both recursive calls share the same hidden `b`.
  `foldParams`/`mapParams` derive cleanly from the traversal via `Const`/`Identity` (both in
  `base`, no `lens` needed for the impl). The rewrite is observable end-to-end: a stub
  "model" that echoes its effective instruction shows `"NEW INSTRUCTION"` in `runProgram`
  output after a traversal edit. No design change needed.
- **M4 (2026-06-08): `WithReasoning o` cannot use the generic schema instances.** Its
  `value :: o` field is polymorphic, and `Shikumi.Schema`'s per-field classes (`FieldSchema`,
  `FieldDoc`) resolve their general case via an `{-# OVERLAPPABLE #-}` instance that GHC
  refuses to commit to for an abstract `o` (a more specific instance — e.g. `Field d a` — might
  exist). So `instance ToSchema o => ToSchema (WithReasoning o)` with the `Generic` default
  fails with "Overlapping instances … the choice depends on the instantiation of `o`". Fix:
  hand-write `ToSchema`/`FromModel`/`ToPrompt` for `WithReasoning` (a nested `{reasoning,
  value}` object) and build the augmented signature's field metadata explicitly (reusing the
  source signature's `inputFields`). Lesson for `docs/plans/5/11`: any wrapper that adds a
  field around a polymorphic payload (retry envelopes, trajectory wrappers) must hand-roll its
  schema instances, not derive them.
- **M5 (2026-06-08): "invalid pipelines fail to compile" verified by construction.** Swapping
  the stages — `pipeline (predict outlineToDraft) (predict topicToOutline)` — is a type error:
  the first stage is `Program Outline Draft` (so `Compose`'s middle type is `Draft`) while the
  second is `Program Topic Outline` (needing the middle type to be `Topic`); `Draft` and
  `Topic` do not unify, so GHC rejects it. The headline guarantee holds.
- **EP-3 interface divergences found while reading the delivered EP-3 (recorded for M1):**
  EP-3 does **not** expose the pinned `runSignature`, `signatureName`, or `withReasoningField`.
  Instead `Shikumi.Adapter` exposes `Adapter { render :: Signature i o -> i -> (Context,
  Options), parse :: Signature i o -> Response -> Either ShikumiError o }` selected by
  `adapterFor :: Model -> Adapter i o`, and a node is run as `render → LLM.complete model ctx
  opts → parse` (see `shikumi/test/EndToEndSpec.hs`). M1 therefore defines `runProgram`'s
  Predict case as that composition rather than importing `runSignature`. `signatureName` has
  no EP-3 equivalent → `programShape` labels a `Predict` by its joined output-field names
  (stable across param changes). `withReasoningField` is provided locally in `Shikumi.Module`
  (EP-4). See Decision Log.


## Decision Log

Record every decision made while working on the plan.

- Decision: Represent `Program i o` as a **typed GADT deep embedding** (the program *is*
  inspectable data), not an opaque Haskell function, not a final-tagless class encoding,
  and not a free applicative/free monad.
  Rationale: The representation must simultaneously support three operations that pull in
  different directions. (a) *Running* it as a typed function — every encoding supports
  this. (b) *Reading and rewriting per-node parameters as data* without executing the
  program and without runtime reflection (Haskell has no Python-style frame
  introspection). An opaque function `i -> Eff es o` fails here outright: you cannot look
  inside a closure to find its instruction string. Final-tagless (encoding the program as
  a polymorphic term `forall repr. Sym repr => repr i o`) can support a "rewrite"
  interpretation only awkwardly — you must thread a second interpreter that rebuilds the
  term, and you cannot get a first-class `Params`-shaped handle to mutate, which the
  optimizer needs. (c) *Serializing* it. A GADT gives you concrete constructors you can
  pattern-match, fold over, and rebuild, which is exactly what reading, rewriting, and
  serializing parameters require. The free applicative is a reasonable alternative for the
  "structure as data" goal, but it buries the per-node parameters inside the functor's
  payload and offers no natural typed `pipeline` (sequential dependency `b` between stages)
  without escalating to a free monad, which then loses the static "structure is fully known
  before running" property that lets the optimizer enumerate nodes up front. The GADT is
  the only encoding that gives all three (run + rewrite + serialize) with the typed,
  statically-known structure the optimizer requires. This decision is inherited from the
  MasterPlan (`docs/masterplans/1-shikumi-typed-lm-programming-framework.md`) Decision Log
  and is validated by milestone M0 before the rest of the framework commits to it.
  Date: 2026-06-07.
- Decision: `Params` is a small record carrying exactly the **optimizable** state of one
  node: an optional instruction override (`Maybe Text`) and an ordered list of few-shot
  demonstrations (`[Demo]`), where a `Demo` is a rendered input/output example pair stored
  as JSON so it is type-agnostic across nodes.
  Rationale: These are precisely the two things DSPy optimizers tune (instruction search
  and demonstration selection / bootstrap). Keeping them in a flat, serializable record —
  rather than, say, leaving demos typed as `[(i, o)]` per node — lets the optimizer
  (`docs/plans/10-optimizer-framework.md`) and compiler (`docs/plans/9-compiler-layer.md`)
  manipulate a *uniform* `Params` value regardless of each node's `i`/`o`, which is what
  the parameter traversal needs to expose homogeneously. The per-node `Signature` still
  carries the *typed* schema; `Params` carries only the tunable overlay. See the dedicated
  discussion under "Interfaces and Dependencies → The Params contract".
  Date: 2026-06-07.
- Decision: **Serialization covers parameter state only, never closures.** The `FMap`
  constructor embeds an arbitrary Haskell function `(o -> o')` which cannot be serialized.
  The serialization story is therefore split: the *structure* of a program (which
  constructors, in which order, with which signature identifiers) is described by a separate
  `ProgramShape` value that is JSON-serializable and omits closures; the *parameter state*
  is a JSON-serializable ordered vector of `Params`. To replay a saved optimized program,
  the host code reconstructs the typed `Program` value in source (the structure rarely
  changes during optimization — only parameters do), then applies the saved parameter
  vector with `setProgramParams`. This matches how DSPy's `dump_state`/`load_state` works:
  state (instructions + demos) is saved and reloaded onto a program the code already
  defines. The rejected alternative — making `FMap` hold a serializable code reference (a
  registry of named pure functions) — is recorded as possible future work but deliberately
  out of scope here to keep the core small.
  Date: 2026-06-07.
- Decision: The parameter interface is provided in **two equivalent forms**: a `lens`
  `Traversal' (Program i o) Params` (named `paramsTraversal`) for callers who already use
  `lens`, and a self-contained `foldParams` / `mapParams` / `mapParamsAt` trio for callers
  who do not want a lens dependency in their reasoning. The traversal is the source of truth
  and the trio is defined in terms of it (or both in terms of a single internal
  `traverseParams`).
  Rationale: `lens` is already a transitive dependency via baikai's `Baikai.Prelude`
  (which re-exports `lens` + `generic-lens`), so a `Traversal'` costs nothing and gives
  optimizer authors the full combinator vocabulary (`toListOf`, `over`, `set`, indexed
  variants). The plain trio keeps the *documented contract* legible to a novice who has
  never seen optics. Both must obey the documented ordering law (left-to-right,
  depth-first) so that `mapParamsAt n` addresses the same node that `foldParams`'s nth
  element came from.
  Date: 2026-06-07.
- Decision: `chainOfThought` is implemented by **extending the output signature with a
  leading `reasoning :: Text` field** (à la DSPy's `ChainOfThought`, which prepends a
  `reasoning` output field), producing a `Program i (WithReasoning o)`, and is *not* a new
  GADT constructor — it is an ordinary function that builds a `Predict` node over the
  extended signature plus an `FMap` that projects the reasoning back out if the caller wants
  the bare `o`. Keeping it out of the GADT keeps the core constructor set minimal (three
  constructors) and demonstrates that richer modules are *derived*, which is the pattern
  `docs/plans/5-module-combinators-and-control-flow.md` will follow for retry/validate/etc.
  Date: 2026-06-07.
- Decision (M0, promote): **Promote the three-constructor GADT as-is.** The promote criterion
  (existential `Compose` compiles; `paramsTraversal` typechecks and is left-to-right
  depth-first; the rewrite is observable in `runProgram` output) was met by `SpikeSpec` with
  no design change. Date: 2026-06-08.
- Decision (M1): the `Predict` GADT constructor **captures the adapter/decode constraints
  existentially**: `Predict :: (FromModel i, FromModel o, ToSchema o, Validatable o, ToPrompt
  i, ToPrompt o) => Signature i o -> Params -> Program i o`. Rationale: `runProgram` must call
  EP-3's `adapterFor`/`render`/`parse` (which need `ToSchema o, FromModel o, Validatable o,
  ToPrompt i, ToPrompt o`) and must decode `Params`' JSON demos into the signature's typed
  `Demo i o` channel (which needs `FromModel i` + `FromModel o`). Capturing the dictionaries
  in the constructor is what lets `runProgram` pattern-match `Predict` and recover them — the
  GADT idiom. The user supplies these instances on their records (the `Generic`-derived
  defaults), exactly as the EP-3 fixtures already do. Date: 2026-06-08.
- Decision (M1): `runProgram`'s type is **`(LLM :> es, Error ShikumiError :> es) => Program i
  o -> i -> Eff es o`** — one capability beyond the pinned `(LLM :> es)`. Rationale: a decode
  failure must surface as a typed `ShikumiError`, and EP-1 already threads provider failures
  through the `Error ShikumiError` effect (every interpreter — `runLLM`/`runLLMResilient` —
  carries `Error ShikumiError :> es` in its residual, and tests run `runErrorNoCallStack
  @ShikumiError`). So this effect is always present wherever `LLM` is run; making it explicit
  is honest, not an added burden. `runProgram` `throwError`s on a `parse`/demo-decode `Left`.
  The exported *name* is unchanged (the constraint, not the surface, adapts — permitted by the
  plan's Idempotence section). Downstream (`docs/plans/5/8/9/10/11/12`) inherit this
  capability. Date: 2026-06-08.
- Decision (M1): the per-node model is a **neutral default (`_Model`) selecting the prompt
  fallback adapter**, not a field of the program and not a parameter of `runProgram`.
  Rationale: the program must stay provider-neutral (Vision: "run it against any provider"),
  so the model cannot live in the program data; and the pinned `runProgram` takes no model.
  `capabilityFor _Model` is `PromptFallback`, which the MasterPlan already records as "the
  exercised path" until EP-2 lands the native schema. EP-4 is stub-driven (the fake `LLM`
  interpreter ignores the model), so this fully satisfies EP-4's acceptance; wiring a real
  ambient model/provider (e.g. a `Reader Model` effect or CLI/eval config) is deferred to the
  plans that need real routing (`docs/plans/8`, `docs/plans/12`). Recorded as known future
  work. Date: 2026-06-08.
- Decision (M1): `Params` demos reach the wire by **decoding each JSON `Demo` into the
  signature's typed `Demo i o` and `setDemos`-ing them onto the effective signature before
  `render`**, reusing EP-3's demo rendering rather than duplicating prompt formatting in EP-4.
  A demo whose JSON does not decode surfaces as the located `ShikumiError` from `fromModel`.
  The effective instruction is `fromMaybe (getInstruction sig) (instructionOverride ps)`
  applied via `setInstruction`. Date: 2026-06-08.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation. At completion, state: did the GADT support
run + rewrite + serialize as designed; did any constructor need to change after M0; how the
parameter ordering law held up under tests; what `docs/plans/5-module-combinators-and-control-flow.md`,
`docs/plans/9-compiler-layer.md`, and `docs/plans/10-optimizer-framework.md` should know
before they build on this.)


## Context and Orientation

This section assumes you know nothing about this repository. Read it fully before editing.

**Where you are.** The repository root is `/Users/shinzui/Keikaku/bokuno/shikumi`. It is a
multi-package Haskell project. The core library package is `shikumi`; its modules live
under a `Shikumi.*` namespace. This plan adds two modules to that package:
`Shikumi.Program` (the typed program representation) and `Shikumi.Module` (the `predict`
and `chainOfThought` constructors), plus a test suite.

**What already exists when you start (hard dependencies).** This plan *hard-depends* on two
sibling plans being implemented first. You do not re-implement them; you consume them. If
they are not yet implemented in the working tree, implement them first (they are referenced
by path only, per the planning rules):

- `docs/plans/1-shikumi-runtime-substrate-and-llm-effect-over-baikai.md` establishes the
  cabal project, the `effectful` integration, and an effect named `LLM`. "effectful" is a
  Haskell effect-system library: an *effect* is a capability (here, "can call a language
  model") that appears in a function's type as a constraint like `LLM :> es`, and `Eff es a`
  is a computation that uses the effects listed in `es` and returns an `a`. That plan also
  defines the shikumi error type (an enumerated set of failures: invalid JSON, missing
  field, schema mismatch, validation failure, provider failure, timeout, budget exceeded).
  For this plan you need from it: the module `Shikumi.LLM` exposing the `LLM` effect with a
  single primitive that, given a *request* (a system/user prompt assembled from a context),
  returns the model's textual/structured response; and the error type in `Shikumi.Error`.
- `docs/plans/3-generic-derived-signatures-and-structured-io.md` establishes
  `Shikumi.Signature` and `Shikumi.Adapter`. A **Signature** is a typed declaration that a
  program step consumes an input record `i` and produces an output record `o`, together
  with an *instruction* (free text telling the model what to do) and per-field descriptions
  derived from the record types via GHC `Generics`. An **Adapter** is the seam that
  *renders* a request from `(Signature i o, instruction, demos, input i)` into the prompt /
  structured-output request that the `LLM` effect consumes, and *parses* the model's
  response back into a typed `o` (or a typed error). The instruction and demonstrations are
  the program's *optimizable parameters*.

Because `docs/plans/3-...` is itself a skeleton at the time this plan is authored, this
plan **pins the exact interface** it requires from EP-3 (below) so that you can proceed
even if EP-3's internal details differ in inessential ways. If EP-3's final names differ,
adjust the imports here and record the difference in the Decision Log; the *shape* of the
contract must hold.

**The pinned EP-3 interface this plan depends on.** From `Shikumi.Signature` you require:

```haskell
-- A typed signature: input record type i, output record type o, an instruction, and
-- Generic-derived field metadata. Construct one with `signature` from a type-level proxy
-- or via a class instance; this plan treats it as opaque except for the accessors below.
data Signature i o

-- The default instruction declared for this signature (from EP-3's metadata).
signatureInstruction :: Signature i o -> Text

-- A stable identifier for a signature, used by ProgramShape serialization to name the node.
-- (E.g. the fully-qualified type name of the signature, or a user-supplied tag.)
signatureName :: Signature i o -> Text
```

From `Shikumi.Adapter` you require a single rendering/parsing entry point that this plan
calls inside `runProgram`. The adapter takes the *effective* instruction and demos (after
any parameter override), the input value, and produces a typed output through the `LLM`
effect:

```haskell
-- Render a request from the signature + effective instruction + demos + input, call the
-- LLM effect, and parse the structured response back to a typed o (or throw/return the
-- shikumi error type). `Demo` is the serialized example type defined in this plan; the
-- adapter knows how to splice demos into the prompt.
runSignature
  :: (LLM :> es)
  => Signature i o
  -> Text          -- effective instruction
  -> [Demo]        -- effective demonstrations
  -> i
  -> Eff es o
```

If EP-3 exposes the render and parse halves separately rather than as one `runSignature`,
define `runSignature` locally in `Shikumi.Program` as their composition. The key contract
is: **`runProgram` for a `Predict` node ultimately calls something equivalent to
`runSignature` with the node's effective instruction and demos**, and the effective
instruction/demos come from overlaying the node's `Params` onto the signature's defaults
(see "The Params contract").

**Terms of art used in this plan (defined once, here).**

- *GADT* (generalized algebraic data type): a data type whose constructors may each fix the
  type parameters differently. It lets us say "`Predict` builds a `Program i o` for some
  particular `i` and `o`, while `Compose` builds a `Program a c` out of a `Program a b` and
  a `Program b c`". The intermediate type `b` is hidden inside the constructor — it is an
  *existential* type variable, meaning it exists but is not visible in the result type.
- *Deep embedding*: representing a little language (here, "LM programs") as a data structure
  you can inspect, rather than directly as Haskell functions. The opposite is a *shallow
  embedding* (each program *is* a Haskell function). Deep embedding is what lets us treat a
  program as data to be rewritten.
- *Traversal* (from the `lens` library): a first-class value `Traversal' s a` that focuses
  on zero-or-more `a` values inside an `s`, supporting both reading all of them
  (`toListOf`) and replacing all of them (`over`, `set`). We use it to focus on every
  `Params` inside a `Program i o`.
- *Demonstration* / *demo*: a worked input→output example included in the prompt to show
  the model the desired behavior. Few-shot prompting = prompting with a few demos.

**How the pieces fit.** A `Program i o` value is a tree of constructors. `runProgram` walks
the tree and *interprets* it as an `Eff` computation that issues `LLM` calls. The parameter
traversal walks the *same* tree and yields/updates the `Params` sitting at each `Predict`
node (composite nodes like `Compose`/`FMap` hold no parameters of their own; they pass the
traversal through to their children). `predict` and `chainOfThought` (in `Shikumi.Module`)
are convenience constructors that produce `Predict`-based trees. Serialization extracts the
ordered parameter vector and the structural shape separately, per the closures decision.


## Plan of Work

The work proceeds as a prototyping spike (M0) that de-risks the central type-system bet,
followed by four additive milestones (M1–M5) that promote and complete the design. Every
milestone is independently verifiable with `cabal test`. Do all edits inside the `shikumi`
core package. Below, file paths assume the conventional layout where the `shikumi` package's
library sources live under `shikumi/src/` and its tests under `shikumi/test/`; if EP-1
established a different directory, mirror that and keep module paths (`Shikumi.Program`,
`Shikumi.Module`) identical.


### Milestone M0 — Prototyping spike (de-risk the GADT)

**Scope.** Before committing the framework to this representation, build the smallest thing
that proves the three-way requirement (run + rewrite + serialize-state) is achievable with a
GADT. This is explicitly a *prototype*: it may live in a single throwaway module
`Shikumi.Program.Spike` and a single test, and it uses a *stub* LLM so it needs no network
and no real EP-3 adapter — you may inline a trivial adapter that returns a canned response
echoing the effective instruction so the test can *observe* parameter changes in the output.

**What will exist at the end.** A module `shikumi/src/Shikumi/Program/Spike.hs` containing a
three-constructor GADT (`Predict`, `Compose`, and `FMap`), a `Params` record, a
`runProgram` over a minimal stub LLM, and a `paramsTraversal`. A test
`shikumi/test/SpikeSpec.hs` that: (1) builds a `predict`-style node and runs it; (2) builds
a `chainOfThought`-style node (extended signature) and runs it; (3) composes two nodes into
a pipeline and runs it, getting a typed result; (4) traverses the pipeline, replaces the
first node's instruction, and asserts via the stub's echoed output that the new instruction
was used. The stub LLM lets you assert on the *effective instruction* without a network.

The prototype GADT (illustrative — exact field types align with EP-3 once promoted):

```haskell
{-# LANGUAGE GADTs #-}
{-# LANGUAGE RankNTypes #-}

module Shikumi.Program.Spike where

import Data.Text (Text)

-- The optimizable state of a single node.
data Params = Params
  { instructionOverride :: Maybe Text  -- Nothing = use the signature's default
  , demos               :: [Demo]
  } deriving (Eq, Show)

-- A serialized example pair. In the spike, keep it simple.
data Demo = Demo { demoInput :: Text, demoOutput :: Text } deriving (Eq, Show)

emptyParams :: Params
emptyParams = Params Nothing []

-- A minimal stand-in for EP-3's Signature, carrying just a default instruction and a
-- pure "model" that the stub LLM applies. In the real module this becomes EP-3's
-- Signature plus EP-3's adapter; here we keep it self-contained.
data SpikeSig i o = SpikeSig
  { sigDefaultInstruction :: Text
  , sigRun                :: Text -> i -> o  -- (effective instruction -> input -> output)
  }

data Program i o where
  Predict :: SpikeSig i o -> Params -> Program i o
  Compose :: Program a b -> Program b c -> Program a c
  FMap    :: (o -> o') -> Program i o -> Program i o'

-- Run: interpret the tree as a function. (The spike uses a pure stub; the real one is
-- `(LLM :> es) => Program i o -> i -> Eff es o`.)
runProgram :: Program i o -> i -> o
runProgram (Predict sig ps) i =
  let instr = maybe (sigDefaultInstruction sig) id (instructionOverride ps)
   in sigRun sig instr i
runProgram (Compose f g) i  = runProgram g (runProgram f i)
runProgram (FMap k p) i     = k (runProgram p i)

-- The parameter traversal: focus on every Params in the tree, left-to-right depth-first.
-- Composite nodes carry no Params of their own and recurse into children.
paramsTraversal :: Applicative f => (Params -> f Params) -> Program i o -> f (Program i o)
paramsTraversal h (Predict sig ps) = Predict sig <$> h ps
paramsTraversal h (Compose f g)    = Compose <$> paramsTraversal h f <*> paramsTraversal h g
paramsTraversal h (FMap k p)       = FMap k <$> paramsTraversal h p
```

Note the subtlety the spike exists to confirm: in `paramsTraversal`'s `Compose` case the
intermediate type `b` is existential, yet the recursion typechecks because each recursive
call returns a `Program a b` / `Program b c` of the *same* hidden `b`, and `Compose`
reassembles them. This is the crux of "rewrite as data while staying typed"; if this does
not compile cleanly, the design must change, and that is what M0 catches.

**Commands.**

```bash
cd /Users/shinzui/Keikaku/bokuno/shikumi
cabal build shikumi
cabal test shikumi:spike   # or whatever test-suite stanza you add for the spike
```

**Acceptance.** The spike test passes: it runs a single node, a chain-of-thought-style
node, and a two-stage pipeline, and it demonstrates that replacing a node's
`instructionOverride` via `paramsTraversal` (e.g. with `lens`'s `over` or a hand-written
modify) changes the value `runProgram` produces (because the stub echoes the effective
instruction). Record in the Decision Log whether the design is **promoted as-is** or
**revised**, and if revised, exactly what changed and why.

**Promote-or-discard criterion.** Promote if (a) the three-constructor GADT compiles with
the existential `Compose`, (b) `paramsTraversal` typechecks and obeys left-to-right
depth-first ordering in the test, and (c) the rewrite is observable in `runProgram` output.
If any fails, revise the constructor set or the `Params`/traversal shape and re-run M0 before
proceeding. Do not start M1 until M0's criterion is met.


### Milestone M1 — The real `Shikumi.Program` (GADT + runProgram over the LLM effect)

**Scope.** Promote the spike into the production module, wired to EP-1's `LLM` effect and
EP-3's `Signature`/adapter. Create `shikumi/src/Shikumi/Program.hs`.

**What will exist at the end.** `Shikumi.Program` exporting: the `Program i o` GADT with
constructors `Predict`, `Compose`, `FMap`; the `Params` and `Demo` types with `emptyParams`;
the smart pipeline operator `pipeline`; and `runProgram :: (LLM :> es) => Program i o -> i
-> Eff es o`. The module compiles against the real `Shikumi.LLM`, `Shikumi.Signature`, and
`Shikumi.Adapter`.

The promoted GADT:

```haskell
{-# LANGUAGE GADTs #-}

module Shikumi.Program
  ( Program (..)
  , Params (..)
  , Demo (..)
  , emptyParams
  , pipeline
  , runProgram
  -- parameter interface (M2):
  , paramsTraversal
  , foldParams
  , mapParams
  , mapParamsAt
  -- serialization (M3):
  , ProgramShape (..)
  , programShape
  , programParams
  , setProgramParams
  ) where

import Data.Text (Text)
import Effectful (Eff, (:>))
import Shikumi.LLM (LLM)
import Shikumi.Signature (Signature, signatureInstruction, signatureName)
import Shikumi.Adapter (runSignature)  -- see "pinned EP-3 interface" above

data Params = Params
  { instructionOverride :: !(Maybe Text)
  , demos               :: ![Demo]
  } deriving (Eq, Show)

data Demo = Demo
  { demoInput  :: !Aeson.Value   -- the input record rendered to JSON
  , demoOutput :: !Aeson.Value   -- the output record rendered to JSON
  } deriving (Eq, Show)

emptyParams :: Params
emptyParams = Params Nothing []

data Program i o where
  Predict :: Signature i o -> Params -> Program i o
  Compose :: Program a b -> Program b c -> Program a c
  FMap    :: (o -> o') -> Program i o -> Program i o'

-- Smart constructor: read left-to-right ("first do p, then do q"). `pipeline p q`
-- typechecks only when p's output type equals q's input type.
pipeline :: Program a b -> Program b c -> Program a c
pipeline = Compose

-- Compute the effective instruction by overlaying the node's Params on the signature.
effectiveInstruction :: Signature i o -> Params -> Text
effectiveInstruction sig ps =
  maybe (signatureInstruction sig) id (instructionOverride ps)

runProgram :: (LLM :> es) => Program i o -> i -> Eff es o
runProgram (Predict sig ps) i =
  runSignature sig (effectiveInstruction sig ps) (demos ps) i
runProgram (Compose f g) i = runProgram f i >>= runProgram g
runProgram (FMap k p) i    = k <$> runProgram p i
```

`FMap` exists so that pure post-processing (projecting a field, mapping a value) is part of
the program data without an LM call. It is also the mechanism by which `chainOfThought`
strips the reasoning field when the caller wants the bare output (M4).

**Why `Compose` rather than a `Functor`/`Category` instance only.** A `Category` instance
(`(.)`/`id`) over `Program` is *additionally* fine to provide and ergonomic, but the named
`Compose` constructor must exist because the traversal and serialization pattern-match on it
by name. Provide the `Category` and `Functor` instances as thin wrappers if desired, but the
constructors are the source of truth.

**Commands.**

```bash
cd /Users/shinzui/Keikaku/bokuno/shikumi
cabal build shikumi
```

**Acceptance.** `Shikumi.Program` compiles against the real effect and signature modules.
A minimal test (extend the test suite) constructs a `Predict` node from a real `Signature`,
runs it through a stub `LLM` interpreter (a pure interpreter for the `LLM` effect that
returns a canned structured response — see "Concrete Steps"), and gets the expected typed
output. `cabal test` passes.


### Milestone M2 — The parameter interface (traversal + fold/map trio)

**Scope.** Add to `Shikumi.Program` the documented parameter interface that
`docs/plans/9-compiler-layer.md` and `docs/plans/10-optimizer-framework.md` consume.

**What will exist at the end.** Four exported functions with the ordering law documented and
tested:

```haskell
-- The source-of-truth traversal: focuses every Params in the program, in left-to-right
-- depth-first order. Obeys the Traversal laws.
paramsTraversal :: Applicative f => (Params -> f Params) -> Program i o -> f (Program i o)
paramsTraversal h (Predict sig ps) = Predict sig <$> h ps
paramsTraversal h (Compose f g)    = Compose <$> paramsTraversal h f <*> paramsTraversal h g
paramsTraversal h (FMap k p)       = FMap k <$> paramsTraversal h p

-- Read every node's Params, in traversal order. (Defined via the Const applicative or
-- lens's `toListOf paramsTraversal`.)
foldParams :: Program i o -> [Params]

-- Apply a function to every node's Params, preserving structure and types.
-- (Defined via the Identity applicative or lens's `over paramsTraversal`.)
mapParams :: (Params -> Params) -> Program i o -> Program i o

-- Apply a function to the Params at a single 0-based index in traversal order; indices out
-- of range leave the program unchanged. This is the optimizer's primary edit primitive:
-- "replace node n's instruction/demos".
mapParamsAt :: Int -> (Params -> Params) -> Program i o -> Program i o
```

`mapParamsAt` is implemented with a stateful traversal (e.g. `lens`'s indexed traversal, or
threading a counter through `paramsTraversal` using `State`) so it touches exactly the nth
focused `Params`.

**The ordering law (the contract).** `foldParams` lists `Params` in *left-to-right,
depth-first* order: for `Compose f g`, all of `f`'s params come before all of `g`'s; for
`FMap k p`, `p`'s params (FMap adds none). `mapParamsAt n` edits the node whose `Params` is
the nth element of `foldParams`. This invariant — *the index `mapParamsAt` uses is the same
index `foldParams` produces* — is the precise promise downstream plans rely on; it must hold
under a property test.

**Commands.**

```bash
cd /Users/shinzui/Keikaku/bokuno/shikumi
cabal test shikumi
```

**Acceptance.** Tests prove: (1) for a two-stage pipeline, `foldParams` returns exactly two
`Params` in stage order; (2) `mapParams` over a program then `foldParams` reflects the
change at every node; (3) `mapParamsAt 0` changes only the first node and `mapParamsAt 1`
only the second, verified by `foldParams` before/after; (4) `mapParamsAt` with an
out-of-range index is the identity; (5) a property test that
`foldParams (mapParamsAt n f p) == adjust n f (foldParams p)` for in-range `n`, where
`adjust` is the obvious list update — this *is* the ordering law made executable.


### Milestone M3 — Serialization (parameter state, not closures)

**Scope.** Add the serialization surface honoring the "state only, never closures"
decision. Two artifacts: a structural `ProgramShape` (JSON-serializable, closure-free) and
an ordered parameter vector with get/set.

**What will exist at the end.**

```haskell
-- A closure-free description of a program's structure, for inspection/debugging and to
-- pair with a saved parameter vector. It records constructor shape and signature names,
-- and explicitly notes that FMap's function is opaque.
data ProgramShape
  = ShapePredict Text            -- the node's signatureName
  | ShapeCompose ProgramShape ProgramShape
  | ShapeFMap ProgramShape       -- the mapped function is omitted (opaque)
  deriving (Eq, Show, Generic)
  -- with aeson ToJSON/FromJSON instances

programShape :: Program i o -> ProgramShape

-- The ordered parameter vector, in foldParams order. JSON-serializable because Params and
-- Demo are JSON-serializable (Demo holds aeson Values; Params holds Maybe Text + [Demo]).
programParams :: Program i o -> [Params]
programParams = foldParams

-- Apply a saved parameter vector back onto a program of the matching shape. The list must
-- have exactly `length (foldParams p)` elements (one per node, in order). Returns the
-- program with each node's Params replaced; on a length mismatch, return a Left with a
-- typed error (or document that it truncates — choose Left and document it).
setProgramParams :: [Params] -> Program i o -> Either ProgramShapeError (Program i o)
```

`setProgramParams` is the replay primitive: the host reconstructs the typed `Program` in
source (structure is code), then applies the saved `[Params]`. `programShape` lets a tool
*verify* that a saved parameter file matches the program it is being loaded onto (compare
shapes / node counts) before applying.

**Why this honors the closures decision.** `ProgramShape` never tries to capture `FMap`'s
function — it records only that an `FMap` node exists. `programParams`/`setProgramParams`
move only the JSON-serializable `Params` (instruction text + JSON demos). No closure is ever
serialized. Add `ToJSON`/`FromJSON` for `Params`, `Demo`, and `ProgramShape` (via
`Generic`/aeson). Saving an optimized program = write `(programShape p, programParams p)` as
JSON; loading = read the `[Params]`, reconstruct `p` in code, `setProgramParams params p`.

**Commands.**

```bash
cd /Users/shinzui/Keikaku/bokuno/shikumi
cabal test shikumi
```

**Acceptance.** A round-trip test: build a two-stage program, set distinct instructions and
demos on each node via `mapParamsAt`, extract `programParams`, JSON-encode then JSON-decode
that vector, `setProgramParams` it back onto a freshly built (default-params) program, and
assert the result's `foldParams` equals the original's. A second test asserts
`programShape` is stable across parameter changes (parameters do not affect shape) and that
`setProgramParams` with a wrong-length vector returns `Left`.


### Milestone M4 — `Shikumi.Module`: `predict` and `chainOfThought`

**Scope.** Create `shikumi/src/Shikumi/Module.hs` with the two foundational module
constructors. These are *functions that build `Program` values*, not new constructors.

**What will exist at the end.**

```haskell
module Shikumi.Module
  ( predict
  , chainOfThought
  , WithReasoning (..)
  , chainOfThoughtRaw
  ) where

import Shikumi.Program (Program, Params, emptyParams)
import Shikumi.Program (pattern Predict)  -- or import the constructor
import Shikumi.Signature (Signature, withReasoningField)
-- ^ EP-3 provides a way to extend an output signature with a leading reasoning field.

-- The basic predictor over a signature. Builds a single Predict node with empty (default)
-- parameters: no instruction override (use the signature's default), no demos. `sig` is
-- typically resolved from a type via EP-3 (e.g. `predict (signature @MySig)` or a
-- type-applied `predict @MySig`).
predict :: Signature i o -> Program i o
predict sig = Predict sig emptyParams

-- The output record o wrapped with a leading reasoning field. EP-3's signature extension
-- produces a signature whose output is (WithReasoning o); the model is asked to emit its
-- step-by-step reasoning first, then the structured answer — DSPy's ChainOfThought.
data WithReasoning o = WithReasoning
  { reasoning :: !Text
  , value     :: !o
  } deriving (Eq, Show, Generic)

-- chainOfThought extends the signature with the reasoning field, then projects back to the
-- bare o with FMap so the caller's program type stays Program i o. Use chainOfThoughtRaw if
-- you want to keep the reasoning visible in the output.
chainOfThought :: Signature i o -> Program i o
chainOfThought sig = FMap value (chainOfThoughtRaw sig)

chainOfThoughtRaw :: Signature i o -> Program i (WithReasoning o)
chainOfThoughtRaw sig = Predict (withReasoningField sig) emptyParams
```

**How `chainOfThought` constructs nodes.** It calls EP-3's `withReasoningField` to obtain a
`Signature i (WithReasoning o)` whose schema/instruction tell the model to produce a
`reasoning` text field *before* the answer fields (this ordering matters: the model reasons,
then commits to the answer). That becomes a `Predict` node. `chainOfThought` then wraps it in
`FMap value` to project out the bare `o`; `chainOfThoughtRaw` skips the projection. Crucially,
the reasoning-augmented node is a normal `Predict` node, so its instruction and demos are
visible to `paramsTraversal` exactly like any other node — the optimizer can tune a
chain-of-thought node's instruction with no special casing. If EP-3 does not yet provide
`withReasoningField`, implement it in EP-3 (it is EP-3's responsibility per
`docs/plans/3-generic-derived-signatures-and-structured-io.md`); pin the requirement here:
"given `Signature i o`, produce `Signature i (WithReasoning o)` with a leading `reasoning`
output field and an instruction that requests step-by-step reasoning."

**Commands.**

```bash
cd /Users/shinzui/Keikaku/bokuno/shikumi
cabal test shikumi
```

**Acceptance.** Tests: (1) `predict sig` builds a single-node program whose `foldParams`
has one element equal to `emptyParams`; (2) `chainOfThoughtRaw sig` runs through the stub
LLM and yields a `WithReasoning o` whose `reasoning` is non-empty (the stub returns a canned
reasoning + answer); (3) `chainOfThought sig` yields the bare `o`; (4) the chain-of-thought
node's `Params` is reachable and editable via `mapParamsAt 0`.


### Milestone M5 — End-to-end acceptance example

**Scope.** Tie everything together into the observable behavior named in Purpose. Add a test
module `shikumi/test/ProgramAcceptanceSpec.hs` and (optionally) an example under
`shikumi/example/` that a reader can run.

**What will exist at the end.** A self-contained test that defines two record-typed
signatures — for instance, a `Topic -> Outline` step and an `Outline -> Draft` step — uses
`predict` for each, composes them with `pipeline` into a `Program Topic Draft`, runs it
through a stub `LLM` interpreter, and asserts a typed `Draft` comes back. A second test
takes that same `Program Topic Draft`, uses `mapParamsAt 0` to set a new instruction and a
demo on the first stage, and asserts both (a) `foldParams` shows the new instruction at
index 0 and the unchanged default at index 1, and (b) running the modified program through a
*recording* stub LLM (one that captures the prompts it is asked to complete) shows the new
instruction text inside the captured first-stage prompt. The second assertion is what proves
the rewrite is not merely cosmetic — it changes what the model actually sees.

**Commands.**

```bash
cd /Users/shinzui/Keikaku/bokuno/shikumi
cabal test shikumi
```

**Acceptance.** `cabal test` runs `ProgramAcceptanceSpec` and both tests pass: the typed
two-stage pipeline returns a `Draft`, and the parameter-rewrite test observes the new
instruction both in `foldParams` and in the captured prompt. This is the plan's definition of
done.


## Concrete Steps

Run everything from the repository root `/Users/shinzui/Keikaku/bokuno/shikumi` unless
stated otherwise.

**1. Confirm the hard dependencies are present.** Check that the modules this plan imports
exist and expose the pinned interface:

```bash
cd /Users/shinzui/Keikaku/bokuno/shikumi
test -f shikumi/src/Shikumi/LLM.hs && echo "LLM present"
test -f shikumi/src/Shikumi/Signature.hs && echo "Signature present"
test -f shikumi/src/Shikumi/Adapter.hs && echo "Adapter present"
```

If any are missing, implement the corresponding sibling plan first
(`docs/plans/1-...md`, `docs/plans/3-...md`). Do not stub them away; this plan's value is in
composing real signatures and a real (if mock-interpreted) LLM effect.

**2. Add the stub LLM interpreter for tests.** In the `shikumi` test suite, add a pure
interpreter for EP-1's `LLM` effect that does not hit the network. It returns a canned
structured response and, in its "recording" variant, appends each request's rendered prompt
to a mutable accumulator (an `IORef [Text]` threaded via the effect runner, or effectful's
`State`/`Writer` effect). Sketch:

```haskell
-- A canned interpreter: every LLM call returns the same fixed response payload.
runLLMStub :: Text -> Eff (LLM : es) a -> Eff es a
-- A recording interpreter: returns canned responses AND records each request's prompt so a
-- test can assert on what the program actually sent.
runLLMRecording :: IORef [Text] -> Text -> Eff (LLM : es) a -> Eff es a
```

The exact signature depends on EP-1's `LLM` effect constructor names; consult
`shikumi/src/Shikumi/LLM.hs`. The interpreter must let the test choose the canned answer so
that `Topic -> Outline -> Draft` produces decodable JSON for each stage's output schema.

**3. Implement milestones M0→M5 in order**, building and testing after each:

```bash
cabal build shikumi
cabal test shikumi
```

Expected final transcript (illustrative):

```text
Program.SpikeSpec
  runs a single predict node           [OK]
  runs a chain-of-thought node         [OK]
  runs a two-stage pipeline            [OK]
  rewrites instruction via traversal   [OK]
Program.ParamSpec
  foldParams returns nodes in order    [OK]
  mapParamsAt edits exactly one node   [OK]
  ordering law holds (property)        [OK]
Program.SerializeSpec
  params JSON round-trip               [OK]
  shape stable across param changes    [OK]
Program.ModuleSpec
  predict builds one node              [OK]
  chainOfThought yields bare output    [OK]
Program.ProgramAcceptanceSpec
  typed two-stage pipeline returns Draft     [OK]
  rewrite changes captured prompt            [OK]

All N tests passed
```

**4. Commit.** Per the project conventions, commit on the current branch (do not create a
feature branch) with a Conventional Commits message and the three required trailers:

```text
feat(program): typed Program GADT, runProgram, parameter traversal, predict/chainOfThought

MasterPlan: docs/masterplans/1-shikumi-typed-lm-programming-framework.md
ExecPlan: docs/plans/4-typed-program-representation-and-core-modules.md
Intention: intention_01ktjgkp10ef79vpwz1cmajek9
```

Commit at each milestone boundary, not only at the end.


## Validation and Acceptance

The plan is accepted when, from the repository root, `cabal test shikumi` passes and
demonstrates the two behaviors below. These are phrased as observable input/output, not as
"a type was added".

**Behavior 1 — typed composition runs end-to-end.** Given two record-typed signatures (e.g.
`Topic -> Outline` and `Outline -> Draft`), the expression
`pipeline (predict outlineSig) (predict draftSig) :: Program Topic Draft` compiles, and
`runProgram thatProgram someTopic` evaluated under the stub `LLM` interpreter returns a
`Draft` value (a typed record), not a string. Swapping the two stages
(`pipeline (predict draftSig) (predict outlineSig)`) must *fail to compile* — verify this
once manually (or with a `should-not-typecheck` test if the suite supports it) and note it in
Surprises, because "invalid pipelines fail to compile" is a headline guarantee.

**Behavior 2 — the program is rewritable as data.** Taking the same `Program Topic Draft`
value, `foldParams` returns two `Params`; `mapParamsAt 0 (\p -> p { instructionOverride =
Just "NEW INSTRUCTION", demos = [someDemo] })` produces a new program whose `foldParams !! 0`
shows the new instruction and demo while `foldParams !! 1` is unchanged; and running the
modified program under the *recording* stub LLM yields captured prompts where the first-stage
prompt contains `"NEW INSTRUCTION"`. This proves the rewrite reaches the wire, not just the
data structure.

**Behavior 3 — parameter state round-trips through JSON.** `programParams` of a program with
distinct per-node parameters JSON-encodes and JSON-decodes to an equal vector, and
`setProgramParams` applies it onto a default-parameter program of the same shape to reproduce
the original `foldParams`; a wrong-length vector yields `Left`.

Run the whole suite:

```bash
cd /Users/shinzui/Keikaku/bokuno/shikumi
cabal test shikumi
```

Interpret a non-zero exit or any `[FAIL]` line as not-yet-accepted; fix and re-run. The
suite must be deterministic (no network; the stub LLM is pure), so a passing run is
reproducible.


## Idempotence and Recovery

All steps are additive and safe to repeat. Re-running `cabal build`/`cabal test` is
idempotent. The M0 spike module (`Shikumi.Program.Spike`) and its test are throwaway: once
M1 promotes the design and its tests pass, delete the spike module and its test-suite stanza
in a follow-up commit (`refactor(program): remove promoted spike`); keeping them is harmless
but redundant. If a milestone's tests fail, the prior milestone's committed state is intact
on the current branch, so you can revert the working tree to the last green commit
(`git stash` or `git checkout -- <files>`) and retry. No step is destructive; nothing is
deleted except the optional spike cleanup, which is recoverable from history.

If EP-3's real names differ from the pinned interface (`runSignature`, `signatureName`,
`signatureInstruction`, `withReasoningField`), adapt the imports in `Shikumi.Program` /
`Shikumi.Module`, keep the *shape* of the contract, and record the rename in the Decision
Log. Do not change the exported names of `Shikumi.Program`'s own surface (`Program`, `Params`,
`Demo`, `runProgram`, `pipeline`, `paramsTraversal`, `foldParams`, `mapParams`,
`mapParamsAt`, `ProgramShape`, `programShape`, `programParams`, `setProgramParams`), because
`docs/plans/5-...md`, `docs/plans/8-...md`, `docs/plans/9-...md`, `docs/plans/10-...md`,
`docs/plans/11-...md`, and `docs/plans/12-...md` consume them by name.


## Interfaces and Dependencies

**Libraries used and why.** `effectful` (the effect system; `Eff`, `(:>)`) so a program's
required capabilities — here `LLM` — are visible in `runProgram`'s type and interpreters can
be layered (cache, trace) by other plans. `lens` and `generic-lens` (already transitively
available via baikai's `Baikai.Prelude`, which re-exports them) for `Traversal'` and optic
combinators; the parameter interface is offered both as a lens and as a plain trio so a
caller need not learn optics. `aeson` for the JSON representation of `Demo` and for
`Params`/`ProgramShape` serialization. `text` for instruction strings.

**Modules consumed (hard dependencies, by path):**

- `docs/plans/1-shikumi-runtime-substrate-and-llm-effect-over-baikai.md` provides
  `Shikumi.LLM` (the `LLM` effect) and `Shikumi.Error` (the enumerated shikumi error type).
- `docs/plans/3-generic-derived-signatures-and-structured-io.md` provides
  `Shikumi.Signature` (`Signature i o`, `signatureInstruction`, `signatureName`,
  `withReasoningField`) and `Shikumi.Adapter` (`runSignature`, splicing `Demo`s into the
  request and parsing the structured response into a typed `o`).

**Types and signatures that must exist at the end of each milestone.**

End of **M0** (spike, throwaway): in `Shikumi.Program.Spike` — `data Program i o where
{ Predict, Compose, FMap }`, `data Params`, `data Demo`, `runProgram :: Program i o -> i ->
o` (pure stub), `paramsTraversal :: Applicative f => (Params -> f Params) -> Program i o ->
f (Program i o)`.

End of **M1**: in `Shikumi.Program` — the GADT `Program i o` with `Predict :: Signature i o
-> Params -> Program i o`, `Compose :: Program a b -> Program b c -> Program a c`, `FMap ::
(o -> o') -> Program i o -> Program i o'`; `data Params = Params { instructionOverride ::
Maybe Text, demos :: [Demo] }`; `data Demo = Demo { demoInput :: Aeson.Value, demoOutput ::
Aeson.Value }`; `emptyParams :: Params`; `pipeline :: Program a b -> Program b c -> Program a
c`; `runProgram :: (LLM :> es) => Program i o -> i -> Eff es o`.

End of **M2**: `paramsTraversal :: Applicative f => (Params -> f Params) -> Program i o -> f
(Program i o)`; `foldParams :: Program i o -> [Params]`; `mapParams :: (Params -> Params) ->
Program i o -> Program i o`; `mapParamsAt :: Int -> (Params -> Params) -> Program i o ->
Program i o`. The ordering law `foldParams (mapParamsAt n f p) == adjust n f (foldParams p)`
(in-range `n`) holds under a property test.

End of **M3**: `data ProgramShape = ShapePredict Text | ShapeCompose ProgramShape
ProgramShape | ShapeFMap ProgramShape` with aeson instances; `programShape :: Program i o ->
ProgramShape`; `programParams :: Program i o -> [Params]`; `setProgramParams :: [Params] ->
Program i o -> Either ProgramShapeError (Program i o)`; aeson `ToJSON`/`FromJSON` for
`Params` and `Demo`.

End of **M4**: in `Shikumi.Module` — `predict :: Signature i o -> Program i o`;
`chainOfThought :: Signature i o -> Program i o`; `chainOfThoughtRaw :: Signature i o ->
Program i (WithReasoning o)`; `data WithReasoning o = WithReasoning { reasoning :: Text,
value :: o }`.

End of **M5**: the test module `ProgramAcceptanceSpec` exercising all of the above against a
stub/recording `LLM` interpreter, with the three acceptance behaviors passing.

**The Params contract (the integration point #4 detail every consumer relies on).** `Params`
is the *uniform, serializable overlay* of optimizable state for one node. It carries
`instructionOverride :: Maybe Text` (`Nothing` means "use the signature's default
instruction", `Just t` overrides it) and `demos :: [Demo]` (ordered few-shot examples, each
a JSON input/output pair so the type is uniform across nodes of differing `i`/`o`). The
*effective* instruction a node uses at run time is `fromMaybe (signatureInstruction sig)
(instructionOverride ps)`; the effective demos are `demos ps`. Composite nodes (`Compose`,
`FMap`) carry **no** `Params` — they are pure structure — so the parameter count of a program
equals its number of `Predict` nodes. The traversal/fold/map functions expose these `Params`
homogeneously and in a stable left-to-right depth-first order, and `mapParamsAt n` addresses
the same `n` that `foldParams` produces. This contract is what lets the compiler
(`docs/plans/9-...md`) rewrite instructions and the optimizer (`docs/plans/10-...md`) search
over demos/instructions: they enumerate nodes with `foldParams`, score variants, and commit
edits with `mapParamsAt`/`mapParams`, then save state with `programParams` and reload it with
`setProgramParams` — none of which requires running the program or any runtime reflection.
