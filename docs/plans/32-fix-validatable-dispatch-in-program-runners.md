---
id: 32
slug: fix-validatable-dispatch-in-program-runners
title: "Fix Validatable Dispatch in Program Runners"
kind: exec-plan
created_at: 2026-07-02T03:30:15Z
intention: "intention_01kwgdyxm7ehh8yys1pp4wf1zr"
master_plan: "docs/masterplans/5-core-runtime-correctness-and-wire-fidelity.md"
---

# Fix Validatable Dispatch in Program Runners

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Shikumi lets a user attach a domain rule to an output record by writing an instance of the
`Validatable` class — for example "a summary must have 3 to 5 bullet points". The framework
promises that when a language model's reply decodes into that record, the rule runs and a
violation surfaces as a typed `ValidationFailure` error. Today that promise is broken for
every program runner: a rule written by the user is silently ignored when the program is
executed through `runProgram`, `runProgramConc`, or `streamProgram`, because the runners
resolve the `Validatable` constraint against a catch-all "always valid" instance instead of
the user's instance. The bug is invisible: everything compiles, everything runs, and invalid
model output flows through as if it were valid. One of the repo's own worked examples
(`shikumi-jitsurei/app/Predict.hs`) even documents the broken behavior as if it were a
design choice.

After this change, a failing `Validatable` rule reliably produces
`Left (ValidationFailure …)` through every runner and through the `chainOfThought` module,
proven by tests that fail on today's code and pass after the fix. The catch-all instance is
deleted, making `Validatable` opt-in: every type used as a program output (or tool input)
must declare an instance, which is one line (`instance Validatable Foo` or
`deriving anyclass (Validatable)`) for types with no rules. This is a deliberate breaking
API change; this plan carries the full in-repo migration.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M1: delete the catch-all instance in `shikumi/src/Shikumi/Schema.hs` and add the `Validatable` constraints to `runPredict`, `streamPredict`, `chainOfThought`, `chainOfThoughtRaw`
- [ ] M1: add the delegating `instance (Validatable o) => Validatable (WithReasoning o)` in `shikumi/src/Shikumi/Module.hs`
- [ ] M1: migrate all in-repo packages (`cabal build all` clean): shikumi-tools builtin request records, jitsurei app types, and any other types the compiler reports
- [ ] M2: add failing-before/passing-after validation tests through `runProgram`, `runProgramConc`, `streamProgram`, and `chainOfThought`
- [ ] M2: full test suite green (`cabal test all`)
- [ ] M3: rewrite the stale doc comment in `shikumi-jitsurei/app/Predict.hs`, update `Validatable` and `chainOfThought` haddocks, note the breaking change in `shikumi/CHANGELOG.md`


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

- Decision: Fix the dispatch bug by deleting the catch-all
  `instance {-# OVERLAPPABLE #-} Validatable a` and making `Validatable` opt-in, rather
  than only adding the missing `Validatable o` constraint to `runPredict`/`streamPredict`
  while keeping the catch-all.
  Rationale: adding the constraint alone does fix dispatch (a GADT-provided given
  dictionary is preferred over instance search), but the catch-all would keep two hazards:
  `-Wredundant-constraints` — enabled in `shikumi/shikumi.cabal` `common-options` — flags
  every explicit `Validatable` constraint as redundant while a universal instance exists,
  which is exactly the pressure that produced this bug; and any future call site that
  forgets the constraint silently regresses to "always valid" again instead of failing to
  compile. Opt-in instances cost one line per type (the class keeps its default
  `validate = Right` method, so `instance Validatable Foo` with no body, or
  `deriving anyclass (Validatable)`, both work) and make the no-rules case explicit.
  Date: 2026-07-01

- Decision: `chainOfThought`'s `withReasoningField` keeps `demos = []` (the source
  signature's typed demos are not carried over), and this behavior is documented loudly in
  the haddocks instead of being changed.
  Rationale: a signature-level demo has type `Demo i o`; the reasoning-augmented node needs
  `Demo i (WithReasoning o)`, and there is no honest reasoning text to synthesize for the
  demo output — an empty or boilerplate reasoning string would teach the model to skip
  reasoning, defeating the module's purpose. Demos supplied through the node's optimizer
  `Params` channel are unaffected (they are stored as JSON and decoded against
  `WithReasoning o`, so they already include a `reasoning` field). If real demand for
  carrying signature demos appears, a follow-up can add an explicit
  `chainOfThoughtWithDemos` that takes reasoning texts.
  Date: 2026-07-01

- Decision: The delegating instance validates the wrapped value only:
  `instance (Validatable o) => Validatable (WithReasoning o)` runs `validate` on the
  `value` field and passes `reasoning` through untouched.
  Rationale: `reasoning` is free-form model prose with no user-declared rules; the user's
  rules live on `o`.
  Date: 2026-07-01

- Decision: The `Verdict` fixture stays package-local in `shikumi/test` rather than
  consuming the shared `Shikumi.Testing.Fixtures` module planned in
  `docs/plans/49-shared-test-harness-and-fixture-diversification.md` (under
  `docs/masterplans/9-ci-and-shared-test-infrastructure.md`).
  Rationale: the planned `shikumi-testing` package depends on the `shikumi` library, so
  the core package's own test suite consuming it would invert the repository's dependency
  layering and tie core tests to an unpublished internal package. That module's `Answer`
  fixture (an output type with a failing-able `validate`) is intentionally the same shape
  as `Verdict`; the plans reference each other so whichever lands second checks for drift.
  Date: 2026-07-01


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This repository is a cabal multi-package Haskell project. The core package lives in
`shikumi/`; sibling packages (`shikumi-tools/`, `shikumi-trace/`, `shikumi-compile/`,
`shikumi-eval/`, `shikumi-optimize/`, `shikumi-okf/`, `shikumi-jitsurei/`, and others) build
on it. Everything builds with GHC 9.12.4 inside the Nix dev shell: run
`nix develop .#ghc9124` from the repository root before any `cabal` command (the system
compiler will not work). Tests are hermetic (no network).

The pieces involved:

A `Signature i o` (`shikumi/src/Shikumi/Signature.hs`) describes one LM call: input record
type `i`, output record type `o`, an instruction, and optional demos. A `Program i o`
(`shikumi/src/Shikumi/Program.hs`) is a tree of nodes; the leaf node `Predict` carries a
signature and is executed by `runPredict`, which renders a prompt, issues the call through
the `LLM` effect, and decodes the reply into `o`.

`Validatable` (`shikumi/src/Shikumi/Schema.hs`, lines 310-317 today) is the post-decode
validation hook:

```haskell
class Validatable a where
  validate :: a -> Either Text a
  validate = Right

-- | Default "always valid" for any type without an explicit rule.
instance {-# OVERLAPPABLE #-} Validatable a
```

Decoding runs validation through `fromModelChecked` (Schema.hs, lines 175-178) and
`parseOutput` (lines 182-185); both carry a `Validatable a` constraint. The adapters
(`shikumi/src/Shikumi/Adapter.hs`) call `fromModelChecked` in their `parse` functions, and
`adapterFor`, `nativeAdapter`, `fallbackAdapter`, `xmlAdapter` all carry `Validatable o`.

The bug. The `Predict` constructor captures the dictionary (Program.hs line 184):

```haskell
Predict ::
  (FromModel i, FromModel o, ToSchema o, Validatable o, ToPrompt i, ToPrompt o) =>
  Signature i o -> Params -> Program i o
```

so pattern-matching `Predict sig ps` inside `runProgram` brings the user's `Validatable o`
dictionary into scope. But `runPredict` (Program.hs lines 304-311) omits the constraint:

```haskell
runPredict ::
  forall i o es.
  (FromModel i, FromModel o, ToSchema o, ToPrompt i, ToPrompt o) =>
  (LLM :> es, Error ShikumiError :> es) =>
  Signature i o -> Params -> i -> Eff es o
```

so the captured dictionary is discarded at the `runProgram (Predict sig ps) i = runPredict
sig ps i` call. Inside `runPredict`, the calls to `adapterFor` (line 314) and
`parseResponse` (line 321) still need `Validatable o` — and GHC solves it from the only
in-scope candidate that matches a bare type variable: the catch-all instance. The
`OVERLAPPABLE` pragma is what makes this legal; GHC commits to the catch-all at this
polymorphic definition site, and the user's more specific instance is never consulted. Note
the contrast with monomorphic call sites: `parseOutput @Summary` in a test picks the user's
`Validatable Summary` instance because at a concrete type the specific instance beats the
overlappable one. That is why the existing test
"validation rule violation -> ValidationFailure" in `shikumi/test/SchemaSpec.hs` (lines
83-85) passes today while the same rule is skipped through `runProgram`.

The same omission exists in `streamPredict` (`shikumi/src/Shikumi/Stream.hs`, lines
238-246: the constraint row is `(FromModel i, FromModel o, ToSchema o, ToPrompt i,
ToPrompt o)`), so `streamProgram` has the identical bug. `runProgramConc` shares
`runPredict`, and `shikumi-trace`'s `runProgramTraced`
(`shikumi-trace/src/Shikumi/Trace/Program.hs`) delegates each `Predict` leaf to
`runProgram`, so both are fixed for free once `runPredict` is fixed.

`chainOfThought` (`shikumi/src/Shikumi/Module.hs`, lines 115-144) has two related issues.
First, its constraint row `(FromModel i, FromModel o, ToSchema o, ToPrompt i, ToPrompt o)`
lacks `Validatable o`, and the `Predict` node it builds has output type `WithReasoning o` —
whose `Validatable (WithReasoning o)` is today solved by the catch-all, so even a correct
`Validatable o` never runs. It needs a delegating instance plus the constraint. Second,
`withReasoningField` (lines 132-144) constructs the augmented signature with a hardcoded
`demos = []`, silently dropping any demos set on the source signature; per the Decision Log
this stays but must be documented.

Why the constraint was omitted in the first place: `shikumi/shikumi.cabal` `common-options`
(lines 17-23) enables `-Wredundant-constraints`. While the catch-all instance exists, an
explicit `Validatable o` constraint on `runPredict` is provably redundant and warns. The
old design resolved the warning by dropping the constraint — the wrong side. Deleting the
catch-all makes the constraints non-redundant, so both edits must land together (warnings
are not errors in this repo, but the build must stay warning-clean).

Breaking-change blast radius. With the catch-all gone, every type that reaches a
`Validatable` constraint needs an explicit instance. Most in-repo types already declare one
(grep for `instance Validatable`); the known gaps found by survey are listed in Plan of
Work M1. The complete, authoritative enumeration is compile-driven: `cabal build all` after
the deletion reports every missing instance as a type error.


## Plan of Work

Milestone 1 — delete the catch-all, thread the constraints, migrate the repo. At the end of
this milestone `cabal build all` succeeds with no new warnings, and validation dispatch is
structurally fixed (proven in M2). All edits in this milestone must land in one commit,
because the constraint additions warn under `-Wredundant-constraints` while the catch-all
still exists.

In `shikumi/src/Shikumi/Schema.hs`: delete the two lines (currently 316-317)

```haskell
-- | Default "always valid" for any type without an explicit rule.
instance {-# OVERLAPPABLE #-} Validatable a
```

and extend the haddock on the `Validatable` class to say: instances are opt-in; a type with
no rules declares `instance Validatable Foo` (no body — the default `validate = Right`
applies) or adds `Validatable` to a `deriving anyclass` list (the `DeriveAnyClass`
extension is already a default extension in every package's cabal `common-options`); the
runners require it for every `Predict` output type.

In `shikumi/src/Shikumi/Program.hs`: add `Validatable o` to `runPredict`'s constraint row
(line 306), making it
`(FromModel i, FromModel o, ToSchema o, Validatable o, ToPrompt i, ToPrompt o)`.
`parseResponse` (line 332) already has it. Nothing else in this module changes; the import
of `Validatable` on line 107 already exists.

In `shikumi/src/Shikumi/Stream.hs`: add `Validatable o` to `streamPredict`'s constraint row
(line 240), and add `Validatable` to the `Shikumi.Schema` import list (line 76). Do not
otherwise restructure this function — EP-34
(`docs/plans/34-route-and-unify-program-streaming.md`) owns its body; this plan owns only
the constraint (master plan integration point 2).

In `shikumi/src/Shikumi/Module.hs`: add the delegating instance next to `WithReasoning`'s
other instances (after line 105):

```haskell
-- | Validation delegates to the wrapped value; the free-form @reasoning@ text
-- carries no user rules.
instance (Validatable o) => Validatable (WithReasoning o) where
  validate wr = (\v -> wr {value = v}) <$> validate (value wr)
```

Add `Validatable o` to the constraint rows of `chainOfThought` (line 116) and
`chainOfThoughtRaw` (line 123). Extend `withReasoningField`'s and `chainOfThought`'s
haddocks to state explicitly: signature-level demos are not carried onto the
reasoning-augmented node (`demos = []`), because a `Demo i o` cannot be turned into a
`Demo i (WithReasoning o)` without inventing reasoning text; demos supplied through the
node's `Params` are unaffected. `predict` (line 63) and `twoStep` (line 174) already carry
`Validatable o` and need no change.

Migration across the repo. Add explicit empty instances (or `deriving anyclass`) for every
type the compiler reports. The survey found these known gaps:

- `shikumi-tools/src/Shikumi/Tool/Builtin/Web.hs`: `FetchReq`, `SearchReq`
- `shikumi-tools/src/Shikumi/Tool/Builtin/Shell.hs`: `BashReq`
- `shikumi-tools/src/Shikumi/Tool/Builtin/Fs.hs`: `ReadReq`, `WriteReq`, `EditReq`,
  `GrepReq`, `GlobReq`
  (these are tool input records; `shikumi-tools/src/Shikumi/Tool.hs` line 116 requires
  `Validatable i` for tool inputs and line 146 calls `fromModelChecked`)
- `shikumi-jitsurei/app/*.hs`: the example apps declare many small record types with
  `ToSchema`/`FromModel`/`ToPrompt` instances but no `Validatable` (e.g. `Summary` in
  `app/Predict.hs`); add instances wherever the compiler demands
- any internal decode types in `shikumi-tools/src/Shikumi/Agent/ReAct.hs`,
  `shikumi-tools/src/Shikumi/CodeExec/ProgramOfThought.hs`, and
  `shikumi-tools/src/Shikumi/CodeExec/CodeAct.hs` that flow through their `parseOutput`
  calls (lines 366/405, 104, 124 respectively) without an instance

Types that only appear as inputs to `Predict` (like `Fixtures.Article`) do not need
instances — the runners require `Validatable` on outputs only; tool inputs are the
exception because `Tool.hs` validates them. Do not add instances speculatively: let
`cabal build all` be the oracle, then record the final list in this plan's Surprises &
Discoveries section.

Milestone 2 — prove the fix with failing-before/passing-after tests. Before writing any
implementation code you can write these tests first and watch them fail against today's
code (they assert `Left (ValidationFailure …)` where today's code returns `Right …`).

Add a rule-carrying fixture to `shikumi/test/ProgramFixtures.hs` (this module is shared by
several specs and already exports records, signatures, canned responses, and the scripted
stub interpreter `runScriptedLLM`):

```haskell
-- | A record with a real validation rule, for the EP-32 dispatch tests.
newtype Verdict = Verdict {score :: Int}
  deriving stock (Generic, Show, Eq)

instance ToSchema Verdict

instance FromModel Verdict

instance ToPrompt Verdict

-- | Domain rule: a score is at most 10.
instance Validatable Verdict where
  validate v
    | score v > 10 = Left "score: must be at most 10"
    | otherwise = Right v

topicToVerdict :: Signature Topic Verdict
topicToVerdict = mkSignature "Score the topic"

-- | A reply whose score violates the rule.
badVerdictResponse :: Response
badVerdictResponse = mkResponse (markerBody [("score", "99")])
```

Export `Verdict (..)`, `topicToVerdict`, and `badVerdictResponse` from the module header.

In `shikumi/test/ProgramSpec.hs` add two cases (imports: `runProgramConc` from
`Shikumi.Program`, `runConcurrent` from `Effectful.Concurrent`, `ShikumiError (..)` — the
constructors — from `Shikumi.Error`, and the new fixtures):

- "a failing Validatable rule surfaces as ValidationFailure through runProgram": script
  `[badVerdictResponse]`, run
  `runProgram (Predict topicToVerdict emptyParams) (Topic "haskell")` under
  `runEff . runErrorNoCallStack @ShikumiError . runScriptedLLM ref`, assert the result is
  `Left (ValidationFailure "score: must be at most 10")`.
- the same through `runProgramConc`, adding `runConcurrent` to the interpreter stack (see
  `shikumi/test/RoutingSpec.hs` `captureRoutedConc` for the stack shape).

In `shikumi/test/StreamSpec.hs` add "a failing Validatable rule surfaces through
streamProgram": that spec's `runStreamingLLM` interpreter takes scripted event lists; use
its `streamEventsFor` helper with terminal text `markerBody [("score", "99")]` over a
`predict topicToVerdict` program (`ProgramFixtures` is already imported there) and assert
`Left (ValidationFailure "score: must be at most 10")`.

In `shikumi/test/ModuleSpec.hs` add "a failing Validatable rule surfaces through
chainOfThought": script one response whose body is

```haskell
markerBody [("reasoning", "thinking"), ("value", "{\"score\": 99}")]
```

The shape matters: the reasoning-augmented signature's output fields are `reasoning` and
`value`, and the inner record's JSON is nested under the `value` section — the existing
"chainOfThoughtRaw yields a WithReasoning value through the stub" case in that spec (lines
32-47) shows the same working fixture shape; copy it. Run
`runProgram (chainOfThought topicToVerdict) (Topic "haskell")` and assert
`Left (ValidationFailure "score: must be at most 10")` — this exercises the delegating
`Validatable (WithReasoning Verdict)` instance end to end.

Milestone 3 — documentation. Rewrite the doc comment in
`shikumi-jitsurei/app/Predict.hs` (lines 13-16) which currently claims "the runtime decode
path does not apply a type's `Validatable` instance — that instance documents the rule; the
combinator is what enforces it in a `Program`": after this plan that statement is false.
Rewrite it to present both mechanisms honestly: a type's `Validatable` instance is enforced
by the decode path in every runner, and the `validate` combinator remains available for
program-level rules that do not belong on the type. Optionally extend that example to show
the instance firing. Update `shikumi/CHANGELOG.md` with the breaking change and the
one-line migration recipe.


## Concrete Steps

All commands run from the repository root
(`/Users/shinzui/Keikaku/bokuno/shikumi`). Enter the dev shell first — the project requires
GHC 9.12.4, which only the shell provides:

```bash
nix develop .#ghc9124
```

Write the M2 tests first and confirm they fail against the unfixed code:

```bash
cabal test shikumi
```

Expected before the fix: the four new cases fail with output like

```text
  a failing Validatable rule surfaces as ValidationFailure through runProgram: FAIL
    expected: Left (ValidationFailure "score: must be at most 10")
     but got: Right (Verdict {score = 99})
```

Apply the M1 edits, then rebuild everything (the migration oracle):

```bash
cabal build all
```

Fix every "No instance for `Validatable …`" error by adding an empty instance next to the
type's other instances. Re-run until clean. Then:

```bash
cabal test shikumi        # or: just test-one shikumi
cabal test all
```

Expected after the fix: all suites pass, including the four new cases. Also confirm the
examples still run (they are stub-driven and hermetic):

```bash
cabal run jitsurei-predict
```

Commit message format: conventional-commit subject, and every commit in this plan MUST
carry these trailers:

```text
fix(schema)!: make Validatable opt-in and thread it through the runners

BREAKING CHANGE: the catch-all `instance {-# OVERLAPPABLE #-} Validatable a`
is deleted; declare `instance Validatable T` (or derive anyclass) for every
Predict output and tool input type.

MasterPlan: docs/masterplans/5-core-runtime-correctness-and-wire-fidelity.md
ExecPlan: docs/plans/32-fix-validatable-dispatch-in-program-runners.md
Intention: intention_01kwgdyxm7ehh8yys1pp4wf1zr
```


## Validation and Acceptance

Acceptance is behavioral. After implementation, all of the following hold:

1. Given a type with a failing rule (fixture `Verdict`, rule "score at most 10") and a
   scripted model reply carrying `score = 99`, running the one-node program through
   `runProgram` returns `Left (ValidationFailure "score: must be at most 10")`; the same
   holds through `runProgramConc`, through `streamProgram` (with the reply delivered as a
   scripted event stream), and through `runProgram (chainOfThought topicToVerdict)` (reply
   carrying a `reasoning` section plus the bad value). These are the four new test cases;
   each fails before the fix (returning `Right (Verdict 99)` / `Right …`) and passes after.
2. A conforming reply (`score = 7`) still decodes to `Right (Verdict 7)` through every
   runner — validation must not reject valid output (cover with at least one positive case
   or rely on the existing suites, which run many rule-free decodes).
3. `cabal build all` inside `nix develop .#ghc9124` succeeds with no new warnings (watch
   for `-Wredundant-constraints` regressions).
4. `cabal test all` passes: no existing behavior regressed. In particular
   `shikumi/test/SchemaSpec.hs`'s existing validation case and every spec using the
   trivial-instance fixtures still pass.
5. `grep -rn "OVERLAPPABLE" shikumi/src/Shikumi/Schema.hs` finds no `Validatable`
   catch-all (the other overlappable instances in that file — `FieldSchema`, `FromField`,
   `FieldDoc` — are unrelated and must remain).


## Idempotence and Recovery

Every step is an ordinary source edit plus a rebuild; re-running builds and tests is
harmless. The risky step is the catch-all deletion, which breaks compilation repo-wide
until the migration completes — do the deletion, constraint additions, and instance
additions in one working session and one commit so `master` never holds a broken tree. If
the migration stalls, `git checkout -- .` restores the pre-plan state. The new tests are
additive and safe to keep even if M1 is rolled back (they will simply fail, correctly
signalling the bug still exists).


## Interfaces and Dependencies

No new libraries. The plan touches only existing modules:

- `shikumi/src/Shikumi/Schema.hs` — `class Validatable a` keeps its shape
  (`validate :: a -> Either Text a`, default `validate = Right`); the catch-all instance is
  removed. Exported name set unchanged.
- `shikumi/src/Shikumi/Program.hs` — `runPredict` gains `Validatable o`; its exported name
  and argument order are unchanged. End-of-milestone signature:

```haskell
runPredict ::
  forall i o es.
  (FromModel i, FromModel o, ToSchema o, Validatable o, ToPrompt i, ToPrompt o) =>
  (LLM :> es, Error ShikumiError :> es) =>
  Signature i o -> Params -> i -> Eff es o
```

- `shikumi/src/Shikumi/Stream.hs` — `streamPredict` gains `Validatable o` in its constraint
  row; body untouched (owned by EP-34, see the master plan's integration point 2).
- `shikumi/src/Shikumi/Module.hs` — new instance
  `instance (Validatable o) => Validatable (WithReasoning o)`; `chainOfThought` and
  `chainOfThoughtRaw` gain `Validatable o`.
- Downstream packages gain one-line `Validatable` instances only; no signatures change
  there (their public functions such as ReAct/CodeAct constructors already carry
  `Validatable o` / `Validatable i`).

Coordination: EP-33 (`docs/plans/33-native-adapter-path-and-strict-mode-schemas.md`) edits
`parseResponse`/`runPredict` bodies and EP-34 edits `streamPredict`'s body; this plan must
not change those bodies beyond the constraint rows. If those plans land first, rebase the
constraint edits onto their versions — the constraint addition is valid against any body.

Shared fixtures (cross-initiative): `docs/plans/49-shared-test-harness-and-fixture-diversification.md`
(under `docs/masterplans/9-ci-and-shared-test-infrastructure.md`) introduces an internal
`shikumi-testing` package whose `Shikumi.Testing.Fixtures` module exports `Answer`, a
rule-carrying output type with a failing-able `validate` — the same blind spot this plan's
`Verdict` fixture closes. `Verdict` deliberately stays local to `shikumi/test` (see the
Decision Log); if `shikumi-testing` already exists when you implement this plan, still add
`Verdict` here, but compare the two fixtures' validation shapes and record any divergence
in the master plan's Surprises & Discoveries section.


## Revision Notes

- 2026-07-01: Added the cross-initiative note on shared test fixtures (EP-49's
  `Shikumi.Testing.Fixtures` vs. this plan's package-local `Verdict`) and the matching
  Decision Log entry. Reason: master plan 9 and its children were authored in parallel
  with this plan, so the fixture seam was documented on only one side.
