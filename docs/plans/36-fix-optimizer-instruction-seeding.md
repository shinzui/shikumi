---
id: 36
slug: fix-optimizer-instruction-seeding
title: "Fix Optimizer Instruction Seeding"
kind: exec-plan
created_at: 2026-07-02T03:30:15Z
intention: "intention_01kwjfeaf8e86bvx2arbh7nk2c"
master_plan: "docs/masterplans/6-optimizer-and-evaluation-correctness.md"
---

# Fix Optimizer Instruction Seeding

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

shikumi is a Haskell framework for building typed language-model programs. A program is
a tree of `Predict` nodes; each node carries a `Signature` (its typed input/output
schema plus a base instruction string written by the program author) and a `Params`
record (tunable state: an optional `instructionOverride` and a list of few-shot
`demos`). The `shikumi-optimize` package ships optimizers that search for better
`Params` and promise, in their documentation, that the returned program is never worse
than the input.

That promise is currently false for every program whose signature carries a non-empty
instruction — which is every realistic program. At run time a node's effective
instruction is "the override if present, else the signature's base instruction"
(`shikumi/src/Shikumi/Program.hs:422`). But all four instruction optimizers read the
"current instruction" as `fromMaybe "" (instructionOverride …)` — they see an empty
string for any node that has no override yet, hand that empty string to the proposer as
the retained "current" candidate, score a blanked copy of the program instead of the
true student, and write the winner back as an override even when the winner is
"keep what you had". MIPROv2 goes further: it unconditionally rewrites every node's
instruction override and demo set for every point of its search grid, including the
baseline point, so its "baseline" score is measured on a blanked, demo-wiped program and
the function can return a program strictly worse than its input. The bug is invisible
today because every optimizer test fixture is built from `mkSignature ""`
(`shikumi-optimize/test/StubLM.hs:129`).

After this change, a user who runs any shipped instruction optimizer
(`instructionSearch`, `copro`, `miprov2`, `gepa`) over a program whose signature
instruction already solves the task gets back a program that still solves the task: the
true student is always among the scored candidates, "keep the current instruction" is a
genuine no-op, MIPROv2's baseline is the real input program, pre-existing demos survive,
and multi-node programs are optimized with correct per-node indexing. A new acceptance
test demonstrates each of these behaviors failing before the fix and passing after.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1 completed 2026-07-03 — added `effectiveInstructionAt` and `setNodeInstrIfNew` to
      `shikumi-optimize/src/Shikumi/Optimize/Search.hs`; unit tests in a new
      `shikumi-optimize/test/SearchSpec.hs` (registered in the cabal file and
      `test/Main.hs`); `cabal test shikumi-optimize` passed with 46 tests.
- [x] M2 completed 2026-07-03 — re-pointed `Instruction.hs` (instructionSearch) and
      `COPRO.hs` at the new helpers; added failing-before tests for both in
      `shikumi-optimize/test/SeedingSpec.hs`; `cabal test shikumi-optimize` passed
      with 48 tests after the fix.
- [ ] M3: fix MIPROv2 — effective-instruction seeding, per-node original demos as demo
      candidate 0, identity `applyVec` at the base vector; failing-before test plus a
      `bootstrapDemoCandidates` unit test
- [ ] M4: GEPA reflects on the effective instruction; capturing-stub test
- [ ] M5: fixture diversification — `ruled` (non-empty signature instruction) and
      `sentimentPipeline` (two-node) fixtures in StubLM; multi-node acceptance tests
      for all four optimizers; full `cabal test shikumi-optimize` green
- [ ] Update haddocks that describe the old behavior (Instruction.hs header, MIPRO.hs
      config comments, Search.hs)


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)

- 2026-07-03: M1's helper tests passed under `cabal test shikumi-optimize`, proving
  `effectiveInstructionAt` reads the signature base instruction when no override exists,
  override text when present, and the second node's base instruction in a two-node
  pipeline. Evidence: the `Search` test group passed and the full suite reported `All
  46 tests passed`.

- 2026-07-03: The new M2 regression tests failed before the `Instruction.hs` and
  `COPRO.hs` source rewiring exactly as expected: `instructionSearch: expected 0.0 >=
  1.0` and `copro: expected 0.0 >= 1.0`, showing both optimizers blanked a solved
  signature instruction. After switching both read paths to `effectiveInstructionAt`
  and writes to `setNodeInstrIfNew`, the same suite reported `All 48 tests passed`.


## Decision Log

- Decision: Fix the read side ("current instruction" = effective instruction, i.e.
  override-or-signature-base) and the write side ("keep current" writes no override) in
  one plan, via two small helpers in `Shikumi.Optimize.Search`, rather than only fixing
  the read side.
  Rationale: Fixing only the read would still write the (correct) current instruction
  back as an override, which is runtime-equivalent but pollutes serialized `Params`,
  masks later signature edits, and makes "did the optimizer change anything?"
  undecidable from the artifact. A keep-aware setter makes retention a true identity.
  Date: 2026-07-01 (source: production-readiness code review)

- Decision: Reuse the existing core accessor `nodeInstructionsIndexed`
  (`shikumi/src/Shikumi/Program.hs:485-506`) to read signature base instructions instead
  of adding a new accessor to `shikumi` core.
  Rationale: It already exists, is index-aligned with `foldParams` by the documented
  ordering law, is currently unused by the optimizers, and avoids touching the core
  package.
  Date: 2026-07-01

- Decision: The `ruled` and `sentimentPipeline` fixtures are added to the package-local
  `shikumi-optimize/test/StubLM.hs` rather than waiting on the shared fixture module
  planned in `docs/plans/49-shared-test-harness-and-fixture-diversification.md` (under
  `docs/masterplans/9-ci-and-shared-test-infrastructure.md`), which exports the
  equivalent `instructedSig` (non-empty-instruction signature) and `twoStageProg`
  (two-node program) from `Shikumi.Testing.Fixtures`.
  Rationale: this plan must be implementable regardless of whether `shikumi-testing`
  exists yet, and the fixtures here are wired to this suite's stub responder mechanics.
  Unlike the core package (see plan 32), `shikumi-optimize`'s test suite has no layering
  obstacle to adopting `shikumi-testing` later; whichever plan lands second converges the
  duplicates and records the outcome in its master plan's Surprises & Discoveries.
  Date: 2026-07-01

- Decision: MIPROv2's demo-candidate list becomes per-node, with the node's current demo
  set as candidate 0 (the empty set remains a distinct candidate when the current set is
  non-empty).
  Rationale: The old list (`[] : labeled : bootstrapped`, identical for every node)
  guaranteed that a student's pre-existing demos were destroyed by every grid point
  including the baseline. Candidate 0 must be "no change" for the baseline vector to
  mean "the input program".
  Date: 2026-07-01

- Decision: Keep `instructionAt` exported from `Search.hs` even though the optimizers
  stop using it.
  Rationale: "The override stored at node n, if any" remains a legitimate question
  (tests ask it to assert that keep-current wrote nothing); deleting it buys nothing.
  Date: 2026-07-01


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This section assumes no prior knowledge of the repository.

The repository is a cabal multi-package workspace. The packages relevant here:

- `shikumi` — the core. `shikumi/src/Shikumi/Program.hs` defines the `Program i o` GADT
  (a tree whose leaves are `Predict sig ps` nodes), the `Params` record
  (`instructionOverride :: Maybe Text`, `demos :: [Demo]`, defined at line 123), and the
  parameter interface: `foldParams` (all `Params` in left-to-right depth-first order),
  `mapParamsAt n f` (edit the `Params` at index `n`), `nodeFieldsIndexed`, and
  `nodeInstructionsIndexed`. The run-time semantics that this whole plan revolves
  around is `effectiveSignature` at `Program.hs:413-423`:

  ```haskell
  instr = fromMaybe (getInstruction sig) (instructionOverride ps)
  ```

  (line 422) — the override wins when present, otherwise the signature's base
  instruction applies. `nodeInstructionsIndexed` (`Program.hs:485-506`) returns, for
  every `Predict` node in `foldParams` order, the *signature's* base instruction; it is
  index-aligned with `foldParams`, and no optimizer currently uses it.

- `shikumi-optimize` — the optimizers. All share
  `shikumi-optimize/src/Shikumi/Optimize/Search.hs`, which provides `scoreOn` (score a
  program over a dataset by running `evaluatePure` and taking the mean score),
  `setNodeInstr idx instr prog` (line 77–78: sets node `idx`'s `instructionOverride` to
  `Just instr`), and `instructionAt idx prog` (line 81–84: returns the *override* at
  node `idx`, `Nothing` when unset). The four instruction optimizers:

  - `Instruction.hs` — `instructionSearch`, greedy one-pass coordinate ascent. Line 69
    reads `curInstr = fromMaybe "" (instructionAt idx prog)`; line 89 writes
    `setNodeInstr idx (maybe curInstr fst best) prog` — always an override, even for
    keep-current. Its module header (lines 11–13) documents the never-worse guarantee
    this plan restores.
  - `COPRO.hs` — `copro`, multi-round coordinate ascent with scored history. Line 99
    reads `cur = fromMaybe "" (instructionAt idx prog)`; `scoreNew` (line 131) scores
    `setNodeInstr idx c prog`; `setBest` (lines 143–147) always writes the best recorded
    instruction as an override — including writing `Just ""` when the empty string is
    the best-scoring entry.
  - `MIPRO.hs` — `miprov2`/`miprov2With`, joint instruction×demo grid search.
    `proposeInstructionCandidates` (line 197) reads
    `curInstr = fromMaybe "" (instructionOverride ps)`. `bootstrapDemoCandidates`
    (line 176) builds per-node demo candidates as
    `take … ([] : filter (not . null) [labeledSet, bootSet])` — the empty set is
    candidate 0 and the node's original demos are never a candidate. `applyVec`
    (lines 279–291) unconditionally sets `instructionOverride = Just (…)` and
    `demos = …` on every node for every grid vector, including the base vector
    `(0,0)`. The baseline is scored at line 254 on `apply baseVec` — a blanked,
    demo-wiped program — and line 275 returns `apply best` unconditionally, so the
    output can be strictly worse than the input.
  - `GEPA.hs` — `gepa`, reflective evolutionary search. Line 179 feeds
    `fromMaybe "" (instructionOverride (paramsAt idx prog))` to the reflective
    proposer's `currentInstruction` field — a degraded prompt signal (GEPA's
    never-worse property itself is safe, because its seed candidate is
    `foldParams student` and `bestOf` falls back to the seed).

  The grounded proposer (`Propose/Grounded.hs:127`) always prepends
  `currentInstruction req` to its returned candidates — retention is guaranteed by the
  proposer, so garbage-in (an empty "current" instruction) means garbage-retained.

- `shikumi-optimize/test/StubLM.hs` — the deterministic offline stub LM used by every
  optimizer test. Its task: classify a `Sentence` into a `Label`
  ("positive"/"negative"). The stub answers correctly when the request's system prompt
  contains the word `RULE` (see `ruleInstruction`, line 152) or when word-overlapping
  demos are present; otherwise it answers the never-correct `"neutral"`. Crucially,
  `sentimentSig = mkSignature ""` (line 129) — the only fixture signature has an empty
  instruction, which is exactly why this bug ships green. The proposer side of the stub
  returns `ruleInstruction` only when the request carries the "creative" stylistic tip
  (tip index 1 in `Propose/Tips.hs`; `instructionSearch` starts at tip 0, `copro` and
  MIPROv2 at tip 1, and each candidate `j` uses tip `tipIndex + j`).

Term definitions used below. "Effective instruction" of node `n`: the string the
runtime will actually use — `instructionOverride` if `Just`, else the signature base
instruction, exactly mirroring `Program.hs:422`. "True student": the input program with
no modifications whatsoever. "Blanked program": the input program with
`instructionOverride = Just ""` written onto a node, which at run time replaces a
non-empty signature instruction with the empty string.

Build/test environment: GHC 9.12.4 via the nix dev shell. From the repository root
(`/…/shikumi`), enter the shell with `nix develop .#ghc9124` and run
`cabal test shikumi-optimize` (or `just test-one shikumi-optimize`).


## Plan of Work

### Milestone 1 — effective-instruction helpers in Search.hs

Scope: add the two helpers every later milestone uses, plus their unit tests. At the end
of this milestone the helpers exist, are exported, and are proven correct on programs
with and without overrides, single- and multi-node; nothing else has changed behavior.

Edit `shikumi-optimize/src/Shikumi/Optimize/Search.hs`. Extend the export list with
`effectiveInstructionAt` and `setNodeInstrIfNew`, extend the `Shikumi.Program` import
with `nodeInstructionsIndexed`, and add `Data.Maybe (fromMaybe)` to the imports. Append:

```haskell
-- | The instruction node @idx@ actually runs with: its 'instructionOverride' when
-- set, else its signature's base instruction — the same precedence the runtime
-- applies in @effectiveSignature@ (shikumi/src/Shikumi/Program.hs). Out-of-range
-- indices yield the empty string. @nodeInstructionsIndexed@ and @foldParams@ are
-- index-aligned by the core ordering law, so zipping them addresses each node once.
effectiveInstructionAt :: Int -> Program i o -> Text
effectiveInstructionAt idx prog =
  case drop idx (zip (nodeInstructionsIndexed prog) (foldParams prog)) of
    ((base, ps) : _) -> fromMaybe base (instructionOverride ps)
    [] -> ""

-- | Set node @idx@'s instruction override, unless the requested instruction is
-- already the node's effective instruction — in that case do nothing, so
-- "keep the current instruction" never writes an override (and never masks the
-- signature default behind a redundant, serialized copy of itself).
setNodeInstrIfNew :: Int -> Text -> Program i o -> Program i o
setNodeInstrIfNew idx instr prog
  | instr == effectiveInstructionAt idx prog = prog
  | otherwise = setNodeInstr idx instr prog
```

Create `shikumi-optimize/test/SearchSpec.hs` exporting `tests :: TestTree` with unit
cases (fixtures from `StubLM`; build a node with an override via
`setNodeInstr 0 "x" sentimentProg`):

- `effectiveInstructionAt 0` on a no-override program whose signature instruction is
  `"S"` returns `"S"`; after `setNodeInstr 0 "x"` it returns `"x"`; out-of-range
  returns `""`.
- `setNodeInstrIfNew 0 base prog` where `base` is the signature instruction leaves
  `instructionAt 0` as `Nothing` (no override written); `setNodeInstrIfNew 0 "y"`
  writes `Just "y"`.
- On a two-node program (introduced fully in M5; for M1 build an inline
  `sentimentProg >>> predict echoSig` locally or defer the multi-node case to M5 —
  either is acceptable, note the choice in Progress).

Register the module: add `SearchSpec` to the test-suite `other-modules` in
`shikumi-optimize/shikumi-optimize.cabal`, and in `shikumi-optimize/test/Main.hs` add
`import SearchSpec qualified` and `SearchSpec.tests` to the test group.

Acceptance: `cabal test shikumi-optimize` passes with the new unit cases.

### Milestone 2 — instructionSearch and COPRO

Scope: the two coordinate-ascent optimizers seed from and retain the effective
instruction. At the end, a program whose signature instruction already solves the task
survives both optimizers unchanged, proven by tests that fail before this milestone.

In `shikumi-optimize/src/Shikumi/Optimize/Instruction.hs`:

- Change the import line 41 to
  `import Shikumi.Optimize.Search (effectiveInstructionAt, freezeProgram, scoreOn, setNodeInstr, setNodeInstrIfNew)`
  (drop `instructionAt`; keep `setNodeInstr` only if still used after the edits —
  it is not, so drop it too). Drop the now-unused `Data.Maybe (fromMaybe)` import if
  GHC flags it.
- Line 69: `let curInstr = fromMaybe "" (instructionAt idx prog)` becomes
  `let curInstr = effectiveInstructionAt idx prog`.
- Line 61 (inside `scoreCands`): `scoreOn train metric (setNodeInstr idx c prog)`
  becomes `scoreOn train metric (setNodeInstrIfNew idx c prog)` — now the retained
  candidate scores the true student.
- Line 89: `pure (setNodeInstr idx (maybe curInstr fst best) prog, calls2)` becomes
  `pure (setNodeInstrIfNew idx (maybe curInstr fst best) prog, calls2)`.
- Update the module header (lines 11–13 area): the "current instruction is always
  retained" sentence should state that "current" means the effective instruction
  (override or signature base) and that retaining it writes no override.

In `shikumi-optimize/src/Shikumi/Optimize/COPRO.hs`, the same three substitutions:
line 99 `cur = effectiveInstructionAt idx prog`; `scoreNew` line 131 uses
`setNodeInstrIfNew`; `setBest` line 145 uses `setNodeInstrIfNew`. Adjust the import
(line 41) accordingly and drop `Data.Maybe (fromMaybe)` if unused.

Tests (new module `shikumi-optimize/test/SeedingSpec.hs`, registered like SearchSpec;
copy the `runStub` harness from `AcceptanceSpec.hs`). Fixtures: `ruled` (added to
StubLM in M5, but needed here — add it now as part of this milestone; see M5 for the
definition) is `predict (mkSignature ruleInstruction)`, a student whose signature
already solves the task (scores 1.0 on the held-out set under the stub).

- "instructionSearch never degrades a solved student": score `ruled` on the held-out
  set (expect 1.0); run
  `optimize (instructionSearch 1 defaultBudget) trainset exactMatch ruled` — with one
  proposal at tip 0 the stub proposes only a bland instruction, so the only winning
  candidate is the retained current one; score the result on held-out. Assert
  `after >= before`. Before this milestone the retained candidate is `""`, the blanked
  program scores 0, the bland proposal scores 0, and the returned program carries
  `instructionOverride = Just ""` — `after` is 0.0 and the test fails. Additionally
  assert `instructionAt 0 (compiledProgram cp) == Nothing` (keep-current wrote no
  override).
- "copro never degrades a solved student when the proposer is unaffordable": use a
  4-example trainset and `copro CoproConfig { breadth = 2, depth = 1, budget = Budget
  { maxLmCalls = 4, maxCandidates = 32 } }` over `ruled`. The proposer costs
  `4 + (breadth-1) = 5 > 4` so COPRO falls back to `[cur]`; scoring one candidate costs
  4 ≤ 4 so it is scored. Before: `cur` is `""`, the blanked program scores 0, and
  `setBest` writes `Just ""` — the result scores 0. After: `cur` is the rule
  instruction, scoring it is an identity, and the result still scores 1.0. Assert
  `after >= before` and no override written.

### Milestone 3 — MIPROv2

Scope: the joint optimizer's baseline is the true student; grid index 0 on each axis
means "no change"; original demos are a candidate. At the end, `miprov2With` can no
longer return a program worse than its input, proven by a failing-before test.

In `shikumi-optimize/src/Shikumi/Optimize/MIPRO.hs`:

- `proposeInstructionCandidates` (line 197): replace
  `curInstr = fromMaybe "" (instructionOverride ps)` with
  `curInstr = effectiveInstructionAt k student` (import it from
  `Shikumi.Optimize.Search`; the `ps` binding from the `zip3` remains used by
  `demoTexts`… it is not — `demoTexts` reads `nodeDemoSets`; change the `zip3` to a
  plain `zip [0 ..] demoCands` and drop `foldParams student` from it, or keep the zip3
  and `_ps`-bind the params; prefer the former). The grounded proposer then retains the
  real current instruction as candidate 0.
- `bootstrapDemoCandidates` (lines 163–178): make the candidate sets per-node with the
  node's current demos first. Replace the last two lines of the `let` and the return:

  ```haskell
  let cap = max 1 (maxBootstrappedDemos cfg)
      labeledSet = take cap (map (\(Example i o) -> recoverDemo i o) exs)
      bootSet = take cap bootstrapped
      -- Candidate 0 is the node's current demo set (identity); the empty set and
      -- the labelled/bootstrapped sets follow, de-duplicated preserving order.
      nodeSets ps =
        take
          (max 1 (numDemoCandidates cfg))
          (dedup (demos ps : [] : filter (not . null) [labeledSet, bootSet]))
  pure (map nodeSets (foldParams student))
  ```

  with a local order-preserving `dedup :: Eq a => [a] -> [a]` (same shape as COPRO's
  `dedupNew`; `Demo` derives `Eq` — verify, and if it does not, add the instance in
  core or compare via `toJSON`). Update the field haddock at line 98
  (`numDemoCandidates`: "incl. the node's current demos at index 0") and the phase-1
  function haddock (lines 146–152).
- `applyVec` (lines 279–291): index 0 on either axis must be an identity. Replace with:

  ```haskell
  applyVec :: [[Text]] -> [[[Demo]]] -> Program i o -> JointVec -> Program i o
  applyVec instrCands demoCands prog vec = foldl step prog (zip [0 ..] vec)
    where
      step p (k, (i, d)) =
        setNodeInstrIfNew k (instrCands !! k !! i) $
          mapParamsAt k (\ps -> ps {demos = demoCands !! k !! d}) p
  ```

  Because instruction candidate 0 is the effective current instruction and demo
  candidate 0 is the node's own demo list, `applyVec … baseVec` is now observationally
  the input program: the baseline score at line 254 measures the true student, the
  early `dsSize > maxCalls` return at lines 251–252 returns the student unchanged, and
  the final `apply best` at line 275 returns the student whenever no trial strictly
  improved on it. Update the module header's phase descriptions accordingly.

Tests (in `SeedingSpec.hs` or a new group in `Miprov2Spec.hs`):

- "miprov2 never returns worse than the input": student =
  `withDemos coveringDemos ruledJoint` where `ruledJoint` is a predict node whose
  signature instruction is `ruleInstruction` and `coveringDemos` are region-B demos
  (reuse the demo data `Miprov2Spec.hs` already has for the joint task; run under
  `runJointStubLM`). This student scores 1.0 on a mixed region-A/region-B held-out
  set. Run `optimize (miprov2With cfg student) trainset metric student` with
  `cfg = (miprov2Auto Miprov2Light) { budget = Budget { maxLmCalls = datasetSize
  trainset, maxCandidates = 32 } }` — the budget covers exactly the baseline full
  evaluation, so no trial can be accepted and the search returns its baseline vector.
  Before: the returned program is the blanked, demo-wiped `apply baseVec` and scores
  0. After: it is the student itself and scores 1.0. Assert `after >= before`.
- "original demos are demo candidate 0": call `bootstrapDemoCandidates` directly (it is
  exported) with a student carrying demos `ds0`; assert the head of every node's
  candidate list is `ds0` and that `[]` still appears as a candidate.

### Milestone 4 — GEPA

Scope: the reflective proposer sees the node's real instruction. At the end, the
`ReflectIn.currentInstruction` field carries the effective instruction, proven by
capturing the rendered proposer request.

In `shikumi-optimize/src/Shikumi/Optimize/GEPA.hs`, `mutateNode` line 179: replace
`let cur = fromMaybe "" (instructionOverride (paramsAt idx prog))` with
`let cur = effectiveInstructionAt idx prog` (import from `Shikumi.Optimize.Search`,
which GEPA already imports for `freezeProgram`). `paramsAt` may become unused — delete
it if so, along with the `fromMaybe` import if flagged.

In `shikumi-optimize/test/StubLM.hs`, add `runGepaStubLMCapturing :: (IOE :> es) =>
IORef [Text] -> Eff (LLM : es) a -> Eff es a`, a copy of `runStubLMCapturing`
(lines 180–185) that answers with `respondGepa` instead of `respondTo` and records
`fullRequestText` for every completion. Export it.

Test (in `GepaSpec.hs` or `SeedingSpec.hs`): run `gepa reflectiveProposer fbMetric
defaultBudget` over `ruled`-with-a-critiquing-feedback-metric (a `FeedbackMetric` that
always returns a non-empty critique containing "specific", so mutation happens) under
the capturing stub; assert that at least one captured request text contains
`ruleInstruction`'s text. Before the fix the proposer request renders an empty current
instruction and the assertion fails; after it passes. (GEPA's never-worse property is
already guaranteed by its seed-candidate fallback — do not assert score regressions
here, only the prompt signal.)

### Milestone 5 — fixture diversification and multi-node acceptance

Scope: make the whole bug class permanently testable. At the end, StubLM offers a
solved single-node fixture and a two-node pipeline fixture, and every optimizer has an
acceptance case over a multi-node program with non-empty signature instructions.

In `shikumi-optimize/test/StubLM.hs`:

- Add and export `ruled :: Program Sentence Label`;
  `ruled = predict (mkSignature ruleInstruction)` (used by M2–M4; if you added it there
  already, this item is done).
- Add and export a two-node pipeline. Define
  `echoSig :: Signature Label Label; echoSig = mkSignature "Echo the sentiment label unchanged."`
  and `sentimentPipeline :: Program Sentence Label;
  sentimentPipeline = sentimentProg >>> predict echoSig` (import `(>>>)` from
  `Shikumi.Combinator`). Teach the stub to serve the echo node: in `answerSentiment`
  and `answerJoint`, before the existing logic, detect an echo request — the last user
  text of an echo-node request renders a `Label`, i.e. it begins with `sentiment:` —
  and return the text after the colon, trimmed. Concretely, add a guard using a new
  helper `parseEcho :: Text -> Maybe Text` that strips an optional `sentiment:` prefix
  and returns `Just value` when present. The echo node therefore behaves as an
  identity regardless of instruction or demos, so pipeline scores equal single-node
  scores and existing score expectations transfer.

Tests (extend `AcceptanceSpec.hs` with a new test group "seeding over multi-node"):

- For each of `instructionSearch 3 defaultBudget`, `copro defaultCoproConfig`,
  `miprov2 Miprov2Light` (under the joint stub use the plain stub instead — the
  pipeline task is the sentiment task), and `gepa reflectiveProposer fbMetric
  defaultBudget`: optimize `underspecifiedPipeline = sentimentPipeline` (node 0 has the
  empty-instruction sentiment signature; node 1 has a non-empty echo signature) on the
  existing trainset and assert (a) the held-out score after is `>=` the score before
  and reaches the 0.75 floor for the searchers that can reach it (instructionSearch,
  copro — the creative-tip proposal supplies `ruleInstruction`), and (b) node 1's
  effective instruction is unchanged: `effectiveInstructionAt 1 result ==
  "Echo the sentiment label unchanged."`. This exercises `applyVec`'s `!!` indexing,
  GEPA's `idx = step \`mod\` nNodes` round-robin, and coordinate ascent across nodes
  for `nNodes > 1`, none of which any current test reaches.
- "true student is always scored" (property-flavored unit): for `instructionSearch`,
  wrap the stub with `runStubLMCapturing` and assert some captured sentiment-request
  carries the `RULE` system prompt when optimizing `ruled` — i.e. the candidate set
  included the true student's rendering. (Cheap proxy for a full property; note it in
  the test comment.)

Finally, sweep the haddocks: `Instruction.hs` header, `COPRO.hs` retention sentences,
`MIPRO.hs` header and config field docs, `Search.hs` new helpers — all must describe
the effective-instruction semantics. Do not touch `shikumi` core.


## Concrete Steps

All commands run from the repository root. Enter the dev shell once per session:

```bash
cd /path/to/shikumi
nix develop .#ghc9124
```

Iterate per milestone:

```bash
cabal build shikumi-optimize
cabal test shikumi-optimize
```

or equivalently `just test-one shikumi-optimize`. Expected failure transcript when a
new failing-before test is added ahead of its fix (M2 example):

```text
    M-seeding
      instructionSearch never degrades a solved student: FAIL
        instructionSearch: expected 0.0 >= 1.0
1 out of N tests failed
```

and after the corresponding source fix:

```text
All N tests passed (…s)
```

Commit at every green milestone boundary with a Conventional Commits subject and the
required trailers. Every commit in this plan MUST carry exactly these trailers:

```text
fix(optimize): seed instruction search from the effective instruction

MasterPlan: docs/masterplans/6-optimizer-and-evaluation-correctness.md
ExecPlan: docs/plans/36-fix-optimizer-instruction-seeding.md
Intention: intention_01kwjfeaf8e86bvx2arbh7nk2c
```

(Adjust the subject per commit: `test(optimize): …` for fixture/test-only commits,
`docs(optimize): …` for haddock sweeps.)

Before finishing, run the full workspace test suite to catch downstream surprises:

```bash
cabal test all
```


## Validation and Acceptance

The change is accepted when all of the following hold, in order:

1. New tests demonstrably fail before their paired source fix. Verify at least once by
   running the M2 test against unmodified `Instruction.hs` (e.g. `git stash` the source
   edit, run, unstash) and recording the failing output in Surprises & Discoveries.
2. `cabal test shikumi-optimize` inside `nix develop .#ghc9124` passes, including the
   pre-existing `AcceptanceSpec` improvement floors (`>= 0.75`), proving optimizers
   still improve genuinely underspecified programs — the fix must not achieve
   never-worse by making optimizers inert.
3. Behavior checks encoded in the tests: for a student whose signature instruction
   already solves the task, each of `instructionSearch`, `copro`, `miprov2` returns a
   program scoring `>=` the input on held-out data, with no `instructionOverride`
   written for kept nodes (`instructionAt n == Nothing`); `bootstrapDemoCandidates`
   lists the node's current demos as candidate 0; GEPA's captured reflective request
   contains the signature instruction text; two-node pipelines optimize without
   touching the second node's effective instruction.
4. `cabal test all` passes (other packages consume `shikumi-optimize` only through
   `optimize`, whose signature is unchanged, so this should be automatic).


## Idempotence and Recovery

Every step is an ordinary source edit plus a test run; re-running any command is safe.
The helpers in M1 are purely additive, so if a later milestone goes wrong you can
revert that milestone's file(s) with `git checkout -- <path>` without losing M1. Tests
are deterministic (stub LM, no network, no randomness beyond fixed LCG streams
elsewhere), so a failure is always reproducible by re-running the same command. If a
milestone is committed and later found faulty, prefer a forward-fixing commit with the
same trailers over history rewrites.


## Interfaces and Dependencies

No new external dependencies. Modules touched, all in `shikumi-optimize` unless noted:

- `Shikumi.Optimize.Search` — gains
  `effectiveInstructionAt :: Int -> Program i o -> Text` and
  `setNodeInstrIfNew :: Int -> Text -> Program i o -> Program i o`; keeps
  `instructionAt`, `setNodeInstr`, `scoreOn`, `selectBest`, `freezeProgram` unchanged.
  Consumes `Shikumi.Program.nodeInstructionsIndexed` (already exported by core).
- `Shikumi.Optimize.Instruction`, `Shikumi.Optimize.COPRO`, `Shikumi.Optimize.MIPRO`,
  `Shikumi.Optimize.GEPA` — internal edits only; public signatures
  (`instructionSearch :: Int -> Budget -> Optimizer i o`,
  `copro :: CoproConfig -> Optimizer i o`,
  `miprov2 :: Miprov2Auto -> Optimizer i o`,
  `miprov2With :: Miprov2Config -> Program i o -> Optimizer i o`,
  `bootstrapDemoCandidates`, `proposeInstructionCandidates`, `searchJoint`,
  `gepa :: Program ReflectIn ReflectOut -> FeedbackMetric o -> Budget -> Optimizer i o`)
  are unchanged.
- Test suite — new `SearchSpec.hs`, `SeedingSpec.hs`; extended `StubLM.hs`
  (`ruled`, `echoSig`, `sentimentPipeline`, `parseEcho`, `runGepaStubLMCapturing`),
  `AcceptanceSpec.hs`, and cabal `other-modules`.

Coordination note (from the master plan): plan 37
(`docs/plans/37-enforce-the-optimizer-budget-contract.md`) adds a budget-metering seam
to the same `Search.hs` and rewrites the same optimizer internals; it is sequenced
after this plan. Nothing in this plan may depend on plan 37's artifacts.

Shared fixtures (cross-initiative): `docs/plans/49-shared-test-harness-and-fixture-diversification.md`
introduces `Shikumi.Testing.Fixtures` in an internal `shikumi-testing` package, exporting
`instructedSig` and `twoStageProg` — the same fixture shapes as this plan's `ruled` and
`sentimentPipeline`. This plan stays self-contained on its package-local versions (see the
Decision Log); if `shikumi-testing` exists when you implement this, prefer importing the
shared fixtures where the stub mechanics allow, and record the convergence (or the reason
it was skipped) in the master plan's Surprises & Discoveries section.


## Revision Notes

- 2026-07-01: Added the cross-initiative note on shared test fixtures (EP-49's
  `Shikumi.Testing.Fixtures` vs. this plan's `ruled`/`sentimentPipeline` in `StubLM.hs`)
  and the matching Decision Log entry. Reason: master plan 9 and its children were
  authored in parallel with this plan, so the fixture seam was documented on only one
  side.
