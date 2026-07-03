---
id: 6
slug: optimizer-and-evaluation-correctness
title: "Optimizer and Evaluation Correctness"
kind: master-plan
created_at: 2026-07-02T03:29:36Z
intention: "intention_01kwjfeaf8e86bvx2arbh7nk2c"
---

# Optimizer and Evaluation Correctness

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

A production-readiness code review of the optimizer, compiler, and evaluation layers
(`shikumi-optimize`, `shikumi-compile`, `shikumi-eval`) found a cluster of correctness
defects that are invisible under the current test fixtures but would surface immediately
in real use. The worst of them inverts the framework's central promise: every
instruction optimizer reads a node's "current instruction" from the per-node override
(`instructionOverride` in `Params`) while ignoring the signature's base instruction, so
optimizing any program whose signature carries a real instruction — that is, any
realistic program — silently blanks that instruction before scoring, and MIPROv2 can
return a program strictly worse than its input. The rest of the cluster: the documented
`Budget` contract is enforced by only three of nine optimizers; serialized compiled
programs silently lose RAG context and silently decode chain-of-thought state onto
non-chain-of-thought templates; and the evaluation layer misses streamed-call usage,
ships a dead `TimedOut` variant, renders a misleading latency figure, and exports a raw
`Score` constructor that bypasses its own clamping invariant.

When this initiative is complete, a user can rely on four behaviors. First, running any
shipped optimizer over a program whose signatures carry non-empty instructions returns a
program that scores at least as well as the input (the documented never-worse
guarantee), and the true, unmodified student is always among the scored candidates.
Second, every optimizer respects its `Budget` under a single, precisely documented
accounting model — no optimizer silently spends unbounded LM calls. Third,
`encodeCompiled`/`decodeCompiledOnto` either round-trips a compiled program with full
fidelity (including RAG context) or fails loudly with a shape-mismatch error — never a
silent semantic downgrade. Fourth, evaluation reports account for streamed LM calls,
optionally time out runaway examples, label latency honestly, and cannot be handed an
out-of-range score.

Excluded from scope: new optimizer algorithms or search-quality improvements, the
Stream-op routing work (that belongs to
`docs/masterplans/5-core-runtime-correctness-and-wire-fidelity.md`, specifically
`docs/plans/34-route-and-unify-program-streaming.md`), performance work, and any
redesign of the `Optimizer`/`Compiler` public architecture beyond what the fixes
require. Where a finding is a contract-versus-implementation mismatch that does not
endanger users (the "optimizers never change structure" text versus `knnFewShot` and
`ensembleSearch`), the remedy is honest documentation, not redesign.


## Decomposition Strategy

The review findings fall into four functional concerns that touch mostly disjoint code
and are independently verifiable, so the initiative decomposes into four ExecPlans, one
per concern.

Plan 36 (instruction seeding) fixes the highest-severity defect: the semantic gap
between how the runtime resolves a node's effective instruction
(`shikumi/src/Shikumi/Program.hs:422`) and how the four instruction optimizers read and
write it. It is one coherent change — introduce an effective-instruction accessor in the
shared `Shikumi.Optimize.Search` plumbing and re-point `instructionSearch`, COPRO,
MIPROv2, and GEPA at it — plus the fixture diversification (non-empty signature
instructions, multi-node programs) that makes the bug class testable at all.

Plan 37 (budget contract) fixes budget enforcement across the same optimizer package.
It is kept separate from plan 36 because the two changes serve different behaviors
(candidate semantics versus cost accounting) and each is independently verifiable, but
they rewrite the same functions, so plan 37 soft-depends on plan 36 landing first.

Plan 38 (serialization fidelity) lives in `shikumi-compile`: the persistence envelope
(shape fingerprint), the RAG migration onto serializable parameters, and the
documentation reconciliation of the structure contract. It shares no code paths with
plans 36/37 beyond consuming the unchanged `CompiledProgram` type.

Plan 39 (evaluation accounting and API tail) lives in `shikumi-eval` and is a bundle of
small, related fixes to one package's accounting and public API. Bundling them keeps
the plan count low without coupling unrelated packages.

Alternatives considered. A single ExecPlan was rejected: the work spans three packages
and well over ten files, and the four concerns have no shared acceptance story. A
per-optimizer decomposition of the shikumi-optimize work (one plan per optimizer) was
rejected because every optimizer change flows through the same
`Shikumi.Optimize.Search` helpers and the same `StubLM` fixtures — eight plans editing
one module is maximal coupling, the opposite of what decomposition should buy. Merging
plans 36 and 37 into one optimizer plan was considered (they touch the same files) and
rejected on scope balance: each is a full plan's worth of work with its own acceptance
suite, and the seeding fix is urgent while the budget work is not.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|----|-------|------|-----------|-----------|--------|
| 36 | Fix Optimizer Instruction Seeding | docs/plans/36-fix-optimizer-instruction-seeding.md | None | None | In Progress |
| 37 | Enforce the Optimizer Budget Contract | docs/plans/37-enforce-the-optimizer-budget-contract.md | None | EP-36 | Not Started |
| 38 | Compiled Program Serialization Fidelity | docs/plans/38-compiled-program-serialization-fidelity.md | None | None | Not Started |
| 39 | Evaluation Accounting and API Tail | docs/plans/39-evaluation-accounting-and-api-tail.md | None | None | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-36).


## Dependency Graph

There are no hard dependencies: every plan compiles and is testable against the current
tree.

Plan 36 should land first. Plan 37 soft-depends on it because both rewrite the internals
of `shikumi-optimize/src/Shikumi/Optimize/Instruction.hs`, `COPRO.hs`, `MIPRO.hs`, and
`GEPA.hs`, and both extend `shikumi-optimize/src/Shikumi/Optimize/Search.hs` and the
`shikumi-optimize/test/StubLM.hs` fixtures. Doing the seeding fix first avoids rebasing
the budget-metering rewrite over changed candidate-selection code, and plan 37's budget
tests want plan 36's multi-node fixture (a two-node program is exactly where per-call
accounting diverges from per-run accounting). Plan 37 can technically start before plan
36 completes, at the cost of a painful merge; do not run them concurrently in separate
working trees.

Plan 38 is independent: it changes `shikumi-compile` only, and nothing in plans 36/37
depends on the serialization envelope (optimizers return in-memory `CompiledProgram`
values; they do not encode them). Plan 39 is independent: it changes `shikumi-eval`
internals whose only consumer contract used by the optimizers is
`aggregateScore <$> evaluatePure …`, which none of the plan-39 changes alter. Plans 38
and 39 can proceed in parallel with each other and with 36/37.

One cross-initiative note: plan 39's stream-usage fix touches the same `Stream`
operation of the `LLM` effect that `docs/plans/34-route-and-unify-program-streaming.md`
(under MasterPlan 5) routes program execution through. This is a soft, non-blocking
relationship — the usage fix is fully testable with stub streams today — but whoever
implements plan 39 should read the note in its Context section so the two efforts do
not double-count usage later.


## Integration Points

Shared artifact: `shikumi-optimize/src/Shikumi/Optimize/Search.hs` (the shared search
plumbing: `scoreOn`, `selectBest`, `setNodeInstr`, `instructionAt`, `freezeProgram`).
Plans involved: 36 and 37. Plan 36 defines the effective-instruction seam
(`effectiveInstructionAt` and the keep-aware setter `setNodeInstrIfNew`) in this module.
Plan 37 owns the budget-enforcement seam (the counting scorer / `BudgetMeter` and its
metered variants of `scoreOn`/`selectBest`) in this same module and must build on plan
36's helpers as landed, not around them: the metered scorer scores candidate programs
produced by plan 36's setters and must not reintroduce a raw
`fromMaybe "" . instructionAt` read anywhere.

Shared artifact: `shikumi-optimize/test/StubLM.hs` (the deterministic offline stub LM
and task fixtures). Plans involved: 36 and 37. Plan 36 extends it with a non-empty
signature-instruction fixture and a two-node pipeline fixture; plan 37 reuses both in
its budget tests (its counting interpreters `runStubLMCounting` and
`runJointStubLMCounting` already exist). Plan 37 must not fork a second stub; extend
the same module.

Shared artifact: `shikumi-optimize/src/Shikumi/Optimize/Types.hs` module header and the
`Budget` haddock. Plans involved: 37 and 38. Plan 37 owns the `Budget` documentation
(lines 69–73 today) and rewrites it to state the enforced accounting model precisely.
Plan 38 owns the "an optimizer never changes a program's structure or types" sentence
(lines 10–11 today) and amends it with the documented `knnFewShot`/`ensembleSearch`
exceptions and their persistence story. These are different paragraphs of the same
file; whichever plan lands second rebases a small doc edit.

Shared artifact: `Shikumi.Compile.Types.CompiledProgram` and
`shikumi-compile/src/Shikumi/Compile/Serialize.hs`. Plans involved: 38 (owner), with
36/37 as passive producers (optimizers emit `CompiledProgram` via `freezeProgram`).
Plan 38 changes the on-disk JSON envelope only; the in-memory type is untouched, so
plans 36/37 need no changes for it. Plan 38's shape-envelope work also gives
`knnFewShot`'s `Embed`-wrapped output a loud decode failure, which is why the contract
reconciliation (M4 of plan 38) lives there and not in the optimizer plans.

Shared artifact: `Shikumi.Eval` scoring surface (`evaluatePure`, `Report.aggregateScore`,
`Score`). Plans involved: 39 (owner) and 36/37 (consumers via `scoreOn`). Plan 39
narrows the `Score` export to hide the raw constructor; a workspace survey found no
production use of the raw constructor outside `shikumi-eval`'s own tests, so the
optimizer plans are unaffected, but if plan 39 lands while 36/37 are in flight, a
recompile of `shikumi-optimize` confirms nothing broke.

Cross-initiative note — shared test fixtures. `docs/masterplans/9-ci-and-shared-test-infrastructure.md`'s
EP-49 (`docs/plans/49-shared-test-harness-and-fixture-diversification.md`) introduces an
internal `shikumi-testing` package whose `Shikumi.Testing.Fixtures` module exports
`instructedSig` (non-empty-instruction signature) and `twoStageProg` (two-node program) —
the same fixture shapes as EP-36's `ruled` and `sentimentPipeline` in
`shikumi-optimize/test/StubLM.hs`. EP-36 stays self-contained on its package-local
versions so it is implementable before `shikumi-testing` exists; whichever plan lands
second converges the duplicates and records the outcome in Surprises & Discoveries.


## Progress

Track milestone-level progress across all child plans. Each entry names the child plan
and the milestone. This section provides an at-a-glance view of the entire initiative.

- [x] EP-36: M1 — effective-instruction helpers in Search.hs, unit-tested
- [x] EP-36: M2 — instructionSearch and COPRO seed from the effective instruction
- [x] EP-36: M3 — MIPROv2 baseline/applyVec preserve the student; original demos are a candidate
- [x] EP-36: M4 — GEPA reflects on the effective instruction
- [x] EP-36: M5 — fixture diversification (non-empty signature instruction, two-node pipeline) and acceptance suite green
- [ ] EP-37: M1 — BudgetMeter seam in Search.hs; instructionSearch/copro/searchJoint rewired
- [ ] EP-37: M2 — labeledFewShot budget parameterization
- [ ] EP-37: M3 — MIPROv2 phases 1–2 metered
- [ ] EP-37: M4 — GEPA seed-eval gate
- [ ] EP-37: M5 — bootstrap and random-search metering
- [ ] EP-37: M6 — ensemble budget via exact call counting
- [ ] EP-37: M7 — honest Budget docs and budget tests for all optimizers
- [ ] EP-38: M1 — shape-fingerprint envelope in Serialize.hs with loud mismatch errors
- [ ] EP-38: M2 — RAG migrated to instructionOverride; RAG round-trip test
- [ ] EP-38: M3 — chain-of-thought round-trip and wrong-template rejection tests
- [ ] EP-38: M4 — structure-contract reconciliation docs (knnFewShot, ensembleSearch)
- [ ] EP-39: M1 — stream usage accumulated in withUsageTotals, non-zero usage test
- [ ] EP-39: M2 — per-example timeout wired to the TimedOut variant
- [ ] EP-39: M3 — latency relabel
- [ ] EP-39: M4 — Score smart-constructor-only export
- [ ] EP-39: M5 — passCount docs note and coverage tests (numSamples > 1, custom FailScore)


## Surprises & Discoveries

Document cross-plan insights, dependency changes, scope adjustments, or unexpected
interactions between child plans. Provide concise evidence.

- 2026-07-03: EP-36's multi-node GEPA acceptance exposed tie drift in
  `Shikumi.Optimize.GEPA.bestOf`: a later child with the same aggregate score could
  replace an earlier equally good candidate and serialize an unnecessary instruction
  override on the echo node. EP-36 changed `bestOf` to fold from the seed and keep the
  earlier candidate on ties, preserving GEPA's never-worse artifact semantics.


## Decision Log

- Decision: Decompose the initiative into four ExecPlans — instruction seeding (36),
  budget contract (37), serialization fidelity (38), evaluation accounting (39) —
  rather than one omnibus plan or per-optimizer plans.
  Rationale: The findings come from a single production-readiness code review but fall
  into four functional concerns with disjoint acceptance stories across three packages.
  One plan would exceed the ExecPlan size guidance (three packages, >10 files);
  per-optimizer plans would maximize coupling through the shared
  `Shikumi.Optimize.Search` module and `StubLM` fixtures. Four plans keep each concern
  independently verifiable while confining the one real coupling (36↔37) to a single
  soft dependency.
  Date: 2026-07-01 (source: production-readiness code review of shikumi-optimize /
  shikumi-compile / shikumi-eval)

- Decision: Order plan 36 before plan 37 (soft dependency), leave 38 and 39 fully
  parallel.
  Rationale: 36 and 37 rewrite the same optimizer internals and share the Search.hs
  seam and StubLM fixtures; landing the HIGH-severity seeding fix first avoids rebasing
  the larger metering refactor and gives 37's budget tests the multi-node fixture 36
  introduces. 38 (shikumi-compile) and 39 (shikumi-eval) touch neither.
  Date: 2026-07-01

- Decision: Plan 37 owns the budget-enforcement seam (counting scorer / BudgetMeter) in
  `Shikumi.Optimize.Search`; plan 36 owns the effective-instruction helpers in the same
  module.
  Rationale: Both plans extend the one shared plumbing module; assigning each seam a
  single owning plan prevents the two from designing incompatible helpers, and the
  master plan's Integration Points section records the hand-off.
  Date: 2026-07-01

- Decision: Treat the `knnFewShot`/`ensembleSearch` violations of the "optimizers never
  change structure" contract as a documentation-and-persistence-story fix inside plan
  38, not a behavioral redesign.
  Rationale: Both optimizers are useful precisely because they change structure (a
  runtime `Embed` selector, an `Ensemble` combinator); the defect is that the contract
  text and the serialization story pretend otherwise. Honest docs plus a loud decode
  failure (which plan 38's shape envelope provides for free) fix the user-facing hazard
  at a fraction of the cost.
  Date: 2026-07-01


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original vision.

(To be filled during and after implementation.)


## Revision Notes

- 2026-07-01: Added the cross-initiative integration note on shared test fixtures
  (EP-49's `Shikumi.Testing.Fixtures` under `docs/masterplans/9-ci-and-shared-test-infrastructure.md`
  versus this initiative's package-local fixtures). Reason: master plan 9 and its
  children were authored in parallel with this plan, so the fixture seam was documented
  on only one side; the affected child plans carry matching Decision Log entries.
