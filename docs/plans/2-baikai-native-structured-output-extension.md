---
id: 2
slug: baikai-native-structured-output-extension
title: "Baikai native structured output extension"
kind: exec-plan
created_at: 2026-06-08T02:44:16Z
intention: "intention_01ktjgkp10ef79vpwz1cmajek9"
master_plan: "docs/masterplans/1-shikumi-typed-lm-programming-framework.md"
---

# Baikai native structured output extension

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Today, baikai — the multi-provider language-model transport library at
`/Users/shinzui/Keikaku/bokuno/baikai` — can send a request and parse the assistant reply,
but it has no way to ask the provider to *constrain the reply to a JSON schema*. The
per-call options record (`Baikai.Options.Options`) carries knobs like `maxTokens`,
`temperature`, `toolChoice`, `cacheRetention`, and `thinking`, but nothing that says "make
the model's output conform to this exact JSON shape." If a caller wants structured output
today, they must coax it through the system prompt and then hope the model returns
well-formed JSON, parsing it themselves and handling the frequent failures.

After this change, a caller can attach a JSON schema (or request plain-JSON mode) to any
request through a new `Options` field, and baikai will translate that into the provider's
*native* structured-output mechanism: OpenAI's `response_format` and Anthropic's
`output_config`. Both providers then *enforce* the schema server-side, returning a body
that is guaranteed to be valid JSON conforming to the schema (or, for plain-JSON mode,
guaranteed to be syntactically valid JSON). The structured payload arrives through baikai's
existing response surface as the assistant's text content — the same place ordinary text
replies appear — so nothing downstream needs a new content type to read it.

Concretely, after this work a developer can write the following against baikai and observe
the model returning conformant JSON:

```haskell
import Baikai

-- A JSON Schema describing the desired output shape.
personSchema :: Data.Aeson.Value
personSchema =
  Data.Aeson.object
    [ "type" Data.Aeson..= ("object" :: Data.Text.Text)
    , "properties" Data.Aeson..= Data.Aeson.object
        [ "name" Data.Aeson..= Data.Aeson.object [ "type" Data.Aeson..= ("string" :: Data.Text.Text) ]
        , "age"  Data.Aeson..= Data.Aeson.object [ "type" Data.Aeson..= ("integer" :: Data.Text.Text) ]
        ]
    , "required" Data.Aeson..= (["name", "age"] :: [Data.Text.Text])
    , "additionalProperties" Data.Aeson..= False
    ]

opts :: Options
opts =
  _Options
    & #responseFormat .~ Just (JsonSchema { name = "person", schema = personSchema, strict = True })
```

When that request runs against `gpt-4o-mini` or a recent Claude model, the assistant text
block of the response is a JSON document like `{"name":"Ada Lovelace","age":36}` that
validates against `personSchema`.

The user-visible behavior this enables, and that the Validation section below demonstrates
with a live transcript, is: **a request carrying a JSON schema yields a response whose body
validates against that schema.** This is the one upstream capability that the broader
shikumi framework (the sibling plan at
`docs/plans/3-generic-derived-signatures-and-structured-io.md`) depends on for its
provider-enforced structured I/O. That sibling plan derives a schema from a Haskell record
type, attaches it through exactly the field this plan adds, and decodes the returned JSON
text back into the record. This plan owns the baikai half of that contract; the contract's
exact shape is pinned down in the "Interfaces and Dependencies" section so the sibling plan
can mirror it.

This work happens **entirely in the baikai repository** at
`/Users/shinzui/Keikaku/bokuno/baikai`, not in the shikumi repository where this plan file
lives. Commits land in the baikai repo and still carry the MasterPlan/ExecPlan/Intention
trailers described in "Concrete Steps".


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1: `Baikai.ResponseFormat` module defining `ResponseFormat` exists; `Options` gains a
  `responseFormat` field; `_Options` defaults it to `Nothing`; `Baikai` re-exports it;
  `cabal build baikai` succeeds. **Done (2026-06-08):** module created (with
  `-Wno-partial-fields`, matching `Baikai.Trace.Event`), `Options` field + `_Options` default
  added, re-exported from `Baikai`, listed in `baikai.cabal` exposed-modules. `cabal build
  baikai` is warning-free; `cabal test baikai` green (41 tests) including a new round-trip
  assertion for both `JsonObject` and `JsonSchema`.
- [x] M2: OpenAI Chat Completions provider maps `responseFormat` onto the upstream
  `response_format` field; `cabal build baikai-openai` succeeds and a pure mapping test
  asserts the produced request carries the expected `response_format`. **Done (2026-06-08):**
  `mkOpenAIResponseFormat` helper added and wired into `mapRequest`; `mapRequest` exported for
  testing. Upstream `RF.ResponseFormat`/`JSONSchema` have no `Eq`, so the test pattern-matches
  `Chat.response_format` to `RF.JSON_Schema` and asserts `name`/`schema`/`strict`/`description`
  field-by-field. `cabal test baikai-openai` green (5 tests). Added `aeson` + `openai` to the
  test stanza.
- [x] M3: Anthropic Messages provider maps `responseFormat` onto the upstream
  `output_config`; `cabal build baikai-claude` succeeds and a pure mapping test asserts the
  produced request carries the expected `output_config`. **Done (2026-06-08):**
  `mkAnthropicOutputConfig` helper added (`JsonSchema` → `Messages.jsonSchemaConfig`; `strict`
  dropped — Anthropic is always schema-enforcing; `JsonObject` → permissive `{"type":"object"}`)
  and wired into `mapRequest`; `mapRequest` exported. Upstream `OutputConfig`/`OutputFormat`
  derive `Eq`, so the test asserts `Messages.output_config req == Just (jsonSchemaConfig
  personSchema)` directly. `cabal test baikai-claude` green (4 tests). Added `aeson` + `claude`
  to the test stanza.
- [x] M4: `baikai-smoke` gains a structured-output smoke case that, when a provider key is
  present, sends a schema-bearing request and asserts the returned text parses as JSON and
  validates against the schema; it skips (does not fail) when no key is set. `cabal build
  baikai-smoke` succeeds; the live run shows a conformant-JSON transcript. **Done (2026-06-08):**
  `StructuredSmoke.hs` created (mirrors `ToolsSmoke`), wired into `Smoke.hs` (`runStructuredCase`
  wrapper + `or hadStructured` in the skip guard) and `other-modules`. No-key run exits 0 with a
  structured-output skip line. **Live run (gpt-4o-mini via `OPENAI_API_KEY`) passed with the
  conformant transcript:** `json={"age":36,"name":"Ada Lovelace"}` — a schema-shaped object
  returned even though the prompt never mentions JSON, confirming server-side schema enforcement.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Discovery (2026-06-07, during plan authoring): **Anthropic now natively supports
  structured JSON output**, so the original masterplan worry that "Anthropic has no
  response_format" is out of date. The pinned `claude` SDK at
  `/Users/shinzui/Keikaku/hub/haskell/claude-project` exposes
  `Claude.V1.Messages.OutputConfig`, `OutputFormat`, and the helper `jsonSchemaConfig`, and
  `Claude.V1.Messages.CreateMessage` already has an `output_config :: Maybe OutputConfig`
  field. There is even an upstream example at
  `claude/examples/claude-structured-outputs-example/Main.hs` that sends
  `output_config = Just (Messages.jsonSchemaConfig outputSchema)` and reads the JSON back
  out of a `ContentBlock_Text`. This means baikai can give a *faithful native* realization
  on **both** providers rather than falling back to a forced-tool emulation on Anthropic.
  Evidence:

  ```text
  $ grep -n "output_config\|OutputConfig\|jsonSchemaConfig" \
      /Users/shinzui/Keikaku/hub/haskell/claude-project/claude/src/Claude/V1/Messages.hs
  11:    , OutputConfig(..)
  758:jsonSchemaConfig :: Value -> OutputConfig
  922:    , output_config :: Maybe OutputConfig
  ```

- Discovery (2026-06-07): **The OpenAI SDK already models `response_format` fully.** The
  pinned `openai` SDK at `/Users/shinzui/Keikaku/hub/haskell/openai-project` exposes
  `OpenAI.V1.ResponseFormat.ResponseFormat (ResponseFormat_Text | JSON_Object |
  JSON_Schema{ json_schema :: JSONSchema })` with `JSONSchema { description, name, schema,
  strict }`, and `OpenAI.V1.Chat.Completions.CreateChatCompletion` already carries a
  `response_format :: Maybe ResponseFormat` field. baikai's request mapper simply never
  sets it. So the OpenAI side is purely additive: set one field on the record baikai
  already constructs.

- Discovery (2026-06-07): **Both providers return the structured payload as ordinary
  assistant text**, not as a new content kind. OpenAI returns the JSON document as the
  message's text content; Anthropic returns it as a `ContentBlock_Text` (per the upstream
  example). baikai already lowers both into a `Content.AssistantText (TextContent ...)`
  block in its streaming assemblers. Therefore **no change to `Baikai.Response`,
  `Baikai.Content`, or `Baikai.Message` is required** — the JSON arrives via
  `flattenAssistantText` exactly like any text reply. This simplifies the contract with the
  sibling plan to "read the assistant text, then JSON-decode it."


## Decision Log

Record every decision made while working on the plan.

- Decision: Model the new capability as a dedicated sum type `ResponseFormat` with two
  constructors — `JsonSchema { name :: Text, schema :: Value, strict :: Bool }` and
  `JsonObject` — carried on `Options` as `responseFormat :: Maybe ResponseFormat`. The
  schema is an aeson `Value` (a raw JSON Schema), mirroring how baikai already carries tool
  schemas as `Tool.parameters :: Value`.
  Rationale: A two-constructor sum exactly matches what both providers offer (a named,
  strictly-enforced schema vs. "just emit valid JSON"). Carrying the schema as a `Value`
  keeps baikai schema-agnostic — it never inspects or validates the schema, it only forwards
  it — which is consistent with the existing `Tool.parameters :: Value` convention
  documented in `/Users/shinzui/Keikaku/bokuno/baikai/docs/user/tools.md`. `Nothing` means
  "no structured-output constraint," preserving today's behavior for every existing caller.
  Date: 2026-06-07.

- Decision: Put `ResponseFormat` in its own module `Baikai.ResponseFormat`, re-exported
  from the umbrella `Baikai` module, rather than inlining it into `Baikai.Options`.
  Rationale: This matches the established baikai pattern where each provider-agnostic
  per-call preference lives in its own small module and is mapped per provider — see
  `Baikai.CacheRetention` and `Baikai.ThinkingLevel`, both tiny modules re-exported from
  `Baikai`. Keeping `ResponseFormat` separate avoids an import cycle (the provider mappers
  import it directly) and keeps `Baikai.Options` a thin record. Date: 2026-06-07.

- Decision: Realize the Anthropic side via the provider's **native** `output_config` JSON
  schema, not via a forced-tool emulation and not as "unsupported."
  Rationale: The masterplan asked us to research what Anthropic supports and pick the most
  faithful approach. The pinned `claude` SDK exposes native structured outputs
  (`OutputConfig`/`jsonSchemaConfig`), so the faithful realization is the native one. A
  forced-single-tool emulation would be strictly worse (it changes the response shape into a
  tool call rather than text, and would require downstream code to special-case it). We
  therefore use `Messages.jsonSchemaConfig` for `JsonSchema`. For `JsonObject` (plain-JSON
  mode), Anthropic's `output_config` requires a schema, so `JsonObject` lowers to a
  permissive "any JSON object" schema (`{"type":"object"}`) on the Anthropic side; on OpenAI
  it lowers to the dedicated `JSON_Object` constructor. The downgrade is documented in code
  comments and below. Date: 2026-06-07.

- Decision: Map `JsonSchema { strict = True }` to OpenAI's `strict = Just True` and
  `strict = False` to `strict = Just False` (explicitly, not `Nothing`). Anthropic's
  `OutputFormat` has no per-schema `strict` flag (its structured outputs are always
  schema-enforcing), so the `strict` field is simply not represented on the Anthropic wire;
  this is documented in the Anthropic mapper.
  Rationale: Being explicit on OpenAI keeps behavior predictable and lets a caller opt out
  of strict mode for hosts that reject it; on Anthropic the field has no analog so it is
  dropped, which is the only honest option. Date: 2026-06-07.

- Decision: Do not change `Baikai.Response`/`Baikai.Content`/`Baikai.Message`. The
  structured payload surfaces as the assistant text block already produced by both
  streaming assemblers; downstream reads it with `flattenAssistantBlocks` /
  `flattenAssistantText` and JSON-decodes it.
  Rationale: See the third Surprises entry — both providers return JSON as text, and the
  existing assemblers already lower that to `AssistantText`. Adding a new content kind would
  be unused complexity. Date: 2026-06-07.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

**Delivered in full (2026-06-08).** All four milestones complete; the purpose is met:
a request carrying a JSON schema yields a response whose body validates against that schema.
The live demonstration is the decisive proof — `gpt-4o-mini` returned
`{"age":36,"name":"Ada Lovelace"}` for a prompt that never mentions JSON, so the provider is
enforcing the attached schema server-side.

What landed, against the plan:

- **M1** — `Baikai.ResponseFormat` (`JsonSchema { name, schema, strict }` | `JsonObject`),
  `Options.responseFormat :: Maybe ResponseFormat` defaulting to `Nothing`, re-exported from
  the umbrella `Baikai`. Exactly as specified.
- **M2** — OpenAI: `mkOpenAIResponseFormat` → upstream `response_format` (`JsonObject` →
  `JSON_Object`; `JsonSchema` → named, explicitly-strict `JSON_Schema`; schema forwarded
  verbatim). `mapRequest` exported for a pure test.
- **M3** — Anthropic: `mkAnthropicOutputConfig` → native `output_config` via
  `Messages.jsonSchemaConfig`. `strict` dropped (Anthropic is always schema-enforcing);
  `JsonObject` downgrades to a permissive `{"type":"object"}` schema. `mapRequest` exported.
- **M4** — `StructuredSmoke.hs`: live conformance case that skips without a key and asserts
  the schema-shaped object otherwise.

No `Baikai.Response`/`Content`/`Message` change was needed — the structured payload arrives as
ordinary assistant text, exactly as the Surprises entries predicted. The cross-plan contract
(integration point #2) is therefore as documented and fixed for EP-3 to consume.

Deviations / notes:
- `ResponseFormat` carries `{-# OPTIONS_GHC -Wno-partial-fields #-}` (the `strict`/`name`/
  `schema` fields are partial across the two constructors), matching `Baikai.Trace.Event`'s
  convention — baikai builds with `-Wpartial-fields` fleet-wide.
- Comparison strategy split by upstream `Eq` availability: OpenAI's `ResponseFormat`/`JSONSchema`
  derive only `Generic`/`Show`, so the M2 test pattern-matches and checks fields individually;
  Anthropic's `OutputConfig`/`OutputFormat` derive `Eq`, so M3 compares directly against
  `jsonSchemaConfig personSchema`.
- Test stanzas gained deps: `baikai-openai-test` += `aeson`, `openai`; `baikai-claude-test` +=
  `aeson`, `claude`.

Gaps / not done (out of scope, as planned): baikai still ships no JSON Schema *validator* — the
smoke test does a structural shape check, and the schema `Value` is forwarded to the provider
verbatim; downstream (EP-3) owns turning a syntactically-valid-but-shape-wrong body into a typed
error. The Anthropic native path was not exercised live (no Anthropic key was present during
implementation); its pure mapping test passes and the wire shape matches the upstream SDK's
documented `output_config`.


## Context and Orientation

This section orients a reader who knows nothing about baikai. Everything below names files
by full path inside the baikai repository at `/Users/shinzui/Keikaku/bokuno/baikai`.

baikai ("媒介 / mediation") is a Haskell library that gives one uniform interface over many
language-model providers. It is a multi-package Cabal project. The packages relevant here:

- **`baikai`** (core, sources under `baikai/src/Baikai/`): defines the provider-neutral
  request/response vocabulary — `Model`, `Context`, `Options`, `Response`, content/message
  types, the provider registry, and the small per-call preference modules. It does not talk
  to any provider directly.
- **`baikai-openai`** (sources under `baikai-openai/src/Baikai/Provider/OpenAI/`): the
  handler for OpenAI's Chat Completions API. It translates baikai's neutral types into the
  upstream `openai` SDK's request type and parses the streamed response back.
- **`baikai-claude`** (sources under `baikai-claude/src/Baikai/Provider/Claude/`): the
  handler for Anthropic's Messages API, translating to/from the upstream `claude` SDK.
- **`baikai-smoke`** (sources under `baikai-smoke/test/`): a live, network-touching test
  suite that exercises every shipped provider when the matching API key environment variable
  is set, and *skips* (never fails) when keys are absent.

The two upstream SDKs baikai wraps live on disk and can be inspected with `mori`:

- `openai` SDK: `/Users/shinzui/Keikaku/hub/haskell/openai-project` (registered as
  `MercuryTechnologies/openai`).
- `claude` SDK: `/Users/shinzui/Keikaku/hub/haskell/claude-project` (registered as
  `MercuryTechnologies/claude`).

Key terms used below, defined in plain language:

- **JSON Schema**: a JSON document that describes the shape another JSON document must have
  (its fields, their types, which are required). In baikai it is always carried as an aeson
  `Data.Aeson.Value` and passed through verbatim; baikai never validates it itself.
- **`response_format`** (OpenAI): a field on OpenAI's chat request that tells the model to
  emit either plain JSON (`{"type":"json_object"}`) or JSON conforming to a named schema
  (`{"type":"json_schema","json_schema":{...}}`).
- **`output_config`** (Anthropic): the equivalent field on Anthropic's Messages request,
  carrying a `format` of type `"json_schema"` with the schema inline.
- **Smart constructor `_Options`**: baikai's convention is to expose a record `Foo` plus a
  value `_Foo` holding sensible empty defaults; callers build values by record-updating the
  default with lens-style overloaded labels, e.g. `_Options & #temperature .~ Just 0.0`.
  The same pattern appears as `_Context`, `_Model`, `_Tool`, `_Response`.

The current `Options` record, at `baikai/src/Baikai/Options.hs`, is exactly:

```haskell
data Options = Options
  { maxTokens :: !(Maybe Natural),
    temperature :: !(Maybe Double),
    apiKey :: !(Maybe ApiKeySource),
    timeoutMs :: !(Maybe Int),
    headers :: !(Map Text Text),
    metadata :: !(Map Text Value),
    toolChoice :: !(Maybe ToolChoice),
    cacheRetention :: !(Maybe CacheRetention),
    thinking :: !(Maybe ThinkingLevel)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

_Options :: Options
_Options =
  Options
    { maxTokens = Nothing,
      temperature = Nothing,
      apiKey = Nothing,
      timeoutMs = Nothing,
      headers = Map.empty,
      metadata = Map.empty,
      toolChoice = Nothing,
      cacheRetention = Nothing,
      thinking = Nothing
    }
```

There is no `responseFormat` field. This plan adds one.

The OpenAI request mapper, at
`baikai-openai/src/Baikai/Provider/OpenAI/Api.hs`, builds the upstream request in
`mapRequest` and currently ends with this record literal (note it constructs from the
upstream default base `Chat._CreateChatCompletion`, so any field it does not mention defaults
to the SDK default, which for `response_format` is `Nothing`):

```haskell
mapRequest ::
  Model -> Context -> Options -> Either Text Chat.CreateChatCompletion
mapRequest m ctx opts = do
  body <- traverse mapMessage (Vector.toList (ctx ^. #messages))
  let compat = openaiCompletionsCompatFor m
      prefix = ...
      mt = fromMaybe (m ^. #maxOutputTokens) (opts ^. #maxTokens)
      toolsField = ...
      toolChoiceField = fmap mkOpenAIToolChoice (opts ^. #toolChoice)
      reasoningEffortField = applyThinkingFormat compat (opts ^. #thinking)
  pure
    Chat._CreateChatCompletion
      { Chat.messages = Vector.fromList (prefix <> body),
        Chat.model = OpenAIModels.Model (m ^. #modelId),
        Chat.max_completion_tokens = Just mt,
        Chat.temperature = opts ^. #temperature,
        Chat.tools = toolsField,
        Chat.tool_choice = toolChoiceField,
        Chat.reasoning_effort = reasoningEffortField
      }
```

The Anthropic request mapper, at
`baikai-claude/src/Baikai/Provider/Claude/Api.hs`, ends with this literal (again
constructed from the upstream default base `Messages._CreateMessage`, so `output_config`
defaults to `Nothing`):

```haskell
mapRequest :: Model -> Context -> Options -> Either Text Messages.CreateMessage
mapRequest m ctx opts = do
  msgs <- traverse mapMessage (Vector.toList (ctx ^. #messages))
  let compat = anthropicMessagesCompatFor m
      baseTokens = fromMaybe (m ^. #maxOutputTokens) (opts ^. #maxTokens)
      thinkingField = computeThinking m (opts ^. #thinking)
      maxTokensField_ = ...
      cacheControlField = computeCacheControl compat (opts ^. #cacheRetention)
      toolsField = ...
      toolChoiceField = ...
  pure
    Messages._CreateMessage
      { Messages.model = m ^. #modelId,
        Messages.messages = Vector.fromList msgs,
        Messages.max_tokens = maxTokensField_,
        Messages.system = fmap Messages.SystemPromptText (ctx ^. #systemPrompt),
        Messages.temperature = opts ^. #temperature,
        Messages.tools = toolsField,
        Messages.tool_choice = toolChoiceField,
        Messages.cache_control = cacheControlField,
        Messages.thinking = thinkingField
      }
```

The upstream SDK types this plan relies on (already present; this plan does not change the
SDKs):

- `OpenAI.V1.ResponseFormat.ResponseFormat` with constructors `ResponseFormat_Text`,
  `JSON_Object`, and `JSON_Schema { json_schema :: JSONSchema }`, plus
  `JSONSchema { description :: Maybe Text, name :: Text, schema :: Maybe Value, strict ::
  Maybe Bool }`. `OpenAI.V1.Chat.Completions.CreateChatCompletion` has
  `response_format :: Maybe ResponseFormat`. Both are re-exported through
  `OpenAI.V1.Chat.Completions` (which baikai already imports as `Chat`).
- `Claude.V1.Messages.OutputConfig { effort :: Maybe Text, format :: Maybe OutputFormat }`,
  `OutputFormat { type_ :: Text, schema :: Value }`, and helpers
  `jsonSchemaConfig :: Value -> OutputConfig` and `jsonSchemaFormat :: Value -> OutputFormat`.
  `Claude.V1.Messages.CreateMessage` has `output_config :: Maybe OutputConfig`. baikai
  already imports this module as `Messages`.

baikai's coding conventions, which all edits must follow: `default-language: GHC2024`;
default extensions `DeriveAnyClass, DuplicateRecordFields, OverloadedLabels,
OverloadedStrings`; records built with `generic-lens` overloaded labels and lens operators
(`&`, `.~`, `^.`); `-Wall -Wmissing-export-lists` are on, so every module needs an explicit
export list and no unused warnings.


## Plan of Work

The work is four milestones. M1 adds the neutral type and the `Options` field in the core
package. M2 and M3 wire that field into the two providers (independent of each other; either
order is fine). M4 adds the live smoke test that proves end-to-end conformance. Each
milestone builds and is independently verifiable.

### Milestone 1 — Add `ResponseFormat` and the `Options` field (package `baikai`)

Scope: introduce the provider-neutral structured-output type and thread it onto `Options`.
At the end of this milestone the type exists, `Options` carries it (defaulting to off), the
umbrella module re-exports it, and the core package compiles. No provider behavior changes
yet, so this milestone is verified by compilation plus a tiny unit assertion that
constructing an `Options` with the new field type-checks and round-trips through the default.

Create a new module `baikai/src/Baikai/ResponseFormat.hs`, modeled on the existing tiny
module `baikai/src/Baikai/CacheRetention.hs`. It defines:

```haskell
-- | Provider-agnostic structured-output preference.
--
-- Each provider maps the value to its own native mechanism:
-- OpenAI's @response_format@ and Anthropic's @output_config@.
-- 'Nothing' on 'Baikai.Options.responseFormat' means no
-- structured-output constraint (today's behaviour).
module Baikai.ResponseFormat
  ( ResponseFormat (..),
  )
where

import Data.Aeson (FromJSON, ToJSON, Value)
import Data.Text (Text)
import GHC.Generics (Generic)

-- | How to constrain the model's output.
data ResponseFormat
  = -- | Enforce a named JSON Schema. The 'schema' is a raw JSON
    --   Schema document (an aeson 'Value'), passed through verbatim;
    --   baikai never inspects or validates it. 'strict' requests the
    --   provider's strict schema-enforcement mode where available
    --   (OpenAI honours it; Anthropic structured outputs are always
    --   schema-enforcing and ignore it).
    JsonSchema
      { name :: !Text,
        schema :: !Value,
        strict :: !Bool
      }
  | -- | Plain-JSON mode: the model must emit syntactically valid JSON
    --   but is not constrained to a specific shape. Maps to OpenAI's
    --   @{"type":"json_object"}@; on Anthropic (whose structured
    --   outputs require a schema) it maps to a permissive
    --   @{"type":"object"}@ schema.
    JsonObject
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)
```

Then edit `baikai/src/Baikai/Options.hs`:

1. Add the import `import Baikai.ResponseFormat (ResponseFormat)` near the other
   `Baikai.*` imports.
2. Add a field `responseFormat :: !(Maybe ResponseFormat)` to the `Options` record. Place
   it after `thinking` to keep the diff small (field order is irrelevant since callers use
   overloaded labels, but appending is cleanest). Remember the trailing comma rules: the
   field before it (`thinking`) needs a comma added.
3. Add `responseFormat = Nothing` to the `_Options` smart constructor.
4. Update the module's Haddock header comment to mention the new field (the header already
   narrates which EP added which field; add a sentence noting EP-2 added `responseFormat`).

The `Options` record derives `ToJSON` via `DeriveAnyClass`; because `ResponseFormat` derives
`ToJSON`/`FromJSON`, this continues to work with no extra instances.

Finally, edit `baikai/src/Baikai.hs` to re-export the new module: add `module
Baikai.ResponseFormat,` to the export list (next to `module Baikai.CacheRetention,` and
`module Baikai.ThinkingLevel,`) and add `import Baikai.ResponseFormat` to the import block.

Also add `Baikai.ResponseFormat` to the `exposed-modules` list in `baikai/baikai.cabal`
(alphabetically it sits right after `Baikai.Response`).

Verification: from the baikai repo root, `cabal build baikai`. It must compile with no
warnings (warnings are errors-adjacent here because `-Wall` plus `-Wmissing-export-lists`
are on; the new module has an explicit export list so it is fine). To prove the field is
usable, add a one-line expression test to the core test suite (see Concrete Steps) that
constructs `_Options & #responseFormat .~ Just JsonObject` and checks
`responseFormat (_Options & #responseFormat .~ Just JsonObject) == Just JsonObject`.

### Milestone 2 — Map `responseFormat` in the OpenAI provider (package `baikai-openai`)

Scope: translate the neutral `ResponseFormat` into the upstream OpenAI `response_format`
field inside `mapRequest`. At the end, an OpenAI request built from an `Options` carrying a
`responseFormat` includes the corresponding `response_format`, and the package compiles. The
milestone is verified by compilation plus a pure unit test that runs `mapRequest` (it is a
pure `Either Text Chat.CreateChatCompletion`) and inspects the `response_format` field of
the produced request.

Edit `baikai-openai/src/Baikai/Provider/OpenAI/Api.hs`:

1. Add imports: `import Baikai.ResponseFormat (ResponseFormat (..))` and
   `import OpenAI.V1.ResponseFormat qualified as RF` (the module exporting `ResponseFormat`
   and `JSONSchema`; it is re-exported through `OpenAI.V1.Chat.Completions`, but importing it
   directly is clearer). Note baikai already imports `OpenAI.V1.Chat.Completions qualified as
   Chat`.
2. Add a small mapping helper near `mkOpenAITool`:

   ```haskell
   -- | Map a baikai 'ResponseFormat' onto the upstream OpenAI
   -- 'RF.ResponseFormat'. 'JsonObject' becomes plain-JSON mode;
   -- 'JsonSchema' becomes a named, optionally-strict schema. The
   -- schema 'Value' is forwarded verbatim.
   mkOpenAIResponseFormat :: ResponseFormat -> RF.ResponseFormat
   mkOpenAIResponseFormat = \case
     JsonObject -> RF.JSON_Object
     JsonSchema {name = n, schema = s, strict = st} ->
       RF.JSON_Schema
         { RF.json_schema =
             RF.JSONSchema
               { RF.description = Nothing,
                 RF.name = n,
                 RF.schema = Just s,
                 RF.strict = Just st
               }
         }
   ```

3. In `mapRequest`, add a `let`-bound field
   `responseFormatField = fmap mkOpenAIResponseFormat (opts ^. #responseFormat)` and add
   `Chat.response_format = responseFormatField` to the `Chat._CreateChatCompletion {...}`
   record. Since the record is built from `_CreateChatCompletion`, when `responseFormat` is
   `Nothing` the field is `Nothing` and the wire request is identical to today — so existing
   callers are unaffected.

Verification: from the baikai repo root, `cabal build baikai-openai`. Then run the
package's test suite (`cabal test baikai-openai`) after adding the pure mapping test
described in Concrete Steps: it constructs a `Model` (any OpenAI model from
`Baikai.Models.Generated`, e.g. `openai_gpt_4o_mini`), a `Context`, and an `Options` with a
`JsonSchema` response format, calls the (newly exported, for testing) `mapRequest`, and
asserts the resulting request's `response_format` is `Just (JSON_Schema {...})` with the
expected name and schema. To make `mapRequest` reachable from the test, add it (and the
helper if you want to test it directly) to the module's export list; it is currently
internal. Exporting `mapRequest` is a safe additive change.

### Milestone 3 — Map `responseFormat` in the Anthropic provider (package `baikai-claude`)

Scope: translate the neutral `ResponseFormat` into the upstream Anthropic `output_config`
field inside `mapRequest`. At the end, an Anthropic request built from an `Options` carrying
a `responseFormat` includes the corresponding `output_config`, and the package compiles.
Verified by compilation plus a pure unit test inspecting the produced request, exactly
parallel to M2.

Edit `baikai-claude/src/Baikai/Provider/Claude/Api.hs`:

1. Add the import `import Baikai.ResponseFormat (ResponseFormat (..))`. baikai already
   imports `Claude.V1.Messages qualified as Messages`, which exports `OutputConfig`,
   `OutputFormat`, `jsonSchemaConfig`, and `jsonSchemaFormat`. Also add
   `import Data.Aeson ((.=))` and `import Data.Aeson qualified as Aeson` if not already
   present (the file already imports `Data.Aeson (Value)` and `Data.Aeson qualified as
   Aeson`; reuse those — `Aeson.object` and the `(.=)` operator are needed for the
   permissive object schema, so add `(.=)` to the existing `Data.Aeson` import list).
2. Add a mapping helper near `computeCacheControl`:

   ```haskell
   -- | Map a baikai 'ResponseFormat' onto the upstream Anthropic
   -- 'Messages.OutputConfig'. 'JsonSchema' forwards the schema
   -- verbatim via 'Messages.jsonSchemaConfig'. Anthropic's structured
   -- outputs are always schema-enforcing, so the baikai 'strict' flag
   -- has no wire analog and is dropped. 'JsonObject' (plain-JSON mode)
   -- has no native Anthropic equivalent — 'output_config' requires a
   -- schema — so it downgrades to a permissive @{"type":"object"}@
   -- schema, which still forces the model to emit a JSON object.
   mkAnthropicOutputConfig :: ResponseFormat -> Messages.OutputConfig
   mkAnthropicOutputConfig = \case
     JsonSchema {schema = s} -> Messages.jsonSchemaConfig s
     JsonObject ->
       Messages.jsonSchemaConfig
         (Aeson.object ["type" .= ("object" :: Text)])
   ```

3. In `mapRequest`, add a `let`-bound field
   `outputConfigField = fmap mkAnthropicOutputConfig (opts ^. #responseFormat)` and add
   `Messages.output_config = outputConfigField` to the `Messages._CreateMessage {...}`
   record. As with OpenAI, when `responseFormat` is `Nothing` the field is `Nothing` and the
   wire request is unchanged from today.

Verification: from the baikai repo root, `cabal build baikai-claude`, then
`cabal test baikai-claude` after adding the pure mapping test (see Concrete Steps): build a
Claude model (e.g. `Models.anthropic_claude_haiku_4_5_20251001`), a `Context`, and an
`Options` with a `JsonSchema`, call the (newly exported) `mapRequest`, and assert the
produced request's `output_config` is `Just (OutputConfig {format = Just (OutputFormat
{type_ = "json_schema", schema = <the schema>})})`. Export `mapRequest` from the module to
make it reachable from the test.

### Milestone 4 — Live structured-output smoke test (package `baikai-smoke`)

Scope: prove end-to-end that a schema-bearing request returns conformant JSON, against the
real providers, while skipping cleanly when no keys are present. At the end, `baikai-smoke`
has a new module `StructuredSmoke` wired into its `main`, and running it with a key set
prints a transcript of the returned JSON and confirms it validates against the schema.

This mirrors the existing `baikai-smoke/test/ToolsSmoke.hs` in structure: a `runStructuredCase
:: ApiCase -> IO Bool` that resolves the first available key env var, skips (returns
`False`) when none is set, and `exitFailure`s on assertion failure.

Create `baikai-smoke/test/StructuredSmoke.hs`. It:

1. Declares a small `personSchema :: Aeson.Value` as in the Purpose section.
2. Builds a `Context` whose single user message asks the model to extract a person's name
   and age from a sentence (e.g. "Ada Lovelace, the mathematician, was 36." — choose a
   sentence whose answer is unambiguous so the assertion is stable).
3. Builds `Options` with `#responseFormat .~ Just (JsonSchema {name = "person", schema =
   personSchema, strict = True})`, `#maxTokens .~ Just 256`, `#temperature .~ Just 0.0`, and
   the resolved key.
4. Calls `completeRequest caseModel ctx opts`, flattens the assistant text with
   `flattenAssistantText . flattenAssistantBlocks`, and:
   - asserts the text parses as JSON (`Aeson.eitherDecodeStrict`), failing with the raw text
     in the error message if not;
   - asserts the decoded value is a JSON object containing a string `name` and an integer
     `age` (a minimal "validates against the schema" check — baikai does not ship a JSON
     Schema validator, and pulling one in is out of scope, so the smoke test performs the
     shape check the schema describes: object with `name :: string` and `age :: number`);
   - prints the returned JSON to stderr as the success transcript.

   The shape check is the proof of conformance the masterplan asks for ("a response whose
   body validates against that schema"): the schema says `{name: string, age: integer}`
   required, and the test confirms exactly that. Implement it by decoding to
   `Aeson.Value`, matching `Aeson.Object`, and checking the two keys with `Aeson.String`
   and `Aeson.Number` respectively.

Wire it into `baikai-smoke/test/Smoke.hs`:

1. Add `import StructuredSmoke qualified`.
2. Add a `runStructuredCase` wrapper paralleling the existing `runToolCase` wrapper that
   re-packs `Main.ApiCase` into `StructuredSmoke.ApiCase` (the smoke entry-point re-declares
   `ApiCase` locally per the existing convention in `ToolsSmoke`).
3. Call it over `apiCases` in `main`:
   `hadStructured <- mapM runStructuredCase apiCases`, and include `or hadStructured` in the
   final "no keys; skipping" `unless (...)` guard.

Add `StructuredSmoke` to the `other-modules` list in `baikai-smoke/baikai-smoke.cabal`
(next to `ToolsSmoke`). The package already depends on `aeson`, `baikai`, `baikai-claude`,
`baikai-openai`, `text`, `vector`, `lens`, and `generic-lens`, which is everything this
module needs; no new dependency.

Verification: `cabal build baikai-smoke` must compile. Then run it with a real key (see
Concrete Steps) and observe the conformant-JSON transcript. Without any key,
`cabal test baikai-smoke` must still pass with the skip message.


## Concrete Steps

All commands run from the **baikai repository root**, `/Users/shinzui/Keikaku/bokuno/baikai`,
unless noted. Run them with that as the working directory (do not `cd` mid-command; invoke
each from that directory).

Before starting, confirm you are in the baikai repo and on the intended branch (commit
directly to the current branch; do not create a feature branch):

```bash
git -C /Users/shinzui/Keikaku/bokuno/baikai rev-parse --show-toplevel
git -C /Users/shinzui/Keikaku/bokuno/baikai status --short
```

**M1 build check** (after creating `Baikai/ResponseFormat.hs`, editing `Options.hs`,
`Baikai.hs`, and `baikai.cabal`):

```bash
cabal build baikai
```

Expected: a successful build ending in something like:

```text
[1 of 1] Compiling Baikai.ResponseFormat ...
Linking ... (or "Up to date")
```

For the M1 field round-trip assertion, add a `testCase` to the existing core test suite. The
core tests live under `baikai/test/`; `baikai/test/Main.hs` is the entry point that
aggregates the spec modules. Add a tiny check (in whichever spec module is most natural, or a
new `OptionsSpec`) asserting:

```haskell
responseFormat (_Options & #responseFormat .~ Just JsonObject) == Just JsonObject
```

Then:

```bash
cabal test baikai
```

Expected: all tests pass, including the new assertion.

**M2 build + pure mapping test:**

```bash
cabal build baikai-openai
cabal test baikai-openai
```

The pure mapping test belongs in `baikai-openai/test/Main.hs` (the package's existing test
entry point). It calls the now-exported `mapRequest` and pattern-matches the result. Expected
shape of the assertion (sketch):

```haskell
case mapRequest model ctx optsWithSchema of
  Right req ->
    Chat.response_format req
      == Just
           (RF.JSON_Schema
              { RF.json_schema =
                  RF.JSONSchema
                    { RF.description = Nothing,
                      RF.name = "person",
                      RF.schema = Just personSchema,
                      RF.strict = Just True
                    }
              })
  Left e -> error (Text.unpack e)
```

Note `RF.JSONSchema` derives only `Generic`/`Show` upstream (not `Eq`); if a direct `==`
does not type-check, compare via `Aeson.toJSON req` and assert the JSON contains the expected
`response_format` object instead. Expected result: the test passes.

**M3 build + pure mapping test:**

```bash
cabal build baikai-claude
cabal test baikai-claude
```

The pure mapping test belongs in `baikai-claude/test/Main.hs`. It asserts the produced
`Messages.output_config` carries the expected schema. As with M2, if upstream `OutputConfig`
lacks `Eq`, compare via `Aeson.toJSON` of the request and assert the `output_config` JSON
object contains `format.schema` equal to the input schema. Expected result: the test passes.

**M4 build:**

```bash
cabal build baikai-smoke
```

Expected: a successful build.

**M4 live run (with a key).** The smoke suite reads provider keys from environment variables
(`ANTHROPIC_KEY`/`ANTHROPIC_API_KEY` for Claude, `OPENAI_KEY`/`OPENAI_API_KEY` for OpenAI)
and skips any case whose key is absent. Run it with whichever key you have. Because the
suite runs *all* cases, set only the key you intend to exercise to keep the run focused, or
set both:

```bash
OPENAI_KEY=sk-... cabal test baikai-smoke
```

Expected: stderr includes a structured-output success line and the returned JSON, e.g.:

```text
[baikai-smoke] structured gpt-4o-mini ok via OPENAI_KEY; json={"name":"Ada Lovelace","age":36}
```

and for Claude:

```bash
ANTHROPIC_KEY=sk-ant-... cabal test baikai-smoke
```

```text
[baikai-smoke] structured claude-haiku-4-5-20251001 ok via ANTHROPIC_KEY; json={"age":36,"name":"Ada Lovelace"}
```

**M4 skip run (no keys).** With no provider keys in the environment, the suite must pass
without failing:

```bash
env -u OPENAI_KEY -u OPENAI_API_KEY -u ANTHROPIC_KEY -u ANTHROPIC_API_KEY cabal test baikai-smoke
```

Expected: the run prints `[baikai-smoke] ... skipping` lines (including a structured-output
skip) and exits 0.

**Commit.** Commit after each milestone with a Conventional Commit message carrying the
three required trailers (these reference the shikumi plan paths even though the commit lands
in the baikai repo, because this work is governed by the shikumi MasterPlan):

```bash
git -C /Users/shinzui/Keikaku/bokuno/baikai add -A
git -C /Users/shinzui/Keikaku/bokuno/baikai commit -m "feat(options): add provider-agnostic ResponseFormat to Options

MasterPlan: docs/masterplans/1-shikumi-typed-lm-programming-framework.md
ExecPlan: docs/plans/2-baikai-native-structured-output-extension.md
Intention: intention_01ktjgkp10ef79vpwz1cmajek9"
```

Use analogous messages for the provider milestones, e.g.
`feat(openai): map ResponseFormat onto response_format`,
`feat(claude): map ResponseFormat onto output_config`, and
`test(smoke): structured-output conformance smoke case`.


## Validation and Acceptance

Acceptance is the observable behavior: **a request carrying a JSON schema yields a response
whose body validates against that schema.** The decisive demonstration is the M4 live smoke
run, which sends the `personSchema` and asserts the returned assistant text is a JSON object
with a string `name` and an integer `age` (the exact shape the schema requires), printing the
JSON as a transcript. A successful run looks like:

```text
[baikai-smoke] structured gpt-4o-mini ok via OPENAI_KEY; json={"name":"Ada Lovelace","age":36}
```

Layered, repeatable acceptance that does not require network access:

- `cabal build baikai && cabal build baikai-openai && cabal build baikai-claude && cabal
  build baikai-smoke` all succeed — proving the field and both mappings compile.
- `cabal test baikai-openai` and `cabal test baikai-claude` pass — the pure mapping tests
  prove that an `Options` carrying a `JsonSchema` produces a request whose `response_format`
  / `output_config` contains the exact schema, *without* any network call. These are the
  fail-before/pass-after tests: before M2/M3 the field does not exist (the test would not
  compile); after, it asserts the precise upstream shape.
- The no-key smoke run exits 0 with skip messages — proving the suite is safe in CI without
  secrets.

To see the change is effective beyond compilation: run the live smoke with a key and read
the transcript JSON; it is the model output constrained by the schema you attached. As an
extra manual check, you can temporarily mangle `personSchema` (e.g. require a field the
sentence cannot supply) and observe the model still returns *schema-conformant* JSON (it
will fabricate or null the field per the schema), confirming the provider is enforcing the
schema rather than the prompt.


## Idempotence and Recovery

All edits are additive and safe to repeat. Creating `Baikai/ResponseFormat.hs` is a new
file; re-running the edits to `Options.hs`, `Baikai.hs`, the two provider `Api.hs` files,
and the cabal/exposed-modules lists is idempotent because each adds a single field or list
entry — if it is already present, leave it. The smoke module is new; wiring it into
`Smoke.hs`/`baikai-smoke.cabal` is a one-time additive edit.

If a build fails partway, the failure is local to the package you just edited; fix that
package and re-run its `cabal build`. Nothing here is destructive: there are no migrations,
no file deletions, and the `Nothing` default for `responseFormat` guarantees every existing
call site and test behaves exactly as before. To roll back entirely, `git revert` the
milestone commits in the baikai repo; because the field defaults to off, partial application
(say, M1 + M2 without M3) is also safe — Anthropic simply ignores a not-yet-wired field
because `mapRequest` there would still default `output_config` to `Nothing`.

If the upstream SDK field names differ from those quoted here (the SDKs are pinned, so they
should not), confirm the current names by reading
`/Users/shinzui/Keikaku/hub/haskell/openai-project/openai/src/OpenAI/V1/ResponseFormat.hs`
and `/Users/shinzui/Keikaku/hub/haskell/claude-project/claude/src/Claude/V1/Messages.hs`
(search for `OutputConfig`/`jsonSchemaConfig`), and adjust the mapping helpers accordingly.


## Interfaces and Dependencies

This section pins the exact types and signatures that must exist at the end of each
milestone, and the cross-plan contract the sibling plan
`docs/plans/3-generic-derived-signatures-and-structured-io.md` mirrors. It is the
authoritative description of integration point #2 (request schema attachment / native
structured output) on the baikai side.

Libraries and modules used, and why:

- `aeson` (`Data.Aeson.Value`): carries the JSON Schema verbatim, matching baikai's existing
  `Tool.parameters :: Value` convention. baikai never validates the schema; it forwards it.
- The upstream `openai` SDK module `OpenAI.V1.ResponseFormat` (re-exported via
  `OpenAI.V1.Chat.Completions`): provides the wire `ResponseFormat`/`JSONSchema` types and
  the `response_format` field on `CreateChatCompletion`.
- The upstream `claude` SDK module `Claude.V1.Messages`: provides `OutputConfig`,
  `OutputFormat`, the `jsonSchemaConfig`/`jsonSchemaFormat` helpers, and the `output_config`
  field on `CreateMessage`.

Types and signatures that must exist:

- End of M1, in `Baikai.ResponseFormat` (and re-exported from `Baikai`):

  ```haskell
  data ResponseFormat
    = JsonSchema { name :: !Text, schema :: !Value, strict :: !Bool }
    | JsonObject
    deriving stock (Eq, Show, Generic)
    deriving anyclass (FromJSON, ToJSON)
  ```

  and the `Options` record gains `responseFormat :: !(Maybe ResponseFormat)` with
  `_Options` defaulting it to `Nothing`.

- End of M2, in `Baikai.Provider.OpenAI.Api`:

  ```haskell
  mkOpenAIResponseFormat :: ResponseFormat -> OpenAI.V1.ResponseFormat.ResponseFormat
  mapRequest :: Model -> Context -> Options -> Either Text Chat.CreateChatCompletion
  -- mapRequest now sets Chat.response_format = fmap mkOpenAIResponseFormat (opts ^. #responseFormat)
  -- mapRequest is added to the module export list for testing.
  ```

- End of M3, in `Baikai.Provider.Claude.Api`:

  ```haskell
  mkAnthropicOutputConfig :: ResponseFormat -> Claude.V1.Messages.OutputConfig
  mapRequest :: Model -> Context -> Options -> Either Text Messages.CreateMessage
  -- mapRequest now sets Messages.output_config = fmap mkAnthropicOutputConfig (opts ^. #responseFormat)
  -- mapRequest is added to the module export list for testing.
  ```

- End of M4, in `baikai-smoke`:

  ```haskell
  -- StructuredSmoke.hs
  data ApiCase = ApiCase { caseLabel :: !String, caseEnvVars :: ![String], caseModel :: !Model }
  runStructuredCase :: ApiCase -> IO Bool
  ```

**The cross-plan contract (integration point #2), for the sibling plan to mirror exactly.**
The sibling plan at `docs/plans/3-generic-derived-signatures-and-structured-io.md` consumes
this capability and must agree with it precisely:

1. **Attaching a schema.** To request native structured output, set
   `Baikai.Options.responseFormat` to `Just (JsonSchema { name, schema, strict })`, where
   `schema` is a JSON Schema as an aeson `Value`. To request plain-JSON mode, set it to
   `Just JsonObject`. Leave it `Nothing` for unconstrained output. The `name` is a short
   identifier the provider attaches to the schema (OpenAI requires it; Anthropic ignores
   it). `strict = True` requests strict enforcement (OpenAI honours it; Anthropic is always
   strict and drops the flag).

2. **Surfacing the response.** The structured JSON is returned as the assistant's **text
   content** — there is no new content kind. The consumer reads it with
   `flattenAssistantBlocks :: Response -> Vector AssistantContent` followed by collecting the
   `AssistantText (TextContent t)` blocks (the sibling plan can reuse the smoke suite's
   `flattenAssistantText` helper pattern), then JSON-decodes that text into its typed record.
   Because both OpenAI and Anthropic emit the structured payload as a single text block, the
   concatenated assistant text *is* the JSON document.

3. **Errors.** baikai itself does not validate the returned JSON against the schema; the
   provider enforces it. If the provider rejects the schema (malformed JSON Schema,
   unsupported feature) the failure arrives through baikai's normal error path — a
   terminal `EventError` on the stream, surfaced as a `BaikaiError` / error message on the
   assembled `Response` — not as a thrown exception mid-stream. The sibling plan's decoding
   layer is responsible for turning a syntactically-valid-but-shape-wrong body into its own
   typed error.

This contract is intentionally minimal: one optional `Options` field in, JSON text out. The
sibling plan owns schema *derivation* (record → `Value`) and *decoding* (text → record);
this plan owns only the transport attachment and the two provider mappings.
