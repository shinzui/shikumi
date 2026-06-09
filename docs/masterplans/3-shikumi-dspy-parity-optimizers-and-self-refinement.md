---
id: 3
slug: shikumi-dspy-parity-optimizers-and-self-refinement
title: "Shikumi DSPy-Parity Optimizers and Self-Refinement"
kind: master-plan
created_at: 2026-06-09T22:35:20Z
intention: "intention_01ktq80q01emxtjfxzd3rw4tjs"
---

# Shikumi DSPy-Parity Optimizers and Self-Refinement

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

Shikumi's V1 (`docs/masterplans/1-shikumi-typed-lm-programming-framework.md`) delivered the
*2023-era* DSPy core: typed `Program i o`, structured I/O, `predict`/`chainOfThought`/`react`,
the classic combinators, evaluation, and the original teleprompters — `labeledFewShot`,
`bootstrapFewShot`, a greedy `instructionSearch`, and `ensembleSearch`. The gap between
Shikumi and DSPy 3.3 (surveyed from a fresh clone) is concentrated almost entirely in what
DSPy added in 2024–2026: its flagship optimizers **MIPROv2** and **GEPA**, the
coordinate-ascent **COPRO**, retrieval-based few-shot (**KNNFewShot**, BootstrapRS), and the
inference-time self-refinement modules **Refine**, **BestOfN**, and **MultiChainComparison**.
This MasterPlan closes that gap. It is the headline of the follow-up: after it, Shikumi's
optimization stack is at parity with modern DSPy, expressed through Shikumi's typed,
effect-honest, program-as-data substrate rather than Python dynamism.

Concretely, after this initiative a Shikumi user can: (1) wrap any `Program` in a
reward-driven self-correcting module — `bestOfN` (sample N rollouts at temperature, keep the
highest-reward one), `refine` (run, inspect the reward, feed a textual critique back and
retry), and `multiChainComparison` (run M reasoning chains and synthesize a consensus answer)
— and have each remain a first-class, composable, serializable `Program`; (2) optimize a
program with **MIPROv2**, which jointly searches instructions *and* few-shot demonstrations
using a *grounded* proposer (one that reads a summary of the dataset, a pseudo-code summary
of the program, each module's role, bootstrapped demos, prior instructions and their scores,
and a randomly chosen "tip"), evaluated on minibatches with a Bayesian/TPE-style search over
the candidate combinations; (3) optimize with **COPRO** (iterative coordinate ascent over
instructions with breadth/depth control); (4) optimize with **GEPA**, which captures
per-node execution feedback, reflects on what went wrong, evolves instruction candidates, and
keeps a Pareto frontier of non-dominated programs; and (5) use **KNNFewShot** to pick demos
by embedding similarity to the input at run time. Every optimizer returns V1's
`CompiledProgram i o` and is invoked through V1's stable `optimize` entry point, so the CLI's
`optimize` subcommand and serialization (`encodeCompiled`/`decodeCompiledOnto`) work
unchanged.

**In scope:** the three self-refinement modules; a grounded instruction proposer (replacing
the V1 static proposer); MIPROv2; COPRO; GEPA; KNNFewShot and BootstrapFewShotWithRandomSearch.

**Out of scope:** weight-level optimization (`BootstrapFinetune`, `BetterTogether`) — V1's
out-of-scope stance holds: Shikumi optimizes prompts, demonstrations, and structure, not model
weights. Also out of scope: the substrate these plans *consume* — ambient model routing,
embeddings, and node-correlated tracing — which are delivered by
`docs/masterplans/2-shikumi-substrate-routing-completion.md` and are hard, cross-MasterPlan
prerequisites of several plans here.


## Decomposition Strategy

The initiative splits into **six child ExecPlans across two phases**. Six is within the
two-to-seven guideline; the phases group them so an implementer sees the ordering at a glance.

- **Phase A — building blocks.** EP-18 (self-refinement modules) and EP-19 (grounded
  instruction proposer). These add the reusable mechanisms the optimizers compose: reward
  functions and self-correction (EP-18), and the proposer that turns dataset/program context
  into instruction candidates (EP-19). Both are independently demonstrable.
- **Phase B — the optimizers.** EP-20 (MIPROv2), EP-21 (COPRO), EP-22 (GEPA), and EP-23
  (KNNFewShot + BootstrapRS). Each is a search procedure layered on evaluation and the Phase A
  building blocks.

The decomposition follows the V1 principle that the proposer (an instruction-generation
*mechanism*) is separated from the optimizers (the *search procedures* that call it), because
MIPROv2 and COPRO both depend on the same grounded proposer and must agree on its interface.
GEPA is its own plan because its algorithm is fundamentally different — reflective evolution
driven by per-node execution feedback and a Pareto frontier — and it depends on a different
substrate (node-correlated traces, MasterPlan 2 EP-16) than the proposer-based optimizers.
KNNFewShot/BootstrapRS are grouped because both are lightweight demo-selection strategies that
depend on the same embeddings substrate (MasterPlan 2 EP-15) and reuse V1's existing bootstrap
machinery.

**Alternatives considered.** (a) *One "modern optimizers" plan* — rejected: MIPROv2, COPRO,
and GEPA have different algorithms, different substrate dependencies, and different acceptance
criteria; merging would produce an unverifiable mega-plan. (b) *Folding the self-refinement
modules into MasterPlan 4's I/O work* — rejected: `Refine`/`BestOfN`/`MultiChainComparison`
are reward-and-optimization concerns (they share the `Metric`/reward vocabulary with the
optimizers) and several read most naturally as new `Program` constructors, so they belong with
the optimizer initiative. (c) *Putting the grounded proposer inside the MIPROv2 plan* —
rejected: COPRO consumes the same proposer; defining it once as its own plan prevents drift.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 18 | Reward-driven self-refinement modules | docs/plans/18-reward-driven-self-refinement-modules.md | EP-14 (MP-2) | None | Not Started |
| 19 | Grounded instruction proposer | docs/plans/19-grounded-instruction-proposer.md | None | EP-16 (MP-2) | Not Started |
| 20 | MIPROv2 optimizer | docs/plans/20-miprov2-optimizer.md | EP-19 | EP-16 (MP-2) | Not Started |
| 21 | COPRO instruction optimizer | docs/plans/21-copro-instruction-optimizer.md | EP-19 | None | Not Started |
| 22 | GEPA reflective optimizer | docs/plans/22-gepa-reflective-optimizer.md | EP-16 (MP-2), EP-19 | EP-18 | Not Started |
| 23 | KNN few-shot and bootstrap random search | docs/plans/23-knn-few-shot-and-bootstrap-random-search.md | EP-15 (MP-2) | None | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference rows by their # prefix. `EP-14`, `EP-15`, `EP-16` live in
MasterPlan 2 (`docs/masterplans/2-shikumi-substrate-routing-completion.md`) and are
cross-MasterPlan dependencies — they must be Complete there before the dependent plan here
can finish (a plan may begin against a stub, but its headline live behavior needs the
substrate).


## Dependency Graph

**Cross-MasterPlan prerequisites.** This whole initiative sits on MasterPlan 2's substrate.
EP-18 hard-depends on MP-2 EP-14 (ambient routing) because `bestOfN`/`multiChainComparison`
must vary temperature per sample, which is inert until routing is live. EP-23 hard-depends on
MP-2 EP-15 (embeddings) because KNN selects demos by embedding similarity. EP-19 and EP-22
depend on MP-2 EP-16 (node-correlated tracing): EP-19 soft (its per-node field summaries and
demo signals read best with node correlation but can fall back to program-level summaries),
EP-22 hard (GEPA's per-predictor reflection is impossible without per-node feedback).

**Within this MasterPlan.** EP-19 (grounded proposer) is the internal root: EP-20 (MIPROv2)
and EP-21 (COPRO) both hard-depend on it because both generate instruction candidates through
it. EP-22 (GEPA) hard-depends on EP-19 too (it reuses the proposer's program/dataset
summaries as reflection context) and soft-depends on EP-18 (GEPA's reward/feedback vocabulary
overlaps the self-refinement modules' reward functions). EP-23 is independent of the others
inside this MasterPlan.

**Parallelism.** Once MP-2's substrate is in place: EP-18 and EP-19 (Phase A) can run in
parallel. After EP-19 lands, EP-20, EP-21, and EP-22 can run in parallel; EP-23 can run any
time after MP-2 EP-15.


## Integration Points

These are the shared artifacts inside this MasterPlan, plus the substrate contracts it
inherits from MasterPlan 2. Each child plan embeds the exact current signatures it builds on
(from the integration dossier) so it stands alone.

1. **The reward function vocabulary.** *Owner: EP-18.* A reward type — most likely reusing
   V1's `Metric o = o -> Prediction o -> Score` shape or a dedicated `Reward o = o -> Score`
   — and the smart constructors `refine`, `bestOfN`, `multiChainComparison`. *Consumers:*
   EP-22 (GEPA) shares the reward/critique vocabulary for its reflective feedback. EP-18 owns
   it; EP-22 must not redefine a parallel reward type. If EP-18 adds new `Program` GADT
   constructors, it must follow V1's EP-4/EP-5 rule: every new constructor is a compile error
   until `paramsTraversal`, `programShape`, and `setProgramParams` pattern-match it (prefer
   deriving from existing constructors or an `Embed` node where possible, as V1's `react` did).

2. **The grounded proposer interface.** *Owner: EP-19.* A `proposeInstructions` surface that
   takes the proposal *signals* — a dataset summary, a program/pseudo-code summary, a per-node
   role/field summary, bootstrapped demos, prior instructions with their scores, and a tip —
   and returns ranked instruction candidates for a target node. The signal-gathering
   sub-programs (dataset summarizer, program describer, module describer) are themselves
   typed Shikumi `Program`s (the V1 pattern: "the optimizer is written in the framework it
   optimizes"). *Consumers:* EP-20 (MIPROv2) and EP-21 (COPRO) both call it; they must agree
   on its input record and output type. EP-19 replaces V1's static `ProposeIn`/`ProposeOut`
   in `Shikumi.Optimize.Instruction` (whose `fieldSummary` is hardcoded because V1 exposed no
   per-node signature accessor).

3. **Per-node signature/field metadata.** *Owner: EP-19 (defines the need), realized with
   help from MP-2 EP-16.* The grounded proposer needs each node's actual input/output field
   names. V1 exposes **no** `nodeSignature :: Program i o -> Int -> Signature` accessor. EP-19
   must introduce a way to recover per-node field metadata — either a `[FieldMeta]`-per-node
   accessor derived alongside `programShape`, or carried via MP-2 EP-16's `NodePath` machinery.
   Whichever it chooses, it documents it here so EP-20/EP-21/EP-22 consume the same accessor.

4. **`Optimizer i o`, `optimize`, and `CompiledProgram i o` (inherited from V1).** *Owner:
   V1 EP-10/EP-9; consumed unchanged.* Every optimizer in this MasterPlan is an `Optimizer i
   o` (the rank-2 record `runOptimizer :: forall es. (LLM, Concurrent, Error ShikumiError,
   Time, Prim) :> es => Dataset i o -> Metric o -> Program i o -> Eff es (CompiledProgram i
   o)`) and is invoked via `optimize`. Output is V1's `CompiledProgram i o`, persisted with
   `encodeCompiled`/`decodeCompiledOnto`. New optimizers **must not** introduce a parallel
   optimizer type or serialization surface; the CLI (`shikumi optimize`) and golden tests
   depend on these being stable.

5. **Node-correlated traces and feedback (inherited from MP-2 EP-16).** *Owner: MP-2 EP-16;
   consumed by EP-20 (per-node demo recovery) and EP-22 (per-node reflection).* The `NodePath`
   identity and per-node feedback channel from
   `docs/masterplans/2-shikumi-substrate-routing-completion.md` integration points #3/#4.
   MIPROv2's bootstrap stage can recover per-node demos through `runProgramTraced`; GEPA reads
   node feedback to mutate that node's instruction.

6. **The embeddings effect (inherited from MP-2 EP-15).** *Owner: MP-2 EP-15; consumed by
   EP-23.* The `Embedding` effect interpreter that makes `EmbedText` real. KNNFewShot embeds
   training inputs and the query input and picks nearest neighbors as demos.


## Progress

- [ ] EP-18: `refine`, `bestOfN`, `multiChainComparison` as first-class composable Programs
- [ ] EP-18: Reward-driven retry demonstrably improves a deliberately-weak program's score
- [ ] EP-19: Grounded proposer — dataset/program/module summarizers as typed Programs
- [ ] EP-19: Per-node field-metadata accessor; proposer consumes real field names + tips + history
- [ ] EP-20: MIPROv2 joint instruction×demo search with minibatch evaluation
- [ ] EP-20: Held-out score lift over the V1 instruction search baseline on a fixture task
- [ ] EP-21: COPRO coordinate-ascent instruction optimizer with breadth/depth control
- [ ] EP-22: GEPA reflective evolution with per-node feedback and a Pareto frontier
- [ ] EP-23: KNNFewShot (embedding-similarity demos) + BootstrapFewShotWithRandomSearch


## Surprises & Discoveries

These were surfaced while authoring the child plans (2026-06-09), before implementation;
they refine the integration contracts above.

- **The `Embed` node's effect row is load-bearing across this MasterPlan.** V1's `Embed ::
  (forall es. (LLM :> es, Error ShikumiError :> es) => i -> Eff es o) -> Program i o` fixes the
  body's row to exactly `(LLM, Error ShikumiError)`. EP-18 (self-refinement), EP-23 (KNN), and
  MasterPlan 4's EP-27 all want a node that needs *more* than that — but widening the row would
  break integration point #4. The consistent resolution: **inject the extra capability as a
  plain value/closure captured in the `Embed` body, not as an effect.** EP-23 passes the KNN
  node a pure `Text -> Vector Double` embedding closure (the shape of EP-15's `runEmbedding`
  argument) rather than the `Embedding` effect; EP-18 builds all three modules as `Embed` nodes
  with no new constructor; EP-22 (GEPA) keeps its `Trace`/`CurrentNode`/`Feedback` effects
  *internal* to the optimizer (discharged against ambient `Prim`/`Time`/`LLM`) so the
  `Optimizer i o` row is unchanged. This is the single most important cross-plan pattern here.
- **The reward vocabulary (integration point #1) must live in the base `shikumi` package, not
  `shikumi-eval`.** EP-18 found that `Program` lives in `shikumi` while `Score`/`Metric`/
  `Prediction` live in `shikumi-eval`, which *depends on* `shikumi` (one-way). Reusing `Metric`
  for the reward would invert that dependency. So EP-18 defines `newtype Reward o = Reward { …
  :: o -> Double }` in base `shikumi`, with a `rewardFromMetric` adapter in `shikumi-eval` for
  callers. EP-22 (GEPA) reuses this reward (as `Score + critique Text`), not a parallel type.
- **EP-19's grounded-proposer dependency on EP-16 is genuinely soft.** EP-19 consumes EP-16's
  `nodeFieldsIndexed` when present but ships an in-package `programShape`/`sigLabel` fallback
  (output field names only, degrading gracefully) so it builds and tests before EP-16 lands.
  The proposer keeps V1's safety property: the current instruction is always retained as a
  candidate so a node never degrades.
- **MIPROv2/COPRO/GEPA each specify a concrete Haskell search surrogate** since there is no
  Optuna/TPE: EP-20 uses greedy coordinate descent with minibatch pruning over the joint
  per-node (instruction × demoset) grid (minibatch-propose, full-eval-confirm); EP-21 is
  breadth/depth coordinate ascent with attempt-history and seen-instruction dedup; EP-22 is a
  Pareto-frontier evolutionary loop with seeded-LCG parent sampling (no IO randomness). All
  three define budget in terms of V1's `Budget {maxLmCalls, maxCandidates}` and prove a
  held-out lift under a deterministic stub LM (mirroring V1 EP-10's 0.0→1.0 style).


## Decision Log

- Decision: Decompose the optimizer parity work into six plans across two phases (building
  blocks: self-refinement + grounded proposer; then the four optimizers), rather than one
  "modern optimizers" plan.
  Rationale: MIPROv2/COPRO/GEPA have distinct algorithms and substrate dependencies; the
  grounded proposer is shared by MIPROv2 and COPRO and must be defined once; GEPA depends on a
  different substrate (node-correlated traces) than the proposer-based optimizers.
  Date: 2026-06-09.
- Decision: Keep weight-level optimization (BootstrapFinetune, BetterTogether) out of scope,
  preserving V1's stance.
  Rationale: Shikumi optimizes prompts, demonstrations, and program structure, not model
  weights; baikai owns no fine-tuning transport.
  Date: 2026-06-09.
- Decision: Make this MasterPlan sit on MasterPlan 2's substrate via cross-MasterPlan hard
  dependencies (EP-18→EP-14, EP-23→EP-15, EP-22→EP-16) rather than re-deriving routing,
  embeddings, or node-correlation here.
  Rationale: those substrates are shared with MasterPlan 4 and belong defined once in the
  foundation MasterPlan; duplicating them would risk divergent contracts.
  Date: 2026-06-09.
- Decision: All new optimizers reuse V1's `Optimizer`/`optimize`/`CompiledProgram` and
  serialization; no parallel optimizer or persistence surface.
  Rationale: the CLI `optimize` subcommand and golden tests depend on these being stable;
  V1 integration points #6 and #10 are authoritative.
  Date: 2026-06-09.
- Decision: Associate this MasterPlan with intention `intention_01ktq80q01emxtjfxzd3rw4tjs`;
  every commit carries `MasterPlan:`, `ExecPlan:`, and `Intention:` trailers.
  Date: 2026-06-09.


## Outcomes & Retrospective

(To be filled during and after implementation.)
