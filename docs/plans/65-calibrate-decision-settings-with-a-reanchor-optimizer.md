---
id: 65
slug: calibrate-decision-settings-with-a-reanchor-optimizer
title: "Calibrate decision settings with a ReAnchor optimizer"
kind: exec-plan
created_at: 2026-09-26T03:43:55Z
intention: "intention_01m3dwyjr6enwaaym2xsg39gz5"
master_plan: "docs/masterplans/12-support-typesafe-jev-and-probability-backed-decision-outputs.md"
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-09-26T03:43:55Z
---

# Calibrate decision settings with a ReAnchor optimizer

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

A *decision output* is a program output that is not generated text but a judgment backed by probabilities. There are three kinds:

- a yes/no `Noul`;
- a `Choice` among declared labels;
- a `Score` on declared ordered levels.

After [64-derive-decision-values-locally-from-probability-evidence.md](64-derive-decision-values-locally-from-probability-evidence.md), each decision output's final answer is computed locally from the model's probabilities through numeric *decision settings* stored in the node's `Params`. There is one kind of setting per decision type:

- a Noul `threshold`: the answer is true when P(true) ≥ threshold;
- Score `cuts`: boundaries on the mean level index that pick the reported level;
- Choice `weights`: per-label multipliers applied before the most probable label is chosen.

The defaults (0.5; evenly spaced cuts; all weights 1.0) are rarely what a particular task wants.

This plan adds `Shikumi.Optimize.ReAnchor`, an optimizer that fits those settings to a user's metric on a training set. It never changes instructions or demos. After this change a user can write:

```haskell
tuned <- optimizeWith cfg (reAnchor defaultReAnchorConfig) trainset metric program
```

They get back a compiled program whose Params carry fitted thresholds, cuts and weights, plus a report of which settings moved and why. The whole search makes one pass of real model calls over the training set. Every candidate setting after that is scored by re-deriving answers from recorded model responses, so trying forty thresholds costs forty in-memory re-runs, not forty rounds of provider calls. A settings change is kept only when it scores strictly better and survives a held-out fold check. Otherwise the node's original settings are restored exactly, including the case where the node had no entry at all.

The design follows DSPy 3.4.0's experimental `ReAnchor`. That code lives in `mori://stanfordnlp/dspy` (third-party, not yet registered in the local Mori registry; artifact-level URIs pending) at these project-relative paths, tag `3.4.0`:

- `dspy/teleprompt/reanchor/reanchor.py`;
- `dspy/teleprompt/reanchor/calibrate.py`;
- `docs/docs/api/experimental/ReAnchor.md`.

The algorithm is restated in full below, so the implementer does not need that checkout.


## Progress

- [ ] Milestone 1: an in-memory response replay and evidence observation layer. A test shows that a second run of a stubbed decision program over the same inputs, with different decision settings, makes zero provider calls yet returns answers derived with the new settings.
- [ ] Milestone 2: the pure fitting core (gap candidates, fold selection, per-type fitters) with property and example tests that reproduce the DSPy behaviours listed under Plan of Work.
- [ ] Milestone 3: `reAnchor` runs inside the shared `SearchSession`. It fits a Noul, a Choice and a Score on stubbed System One evidence, refuses a gain confined to one fold, restores absent entries, and produces the report. Acceptance test `ReAnchorSpec` passes under `cabal test shikumi-optimize`.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Score candidate settings by re-running the program under a ReAnchor-owned in-memory response replay, not by requiring the user to configure a response cache as DSPy does.
  Rationale: The shared `SearchSession` (ADR-5) admits every `Complete` that reaches it, so ordinary cache hits below the session would still consume operation budget and candidate collectors. A replay layer installed *inside* each candidate runner answers already-seen requests before they reach admission. It keeps settings search free and makes the operation count honest: only genuinely new requests, such as a downstream node whose input changed because an upstream decision flipped, are admitted and billed.
  Date: 2026-09-26

- Decision: Each tried setting is a reserved `SearchSession` candidate, annotated with node, field, parameter and value.
  Rationale: This keeps ReAnchor inside the shared admission and diagnostic report contract of ADR-5, instead of inventing a side channel. Because replayed calls cost no operations, the binding limit is `candidateLimit`. `defaultReAnchorConfig` documents a recommended `RunLimits` with a higher candidate limit. When candidates run out, fitting stops and the best settings accepted so far are kept, which are always valid.
  Date: 2026-09-26

- Decision: Fit only outputs whose type is a Shikumi decision type (`Noul`, `Choice a`, `Score levels`). Do not promote native `Bool` or enum outputs into evidence mode as DSPy does.
  Rationale: In Shikumi the decision-ness of an output is a type-level fact fixed by EP-63. Promoting a native output would change the request, which defeats replay, and would change the output type.
  Date: 2026-09-26


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

The repository is a multi-package Haskell workspace (`cabal.project` at the root). The packages that matter here are:

- `shikumi` (core): `Program`, `Params`, execution;
- `shikumi-eval`: datasets, metrics, evaluation;
- `shikumi-trace`: per-node observations;
- `shikumi-cache`: canonical request keys;
- `shikumi-optimize`: optimizers;
- `shikumi-testing`: internal offline stub interpreters and fixtures.

Build and test with `cabal build all` and `cabal test shikumi-optimize` from the repository root, inside `nix develop`. The `justfile` wraps these as `just build` and `just test-one shikumi-optimize`.

**Programs and their nodes.** A `Program i o` (`shikumi/src/Shikumi/Program.hs`) is a tree whose leaves are `Predict` nodes. Each `Predict` holds a typed `Signature i o` and a `Params` record. Today `Params` has `instructionOverride :: Maybe Text` and `demos :: [Demo]`. EP-64 adds the per-field decision settings. Nodes are addressed by a 0-based index in traversal order, and several functions share that order:

- `foldParams` / `programParams` read every node's Params;
- `mapParamsAt n f` edits one node;
- `nodeFieldsIndexed` gives each node's input and output field names;
- `Shikumi.Trace.Node.programNodePaths` (`shikumi-trace/src/Shikumi/Trace/Node.hs:85`) gives each node's `NodePath`.

The code calls this shared order "the ordering law", and ReAnchor relies on it to connect an observed call to the node whose Params it will edit.

**How a node calls the model.** `runPredict` (`shikumi/src/Shikumi/Program.hs:332`) renders the prompt model-agnostically. It issues `complete placeholderModel ctx opts` through the `LLM` effect (`shikumi/src/Shikumi/LLM.hs`), then decodes the `Response`. The router (`Shikumi.Routing.routeLLM`) is installed *outside* the program and rewrites the placeholder model into the real one. So any interposer installed around the program run sees a deterministic, pre-routing request. After EP-64, decoding reads the node's decision settings and derives the answer from the probabilities in the response. Re-decoding the same `Response` under new settings is therefore enough to get new answers.

**Observations.** `Shikumi.Trace.Observation.runProgramObserved` (`shikumi-trace/src/Shikumi/Trace/Observation.hs:41`) runs a program and returns `(Either ShikumiError o, [NodeObservation])`. Each `NodeObservation` carries `observationPath :: NodePath` and `observationOutput :: Maybe Value`, the node's decoded output as JSON. EP-63 gives decision values a JSON encoding that includes their evidence, so an observation's output field holds the probabilities that output was derived from.

**Optimizers and the search session.** An optimizer is a `ConfiguredOptimizer i o` (`shikumi-optimize/src/Shikumi/Optimize/Types.hs`), a rank-2 function of a `SearchSession es`, a `Dataset i o`, a `Metric o` and a `Program i o` that returns a `CompiledProgram i o`. It is run by `Shikumi.Optimize.optimizeWith`. `SearchSession` (`shikumi-optimize/src/Shikumi/Optimize/Execution.hs`) owns the shared machinery. Its operations are:

- *admission*: every `Complete`/`Stream` reaching it consumes one slot of `operationLimit`, or the run stops with `BudgetExceeded`;
- *candidate reservation*: `reserveCandidate`, bounded by `candidateLimit`;
- `annotateCandidate`, which attaches metadata to a candidate;
- `evaluateCandidate session ident dataset runner classify metric policy objective`, which runs `runner` over every example and returns a `CandidateReport` whose `exampleScores :: [(Int, Double)]` are the per-example metric values (`shikumi-optimize/src/Shikumi/Optimize/Report.hs:139`);
- `evaluateCandidates`, bounded concurrency over several candidates;
- `setSelection`, which records how the winner was chosen.

`Shikumi.Optimize.Structure` (`shikumi-optimize/src/Shikumi/Optimize/Structure.hs:55-80`) is the closest existing example of a strategy using all of these. A `Metric o` (`shikumi-eval/src/Shikumi/Eval/Metric.hs:71`) is `o -> Prediction o -> Score`, where `Score` is a newtype over a `Double` clamped to [0,1]. The name clashes with the decision type `Score levels` from `Shikumi.Decision`, so import one of them qualified.

**Decision types (from EP-63 and EP-64; reconcile names when they land).** This plan assumes the following names. If the implemented names differ, update this section and the code together.

- **From `Shikumi.Decision` (EP-63).** `Noul`, `Choice a` and `Score levels`, with evidence records:
  - `NoulEvidence`, holding `pTrue :: Double`, which is P(true);
  - `ChoiceEvidence`, holding `probabilities :: Map Text Double` keyed by label, plus a `confidence`. Declaration order comes from the field's `Judgment` (`JudgeChoice` lists labels in order);
  - `ScoreEvidence`, holding `levelProbabilities :: Vector Double` over level indexes `0..n-1`, plus a `confidence`;
  - `FieldEvidence = FieldNoul … | FieldChoice … | FieldScore …`, which wraps one field's evidence;
  - `Judgment { judgmentField, judgmentInstruction, judgmentKind }` and `judgmentsInSchema :: Value -> ([Judgment], [Text])`, which give each field's kind and ordered labels or levels.

  Each has `FromJSON` from the decision value's JSON.
- **From EP-64 in `shikumi/src/Shikumi/Program.hs` or `Shikumi.Decision.Settings`.** A sum `DecisionSetting = NoulSetting { threshold :: Double } | ScoreSetting { cuts :: [Double] } | ChoiceSetting { weights :: Map Text Double }`, stored as `decisionSettings :: Map Text DecisionSetting` in `Params`, keyed by output field name. Alongside it EP-64 provides `validateSetting`, `defaultSetting :: Judgment -> DecisionSetting` and `deriveField :: Judgment -> Maybe DecisionSetting -> FieldEvidence -> Either ShikumiError Value`. An absent key means the type's default. The accessors are:
  - `decisionSettingFor :: Text -> Params -> Maybe DecisionSetting`;
  - `setDecisionSetting :: Text -> DecisionSetting -> Params -> Params`;
  - `clearDecisionSetting :: Text -> Params -> Params`;
  - this plan's own helper `effectiveDecisionSetting j ps = fromMaybe (defaultSetting j) (decisionSettingFor (judgmentField j) ps)`, which returns the stored value or the type default.

  The default is computed from the node's field metadata: the output's kind and its number of levels or labels. Neither EP-63 nor EP-64 exposes it per node. Milestone 1 of this plan therefore adds `nodeDecisionFieldsIndexed :: Program i o -> [[Judgment]]` to core, next to `nodeFieldsIndexed`, with the same traversal order. It is computed as `fst (judgmentsInSchema (deriveSchema @o))` at each `Predict` node.

**Relevant ADRs.**

- [ADR-5](../adr/0005-own-optimizer-admission-and-diagnostic-reports-in-search-sessions.md): strategies must run inside the shared `SearchSession`, use its admission and candidate lifecycle, and report through it. Candidate examples run sequentially in isolated collectors.
- [ADR-8](../adr/0008-restore-typed-structures-through-trusted-recipe-registries.md): compiled parameter serialization is independent of optimizer reports. ReAnchor's output is plain `Params` and must round-trip through `programParams`/`setProgramParams` with no report attached.
- [ADR-9](../adr/0009-centralize-offline-harness-and-diverse-fixtures.md): reusable stub interpreters and fixtures live in `shikumi-testing`. Use the System One stub responder EP-63 adds there, rather than writing a private one in `shikumi-optimize/test/StubLM.hs`.

No cross-repository ADR applies.


## Plan of Work

### The algorithm being ported

This restates DSPy's `calibrate.py` precisely. ReAnchor visits every `Predict` node in traversal order, and within a node every decision output field in signature order. For each (node, field) it does the following.

1. **Score the original.** Score the current program on the training set and keep the per-example score vector `before`. Save the node's original entry for the field, which may be absent.
2. **Materialize the defaults.** Write the field's *effective* setting (stored or default) into Params so there is a concrete value to move. Score again to get `base`. On a System One backend `base` equals `before`.
3. **Record evidence.** Run the program once over the training set at the current settings, recording for every call of *this node* the evidence of *this field*. The node can run several times per example, for instance inside `Map`, and every call counts.
4. **Fit.** Run the fitter for the field's kind (below). It returns the best setting, its score vector, an observation summary, and fold-check counters.
5. **Compare with the original.** Run the selection rule below with `before` as the start and the fitted score vector as the only tried entry. If it would not keep the fitted behaviour, restore the original entry exactly: delete the key if it was absent, otherwise write back the saved value. Record the row as skipped with the reason "fitted behaviour did not beat the original". Otherwise keep the fitted setting.

Settings fitted for earlier fields stay in place while later fields are fitted, so the search is greedy and sequential.

**Candidate generation, `gaps values lo hi geometric`.**

1. Take the sorted distinct values strictly inside `(lo, hi)`.
2. If there are more than `maxCandidates - 1` = 39 of them, thin them to 39 evenly spaced order statistics. With `step = (len - 1) / 38`, keep `inner[round(i * step)]` for `i` in `0..38`, deduplicated and sorted. Python's `round` rounds half to even, and so does Haskell's `round`, which keeps the two implementations aligned.
3. Close the list with `lo` and `hi`, and for each adjacent pair `(a, b)`:
   - compute the midpoint `(a+b)/2` and width `b-a`;
   - when `geometric` is set, use `sqrt(a*b)` and `log(b/a)` instead;
   - keep the candidate only if the midpoint lies strictly inside `(a, b)`, because adjacent floats can round the midpoint onto a boundary.
4. Replace each kept midpoint by its *tidy* form: the value rounded to the fewest decimal digits (1 to 11) that still lies strictly inside `(a, b)`, or the raw midpoint if none does.

**Selection, `select start tried`.** `tried` is a list of `(scores, tieKey, setting)`, where `scores` is the per-example vector.

1. **Pick on the whole training set.** `pick start tried rows` returns the entry maximizing `(sum of scores over rows, tieKey)`, but only if that sum is strictly greater than the sum of `start` over the same rows. Otherwise it returns nothing. On equal `(sum, tieKey)` the earliest entry wins, as Python's `max` does. If the whole-set pick returns nothing, keep the start (the fold check was not refused).
2. **Split into folds.** Split example indexes deterministically into `k = min 5 n` folds: shuffle `0..n-1` with a fixed seed, then fold `j` takes every `k`-th element starting at `j`.
3. **Score the held-out folds.** For each fold, run `pick` on the rows *outside* the fold. Add that pick's scores, or `start`'s when nothing was picked, over the rows *inside* the fold into `held`, and add `start`'s scores over the same rows into `heldStart`.
4. **Decide.** Keep the whole-set pick only when `held > heldStart` strictly. Otherwise keep the start and count one refused fold check.

**Threshold fitter (Noul).** The observed values are the recorded P(true)s. The candidates are:

- `gaps ps 0 1` (arithmetic);
- for every adjacent pair of distinct observed values `lower < upper` with no float strictly between them (`nextafter lower upper == upper`), the candidate `upper` with width `upper - lower`, because `p >= upper` still separates the pair;
- if 0.0 was observed, the candidate `0.0` with width 0, since `p >= 0` is the only threshold that makes P(true)=0 answer true.

Score each candidate by setting it and re-running. The tie key is `(width, -|t - start|, t)`, so the widest gap wins, then the candidate nearest the current threshold, then the larger value. Select with `base` as the start.

**Cuts fitter (Score with N levels, top index N-1).** For each call compute the mean level index `Σ i·pᵢ / Σ pᵢ`. For each cut `i` in turn:

1. Its range is `(below, above)`, where `below` is the previous cut (or 0) and `above` is the next cut (or N-1). This keeps the cuts strictly ordered.
2. The candidates are `gaps means below above`, skipping the current value.
3. The tie key is the width, and selection starts from the current best score vector.

An accepted cut updates both the running best cuts and the best score vector before the next cut is tried. The cuts choose `.level` only and never change the continuous value.

**Weights fitter (Choice with labels in declaration order).** Start from the effective weights, missing labels at 1.0. For each label in turn:

1. **Find the flip points.** For every recorded call, let `rival = max over other labels of weight[other] * p[other]`, using the current running weights. If `p[label] > 0` and `rival > 0`, the ratio `rival / p[label]` is a flip point: the multiplier at which this label's pick flips on that call.
2. **Bound the range.** The range is `(max 1e-3 (min flips / 4), min 1e3 (max flips * 4))`, or `(1e-3, 1e3)` with no flips.
3. **Generate candidates.** Use `gaps flips low high` with geometric midpoints and log widths, skipping a candidate equal to the current weight.
4. **Select.** The tie key is the width. An accepted candidate updates the running weights and best score vector before the next label.

The per-field report row records the node index and path, the field, the parameter kind, and the fitted value (absent when skipped). It also records `trainScoreOriginal`, the mean of `before`; `trainScoreAtStart`, the mean of `base`; `trainScore`, the mean of the retained behaviour; an observation summary (calls, distinct values, min, max, candidates tried); and fold-check counters (passed, failed). The overall report adds the mean training score before and after, and optionally validation scores before and after. Validation is never used for fitting.

DSPy stops at the first program or metric error. Mirror that by passing a `classify` that returns `FailAbort` for every error to `evaluateCandidate`. A non-finite metric value is impossible here, because `Score` is clamped.

### Milestone 1: replay and evidence observation

The scope is a new internal module `shikumi-optimize/src/Shikumi/Optimize/ReAnchor/Replay.hs` (listed in `other-modules` or exposed as internal) with two pieces.

`withReplay :: (LLM :> es, Prim :> es) => ReplayStore -> Eff es a -> Eff es a` interposes on `Complete`. It computes `Shikumi.Cache.Key.cacheKey model ctx opts` and answers from the store on a hit. On a miss it forwards the call to the enclosing handler and stores the response. `Stream` passes through untouched. `ReplayStore` is an `IORef (Map CacheKey Response)` created per ReAnchor run and discarded afterwards, so it never persists and never crosses runs. This adds `shikumi-cache ^>=0.2.0.0` to `shikumi-optimize`'s `build-depends`. `shikumi-cache` depends only on core `shikumi` and `baikai`, so no package cycle appears.

The crucial placement is that the replay is installed *inside* the runner passed to `evaluateCandidate`, for example `\inp -> withReplay store (runProgramObserved candidateProgram inp)`. Effectful's `interpose` handles an operation at the innermost installation first, so a replayed call never reaches the candidate's operation counter or the session's admission, while a miss does.

`observeEvidence` takes the `[NodeObservation]` from `runProgramObserved`, the target node's `NodePath` (from `programNodePaths` at the node's index), and a field name. It decodes that field of each matching observation's `observationOutput` into the evidence record for the field's kind, in call order.

At the end of the milestone, a test in `shikumi-optimize/test/ReAnchorSpec.hs` runs a one-node Noul program over three inputs with a counting System One stub from `shikumi-testing`. It runs once with threshold 0.5 and once with threshold 0.9, sharing one store. It asserts that the stub was called exactly three times in total, and that an input whose recorded P(true) is 0.7 answers true under 0.5 and false under 0.9.

### Milestone 2: the pure fitting core

The scope is `shikumi-optimize/src/Shikumi/Optimize/ReAnchor/Fit.hs`, containing pure functions only. They are `gaps`, `tidy`, `folds`, `pickBest`, `selectKept`, and three candidate generators (`thresholdCandidates`, `cutCandidates`, `weightCandidates`) that take evidence and the current setting and return candidate settings with widths and tie keys. These functions are deliberately separate from execution, so they can be tested without a program.

Tests reproduce these behaviours:

- `gaps [0.98, 1.0] 0 1` yields exactly the candidates 0.5 and 0.99, matching DSPy's documented example. The value 1.0 is not strictly inside `(0, 1)`, so the points are `[0, 0.98, 1]`. The raw midpoints 0.49 and 0.99 tidy to 0.5 and 0.99.
- Fifty distinct inputs are thinned to at most 40 gaps.
- Adjacent floats yield the upper value as a candidate.
- A 0.0 observation yields threshold 0.
- Cut candidates never leave `(below, above)`.
- `selectKept` refuses a gain concentrated in one example of five when the held-out total does not beat the start, and accepts a gain spread across folds.

Use `tasty-quickcheck` only if it is already a test dependency. Otherwise use explicit examples.

### Milestone 3: the optimizer in the search session

The scope is the public module `shikumi-optimize/src/Shikumi/Optimize/ReAnchor.hs`, exposed and re-exported from `Shikumi.Optimize`, containing:

```haskell
data ReAnchorConfig = ReAnchorConfig
  { validation :: !(Maybe (Dataset i o)) -- scored before/after for the report only; never fitted
  , maxCandidatesPerStep :: !Int          -- default 40, as in DSPy
  , foldCount :: !Int                     -- default 5
  }

defaultReAnchorConfig :: ReAnchorConfig
reAnchor :: ReAnchorConfig -> ConfiguredOptimizer i o
reAnchorWith :: ... => ReAnchorConfig -> SearchSession es -> Dataset i o -> Metric o -> Program i o
             -> Eff es (CompiledProgram i o, ReAnchorReport)
data ReAnchorReport = ReAnchorReport { trainScoreBefore, trainScore :: Double
                                     , valScoreBefore, valScore :: Maybe Double
                                     , fitted :: [FieldCalibration] }
```

The type variables in `ReAnchorConfig` make it `ReAnchorConfig i o`; adjust as needed. `ReAnchorReport` and `FieldCalibration` derive `ToJSON`.

`reAnchorWith`:

1. Rejects an empty training set, and a program with no decision outputs, with `ValidationFailure`.
2. Creates one `ReplayStore`.
3. Scores the unmodified program as the baseline candidate.
4. Runs the per-(node, field) procedure above. Every scoring of a tried setting reserves a candidate and annotates it with `node`, `path`, `field`, `parameter` and `value`, then calls `evaluateCandidate` with the replaying runner and reads `exampleScores`.
5. When `reserveCandidate` returns `Nothing`, stops fitting and keeps the accepted settings. Accepted settings are always valid, because every change passed selection.
6. Calls `setSelection session "ReAnchor: strict improvement with held-out fold check" …`.

`defaultReAnchorConfig`'s Haddock recommends `RunLimits { candidateLimit = 2000 }`, because replayed candidates consume no operations.

The acceptance tests in `ReAnchorSpec` use `shikumi-testing` fixtures and a scripted System One stub from EP-63 that returns fixed distributions per input:

- **Noul.** Ten examples whose correct answers separate at P(true) ≈ 0.72. The default 0.5 threshold scores 0.7. After `reAnchor` the stored threshold lies in the observed gap around 0.72 and the training score is 1.0. The stub call count equals the recording and scoring calls for ten inputs, with no additional calls per candidate.
- **Fold check.** A dataset where the only improving threshold fixes one example out of five folds' worth. The field row is skipped and the node's Params has no entry for the field, exactly as before.
- **Choice.** A three-label choice where one label is systematically over-picked. The fitted weight for that label is below 1 and the score improves.
- **Score.** A three-level score whose natural boundary sits at mean index 1.6. The fitted second cut lies between the observed means around 1.6, and the first cut stays below it.
- **Composed program.** Two nodes, where the first node's decision is part of the second node's input. Flipping the first node's threshold creates new requests for the second node. The test asserts they were admitted (the report's `admittedOperations` grew) and that a repeated identical candidate made no further calls.
- **Serialization.** The tuned program's `programParams` round-trips through JSON and `setProgramParams`, and running it reproduces the fitted answers.


## Concrete Steps

Run all commands from the repository root inside `nix develop`.

```bash
cabal build shikumi-optimize
cabal test shikumi-optimize --test-options='-p ReAnchor'
```

Expected at the end of milestone 3:

```text
ReAnchor
  replay: second settings pass makes no provider calls:    OK
  fit: gaps tidy midpoints (0.98, 1.0):                    OK
  fit: fold check refuses a one-fold gain:                 OK
  noul threshold fitted to the observed gap:               OK
  refused fit restores an absent settings entry:           OK
  choice weight lowers an over-picked label:               OK
  score cuts stay ordered:                                 OK
  composed program admits only new downstream requests:    OK
  fitted params round-trip through serialization:          OK
```

Then run the full suite with `just test`, and `just check-adr` if an ADR was added.


## Validation and Acceptance

The plan is accepted when all of the following hold:

- `cabal test shikumi-optimize` passes, including every case in `ReAnchorSpec` listed above.
- The Noul acceptance case shows the model was called once per training input for recording, and never again per candidate. Assert this on the stub's counter, not on timing.
- A program with no decision outputs fails fast with a `ValidationFailure` naming the reason.
- The returned `CompiledProgram`'s Params differ from the input's only in `decisionSettings`.


## Idempotence and Recovery

Everything is additive: two new internal modules, one public module, one test spec, one new dependency edge (`shikumi-optimize` → `shikumi-cache`). Rerunning the tests is safe. ReAnchor itself never mutates the caller's program, because `Program` is an immutable value. The replay store is per run and in memory. If the new dependency edge causes a solver problem, the fallback is to copy the key into `Replay.hs` using `Shikumi.Cache.Key.requestToCanonicalValue`'s approach, and to record that in the Decision Log.


## Interfaces and Dependencies

This plan defines:

- `Shikumi.Optimize.ReAnchor`: `reAnchor`, `reAnchorWith`, `ReAnchorConfig`, `defaultReAnchorConfig`, `ReAnchorReport`, `FieldCalibration`;
- internal `Shikumi.Optimize.ReAnchor.Replay`: `ReplayStore`, `newReplayStore`, `withReplay`, `observeEvidence`;
- internal `Shikumi.Optimize.ReAnchor.Fit`: the pure selection core.

It consumes:

- EP-63's `Shikumi.Decision` evidence records and their JSON, from [63-declare-decision-outputs-and-route-them-to-system-one-models.md](63-declare-decision-outputs-and-route-them-to-system-one-models.md);
- EP-64's `DecisionSetting`, `decisionSettings`, the setting accessors and per-node decision field metadata, from [64-derive-decision-values-locally-from-probability-evidence.md](64-derive-decision-values-locally-from-probability-evidence.md);
- `Shikumi.Trace.Observation.runProgramObserved` and `Shikumi.Trace.Node.programNodePaths`;
- `Shikumi.Cache.Key.cacheKey`;
- the `SearchSession` API in `Shikumi.Optimize.Execution`.

It must not change any of them. If a needed accessor is missing, add it in the owning package in a separate commit, and note it in Surprises & Discoveries.

It benefits from, but does not require, [66-request-probability-evidence-from-generative-models.md](66-request-probability-evidence-from-generative-models.md). Once EP-66 lands, add one `ReAnchorSpec` case that fits a threshold over a generative stub's evidence, proving calibration is backend-agnostic.
