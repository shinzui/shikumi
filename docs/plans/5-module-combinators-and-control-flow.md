---
id: 5
slug: module-combinators-and-control-flow
title: "Module combinators and control flow"
kind: exec-plan
created_at: 2026-06-08T02:44:17Z
intention: "intention_01ktjgkp10ef79vpwz1cmajek9"
master_plan: "docs/masterplans/1-shikumi-typed-lm-programming-framework.md"
---

# Module combinators and control flow

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Shikumi (仕組み — "the mechanism behind how something works") is a Haskell framework for
writing language-model (LM) programs as ordinary, well-typed software. A *program* in
shikumi is a value of a typed data type `Program i o`, read "a program that consumes an
input of Haskell type `i` and produces an output of Haskell type `o`". This data type is a
*GADT* — a generalized algebraic data type, meaning a data type whose constructors each
carry their own type indices, so the compiler can track the input and output type of every
piece of a program. Because a `Program` is *data* (not an opaque function), it can be run
as a typed function, traversed and rewritten by optimizers, and serialized to disk. The
program representation, the function `runProgram` that executes it, the two base building
blocks `predict` (one LM call) and `chainOfThought` (one LM call that first emits a
reasoning field), and the *parameter-traversal interface* (the way tooling reaches into a
program to read and replace the tunable parameters of every node) are all owned by a
sibling plan, `docs/plans/4-typed-program-representation-and-core-modules.md`. That sibling
is a hard dependency of this plan: nothing here can be built until it has landed.

This plan delivers the **combinators and control-flow layer** that turns those base blocks
into real programs. After this change a user can take small typed programs and assemble
them into larger ones without writing a single prompt string or hand-parsing any model
output, and the compiler will reject any assembly whose types do not line up. Concretely,
a user will be able to write:

```haskell
-- Sequence two programs; only type-checks because `Draft`'s output feeds `Polish`'s input.
writeEssay :: Program Topic Essay
writeEssay = draftProgram >>> polishProgram

-- Run the same classifier five times at varying temperature and keep the majority answer.
robustClassify :: Program Review Sentiment
robustClassify = majorityVote 5 classifySentiment

-- Re-run a flaky extraction up to three times until it succeeds.
extractSafely :: Program Document Invoice
extractSafely = retry 3 extractInvoice

-- Extract, then reject any output failing a typed check, retrying on rejection.
extractValid :: Program Document Invoice
extractValid = validateRetry 3 invoiceLooksReasonable extractInvoice
```

The user-visible behaviors enabled by this plan, each demonstrated with a **mock LM** (a
deterministic, scripted stand-in for a real provider, so the examples run with no network
and no API key) are:

1. **Pipeline** — sequential composition `a -> b -> c`, surfaced as a `>>>` operator and an
   n-ary `pipeline` helper; output types thread through and mismatches fail to compile.
2. **Map** — apply one `Program a b` across a list/`Vector` of `a`, producing `[b]`, with a
   choice of sequential or bounded-concurrent execution.
3. **Parallel** — run several programs on the *same* input concurrently and collect a
   tuple of their outputs.
4. **Retry** — re-run a program up to *N* times when it fails, succeeding as soon as one
   attempt succeeds; integrates with the shikumi error type.
5. **Validate** — run a program, then check its typed output against a predicate; on
   rejection surface a validation-failure error, optionally feeding the rejection back into
   a retry loop.
6. **MajorityVote** — sample a program *K* times (varying temperature) and return the modal
   (most-frequent) typed output.
7. **Ensemble** — run several *distinct* programs and fold their outputs together with a
   user-supplied reducer.

The "see it working" proof is a test suite (`cabal test shikumi:combinators`) whose cases
assert observable aggregate behavior: a MajorityVote over five scripted samples returns the
value that appeared three times; a Retry whose mock fails once then succeeds returns the
success and records exactly two attempts; a Pipeline threads an intermediate type that
never appears in its own signature; a Map runs a per-element program over a five-element
input and returns five outputs.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M0 (prototype): confirm the EP-4 GADT and parameter-traversal interface are present
      and stable; write a throwaway `Pipeline` + `Retry` against a hand-rolled mock LM to
      validate that new constructors run, traverse, and serialize before committing the
      full surface.
- [ ] M1: `Shikumi.Combinator` module skeleton + the mock LM test harness
      (`Shikumi.LLM.Mock`) and the `cabal test shikumi:combinators` target wired up.
- [ ] M2: `Pipeline` — `>>>`, `pipeline`, run/traverse/serialize, type-threading test.
- [ ] M3: `Map` — `mapP`, sequential and bounded-concurrent interpretation, list test.
- [ ] M4: `Parallel` — `parallel2`, `parallelN`, concurrent run, tuple-collection test.
- [ ] M5: `Retry` — `retry`, attempt counting, error integration, succeeds-on-2nd test.
- [ ] M6: `Validate` — `validate`, `validateRetry`, validation-failure error, feedback test.
- [ ] M7: `MajorityVote` — `majorityVote`, temperature schedule, modal aggregation test.
- [ ] M8: `Ensemble` — `ensemble`, reducer fold, heterogeneous-program test.
- [ ] M9: traversal/serialization round-trip test covering every new constructor; update
      the MasterPlan Progress row for EP-5.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Add combinators as **new GADT constructors of `Program i o`** (the type owned
  by `docs/plans/4-typed-program-representation-and-core-modules.md`), not as opaque
  functions wrapping `runProgram`.
  Rationale: integration point #4 in the MasterPlan
  (`docs/masterplans/1-shikumi-typed-lm-programming-framework.md`) requires that every node
  of a program remain (a) runnable, (b) traversable/rewritable by optimizers, and (c)
  serializable. A combinator implemented as an opaque Haskell function would hide its
  sub-programs from the parameter traversal, so an optimizer could never reach the
  `predict` nodes nested inside a `MajorityVote` or a `Pipeline`. Constructors keep the
  whole tree inspectable. The lone exceptions are *ergonomic surface* helpers (`>>>`,
  `pipeline`, `parallelN`) that are thin smart constructors building those constructors;
  they introduce no new runtime behavior.
  Date: 2026-06-07.

- Decision: Express concurrency for `Parallel` and `Map` through the **`Concurrent` effect
  from `effectful`** (`Effectful.Concurrent`, `Effectful.Concurrent.Async`), adding
  `Concurrent :> es` to the constraint of `runProgram` *only on the concurrent code paths*
  by way of a small capability the interpreter requests, rather than forcing every program
  to demand `Concurrent`.
  Rationale: `effectful` already provides `concurrently`, `mapConcurrently`, and
  `pooledMapConcurrentlyN` over `Eff es` (verified in the local checkout at
  `effectful/effectful/src/Effectful/Concurrent/Async.hs`). Using these keeps shikumi's "no
  global mutable state, capabilities visible in the type" stance intact. See "Concurrency
  model" in Context and Orientation for the exact constraint shape chosen.
  Date: 2026-06-07.

- Decision: `MajorityVote` aggregates by **modal equality over `Eq o`** by default, with an
  overload (`majorityVoteBy`) taking an explicit aggregation function for outputs that are
  not usefully `Eq` (e.g. long free text where exact equality is too strict).
  Rationale: the modal vote is the DSPy-style behavior the user expects, and `Eq` is the
  smallest constraint that makes "most frequent" well-defined. The explicit overload covers
  the realistic case where outputs need normalization before counting.
  Date: 2026-06-07.

- Decision: `Ensemble`'s aggregation is a **user-supplied total reducer** `([r] -> o)` over
  a homogeneous result type `r`, with `MajorityVote` defined as the special case
  `ensemble`-of-one-program-sampled-K-times plus the modal reducer.
  Rationale: keeps the two aggregating combinators sharing one well-tested reduction path
  and avoids inventing a bespoke partial aggregation that could fail at runtime.
  Date: 2026-06-07.

- Decision: `Retry` and `Validate` integrate with the **shikumi error type owned by
  `docs/plans/1-shikumi-runtime-substrate-and-llm-effect-over-baikai.md`** (the enumerated
  error covering invalid JSON, missing field, schema mismatch, validation failure, provider
  failure, timeout, budget exceeded). `Validate` raises the *validation-failure* variant of
  that type on rejection; `Retry` decides whether to retry by inspecting the error value.
  Rationale: integration point #1 requires every plan to use the one shared error type
  rather than inventing its own.
  Date: 2026-06-07.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This section assumes you have never seen this repository. Read it fully before editing.

**Where things live.** The shikumi repository root is
`/Users/shinzui/Keikaku/bokuno/shikumi`. At the time this plan was authored the repository
contains only `docs/` and `.claude/`; the Haskell project itself is scaffolded by the
substrate plan, `docs/plans/1-shikumi-runtime-substrate-and-llm-effect-over-baikai.md`,
which establishes a multi-package Cabal project (a `cabal.project` at the root) following
the package layout below. You do not create that scaffolding here; you add a module to the
already-existing core package.

The core package is named `shikumi`. Its modules live under
`<repo-root>/shikumi/src/Shikumi/`. The modules this plan depends on and the module it adds
are:

- `Shikumi.Program` — owned by `docs/plans/4-typed-program-representation-and-core-modules.md`.
  Defines the GADT `Program i o`, the executor `runProgram`, the base constructors used by
  `predict`/`chainOfThought`, and the parameter-traversal interface. **This plan edits this
  module to add new constructors**, then puts the ergonomic surface (operators and helpers)
  in a new module.
- `Shikumi.Module` — owned by the same sibling plan. Defines `predict` and
  `chainOfThought`, the leaf programs you will compose in examples and tests.
- `Shikumi.Error` — owned by
  `docs/plans/1-shikumi-runtime-substrate-and-llm-effect-over-baikai.md`. Defines the
  shikumi error type. You consume its *validation-failure* and *retry-relevant* variants.
- `Shikumi.LLM` — owned by the same substrate plan. Defines the `effectful` effect `LLM`
  (one provider-neutral LM call) and its interpreter over the transport library *baikai*
  (`/Users/shinzui/Keikaku/bokuno/baikai`). You do not call baikai directly; you only ever
  go through the `LLM` effect, and in tests you supply a **mock interpreter** of it.
- `Shikumi.Combinator` — **new module, owned by this plan**. Holds the ergonomic surface
  (operators and helper smart constructors) and re-exports the new constructors. New GADT
  constructors themselves live in `Shikumi.Program` (because a GADT's constructors must be
  declared with the type), but everything a user imports to *use* combinators lives here.

**What a GADT is, concretely, and why it matters here.** A normal Haskell data type's
constructors all produce the same type. A GADT lets each constructor declare a more
specific result type. The sibling plan's `Program i o` is a GADT roughly like this (the
exact constructor set is owned by that plan; this is the shape you can rely on):

```haskell
-- Owned by docs/plans/4-typed-program-representation-and-core-modules.md.
-- Reproduced here ONLY so this plan is self-contained; do not copy it into code.
data Program i o where
  Predict   :: Signature i o -> Params -> Program i o
  Compose   :: Program a b -> Program b c -> Program a c
  FMap      :: (o -> o') -> Program i o -> Program i o'
  -- ... chainOfThought and others
```

`Compose` already gives sequential composition: it only type-checks when the first
program's output `b` equals the second program's input. So this plan's `Pipeline` is *not*
a brand-new runtime idea — it is the **ergonomic surface over `Compose`** (an operator and
an n-ary helper). If, when you read the landed EP-4, `Compose` is named differently or
absent, this plan adapts: where the constructor exists, build only the surface; where it
does not, add it as a constructor exactly as the other combinators below are added.

**The parameter-traversal interface (the thing optimizers depend on).** EP-4 exposes a way
to read and rewrite the tunable parameters (`Params`: the instruction text and the
demonstrations, the *optimizable* fields) of *every leaf node* in a program. The exact
surface is owned by EP-4; this plan relies on it having the shape of *either* a `lens`
traversal `programParams :: Traversal' (Program i o) Params` *or* a pair
`foldParams :: Program i o -> [Params]` and
`mapParams :: (Params -> Params) -> Program i o -> Program i o`. Whichever EP-4 ships, the
contract every new constructor in this plan must honor is: **the traversal must descend
into all sub-programs of the new constructor.** A `Pipeline a b c` must expose the params of
both halves; a `MajorityVote` must expose the params of the single program it samples; an
`Ensemble` must expose the params of every member. Concretely, when EP-4 extends the
traversal with a case per constructor, this plan's constructors each recurse into their
`Program` children. M9 verifies this end-to-end: after you replace every leaf's params via
the traversal and then run, the run must reflect the replacement, including for params
buried inside a `MajorityVote` inside a `Pipeline`.

**Serialization.** EP-4 makes `Program i o` serializable (so compiled/optimized programs
can be saved and replayed). Each new constructor must participate: it serializes its tag
plus its scalar parameters (e.g. `Retry`'s attempt count, `MajorityVote`'s sample count and
temperature schedule) and recursively serializes its sub-programs. Pure *functions* carried
by constructors (a reducer `[r] -> o`, an aggregation `[o] -> o`, a predicate `o -> Bool`)
cannot be serialized; the way EP-4 handles non-serializable payloads (e.g. a registry of
named functions, or marking those nodes as "opaque, not round-trippable") is the rule this
plan follows. The pragmatic stance taken here: `Pipeline`, `Map`, `Parallel`, `Retry`, and
`MajorityVote` (modal, default `Eq`) are **fully serializable**; `validate`, `ensemble`, and
`majorityVoteBy` carry user functions and are serializable only if EP-4's function-registry
mechanism is used. M9's round-trip test covers the fully-serializable set and asserts a
clear, typed error (not a crash) for the function-carrying set when no registry name is
supplied.

**The shikumi error type.** Owned by
`docs/plans/1-shikumi-runtime-substrate-and-llm-effect-over-baikai.md`. It is an enumerated
sum type whose variants include at least: invalid JSON, missing field, schema mismatch,
**validation failure** (carrying a human-readable reason), provider failure, timeout, and
budget exceeded. Programs surface errors through an error channel in the effect stack (an
`Error ShikumiError :> es` constraint or an `Eff es (Either ShikumiError o)` result — EP-1
owns which). This plan treats "a program failed" as "the error channel carried a
`ShikumiError`". `Retry` catches such failures and re-runs; `Validate` *produces* the
validation-failure variant. You will define the term "failure" precisely in M5.

**The concurrency model (decided, stated once, used by `Parallel` and `Map`).** The
`effectful` library provides a `Concurrent` effect. Its module
`Effectful.Concurrent.Async` exposes (verified in the local checkout at
`/Users/shinzui/Keikaku/hub/haskell/effectful-project/effectful/effectful/src/Effectful/Concurrent/Async.hs`):

```haskell
concurrently            :: Concurrent :> es => Eff es a -> Eff es b -> Eff es (a, b)
mapConcurrently         :: (Traversable t, Concurrent :> es) => (a -> Eff es b) -> t a -> Eff es (t b)
pooledMapConcurrentlyN  :: (Traversable t, Concurrent :> es) => Int -> (a -> Eff es b) -> t a -> Eff es (t b)
replicateConcurrently   :: Concurrent :> es => Int -> Eff es a -> Eff es [a]
```

`concurrently` runs two actions in parallel and returns both results; `mapConcurrently`
runs an action over a traversable in parallel; `pooledMapConcurrentlyN n` does the same but
never runs more than `n` actions at once (bounded concurrency, which matters because each
action is an LM call subject to provider rate limits, handled by EP-1);
`replicateConcurrently k` runs the same action `k` times in parallel. The decision:
**`Parallel` uses `concurrently` (two) and a fold over `mapConcurrently`/`Conc` (several);
`Map` defaults to bounded `pooledMapConcurrentlyN` with a caller-chosen width and offers a
strictly-sequential variant; `MajorityVote` uses `replicateConcurrently` over the sampling
loop.** All three add `Concurrent :> es` to the constraint of their interpretation branch.
Because `runProgram` is the single executor, the cleanest shape (which this plan adopts and
M1 records) is for the *concurrent constructors' interpretation* to require `Concurrent :>
es` in the type of `runProgram`, so any program containing a `Parallel`/`Map`/`MajorityVote`
node carries `Concurrent :> es` in its type, exactly as it carries `LLM :> es`. Programs
that contain none of these run without `Concurrent`. (If EP-4 fixed `runProgram`'s
constraint to a closed set that omits `Concurrent`, M0 detects this and the plan falls back
to a separate `runProgramC :: (LLM :> es, Concurrent :> es, ...) => ...` executor for the
concurrent surface, documented in the Decision Log at that time.)

**The mock LM (how every test runs offline).** A *mock LM* is a fake interpreter of the
`LLM` effect that returns scripted answers instead of calling a provider. You add it as
`Shikumi.LLM.Mock` in the test tree (or core test support module). It is the single most
important test ingredient: it lets a test say "the next three LM calls return X, then fail,
then return Y" and then assert what a combinator does with that script. Its shape:

```haskell
-- A scripted, deterministic interpreter of the LLM effect for tests.
-- Each call pops the next scripted reply; a reply may be a success or a failure,
-- and may depend on the request's temperature so MajorityVote tests can vary samples.
data MockReply = MockOk Value | MockFail ShikumiError
runMockLLM :: [MockReply] -> Eff (LLM : es) a -> Eff es a
-- plus a counting variant that also returns how many LM calls were made:
runMockLLMCounting :: [MockReply] -> Eff (LLM : es) a -> Eff es (a, Int)
```

The exact `LLM` effect operations are owned by EP-1; the mock interprets whatever single
"complete this request" operation that effect exposes, ignoring everything except the
fields a test needs (the temperature, to script per-sample answers). M1 builds this.


## Plan of Work

The work proceeds in ten milestones (M0–M9). M0 is an explicit prototype that de-risks the
two assumptions everything else rests on: that EP-4's GADT accepts new constructors which
`runProgram` can interpret, and that EP-4's parameter traversal and serialization can be
extended to those constructors. M1 builds shared scaffolding. M2–M8 each add one combinator
(surface + constructor + interpretation + traversal/serialization wiring + a behavior
test). M9 proves the cross-cutting properties (traversal reaches nested nodes; serialization
round-trips) and updates the MasterPlan.

Throughout, follow the repository conventions: every commit message uses Conventional
Commits (`feat:`, `test:`, `refactor:`, etc.) and carries the three trailers

```text
MasterPlan: docs/masterplans/1-shikumi-typed-lm-programming-framework.md
ExecPlan: docs/plans/5-module-combinators-and-control-flow.md
Intention: intention_01ktjgkp10ef79vpwz1cmajek9
```

Commit at the end of every milestone. Do not create a feature branch; commit to the current
branch.

### M0 — Prototype: new constructors run, traverse, serialize

Scope: before committing to the full surface, prove the keystone assumption against the
*actual* landed EP-4. Read `Shikumi.Program` and `Shikumi.Module` as they exist in the
tree. Identify (a) whether sequential composition already exists (likely `Compose`), (b)
the precise parameter-traversal surface (`Traversal'` vs. `foldParams`/`mapParams`), (c) how
serialization is structured, and (d) `runProgram`'s exact constraint. Then, in a throwaway
test module, add two trial constructors — a `PipelineP` (if `Compose` is absent) and a
`RetryP Int (Program i o)` — wire them into `runProgram`, the traversal, and the serializer,
and write three asserting tests: one that runs a two-stage pipeline against the mock LM, one
that runs a retry that fails-then-succeeds, and one that reads the params of the leaf inside
the retry through the traversal. At the end of M0 you will have written down, in this plan's
Decision Log, the exact EP-4 surface you are building against (names, constraints,
serialization style), so M1–M9 are unambiguous. If any assumption is false (e.g. the
traversal cannot be extended without EP-4 changes), record it and coordinate, since this
plan hard-depends on EP-4.

Commands to run (from the repo root):

```bash
cabal build shikumi
cabal test shikumi:combinators --test-options="--match prototype"
```

Acceptance: the three prototype tests pass, and the Decision Log names the concrete EP-4
surface (traversal type, serialization style, `runProgram` constraint). The throwaway
constructors may then be deleted or promoted in M2/M5.

### M1 — `Shikumi.Combinator` skeleton + mock LM harness + test target

Scope: create the new module `<repo-root>/shikumi/src/Shikumi/Combinator.hs` (exporting
nothing yet but the module header and an `import`-friendly stub), create the mock LM at
`<repo-root>/shikumi/test/Shikumi/LLM/Mock.hs` with `MockReply`, `runMockLLM`, and
`runMockLLMCounting`, and add a test-suite stanza `shikumi:combinators` to the `shikumi`
package's `.cabal` file pointing at `<repo-root>/shikumi/test/CombinatorSpec.hs`. Use a
test framework already chosen by EP-1's scaffolding (e.g. `hspec` or `tasty`); match it. Add
one trivial passing test so the target is green.

Commands:

```bash
cabal test shikumi:combinators
```

Acceptance: `cabal test shikumi:combinators` builds and reports one passing test. The mock
LM compiles and can interpret a single scripted `predict` call (a smoke test asserting that
a `predict` program run under `runMockLLM [MockOk <scripted-json>]` returns the decoded
value).

### M2 — Pipeline

Scope: deliver sequential composition as ergonomic surface over EP-4's `Compose` (or, if
absent, as a new constructor `Pipeline :: Program a b -> Program b c -> Program a c`). In
`Shikumi.Combinator` add the operator and the n-ary helper (signatures in Interfaces and
Dependencies). Wire `runProgram` (run the first, feed its output to the second),
the traversal (descend into both halves), and serialization (tag + both children). Write a
test that builds `a >>> b` where the intermediate type `b` does not appear in the composite
signature, runs it against a mock that scripts both stages, and asserts the final typed
output; plus a *negative* compile test (a commented example, or an `expect-fail`
type-error test if the harness supports it) showing that composing mismatched types is
rejected.

Commands:

```bash
cabal test shikumi:combinators --test-options="--match Pipeline"
```

Acceptance: a pipeline of two scripted stages returns the second stage's output; the
intermediate type is threaded but absent from the composite type; mismatched composition
does not compile.

### M3 — Map

Scope: add `Map :: Program a b -> Program [a] [b]` (or a `Vector`-typed variant; pick `[]`
for the constructor and offer a `Vector` helper that converts) and the surface `mapP`. Its
interpretation runs the inner program once per element. Provide two execution strategies:
`mapP` (bounded-concurrent via `pooledMapConcurrentlyN` with a caller-supplied width) and
`mapSeqP` (strictly sequential, no `Concurrent` constraint). Wire traversal (descend into
the single inner program) and serialization (tag + width + child). Write a test over a
five-element input asserting five outputs in order, using a mock scripted with five replies,
and a second test asserting that `mapSeqP` consumes the scripted replies in input order.

Commands:

```bash
cabal test shikumi:combinators --test-options="--match Map"
```

Acceptance: `mapP` over five inputs yields five outputs preserving element order; the
sequential variant compiles without `Concurrent :> es`; the concurrent variant requires it.

### M4 — Parallel

Scope: add `Parallel :: Program i a -> Program i b -> Program i (a, b)` and the surface
`parallel2` plus an n-ary `parallelN` helper for a homogeneous list of programs producing
`Program i [o]` (the simplest heterogeneous case stays the binary tuple; deeper tuples are
built by nesting `parallel2`). Interpretation runs both/all sub-programs on the *same* input
via `concurrently` / a `Conc` fold, adding `Concurrent :> es`. Wire traversal (descend into
both children) and serialization. Write a test that runs two scripted programs on one input
and asserts the collected tuple, and a test that `parallelN` over three programs returns a
three-element list.

Commands:

```bash
cabal test shikumi:combinators --test-options="--match Parallel"
```

Acceptance: `parallel2 p q` on input `x` returns `(p x, q x)` from scripted mocks;
`parallelN [p,q,r]` returns `[p x, q x, r x]`; both require `Concurrent :> es`.

### M5 — Retry

Scope: add `Retry :: Int -> Program i o -> Program i o` and the surface `retry`. Define
"failure" precisely: a run fails when its execution yields a `ShikumiError` on the error
channel (the variants owned by EP-1). `retry n p` runs `p`; on failure it re-runs, up to `n`
total attempts; it returns the first success, or the *last* error if all attempts fail.
Optionally accept a predicate on the error (`retryWhen :: (ShikumiError -> Bool) -> Int ->
Program i o -> Program i o`) so callers can retry only transient errors (e.g. timeout,
provider failure) and not, say, budget-exceeded. Wire traversal (descend into the inner
program) and serialization (tag + count + child; the predicate variant follows EP-4's
function-payload rule). Write a test using `runMockLLMCounting` whose script is
`[MockFail timeoutErr, MockOk good]`: assert the result is the success **and** exactly two
LM calls were made; a second test where all three attempts fail asserts the last error is
surfaced and three calls were made.

Commands:

```bash
cabal test shikumi:combinators --test-options="--match Retry"
```

Acceptance: a fail-then-succeed script returns the success after exactly two attempts; an
all-fail script surfaces the final error after exactly `n` attempts; `retryWhen` skips
non-matching errors after a single attempt.

### M6 — Validate

Scope: add `Validate :: (o -> Either Text o) -> Program i o -> Program i o` and the
surfaces `validate` (predicate form: `(o -> Bool)` plus a reason string) and `validateRetry`
(combine `Validate` with `Retry` so a rejected output triggers re-running the inner program,
threading the validator's reason into the retry as context where EP-4/EP-1 permit feedback).
A validator returns `Right o` to accept (optionally normalizing) or `Left reason` to reject;
on rejection the interpretation raises the **validation-failure** variant of the shikumi
error carrying `reason`. Wire traversal (descend into the inner program; the validator is a
function payload) and serialization (function-payload rule). Write a test where the mock
returns a value the validator rejects, asserting the surfaced error is the validation-failure
variant with the expected reason; and a `validateRetry` test where the first sample is
rejected and the second accepted, asserting two attempts and the accepted output.

Commands:

```bash
cabal test shikumi:combinators --test-options="--match Validate"
```

Acceptance: a rejected output surfaces the validation-failure error with the reason string;
`validateRetry 2` recovers when the second attempt passes; an accepted (and normalized)
output is returned unchanged-or-normalized.

### M7 — MajorityVote

Scope: add `MajorityVote :: Int -> TempSchedule -> Program i o -> Program i o` (the
`Eq o`-modal default) and `majorityVoteBy :: Int -> TempSchedule -> ([o] -> o) -> Program i
o -> Program i o`. `TempSchedule` is a small value describing how to vary temperature across
the `K` samples (e.g. a fixed list of temperatures, or a base + spread); define it in this
module. Interpretation samples the inner program `K` times via `replicateConcurrently`,
each sample tagged with its scheduled temperature (passed through the `LLM` effect/`Params`
so the mock can branch on it), collects the `K` outputs, and reduces: the default picks the
modal value (most frequent under `Eq`, ties broken by first-seen order); `majorityVoteBy`
applies the supplied reducer. Adds `Concurrent :> es`. Wire traversal (descend into the
single inner program) and serialization (default form fully serializable; the `By` form
follows the function-payload rule). Write the headline test: a mock scripted so that five
samples produce, in order, `A, B, A, A, B`; assert `majorityVote 5 sched p` returns `A`.
Add a tie test (`A, B`) asserting first-seen wins, and a `majorityVoteBy` test using a
custom reducer (e.g. average a numeric field).

Commands:

```bash
cabal test shikumi:combinators --test-options="--match MajorityVote"
```

Acceptance: over five samples `A,B,A,A,B` the result is `A`; ties resolve to the
first-seen value; `majorityVoteBy` applies the custom reducer; sampling varies temperature
per the schedule (assert via the mock recording the temperatures it saw).

### M8 — Ensemble

Scope: add `Ensemble :: [Program i r] -> ([r] -> o) -> Program i o` and the surface
`ensemble`. Interpretation runs every member program on the same input (concurrently, via
the M4 path) collecting `[r]`, then applies the total reducer to produce `o`. Note that
`MajorityVote` is then expressible as `ensemble (replicate k p) modalReducer` modulo the
temperature schedule; keep both (MajorityVote's per-sample temperature variation is its
distinguishing feature). Wire traversal (descend into every member program) and
serialization (members serialize recursively; reducer follows the function-payload rule).
Write a test with three distinct scripted member programs and a reducer that, say,
concatenates their text outputs, asserting the folded result; and a test asserting the
traversal reaches a leaf buried inside member #2.

Commands:

```bash
cabal test shikumi:combinators --test-options="--match Ensemble"
```

Acceptance: `ensemble [p,q,r] reduce` on input `x` returns `reduce [p x, q x, r x]`; the
parameter traversal reaches leaves inside every member.

### M9 — Cross-cutting: traversal reaches nested nodes; serialization round-trips

Scope: prove the two integration-point #4 properties across *all* new constructors. Build a
deliberately deep program — e.g. `pipeline [retry 2 (majorityVote 3 sched predictA),
validate ok predictB]` — and (1) use EP-4's traversal to read every leaf's params, asserting
the count and identity of leaves reached (must include the leaf inside the `MajorityVote`
inside the `Retry` inside the `Pipeline`); (2) use the traversal to *replace* every leaf's
instruction with a sentinel, run the program under a mock that echoes the instruction it
received, and assert the sentinel reached the deepest leaf; (3) serialize the
fully-serializable subset and deserialize it, asserting structural equality and identical
run behavior; (4) assert that serializing a function-carrying node (an `ensemble` with an
anonymous reducer) yields the typed "opaque/unregistered function" error rather than a
crash. Finally, update the MasterPlan Progress line for EP-5
(`docs/masterplans/1-shikumi-typed-lm-programming-framework.md`, the row
`- [ ] EP-5: Retry, Validate, Pipeline, Map, Parallel, MajorityVote, Ensemble`) to checked,
and write the Outcomes & Retrospective entry here.

Commands:

```bash
cabal test shikumi:combinators
```

Acceptance: the deep-program traversal reaches every leaf including the deepest; a sentinel
written through the traversal is observed at the deepest leaf at run time; the serializable
subset round-trips to a structurally-equal program that runs identically; a function-carrying
node serializes to a clear typed error; the full `shikumi:combinators` suite is green.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/shikumi` unless
stated otherwise.

First, confirm the dependency is present and read it:

```bash
cabal build shikumi
ls shikumi/src/Shikumi/Program.hs shikumi/src/Shikumi/Module.hs
```

You should see `Shikumi.Program` and `Shikumi.Module` build cleanly. Read both, plus
`Shikumi.Error` and `Shikumi.LLM`, to learn the exact constructor set, the traversal
surface, the serialization style, and `runProgram`'s constraint. Record them in the Decision
Log (M0).

A representative expected transcript after M1 (your framework's exact wording may differ):

```text
$ cabal test shikumi:combinators
Build profile: -w ghc -O1
...
Shikumi.Combinator
  smoke
    predict through mock LLM returns decoded value [OK]

All 1 tests passed (0.01s)
```

A representative expected transcript after M7 (the headline aggregation proof):

```text
$ cabal test shikumi:combinators --test-options="--match MajorityVote"
Shikumi.Combinator
  MajorityVote
    five samples A,B,A,A,B -> A [OK]
    tie A,B resolves to first-seen A [OK]
    majorityVoteBy averages the numeric field [OK]
    sampling varied temperature per schedule [OK]

All 4 tests passed (0.03s)
```

A representative expected transcript after M5 (retry attempt counting):

```text
$ cabal test shikumi:combinators --test-options="--match Retry"
Shikumi.Combinator
  Retry
    fail-then-succeed returns success after exactly 2 attempts [OK]
    all-fail surfaces final error after exactly 3 attempts [OK]
    retryWhen skips non-matching errors after 1 attempt [OK]

All 3 tests passed (0.02s)
```

After M9, update the MasterPlan and verify the whole suite:

```bash
cabal test shikumi:combinators
```

This section must be updated with the *actual* transcripts as milestones complete.


## Validation and Acceptance

The overall acceptance for this plan is observable, not structural: **a runnable example
per combinator, driven by a mock LM, exhibiting the expected aggregate behavior**, all under
`cabal test shikumi:combinators`. Specifically, after this plan a reader can run that one
command and observe:

- Pipeline threads an intermediate type that is absent from the composite signature and
  returns the second stage's output (M2). Composing mismatched types fails to compile (M2,
  negative test).
- Map produces exactly one output per input, in order, for both the concurrent and
  sequential strategies (M3).
- Parallel returns the tuple/list of every sub-program's output on a shared input (M4).
- Retry returns the success of a fail-then-succeed script after exactly two attempts, and
  surfaces the final error after exactly `n` attempts when all fail (M5).
- Validate surfaces the shikumi validation-failure error with the validator's reason on
  rejection, and `validateRetry` recovers on a later passing attempt (M6).
- MajorityVote over the script `A,B,A,A,B` returns `A`; ties resolve to first-seen;
  `majorityVoteBy` applies a custom reducer (M7).
- Ensemble returns `reduce [p x, q x, r x]` over distinct member programs (M8).
- The parameter traversal reaches every leaf, including the deepest nested one; a value
  written through the traversal is observed at run time; the serializable subset round-trips;
  a function-carrying node serializes to a typed error rather than crashing (M9).

A test is only acceptance if it would have **failed before** the corresponding milestone and
**passes after**. For each combinator, write the test first against the empty surface
(it fails to compile or fails at runtime), then implement until it passes.


## Idempotence and Recovery

Every milestone is additive: it adds a constructor, surface functions, and a test file
section. Re-running `cabal build` and `cabal test shikumi:combinators` is always safe and
repeatable; nothing here mutates external state, touches a network, or writes outside the
repository (the mock LM is in-process and deterministic). If a milestone is interrupted
mid-way, the Progress checklist records which constructor is half-done; resume by completing
its interpretation, traversal, serialization, and test in that order. If an edit to
`Shikumi.Program` breaks the build of the owning sibling plan's tests, revert just that edit
(the new constructor is self-contained — a new GADT line, a new `runProgram` case, a new
traversal case, a new serialization case) and reapply it minimally. Because the new
constructors only *add* cases, existing programs and tests remain valid; there is no
migration and no destructive step.


## Interfaces and Dependencies

**Libraries.** `effectful` and `effectful-core` (the effect system; `Eff`, `:>`, `interpret`,
`send`), `Effectful.Concurrent` / `Effectful.Concurrent.Async` (the `Concurrent` effect and
`concurrently`, `mapConcurrently`, `pooledMapConcurrentlyN`, `replicateConcurrently`),
`lens` + `generic-lens` (for the traversal if EP-4 ships a `Traversal'`), `containers` (for
`Map`-based mode counting in `MajorityVote`), `vector` (the `Vector` `Map` helper), `text`,
and `aeson` (`Value` for mock replies and serialization). All are already dependencies of
the `shikumi` core package per the package layout established by
`docs/plans/1-shikumi-runtime-substrate-and-llm-effect-over-baikai.md`.

**Consumed from siblings (by path).**
`docs/plans/4-typed-program-representation-and-core-modules.md` provides `Shikumi.Program`
(the `Program i o` GADT, `runProgram`, the base constructors, the parameter-traversal
interface, and the serializer) and `Shikumi.Module` (`predict`, `chainOfThought`).
`docs/plans/1-shikumi-runtime-substrate-and-llm-effect-over-baikai.md` provides
`Shikumi.LLM` (the `LLM` effect) and `Shikumi.Error` (`ShikumiError`, including the
validation-failure variant).

**Types and signatures that must exist at the end of each milestone.** New GADT
constructors are added to `Shikumi.Program` (declared with the type); ergonomic surface and
re-exports live in `Shikumi.Combinator`.

End of M1 (`Shikumi.LLM.Mock`, test tree):

```haskell
data MockReply = MockOk Aeson.Value | MockFail ShikumiError
runMockLLM         :: [MockReply] -> Eff (LLM : es) a -> Eff es a
runMockLLMCounting :: [MockReply] -> Eff (LLM : es) a -> Eff es (a, Int)
```

End of M2 (Pipeline), in `Shikumi.Combinator`:

```haskell
(>>>)    :: Program a b -> Program b c -> Program a c
infixr 1 >>>
pipeline :: [Program a a] -> Program a a   -- n-ary, same-type stages; typed chains use (>>>)
```

(If EP-4 lacks `Compose`, also add `Pipeline :: Program a b -> Program b c -> Program a c`
to `Shikumi.Program`.)

End of M3 (Map), constructor in `Shikumi.Program`, surface in `Shikumi.Combinator`:

```haskell
data Program i o where
  Map :: Program a b -> Program [a] [b]
  -- ... (other constructors)

mapP    :: Int -> Program a b -> Program [a] [b]    -- bounded concurrency width
mapSeqP :: Program a b -> Program [a] [b]           -- strictly sequential
mapVecP :: Int -> Program a b -> Program (Vector a) (Vector b)
```

End of M4 (Parallel):

```haskell
data Program i o where
  Parallel :: Program i a -> Program i b -> Program i (a, b)

parallel2 :: Program i a -> Program i b -> Program i (a, b)
parallelN :: [Program i o] -> Program i [o]
```

End of M5 (Retry):

```haskell
data Program i o where
  Retry :: Int -> Program i o -> Program i o

retry     :: Int -> Program i o -> Program i o
retryWhen :: (ShikumiError -> Bool) -> Int -> Program i o -> Program i o
```

End of M6 (Validate):

```haskell
data Program i o where
  Validate :: (o -> Either Text o) -> Program i o -> Program i o

validate      :: (o -> Bool) -> Text -> Program i o -> Program i o
validateRetry :: Int -> (o -> Bool) -> Text -> Program i o -> Program i o
```

End of M7 (MajorityVote):

```haskell
data TempSchedule = TempFixed [Double] | TempSpread { base :: Double, spread :: Double }

data Program i o where
  MajorityVote :: Eq o => Int -> TempSchedule -> Program i o -> Program i o

majorityVote   :: Eq o => Int -> TempSchedule -> Program i o -> Program i o
majorityVoteBy :: Int -> TempSchedule -> ([o] -> o) -> Program i o -> Program i o
```

End of M8 (Ensemble):

```haskell
data Program i o where
  Ensemble :: [Program i r] -> ([r] -> o) -> Program i o

ensemble :: [Program i r] -> ([r] -> o) -> Program i o
```

**Executor constraint.** Every new constructor must be handled by `runProgram`. Its type at
the end of this plan, for any program containing a concurrent constructor
(`Map` concurrent path / `Parallel` / `MajorityVote`), is:

```haskell
runProgram :: (LLM :> es, Error ShikumiError :> es, Concurrent :> es)
           => Program i o -> i -> Eff es o
```

Programs containing none of those run with only `(LLM :> es, Error ShikumiError :> es)`.
The precise error-channel encoding (an `Error` effect vs. an `Either` result) is owned by
`docs/plans/1-shikumi-runtime-substrate-and-llm-effect-over-baikai.md`; M0 records which it
is, and this plan conforms.

**Traversal contract.** Whatever surface EP-4 ships
(`programParams :: Traversal' (Program i o) Params`, or
`foldParams`/`mapParams`), each new constructor's case must recurse into all of its
`Program` children so optimizers reach every nested leaf. This is verified in M9.

**Serialization contract.** `Pipeline`/`Compose`, `Map`, `Parallel`, `Retry`, and the
default `MajorityVote` are fully serializable (tag + scalar fields + recursively-serialized
children). `Validate`, `Ensemble`, `majorityVoteBy`, and `retryWhen` carry user functions
and serialize only via EP-4's function-registry mechanism; absent a registered name, their
serializer yields the typed "opaque/unregistered function" error (verified in M9).
