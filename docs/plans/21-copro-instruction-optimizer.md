---
id: 21
slug: copro-instruction-optimizer
title: "COPRO instruction optimizer"
kind: exec-plan
created_at: 2026-06-09T22:35:41Z
intention: "intention_01ktq80q01emxtjfxzd3rw4tjs"
master_plan: "docs/masterplans/3-shikumi-dspy-parity-optimizers-and-self-refinement.md"
---

# COPRO instruction optimizer

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Shikumi is a Haskell framework for building programs out of language-model (LM) calls. A
*program* is a value of type `Program i o` (a typed function from input `i` to output `o`
implemented by one or more LM calls). Each LM call carries an *instruction* — a natural-language
string telling the model what to do — and the instruction is one of the things an *optimizer*
is allowed to rewrite to make the program score better on a dataset. Today Shikumi ships a
greedy instruction optimizer called `instructionSearch` (in
`shikumi-optimize/src/Shikumi/Optimize/Instruction.hs`): it visits each LM call once, asks a
proposer for a handful of fresh instructions, scores each, and keeps the best. It improves a
weak program, but it is *one-shot* per node — it never looks at how earlier proposals scored to
inform later ones, and it never revisits a node after the first round.

This plan delivers **COPRO** (short for "Coordinate-ascent PROmpt optimization"), a more
principled instruction optimizer modelled on DSPy's optimizer of the same name. After this
change a Shikumi user can write:

```haskell
compiled <- optimize (copro defaultCoproConfig) trainset exactMatch weakProgram
```

and get back a `CompiledProgram Sentence Label` whose instructions have been improved over
several *rounds* (called **depth**), where each round generates several candidate instructions
(called **breadth**) using a *grounded* proposer that is told the history of every instruction
tried so far together with the validation score each one earned. Because COPRO feeds the
"attempt history" forward, later rounds can build on what worked and avoid what did not — a
capability the one-shot `instructionSearch` lacks.

The user-visible, demonstrable outcome — provable offline with no network and no API key, using
a deterministic stub LM — is this: a deliberately *weak* sentiment-classification program (one
whose instruction is empty, so it answers a useless constant and scores `0`) scores strictly
higher on a **held-out** dataset (one the optimizer never trains on) after `copro` than before;
and running `copro` with a *deeper* depth never scores worse than running it with a shallower
depth on the same fixture. The optimized program round-trips through Shikumi's serialization
(`encodeCompiled` / `decodeCompiledOnto`) unchanged, exactly like every other optimizer's
output, so the CLI and on-disk format keep working.

**Relationship to the existing `instructionSearch`.** COPRO is the principled generalization of
`instructionSearch`: the existing optimizer is exactly COPRO with depth `1` and no attempt
history. We **keep `instructionSearch` as-is** (it is referenced by existing tests in
`shikumi-optimize/test/InstructionSpec.hs` and `AcceptanceSpec.hs`, and by the MasterPlan's
acceptance comparisons) and add `copro` alongside it as a new module. We do **not** delete or
rewrite `instructionSearch`; the two coexist, and COPRO reuses the same proposer-as-a-Program
pattern, the same `Budget` accounting, the same `setNodeInstr`/`instructionAt` node-addressing
helpers (lifted into a shared location), and the same "the current instruction is always a
candidate" safety property that guarantees a node can never be made worse than where it started.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M0: (2026-06-09) `Shikumi.Optimize.COPRO` with `CoproConfig`/`defaultCoproConfig`/`copro`,
  wired into the cabal and re-exported from `Shikumi.Optimize`. `setNodeInstr`/`instructionAt`
  lifted into `Shikumi.Optimize.Search` (shared by `instructionSearch` and `copro`); existing
  suite stayed green through the refactor.
- [x] M1: (2026-06-09) Breadth candidates come from EP-19's *delivered* `proposeInstructions`
  (not a plan-local `coproProposer`/`variant:N` stub, which EP-19 obsoleted). The scored attempt
  history is threaded as EP-19's `ProposeRequest.history :: [PastInstruction]`, which the proposer
  renders internally — so COPRO needs no `renderHistory` of its own. `tipIndex = 1` so the
  creative tip (which unlocks the stub's RULE candidate) is always offered.
- [x] M2: (2026-06-09) `optimizeNode` depth loop with per-instruction best-keeping, seen-
  instruction dedup (assoc list keyed by instruction), and `Budget` gating (proposer cost
  `4 + breadth-1`; scoring cost `dsSize` per candidate). Tests prove deeper depth ≥ shallower on
  held-out and the recorded count ≤ `maxLmCalls` (8).
- [x] M3: (2026-06-09) Multi-node coordinate ascent via `foldM` over `[0..nNodes-1]` →
  `CompiledProgram`. Held-out lift (0.0 → 1.0) and `encodeCompiled`/`decodeCompiledOnto`
  round-trip tests pass.
- [x] Final: (2026-06-09) fourmolu-formatted; `cabal test shikumi-optimize` (29) and `cabal test
  all` green; committed with trailers; Outcomes filled.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **EP-19 landed, so COPRO uses the real grounded proposer — the plan-local `coproProposer`/
  `CoproProposeIn`/`variant:N` design is obsolete.** EP-19 removed V1's `proposeInstruction` and
  its `variant:N` stub convention; the delivered `proposeInstructions :: Dataset i o ->
  ProposeRequest i o -> Eff es ProposeResult` already does breadth (`numCandidates`), retains the
  current instruction, dedups, *and* takes a scored `history :: [PastInstruction]` it renders
  internally. So `optimizeNode` maps directly onto one `proposeInstructions` call per round with
  `history` = the accumulated `(instruction, score)` evaluated list. COPRO needed no proposer
  Program, no `renderHistory`, and no `proposeBreadth` of its own — a large simplification over
  the drafted M1.
- **`copro` carries `(ToJSON i, ToJSON o)`** (like `instructionSearch`/`miprov2`) because
  `proposeInstructions` renders dataset rows. The `Optimizer` type is unchanged; the constraints
  sit on the smart constructor.
- **Minibatch screening (MasterPlan Speed-audit cascade) was deferred.** The MasterPlan flagged
  "EP-21 should screen candidates on a seeded minibatch before confirming on the full dataset."
  COPRO scores on the whole training set (deterministic, and the fixtures are tiny so there is no
  speed gap to close). The screen-then-confirm optimization is a follow-up; it does not change the
  public surface or any acceptance behaviour. Recorded in the Decision Log.


## Decision Log

Record every decision made while working on the plan.

- Decision: Add `copro` as a **new module** (`Shikumi.Optimize.COPRO`) and keep the existing
  `instructionSearch` untouched, rather than superseding it in place.
  Rationale: `instructionSearch` is referenced by existing tests and the MasterPlan's acceptance
  comparisons; COPRO is its strict generalization (depth-1, no-history COPRO ≈ `instructionSearch`),
  so coexistence costs little and avoids churning a passing baseline. The MasterPlan's
  Decomposition Strategy treats COPRO as additive parity work, not a rewrite.
  Date: 2026-06-09.
- Decision: Consume EP-19's grounded proposer through a small, *plan-local* interface
  (`CoproProposeIn` → `[CoproProposeOut]` via a `proposeBreadth` function this plan owns), and
  default that function to a self-contained proposer Program when EP-19 has not yet landed.
  Rationale: EP-19 (`docs/plans/19-grounded-instruction-proposer.md`) is a hard dependency but is
  still a skeleton; the MasterPlan permits "a plan may begin against a stub, but its headline live
  behavior needs the substrate." Routing all proposer calls through one function lets EP-19 drop
  in its `proposeInstructions` without touching the depth/breadth loop. See Interfaces section.
  Date: 2026-06-09.
- Decision: Preserve the "current instruction is always a candidate" safety property by always
  prepending the node's current instruction to the breadth candidates before scoring, exactly as
  `instructionSearch` does.
  Rationale: it is the invariant that makes coordinate ascent monotone — a node can never be made
  worse than where it started — and it is what the MasterPlan brief asks us to keep.
  Date: 2026-06-09.
- Decision (revised at implementation, 2026-06-09): **The proposer seam is EP-19's delivered
  `proposeInstructions`, not a plan-local `coproProposer`/`proposeBreadth`/`renderHistory`.** EP-19
  removed V1's `proposeInstruction` and its `variant:N` convention, and its `ProposeRequest`
  already carries a scored `history :: [PastInstruction]` it renders internally. So `optimizeNode`
  calls `proposeInstructions` once per round with the accumulated history; the candidate retention,
  dedup, and history rendering are all EP-19's. `copro` gains a `(ToJSON i, ToJSON o)` constraint
  (the proposer renders dataset rows). Date: 2026-06-09.
- Decision (2026-06-09): **Defer the MasterPlan Speed-audit minibatch-screening cascade.** COPRO
  scores candidates on the full training set; screen-then-confirm on a seeded minibatch is a
  follow-up optimization that changes neither the public surface nor any acceptance behaviour, and
  the hermetic fixtures are too small for it to matter. Date: 2026-06-09.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

**Completed 2026-06-09.** COPRO ships as `Shikumi.Optimize.COPRO` (`copro`/`CoproConfig`/
`defaultCoproConfig`), re-exported from `Shikumi.Optimize` and invoked through the unchanged
`optimize`. It is coordinate ascent over `foldParams` nodes, each optimized over `depth` rounds of
`breadth` candidates drawn from EP-19's grounded proposer fed the scored attempt history; the
current instruction is always retained and an instruction-keyed evaluated list both dedups
re-proposals and tracks the best. `setNodeInstr`/`instructionAt` were lifted into
`Shikumi.Optimize.Search` so `instructionSearch` and `copro` share one copy (a pure refactor that
kept the existing suite green).

The headline purpose is met: a weak (empty-instruction) program scores **0.0 → 1.0** on a held-out
set after `copro`; deeper depth is monotone (`depth 3 >= depth 1`); the LM-call count stays within
a tight `Budget` (≤ 8); and the result round-trips through `encodeCompiled`/`decodeCompiledOnto`.
`cabal test shikumi-optimize` is 29/29 green and `cabal test all` passes (the lifted helpers did
not disturb `instructionSearch` or the other optimizers).

Gaps / deferred: minibatch screening (MasterPlan Speed-audit cascade) — full-dataset scoring is
used; a genuine multi-node fixture (single-node fixtures exercise the fold structurally, the same
posture `instructionSearch` takes). Neither affects the acceptance contract.


## Context and Orientation

This section explains everything a newcomer needs. Read it fully before editing.

### Where the code lives

The optimizer framework is the Cabal package `shikumi-optimize`, rooted at
`/Users/shinzui/Keikaku/bokuno/shikumi/shikumi-optimize`. Its public modules sit under
`shikumi-optimize/src/Shikumi/Optimize/`. The package's `.cabal` file is
`shikumi-optimize/shikumi-optimize.cabal`. Its test suite is `shikumi-optimize/test/`, driven by
`shikumi-optimize/test/Main.hs` and built with the `tasty`/`tasty-hunit` testing libraries.

Everything you need to imitate already exists in that directory; this plan adds one new source
module and one new test module, edits the `.cabal` file to list them, and edits
`Shikumi/Optimize.hs` to re-export the new module.

### The pieces you will build on (exact current signatures)

These are copied verbatim from the current source so you do not need to open other plans.

**The `Optimizer` strategy object** (from
`shikumi-optimize/src/Shikumi/Optimize/Types.hs`). An `Optimizer i o` is a newtype wrapping one
rank-2 function — given a training dataset, a metric, and a starting program, it returns a
compiled program:

```haskell
newtype Optimizer i o = Optimizer
  { runOptimizer ::
      forall es.
      (LLM :> es, Concurrent :> es, Error ShikumiError :> es, Time :> es, Prim :> es) =>
      Dataset i o ->
      Metric o ->
      Program i o ->
      Eff es (CompiledProgram i o)
  }
```

The phrase "rank-2 function" means the function works for *any* effect row `es` that provides
those five capabilities; you never pick `es` yourself — the caller (a test, or the CLI) does, by
running the result under concrete interpreters. The five capabilities are: `LLM` (issue
model calls), `Concurrent` (bounded parallelism, used by the evaluator), `Error ShikumiError`
(typed failures), `Time` (per-example latency), and `Prim` (a mutable counter the usage
accounting uses). You will never need to discharge these yourself inside the optimizer; you just
call `scoreOn` and `runProgram`, which require them.

**The search budget** (same file):

```haskell
data Budget = Budget
  { maxLmCalls :: !Int,        -- ceiling on raw LM calls (proposals + scoring)
    maxCandidates :: !Int      -- ceiling on candidate programs scored
  }
  deriving stock (Eq, Show)

defaultBudget :: Budget
defaultBudget = Budget {maxLmCalls = 200, maxCandidates = 32}
```

A *raw LM call* is one request to the model. Two things spend the budget: each proposer call is
one LM call, and *scoring* one candidate program runs it over the whole dataset, costing one LM
call per dataset example. The optimizer must thread a running count of raw LM calls and stop —
returning the best found *so far* — before either bound would be exceeded. `maxLmCalls` bounds
total calls; `maxCandidates` bounds how many candidate programs are scored.

**The scoring and freezing helpers** (from
`shikumi-optimize/src/Shikumi/Optimize/Search.hs`):

```haskell
scoreOn ::
  (LLM :> es, Concurrent :> es, Error ShikumiError :> es, Time :> es, Prim :> es) =>
  Dataset i o -> Metric o -> Program i o -> Eff es Double
-- Runs evaluatePure, returns the aggregate score in [0,1].

freezeProgram :: Program i o -> CompiledProgram i o
-- Wraps a finished program as compiled (parameters already live on the nodes).
```

`scoreOn` is the only effectful step in the search; it scores a program by running EP-8's
`evaluate` over the dataset and returning the mean per-example score (a `Double` in `[0,1]`).
`freezeProgram` is just `CompiledProgram` — Shikumi stores each node's parameters *on the node*,
so once you have rewritten the program's instructions you simply wrap it.

**The program/parameter model** (from `shikumi/src/Shikumi/Program.hs`). A program is a tree of
nodes; the *optimizable* nodes are `Predict` nodes, each carrying a `Params` record:

```haskell
data Params = Params
  { instructionOverride :: !(Maybe Text),   -- an instruction string overriding the node's default
    demos :: ![Demo]
  }

foldParams      :: Program i o -> [Params]                            -- left-to-right depth-first
mapParamsAt     :: Int -> (Params -> Params) -> Program i o -> Program i o
programParams   :: Program i o -> [Params]                            -- same order as foldParams
```

The list returned by `foldParams` is in **left-to-right depth-first order**; for `Compose f g`,
all of `f`'s `Params` come before `g`'s. Composite nodes (`Compose`, `FMap`, `Embed`) carry no
`Params`; the list length equals the number of `Predict` nodes. You address a node by its index
in that list. `mapParamsAt idx f` applies `f` to the `Params` at index `idx`. Setting a node's
instruction is therefore:

```haskell
setNodeInstr :: Int -> Text -> Program i o -> Program i o
setNodeInstr idx instr = mapParamsAt idx (\ps -> ps {instructionOverride = Just instr})

instructionAt :: Int -> Program i o -> Maybe Text
instructionAt idx prog = case drop idx (foldParams prog) of
  (ps : _) -> instructionOverride ps
  [] -> Nothing
```

These two helpers already exist *inside* `Shikumi.Optimize.Instruction` (not exported). This plan
lifts them into the shared `Shikumi.Optimize.Search` module so both `instructionSearch` and
`copro` import one copy. (Do this as a mechanical move; see M0.)

**Important limitation you must work within.** There is **no** per-node signature accessor in
Shikumi: no function `nodeSignature :: Program i o -> Int -> Signature` exists, so you cannot read
a specific node's input/output field names at runtime. The existing `instructionSearch` works
around this by passing a *static* field summary string (`"the task's input and output fields"`)
to the proposer. COPRO does the same: its proposer prompt is grounded in the *attempt history*
(instructions tried and their scores), not in per-node field names. If EP-19 later adds a
field-metadata accessor, the proposer interface this plan defines can carry richer signals
without changing the depth/breadth loop.

**Serialization** (from `shikumi-compile/src/Shikumi/Compile/Serialize.hs`):

```haskell
encodeCompiled      :: CompiledProgram i o -> ByteString
decodeCompiledOnto  :: Program i o -> ByteString -> Either String (CompiledProgram i o)
```

`encodeCompiled` emits a JSON array of `Params` in `foldParams` order. `decodeCompiledOnto`
applies a saved `[Params]` back onto a *template* program (the same program structure, supplied
in code) and returns `Left` on malformed JSON or a node-count mismatch. The round-trip test in M3
encodes a `copro` result and decodes it back onto `sentimentProg`, asserting the instructions
survive.

### The deterministic stub LM (how the offline tests work)

The test suite never touches a network. It interprets the `LLM` effect with a *stub* in
`shikumi-optimize/test/StubLM.hs` that inspects each rendered request and answers by a fixed
rule. Re-read its module header before writing tests; the salient facts you will rely on are:

- The task is binary sentiment classification of a `Sentence` (a newtype over `Text`) into a
  `Label` (`"positive"` / `"negative"`). Ground truth: a sentence containing the word `good` is
  positive, one containing `bad` is negative (`goldLabel`).
- A *sentiment* request is answered: with demos → nearest-demo classification; with no demos but
  an instruction containing the literal substring `RULE` → apply `goldLabel` (correct answers);
  with no demos and no `RULE` instruction → the constant `"neutral"`, which never matches a real
  label, so the score is `0`. This is why the underspecified program (empty instruction) scores
  `0` "before".
- A *proposer* request is recognised by its output asking for a `proposedInstruction` field
  (`isProposer`). The stub answers a proposer request by reading a `variant:N` marker out of the
  request text and returning `proposerInstruction N`: variant `0` is the "magic" `RULE`-bearing
  instruction (`ruleInstruction`), every other variant is bland (`blandInstruction`,
  `"Please answer."`). So among any breadth of candidates, exactly the variant-0 one unlocks
  correct answers — which is what COPRO must discover and keep.

The fixtures `sentimentProg`, `ruleInstruction`, `blandInstruction`, `goldLabel`, `Sentence`,
`Label`, `runStubLM`, and `runStubLMCounting` are all exported from `StubLM` and reused as-is.

**Adapting the stub for COPRO's history-carrying proposer.** COPRO's proposer input differs from
`instructionSearch`'s in that it carries a *history of attempts*, not just a single `variant:N`
marker. Two compatible options exist; this plan chooses option (a):

- **(a) Keep the `variant:N` marker convention.** COPRO's proposer input record includes a
  `variant` field that the breadth loop fills with the candidate index `0..breadth-1`, plus a
  `history` field (free text). The stub already keys on `variant:N`, so **no stub change is
  needed**: candidate index 0 yields the magic instruction, the rest are bland, on every depth
  round. The `history` text is still rendered into the request (so a test can assert it reached
  the proposer), but the stub ignores it for choosing the answer. This keeps the stub honest and
  deterministic while still exercising history threading end-to-end.
- (b) Make the stub *score-aware* (return the magic instruction once the history shows a high
  score). Rejected for M1–M3 because it couples the stub to COPRO's internal history format and
  makes the test less obviously deterministic; option (a) already proves history reaches the
  proposer and that breadth selection works.

Because of option (a), a single depth round already surfaces the magic instruction (it is always
candidate index 0 of the breadth), so the "after > before" lift is achievable at depth 1, and
deeper depths preserve it (they re-score the magic instruction, which is already best, and the
"current instruction always a candidate" rule prevents regression). The "deeper ≥ shallower"
acceptance is therefore a *monotonicity* assertion, not a "more depth finds something new"
assertion — which is the correct, robust claim for a deterministic stub.


## The COPRO algorithm (in plain language, mirrored from DSPy)

DSPy's `COPRO` (read for fidelity at `/tmp/dspy/dspy/teleprompt/copro_optimizer.py`) optimizes
the *instruction* (and an output-field *prefix*, which Shikumi does not model and we omit) of
every predictor in a program by *coordinate ascent over rounds*. Restating its mechanics in our
own words, with the two key knobs **breadth** and **depth**:

**Seeding.** For each predictor, it reads the current instruction and asks the proposer for
`breadth - 1` fresh instruction candidates, *then appends the current instruction itself* so the
candidate pool has exactly `breadth` entries and always contains the starting point. (This is the
"current instruction is always a candidate" safety property — a node can never be driven below
where it started.)

**Depth loop.** It then repeats for `depth` rounds. In each round, for each predictor, it scores
every candidate in that predictor's current pool by setting the candidate on a working copy of the
program and evaluating the whole program over the trainset; it records each `(instruction, score)`
pair in an *evaluated-candidates* map, and at the end of the predictor's turn it sets that
predictor to its **best-scoring instruction so far** before moving to the next predictor. Setting
the best before moving on is what makes it *coordinate ascent*: later predictors are optimized
against the already-improved earlier ones.

**Attempt history → next breadth.** Between rounds (every round except the last), for each
predictor it builds an *attempt history*: it sorts the evaluated candidates by score ascending
(so the best appear last) and formats them as a list of lines like `Instruction #k: …` paired
with `Resulting Score #k: …`. It feeds that history to a *second* proposer signature
(`GenerateInstructionGivenAttempts`) whose instruction explicitly says "here are instructions I've
tried and their scores, in increasing order; propose a better one," and asks for `breadth` new
candidates. Those become the next round's pool. Feeding the scored history forward is the whole
point of COPRO over a one-shot search: the proposer can learn from what scored well.

**Dedup.** Because the proposer can repeat itself, DSPy de-duplicates: it never keeps two
candidates with the *same instruction* (it compares instruction text within an equal-score batch).
The evaluated-candidates map is itself keyed by instruction, so re-proposing an already-tried
instruction does not cost a re-evaluation and does not create a duplicate entry — it only updates
the score if the new evaluation is higher.

**Result.** After all rounds, it collects every evaluated candidate across predictors, sorts by
score descending, drops duplicates, and returns the program carrying the best instructions found.

**What Shikumi mirrors and what it simplifies.** We mirror: breadth and depth as explicit knobs;
the current instruction always in the pool; per-node coordinate ascent (set best before moving
on); the attempt-history-fed proposer; instruction-keyed dedup so re-proposals are free; and the
final "carry the best instruction on every node" program. We simplify, and say so plainly:

- **No output-field "prefix."** Shikumi's `Params` has no prefix field; we optimize the
  instruction only. (DSPy's prefix is the trailing cue before the answer; Shikumi's adapter does
  not expose one.)
- **Whole-dataset scoring, not minibatches.** DSPy can evaluate on subsets; we score on the full
  trainset via `scoreOn` for determinism, bounded by `Budget`. (Minibatching is MIPROv2's concern,
  EP-20.)
- **No `track_stats`.** We do not return per-depth statistics; the `Budget` and the returned
  program are the observable contract.
- **The proposer is a typed Shikumi `Program`**, not a Python `dspy.Predict`, so it is itself
  cached, traced, and testable under the same stub — "the optimizer is written in the framework it
  optimizes."


## Plan of Work

The work is four milestones. M0 is a green-building scaffold; M1 adds breadth generation; M2 adds
the depth loop; M3 wires multi-node coordinate ascent and the acceptance + round-trip tests.
Throughout, place new code in `shikumi-optimize/src/Shikumi/Optimize/COPRO.hs` and new tests in
`shikumi-optimize/test/CoproSpec.hs`.

### Milestone M0 — scaffold the module, config, and a baseline `copro`

**Scope.** Create the module with its configuration type and a `copro` whose behavior is, for now,
identical to a single-round instruction search (depth 1, breadth from config, no history). This
gets the package compiling with the new public surface and gives M1–M3 something to grow.

**What will exist at the end.** A new file
`shikumi-optimize/src/Shikumi/Optimize/COPRO.hs` exporting:

```haskell
data CoproConfig = CoproConfig
  { breadth :: !Int,     -- candidate instructions generated per node per round (>= 2)
    depth :: !Int,       -- number of coordinate-ascent rounds (>= 1)
    budget :: !Budget    -- LM-call / candidate ceilings (reused from Optimize.Types)
  }
  deriving stock (Eq, Show)

defaultCoproConfig :: CoproConfig
defaultCoproConfig = CoproConfig {breadth = 4, depth = 3, budget = defaultBudget}

copro :: CoproConfig -> Optimizer i o
```

For M0 only, `copro`'s body may delegate to a private one-round routine; you will replace that
routine's internals in M2. The `breadth >= 2` and `depth >= 1` requirements mirror DSPy's
`breadth > 1` guard; clamp rather than error (`max 2`, `max 1`) so a CLI cannot crash the
optimizer with a bad flag.

**Shared helpers move.** In `shikumi-optimize/src/Shikumi/Optimize/Search.hs`, add and export
`setNodeInstr` and `instructionAt` (copy the two definitions verbatim from
`Shikumi/Optimize/Instruction.hs`), then change `Instruction.hs` to import them from `Search`
instead of defining them locally. This is a pure refactor: `cabal test shikumi-optimize` must stay
green after it. Add the two names to `Search`'s export list and to
`Shikumi/Optimize.hs`'s re-export (it already re-exports the whole `Search` module, so no edit is
needed there beyond confirming).

**Cabal + façade wiring.** In `shikumi-optimize/shikumi-optimize.cabal`, add
`Shikumi.Optimize.COPRO` to the library's `exposed-modules` and `CoproSpec` to the test suite's
`other-modules`. In `shikumi-optimize/src/Shikumi/Optimize.hs`, add
`import Shikumi.Optimize.COPRO` and `module Shikumi.Optimize.COPRO` to the re-export list, so a
user gets `copro` from the single `Shikumi.Optimize` import like every other optimizer.

**Commands.**

```bash
nix develop .#ghc9124 --command cabal build shikumi-optimize
```

**Acceptance.** The package compiles; `copro defaultCoproConfig` typechecks as an
`Optimizer i o`; the existing test suite still passes:

```bash
nix develop .#ghc9124 --command cabal test shikumi-optimize
```

### Milestone M1 — breadth-candidate generation via the grounded proposer fed the attempt history

**Scope.** Define COPRO's proposer interface and the `proposeBreadth` function that turns a node's
current instruction plus an attempt history into a list of `breadth - 1` candidate instructions
(to which the caller will prepend the current instruction). This is where EP-19's grounded
proposer is consumed.

**Term: attempt history.** An *attempt history* is the record of instructions already tried for a
node together with the validation score each earned. COPRO renders it as text and feeds it to the
proposer so the proposer can propose something better than what scored poorly. In this plan it is a
value of type `[Scored Text]` (reusing `Scored` from `Shikumi.Optimize.Types`, where
`Scored a = Scored { candidate :: a, score :: Double }`): each entry is an instruction string and
the aggregate score it earned. It is rendered to a single `Text` block by a `renderHistory`
function, sorted *ascending by score* (best last) to match DSPy's "arranged in increasing order"
convention.

**The proposer records.** In `COPRO.hs`:

```haskell
data CoproProposeIn = CoproProposeIn
  { currentInstruction :: Text,   -- the node's instruction at the start of the round
    fieldSummary :: Text,         -- static: "the task's input and output fields" (no per-node accessor)
    history :: Text,              -- rendered attempt history; "" on the seed round
    variant :: Int                -- which of the breadth candidates this is (0-based)
  }
  deriving stock (Generic, Show)

instance FromModel CoproProposeIn
instance ToPrompt CoproProposeIn

newtype CoproProposeOut = CoproProposeOut {proposedInstruction :: Text}
  deriving stock (Generic, Show)

instance ToSchema CoproProposeOut
instance FromModel CoproProposeOut
instance ToPrompt CoproProposeOut
instance Validatable CoproProposeOut
```

The `variant` field is what lets the deterministic stub return a *different* candidate per index
(stub keys on the `variant:N` marker; see Context). In production, EP-19's proposer would sample
`breadth - 1` candidates at temperature; the `variant` index stands in for "the i-th sample" under
the stub, which cannot sample.

**The proposer Program and the `proposeBreadth` seam.** Provide a single proposer Program and the
function that drives it `breadth - 1` times:

```haskell
coproProposer :: Program CoproProposeIn CoproProposeOut
coproProposer = predict coproProposeSig

coproProposeSig :: Signature CoproProposeIn CoproProposeOut
coproProposeSig =
  mkSignature
    "You are an instruction optimizer. You are given the current instruction for a task, \
    \a summary of its input and output fields, and a history of instructions already tried \
    \with their validation scores in increasing order. Propose a single, improved instruction \
    \in the `proposedInstruction` field. Be creative; learn from the scored history."

-- Generate up to (breadth-1) candidate instructions, threading the LM-call count and
-- stopping before maxLmCalls would be exceeded. Returns (candidates, newCallCount).
proposeBreadth ::
  (LLM :> es, Error ShikumiError :> es) =>
  CoproConfig ->
  Int ->            -- LM calls already spent
  Text ->           -- current instruction
  Text ->           -- rendered history ("" on seed round)
  Eff es ([Text], Int)
```

`proposeBreadth` calls `runProgram coproProposer (CoproProposeIn cur summary hist i)` for
`i <- [0 .. breadth-2]`, each call costing one LM call, stopping early if the next call would push
the running count over `maxLmCalls (budget cfg)`. It returns the proposed instruction strings and
the updated count. `summary` is the static `"the task's input and output fields"` string (the
per-node-accessor limitation, documented above).

**Consuming EP-19 (Integration Point #2).** When EP-19's
`docs/plans/19-grounded-instruction-proposer.md` lands its `proposeInstructions` surface,
`proposeBreadth` is the *only* function that changes: its body swaps the `coproProposer` Program
for a call to EP-19's proposer, mapping COPRO's `(currentInstruction, history)` signals onto
EP-19's richer input record (dataset summary, program summary, prior instructions with scores,
tip). The depth/breadth loop in M2 calls `proposeBreadth` and is unaffected. Until then,
`coproProposer` is the self-contained proposer, so this plan builds and tests with no EP-19
dependency in the tree — the dependency is *interface-level*, satisfied by a local default. Record
in the Decision Log when the swap happens.

**`renderHistory`.** A pure helper:

```haskell
renderHistory :: [Scored Text] -> Text
```

Sort ascending by `score`, then for the `k`-th entry (1-based) emit two lines
`"Instruction #k: " <> candidate` and `"Resulting Score #k: " <> tshow score`, joined by newlines.
Empty history renders to `""`.

**Test (`CoproSpec`, first cases).** Add `shikumi-optimize/test/CoproSpec.hs` with:

1. *Breadth surfaces the magic instruction.* Call `proposeBreadth` (via a tiny exposed test seam,
   or by running `copro` at breadth `4` / depth `1` and inspecting the chosen node instruction)
   under `runStubLM`; assert the resulting node instruction equals `ruleInstruction`. This proves
   candidate index 0 (the magic variant) is generated and selected.
2. *History reaches the proposer.* Use a counting/inspecting stub variant (or assert via the
   non-empty history rendered into a second-round request) that the `history` text is non-empty on
   rounds after the first. At M1 you may assert `renderHistory` purely (no LM): given
   `[Scored "a" 0.0, Scored "b" 1.0]` the output contains `"Instruction #1: a"` and
   `"Instruction #2: b"` in that order (ascending by score). Keep this as a pure unit test so it is
   fast and deterministic.

**Commands / acceptance.**

```bash
nix develop .#ghc9124 --command cabal test shikumi-optimize
```

`renderHistory` orders ascending; `proposeBreadth` honors the budget; the magic instruction is
among the breadth candidates.

### Milestone M2 — the depth loop: best-keeping, history threading, seen-instruction dedup, budget

**Scope.** Implement the core single-node coordinate-ascent-over-rounds routine and prove its two
defining properties on a one-node program: deeper depth never scores worse than shallower, and the
recorded LM-call count never exceeds `maxLmCalls`.

**The per-node routine.** Write a function that optimizes one node's instruction over `depth`
rounds, threading three things: the running LM-call count (for the budget), the evaluated-candidate
map (instruction → best score, for dedup and best-keeping), and the program (so each candidate is
scored in context of the current best instructions on the *other* nodes):

```haskell
-- Optimize node `idx` over `depth` rounds. Returns the program with node idx set to its
-- best-found instruction, plus the updated LM-call count.
optimizeNode ::
  (LLM :> es, Concurrent :> es, Error ShikumiError :> es, Time :> es, Prim :> es) =>
  CoproConfig ->
  Dataset i o ->
  Metric o ->
  Int ->                       -- node index
  (Program i o, Int) ->        -- (program-so-far, LM calls spent)
  Eff es (Program i o, Int)
```

Its loop, per round `r` in `1..depth`:

1. **Build the candidate pool.** On round 1, `hist = ""`; on later rounds, `hist = renderHistory`
   of the evaluated map's contents. Call `proposeBreadth cfg calls cur hist` to get `breadth - 1`
   proposals, then **prepend the current instruction** `cur` so the pool always contains the
   starting point (safety property). De-duplicate the pool against the *evaluated map's keys*
   (instructions already scored this run) and against itself, so no instruction is scored twice —
   this is the seen-instruction dedup. (Use a `Set Text` of seen instructions; preserve order, keep
   first occurrence — mirror the existing `nubOrd` style in `StubLM.hs`.)
2. **Score each new candidate**, threading the LM-call count: scoring one candidate costs `dsSize`
   LM calls (one per dataset example, where `dsSize = datasetSize train`). Before scoring a
   candidate, check `calls + dsSize <= maxLmCalls (budget cfg)` *and* that the number scored so far
   `< maxCandidates (budget cfg)`; if either bound would be exceeded, stop scoring (return the best
   found so far). For each scored candidate, insert `instruction -> max(oldScore, newScore)` into
   the evaluated map.
3. **Set the node to its best instruction so far** (the max-scoring key of the evaluated map; ties
   broken by earliest insertion, matching `selectBest`'s "earliest wins"). This updated program is
   what the next round (and the next node) sees.

After `depth` rounds, return the program (node `idx` carrying its best instruction) and the count.

**Why the evaluated map both dedups and keeps-best.** Keying by instruction text means
re-proposing an instruction already in the map costs *no* re-evaluation (we skip it in step 1's
dedup) and the map's max key is, by construction, the best instruction tried for this node — so
"set best so far" is a one-line `maximumBy`. This is exactly DSPy's `evaluated_candidates[id(p)]`
dict semantics, minus the prefix.

**Budget invariant.** The running count starts at whatever the caller passes (M3 threads it across
nodes) and is incremented by `1` per proposer call and by `dsSize` per scored candidate. Every
spend is gated by a pre-check against `maxLmCalls`, so the recorded count can never exceed it —
mirroring `instructionSearch`'s accounting exactly. `maxCandidates` independently caps how many
programs are scored across all rounds of this node.

**Tests (add to `CoproSpec`).**

1. *Deeper depth never scores worse (monotonicity).* On the one-node `sentimentProg` and the
   two-example trainset (`"good film"`/`"bad film"`), run `copro` at `depth = 1` and at `depth = 3`
   (breadth `4`, generous budget), score each result on the *trainset* (or a held-out set) with
   `scoreOn`, and assert `scoreDepth3 >= scoreDepth1`. Under the stub both reach the magic
   instruction, so both score `1.0` and the assertion is `1.0 >= 1.0`; the test fails loudly if a
   regression makes deeper depth drop the magic instruction.
2. *Budget is respected.* Reusing the `runStubLMCounting` pattern from `InstructionSpec.hs`, run
   `copro` with a deliberately tight budget (`Budget {maxLmCalls = 8, maxCandidates = 32}`) and
   assert the recorded completion count satisfies `0 < count <= 8`.

**Commands / acceptance.**

```bash
nix develop .#ghc9124 --command cabal test shikumi-optimize
```

Both new tests pass; deeper depth is monotone; the budget bound holds.

### Milestone M3 — multi-node coordinate ascent, held-out lift, and serialization round-trip

**Scope.** Wire `optimizeNode` across *all* nodes in `foldParams` order (this is the coordinate
ascent), produce the final `CompiledProgram`, and prove the headline behavior: held-out score
strictly improves, deeper depth never regresses, and the result round-trips through serialization.

**The `copro` driver.** Replace M0's placeholder body with:

```haskell
copro cfg = Optimizer $ \train metric student -> do
  let nNodes = length (foldParams student)
  (final, _calls) <-
    foldM
      (\(prog, calls) idx -> optimizeNode cfg train metric idx (prog, calls))
      (student, 0)
      [0 .. nNodes - 1]
  pure (freezeProgram final)
```

`foldM` threads the program and the LM-call count left to right across nodes, so each node is
optimized against the already-improved earlier nodes — coordinate ascent. The shared running count
means the `Budget` bounds the *whole* optimization, not each node independently (matching
`instructionSearch`). If the budget is exhausted partway, later nodes keep their starting
instructions (their candidate pools never get scored), which is safe because the starting
instruction is always in the pool.

**Held-out acceptance test.** Mirror `AcceptanceSpec.hs` but for `copro`. Use the existing
`trainset` (six `good`/`bad` examples) and a disjoint `heldout` set (different topics). Assert:

- `before = scoreOn heldout exactMatch underspecified` is `< 0.5` (the empty-instruction program
  scores `0` — it answers `"neutral"`).
- `afterCopro = scoreOn heldout exactMatch (compiledProgram cp)` where
  `cp <- optimize (copro defaultCoproConfig) trainset exactMatch underspecified` satisfies
  `afterCopro > before` and `afterCopro >= 0.75` (a floor, so a future near-no-op fails loudly).
- *Deeper ≥ shallower on held-out:* with `cfg1 = defaultCoproConfig {depth = 1}` and
  `cfg3 = defaultCoproConfig {depth = 3}`, the held-out score after `cfg3` is `>=` after `cfg1`.

**Serialization round-trip test.** After optimizing, `let bs = encodeCompiled cp` and
`decodeCompiledOnto sentimentProg bs`; assert it is `Right cp'` and that
`programParams (compiledProgram cp')` equals `programParams (compiledProgram cp)` (in particular,
the node's `instructionOverride` is `Just ruleInstruction`). This proves the optimized program
persists and reloads onto the template exactly like every other optimizer's output (Integration
Point #4: same `CompiledProgram` surface, same serialization).

**Multi-node note.** The acceptance fixtures use a single-node program (`sentimentProg`), which is
sufficient to prove coordinate ascent *runs* (the fold visits one node). To exercise the
*multi-node* path, optionally add a two-node program `sentimentProg >>> identityRelabel` is **not**
available off the shelf; instead compose two sentiment predictors is type-incompatible
(`Label ≠ Sentence`). Therefore the multi-node coordinate-ascent path is exercised structurally by
the fold (which is `length`-driven and correct for any node count) and asserted by a unit test that
builds a two-`Predict` program of matching types if one is convenient; if not, document in the
Outcomes that multi-node ascent is covered by the fold's construction and the single-node
acceptance, and that a genuine two-node fixture is deferred (the same posture `instructionSearch`
takes). Do **not** block M3 on inventing a contrived two-node fixture; the fold over
`[0 .. nNodes-1]` is correct by construction.

**Commands / acceptance.**

```bash
nix develop .#ghc9124 --command cabal test shikumi-optimize
nix develop .#ghc9124 --command cabal test all
```

Expected: the `Copro` test group passes; `cabal test all` stays green (no regression to the other
packages or the existing optimizer tests).


## Concrete Steps

All commands run from the repository root
`/Users/shinzui/Keikaku/bokuno/shikumi` unless stated otherwise. The toolchain is GHC 9.12.4,
entered via the Nix dev shell `ghc9124`. Formatting is fourmolu with 2-space indentation
(`fourmolu.yaml` at the repo root governs it).

1. **Enter the toolchain and confirm a clean baseline.**

   ```bash
   nix develop .#ghc9124 --command cabal build shikumi-optimize
   nix develop .#ghc9124 --command cabal test shikumi-optimize
   ```

   You should see the existing suite (`OptimizeSpec`, `LabeledFewShotSpec`, `BootstrapSpec`,
   `InstructionSpec`, `EnsembleSpec`, `AcceptanceSpec`) report all tests passing before you change
   anything.

2. **M0.** Move `setNodeInstr`/`instructionAt` into `Shikumi/Optimize/Search.hs` (export them);
   make `Shikumi/Optimize/Instruction.hs` import them. Create
   `shikumi-optimize/src/Shikumi/Optimize/COPRO.hs` with `CoproConfig`, `defaultCoproConfig`, and a
   placeholder `copro`. Add the module to `exposed-modules` in the `.cabal` and to the re-export in
   `Shikumi/Optimize.hs`. Rebuild and re-test (must stay green).

3. **M1.** Add `CoproProposeIn`/`CoproProposeOut`, `coproProposer`, `proposeBreadth`,
   `renderHistory`. Create `shikumi-optimize/test/CoproSpec.hs` with the breadth/history tests; add
   `CoproSpec` to the test suite's `other-modules` and to `Main.hs`'s test group. Re-test.

4. **M2.** Add `optimizeNode` with the depth loop, dedup, best-keeping, and budget gating. Add the
   monotonicity and budget tests to `CoproSpec`. Re-test.

5. **M3.** Replace `copro`'s body with the multi-node `foldM`. Add the held-out acceptance and the
   serialization round-trip tests. Run `cabal test shikumi-optimize` then `cabal test all`.

6. **Format and finish.**

   ```bash
   nix develop .#ghc9124 --command fourmolu --mode inplace \
     shikumi-optimize/src/Shikumi/Optimize/COPRO.hs \
     shikumi-optimize/src/Shikumi/Optimize/Search.hs \
     shikumi-optimize/src/Shikumi/Optimize/Instruction.hs \
     shikumi-optimize/test/CoproSpec.hs
   nix develop .#ghc9124 --command cabal test all
   ```

   Then commit (see Idempotence / commit trailers below).

Expected transcript shape for the final test run (names illustrative):

```text
shikumi-optimize
  ...
  Copro
    M1 renderHistory orders ascending:                 OK
    M1 breadth surfaces the magic instruction:         OK
    M2 deeper depth never scores worse:                OK
    M2 respects the LM-call budget:                    OK
    M3 held-out score strictly improves:               OK
    M3 deeper depth >= shallower on held-out:          OK
    M3 round-trips through encode/decode:              OK

All N tests passed
```


## Validation and Acceptance

The plan is accepted when, running entirely offline against the stub LM with no network and no API
key, `nix develop .#ghc9124 --command cabal test shikumi-optimize` shows the `Copro` group passing
and these observable behaviors hold:

- **Held-out lift.** A deliberately weak program (empty instruction) scores `< 0.5` on a held-out
  set it never trains on, and `> before` and `>= 0.75` on that same set after
  `optimize (copro defaultCoproConfig) trainset exactMatch`. This is behavior a human can read off
  the two `scoreOn` numbers, not an internal attribute.
- **Depth monotonicity.** The held-out score after `depth = 3` is never lower than after
  `depth = 1` on the fixture.
- **Budget honored.** With `Budget {maxLmCalls = 8, …}`, the counting stub records `0 < calls <= 8`
  completions, proving the search stops before the bound.
- **Serialization parity.** `decodeCompiledOnto sentimentProg (encodeCompiled cp)` returns `Right`
  and the reloaded program's `programParams` match the optimized program's — the optimized
  instruction (`Just ruleInstruction`) survives the round trip.
- **No regression.** `nix develop .#ghc9124 --command cabal test all` stays green, so adding COPRO
  did not disturb `instructionSearch` or any other package.


## Idempotence and Recovery

Every step is additive and repeatable. The M0 helper move is a pure refactor guarded by the
existing test suite: if it breaks a build, revert the `Search.hs`/`Instruction.hs` edits and the
package returns to its prior green state. Re-running any `cabal build`/`cabal test` is safe and has
no side effects beyond the build cache. If a milestone's test fails, fix the code and re-run the
same command; nothing is written outside the working tree until you commit.

Commit only when the user asks (per repository convention, commit directly to the current branch,
no feature branch). Each commit message follows Conventional Commits and carries the three
trailers the MasterPlan mandates:

```text
feat(optimize): add COPRO coordinate-ascent instruction optimizer

MasterPlan: docs/masterplans/3-shikumi-dspy-parity-optimizers-and-self-refinement.md
ExecPlan: docs/plans/21-copro-instruction-optimizer.md
Intention: intention_01ktq80q01emxtjfxzd3rw4tjs
```


## Interfaces and Dependencies

**Package:** all code lives in `shikumi-optimize`. New library module:
`Shikumi.Optimize.COPRO`. New test module: `CoproSpec`.

**Reused, unchanged (the integration contract):**

- `Shikumi.Optimize.Types` — `Optimizer (..)`, `Budget (..)`, `defaultBudget`, `Scored (..)`.
  COPRO is an `Optimizer i o` and uses `Budget` for its ceilings and `Scored Text` for history
  entries. (Integration Point #4: no parallel optimizer type.)
- `Shikumi.Optimize.Search` — `scoreOn`, `freezeProgram`, and (newly added here)
  `setNodeInstr`, `instructionAt`.
- `Shikumi.Optimize` — re-exports `copro` and `CoproConfig` so users import one module.
- `Shikumi.Program` — `Program`, `Params (..)`, `foldParams`, `mapParamsAt`, `programParams`,
  `runProgram`.
- `Shikumi.Module` — `predict` (to build the proposer Program).
- `Shikumi.Signature` — `Signature`, `mkSignature` (the proposer's signature).
- `Shikumi.Schema` — `FromModel`, `ToSchema`, `Validatable`; `Shikumi.Adapter` — `ToPrompt`
  (instances on the proposer records).
- `Shikumi.Eval` — `Dataset`, `Metric`, `datasetSize`, and (in tests) `dataset`, `example`,
  `exactMatch`.
- `Shikumi.Compile.Types` — `CompiledProgram`, `compiledProgram`; `Shikumi.Compile.Serialize` —
  `encodeCompiled`, `decodeCompiledOnto` (Integration Point #4: same serialization surface).

**Cross-plan dependency (Integration Point #2): EP-19's grounded proposer.** This plan *hard*
depends on `docs/plans/19-grounded-instruction-proposer.md` for its production proposer, but is
written so the dependency is satisfied at the *interface* level by a local default
(`coproProposer` + `proposeBreadth`). The single seam EP-19 plugs into is `proposeBreadth`; when
EP-19 lands `proposeInstructions`, only that function's body changes (mapping COPRO's
`current/history/variant` signals onto EP-19's richer input record), and a Decision Log entry
records the swap. The depth/breadth loop (`optimizeNode`, `copro`) is independent of which proposer
backs `proposeBreadth`.

**Signatures that must exist at the end of each milestone.**

- After M0: `data CoproConfig`, `defaultCoproConfig :: CoproConfig`, `copro :: CoproConfig ->
  Optimizer i o`; `setNodeInstr`/`instructionAt` exported from `Shikumi.Optimize.Search`.
- After M1: `CoproProposeIn`, `CoproProposeOut`, `coproProposer :: Program CoproProposeIn
  CoproProposeOut`, `proposeBreadth :: (LLM :> es, Error ShikumiError :> es) => CoproConfig -> Int
  -> Text -> Text -> Eff es ([Text], Int)`, `renderHistory :: [Scored Text] -> Text`.
- After M2: `optimizeNode :: (LLM :> es, Concurrent :> es, Error ShikumiError :> es, Time :> es,
  Prim :> es) => CoproConfig -> Dataset i o -> Metric o -> Int -> (Program i o, Int) -> Eff es
  (Program i o, Int)`.
- After M3: `copro` body is the multi-node `foldM`; tests `CoproSpec.tests :: TestTree` wired into
  `Main.hs`.

**Toolchain facts.** Build/test under `nix develop .#ghc9124` (GHC 9.12.4). Test commands:
`cabal test shikumi-optimize` (this package) and `cabal test all` (whole repo). Formatting:
fourmolu, 2-space indentation, governed by `fourmolu.yaml` at the repo root. All tests are hermetic
against the stub LM in `shikumi-optimize/test/StubLM.hs` — no network, no API key.
