---
id: 66
slug: request-probability-evidence-from-generative-models
title: "Request probability evidence from generative models"
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

# Request probability evidence from generative models

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

After this change a Shikumi program with *decision outputs* works on ordinary generative models, not only on TypeSafe's System One models. A decision output is a yes/no judgment (`Noul`), a choice among declared labels (`Choice`), or a rating on declared ordered levels (`Score`). Examples of generative models are OpenAI Chat Completions, OpenAI Responses and Anthropic Messages, plus any model that only understands the marker prompt format. The model is asked to report a probability distribution for each decision field instead of a bare answer. Shikumi then derives the answer locally, with the same per-field threshold, cuts and weights that apply when the evidence comes from Jev.

The practical result is that one `Program i o` runs unchanged against `jev-latest` or against a generative model. Both return identically typed results with probability evidence attached, and a calibration fitted on one backend is expressed in the same settings on the other. Users with no TypeSafe account can use decision outputs and the ReAnchor-style calibration optimizer on the models they already have.

To see it working, run the offline test suite (see Validation and Acceptance). A stubbed native model and a stubbed marker-format model each answer the same three-field decision signature with evidence JSON. The decoded result has the expected `value`, `level` and chosen label. Changing a threshold in `Params` changes the derived answer without a second model call.


## Progress

- [ ] Milestone 1: evidence-mode rendering. For a signature whose output type contains decision fields, `runPredict` stamps an evidence-mode request: an evidence JSON schema, a system prompt that embeds each field's question, and demos moved into the instructions. Pure rendering tests pass for both the native and marker shapes.
- [ ] Milestone 2: evidence decoding. Generative evidence JSON, from a native JSON body or from marker sections, is validated, turned into EP-63's evidence records, and derived through EP-64's settings. Offline stub tests pass for both shapes, including the typed-error cases.
- [ ] Milestone 3: opt-in for native fields, backend parity and cache reuse. Bare `Bool` and enum outputs switch to evidence mode only when their field has a decision-settings entry. A parity test shows the Jev stub and a generative stub producing equal results for equal evidence. A cache test shows that a threshold change reuses the cached response.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Evidence mode is decided from the output type and `Params`, never from the model. `runPredict` stamps both the System One state (EP-63) and the generative evidence-mode render, and the router picks one once the real model is known.
  Rationale: `runPredict` is deliberately model-agnostic. It renders against a placeholder model, and `Shikumi.Routing.translateForWire` specializes the request later. That design is described in Context and Orientation.
  Date: 2026-09-26

- Decision: Probabilities reported by a generative model must each be finite and in [0, 1], and the keys must be exactly the declared ones. Anything else is a typed error, and nothing is repaired. The distribution is *not* required to sum to 1, because EP-64's derivations normalize by the total mass.
  Rationale: This matches DSPy 3.4.0 and TypeSafe's own client. A model's self-reported numbers are evidence to be checked, not trusted, but rejecting near-1 sums would fail most real replies.
  Date: 2026-09-26

- Decision: Labeled demonstrations are rendered as a JSON "Task examples (labels or evidence)" block appended to the instructions, and never as assistant turns.
  Rationale: A demo usually has a bare label such as `false` or `"billing"`, not a distribution. Rendering it as an assistant turn would force Shikumi to fabricate evidence the model then imitates. DSPy made the same choice.
  Date: 2026-09-26


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

**What a decision output is.** The types come from EP-63 ([63-declare-decision-outputs-and-route-them-to-system-one-models.md](63-declare-decision-outputs-and-route-them-to-system-one-models.md)); the settings and derivation from EP-64 ([64-derive-decision-values-locally-from-probability-evidence.md](64-derive-decision-values-locally-from-probability-evidence.md)). Both plans must be complete before this one starts. The three decision kinds are:

- **Noul.** A yes/no answer. Its evidence is the single number P(true). The value is `P(true) >= threshold`, with a default threshold of 0.5.
- **Choice.** One of a declared set of labels, each with an optional description. Its evidence is a probability per label plus a confidence. The value is the label maximizing `probability * weight`.
- **Score.** One of 2 to 10 ordered levels with descriptions, numbered 0 to N−1. Its evidence is a probability per level index plus a confidence. The continuous value is `Σ i·p_i / Σ p_i`, and the level is the number of *cuts* at or below that value.

The threshold, weights and cuts are *per-field decision settings*. EP-64 stores them in `Params` (`shikumi/src/Shikumi/Program.hs`), the per-node overlay that already holds an instruction override and demos. Deriving the answer from the evidence always happens locally in Shikumi, never on the provider.

**Assumed interface names.** This plan relies on the following names from EP-63 and EP-64. The implementer must reconcile them with what those plans actually shipped, and update this section and the code together.

- From EP-63, in module `Shikumi.Decision`:
  - the types `Noul`, `Choice a` and `Score levels`;
  - the evidence records `NoulEvidence { pTrue }`, `ChoiceEvidence { probabilities :: Map Text Double, confidence }` and `ScoreEvidence { levelProbabilities :: Vector Double, confidence }`, wrapped per field in `FieldEvidence`;
  - the field metadata `Judgment { judgmentField, judgmentInstruction, judgmentKind }`, where `JudgmentKind = JudgeBoolean … | JudgeChoice [(Text, Maybe Value)] | JudgeOrdered [Value]` carries the ordered answer keys and criteria;
  - `judgmentsInSchema :: Value -> ([Judgment], [Text])`, applied to `deriveSchema @o`. Use this rather than `judgmentsOf`, which requires `DecisionOutputs o` and so excludes bare fields;
  - `questionJSON :: Judgment -> Value`, which renders the same question object that goes to Jev;
  - `metaDecisionStateKey = "shikumi.decision.state"` in `Shikumi.Adapter`.

  Bare `Bool` and nullary-enum fields appear in `judgmentsInSchema` as ordinary boolean and choice judgments. A field is *native* when its schema lacks EP-63's private `x-shikumi-decision` marker; the rich `Noul`/`Choice`/`Score` types carry that marker.
- From EP-64:
  - the settings lookup `decisionSettingFor :: Text -> Params -> Maybe DecisionSetting`;
  - a shared per-field derivation, assumed to be `deriveField :: Judgment -> Maybe DecisionSetting -> FieldEvidence -> Either ShikumiError Value`. It returns the field's JSON exactly as the output type's `FromModel` instance expects. The System One path already uses it, and this plan must reuse it rather than write a second derivation.

**How a `Predict` node reaches the wire today.** `runPredict` (`shikumi/src/Shikumi/Program.hs`, around line 338) renders a request without knowing the real model:

1. It applies the node's `Params` through `effectiveSignature` (same file, around line 478).
2. It renders the marker-format prompt with `adapterFor placeholderModel`.
3. It stamps the alternatives the router may need into the request's private `Options.metadata` map:
   - the derived JSON schema, through `attachSchema` under `metaResponseSchemaKey` (`"shikumi.responseSchema"`);
   - the native system prompt and JSON demo turns, through `attachNativeRender` under `metaNativePromptKey` and `metaNativeDemosKey`, computed by `nativeRenderPieces`.

   These are in `shikumi/src/Shikumi/Adapter.hs`, lines 212–265.

Later, `Shikumi.Routing.translateForWire` (`shikumi/src/Shikumi/Routing.hs`, around line 119) sees the real model:

- If `capabilityFor` (`Shikumi/Adapter.hs:190`) says `NativeSchema`, it turns the stamped schema into a strict `JsonSchema` response format and swaps in the native prompt and demos.
- If it says `PromptFallback`, it leaves the marker context alone.
- Either way it strips every reserved `shikumi.*` key before transport.

EP-63 adds a third capability, `DecisionOnly`, for System One models, along with the `shikumi.decision.state` stamp.

On the way back, `parseResponse` (`Program.hs`, around line 372) looks at the body. If it parses as JSON it uses `nativeAdapter`'s parser (`Adapter.hs:278`), which runs `assistantJSON` and then `fromModelChecked`. Otherwise it uses `fallbackAdapter` (`Adapter.hs:294`), which splits `[[ ## field ## ]]` sections and coerces each one against the derived schema with `sectionsToObject` (`Adapter.hs:516`). Coercion is schema-driven, so a section whose schema property is an object is parsed as JSON. Milestone 1 must confirm this with a test and not assume it.

**How DSPy 3.4.0 does this.** The reference is `mori://stanfordnlp/dspy` at tag `3.4.0`, file `dspy/adapters/decision.py`. It is not registered in the local Mori registry, so the artifact-level URI is pending. The facts this plan copies:

- Each decision output field's type is replaced with a closed *evidence* type:
  - For a Noul it is `{"noul": p}`.
  - For a Choice or Score it is `{"probabilities": {<key>: p, …}, "confidence": c}`. A Choice uses its labels as keys; a Score uses `"0"` … `"N-1"`. Extra keys are forbidden.
  - Every `p` and `c` is constrained to [0, 1].
- The field's description is replaced with the pretty-printed JSON *question* (`type`, `instructions`, `criteria`), the same object Jev receives, so the criteria reach the model through the output-field instructions.
- Demonstrations are appended to the signature instructions as `"\n\nTask examples (labels or evidence):\n" + <json array of demo objects>`, and the adapter is given no demo turns.
- Bare `bool` and `Literal` outputs keep ordinary generation unless the field has an explicit per-field settings entry. Rich decision types always use evidence mode.
- Nested decision types (in lists or maps) are not evidence-decoded.
- Streaming is refused.

**Relevant ADRs.**

- [ADR-9](../adr/0009-centralize-offline-harness-and-diverse-fixtures.md) puts reusable stub interpreters and fixtures in the internal `shikumi-testing` package, so the evidence-response builders added here go there. Its stub interpreters include `runStubLLM`, `runScriptLLM` and `captureLLMRequests` in `shikumi-testing/src/Shikumi/Testing/StubLLM.hs`, and response builders such as `mkTextResponse` and `markerResponse` in `shikumi-testing/src/Shikumi/Testing/Response.hs`.
- [ADR-12](../adr/0012-apply-request-defaults-before-cache-and-observation.md) fixes the request order: routing, then default filling, then cache and trace observation, then metadata stripping and transport. It also excludes schemas and private metadata from the defaults vocabulary. So the evidence stamps below must survive `withRequestDefaults` untouched, and must be stripped only in `translateForWire`, like the existing keys.

No ADR covers decision outputs yet.


## Plan of Work

### Milestone 1: evidence-mode rendering

**Scope.** Add a notion of an *evidence request* to the rendering path. At the end, a pure function renders a decision signature into an evidence-mode request for both wire shapes, and `runPredict` stamps it. No decoding changes yet.

**Deciding which fields are in evidence mode.** In `shikumi/src/Shikumi/Adapter.hs`, add `evidenceFields :: forall o. ToSchema o => Map Text DecisionSetting -> [Judgment]` (it takes the `decisionSettings` map, not `Params`, because `Shikumi.Program` imports `Shikumi.Adapter` and the reverse import would be a cycle). It selects:

- every rich decision field (`Noul`, `Choice`, `Score`);
- every native `Bool` or enum field for which the settings map has an entry for the field name.

When the result is empty, rendering is byte-for-byte what it is today. That no-op must hold: existing golden and adapter tests must pass unchanged.

**The evidence schema.** Add `evidenceSchema :: Value -> [Judgment] -> Value`. It takes the ordinary derived schema from `deriveSchema @o` and replaces the property of each evidence field:

- a Noul becomes `{"type":"object","properties":{"noul":{"type":"number","minimum":0,"maximum":1,"description":"Probability that the answer is true."}},"required":["noul"],"additionalProperties":false}`;
- a Choice or Score becomes an object with a `probabilities` object and a `confidence` number. `probabilities` has one required number property per declared key and `additionalProperties: false`. The `confidence` number is also in [0, 1].

Keep the property order of the original schema. Build the schema from `Judgment`, never by re-deriving the answer space, so it cannot drift from the schema Jev sees.

**The field description.** In both the native output guide (`nativeOutputGuide`, `Adapter.hs:389`) and the marker guide (`fallbackOutputGuide`, `Adapter.hs:396`), an evidence field's description becomes the pretty-printed `questionJSON judgment`. The guide also states that each probability is between 0 and 1 and that the Choice and Score probabilities should sum to one.

**Demos.** When at least one field is in evidence mode:

- the node's demos are removed from the demo turns, for both the marker demo messages and `nativeRenderPieces`'s JSON demo list;
- they are appended to the system header as `Task examples (labels or evidence):` followed by a JSON array. Each element is the demo's input and output objects merged, containing only signature fields.

A demo output whose decision field holds a rich value keeps its JSON (value plus evidence); a bare label stays bare. Never fabricate a distribution.

**Stamping.** In `runPredict`, when `evidenceFields` is non-empty:

- stamp `evidenceSchema` in place of the plain schema under `metaResponseSchemaKey`;
- stamp the evidence-mode native prompt under `metaNativePromptKey`, with an empty native demo list;
- make the marker-format context the evidence-mode marker context;
- add a new reserved key, `metaDecisionEvidenceKey = "shikumi.decision.evidence"`, defined in `Adapter.hs` next to `metaDecisionStateKey`. Its value is the JSON list of evidence field names and kinds.

`translateForWire` must add the new key to its strip list. It must also refuse, with a typed `ValidationFailure`, a streaming LLM operation that carries the key, because evidence cannot be decoded from a partial stream. EP-63's `DecisionOnly` branch keeps using the state stamp and ignores the evidence stamps. For every other capability the existing logic applies unchanged, because the evidence alternatives were stamped into the same keys.

**Acceptance.** Add `shikumi/test/DecisionEvidenceRenderSpec.hs` with these tests:

- A three-field signature (a Noul, a three-label Choice with descriptions, a three-level Score) plus one free-form `Text` field renders a native request. Its `responseFormat` schema has the evidence objects for the three decision fields and a plain string for the `Text` field.
- The marker render contains the question JSON under each decision field.
- A node with one labeled demo has no demo turns, and its system text contains the `Task examples` block.
- A signature with only a bare `Bool` field and no settings renders exactly as before, compared against the current rendering function's output.
- The marker coercion claim holds: `sectionsToObject` over the evidence schema turns the section text `{"noul": 0.8}` into a JSON object, not a string. If it does not, fix `sectionToValue` for object-typed properties and record the finding in Surprises & Discoveries.

### Milestone 2: evidence decoding

**Scope.** Decode what the generative model returns into the typed output. At the end, a stubbed native model and a stubbed marker model both produce correct `Noul`, `Choice` and `Score` values.

**Where the change goes.** Change `parseResponse` in `Program.hs`. When `evidenceFields` for the effective `Params` is non-empty:

1. Obtain the raw JSON object, using the same body-shape detection as today. For the native shape it comes from `assistantJSON`. For the marker shape it comes from `sectionsToObject` over the evidence schema.
2. For each evidence field, validate the reported JSON and build EP-63's evidence record. The validation rules are:
   - The value must be an object with exactly the declared keys. For a Noul that is `noul`. For a Choice or Score it is `probabilities` and `confidence`, and the keys of `probabilities` must be exactly the declared answer keys.
   - Every probability and confidence must be a finite number in [0, 1]. JSON has no NaN, but an out-of-range or non-numeric value, or a missing or extra key, fails.
   - Score keys are the strings `"0"` … `"N-1"`; they are converted to level indices.

   Failures use the existing `ShikumiError` constructors with a field path: `SchemaMismatch` for shape and key errors, and `ValidationFailure` for range errors. Do not require the distribution to sum to 1, and do not renormalize here. EP-64's derivation divides by the total mass and raises its own typed error when the effective mass is zero. A Noul's confidence is never taken from the model; EP-64 derives it from the distance to the threshold.
3. Call EP-64's `deriveField` with the field's settings to obtain the field's final JSON, and substitute it into the object.
4. Run the ordinary `fromModelChecked` on the rewritten object, so non-decision fields and `Validatable` rules behave as today.

**Test fixtures.** Put the evidence reply builders in `shikumi-testing/src/Shikumi/Testing/Response.hs`, as ADR-9 requires:

- `evidenceJSONResponse :: [(Text, Value)] -> Response` builds a native JSON body;
- `evidenceMarkerResponse :: [(Text, Value)] -> Response` builds marker sections whose text is the encoded evidence.

Also add a shared decision fixture signature to `shikumi-testing/src/Shikumi/Testing/Fixtures.hs`, extending the one EP-63 added rather than copying it.

**Acceptance.** Add `shikumi/test/DecisionEvidenceSpec.hs`.

The positive tests run the fixture program under `routeLLM` with an OpenAI Chat Completions model over `runStubLLM`, which is the native shape. They also run it under an un-routed or `PromptFallback` model, which is the marker shape. Both are given the evidence:

- `urgent`: `{"noul": 0.83}`;
- `category`: `{"probabilities": {"billing": 0.2, "technical": 0.7, "account": 0.1}, "confidence": 0.9}`;
- `severity`: `{"probabilities": {"0": 0.1, "1": 0.3, "2": 0.6}, "confidence": 0.8}`.

Both must decode:

- `urgent` to value `True` with probability 0.83;
- `category` to `"technical"`;
- `severity` to value 1.5 and level 1, using the default cuts `[0.5, 1.5]`.

The negative tests each expect a typed error naming the field:

- a probability of 1.2;
- a missing `"account"` key;
- an extra key;
- a string in place of a number;
- a Choice whose only non-zero option has weight 0, which is EP-64's zero-mass error.

### Milestone 3: opt-in for native fields, parity and cache reuse

**Scope.** Prove the cross-backend promise.

**Tests to add.**

- **Native opt-in.** A program whose output has a bare `Bool` field decodes ordinarily from `{"flag": true}` while its `Params` has no settings for `flag`. After a `NoulSetting 0.7` is inserted, the same program sends an evidence schema and decodes `{"flag": {"noul": 0.65}}` to `False`.
- **Parity.** Run the fixture program once against EP-63's System One stub responder and once against the generative stub, with the same underlying probabilities, and assert the two decoded outputs are equal. The only exception is Choice and Score `confidence`, which is backend-reported. Give it the same number in both stubs.
- **Cache reuse.** Compose the in-memory cache from `shikumi-cache` below `routeLLM` and above a counting stub (`runCountingLLM`). Run once, change only the Noul threshold in `Params`, run again, and assert that the derived value changed while the call count stayed at 1. This holds because settings are never part of the request.

Finally, update the decision-types section of the user documentation EP-63 created, or `README.md` if EP-63 put it there. Describe the generative path, the evidence shapes, how demos are rendered, and the bare-field opt-in.


## Concrete Steps

Run all commands from the repository root, `/Users/shinzui/Keikaku/bokuno/shikumi`.

Before starting, confirm that EP-63 and EP-64 are complete and reconcile the assumed names:

```bash
grep -n "judgmentsOf\|questionJSON\|NoulEvidence\|metaDecisionStateKey" -r shikumi/src
grep -n "decisionSettingFor\|deriveField\|DecisionSetting" -r shikumi/src
```

Build and run the focused suites while working:

```bash
cabal build shikumi shikumi-testing
cabal test shikumi-test --test-options='-p DecisionEvidence'
```

The expected shape of a passing run:

```text
DecisionEvidenceRender
  native evidence schema:             OK
  marker question json:               OK
  demos become task examples:         OK
  bare Bool unchanged without opt-in: OK
DecisionEvidence
  native shape decodes:               OK
  marker shape decodes:               OK
  rejects out-of-range probability:   OK
...
All N tests passed
```

Before each commit, run the full gate:

```bash
just test
just check-adr
```

Commits follow Conventional Commits and carry the trailers:

```text
feat(decision): request probability evidence from generative models

MasterPlan: docs/masterplans/12-support-typesafe-jev-and-probability-backed-decision-outputs.md
ExecPlan: docs/plans/66-request-probability-evidence-from-generative-models.md
Intention: intention_01m3dwyjr6enwaaym2xsg39gz5
```


## Validation and Acceptance

The plan is accepted when all of the following hold:

- `cabal test shikumi-test` passes, including the new `DecisionEvidenceRenderSpec` and `DecisionEvidenceSpec`.
- Every pre-existing adapter, routing, golden and serialization test passes unmodified. This proves that programs without decision outputs render and decode exactly as before.
- The three Milestone 3 tests pass: native-field opt-in, System One versus generative parity, and a single model call across a threshold change.

The observable behaviour, stated plainly: the same decision program, given the same probabilities, yields the same typed answer whether the evidence came from Jev or from a generative model. Tuning a threshold changes answers without new model calls.

An optional live check, not part of CI, follows the existing `SHIKUMI_LIVE` gating in `shikumi/test/LiveSpec.hs`. Run the fixture program against one real native model and confirm that the reply parses as evidence. Record the outcome, including any systematic mis-formatting by the model, in Surprises & Discoveries.


## Idempotence and Recovery

All changes are additive and gated on the evidence-field set being non-empty, so a partial implementation cannot change behaviour for existing programs. The no-op tests in Milestone 1 guard this. Tests are hermetic and can be rerun freely. If Milestone 2 has to be abandoned midway, remove the evidence stamps from `runPredict` and the program falls back to today's behaviour. The rendering functions from Milestone 1 can stay, because they are pure and unused.


## Interfaces and Dependencies

This plan defines the following interfaces:

- In `shikumi/src/Shikumi/Adapter.hs`:
  - `metaDecisionEvidenceKey :: Text` (`"shikumi.decision.evidence"`), stripped by the router like every `shikumi.*` key;
  - `evidenceFields :: forall o. ToSchema o => Map Text DecisionSetting -> [Judgment]` (it takes the `decisionSettings` map, not `Params`, because `Shikumi.Program` imports `Shikumi.Adapter` and the reverse import would be a cycle);
  - `evidenceSchema :: Value -> [Judgment] -> Value`;
  - evidence-mode variants of the native and marker output guides.
- In `shikumi/src/Shikumi/Program.hs`: the evidence branch of `parseResponse` and a private `decodeEvidence :: Judgment -> Value -> Either ShikumiError Evidence`.
- In `shikumi-testing/src/Shikumi/Testing/Response.hs`: `evidenceJSONResponse` and `evidenceMarkerResponse`.

It consumes:

- EP-63's `Shikumi.Decision` types, evidence records, `judgmentsOf`, `questionJSON` and `DecisionOnly` routing;
- EP-64's `decisionSettingFor`, `DecisionSetting` and `deriveField`.

It must not define a second evidence type or a second derivation. No new package dependencies are needed. Baikai is used as it is today, and this plan has no dependency on `mori://shinzui/baikai/okf/improvement-requests/concepts/IR-10`.
