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

- **A TypeSafe System One model such as Jev (`jev-latest`).** It answers only declared judgments and returns a probability distribution for each.
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

The provider side (the Jev wire client and the Baikai content types that carry probabilities) belongs to `mori://shinzui/baikai`. It is requested there as `mori://shinzui/baikai/okf/improvement-requests/concepts/IR-10`, which is tracked here as Phase 1 but is not a Shikumi ExecPlan.

Explicitly excluded:

- streaming decisions;
- decision outputs nested in containers (`[Noul]`, maps of `Choice`);
- decision outputs from the recursive session runtime (`Shikumi.Recursive`) and from ReAct submissions;
- token-logprob extraction from generative providers;
- any silent fallback from a System One model to a generative one when a signature has free-form outputs;
- fine-tuning;
- running live provider calls in CI.

The reference behaviour is DSPy 3.4.0 (tag `3.4.0`, repository `mori://stanfordnlp/dspy`, not yet registered in the local Mori registry; artifact-level URIs pending). The relevant project-relative paths are:

- user contract: `docs/docs/api/experimental/DecisionTypes.md`;
- optimizer: `docs/docs/api/experimental/ReAnchor.md`;
- wire client: `dspy/_vendor/lm15/providers/typesafe.py`;
- judgment schema convention: `dspy/_vendor/lm15/judgments.py`.


## Decomposition Strategy

The initiative splits into five phases by capability. Each Shikumi phase produces a behaviour that can be demonstrated offline with the `shikumi-testing` stub interpreters:

- **Phase 1 (Baikai).** The provider and the content types, owned by Baikai and requested as IR-10.
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
- [ADR-11](../adr/0011-preserve-provider-errors-and-centralize-retry-policy.md): Baikai owns transport classification. A System One refusal of an unsupported request must surface as a preserved, terminal `ProviderError`, never reclassified from message text.
- [ADR-12](../adr/0012-apply-request-defaults-before-cache-and-observation.md): request defaults (thinking level, speed, token ceiling) are filled after routing. A System One provider drops them, so decision routing must not treat that drop as an error.
- [ADR-5](../adr/0005-own-optimizer-admission-and-diagnostic-reports-in-search-sessions.md): new optimizers run inside the shared `SearchSession` and its admission and reporting.
- [ADR-8](../adr/0008-restore-typed-structures-through-trusted-recipe-registries.md): compiled parameter serialization is independent of optimizer reports and must stay backward-compatible, which applies to the new `Params` field.

No cross-repository ADR in `mori://shinzui/baikai` covers judgment models; IR-10 is the governing upstream record.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| IR-10 | Support TypeSafe System One judgment models (Baikai, external) | `mori://shinzui/baikai/okf/improvement-requests/concepts/IR-10` | None | None | Proposed |
| 63 | Declare decision outputs and route them to System One models | [63-declare-decision-outputs-and-route-them-to-system-one-models.md](../plans/63-declare-decision-outputs-and-route-them-to-system-one-models.md) | IR-10 (milestones 2–3) | None | Not Started |
| 64 | Derive decision values locally from probability evidence | [64-derive-decision-values-locally-from-probability-evidence.md](../plans/64-derive-decision-values-locally-from-probability-evidence.md) | EP-63 | None | Not Started |
| 65 | Calibrate decision settings with a ReAnchor optimizer | [65-calibrate-decision-settings-with-a-reanchor-optimizer.md](../plans/65-calibrate-decision-settings-with-a-reanchor-optimizer.md) | EP-64 | EP-66 | Not Started |
| 66 | Request probability evidence from generative models | [66-request-probability-evidence-from-generative-models.md](../plans/66-request-probability-evidence-from-generative-models.md) | EP-64 | None | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled. The IR-10 row mirrors the Baikai record's `status` field, which is authoritative (`proposed`, `accepted`, `completed`).


## Dependency Graph

IR-10 is Baikai work and runs on Baikai's schedule. EP-63 does not wait for it to start. EP-63 milestone 1 needs only today's Baikai. It covers the types, the schema, the pure derivation with default settings, state rendering, and the typed refusal of non-decision outputs. Wiring evidence out of a `Response` needs IR-10's `AssistantData` content variant. That covers the `evidenceOf` wiring and the cache round-trip in milestone 2, and the loopback-HTTP route to a real `jev-*` model in milestone 3. Before IR-10 is released, milestone 2 may proceed against a Baikai checkout that has merged IR-10's content types, supplied through the gitignored `cabal.project.local`. Otherwise it waits. EP-63 must not invent a Shikumi-private evidence carrier in the meantime.

EP-64 hard-depends on EP-63 because it parameterizes the decoder and types EP-63 defines. Precisely, EP-64's first milestone (settings types and pure derivation) needs only EP-63 milestone 1. Its later milestones apply settings inside decoding, so they need EP-63 milestone 2. EP-65 and EP-66 both hard-depend on EP-64. EP-65 searches the settings EP-64 serializes. EP-66 routes evidence into EP-64's derivation, so the same settings apply on both backends. EP-65 and EP-66 can proceed in parallel. EP-65 benefits from EP-66, because it can then be demonstrated on a generative stub as well as a System One stub, but it does not require it.

Recommended order: IR-10 filed (done at plan creation); EP-63 milestone 1; EP-64's pure settings and derivation milestone; the IR-10 content types; EP-63 milestones 2–3; the remainder of EP-64; then EP-66 and EP-65 in parallel. EP-66's decoding reads JSON text from generative models, so it does not need `AssistantData`. It can therefore run ahead of EP-63 milestone 2 if IR-10 stalls.


## Integration Points

**Decision types and evidence (`Shikumi.Decision`, new, in the core `shikumi` package).** EP-63 defines them:

- `Noul`, `Choice a`, `Score levels`;
- the evidence records `NoulEvidence`, `ChoiceEvidence` and `ScoreEvidence`;
- the `DecisionOutputs o` class.

EP-64 adds the settings types and replaces EP-63's fixed defaults with settings lookup. It must not change the evidence records' JSON shape. EP-66 produces the same evidence records from generative JSON and must not define a parallel type.

**Reconciled names.** Child plans were drafted in parallel and then reconciled against the names below. Implementers rename in all affected plans together if the landed code differs.

EP-63 defines these in `Shikumi.Decision`:

- **Rich result types.** `NoulWith t f` (with `type Noul = NoulWith "" ""`), `Choice a` (options via `ChoiceOptions a`), and `Score levels`.
- **Evidence records.** `NoulEvidence { pTrue }`, `ChoiceEvidence { probabilities :: Map Text Double, confidence }`, `ScoreEvidence { levelProbabilities :: Vector Double, confidence }`, and the per-field wrapper `FieldEvidence`.
- **Field metadata.** `Judgment { judgmentField, judgmentInstruction, judgmentKind }` with `JudgmentKind = JudgeBoolean | JudgeChoice | JudgeOrdered`. `judgmentsInSchema :: Value -> ([Judgment], [Text])` works for any output type, including bare `Bool` and enum fields. `IsDecision`, `DecisionOutputs` and `judgmentsOf` are the compile-time System One guarantee only.
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

**The judgment schema convention.** EP-63 owns it: `Shikumi.Schema` instances for the decision types. The shapes are:

- a boolean;
- `anyOf` of `const` branches with per-branch `description` for Choice;
- an integer `anyOf` of `const` values `0..n-1` with level descriptions for Score.

This must match the convention IR-10's provider reads, which is DSPy's `lm15` convention. EP-66 derives its *evidence* schema (probabilities per key) from the same metadata, through a function EP-63 exports rather than by re-deriving it.

**The routing capability.** EP-63 adds `DecisionOnly` to `Shikumi.Adapter.ModelCapability` and extends `capabilityFor` and `Shikumi.Routing.translateForWire`. The reserved metadata key for the rendered state (`shikumi.decision.state`) is defined in `Shikumi.Adapter` next to the existing `shikumi.*` keys and stripped before transport like them. EP-66 adds a second key for evidence-mode generative requests in the same place. When IR-10 lands, EP-63 switches `capabilityFor` to Baikai's capability predicate instead of matching provider names.

**`Params` (`shikumi/src/Shikumi/Program.hs`).** EP-64 alone adds the per-field decision settings. It must hand-write `FromJSON Params` so documents without the field still decode (ADR-8). EP-65 only reads and writes that field through EP-64's accessors.

**The response cache and trace replay** (`shikumi-cache/src/Shikumi/Cache/ResponseJSON.hs`, the `shikumi-trace` replay). EP-63 must prove that a `Response` carrying `AssistantData` round-trips through the cache codec. EP-64 must prove that changing a setting produces a cache hit, not a new call.

**Fixtures.** Per ADR-9, EP-63 adds decision fixtures and a System One stub responder to `shikumi-testing`; later plans extend them.

Candidate ADRs, to be written when implemented, not now:

- decision values are always derived locally from evidence and never copied from a provider's pick;
- decision settings are serialized `Params`, excluded from request identity;
- System One routing refuses non-decision outputs rather than falling back.


## Progress

Phase 1 is filed in Baikai as IR-10 with status `proposed`. No Shikumi child plan has started. EP-63 milestone 1 is implementable now; its milestones 2–3 wait on IR-10's content types. Open cross-plan gates:

- [ ] Integration gate: IR-10 released, and `shikumi` builds against the published `baikai-typesafe` without `cabal.project.local` overrides.


## Surprises & Discoveries

(None yet.)


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


## Outcomes & Retrospective

(To be filled during and after implementation.)
