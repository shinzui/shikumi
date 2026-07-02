---
id: 38
slug: compiled-program-serialization-fidelity
title: "Compiled Program Serialization Fidelity"
kind: exec-plan
created_at: 2026-07-02T03:30:16Z
intention: "intention_01kwgdyxm7ehh8yys1pp4wf1zr"
master_plan: "docs/masterplans/6-optimizer-and-evaluation-correctness.md"
---

# Compiled Program Serialization Fidelity

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

shikumi programs are trees of LM-calling `Predict` nodes. The `shikumi-compile` package
"compiles" a program by baking a prompting strategy into it — setting per-node
parameters (`zeroShot`, `fewShot`) or rewriting structure (`chainOfThoughtCompiler`,
`rag`) — and can persist the result: `encodeCompiled` writes JSON,
`decodeCompiledOnto template bytes` loads it back onto a program you still hold as code
(mirroring DSPy's `dump_state`/`load_state`).

Today the persisted form is only the ordered list of per-node `Params`
(`shikumi-compile/src/Shikumi/Compile/Serialize.hs:35-36`), and that loses information
silently in two shipped cases. The RAG compiler injects retrieved context by rewriting
each node's *signature* instruction (`shikumi-compile/src/Shikumi/Compile/RAG.hs:80`,
via `setInstruction`), not its `Params` — so a saved RAG-compiled program decodes back
*without* its retrieved context and no error tells you. The chain-of-thought compiler
rewrites structure (`shikumi-compile/src/Shikumi/Compile/ChainOfThought.hs:68`:
`Predict` becomes `FMap value (… chainOfThoughtRaw …)`), which keeps the node count
identical — so a chain-of-thought state decodes cleanly onto the plain base template,
silently yielding a program that no longer reasons step-by-step. The core already
sketches the fix (`shikumi/src/Shikumi/Program.hs:623-626`: save
`(programShape p, programParams p)`), and `ProgramShape` already has JSON instances;
`Serialize.hs` just never adopted the shape half.

After this change: the persisted envelope carries a structural fingerprint;
`decodeCompiledOnto` fails loudly with a shape-mismatch message when the template is
not the program the state was saved from (catching the chain-of-thought case); the RAG
compiler stores its context in serializable `Params` so a RAG round-trip is faithful;
and the "an optimizer never changes a program's structure" contract text
(`shikumi-optimize/src/Shikumi/Optimize/Types.hs:10-11`) is reconciled with the two
optimizers that genuinely do (`knnFewShot`, `ensembleSearch`), with their
(non-)persistence story documented instead of implied.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M1: `CompiledState` envelope (shape + params) in Serialize.hs; loud shape and
      count mismatch errors; existing round-trip tests updated
- [ ] M2: RAG writes `instructionOverride` instead of `setInstruction`; prompt-equality
      test updated; RAG round-trip test added
- [ ] M3: chain-of-thought round-trip onto the correct template; wrong-template decode
      returns Left (failing-before test)
- [ ] M4: contract reconciliation docs in Optimize/Types.hs, KNN.hs, Ensemble.hs; knn
      wrong-template decode test in shikumi-optimize
- [ ] `cabal test all` green


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

- Decision: The new envelope is a clean break — `decodeCompiledOnto` rejects the old
  bare-`[Params]` JSON with a descriptive error instead of accepting it as a legacy
  format.
  Rationale: The project is pre-production (this initiative exists to reach production
  readiness); no persisted artifacts carry compatibility guarantees, and a silent
  legacy path would preserve exactly the silent-loss hole this plan closes. The error
  message names the expected envelope so a user with an old file knows to re-save.
  Date: 2026-07-01 (source: production-readiness code review)

- Decision: Fix RAG by migrating its injection to `instructionOverride` (per-node
  `Params`), not by serializing signature-level rewrites.
  Rationale: Signatures are typed, closure-bearing values that the serialization layer
  deliberately excludes (`Serialize.hs` module header); `Params` is the designed
  persistence channel and the runtime already gives overrides precedence
  (`shikumi/src/Shikumi/Program.hs:422`). The migration also *improves* compiler
  composition: applying `rag` after `zeroShot` now appends context to the zero-shot
  instruction instead of being masked by it.
  Date: 2026-07-01

- Decision: Reconcile the structure contract by amending documentation (M4), not by
  redesigning `knnFewShot`/`ensembleSearch`.
  Rationale: Master-plan decision (see
  `docs/masterplans/6-optimizer-and-evaluation-correctness.md` Decision Log): both
  optimizers are useful because they change structure; the user hazard is the
  undocumented persistence gap, which the M1 envelope turns into a loud failure.
  Date: 2026-07-01

- Decision: Keep `decodeCompiledOnto`'s error type as `Either String` rather than
  introducing a structured error sum.
  Rationale: The only current consumers are tests and the CLI's load path, which
  render the string; a structured error is easy to add later and would widen this
  plan's blast radius now.
  Date: 2026-07-01


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This section assumes no prior repository knowledge.

Packages involved: `shikumi` (core), `shikumi-compile` (compilers + serialization),
`shikumi-optimize` (only for M4 docs/tests). Key artifacts, by full path:

- `shikumi/src/Shikumi/Program.hs` — the `Program i o` GADT. Per-node tunable state is
  `Params { instructionOverride :: Maybe Text, demos :: [Demo] }` (line 123); at run
  time the override, when present, replaces the signature's base instruction entirely
  (line 422). `programShape :: Program i o -> ProgramShape` (lines 602–615) extracts a
  closure-free constructor tree — each `Predict` is labeled by its joined output-field
  names (`sigLabel`, lines 620–621), and `ProgramShape` derives `Eq`, `ToJSON`,
  `FromJSON` (lines 567–590). Note what the shape does and does not see: it changes
  when chain-of-thought rewrites `Predict` into `FMap` around an augmented signature
  (both the constructor tree and the label change, since the augmented output gains a
  `reasoning` field), but it does *not* change when RAG edits a signature's
  instruction (instructions are not part of the shape) — which is exactly why RAG must
  move its edit into `Params` (M2) rather than rely on the fingerprint (M1).
  `programParams` (= `foldParams`, one `Params` per `Predict` node in deterministic
  order) and `setProgramParams` (length-checked re-application, lines 633–636) already
  exist and are what `Serialize.hs` wraps.
- `shikumi-compile/src/Shikumi/Compile/Types.hs` — `Compiler` (a pure
  `forall i o. Program i o -> Program i o` rewrite) and
  `CompiledProgram i o = CompiledProgram { compiledProgram :: Program i o }`.
- `shikumi-compile/src/Shikumi/Compile/Serialize.hs` — `encodeCompiled` (line 35–36:
  `encode (programParams p)` — params only) and `decodeCompiledOnto` (lines 43–57:
  decode `[Params]`, apply via `setProgramParams`, report only a count mismatch).
- `shikumi-compile/src/Shikumi/Compile/RAG.hs` — `rag retriever query`: retrieves once
  at compile time, then `install` (lines 74–91) rewrites every `Predict sig ps` to
  `Predict (setInstruction (getInstruction sig <> "\n\n" <> ctx) sig) ps` (line 80).
- `shikumi-compile/src/Shikumi/Compile/ChainOfThought.hs` — `cot` (line 68) rewrites
  every `Predict sig ps` to `FMap value (mapParams (const ps) (chainOfThoughtRaw sig))`.
- `shikumi-compile/test/Main.hs` — the test suite. `runWithCapture` runs a compiled
  program under a scripted mock LM and returns the rendered prompts; the current
  serialization tests (lines 191–219) round-trip only `zeroShot` and `fewShot` and
  check the count-mismatch Left.
- `shikumi-optimize/src/Shikumi/Optimize/Types.hs` lines 10–11 — "An optimizer never
  changes a program's structure or types"; contradicted by
  `shikumi-optimize/src/Shikumi/Optimize/KNN.hs` (`knnDemos`/`knnFewShot`, lines
  91–110: wraps the student in an `Embed` node whose body is an unrecoverable closure;
  `Embed` carries no `Params`, so it serializes as an *empty* parameter vector) and
  `shikumi-optimize/src/Shikumi/Optimize/Ensemble.hs` (`ensembleSearch`, lines 27–34:
  returns an `Ensemble` combinator node).

Build/test: repository root, `nix develop .#ghc9124`, then
`cabal test shikumi-compile` (or `just test-one shikumi-compile`); M4's test runs under
`cabal test shikumi-optimize`.


## Plan of Work

### Milestone 1 — the shape-fingerprint envelope

Scope: the persisted JSON gains a structural fingerprint and `decodeCompiledOnto`
verifies it. At the end, saving and loading works exactly as before for matching
templates, and any structural mismatch is a descriptive `Left`.

Edit `shikumi-compile/src/Shikumi/Compile/Serialize.hs`. Add an envelope type
(deriving `Generic`, with `ToJSON`/`FromJSON` instances):

```haskell
-- | The persisted form of a compiled program: the structural fingerprint of the
-- program it was saved from, plus its ordered parameter vector. The shape lets
-- 'decodeCompiledOnto' refuse a template that is not the saved program's
-- structure (e.g. loading chain-of-thought state onto the plain base program).
data CompiledState = CompiledState
  { shape :: !ProgramShape,
    params :: ![Params]
  }
  deriving stock (Generic)
```

`encodeCompiled (CompiledProgram p)` becomes
`encode (CompiledState (programShape p) (programParams p))`. `decodeCompiledOnto`
decodes the envelope, then checks `shape st == programShape template` *before*
`setProgramParams`; on mismatch return a `Left` whose message says the saved state was
produced by a structurally different program and names both shapes' `show` renderings
(they are small); on a JSON parse failure, prepend a hint that pre-envelope saves
(a bare JSON array) are not supported and must be re-encoded. Keep the existing
count-mismatch branch as a defensive second check (it should be unreachable when
shapes match, since the shape determines the `Predict` count). Import `ProgramShape`
and `programShape` from `Shikumi.Program`.

Update the existing tests in `shikumi-compile/test/Main.hs` (`m6_serialize`,
lines 191–219): the two happy-path round-trips need no change (they decode onto the
same-shaped template); the "wrong-shaped template" case (2-node payload onto a 1-node
template, lines 213–218) still returns `Left` — additionally assert the message
mentions the shape (not just a count). Add a case: a bare `[Params]` JSON literal
(write it inline with `Data.Aeson.encode` of a `[Params]` value) is rejected with the
re-encode hint.

Acceptance: `cabal test shikumi-compile` green; the new bare-array case fails before
the envelope lands (it decodes successfully today) — write it first.

### Milestone 2 — RAG context survives the round-trip

Scope: RAG's injected context moves from the signature to the serializable override. At
the end, encode→decode of a RAG-compiled program preserves the retrieved context in the
rendered prompt.

Edit `shikumi-compile/src/Shikumi/Compile/RAG.hs`. In `install` (lines 74–91), replace
the `Predict` case:

```haskell
go (Predict sig ps) =
  let base = fromMaybe (getInstruction sig) (instructionOverride ps)
   in Predict sig ps {instructionOverride = Just (base <> "\n\n" <> ctx)}
```

with imports adjusted (`Data.Maybe (fromMaybe)`, `Shikumi.Program (Params (..))`;
`setInstruction` is no longer needed — drop it from the `Shikumi.Signature` import,
keeping `getInstruction`). Semantics: the effective instruction (existing override if
any, else the signature base) gains the context block, and the result lives in
`Params`, so `programParams` carries it. Rewrite the module-header caveat paragraph
(lines 19–26): the old text warned that an override set later replaces the whole
instruction *including context* (still true — `zeroShot` after `rag` wipes context, as
before, since `zeroShot` overwrites overrides) but the converse improves: `rag` after
`zeroShot` now appends to the zero-shot instruction instead of being masked. State
both orderings explicitly.

Tests in `shikumi-compile/test/Main.hs`: the existing M5 prompt test (retrieved passage
appears in the prompt, lines 177–184) must stay green unchanged — the rendered prompt
is identical because overrides take precedence at run time. Add to `m6_serialize`: "RAG
context survives encode/decode" — compile `rag (inMemoryRetriever 1 corpus) "shikumi
mechanism"` over `qaBase`, `encodeCompiled`, `decodeCompiledOnto qaBase`, run both via
`runWithCapture`, and assert the round-tripped prompt still contains the passage text
(`"mechanism behind how a system works"`) and equals the original prompt. This test
fails before this milestone (the decoded program loses the context and the prompts
differ) — write it first and record the failure.

### Milestone 3 — chain-of-thought fidelity

Scope: prove the envelope catches the CoT silent-downgrade and that the supported
round-trip works. No source changes expected beyond M1; this milestone is tests plus a
haddock note.

Add to `m6_serialize` in `shikumi-compile/test/Main.hs`:

- "CoT state does not decode onto the base template": encode
  `compile chainOfThoughtCompiler qaBase`, then `decodeCompiledOnto qaBase` must be
  `Left` with the shape-mismatch message. Before M1 this decoded `Right` (same node
  count) and silently produced a non-reasoning program — this is the plan's
  headline failing-before test; run it against the pre-M1 tree once and record the
  wrongly-successful decode in Surprises & Discoveries.
- "CoT round-trips onto the CoT template": the correct template for a
  chain-of-thought save is the same structural rewrite applied to the base program —
  decode onto `compiledProgram (compile chainOfThoughtCompiler qaBase)` and assert
  prompt equality via `runWithCapture` with the existing `cotAnswerResponse` fixtures
  (see the M4 group at lines 140–157 for the response fixtures to reuse).

Add a sentence to the `chainOfThoughtCompiler` haddock (`ChainOfThought.hs`) and to
`decodeCompiledOnto`'s haddock naming this rule: the decode template must be the
compiled shape, i.e. re-apply the same structural compilers to the base program before
loading state onto it.

### Milestone 4 — reconcile the structure contract

Scope: documentation and one loud-failure test; no behavior redesign. Edit
`shikumi-optimize/src/Shikumi/Optimize/Types.hs` module header: after the "never
changes a program's structure or types" sentence (lines 10–11), add a paragraph naming
the two exceptions and their persistence story — `knnFewShot` wraps the student in a
run-time `Embed` selector node (an opaque effectful closure: it serializes as an empty
parameter vector with shape `ShapeEmbed`, so its state cannot be persisted and
reloaded; persist the underlying student instead, or use `knnFewShotCentroid`, which is
a plain `Params` artifact), and `ensembleSearch` returns an `Ensemble` combinator over
its members (same caveat; the members' parameters are traversed by `foldParams`, but
the reducer closure and member structure require the matching ensemble template at
decode time). Add matching paragraphs to the haddocks of `knnFewShot`
(`shikumi-optimize/src/Shikumi/Optimize/KNN.hs`) and `ensembleSearch`
(`shikumi-optimize/src/Shikumi/Optimize/Ensemble.hs`).

Test (in `shikumi-optimize/test/KNNSpec.hs`, which already exists): encode the result
of `knnFewShot` (via `encodeCompiled`) and assert `decodeCompiledOnto` onto the plain
student returns `Left` mentioning the shape — the envelope from M1 makes this loud
(`ShapeEmbed` versus `ShapePredict …`); before M1 it was already `Left` but only via
the incidental count mismatch, so assert on the shape wording to pin the improved
diagnostic. (`shikumi-optimize` already depends on `shikumi-compile`.)


## Concrete Steps

All commands from the repository root, inside the dev shell:

```bash
cd /path/to/shikumi
nix develop .#ghc9124
cabal build shikumi-compile
cabal test shikumi-compile           # or: just test-one shikumi-compile
cabal test shikumi-optimize          # M4 only
cabal test all                       # before finishing
```

For each milestone, write its failing-before test first and run it. Expected transcript
for the M3 headline test against the unfixed tree:

```text
    M6 serialize
      CoT state does not decode onto the base template: FAIL
        expected a shape-mismatch Left, got Right
```

and after M1:

```text
All N tests passed (…s)
```

Commit at green milestone boundaries with Conventional Commits subjects and these exact
trailers on every commit:

```text
fix(compile): persist a shape fingerprint with compiled params

MasterPlan: docs/masterplans/6-optimizer-and-evaluation-correctness.md
ExecPlan: docs/plans/38-compiled-program-serialization-fidelity.md
Intention: intention_01kwgdyxm7ehh8yys1pp4wf1zr
```

(Per-commit subjects: `fix(compile): store RAG context in instruction overrides`,
`test(compile): …`, `docs(optimize): document structure-changing optimizers`, etc.)

Check for other `encodeCompiled`/`decodeCompiledOnto` callers before starting
(`grep -rn "decodeCompiledOnto\|encodeCompiled" --include='*.hs' .` excluding
`dist-newstyle`) — the CLI (`shikumi-cli`) load/save path, if it round-trips fixtures,
may need its stored fixture regenerated; record whatever you find in Surprises &
Discoveries.


## Validation and Acceptance

Accepted when:

1. Saving then loading a RAG-compiled program onto its base template renders a prompt
   identical to the pre-save program, retrieved context included (M2 test) — this
   fails on the unfixed tree.
2. Loading a chain-of-thought save onto the plain base template returns `Left` with a
   shape-mismatch message (M3 test) — this decodes `Right` (silently wrong) on the
   unfixed tree; loading onto the correctly re-compiled template round-trips with
   identical prompts.
3. Legacy bare-`[Params]` JSON is rejected with a message telling the user to
   re-encode (M1 test).
4. The structure-contract text in `Shikumi.Optimize.Types`, `KNN.hs`, and `Ensemble.hs`
   names the exceptions and the persistence story, and the knn wrong-template decode
   asserts a shape-worded `Left` (M4).
5. `cabal test shikumi-compile`, `cabal test shikumi-optimize`, and finally
   `cabal test all` pass inside `nix develop .#ghc9124`.


## Idempotence and Recovery

All steps are source edits and deterministic offline tests; re-running is safe. The
envelope change (M1) is the only step with any migration surface: it invalidates
previously saved JSON by design (clean break, see Decision Log). If a stakeholder
surfaces a real persisted artifact that must keep working, add a legacy decode branch
behind an explicit function (e.g. `decodeLegacyParamsOnto`) rather than silently
widening `decodeCompiledOnto` — record such a change in the Decision Log. Milestones
M2–M4 are independent of each other and individually revertible per file.


## Interfaces and Dependencies

No new external dependencies (`aeson` and `Generic` derivation are already used in both
packages). End-state surface:

- `Shikumi.Compile.Serialize` (`shikumi-compile/src/Shikumi/Compile/Serialize.hs`):
  `encodeCompiled :: CompiledProgram i o -> ByteString` (unchanged type, new JSON
  layout `{"shape": …, "params": […]}`); `decodeCompiledOnto :: Program i o ->
  ByteString -> Either String (CompiledProgram i o)` (unchanged type, new shape
  check); new internal (or exported, implementer's choice — note it in the Decision
  Log) `CompiledState { shape :: ProgramShape, params :: [Params] }`.
- `Shikumi.Compile.RAG`: `rag :: Retriever -> Text -> Compiler` (unchanged type; the
  rewrite now targets `Params.instructionOverride`).
- `Shikumi.Compile.ChainOfThought`, `Shikumi.Optimize.Types`, `Shikumi.Optimize.KNN`,
  `Shikumi.Optimize.Ensemble`: docs only.
- Consumed from core, all already exported: `programShape`, `ProgramShape (..)`,
  `programParams`, `setProgramParams`, `Params (..)`, `getInstruction`.

This plan is independent of plans 36/37 (optimizer internals) and 39 (shikumi-eval);
it can be implemented in any order relative to them. Coordination note from the master
plan: plan 37 also edits the `Shikumi.Optimize.Types` module header (the `Budget`
haddock, a different paragraph) — whichever lands second rebases a trivial doc hunk.
