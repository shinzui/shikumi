---
id: 64
slug: derive-decision-values-locally-from-probability-evidence
title: "Derive decision values locally from probability evidence"
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

# Derive decision values locally from probability evidence

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.

This plan belongs to the MasterPlan `docs/masterplans/12-support-typesafe-jev-and-probability-backed-decision-outputs.md` and hard-depends on `docs/plans/63-declare-decision-outputs-and-route-them-to-system-one-models.md`.


## Purpose / Big Picture

After this change, a user who runs a decision-producing Shikumi program can control *how* each decision is drawn from the probabilities, without asking the model again. Three settings are available:

- **Noul threshold.** Set a yes/no field's threshold, for example "only say urgent when P(true) ≥ 0.7".
- **Score cuts.** Move the cut points that turn a severity score into a level.
- **Choice weights.** Weight or disable the labels of a classification.

These settings live in the program's `Params` next to its instruction and demos. They are serialized with a compiled program and restored with it. Because they are applied locally to the evidence, they never change the provider request. Re-running with new settings is therefore served entirely from the response cache or from a recorded trace.

You can see it working in three ways:

- **Cache hit.** The test suite runs a program once against a counting stub, changes a threshold, and runs it again through `Shikumi.Cache.cachedLLM`. The second run returns a different `value` while the stub's call count stays at 1.
- **Replay.** Replaying a recorded trace with new settings yields the new values under `Shikumi.Trace.Replay.runLLMReplay`, which structurally cannot reach a provider.
- **Old JSON.** A `Params` JSON document written before this change still decodes.


## Progress

- [ ] Milestone 1: The settings types, their validation, and the pure derivation functions exist in `Shikumi.Decision`. Property and unit tests reproduce the worked examples in this plan.
- [ ] Milestone 2: `Params` carries per-field decision settings with a backward-compatible JSON codec. `runPredict` applies them, and an invalid setting fails with `ValidationFailure` before any LLM call.
- [ ] Milestone 3: Tests in `shikumi-cache` and `shikumi-trace` prove that a settings change is a cache hit, that replay with new settings yields new values with zero provider calls, and that a compiled program round-trips its settings.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Settings are keyed by output field name (the Haskell record selector, which is also the JSON property name the schema uses). They live in a new `Params` field, `decisionSettings`, not in the signature.
  Rationale: `Params` is the uniform, serializable overlay that optimizers and `shikumi-compile` already traverse (`paramsTraversal`, `programParams`). The MasterPlan assigns this field to this plan alone, so EP-65's calibrator can read and write it through the accessors defined here.
  Date: 2026-09-26

- Decision: Derivation rules are copied exactly from DSPy 3.4.0's `DecisionTypes.md`, including tie-breaking and the Noul confidence formula.
  Rationale: The MasterPlan's reference behaviour is DSPy 3.4.0. Matching it exactly lets calibration results and user expectations transfer between the two libraries.
  Date: 2026-09-26


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Shikumi is a Haskell library for typed language-model programs. A `Program i o` (GADT in `shikumi/src/Shikumi/Program.hs`, around line 200) is a tree of nodes. Its leaves are `Predict sig ps` and `PredictCaptured codec sig ps`, where `sig :: Signature i o` describes the task and `ps :: Params` is the node's tunable overlay.

`Params` (`shikumi/src/Shikumi/Program.hs`, around line 131) currently has two fields: `instructionOverride :: Maybe Text` and `demos :: [Demo]`. Its `FromJSON` instance is derived through `Generic`, and `emptyParams = Params Nothing []` is the default.

`runPredict` (same file, around line 332) interprets a leaf in four steps:

1. `effectiveSignature sig ps` (around line 473) applies the instruction override and decodes the demos.
2. The signature is rendered to a baikai `Context` and `Options`.
3. It calls `complete placeholderModel ctx opts` (the `LLM` effect).
4. It decodes the reply with `parseResponse`.

Optimizers change `Params` through the traversal helpers `paramsTraversal`, `foldParams`, `mapParams` and `mapParamsAt`, which are exported from `Shikumi.Program`.

A compiled program is serialized by `shikumi-compile/src/Shikumi/Compile/Serialize.hs`. It writes `CompiledState { shape, params :: [Params] }` from `programShape` and `programParams`, and reads it back with `decodeCompiledOnto`, which re-applies the vector through `setProgramParams`. `Params`' JSON encoding is therefore a persisted format. [ADR-8](../adr/0008-restore-typed-structures-through-trusted-recipe-registries.md) requires compiled parameter serialization to stay independent of optimizer reports, and it requires older documents to keep decoding.

The response cache (`shikumi-cache/src/Shikumi/Cache.hs`, `cachedLLM` / `cachedLLMWith`) sits on the `LLM` effect. It keys each request with `Shikumi.Cache.Key.cacheKey`, a BLAKE3 hash over the canonical JSON of model, `Context` and `Options`, and it stores the whole baikai `Response`. Trace replay (`shikumi-trace/src/Shikumi/Trace/Replay.hs`, `runLLMReplay :: Map CacheKey Value -> Eff (LLM : es) a -> Eff es a`) answers each request from a recorded trace by the same key and fails with `ReplayDivergence` on any unknown key. Both mechanisms return a *response*, and decoding runs afterwards. Anything applied after decoding therefore changes the result without changing the key. This plan relies on that fact.

[ADR-12](../adr/0012-apply-request-defaults-before-cache-and-observation.md) states that request defaults are not serialized in `Program` or `Params`, and that the request order is routing, defaults, cache/trace, then transport. Decision settings are the opposite kind of value: they are serialized in `Params` and never enter the request at all. Keep them out of `Options.metadata`, or they would change the cache key.

[ADR-9](../adr/0009-centralize-offline-harness-and-diverse-fixtures.md) puts reusable stub interpreters and fixtures in the internal `shikumi-testing` package (`shikumi-testing/src/Shikumi/Testing/StubLLM.hs`, `Fixtures.hs`, `Response.hs`). Extend the decision fixtures there rather than copying them into each suite.

Some terms used in this plan:

- **Decision output.** A record field whose type is one of the decision types from EP-63.
- **Evidence.** The probabilities a backend returned for that field.
- **Deriving.** Computing the user-visible answer (`value`, `level`, chosen label) from evidence and settings.
- **Settings.** The per-field numeric knobs described below.

**Interfaces assumed from EP-63.** EP-63 is not yet implemented. This plan assumes the names below. When EP-63 lands, reconcile these names with the landed code and record any renames in this plan's Decision Log. Do not change EP-63's evidence JSON shapes; the MasterPlan forbids it.

- **Module.** `Shikumi.Decision` in the core `shikumi` package.
- **Noul.** `Noul` (a synonym for `NoulWith "" ""`) holds a derived `value :: Bool`, `probability :: Double` (P(true)) and a derived `confidence :: Double`. Its evidence record is `NoulEvidence { pTrue :: Double }`.
- **Choice.** `Choice a` is for an enumeration `a` of nullary constructors, in declaration order. It holds a derived `value :: a`, `probabilities` over the labels in declaration order, and a backend `confidence :: Maybe Double`. Its evidence record is `ChoiceEvidence { probabilities :: Map Text Double, confidence :: Maybe Double }`. Declaration order comes from the field's `Judgment` (`JudgeChoice` lists labels in order), not from the map.
- **Score.** `Score (levels :: [Symbol])` holds a derived `value :: Double`, a derived `level :: Int`, `levelProbabilities :: Vector Double` over the level indices 0..N−1, and a backend `confidence :: Maybe Double`. Its evidence record is `ScoreEvidence { levelProbabilities :: Vector Double, confidence :: Maybe Double }`. `FieldEvidence = FieldNoul NoulEvidence | FieldChoice ChoiceEvidence | FieldScore ScoreEvidence` wraps one field's evidence.
- **Default derivation.** EP-63 exports the pure functions `deriveNoul :: Double -> NoulEvidence -> (Bool, Double)`, `deriveScore :: [Double] -> ScoreEvidence -> Either Text (Double, Int)` and `deriveChoice :: Map Text Double -> ChoiceEvidence -> Either Text Text`, and calls them with fixed defaults: threshold 0.5, cuts `[0.5, 1.5, …, N−1.5]`, all weights 1.0. This plan owns the settings that feed them. It does not redefine them, but it tightens them to the exact rules below if EP-63's versions differ.
- **Output field metadata.** `Judgment { judgmentField :: Text, judgmentInstruction :: Maybe Text, judgmentKind :: JudgmentKind }`, where `JudgmentKind = JudgeBoolean … | JudgeChoice [(Text, Maybe Value)] | JudgeOrdered [Value]`, gives each field's name, kind, ordered labels and level count. Obtain the judgments of any output type with `judgmentsInSchema (deriveSchema @o)`, which returns the judgments and the free-form property names. Do not use `judgmentsOf`, which requires `DecisionOutputs o`: settings must also apply to bare `Bool` and nullary-enum fields, whose schemas are judgments too.


## Plan of Work

### Milestone 1: settings and pure derivation

Add the settings vocabulary and the derivation functions to `shikumi/src/Shikumi/Decision.hs`, or to a new internal module `Shikumi.Decision.Derive` that `Shikumi.Decision` re-exports, if EP-63's module is already large. Everything in this milestone is pure. At the end, the functions below exist with tests, and no runtime path uses them yet.

Define the per-field setting as a sum type:

```haskell
data DecisionSetting
  = NoulSetting { threshold :: !Double }
  | ScoreSetting { cuts :: ![Double] }
  | ChoiceSetting { weights :: !(Map Text Double) }
  deriving stock (Eq, Show, Generic)
```

Give it a tagged JSON encoding: `{"kind":"noul","threshold":0.7}`, `{"kind":"score","cuts":[0.5,1.6]}`, `{"kind":"choice","weights":{"billing":2}}`. Use `Data.Map.Strict` qualified. `Shikumi.Program` already has a `Map` constructor in scope.

Validation, `validateSetting :: Judgment -> DecisionSetting -> Either Text DecisionSetting`, enforces the following rules. The error text names the field and the rule broken.

- **Kind.** The setting's kind matches the field's kind.
- **Noul.** The threshold is finite and in the closed interval [0, 1].
- **Score.** For N levels there are exactly N−1 cuts. They are finite and strictly increasing, and each lies in the open interval (0, N−1).
- **Choice.** Every key is a declared label. Every weight is finite and ≥ 0. Omitted labels default to 1.0. Weight 0 disables a label.

Derivation functions take evidence plus an *effective* setting. The effective setting is the stored one, or the type's default when none is stored.

- **`deriveNoul :: Double -> NoulEvidence -> (Bool, Double)`** returns value and confidence. For threshold `t` and evidence `p`:
  - `value = p >= t`
  - `confidence = abs (p - t) / max t (1 - t)`

  When `max t (1 - t)` is 0, which cannot happen for t in [0, 1], guard it anyway. Worked example: p = 0.8, t = 0.7 gives value True and confidence 0.1 / 0.7 ≈ 0.142857.
- **`deriveScore :: [Double] -> ScoreEvidence -> Either Text (Double, Int)`** returns value and level:
  - `value = sum (i * p_i) / sum p_i` over i = 0..N−1
  - `level` = the number of cuts `c` with `c <= value`

  A zero probability sum is an error. Confidence passes through from evidence unchanged. Worked example (from DSPy's documentation): probabilities `[0.1, 0.3, 0.6]` give value 1.5. Cuts `[0.5, 1.6]` give level 1, and cuts `[0.5, 1.5]` give level 2. Cuts never change `value`.
- **`deriveChoice :: Map Text Double -> ChoiceEvidence -> Either Text Text`** returns the chosen label:
  1. Compute `score_k = p_k * w_k` for each label, with `w_k` defaulting to 1.0.
  2. If every score is 0, return `Left` ("no remaining probability mass").
  3. The *raw winner* is the label with maximal `p_k`, with ties going to the earliest declared label.
  4. Among labels with maximal `score_k`, pick the raw winner if it is among them, otherwise the earliest declared label.

  Confidence passes through unchanged. Reweighting does not recalibrate it.

Tests go in a new `shikumi/test/DecisionDeriveSpec.hs`, registered in `shikumi/test/Main.hs` and in the `other-modules` of the `shikumi-test` suite in `shikumi/shikumi.cabal`. They cover:

- the three worked examples above;
- a raw tie resolved by declaration order;
- a weighted tie resolved in favour of the raw winner;
- a zero-weight label never selected;
- all-zero mass rejected;
- validation rejecting each rule;
- a property: for random valid cuts, `value` is independent of cuts and `level` is monotone in `value`.

### Milestone 2: settings in `Params` and at run time

Extend `Params` in `shikumi/src/Shikumi/Program.hs` with `decisionSettings :: !(Map Text DecisionSetting)`, and set `emptyParams = Params Nothing [] Map.empty`. Replace the derived `FromJSON Params` with a hand-written instance that reads the field with `.:?` and defaults to empty. Keep `ToJSON` emitting the field only when it is non-empty (`omitNothingFields`-style handwritten `toJSON`). Existing compiled documents and trace fixtures then remain byte-identical for programs that do not use decisions.

`Shikumi.Program` must import `Shikumi.Decision` for the type. Check that this does not create a module cycle. If `Shikumi.Decision` imports `Shikumi.Program`, move `DecisionSetting` and its JSON instances into a small leaf module `Shikumi.Decision.Setting` that both import.

Export accessors from `Shikumi.Program` for EP-65:

- `decisionSettingFor :: Text -> Params -> Maybe DecisionSetting`
- `setDecisionSetting :: Text -> DecisionSetting -> Params -> Params`
- `clearDecisionSetting :: Text -> Params -> Params`

Do not add a Decision Log entry for these names unless they change.

Apply settings in `runPredict`. Before rendering, validate every entry of `decisionSettings ps` against the output's decision fields. A key that names no decision field, a kind mismatch, or an invalid value throws `ValidationFailure` (from `Shikumi.Error`) before `complete` is called. After `parseResponse` has decoded the evidence-bearing output, re-derive each decision field's `value`, `level` or chosen label (and Noul `confidence`) using the effective setting.

There are two acceptable shapes for this re-derivation:

- **Parameterized decode.** Thread a settings map into the decode function EP-63 exposes, so decoding and derivation happen together.
- **Post-decode rewrite.** Rewrite each decision field of the decoded `o` through a class method, for example `applyDecisionSettings :: Map Text DecisionSetting -> o -> Either Text o`, generically derived alongside `DecisionOutputs`.

Prefer the first if EP-63's decoder already takes defaults as an argument. Record the choice in the Decision Log.

The same application must happen in the `PredictCaptured` path, which also goes through `runPredict` or a sibling. Check both executors, `runProgram` and `runProgramConc`, around lines 282 and 307.

Tests in `shikumi/test/DecisionDeriveSpec.hs` or a new `DecisionParamsSpec.hs` use the scripted stub from `shikumi-testing` together with EP-63's System One stub responder or evidence fixture:

1. Run a `Predict` whose output has one Noul field, with evidence p = 0.6. With empty params the result is True. With `setDecisionSetting "urgent" (NoulSetting 0.7)` the result is False.
2. An invalid threshold of 1.5 throws `ValidationFailure`, and the stub records zero calls.
3. JSON: a literal pre-change document `{"instructionOverride":null,"demos":[]}` decodes to `emptyParams`. A `Params` with settings round-trips, and `encode emptyParams` is unchanged from before this plan (compare against the literal string).

### Milestone 3: cache, replay and compiled-program proof

This milestone changes no library code unless a test exposes a bug. It adds acceptance tests.

- **Cache hit** (`shikumi-cache/test/Main.hs`, suite `shikumi-cache-test`). Build a counting stub that returns one fixed evidence response. Run a Noul program under `cachedLLM` with an in-memory backend, then run it again with the same `Program` after `mapParams (setDecisionSetting "urgent" (NoulSetting 0.7))`. Assert:
  - the two results differ;
  - the stub's call count is 1;
  - the two requests' `cacheKey` values are equal. Compute them by capturing `Context`/`Options` in the stub, or by calling `cacheKey` on the rendered request.
- **Replay with zero calls** (`shikumi-trace/test`, suite `shikumi-trace-test`). Record a trace of one run using the existing trace fixtures in `shikumi-trace/test/TraceFixtures.hs`, build the replay index with `Shikumi.Trace.Store.replayIndex`, then run the reweighted program under `runLLMReplay`. Assert the new value and that no `ReplayDivergence` was raised. `runLLMReplay` has no provider registry, so reaching the result proves zero provider calls.
- **Compiled round-trip** (`shikumi-compile/test/Main.hs`). `encodeCompiled` a program whose decision settings are populated, then `decodeCompiledOnto` a fresh template, and check that `programParams` are equal.


## Concrete Steps

Work from the repository root, `/Users/shinzui/Keikaku/bokuno/shikumi`.

```bash
cabal build shikumi
cabal test shikumi-test --test-options='--match "Decision"'
cabal test shikumi-cache-test shikumi-trace-test shikumi-compile-test
just test
```

Expected tail of a successful focused run:

```text
Decision derivation
  Noul threshold 0.7 on p=0.8 gives True, confidence 0.142857 [✔]
  Score [0.1,0.3,0.6] gives value 1.5; cuts [0.5,1.6] give level 1 [✔]
  Choice weighted tie prefers the raw winner [✔]
...
Finished in … seconds
N examples, 0 failures
```


## Validation and Acceptance

The plan is accepted when all of the following hold:

1. `cabal test all` (`just test`) passes.
2. The three named behaviours are demonstrated by tests that fail before this plan and pass after it:
   - changing a Noul threshold flips a value served from cache, with the stub call count at 1 and equal cache keys;
   - replaying a recorded trace with new cuts or weights changes `level` or the chosen label without a `ReplayDivergence`;
   - an invalid setting raises `ValidationFailure` with zero LLM calls.
3. A pre-change `Params` JSON literal decodes, and `encode emptyParams` is byte-identical to its pre-change output.
4. The DSPy worked example (probabilities `[0.1, 0.3, 0.6]`, cuts `[0.5, 1.6]`) yields value 1.5 and level 1.


## Idempotence and Recovery

All changes are additive: a new field with a default, new functions, new tests. Re-running builds and tests is safe. If the hand-written `FromJSON Params` breaks a downstream decode, restore the derived instance temporarily and add the missing-field default through `genericParseJSON` options instead. If adding the `Shikumi.Decision` import to `Shikumi.Program` creates a cycle, extract the leaf module described in Milestone 2 before continuing. No persisted data is migrated. Documents written after this change and containing settings will not decode in older Shikumi releases, which is acceptable for a pre-1.0 additive field. Note it in the changelog.


## Interfaces and Dependencies

These are the interfaces this plan defines. EP-65 consumes them, and EP-66 relies on derivation applying unchanged to generative evidence:

```haskell
-- Shikumi.Decision (or Shikumi.Decision.Setting)
data DecisionSetting
  = NoulSetting { threshold :: !Double }
  | ScoreSetting { cuts :: ![Double] }
  | ChoiceSetting { weights :: !(Map Text Double) }

validateSetting :: Judgment -> DecisionSetting -> Either Text DecisionSetting
defaultSetting  :: Judgment -> DecisionSetting
-- the shared per-field derivation used by the System One path (EP-63) and the generative path (EP-66):
deriveField     :: Judgment -> Maybe DecisionSetting -> FieldEvidence -> Either ShikumiError Value
-- consumed from EP-63, not redefined:
-- deriveNoul   :: Double -> NoulEvidence -> (Bool, Double)
-- deriveScore  :: [Double] -> ScoreEvidence -> Either Text (Double, Int)
-- deriveChoice :: Map Text Double -> ChoiceEvidence -> Either Text Text

-- Shikumi.Program
data Params = Params
  { instructionOverride :: !(Maybe Text),
    demos :: ![Demo],
    decisionSettings :: !(Map Text DecisionSetting)
  }
decisionSettingFor   :: Text -> Params -> Maybe DecisionSetting
setDecisionSetting   :: Text -> DecisionSetting -> Params -> Params
clearDecisionSetting :: Text -> Params -> Params
```

Consumed from EP-63, to be reconciled with the landed code: `NoulEvidence`, `ChoiceEvidence`, `ScoreEvidence`, `FieldEvidence`, `Judgment`/`JudgmentKind`, `judgmentsInSchema`, and `deriveNoul`/`deriveScore`/`deriveChoice`. `deriveField` returns the field's JSON exactly as the output type's `FromModel` instance expects: the rich object for `Noul`/`Choice`/`Score`, or the bare value for a native `Bool`/enum field. EP-63's decoding and EP-66's decoding both call it.

This plan adds no new package dependencies. `containers` and `aeson` are already dependencies of `shikumi`. The tests use `shikumi-testing`, per ADR-9.
