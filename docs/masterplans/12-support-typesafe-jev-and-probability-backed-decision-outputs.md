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

The provider side (the Jev wire client, the Baikai content types that carry probabilities, and the judgment-only model capability) belongs to `mori://shinzui/baikai`. It is requested there as `mori://shinzui/baikai/okf/improvement-requests/concepts/IR-10` and planned as Baikai's MasterPlan 14 (`mori://shinzui/baikai/masterplans/14-support-typesafe-system-one-judgment-models`, artifact-level URI pending) with two child plans: EP-83, the provider-neutral content carrier (`mori://shinzui/baikai/plans/83-preserve-structured-data-and-probability-evidence-across-baikai`), and EP-84, the TypeSafe provider, the judgment catalog facts and the core judgment layer (`mori://shinzui/baikai/plans/84-deliver-the-typesafe-system-one-provider-and-judgment-catalog`). The wire types come from a third repository, the in-house client `mori://shinzui/typesafe-hs`. All of that is tracked here as Phase 1, but none of it is a Shikumi ExecPlan.

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

- **Phase 1 (Baikai).** The content carrier (Baikai EP-83), then the judgment-only capability, the core judgment layer and the `baikai-typesafe` provider (Baikai EP-84, which in turn needs the `typesafe-hs` client on Hackage). Owned by Baikai, requested as IR-10 and coordinated by Baikai's MasterPlan 14.
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
| IR-10 | Support TypeSafe System One judgment models (Baikai, external) | `mori://shinzui/baikai/okf/improvement-requests/concepts/IR-10` | `typesafe-hs` on Hackage (for Baikai EP-84) | None | Proposed (Baikai EP-83 and EP-84 Not Started) |
| 63 | Declare decision outputs and route them to System One models | [63-declare-decision-outputs-and-route-them-to-system-one-models.md](../plans/63-declare-decision-outputs-and-route-them-to-system-one-models.md) | Baikai EP-83 (milestone 2); Baikai EP-84 and the released packages (milestone 3) | None | Not Started |
| 64 | Derive decision values locally from probability evidence | [64-derive-decision-values-locally-from-probability-evidence.md](../plans/64-derive-decision-values-locally-from-probability-evidence.md) | EP-63 | None | Not Started |
| 65 | Calibrate decision settings with a ReAnchor optimizer | [65-calibrate-decision-settings-with-a-reanchor-optimizer.md](../plans/65-calibrate-decision-settings-with-a-reanchor-optimizer.md) | EP-64 | EP-66 | Not Started |
| 66 | Request probability evidence from generative models | [66-request-probability-evidence-from-generative-models.md](../plans/66-request-probability-evidence-from-generative-models.md) | EP-64 | None | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled. The IR-10 row mirrors the Baikai record's `status` field, which is authoritative (`proposed`, `accepted`, `completed`), followed by the registry status of Baikai MasterPlan 14's children. Baikai's decomposition may still move: on 2026-10-21 its MasterPlan 14 and EP-84 were reviewed `changes-requested`, and an empty EP-99 skeleton (provider-neutral judgment layer and judgment-only catalog facts) exists uncommitted in that checkout. Shikumi therefore depends on named Baikai capabilities, listed in Dependency Graph, not on Baikai plan numbers.


## Dependency Graph

IR-10 is Baikai work and runs on Baikai's schedule. EP-63 does not wait for it to start. EP-63 milestone 1 needs only today's Baikai (0.8.0.0). It covers the types, the schema, the pure derivation with default settings, state rendering, and the typed refusal of non-decision outputs. The later milestones need three Baikai capabilities, in this order:

1. **The content carrier** (Baikai EP-83): `UserData Value` and `AssistantData DataContent`, where `DataContent` has `value`, `probabilities :: Maybe (Map Text (Map Text Double))`, `confidence :: Maybe (Map Text Double)` and `method`. EP-63 milestone 2 (`evidenceOf`, sending the state as `UserData`, the cache round-trip) needs this and nothing else.
2. **The judgment-only capability and the core judgment layer** (Baikai EP-84 milestone 1, possibly split out into Baikai's EP-99): `OutputKind`, `Model.outputKind`, `isJudgmentOnly :: Model -> Bool`, the `TypeSafeSystemOne` API tag and `Baikai.Judgment` (`compileJudgments`, `refuseGenerationControls`, `validateAnswers`). EP-63 milestone 3 switches `capabilityFor` to `isJudgmentOnly` and adds the schema-convention parity test against `compileJudgments`.
3. **The provider** (Baikai EP-84, which depends on the first Hackage release of `mori://shinzui/typesafe-hs`): the `baikai-typesafe` package with its catalog entries `jev-latest` and `jev-preview`. EP-63 milestone 3's loopback-HTTP route needs it.

Baikai's content types and judgment layer land in core `baikai` with a PVP major bump, and `baikai-typesafe` cannot be published before `typesafe-hs` is. Before those releases, EP-63 milestones 2 and 3 may proceed against the sibling Baikai checkout through the gitignored `cabal.project.local`, which already overrides `baikai`, `baikai-claude`, `baikai-openai` and `baikai-effectful`. Otherwise they wait. EP-63 must not invent a Shikumi-private evidence carrier in the meantime, and a green build against the local override does not count as the integration gate.

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
- **Pure derivation.** `deriveNoul`, `deriveScore` and `deriveChoice`, each taking explicit settings.

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

**The judgment schema convention.** Two readers exist. Baikai's `Baikai.Judgment.compileJudgments` (EP-84) is the one the provider trusts, and it owns the convention once released. Shikumi's `judgmentsInSchema` (EP-63) is needed before Baikai ships and for the generative path, so it stays, but it must accept exactly the shapes Baikai compiles and nothing Baikai refuses. EP-63 owns the `Shikumi.Schema` instances that emit those shapes:

- a plain boolean for a `Noul` with no criteria, or an `anyOf` of `{"const": true, "description": …}` and `{"const": false, "description": …}` branches when `NoulWith t f` declares criteria. The criteria must live in those branches, because the private `x-shikumi-decision` marker is stripped before transport and Baikai reads criteria only from the branches;
- a string `anyOf` of `const` branches with per-branch `description` for Choice, in declaration order;
- an integer `anyOf` of `const` values `0..n-1` with level descriptions for Score.

The private marker carries only what the decoder needs (`kind`), never anything the provider must see. EP-63 milestone 3 adds a parity test: for the `Assessment` fixture, `judgmentsInSchema` and `compileJudgments` agree on field order, kinds, labels, level count and criteria. EP-66 derives its *evidence* schema (probabilities per key) from the same metadata, through a function EP-63 exports rather than by re-deriving it.

**The routing capability.** EP-63 adds `DecisionOnly` to `Shikumi.Adapter.ModelCapability` and extends `capabilityFor` and `Shikumi.Routing.translateForWire`. The reserved metadata key for the rendered state (`shikumi.decision.state`) is defined in `Shikumi.Adapter` next to the existing `shikumi.*` keys and stripped before transport like them. EP-66 adds a second key for evidence-mode generative requests in the same place. Until Baikai's capability ships, `capabilityFor` returns `DecisionOnly` for provider `typesafe`, which is the provider name Baikai's catalog will use; when Baikai EP-84 lands, EP-63 switches to `isJudgmentOnly m`, tested before the `declaredStructuredOutput` derivation that ADR-14 describes. For a `DecisionOnly` model the wire context is exactly what Baikai's preflight accepts: no system prompt, no tools, one user message with one `UserData` part holding the state.

**Request defaults (`shikumi/src/Shikumi/LLM/Defaults.hs`, EP-63 owns the change).** `withRequestDefaults` runs after `routeLLM`, so it sees the real model. Baikai's judgment providers refuse any explicit `thinking`, non-standard `speed`, `maxTokens`, `temperature` and the other sampling controls. EP-63 makes the defaults layer skip the thinking, speed and token-ceiling defaults when `isJudgmentOnly` holds for the routed model, while the evidence default still applies. Explicit controls are not touched by Shikumi: a stamped per-sample temperature from a sampling combinator reaches Baikai and is refused there as a typed, terminal error. This is the only cross-plan change to the ADR-12 layer; `RequestDefaultsSpec` must cover it.

**`Params` (`shikumi/src/Shikumi/Program.hs`).** EP-64 alone adds the per-field decision settings. It must hand-write `FromJSON Params` so documents without the field still decode (ADR-8). EP-65 only reads and writes that field through EP-64's accessors.

**The response cache and trace replay** (`shikumi-cache/src/Shikumi/Cache/ResponseJSON.hs`, the `shikumi-trace` replay). EP-63 must prove that a `Response` carrying `AssistantData` round-trips through the cache codec. Baikai's EP-83 adds named codecs in `Baikai.Response.JSON` instead of global `Response` instances, precisely so that Shikumi's orphan instances keep working; `AssistantContent` already has Baikai-owned JSON instances, so the new constructor is carried without a Shikumi codec change. Shikumi keeps its orphan instances and keeps excluding per-call evidence from cache entries. EP-64 must prove that changing a setting produces a cache hit, not a new call.

**Fixtures.** Per ADR-9, EP-63 adds decision fixtures and a System One stub responder to `shikumi-testing`; later plans extend them.

Candidate ADRs, to be written when implemented, not now:

- decision values are always derived locally from evidence and never copied from a provider's pick;
- decision settings are serialized `Params`, excluded from request identity;
- System One routing refuses non-decision outputs rather than falling back;
- request defaults are not filled for judgment-only models (an amendment to ADR-12);
- Shikumi's judgment schema reader is a conforming subset of Baikai's `compileJudgments`, and decision criteria are never carried in the private schema marker.


## Progress

Phase 1 is filed in Baikai as IR-10 (status `proposed`) and planned as Baikai MasterPlan 14 with EP-83 and EP-84, both Not Started as of 2026-10-21. Baikai's plans were revised on 2026-10-21 (TypeSafe OpenAPI 0.2.0 wire, provider-neutral `Baikai.Judgment` in core, in-house `typesafe-hs` client); this MasterPlan and EP-63 were reconciled to them the same day. No Shikumi child plan has started. EP-63 milestone 1 is implementable now; milestone 2 waits on Baikai EP-83 and milestone 3 on Baikai EP-84. Open cross-plan gates:

- [ ] `typesafe-hs` has a first release on Hackage (its own MasterPlan 1, EP-6).
- [ ] Baikai EP-83 and EP-84 are Complete, core `baikai` and `baikai-typesafe` are published, and IR-10's status is `completed`.
- [ ] `shikumi` builds against the published packages with no `cabal.project.local` override. The core bump is a PVP major, so `just upgrade-baikai` will stop at the build and the bound change is a manual migration.


## Surprises & Discoveries

- 2026-10-21: Baikai refuses, rather than drops, every explicit generation and reasoning control on a judgment-only model (Baikai MasterPlan 14, "Consumer handoff"; EP-84 Decision Log 2026-09-26). This MasterPlan and EP-63 assumed a silent drop. The consequence is a Shikumi change this initiative had not planned: `Shikumi.LLM.Defaults` fills thinking, speed and token ceiling after routing, so without an exemption every routed Jev call would be refused. EP-63 now owns that exemption.
- 2026-10-21: TypeSafe's OpenAPI 0.2.0 document contradicts the DSPy 3.4.0 client this initiative was planned against. Choice and score answers carry a required provider `confidence`, score answers carry a required `score` and `legend`, and noul questions accept optional criteria. Shikumi's evidence records already had `confidence :: Maybe Double` on `ChoiceEvidence` and `ScoreEvidence`, so no type changes; the `Maybe` stays for the generative path. The noul criteria of `NoulWith t f` are now a documented feature, but EP-63's draft hid them inside the stripped `x-shikumi-decision` marker, where Baikai would never see them. EP-63 now emits them as `anyOf` `const` branches.
- 2026-10-21: Baikai moved the schema compiler, generation-control audit and answer validator into core as `Baikai.Judgment`, so a second judgment dialect (OpenAI's Decisions API, in public beta serving `gpt-6-luna`) needs only a wire adapter. Shikumi's `judgmentsInSchema` therefore duplicates a Baikai-owned convention. The decision below keeps Shikumi's reader and pins parity by test. OpenAI's predicate has no criteria, so a `NoulWith` with declared criteria would be refused by that future adapter; nothing in this initiative needs to change for it.
- 2026-10-21: Baikai's provider takes its wire types from the in-house client `mori://shinzui/typesafe-hs` (registered 2026-10-21, no Cabal package yet, not on Hackage). Baikai's release gate builds each source distribution from Hackage only, so `baikai-typesafe` cannot ship before `typesafe-hs` does. This adds a third repository to the integration gate.
- 2026-10-21: Shikumi's `fromBaikaiError` maps Baikai's `InvalidRequest` to `SchemaMismatch` and `DecodeFailure` to `InvalidJSON`, so Baikai's typed `RequestProblem` detail (offending field path, unsupported model) does not survive into Shikumi's error vocabulary. Shikumi's own preflight should refuse every such request first, so this is a diagnostic loss, not a behavioural one. Widening the mapping is an ADR-11 change and is not in scope unless EP-63's implementation finds it necessary.
- 2026-10-21: Baikai's own MasterPlan 14 was reviewed `changes-requested` the same day, and an empty EP-99 skeleton exists uncommitted in that checkout to carve the judgment layer out of EP-84. The Baikai plan numbers this MasterPlan cites may therefore change; the capabilities in Dependency Graph will not.


## Decision Log

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

(To be filled during and after implementation.)


## Revision Notes

2026-10-21: Reconciled with Baikai's revised plans of the same day (Baikai MasterPlan 14, EP-83 and EP-84, and the new `mori://shinzui/typesafe-hs` client). The wire authority moved from DSPy 3.4.0 to TypeSafe's OpenAPI 0.2.0; the content carrier, the judgment-only capability and the core judgment layer now have concrete names; Baikai refuses rather than drops generation controls, which adds a request-defaults exemption to EP-63; noul criteria move out of the private schema marker; the integration gate gains the `typesafe-hs` and core-major release steps; ADR-11's consequences are stated precisely and ADR-14 is cited. EP-63, EP-64, EP-65 and EP-66 were cascaded accordingly.
