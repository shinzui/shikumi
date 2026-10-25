---
id: 12
slug: support-typesafe-jev-and-probability-backed-decision-outputs
title: "Support TypeSafe Jev and probability-backed decision outputs"
kind: master-plan
created_at: 2026-09-26T03:43:55Z
intention: "intention_01m3dwyjr6enwaaym2xsg39gz5"
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-09-26T03:43:55Z
  reviews:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-10-22T03:38:28Z
      verdict: "changes-requested"
      note: "Stale against Baikai's 2026-10-21 revisions: refuse-not-drop generation controls, OpenAPI 0.2.0 wire, Baikai.Judgment in core, typesafe-hs gate; ADR-11 mapping misstated, ADR-14 uncited"
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-10-22T03:38:28Z
      mode: "update"
      note: "Reconcile with Baikai MP14/EP-83/EP-84 and typesafe-hs: capability-level deps, DataContent mapping, request-defaults exemption, noul criteria placement, release gates"
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-25T04:33:29Z
      mode: "implement"
      note: "Start EP-63 offline work while upstream integration remains pending"
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-25T17:50:52Z
      mode: "implement"
      note: "Integrate released Baikai judgment routing and continue decision runtime implementation"
---

# Support TypeSafe Jev and probability-backed decision outputs

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Vision & Scope

When this initiative is complete, a Shikumi user can declare outputs that are *decisions* rather than generated values. There are three kinds:

- a yes/no judgment, called a `Noul` after TypeSafe's name for it;
- a choice among declared labels, called a `Choice`;
- a rating on declared ordered levels, called a `Score`.

A decision result carries the probability evidence behind it as well as the answer. The same `Program i o` can run against two kinds of backend and returns identically typed results from either:

- **A judgment-only model.** It answers only declared judgments and returns a probability distribution for each. The first is TypeSafe's System One model Jev (`jev-latest`). Baikai models the capability provider-neutrally, so a second dialect such as OpenAI's Decisions API would reach Shikumi through the same route without a Shikumi change.
- **An ordinary generative model.** It is asked to report those distributions as structured JSON.

The final answer (`value`, `level`, or chosen label) is derived locally from the evidence through per-field numeric settings stored in the program's `Params`:

- a Noul `threshold`;
- Score `cuts`;
- Choice `weights`.

Because these settings are local, changing them never changes the provider request and reuses cached evidence. A new optimizer, modelled on DSPy 3.4.0's ReAnchor, fits those settings against a user metric with a fold check. It never touches instructions or demos.

In scope:

- the decision types and their JSON-schema encoding;
- a decision-only routing capability and adapter;
- local derivation with serialized per-field settings;
- the calibration optimizer;
- the generative evidence path.

The provider side (the Jev wire client, the Baikai content types that carry probabilities, and the judgment-only model capability) belongs to `mori://shinzui/baikai`. It is requested there as `mori://shinzui/baikai/okf/improvement-requests/concepts/IR-10` and planned as Baikai's MasterPlan 14 (`mori://shinzui/baikai/masterplans/14-support-typesafe-system-one-judgment-models`, artifact-level URI pending) with three child plans: EP-83, the provider-neutral content carrier (`mori://shinzui/baikai/plans/83-preserve-structured-data-and-probability-evidence-across-baikai`); EP-99, the judgment-only catalog facts and the provider-neutral core judgment layer (`mori://shinzui/baikai/plans/99-add-a-provider-neutral-judgment-layer-and-judgment-only-catalog-facts-to-core`); and EP-84, the TypeSafe provider (`mori://shinzui/baikai/plans/84-deliver-the-typesafe-system-one-provider-and-judgment-catalog`). The wire types come from a third repository, the in-house client `mori://shinzui/typesafe-hs`. All of that is tracked here as Phase 1, but none of it is a Shikumi ExecPlan.

Explicitly excluded:

- streaming decisions;
- decision outputs nested in containers (`[Noul]`, maps of `Choice`);
- decision outputs from the recursive session runtime (`Shikumi.Recursive`) and from ReAct submissions;
- token-logprob extraction from generative providers;
- any silent fallback from a System One model to a generative one when a signature has free-form outputs;
- fine-tuning;
- running live provider calls in CI.

The reference behaviour for the decision types, local derivation and calibration is DSPy 3.4.0 (tag `3.4.0`, repository `mori://stanfordnlp/dspy`, not yet registered in the local Mori registry; artifact-level URIs pending). The relevant project-relative paths are:

- user contract: `docs/docs/api/experimental/DecisionTypes.md`;
- optimizer: `docs/docs/api/experimental/ReAnchor.md`;
- judgment schema convention: `dspy/_vendor/lm15/judgments.py`.

DSPy is no longer the authority for the wire. Since 2026-10-21 Baikai's plans follow TypeSafe's own OpenAPI document, version 0.2.0 (published at `https://api.typesafe.ai/openapi.json`, to be vendored by `mori://shinzui/typesafe-hs`), which differs from DSPy's `lm15` client: a choice answer carries a required `confidence`; a score answer carries a required `score`, `confidence` and `legend`; a noul question accepts optional `true`/`false` criteria; a success body requires `model` and `usage`. Shikumi never speaks the wire itself, so these facts reach it only through Baikai's content types.


## Decomposition Strategy

The initiative splits into five phases by capability. Each Shikumi phase produces a behaviour that can be demonstrated offline with the `shikumi-testing` stub interpreters:

- **Phase 1 (Baikai).** The content carrier (Baikai EP-83), then the judgment-only capability and the core judgment layer (Baikai EP-99), then the `baikai-typesafe` provider (Baikai EP-84, which in turn needs the `typesafe-hs` client on Hackage). Owned by Baikai, requested as IR-10 and coordinated by Baikai's MasterPlan 14.
- **Phase 2, EP-63: routing.** Makes decisions expressible and routable. It covers:
  - the types;
  - their schema;
  - a compile-time `DecisionOutputs` class for programs that must run on System One;
  - the `DecisionOnly` capability;
  - the adapter that renders a signature and demos as one JSON *state*;
  - decoding the probability evidence into typed results.
- **Phase 3, EP-64: local derivation.** Makes those results tunable. Per-field settings live in `Params`, derivation is pure and local, and the settings are serialized with compiled programs and replayed without new provider calls.
- **Phase 4, EP-65: calibration.** An optimizer over those settings.
- **Phase 5, EP-66: generative evidence.** Lets generative models produce the same evidence, so a decision program is not tied to one vendor.

Alternatives considered:

- **One plan per package** (core, cache, optimize). Rejected: the adapter, the decoder and the parameter overlay must agree on one evidence representation, and splitting them by package would leave nobody owning it.
- **Merging EP-63 and EP-64.** Rejected: EP-63 is independently useful with fixed default settings (threshold 0.5, evenly spaced cuts, unit weights). EP-64's serialization change to `Params` has its own compatibility risk.
- **Putting the generative path first.** It would need no Baikai change. It was rejected as the default ordering because Jev's judgment convention fixes the schema shape the generative path must mirror. EP-66 has no hard dependency on IR-10, so it may be pulled ahead if IR-10 stalls. That choice is recorded in the Decision Log below.

Relevant local ADRs:

- [ADR-9](../adr/0009-centralize-offline-harness-and-diverse-fixtures.md): offline stub interpreters, loopback HTTP fixtures, and new fixtures belong in `shikumi-testing`.
- [ADR-11](../adr/0011-preserve-provider-errors-and-centralize-retry-policy.md): Baikai owns transport classification and Shikumi never reclassifies from message text. Under the existing `fromBaikaiError` mapping, Baikai's pre-dispatch refusal of an unsupported judgment request (category `InvalidRequest`) surfaces as a terminal `SchemaMismatch`, a malformed Jev reply (`DecodeFailure`) surfaces as `InvalidJSON`, and every other category is preserved as `ProviderError`. All three are terminal. Baikai's typed `RequestProblem` detail is not preserved by that mapping; see Surprises & Discoveries.
- [ADR-12](../adr/0012-apply-request-defaults-before-cache-and-observation.md): request defaults (thinking level, speed, token ceiling) are filled after routing by `Shikumi.LLM.Defaults`. Baikai's judgment providers refuse every explicit generation or reasoning control rather than dropping it, so the defaults layer must not fill those three fields for a judgment-only model. ADR-12 must be amended when EP-63 implements that exemption.
- [ADR-14](../adr/0014-separate-schema-enforcement-from-tool-calling-capability.md): `capabilityFor` is a pure function of `Model` derived from Baikai's `declaredStructuredOutput`. EP-63 adds the `DecisionOnly` branch in front of that derivation, keyed on Baikai's `isJudgmentOnly`.
- [ADR-5](../adr/0005-own-optimizer-admission-and-diagnostic-reports-in-search-sessions.md): new optimizers run inside the shared `SearchSession` and its admission and reporting.
- [ADR-8](../adr/0008-restore-typed-structures-through-trusted-recipe-registries.md): compiled parameter serialization is independent of optimizer reports and must stay backward-compatible, which applies to the new `Params` field.

No cross-repository ADR in `mori://shinzui/baikai` covers judgment models yet; Baikai's EP-83 and EP-84 will write them during implementation. Until then IR-10 and Baikai's MasterPlan 14 are the governing upstream records. `mori://shinzui/typesafe-hs` has no ADR corpus.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| IR-10 | Support TypeSafe System One judgment models (Baikai, external) | `mori://shinzui/baikai/okf/improvement-requests/concepts/IR-10` | `typesafe-hs` on Hackage (for Baikai EP-84) | None | Completed (Baikai EP-83, EP-99 and EP-84 Complete) |
| 63 | Declare decision outputs and route them to System One models | [63-declare-decision-outputs-and-route-them-to-system-one-models.md](../plans/63-declare-decision-outputs-and-route-them-to-system-one-models.md) | Baikai EP-83 (milestone 2); Baikai EP-84 and the released packages (milestone 3) | None | Complete |
| 64 | Derive decision values locally from probability evidence | [64-derive-decision-values-locally-from-probability-evidence.md](../plans/64-derive-decision-values-locally-from-probability-evidence.md) | EP-63 milestone 1 (pure settings); milestone 2 (runtime settings) | None | Complete |
| 65 | Calibrate decision settings with a ReAnchor optimizer | [65-calibrate-decision-settings-with-a-reanchor-optimizer.md](../plans/65-calibrate-decision-settings-with-a-reanchor-optimizer.md) | EP-64 | EP-66 | Complete |
| 66 | Request probability evidence from generative models | [66-request-probability-evidence-from-generative-models.md](../plans/66-request-probability-evidence-from-generative-models.md) | EP-64 | None | Complete |

Status values: Not Started, In Progress, Complete, Cancelled. The IR-10 row mirrors the Baikai record's `status` field, which is authoritative (`proposed`, `accepted`, `completed`), followed by the registry status of Baikai MasterPlan 14's children. On 2026-10-22 Baikai split the provider-neutral judgment layer and the judgment-only catalog facts out of EP-84 into EP-99 (`mori://shinzui/baikai/plans/99-add-a-provider-neutral-judgment-layer-and-judgment-only-catalog-facts-to-core`, artifact-level URI pending), so the three capabilities in Dependency Graph map to EP-83, EP-99 and EP-84 respectively. Shikumi still depends on the capabilities, not on the plan numbers.


## Dependency Graph

IR-10 is Baikai work and runs on Baikai's schedule. EP-63 does not wait for it to start. EP-63 milestone 1 needs only today's Baikai (0.8.0.0). It covers the types, the schema, the pure derivation with default settings, state rendering, and the typed refusal of non-decision outputs. The later milestones need three Baikai capabilities, in this order:

1. **The content carrier** (Baikai EP-83): `UserData Value` and `AssistantData DataContent`, where `DataContent` has `value`, `probabilities :: Maybe (Map Text (Map Text Double))`, `confidence :: Maybe (Map Text Double)` and `method`. EP-63 milestone 2 (`evidenceOf`, sending the state as `UserData`, the cache round-trip) needs this and nothing else.
2. **The judgment-only capability and the core judgment layer** (Baikai EP-99): `OutputKind`, `Model.outputKind`, `isJudgmentOnly :: Model -> Bool`, the `InputData` modality, the `TypeSafeSystemOne` API tag with the `jev-latest` and `jev-preview` catalog entries, and `Baikai.Judgment` (`prepareJudgment`, `compileJudgments`, `refuseGenerationControls`, `validateAnswers`, `judgmentMethod`). EP-63 milestone 3 switches `capabilityFor` to `isJudgmentOnly` and adds the schema-convention parity test against `compileJudgments`. Baikai orders `Judgments` by the schema's `required` array when it lists every declared property exactly once, and by ascending key otherwise, because aeson objects do not keep declaration order (Baikai EP-99 Decision Log, 2026-10-22). Shikumi's derived schemas list every output field in `required` in declaration order, so both readers see declaration order.
3. **The provider** (Baikai EP-84, which depends on the first Hackage release of `mori://shinzui/typesafe-hs`): the `baikai-typesafe` package, with its wire mapping over the in-house client, transport and evidence. EP-63 milestone 3's loopback-HTTP route needs it.

Baikai's content types (EP-83) and judgment layer (EP-99) land in core `baikai` with one PVP major bump that does not wait for `typesafe-hs`; `baikai-typesafe` (EP-84) cannot be published before `typesafe-hs` is. Before those releases, EP-63 milestones 2 and 3 may proceed against the sibling Baikai checkout through the gitignored `cabal.project.local`, which already overrides `baikai`, `baikai-claude`, `baikai-openai` and `baikai-effectful`. Otherwise they wait. EP-63 must not invent a Shikumi-private evidence carrier in the meantime, and a green build against the local override does not count as the integration gate.

EP-64 hard-depends on EP-63 because it parameterizes the decoder and types EP-63 defines. Precisely, EP-64's first milestone (settings types and pure derivation) needs only EP-63 milestone 1. Its later milestones apply settings inside decoding, so they need EP-63 milestone 2. EP-65 and EP-66 both hard-depend on EP-64. EP-65 searches the settings EP-64 serializes. EP-66 routes evidence into EP-64's derivation, so the same settings apply on both backends. EP-65 and EP-66 can proceed in parallel. EP-65 benefits from EP-66, because it can then be demonstrated on a generative stub as well as a System One stub, but it does not require it.

Recommended order: IR-10 filed (done at plan creation); EP-63 milestone 1; EP-64's pure settings and derivation milestone; the IR-10 content types; EP-63 milestones 2–3; the remainder of EP-64; then EP-66 and EP-65 in parallel. EP-66's decoding reads JSON text from generative models, so it does not need `AssistantData`. It can therefore run ahead of EP-63 milestone 2 if IR-10 stalls.


## Integration Points

**Decision types and evidence (`Shikumi.Decision`, new, in the core `shikumi` package).** EP-63 defines them:

- `Noul`, `Choice a`, `Score levels`;
- the evidence records `NoulEvidence`, `ChoiceEvidence` and `ScoreEvidence`;
- the `DecisionOutputs o` class.

EP-64 adds the settings types and replaces EP-63's fixed defaults with settings lookup. It must not change the evidence records' JSON shape. EP-66 produces the same evidence records from generative JSON and must not define a parallel type.

**Reading Baikai's `DataContent` (EP-63 owns `evidenceOf`).** Baikai's `probabilities` map is keyed by field name and then by answer key: `true` and `false` for a boolean judgment, the declared labels for a choice, and decimal level indices (`"0"`, `"1"`, …) for a score. Its `confidence` map holds the provider-reported per-field confidence where the provider gives one (TypeSafe: choice and score; never a noul). Its `method` is `provider_classification`. Its `value` holds Baikai's base chosen answers: a boolean at p ≥ 0.5, the provider's declared choice, and the provider's expected score as a JSON number. EP-63 builds `NoulEvidence` from the `true` key, `ChoiceEvidence` from the label keys plus the confidence entry, and `ScoreEvidence` from the level keys sorted numerically plus the confidence entry. It reads `value` only in a parity test: Shikumi's locally derived defaults must agree with Baikai's base answers on the fixture, and the decision types never copy `value`.

**Reconciled names.** Child plans were drafted in parallel and then reconciled against the names below. Implementers rename in all affected plans together if the landed code differs.

EP-63 defines these in `Shikumi.Decision`:

- **Rich result types.** `NoulWith t f` (with `type Noul = NoulWith "" ""`), `Choice a` (options via `ChoiceOptions a`), and `Score levels`.
- **Evidence records.** `NoulEvidence { pTrue }`, `ChoiceEvidence { probabilities :: Map Text Double, confidence }`, `ScoreEvidence { levelProbabilities :: Vector Double, confidence }`, and the per-field wrapper `FieldEvidence`.
- **Field metadata.** `Judgment { judgmentField, judgmentInstruction, judgmentKind }` with `JudgmentKind = JudgeBoolean | JudgeChoice | JudgeOrdered`. `judgmentsInSchema :: Value -> ([Judgment], [Text])` works for any output type, including bare `Bool` and enum fields. `IsDecision`, `DecisionOutputs` and `judgmentsOf` are the compile-time System One guarantee only. Baikai's `Baikai.Judgment` has the isomorphic `Judgment { name, instructions :: Value, kind }` with `JudgmentKind = PredicateJudgment (Maybe (Value, Value)) | ChoiceJudgment (Vector (Text, Maybe Value)) | ScoreJudgment (Vector (Maybe Value))`; Shikumi keeps its own names and types because they exist before Baikai's release and serve the generative path too.
- **Question rendering.** `questionJSON :: Judgment -> Value`.
- **Pure derivation.** `deriveNoul`, `deriveScore` and `deriveChoice`, each taking explicit settings; `deriveChoice` also takes declared labels in order before the weights map.

EP-63 also defines, in `Shikumi.Adapter` and `Shikumi.Testing.SystemOne`:

- `DecisionOnly`;
- `metaDecisionStateKey`;
- the private `x-shikumi-decision` schema marker, stripped before transport;
- `systemOneResponse` and `systemOneResponder`.

EP-64 defines these:

- In `Shikumi.Decision`, or the leaf module `Shikumi.Decision.Setting` if needed to avoid an import cycle:
  - `DecisionSetting = NoulSetting { threshold } | ScoreSetting { cuts } | ChoiceSetting { weights }`;
  - `validateSetting` and `defaultSetting`, both over `Judgment`;
  - `deriveField :: Judgment -> Maybe DecisionSetting -> FieldEvidence -> Either ShikumiError Value`, the single per-field derivation that both backends call.
- In `Shikumi.Program`:
  - the `decisionSettings :: Map Text DecisionSetting` field of `Params`;
  - `decisionSettingFor`, `setDecisionSetting` and `clearDecisionSetting`.

EP-65 adds `nodeDecisionFieldsIndexed :: Program i o -> [[Judgment]]` to core. EP-66 adds `metaDecisionEvidenceKey`, `evidenceFields` (over the settings map rather than `Params`, which avoids an `Adapter` → `Program` import cycle), and `evidenceSchema`.

**The judgment schema convention.** Two readers exist. Baikai's `Baikai.Judgment.compileJudgments` (EP-99) is the one the provider trusts, and it owns the convention once released. Shikumi's `judgmentsInSchema` (EP-63) is needed before Baikai ships and for the generative path, so it stays, but it must accept exactly the shapes Baikai compiles and nothing Baikai refuses. EP-63 owns the `Shikumi.Schema` instances that emit those shapes:

- a plain boolean for a `Noul` with no criteria, or an `anyOf` of `{"const": true, "description": …}` and `{"const": false, "description": …}` branches when `NoulWith t f` declares criteria. The criteria must live in those branches, because the private `x-shikumi-decision` marker is stripped before transport and Baikai reads criteria only from the branches;
- a string `anyOf` of `const` branches with per-branch `description` for Choice, in declaration order;
- an integer `anyOf` of `const` values `0..n-1` with level descriptions for Score.

The private marker carries only what the decoder needs (`kind`), never anything the provider must see. EP-63 milestone 3 adds a parity test: for the `Assessment` fixture, `judgmentsInSchema` and `compileJudgments` agree on field order, kinds, labels, level count and criteria. EP-66 derives its *evidence* schema (probabilities per key) from the same metadata, through a function EP-63 exports rather than by re-deriving it.

**Generative schema ownership.** EP-66 retains the original answer schema under
`metaDecisionSchemaKey` while the ordinary response-schema stamp holds evidence
objects. DecisionOnly routing chooses the original schema; generative routing
chooses evidence. Both are stripped. Prompt classes live in the re-exported leaf
`Shikumi.Adapter.Prompt` to avoid an Adapter/Decision cycle. Demo evidence and
structured-state labels use separate JSON projections.

**The routing capability.** EP-63 adds `DecisionOnly` to `Shikumi.Adapter.ModelCapability` and extends `capabilityFor` and `Shikumi.Routing.translateForWire`. The reserved metadata key for the rendered state (`shikumi.decision.state`) is defined in `Shikumi.Adapter` next to the existing `shikumi.*` keys and stripped before transport like them. EP-66 adds a second key for evidence-mode generative requests in the same place. Until Baikai's capability ships, `capabilityFor` returns `DecisionOnly` for provider `typesafe`, which is the provider name Baikai's catalog will use; when Baikai EP-99 lands, EP-63 switches to `isJudgmentOnly m`, tested before the `declaredStructuredOutput` derivation that ADR-14 describes. For a `DecisionOnly` model the wire context is exactly what Baikai's preflight accepts: no system prompt, no tools, one user message with one `UserData` part holding the state.

**Request defaults (`shikumi/src/Shikumi/LLM/Defaults.hs`, EP-63 owns the change).** `withRequestDefaults` runs after `routeLLM`, so it sees the real model. Baikai's judgment providers refuse any explicit `thinking`, non-standard `speed`, `maxTokens`, `temperature` and the other sampling controls. EP-63 makes the defaults layer skip the thinking, speed and token-ceiling defaults when `isJudgmentOnly` holds for the routed model, while the evidence default still applies. Explicit controls are not touched by Shikumi: a stamped per-sample temperature from a sampling combinator reaches Baikai and is refused there as a typed, terminal error. This is the only cross-plan change to the ADR-12 layer; `RequestDefaultsSpec` must cover it.

**`Params` (`shikumi/src/Shikumi/Program.hs`).** EP-64 alone adds the per-field decision settings. It must hand-write `FromJSON Params` so documents without the field still decode (ADR-8). EP-65 only reads and writes that field through EP-64's accessors.

**The response cache and trace replay** (`shikumi-cache/src/Shikumi/Cache/ResponseJSON.hs`, the `shikumi-trace` replay). EP-63 must prove that a `Response` carrying `AssistantData` round-trips through the cache codec. Baikai's EP-83 adds named codecs in `Baikai.Response.JSON` instead of global `Response` instances, precisely so that Shikumi's orphan instances keep working; `AssistantContent` already has Baikai-owned JSON instances, so the new constructor is carried without a Shikumi codec change. Shikumi keeps its orphan instances and keeps excluding per-call evidence from cache entries. EP-64 must prove that changing a setting produces a cache hit, not a new call.

**Fixtures.** Per ADR-9, EP-63 adds decision fixtures and a System One stub responder to `shikumi-testing`; later plans extend them.

Durable decisions are recorded in [ADR-15](../adr/0015-derive-decision-answers-from-probability-evidence.md), with defaults in [ADR-12](../adr/0012-apply-request-defaults-before-cache-and-observation.md), capability selection in [ADR-14](../adr/0014-separate-schema-enforcement-from-tool-calling-capability.md), and calibration in [ADR-5](../adr/0005-own-optimizer-admission-and-diagnostic-reports-in-search-sessions.md):

- decision values are always derived locally from evidence and never copied from a provider's pick;
- decision settings are serialized `Params`, excluded from request identity;
- System One routing refuses non-decision outputs rather than falling back;
- request defaults are not filled for judgment-only models (an amendment to ADR-12);
- Shikumi's judgment schema reader is a conforming subset of Baikai's `compileJudgments`, and decision criteria are never carried in the private schema marker.


## Progress

All four Shikumi children and the external integration gates are Complete
(2026-10-25). The published Baikai 0.9 cohort provides structured content,
judgment-only routing and the TypeSafe adapter without a local override. The same
decision program decodes System One, native JSON and marker evidence through local
settings. Cache keys stay equal when numeric settings change; trace replay and
compiled settings restore correctly. ReAnchor fits thresholds, cuts and weights
with replay above admission and strict held-out selection.

Acceptance includes build-all, the full repository test suite, compiler-rejection
diagnostics, TypeSafe loopback requests/refusals/malformed replies, compiler parity,
source-distribution inclusion, Haddock identifier checks and strict ADR validation.
Redis tests skip without a reachable socket and live calls remain opt-in; no live
provider calls were run.

The Hackage registry and upstream package-prefixed release tags were checked on
2026-10-25. Baikai core 0.10.0.0 and Claude/OpenAI 0.7.3.0 were newer, but the
then-published TypeSafe 0.1.0.0 and effectful 0.4.0.4 bounds required core 0.9.
Shikumi uses the complete released cohort, with no compatibility override.

- [x] `typesafe-hs` 0.1.0.0 is on Hackage.
- [x] Baikai EP-83, EP-99 and EP-84 are Complete; IR-10 is completed and the required packages are published.
- [x] The repository builds and tests against published packages with no local override.


## Surprises & Discoveries

- 2026-10-25: The upstream content, judgment and provider capabilities had shipped since the prior handoff. Hackage and package-prefixed upstream tags confirmed a complete 0.9 cohort, which removed the integration blocker. IR-10 is completed and all three upstream children are Complete.
- 2026-10-25: Plain Predict observations intentionally omit typed JSON output. ReAnchor captures raw responses by structural node path so it can fit ordinary predict programs. Its replay is inside candidate admission; accepted-candidate reporting pins the held-out winner and excludes rejected trials from the reported frontier. ADR-5 records this boundary.
- 2026-10-25: Generative evidence and judgment answer schemas must coexist on the model-agnostic request. A separate original-schema stamp and the prompt-class leaf module resolve routing ownership and the import cycle; ADR-15 records the shared contract.

- 2026-10-21: Baikai refuses, rather than drops, every explicit generation and reasoning control on a judgment-only model (Baikai MasterPlan 14, "Consumer handoff"; EP-84 Decision Log 2026-09-26). This MasterPlan and EP-63 assumed a silent drop. The consequence is a Shikumi change this initiative had not planned: `Shikumi.LLM.Defaults` fills thinking, speed and token ceiling after routing, so without an exemption every routed Jev call would be refused. EP-63 now owns that exemption.
- 2026-10-21: TypeSafe's OpenAPI 0.2.0 document contradicts the DSPy 3.4.0 client this initiative was planned against. Choice and score answers carry a required provider `confidence`, score answers carry a required `score` and `legend`, and noul questions accept optional criteria. Shikumi's evidence records already had `confidence :: Maybe Double` on `ChoiceEvidence` and `ScoreEvidence`, so no type changes; the `Maybe` stays for the generative path. The noul criteria of `NoulWith t f` are now a documented feature, but EP-63's draft hid them inside the stripped `x-shikumi-decision` marker, where Baikai would never see them. EP-63 now emits them as `anyOf` `const` branches.
- 2026-10-21: Baikai moved the schema compiler, generation-control audit and answer validator into core as `Baikai.Judgment`, so a second judgment dialect (OpenAI's Decisions API, in public beta serving `gpt-6-luna`) needs only a wire adapter. Shikumi's `judgmentsInSchema` therefore duplicates a Baikai-owned convention. The decision below keeps Shikumi's reader and pins parity by test. OpenAI's predicate has no criteria, so a `NoulWith` with declared criteria would be refused by that future adapter; nothing in this initiative needs to change for it.
- 2026-10-21: Baikai's provider takes its wire types from the in-house client `mori://shinzui/typesafe-hs` (registered 2026-10-21, no Cabal package yet, not on Hackage). Baikai's release gate builds each source distribution from Hackage only, so `baikai-typesafe` cannot ship before `typesafe-hs` does. This adds a third repository to the integration gate.
- 2026-10-21: Shikumi's `fromBaikaiError` maps Baikai's `InvalidRequest` to `SchemaMismatch` and `DecodeFailure` to `InvalidJSON`, so Baikai's typed `RequestProblem` detail (offending field path, unsupported model) does not survive into Shikumi's error vocabulary. Shikumi's own preflight should refuse every such request first, so this is a diagnostic loss, not a behavioural one. Widening the mapping is an ADR-11 change and is not in scope unless EP-63's implementation finds it necessary.
- 2026-10-21: Baikai's own MasterPlan 14 was reviewed `changes-requested` the same day, and an empty EP-99 skeleton exists uncommitted in that checkout to carve the judgment layer out of EP-84. The Baikai plan numbers this MasterPlan cites may therefore change; the capabilities in Dependency Graph will not. Resolved 2026-10-22: Baikai filled and registered EP-99. `OutputKind`, `isJudgmentOnly`, `InputData`, the `TypeSafeSystemOne` tag, the `jev-*` catalog entries and `Baikai.Judgment` are EP-99's; EP-84 keeps the `baikai-typesafe` provider package. Baikai's EP-99 initially left open how `Judgments` recover property order from an aeson object; the `required`-then-ascending rule was added to it the same day at Shikumi's request, so the parity test has a defined order to compare. Baikai's core major release now ships without waiting for `typesafe-hs`, so EP-63 milestone 3's capability switch and parity test can land before its loopback-HTTP route.


## Decision Log

- Decision: Complete EP-63's offline types and EP-64's pure settings milestone while upstream capabilities are developed separately. Choice derivation takes ordered labels explicitly; state uses typed `ToPrompt` JSON methods. The durable boundaries are recorded in [ADR-15](../adr/0015-derive-decision-answers-from-probability-evidence.md).
  Rationale: These milestones need only published core dependencies. They establish the shared evidence and judgment interfaces without introducing a private transport carrier or weakening any release gate.
  Date: 2026-10-24

- Decision: Track the Baikai phase as the improvement request `mori://shinzui/baikai/okf/improvement-requests/concepts/IR-10` rather than as a Shikumi ExecPlan, and ask for provider-neutral `AssistantData`/`UserData` content instead of a text-body stopgap.
  Rationale: Probabilities are the product of a System One call. Carrying them as JSON in a text part would leak one provider's format into every caller, and would lose them in Baikai's trace and cost-log encodings.
  Date: 2026-09-26

- Decision: Derive every decision value locally from evidence, on both backends, and store numeric settings in `Params`, outside request identity.
  Rationale: This matches DSPy 3.4.0. It makes calibration a pure, cache-friendly search, and it keeps a program's result independent of which backend produced the evidence.
  Date: 2026-09-26

- Decision: EP-66 hard-depends only on EP-64, not on IR-10, and may be pulled ahead of EP-65 or EP-63 milestone 3 if IR-10 is delayed.
  Rationale: The generative evidence path needs no new provider and gives users decision outputs on existing models.
  Date: 2026-09-26

- Decision: Track the Baikai phase by three named capabilities (content carrier; judgment-only capability and core judgment layer; `baikai-typesafe` provider) and keep IR-10 as the single external registry row, rather than registering Baikai's EP-83, EP-84 and the pending EP-99 as rows.
  Rationale: Baikai's decomposition was reviewed `changes-requested` on 2026-10-21 and may still split. The capabilities are what EP-63's milestones consume, and they are stable across that split.
  Date: 2026-10-21

- Decision: Keep Shikumi's `judgmentsInSchema` as its own reader of the judgment schema convention, require by test that it agrees with Baikai's `Baikai.Judgment.compileJudgments` on the shared fixture once that module is released, and never carry decision criteria in the private `x-shikumi-decision` marker.
  Rationale: EP-63 milestone 1 and EP-66 must work against today's Baikai and against generative models, where no judgment provider is involved. Delegating to Baikai's compiler would tie the offline milestones to Baikai's release. Parity by test keeps one convention with two readers honest. The marker is stripped before transport, so anything the provider must see has to be ordinary schema.
  Date: 2026-10-21

- Decision: `Shikumi.LLM.Defaults` skips the thinking, speed and token-ceiling defaults for a judgment-only model; explicit controls pass through untouched and Baikai's refusal surfaces as a typed, terminal error. EP-63 owns the change and amends ADR-12 when it lands.
  Rationale: Baikai refuses explicit generation controls on judgment-only models instead of dropping them. Defaults are Shikumi's own additions, so withholding them is not a silent fallback; an explicit control is user intent, and refusing it loudly matches this initiative's exclusion of silent fallbacks.
  Date: 2026-10-21


## Outcomes & Retrospective

Completed 2026-10-25 through EP-63, EP-64, EP-65 and EP-66. Users can declare rich
decisions, route them to Jev or a generative model, tune serialized settings without
changing an existing evidence request, and calibrate those settings through the
shared search session. Unsupported judgment outputs and decision streams fail
before dispatch. The published-dependency and offline HTTP gates are satisfied.

The ADR distillation pass reviewed every child's decisions, discoveries and
outcomes. ADR-5 owns replay/admission and held-out selection, ADR-12 the defaults
exemption, ADR-14 capability selection, and ADR-15 evidence, schema, state, demo
and local-derivation boundaries. No initiative-level friction remained to triage.
Live provider verification and package publication were not part of this execution.


## Revision Notes

2026-10-21: Reconciled with Baikai's revised plans of the same day (Baikai MasterPlan 14, EP-83 and EP-84, and the new `mori://shinzui/typesafe-hs` client). The wire authority moved from DSPy 3.4.0 to TypeSafe's OpenAPI 0.2.0; the content carrier, the judgment-only capability and the core judgment layer now have concrete names; Baikai refuses rather than drops generation controls, which adds a request-defaults exemption to EP-63; noul criteria move out of the private schema marker; the integration gate gains the `typesafe-hs` and core-major release steps; ADR-11's consequences are stated precisely and ADR-14 is cited. EP-63, EP-64, EP-65 and EP-66 were cascaded accordingly.

2026-10-22: Baikai split its EP-84 into EP-99 (judgment-only catalog facts, the TypeSafe API tag and catalog entries, and the provider-neutral judgment layer, all in core) and EP-84 (the `baikai-typesafe` provider). The Dependency Graph, registry, Progress and Integration Points now name EP-99 for the second capability, use Baikai's actual names (`prepareJudgment`, `judgmentMethod`), and record the question-order rule the parity test relies on. EP-63 was cascaded.

2026-10-24: Started implementation and completed the offline EP-63 and pure EP-64 milestones. Registered both children In Progress, made EP-64's milestone dependency explicit in the registry, recorded the landed Choice/state interfaces and added ADR-15. Upstream provider integration and release gates remain open.

2026-10-25: Completed runtime integration against published dependencies, local
settings and persistence, ReAnchor calibration, and generative evidence. All
children and cross-repository gates are accepted; durable context was distilled
into ADR-5, ADR-12, ADR-14 and ADR-15.
