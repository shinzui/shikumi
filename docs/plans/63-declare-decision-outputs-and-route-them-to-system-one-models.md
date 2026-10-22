---
id: 63
slug: declare-decision-outputs-and-route-them-to-system-one-models
title: "Declare decision outputs and route them to System One models"
kind: exec-plan
created_at: 2026-09-26T03:43:55Z
intention: "intention_01m3dwyjr6enwaaym2xsg39gz5"
master_plan: "docs/masterplans/12-support-typesafe-jev-and-probability-backed-decision-outputs.md"
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
      note: "Noul criteria hidden in the stripped marker; defaults assumed dropped; capabilityFor and error mapping stale; wire sample pre-0.2.0; hspec flags on tasty suites"
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-10-22T03:38:28Z
      mode: "update"
      note: "Cascade Baikai reconciliation: anyOf noul criteria, DataContent evidenceOf, request-defaults exemption, isJudgmentOnly switch, compileJudgments parity, fromBaikaiError expectations"
---

# Declare decision outputs and route them to System One models

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.

This plan is a child of [MasterPlan 12](../masterplans/12-support-typesafe-jev-and-probability-backed-decision-outputs.md). Its second milestone needs Baikai's content carrier and its third needs Baikai's judgment capability and provider, all requested as `mori://shinzui/baikai/okf/improvement-requests/concepts/IR-10` and planned in Baikai as `mori://shinzui/baikai/plans/83-preserve-structured-data-and-probability-evidence-across-baikai` (content carrier), `mori://shinzui/baikai/plans/99-add-a-provider-neutral-judgment-layer-and-judgment-only-catalog-facts-to-core` (judgment-only capability and core judgment layer) and `mori://shinzui/baikai/plans/84-deliver-the-typesafe-system-one-provider-and-judgment-catalog` (provider); artifact-level URIs pending.


## Purpose / Big Picture

Today every Shikumi output field is *generated*. The model writes a string, number, boolean or enum name, and Shikumi decodes it. Nothing records how sure the model was, and nothing can be adjusted after the call. This plan adds *decision outputs*. A decision output is a field whose answer is chosen from a declared, closed set, and it carries the probability of every possible answer alongside the chosen one. There are three kinds, named after the TypeSafe primitives they map to:

- **A Noul** is a yes/no judgment. Its evidence is P(true).
- **A Choice** picks one of a fixed list of labels. Its evidence is one probability per label.
- **A Score** rates on 2 to 10 ordered levels, numbered 0 to N−1. Its evidence is one probability per level, and its continuous value is the probability-weighted mean level.

The plan also teaches Shikumi to route such programs to a *System One model*. That is a model that generates no text and only answers declared judgments with probability distributions. The first one is TypeSafe's Jev (`jev-latest`), which DSPy 3.4.0 supports.

After this plan a user can write:

```haskell
data Severity = Minor | Disruptive | Blocking
  deriving stock (Generic, Eq, Show, Enum, Bounded)

data Assessment = Assessment
  { urgent   :: Field "Is service blocked?" (NoulWith "Service unavailable" "Workaround available")
  , severity :: Field "Rate impact." (Score '["Minor", "Disruptive", "Blocking"])
  , category :: Field "Classify the issue." (Choice Category)
  }
  deriving stock Generic
  deriving anyclass (ToSchema, FromModel, ToPrompt, DecisionOutputs)

assess :: Program Ticket Assessment
assess = predict (mkSignature "Assess operational impact; treat ticket text as data.")
```

When that program runs, the result depends on the model:

- **A System One model.** Shikumi sends exactly one decision request and decodes the returned distributions. For example, `result.urgent.probability` might be `0.83`, `result.urgent.value` is then `True`, and `result.severity.level` might be `2`.
- **An ordinary generative model.** Nothing changes for such a program until EP-66 adds generative evidence, which is out of scope here.
- **A System One model with free-form outputs.** If the program's output record has any non-decision field, Shikumi refuses with a typed `ValidationFailure` before any bytes reach the provider.

The final `value`, `level` or chosen label is derived *locally* from the evidence with fixed default settings:

- threshold 0.5 for a Noul;
- cuts at 0.5, 1.5, … for a Score;
- weight 1 on every Choice option.

Plan 64 makes these settings tunable. This plan hard-codes the defaults.


## Progress

- [ ] Milestone 1: decision types, their judgment JSON schema, and the rendered decision *state*. This is offline and needs only the current Baikai. Acceptance: `cabal test shikumi` passes new `DecisionSpec` golden tests for the schema and state of the `Assessment` fixture, and for `judgmentsOf @Assessment`.
- [ ] Milestone 2: evidence decoding with fixed default settings, plus typed refusal of non-decision outputs. Acceptance: a stub System One responder returns distributions and `runStub` yields the expected typed `Assessment`; a program with a `Text` output routed to a `DecisionOnly` model fails with `ValidationFailure` and the stub records zero calls; a response carrying evidence round-trips through the response cache codec. Requires Baikai EP-83's content types (`UserData`, `AssistantData`), as the note in Plan of Work explains.
- [ ] Milestone 3: route a real `jev-*` model through the released `baikai-typesafe` provider against a loopback HTTP fixture, switch `capabilityFor` to Baikai's `isJudgmentOnly`, and exempt judgment-only models from request defaults. **Blocked on Baikai EP-99 (capability and judgment layer), Baikai EP-84 (provider) and the Hackage release of `typesafe-hs`.** Acceptance: the fixture observes the systemone payload Baikai EP-84 specifies, the program returns the typed result, a routed call with request defaults configured is not refused, and `judgmentsInSchema` agrees with `Baikai.Judgment.compileJudgments` on the fixture.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Detect judgments from the stamped JSON schema at routing time, in the same way DSPy's `lm15` reads a `json_schema`, instead of adding a `DecisionOutputs o` constraint to `Shikumi.Program.runPredict`.
  Rationale: `runPredict` renders model-agnostically and the real model is only known in `Shikumi.Routing.routeLLM`. Adding a class constraint to every `Predict` node would ripple through every combinator. The `DecisionOutputs` class still exists, as an opt-in compile-time guarantee for programs meant only for System One models.
  Date: 2026-09-26

- Decision: Refuse a non-decision output on a `DecisionOnly` model with the existing terminal `ShikumiError` constructor `ValidationFailure`, rather than adding a new constructor.
  Rationale: Adding a constructor to `ShikumiError` would break every exhaustive match downstream. [ADR-12](../adr/0012-apply-request-defaults-before-cache-and-observation.md) already uses `ValidationFailure` for terminal configuration errors raised before dispatch, and [ADR-11](../adr/0011-preserve-provider-errors-and-centralize-retry-policy.md) keeps it non-retryable.
  Date: 2026-09-26

- Decision: Mark decision fields in the schema with a private annotation key, `x-shikumi-decision`, and strip it in `translateForWire` before transport.
  Rationale: Jev's convention treats a plain `Bool` and a `Noul` alike, since both are `"type": "boolean"`. The decoder, however, must know whether to produce a bare `Bool` or rich evidence. Stripping the key keeps strict provider schema validation (OpenAI `strict: true`) unaffected.
  Date: 2026-09-26

- Decision: Noul criteria are ordinary schema, not marker content. `NoulWith t f` with at least one non-empty criterion emits `{"type": "boolean", "anyOf": [{"const": true, "description": t}, {"const": false, "description": f}]}`; with none it emits a plain `{"type": "boolean"}`. The `x-shikumi-decision` marker carries only `{"kind": …}`. This supersedes the criteria placement implied by the previous entry.
  Rationale: The marker is stripped before transport, so criteria placed there would never reach Baikai. Baikai's `Baikai.Judgment.compileJudgments` reads noul criteria exactly from `anyOf`/`oneOf` branches of `const true` and `const false` with descriptions, and TypeSafe's OpenAPI 0.2.0 documents the optional `criteria` object the provider sends from them.
  Date: 2026-10-21

- Decision: Judgment-only models are exempt from request defaults. `withRequestDefaults` in `Shikumi.LLM.Defaults` leaves `thinking`, `speed` and `maxTokens` untouched when `isJudgmentOnly` holds for the routed model (interim: provider `typesafe`), and still fills `evidence`. Explicit controls, including a stamped per-sample temperature, pass through and are refused by Baikai as a typed error.
  Rationale: Baikai's judgment providers refuse every explicit generation control instead of dropping it, and the defaults layer runs after routing, so a filled default would make every Jev call fail. Defaults are Shikumi's additions, so withholding them is not a silent fallback. ADR-12 is amended when this lands.
  Date: 2026-10-21


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Shikumi is a Haskell framework for typed language-model programs. The repository root holds one directory per Cabal package. The ones this plan touches are:

- `shikumi/`, the core package;
- `shikumi-testing/`, the internal offline test harness;
- `shikumi-cache/`, the response cache;
- `shikumi-tools/`, which hosts HTTP-level provider tests.

Provider transport comes from the separate library Baikai (`mori://shinzui/baikai`; find its source with `mori registry show shinzui/baikai --full`).

**How a prediction runs today.** `Shikumi.Module.predict` (`shikumi/src/Shikumi/Module.hs:63`) builds a `Predict` node. The executor `Shikumi.Program.runPredict` (`shikumi/src/Shikumi/Program.hs`, around line 335) handles that node in five steps:

1. It applies the node's `Params` (instruction override and demos).
2. It renders a prompt with `adapterFor placeholderModel`. The placeholder always selects the text "marker" format.
3. It stamps three items onto the private metadata map `Options.metadata`, under reserved `shikumi.*` keys defined in `shikumi/src/Shikumi/Adapter.hs` around lines 205–234 (for example `metaResponseSchemaKey = "shikumi.responseSchema"`):
   - the output's JSON schema (`attachSchema (deriveSchema @o)`);
   - a native-format system prompt;
   - native-format demos.
4. It calls the `LLM` effect's `complete placeholderModel ctx opts`.
5. It decodes the reply with `parseResponse`.

`parseResponse` decides the reply's shape from the body. If the assistant text (`Shikumi.Adapter.assistantJSON`) parses as JSON, it takes the native JSON path; otherwise it takes the marker path.

**Routing.** `Shikumi.Routing.routeLLM` (`shikumi/src/Shikumi/Routing.hs:98`) intercepts each `LLM` call, replaces the placeholder with the ambient real `Baikai.Model.Model`, and calls `translateForWire` (same file, around line 119). `translateForWire` reads the stamps. For models where `Shikumi.Adapter.capabilityFor` (`shikumi/src/Shikumi/Adapter.hs:190`) returns `NativeSchema`, it:

- sets `Options.responseFormat` to `JsonSchema` with `strict = True`;
- swaps in the native system prompt and demos.

For every model it then removes the four reserved keys (schema, temperature, native prompt, native demos). Per [ADR-14](../adr/0014-separate-schema-enforcement-from-tool-calling-capability.md), `capabilityFor` is derived from Baikai's `declaredStructuredOutput` for the model's `api`: it returns `NativeSchema` when Baikai declares `NativeJsonSchema` and the model is either a CLI transport or a first-party HTTP host (`openai` over Chat Completions or Responses, `anthropic` over Messages), and `PromptFallback` otherwise. The `DecisionOnly` branch this plan adds is tested before that derivation.

**Request defaults.** `Shikumi.LLM.Defaults.withRequestDefaults` (`shikumi/src/Shikumi/LLM/Defaults.hs`) interposes on the `LLM` effect after `routeLLM`, so it sees the real model, and fills absent `thinking`, `speed`, `maxTokens` and `evidence` from an invocation-scoped `RequestDefaults`. [ADR-12](../adr/0012-apply-request-defaults-before-cache-and-observation.md) fixes that order. Baikai's judgment providers refuse every explicit generation and reasoning control, so this plan exempts judgment-only models from the first three defaults (milestone 3) and amends ADR-12.

**Schemas.** `Shikumi.Schema.ToSchema` (`shikumi/src/Shikumi/Schema.hs:68`) derives a JSON schema from a record generically:

- `Field "description" a` (in `shikumi/src/Shikumi/Schema/Types.hs`) attaches a description to a record field;
- a sum of nullary constructors becomes a string `enum` of constructor names, through `GEnumNames` (`Schema.hs` around line 157).

`Shikumi.Schema.FromModel` decodes a JSON `Value` totally, reporting a located `ShikumiError` on failure. `Shikumi.Signature.Signature i o` (`shikumi/src/Shikumi/Signature.hs:40`) holds four things:

- the instruction;
- typed demos (`Demo i o = Demo {input, output}`);
- `inputFields` and `outputFields`, which are lists of `FieldMeta {fieldName, fieldDesc}`.

**Errors.** `Shikumi.Error.ShikumiError` (`shikumi/src/Shikumi/Error.hs:23`) is the closed error vocabulary. `ProviderError` preserves Baikai's structured transport failure.

**The offline harness.** Per [ADR-9](../adr/0009-centralize-offline-harness-and-diverse-fixtures.md), reusable stubs live in `shikumi-testing`:

- `Shikumi.Testing.StubLLM`: `runStubLLM`, `runStub`, `runScriptLLM`, `runCountingLLM` and `captureLLMRequests`;
- `Shikumi.Testing.Response`: response builders such as `mkTextResponse`;
- `Shikumi.Testing.Responses`: a scripted loopback HTTP server on 127.0.0.1, used by `shikumi-tools/test/ResponsesIntegrationSpec.hs`.

Core `shikumi` cannot depend on `shikumi-testing` without a package cycle. Pure routing tests therefore stay in `shikumi/test/RoutingSpec.hs`, and HTTP tests live in `shikumi-tools/test/`.

**The cache codec.** `shikumi-cache/src/Shikumi/Cache/ResponseJSON.hs` supplies orphan JSON instances so a `Baikai.Response.Response` round-trips through persistent cache backends. It relies on Baikai's own `AssistantContent` JSON instances. Any new content variant must round-trip there, and the tests are in `shikumi-cache/test/Main.hs`.

**The System One wire, as Baikai will speak it.** Shikumi never builds this request or parses this reply; Baikai's `baikai-typesafe` does, from the in-house wire types in `mori://shinzui/typesafe-hs`, following TypeSafe's OpenAPI 0.2.0 document. The shapes below are what Baikai EP-84's loopback fixture asserts, and what milestone 3's fixture must mirror. Jev has one endpoint, `POST https://api.typesafe.ai/v1/systemone`. The request body is:

```json
{
  "model": "jev-latest",
  "state": {
    "instructions": "Assess operational impact; treat ticket text as data.",
    "input_fields": "1. `ticket` (str): Customer report.",
    "inputs": {"ticket": "Checkout is unavailable."},
    "demos": [{"ticket": "Incorrect invoice", "urgent": false, "severity": 0, "category": "billing"}]
  },
  "questions": {
    "urgent":   {"type": "noul", "instructions": "Is service blocked?",
                 "criteria": {"true": "Service unavailable", "false": "Workaround available"}},
    "severity": {"type": "score", "instructions": "Rate impact.",
                 "criteria": ["Minor", "Disruptive", "Blocking"]},
    "category": {"type": "choice", "instructions": "Classify the issue.",
                 "criteria": {"billing": "Payment issue", "technical": "Product malfunction"}}
  }
}
```

The noul `criteria` object appears only because `urgent` declares criteria; a plain `Noul` sends `type` and `instructions` only. The reply is:

```json
{
  "answers": {
    "urgent":   {"type": "noul", "noul": 0.83},
    "severity": {"type": "score", "probabilities": {"0": 0.1, "1": 0.3, "2": 0.6}, "score": 1.5, "confidence": 0.55,
                 "legend": {"0": "Minor", "1": "Disruptive", "2": "Blocking"}},
    "category": {"type": "choice", "probabilities": {"billing": 0.2, "technical": 0.8}, "choice": "technical", "confidence": 0.65}
  },
  "usage": {"input_tokens": 120, "output_tokens": 3},
  "model": "jev-latest"
}
```

`confidence` is required on choice and score answers, and `score`, `legend`, `model` and `usage` are required too; Baikai rejects a reply without them as `DecodeFailure`. Jev has no system prompt, accepts exactly one user state, and supports no tools, media, streaming, or sampling controls. Baikai refuses a request that carries any of those with a typed `InvalidRequest` before any bytes are sent, and it refuses explicit generation controls (`maxTokens`, `temperature`, `topP`, stop sequences, `seed`, penalties, `thinking`, non-standard `speed`, non-trivial cache retention) the same way. Baikai's core module `Baikai.Judgment` (`compileJudgments`, Baikai EP-99) reads the questions from the `JsonSchema` response format. Baikai orders `Judgments` by the schema's `required` array when it lists every declared property exactly once, and by ascending key otherwise, because aeson objects do not keep declaration order (Baikai EP-99 Decision Log, 2026-10-22). Shikumi's `deriveSchema` already lists every field in `required` in declaration order (`shikumi/src/Shikumi/Schema.hs`, around line 111), so both readers see declaration order. A top-level property is a judgment when it has one of three shapes:

- **Yes/no:** `"type": "boolean"`, optionally written as an `anyOf` or `oneOf` of `{"const": true, "description": …}` and `{"const": false, "description": …}` branches whose descriptions become the noul criteria.
- **Choice:** a string `anyOf` of `{"const": label, "description": …}` branches, or a string `enum`, 1 to 255 labels in declared order.
- **Ordered score:** an integer `anyOf` of `const` values that is exactly `0..n-1`, 2 to 10 levels, with descriptions as the level criteria.

The property's `description` becomes the question's `instructions`, defaulting to the property name when absent. Any other property is free-form, and the request is refused. The reply comes back as one `AssistantData DataContent` part (Baikai EP-83): `value` holds Baikai's base chosen answers (a boolean at p ≥ 0.5, the provider's declared choice, the provider's expected score as a number), `probabilities` holds one distribution per field keyed by `true`/`false`, the labels, or the decimal level indices, `confidence` holds the provider's per-field confidence for choice and score fields, and `method` is `provider_classification`. The judgment-only capability is `Baikai.Model.isJudgmentOnly`, a pure function over the catalog-carried `outputKind` (Baikai EP-99); the API tag is `TypeSafeSystemOne` and the catalog provider name is `typesafe`, both also Baikai EP-99; the `baikai-typesafe` package itself is Baikai EP-84. Shikumi's `fromBaikaiError` (`shikumi/src/Shikumi/Error.hs`) maps Baikai's `InvalidRequest` to `SchemaMismatch` and `DecodeFailure` to `InvalidJSON`, both terminal; Baikai's typed `RequestProblem` detail is not preserved by that mapping.

**Relevant ADRs.**

- [ADR-9](../adr/0009-centralize-offline-harness-and-diverse-fixtures.md) puts the new stub responder and loopback fixture in `shikumi-testing`.
- [ADR-11](../adr/0011-preserve-provider-errors-and-centralize-retry-policy.md): never classify from message text. Baikai's pre-dispatch refusal of an unsupported judgment request arrives as `InvalidRequest` and becomes a terminal `SchemaMismatch`; a malformed reply arrives as `DecodeFailure` and becomes a terminal `InvalidJSON`; everything else stays a `ProviderError`. Tests assert those constructors, not `ProviderError` for all three.
- [ADR-12](../adr/0012-apply-request-defaults-before-cache-and-observation.md): request defaults (thinking, speed, token ceiling) are filled after routing. Baikai's judgment providers refuse them, so this plan exempts judgment-only models in `Shikumi.LLM.Defaults` and amends ADR-12 in the same change.
- [ADR-14](../adr/0014-separate-schema-enforcement-from-tool-calling-capability.md): `capabilityFor` is a pure function of `Model`; the `DecisionOnly` branch keeps it that way by reading `isJudgmentOnly`.


## Plan of Work

**Milestone 1: types, schema, and state (offline).** Create `shikumi/src/Shikumi/Decision.hs`, export it from `shikumi/shikumi.cabal`, and re-export it from the top-level `Shikumi` module if that module re-exports `Shikumi.Schema`.

The module defines three evidence records. They are the only representation of probability evidence in the initiative; plans 64–66 consume them unchanged.

```haskell
data NoulEvidence   = NoulEvidence   { pTrue :: !Double }
data ChoiceEvidence = ChoiceEvidence { probabilities :: !(Map Text Double), confidence :: !(Maybe Double) }
data ScoreEvidence  = ScoreEvidence  { levelProbabilities :: !(Vector Double), confidence :: !(Maybe Double) }
data FieldEvidence  = FieldNoul NoulEvidence | FieldChoice ChoiceEvidence | FieldScore ScoreEvidence
```

All four types have `Eq`, `Show` and `Generic`, plus JSON instances. The JSON shapes are the generative evidence shapes EP-66 will ask models to produce:

- `{"noul": p}`
- `{"probabilities": {...}, "confidence": c}`
- `{"probabilities": {"0": p0, ...}, "confidence": c}`

It defines the three rich result types:

- `NoulWith (t :: Symbol) (f :: Symbol)`, with the synonym `type Noul = NoulWith "" ""`. An empty symbol means no criterion, which is sent as JSON `null`. Fields: `value :: Bool`, `probability :: Double` and `confidence :: Double`, where confidence is `abs (p - t) / max t (1 - t)` with t the threshold.
- `Choice a`, with `value :: a`, `probabilities :: Map Text Double` and `confidence :: Maybe Double`. The options come from a class `ChoiceOptions a`, whose method `choiceOptions :: [(Text, a, Maybe Text)]` lists each label, its value and its criterion. It has a `Generic` default over nullary sums that reuses the constructor names `GEnumNames` produces and gives no descriptions. Users override it to add descriptions.
- `Score (levels :: [Symbol])`, with `value :: Double`, `level :: Int`, `levelProbabilities :: Vector Double` and `confidence :: Maybe Double`. A type-family constraint rejects fewer than 2 or more than 10 levels at compile time.

It defines the judgment metadata that EP-66 consumes:

```haskell
data JudgmentKind
  = JudgeBoolean (Maybe Value) (Maybe Value)      -- true / false criteria
  | JudgeChoice  [(Text, Maybe Value)]            -- label, criterion; declaration order
  | JudgeOrdered [Value]                          -- level criteria, index = level
data Judgment = Judgment { judgmentField :: Text, judgmentInstruction :: Maybe Text, judgmentKind :: JudgmentKind }

judgmentsInSchema :: Value -> ([Judgment], [Text])   -- (judgments, free-form property names); the rules Baikai's compileJudgments applies
```

It defines a class `IsDecision a`. Its method `decisionKind :: Proxy a -> JudgmentKind` has instances for `NoulWith`, `Choice a`, `Score levels` and plain `Bool`. It then defines a class `DecisionOutputs o`, with a `Generic` default that requires every record field (seen through `Field`) to be `IsDecision`, plus `judgmentsOf :: forall o. DecisionOutputs o => [Judgment]`. A field that is not a decision produces a custom `TypeError` naming the field. `judgmentsOf` and `judgmentsInSchema` must agree on the `Assessment` fixture, and a test asserts it.

**`ToSchema` instances.** Each decision type emits the lm15 convention and a private marker, as recorded in the Decision Log:

- `NoulWith` emits `{"type": "boolean", "x-shikumi-decision": {"kind": "noul"}}` when both criteria are empty, and `{"type": "boolean", "anyOf": [{"const": true, "description": t}, {"const": false, "description": f}], "x-shikumi-decision": {"kind": "noul"}}` otherwise, with an empty criterion rendered as a `null` description. The criteria live in the branches, never in the marker, because the marker is stripped before transport and Baikai reads criteria only from the branches.
- `Choice a` emits `{"type": "string", "anyOf": [{"const": label, "description": …}], "x-shikumi-decision": {"kind": "choice"}}`.
- `Score` emits `{"type": "integer", "anyOf": [{"const": 0, "description": "Minor"}, …], "x-shikumi-decision": {"kind": "score"}}`.

The field `description` still comes from `Field` through the existing `FieldSchema` path.

**Rendering the state.** Add `renderDecisionState :: (ToPrompt i, ...) => Signature i o -> i -> Value` in `Shikumi.Decision`. It produces the `state` object shown in Context and Orientation:

- `instructions` from the signature;
- `input_fields` as numbered lines built from `inputFields`;
- `inputs` as the input record encoded to JSON;
- `demos` as a flat object per demo, merging the input and output JSON, and omitted when there are no demos.

Implement the JSON encoding of `i` with the same machinery the native adapter uses for demos. Look at `nativeRenderPieces` in `Shikumi.Program`, and reuse or extract its helper rather than writing a new encoder.

In `Shikumi.Adapter`, add the key `metaDecisionStateKey = "shikumi.decision.state"` beside the other reserved keys. Add `attachDecisionState`, and have `runPredict` call it whenever `fst (judgmentsInSchema (deriveSchema @o))` is non-empty. Do not change the marker or native rendering. Milestone 1 ends with golden tests only: no routing and no provider.

**Milestone 2: evidence decoding and refusal.**

*Capability.* Add `DecisionOnly` to `Shikumi.Adapter.ModelCapability`. Until Baikai ships `isJudgmentOnly`, `capabilityFor` returns `DecisionOnly` when `m ^. #provider == "typesafe"`, which is the provider name Baikai's catalog uses for `jev-latest` and `jev-preview`; this check runs before the `declaredStructuredOutput` derivation. Add a comment pointing at Baikai EP-99 and at the switch in milestone 3. `adapterFor` maps `DecisionOnly` to `nativeAdapter`: the rendered marker context is discarded by routing anyway, so the choice only affects un-routed runs.

*Routing.* Extend `translateForWire`, or make the router call a new effectful companion, because refusal needs `Error ShikumiError`. For a `DecisionOnly` model:

1. Compute `(js, freeForm) = judgmentsInSchema schema` from the stamped schema.
2. If `freeForm` is non-empty, or no decision state was stamped, throw `ValidationFailure` naming the model id and the offending fields, for example `"jev-latest answers only declared judgments; free-form output fields: summary"`. Throw it before calling the inner interpreter.
3. Otherwise replace the context with a single user message holding exactly one part with the state. Use a `UserData` part once Baikai EP-83's content types are available; until then a single `UserText` part holding the state encoded as JSON is acceptable, with a note in Surprises & Discoveries. Baikai refuses a scalar or `null` state, so the state is always the object `renderDecisionState` produces.
4. Drop the system prompt and leave `tools` empty; Baikai refuses both.
5. Set `responseFormat = JsonSchema` from the schema with every `x-shikumi-decision` key removed.
6. Strip all reserved keys, including `metaDecisionStateKey`.

For native models the `x-shikumi-decision` keys must also be stripped, so the same stripping helper is used on both paths.

*Decoding.* In `parseResponse`, before the JSON/marker shape detection, look for evidence on the response. `evidenceOf :: [Judgment] -> Response -> Maybe (Map Text FieldEvidence)` reads the `AssistantData DataContent` part Baikai EP-83 defines: `probabilities :: Maybe (Map Text (Map Text Double))` keyed by field and then by answer key, and `confidence :: Maybe (Map Text Double)` keyed by field. Interpreted against the schema's judgments, a boolean field's `true` key gives `NoulEvidence`, a choice field's label keys plus its confidence entry give `ChoiceEvidence`, and a score field's decimal level keys, sorted numerically, plus its confidence entry give `ScoreEvidence`. `DataContent.value` is never read into a result; a milestone 2 test only checks that Baikai's base answers in `value` agree with Shikumi's default derivation on the fixture. When evidence is present, build one JSON object per output field, as follows, and decode it with the ordinary `FromModel o`:

- A field carrying `x-shikumi-decision` gets its evidence object.
- A plain `Bool` gets `pTrue >= 0.5`.

The `FromModel` instances of the decision types decode the evidence object and derive the value with the fixed defaults:

- **Noul:** threshold 0.5.
- **Score:** `value = Σ i·pᵢ / Σ pᵢ`, and `level` = the number of cuts `[0.5, 1.5, …, n−1.5]` that are ≤ `value`.
- **Choice:** the argmax of `probability × 1.0`. Ties go to declaration order. Zero total probability mass is a `SchemaMismatch`.

The value is always derived from the probabilities, never copied from Jev's `"choice"` field. Expose three pure derivation functions. Each takes an explicit settings argument, and this plan always passes the defaults: threshold 0.5, cuts `[0.5, 1.5, …, N−1.5]`, and all weights 1.0. Plan 64 replaces the defaults with values from `Params`.

```haskell
deriveNoul   :: Double -> NoulEvidence -> (Bool, Double)                      -- threshold → (value, confidence)
deriveScore  :: [Double] -> ScoreEvidence -> Either Text (Double, Int)        -- cuts → (value, level)
deriveChoice :: Map Text Double -> ChoiceEvidence -> Either Text Text         -- weights → chosen label
```

Also export `questionJSON :: Judgment -> Value`. It renders the question object exactly as it is sent to Jev under `questions.<field>`. The routing code uses it, and EP-66 reuses it to describe evidence fields to generative models.

*Baikai EP-83 note.* `UserData` and `AssistantData DataContent` are Baikai EP-83's deliverables, landing in core `baikai` with a PVP major bump. Milestone 2's end-to-end stub test needs a `Response` that carries `AssistantData`. If EP-83 is merged in the sibling Baikai checkout but not released, build against it through the gitignored `cabal.project.local`, which already overrides the Baikai packages. If it is not merged at all, complete and test the pure parts: `judgmentsInSchema`, the `FromModel` evidence decoding from hand-built evidence objects, the derivation functions, and the refusal. Record the gap in Surprises & Discoveries, and leave the `evidenceOf` wiring and the cache round-trip for milestone 3. Do not invent a Shikumi-private evidence carrier: the MasterPlan forbids it.

*Harness.* Add `Shikumi.Testing.SystemOne` to `shikumi-testing` with three things:

- `systemOneModel :: Text -> Model`, a `Model` with `provider = "typesafe"` and, once Baikai EP-84 is available, `api = TypeSafeSystemOne` and `outputKind = JudgmentOutput` so that `isJudgmentOnly` holds;
- `systemOneResponse :: [(Text, FieldEvidence)] -> Response`;
- `systemOneResponder :: (Value -> [(Text, FieldEvidence)]) -> Context -> Response`, which decodes the state and lets a test answer per input.

Add the `Assessment` / `Ticket` fixture beside the existing fixtures in `shikumi-testing/src/Shikumi/Testing/Fixtures.hs`, per ADR-9.

*Cache.* Add a test in `shikumi-cache/test/Main.hs` asserting that `systemOneResponse` round-trips through `Shikumi.Cache.ResponseJSON` unchanged. Baikai EP-83 gives `AssistantData` its own `AssistantContent` JSON encoding and adds only named codecs (`Baikai.Response.JSON`) for whole responses, deliberately leaving Shikumi's orphan `Response` instances alone, so no orphan change is expected; if one is needed, add it there and record why.

**Milestone 3: real routing (blocked on Baikai EP-99, Baikai EP-84 and the `typesafe-hs` release).** When core `baikai` with `Baikai.Judgment` and `isJudgmentOnly` (Baikai EP-99) and `baikai-typesafe` (Baikai EP-84) are on Hackage. Baikai's core release does not wait for `typesafe-hs`, so steps 2, 4 and 5 may land as soon as core is published, with the loopback route following when the provider is:

1. Bump the Baikai bounds. The core bump is a PVP major, which `just upgrade-baikai` cannot do (it stops at the build); migrate the bounds and any source changes by hand, and run `just test` with no `cabal.project.local`.
2. Switch `capabilityFor` to `isJudgmentOnly m` instead of the provider-name match, keeping it ahead of the `declaredStructuredOutput` derivation.
3. Send the state as `UserData`.
4. Exempt judgment-only models from request defaults in `Shikumi.LLM.Defaults.withRequestDefaults`: when `isJudgmentOnly model` holds, apply only the evidence default. Add a case to `shikumi/test/RequestDefaultsSpec.hs` showing that a routed `jev-latest` call under configured thinking, speed and token-ceiling defaults reaches the stub with those three fields still `Nothing`, and that a generative model under the same defaults still has them filled. Amend ADR-12 in the same commit.
5. Add a parity test in `shikumi/test/DecisionSpec.hs`: `judgmentsInSchema` on the `Assessment` schema (markers stripped) and `Baikai.Judgment.compileJudgments` on the same schema agree on field order, kinds, labels, level count and criteria. Both order questions by the schema's `required` array when it lists every property, which Shikumi's `deriveSchema` always does, in declaration order.

Add a scripted JSON loopback fixture, `withSystemOneFixture`, to `shikumi-testing`, modelled on `Shikumi.Testing.Responses`, but as one JSON reply rather than SSE. Add `shikumi-tools/test/SystemOneIntegrationSpec.hs`. That spec registers the Baikai TypeSafe provider in an isolated registry with an explicit `Options.apiKey` (Baikai does not forward the default credential to a non-official host) and the fixture's base URL, runs `assess` under `routeLLM` with a `jev-latest` model, and asserts four things:

- the captured payload equals the request JSON in Context and Orientation, compared structurally rather than by key order, including the noul `criteria` object for `urgent`;
- the typed result matches;
- a fixture reply with an undeclared key, or with `confidence`, `score` or `legend` missing, surfaces as a terminal `InvalidJSON` (Baikai's `DecodeFailure` through `fromBaikaiError`), per ADR-11;
- a program whose stamped options carry an explicit temperature surfaces Baikai's refusal as a terminal `SchemaMismatch` with zero fixture requests.

An optional live check, not run in CI, may run the same program against `jev-latest` when `TYPESAFE_API_KEY` is set, following `shikumi/test/LiveSpec.hs`.


## Concrete Steps

Run everything from the repository root inside `nix develop`.

```bash
cabal build shikumi shikumi-testing
cabal test shikumi --test-options='-p Decision'
cabal test shikumi-cache
cabal test shikumi-tools --test-options='-p SystemOne'   # milestone 3 only
just test                                                # before each commit
```

After milestone 1, the focused run should report the new cases passing (the suites use tasty, so the pattern flag is `-p` and each case prints `OK`):

```text
Decision
  judgment schema
    Assessment schema matches golden:                        OK
    judgmentsOf agrees with judgmentsInSchema:               OK
  decision state
    renders instructions, input_fields, inputs and demos:    OK
    omits demos when there are none:                         OK
```

If the local Baikai override is used for milestone 2, remember that a green local build does not prove Hackage consumers build. Milestone 3's acceptance must be re-run with no `cabal.project.local`.


## Validation and Acceptance

**Milestone 1.** `cabal test shikumi` passes. Golden tests check three things:

- the `Assessment` schema is exactly the lm15-convention shape plus `x-shikumi-decision` markers;
- `judgmentsOf @Assessment` lists `urgent` (boolean, criteria true/false), `severity` (ordered, three levels) and `category` (choice, two labels), in that order;
- `renderDecisionState` on a one-demo signature equals the `state` object in Context and Orientation.

Adding a `summary :: Field "…" Text` field to a record deriving `DecisionOutputs` fails to compile with a message naming `summary`. Record that transcript in Surprises & Discoveries.

**Milestone 2.** The stub test answers with:

- `urgent` p = 0.83;
- `severity` [0.1, 0.3, 0.6];
- `category` {billing: 0.2, technical: 0.8}.

It asserts:

- `urgent.value == True`, `urgent.probability == 0.83`, and `urgent.confidence` ≈ 0.66;
- `severity.value == 1.5` and `severity.level == 2`;
- `category.value == Technical`.

A second test uses a record with a `Text` field under `runCountingLLM` and a `DecisionOnly` model. It asserts `Left (ValidationFailure msg)`, where `msg` mentions the field name, and a call count of 0. A routing test in `shikumi/test/RoutingSpec.hs` asserts that, for a native OpenAI model, the outgoing `responseFormat` contains no `x-shikumi-decision` key. The cache test round-trips `systemOneResponse`.

**Milestone 3.** `cabal test shikumi-tools` passes `SystemOneIntegrationSpec`. The fixture receives exactly one POST to `/v1/systemone` with the expected body, and the program returns the same typed `Assessment` as the stub test. `RequestDefaultsSpec` shows the judgment-only exemption, `DecisionSpec` shows parity with `compileJudgments`, and `just test` passes with no `cabal.project.local` present.


## Idempotence and Recovery

All changes are additive. The new module, capability constructor, reserved key and harness module leave existing programs' requests byte-identical, because the state is stamped only when the schema contains a judgment and is always stripped before transport. `RoutingSpec` and the cache golden tests already pin the existing wire shapes; if one of them changes, stop and fix the regression rather than updating the golden. Adding `DecisionOnly` makes existing `case capabilityFor` matches non-exhaustive. Fix each such match (GHC's `-Wincomplete-patterns` lists them) by treating `DecisionOnly` explicitly. To back out, revert the commits: no persisted data format changes in this plan.


## Interfaces and Dependencies

This plan defines the following, which the rest of MasterPlan 12 depends on:

- In `Shikumi.Decision`:
  - the evidence records `NoulEvidence`, `ChoiceEvidence`, `ScoreEvidence` and `FieldEvidence`, with their JSON shapes;
  - `NoulWith t f` / `Noul`, `Choice a` with `ChoiceOptions a`, and `Score levels`;
  - `IsDecision`, `DecisionOutputs` and `judgmentsOf`;
  - `Judgment`, `JudgmentKind` and `judgmentsInSchema`;
  - `renderDecisionState`;
  - `deriveNoul`, `deriveScore` and `deriveChoice`, with the signatures above, which take explicit settings;
  - `questionJSON :: Judgment -> Value`.
- In `Shikumi.Adapter`: `DecisionOnly` and `metaDecisionStateKey`, plus a schema-stripping helper for `x-shikumi-decision`.
- In `Shikumi.LLM.Defaults`: the judgment-only exemption inside `withRequestDefaults` (milestone 3).
- In `shikumi-testing`: `Shikumi.Testing.SystemOne` (`systemOneModel`, `systemOneResponse`, `systemOneResponder`, and `withSystemOneFixture` in milestone 3), and the `Assessment` fixture.

External dependencies, all requested as `mori://shinzui/baikai/okf/improvement-requests/concepts/IR-10`: from Baikai EP-83, the `UserData Value` and `AssistantData DataContent` content variants (`DataContent` with `value`, `probabilities`, `confidence`, `method`); from Baikai EP-99, `OutputKind`, `isJudgmentOnly`, `InputData`, the `TypeSafeSystemOne` API tag with the `jev-latest` and `jev-preview` catalog entries, and `Baikai.Judgment` (`prepareJudgment`, `compileJudgments`, `refuseGenerationControls`, `validateAnswers`, `judgmentMethod`); from Baikai EP-84, the `baikai-typesafe` package, which itself needs the first Hackage release of `mori://shinzui/typesafe-hs`. Shikumi never depends on `typesafe-hs` directly. No new Hackage dependencies are needed in Shikumi: `containers`, `vector` and `aeson` are already dependencies of `shikumi`.


## Revision Notes

2026-10-21: Reconciled with Baikai's revised EP-83 and EP-84 and with TypeSafe's OpenAPI 0.2.0 document. Noul criteria move from the private marker into `anyOf` `const` branches; the reply sample gains the required `confidence`, `score` and `legend`; `evidenceOf` is specified against Baikai's `DataContent`; milestone 3 gains the request-defaults exemption, the `isJudgmentOnly` switch and the `compileJudgments` parity test; error expectations follow the actual `fromBaikaiError` mapping; `capabilityFor` is described as ADR-14 left it; test commands use tasty's `-p`.

2026-10-22: Baikai split EP-84; the capability, the API tag and catalog entries, and `Baikai.Judgment` now come from Baikai EP-99, and only the `baikai-typesafe` provider from EP-84. Milestone 3's blocking statement, interim-comment pointer and interfaces follow the split, and the parity test records Baikai's `required`-then-ascending question-order rule.
