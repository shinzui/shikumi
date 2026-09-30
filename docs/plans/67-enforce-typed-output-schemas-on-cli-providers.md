---
id: 67
slug: enforce-typed-output-schemas-on-cli-providers
title: "Enforce typed output schemas on CLI providers"
kind: exec-plan
created_at: 2026-09-30T14:54:38Z
intention: "intention_01m3scyv6pep0841b0j5rvkyhk"
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-09-30T14:54:38Z
  revisions:
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-09-30T16:06:58Z
      mode: "implement"
      note: "Milestones 1-3 implemented"
---

# Enforce typed output schemas on CLI providers

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Shikumi runs typed programs: a `Signature` names an input record and an output record, and
Shikumi asks a language model for the output and decodes the reply into that record. When the
model's host can *enforce* a JSON schema (it rejects or constrains any reply that does not fit),
Shikumi sends the output record's derived schema and the reply is guaranteed to decode. When it
cannot, Shikumi falls back to a text prompt and hopes the model writes the right shape.

Today every model reached through a subscription command-line tool (the `claude` CLI or the
`codex` CLI, used through Baikai's `claude-cli`/`codex-cli` providers) takes the text fallback,
even though both CLIs can now enforce a schema. Mina measured the consequence: 43 of 62 judge runs
through `codex-cli` failed to decode because the model wrote arrays of strings where arrays of
objects were required. The fallback prompt made it worse: it names each output field and its
description, but never says that a field is a list of objects or which keys and enum values those
objects have.

After this change, two things are true. First, a program run on a `claude-cli` or `codex-cli` model
takes the native path: Shikumi attaches the derived schema, Baikai hands it to the CLI
(`claude --json-schema`, `codex exec --output-schema`), and a list-of-records output decodes. Second,
a model that truly has no schema enforcement (for example an Ollama host) sees, in its fallback
prompt, the JSON shape of every structured field, including nested keys and closed enum values.

This work implements `mori://shinzui/shikumi/okf/improvement-requests/concepts/IR-4`
(`docs/improvement-requests/enforce-typed-output-schemas-on-cli-providers.md`). Its Baikai half,
`mori://shinzui/baikai/okf/improvement-requests/concepts/IR-11`, is complete.

You can see it working in three ways. A new hermetic test registers a fake CLI provider that returns
schema-conforming JSON only when it receives a schema, and returns malformed string arrays when it
does not. A typed program with a list of records decodes through it. A pinned-text test shows the
new fallback guide. After release, Mina's live `codex-cli` judges can drop their key-listing
workaround.


## Progress

- [x] Milestone 1 (2026-09-30): Shikumi builds against `baikai >=0.7.2.0`, `baikai-claude >=0.7.1.0` and
  `baikai-openai >=0.7.1.0`. `capabilityFor` returns `NativeSchema` for `AnthropicMessagesCli` and
  `OpenAICompletionsCli`. Existing HTTP routing, third-party Chat Completions hosts, `Custom` hosts
  and ReAct's tool-protocol choice for CLI models are unchanged. `cabal test shikumi shikumi-tools` passes.
  Evidence: `shikumi` 248 tests pass, including five new `capabilityFor` cases; `shikumi-tools` passes,
  including three new `ProtocolAuto` cases (codex CLI, claude CLI, deepseek → `ProtocolPrompt`). The
  CLI routing assertion lives in `CliSchemaSpec` (Milestone 2).
- [ ] Milestone 2: A typed program whose output holds a list of records with an enum field decodes
  through a scripted `AnthropicMessagesCli` provider that enforces the schema. The same provider
  registered under a fallback tag fails with the Mina-style `SchemaMismatch`.
- [ ] Milestone 3: `fallbackAdapter`'s guide renders the JSON shape of every object or array output
  field, and a pinned-text test fixes the rendered guide. Scalar-only guides are byte-for-byte
  unchanged. `cabal test all` passes.
- [ ] Milestone 4: `shikumi` and `shikumi-tools` are released to Hackage, bounded to the Baikai
  cohort that implements IR-11. IR-4 is marked completed with evidence.


## Surprises & Discoveries

- As of 2026-09-30 only `baikai-0.7.2.0` is on Hackage. `baikai-claude-0.7.1.0` and
  `baikai-openai-0.7.1.0` are tagged in the Baikai repository (commit `7dd44f9`) but return HTTP 404
  on Hackage, and both packages' preferred-version lists still stop at `0.7.0.0`. Milestones 1–3 build
  locally because the gitignored `cabal.project.local` points at the sibling Baikai checkout.
  Milestone 4 cannot ship until both provider packages are uploaded.

    ```text
    baikai-0.7.2.0: 200
    baikai-claude-0.7.1.0: 404
    baikai-openai-0.7.1.0: 404
    ```

- `shikumi-tools/src/Shikumi/Agent/ReAct.hs` (`resolveProtocolKind`) reuses `capabilityFor` to decide
  whether to use provider-native *tool calling*. Its comment says this depends on CLI models resolving
  to fallback, because Baikai silently drops tools for CLI providers. Schema support and tool-calling
  support are therefore different capabilities. Changing `capabilityFor` alone would break ReAct on
  CLI models. See the Decision Log.


## Decision Log

- Decision: Derive schema capability from Baikai's `declaredStructuredOutput (model ^. #api)`, but
  keep the first-party provider guard for the three HTTP API tags. The rule is: `NativeSchema` when
  Baikai declares `NativeJsonSchema` for the model's `api` and either the `api` is a CLI tag
  (`AnthropicMessagesCli`, `OpenAICompletionsCli`) or the `(provider, api)` pair is one of the three
  pairs that are native today.
  Rationale: The Baikai catalog serves `deepseek` and `openrouter` models over the
  `OpenAIChatCompletions` tag. Baikai sends the schema to them, but it cannot know whether those hosts
  enforce it, and IR-4 acceptance 4 requires existing native API routing to be unchanged. A CLI tag is
  always served by Baikai's own CLI provider, so Baikai's declaration is authoritative there.
  Date: 2026-09-30

- Decision: Give ReAct its own tool-calling capability check, preserving the pre-change table
  (`openai`+Chat Completions, `openai`+Responses, `anthropic`+Messages are native; everything else is
  prompt). Do not reuse `capabilityFor` for tools.
  Rationale: Baikai's CLI providers enforce schemas but still drop tools. Sharing one predicate would
  send CLI agents down a tool protocol that never executes.
  Date: 2026-09-30

- Decision: `Custom` API tags stay `PromptFallback`. Shikumi does not consult a provider registry's
  `ApiProvider.structuredOutput` field.
  Rationale: `capabilityFor` is a pure function of `Model`, and routing does not hold the registry.
  Reading the registry would change `Shikumi.Routing`'s interface for a case no consumer needs yet.
  Record it as follow-up work if one appears.
  Date: 2026-09-30

- Decision: The fallback guide adds a shape line only for output fields whose schema (ignoring
  nullability) is an object or an array. Scalars, including top-level enums such as the fixture's
  `sentiment`, render exactly as before. Nested field descriptions are omitted. The shape is compact
  JSON-like notation, not a full JSON Schema.
  Rationale: IR-4 acceptance 4 requires scalar-only fallback prompts to be unchanged. A one-line
  shape is short enough for small models and still carries every key and enum value.
  Date: 2026-09-30

- Decision: Pin the rendered guide with an inline expected `Text` in the test source, the way
  `shikumi/test/SchemaSpec.hs` pins `expectedSummarySchema`. Do not add `tasty-golden` or a golden
  file.
  Rationale: This needs no new test dependency and no `extra-source-files` entry for the sdist, and
  the expected text sits beside the assertion.
  Date: 2026-09-30

- Decision: Bound `baikai-claude` and `baikai-openai` at `>=0.7.1.0`, not only `baikai` at `>=0.7.2.0`.
  Rationale: With an older provider package, Shikumi would install the native JSON prompt and attach
  a `responseFormat` that the CLI provider silently ignores. That drops the marker fallback and gains
  no enforcement, which is worse than today.
  Date: 2026-09-30


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

The repository is a multi-package Cabal project. `cabal.project` lists the packages. Build inside the
Nix dev shell (`nix develop`), which provides GHC 9.12.4. The system GHC on `PATH` is the wrong compiler.
A gitignored `cabal.project.local` adds the sibling Baikai packages (`../baikai/baikai`,
`../baikai/baikai-claude`, `../baikai/baikai-openai`, `../baikai/baikai-effectful`) as local
packages. A local build therefore uses the Baikai working tree, not Hackage. A green local build does
not prove that a Hackage consumer resolves.

Some terms used below:

**Baikai** is the provider library Shikumi talks to models through. A `Baikai.Model` record has an
`api` field of type `Baikai.Api` (defined in `../baikai/baikai/src/Baikai/Api.hs`). Its constructors
are `OpenAIChatCompletions`, `OpenAIResponses`, `AnthropicMessages`, `OpenAICompletionsCli` (the
`codex` CLI), `AnthropicMessagesCli` (the `claude` CLI) and `Custom Text`. The model also has a
`provider` text such as `"openai"`, `"anthropic"`, `"deepseek"` or `"openrouter"`.

**Structured-output support** is Baikai's new capability signal (IR-11, released in `baikai-0.7.2.0`,
module `Baikai.ResponseFormat`, re-exported from `Baikai`):

```haskell
data StructuredOutputSupport = NativeJsonSchema | NoStructuredOutput

declaredStructuredOutput :: Api -> StructuredOutputSupport
-- AnthropicMessages, OpenAIChatCompletions, OpenAIResponses,
-- AnthropicMessagesCli, OpenAICompletionsCli -> NativeJsonSchema
-- Custom _                                   -> NoStructuredOutput
```

When a request's `Options.responseFormat` is `Just (JsonSchema fmt)`, `baikai-claude-0.7.1.0` passes
the schema as `claude -p --json-schema <schema>`. `baikai-openai-0.7.1.0` writes it to a temporary
file and passes `codex exec --output-schema <file>`. Both return the CLI's structured reply as the
response's assistant text, the same way the HTTP providers do. A CLI that is too old to know the flag
fails with Baikai's `InvalidRequest` category. Shikumi already surfaces that as a terminal
`ProviderError`.

**The adapter seam** is `shikumi/src/Shikumi/Adapter.hs`. An `Adapter i o` has two functions:
`render` builds a Baikai `Context` and `Options` from a signature and an input, and `parse` decodes a
Baikai `Response` into the output record. The file defines the following:

- `data ModelCapability = NativeSchema | PromptFallback`
- `capabilityFor :: Model -> ModelCapability` at about line 190. Today it is a fixed table: `("openai",
  OpenAIChatCompletions)`, `("openai", OpenAIResponses)` and `("anthropic", AnthropicMessages)` are
  `NativeSchema`, and everything else, including both CLI tags, is `PromptFallback`.
- `adapterFor`, which picks `nativeAdapter` or `fallbackAdapter` from `capabilityFor`.
- `fallbackAdapter`, whose system prompt is `systemHeader sig <> fallbackOutputGuide sig`.
- `fallbackOutputGuide :: Signature i o -> Text` at about line 396. It is not exported. It renders
  one `[[ ## field ## ]]` marker line per output field, with `  -- <description>` appended when the
  field has one, and ends with `[[ ## completed ## ]]`. `outputFields sig` yields `FieldMeta
  { fieldName, fieldDesc }` values (`shikumi/src/Shikumi/Schema/Types.hs`).

**Routing** is `shikumi/src/Shikumi/Routing.hs`. A program renders before it knows the real model,
so `Shikumi.Program.runPredict` always renders the fallback (marker) prompt. It also stamps
alternatives onto private `Options.metadata` keys: the derived schema under
`metaResponseSchemaKey` and the native JSON prompt and demos under `metaNativePromptKey` and
`metaNativeDemosKey`. `routeLLM` then calls `translateForWire` with the ambient model (supplied by
`runRouting model`). That function checks `capabilityFor m`. When the model is native, it sets
`responseFormat = JsonSchema (jsonSchemaFormat "output" schema){strict = True}` and swaps in the
native prompt. It strips the private keys in every case. Consequently, changing `capabilityFor` is
enough to route CLI models natively. No routing code changes.

**Derived schemas** come from `Shikumi.Schema.deriveSchema @o` and are Aeson `Value`s with every
definition inlined (no `$ref`). A record becomes `{"type":"object","properties":{…},"required":[…in
field order…],"additionalProperties":false}`. A list becomes `{"type":"array","items":…}`. An
enum-like sum of nullary constructors becomes `{"type":"string","enum":[…]}`. A `Maybe a` becomes
`{"anyOf":[<a>,{"type":"null"}]}`. Aeson's `KeyMap` does not preserve insertion order, so use the
`required` array for field order. `shikumi/test/SchemaSpec.hs` pins the full schema for the fixture
`Summary`.

**ReAct** (`shikumi-tools/src/Shikumi/Agent/ReAct.hs`) is the tool-using agent loop.
`resolveProtocolKind ProtocolAuto m` currently maps `capabilityFor m` to `ProtocolNative` (provider
function calling) or `ProtocolPrompt`. `shikumi-tools/test/ProtocolSpec.hs` tests it.

The relevant test infrastructure is as follows. The `shikumi` test suite (`shikumi/test/Main.hs`
aggregates the `*Spec` modules) is hermetic. `shikumi/test/StubProvider.hs` shows how to build an
isolated `ProviderRegistry` with `newProviderRegistry`, `registerApiProviderWith` and
`apiProviderWith <api> <stream> <complete>`. `shikumi/test/ContinuationSpec.hs` (around line 63)
shows the full runtime stack
`runEff . runErrorNoCallStack @ShikumiError . runRouting model . runLLMWith reg . routeLLM`.
`shikumi/test/ResponsesSpec.hs` asserts the exact `responseFormat` the router attaches.
`shikumi/test/Fixtures.hs` holds the `Summary` fixture (`headline`, `bullets :: [Text]`, `author ::
Author` record, `sentiment` enum, `note :: Maybe Text`).

Relevant ADRs:

- [docs/adr/0010-use-bounded-schema-guided-xml-fragments.md](../adr/0010-use-bounded-schema-guided-xml-fragments.md)
  (ADR-10) established that guides may be derived by walking `deriveSchema` (see `xmlSchemaGuide` in
  `shikumi/src/Shikumi/Adapter/Xml.hs`), and that automatic adapter routing did not change for that
  work. This plan does change automatic routing, but only through `capabilityFor`. The XML adapters
  stay opt-in.
- [docs/adr/0012-apply-request-defaults-before-cache-and-observation.md](../adr/0012-apply-request-defaults-before-cache-and-observation.md)
  (ADR-12) fixes the order routing → defaults → cache/trace → transport. Cache keys see the
  effective options. After this change a CLI request carries a `responseFormat` and a different
  system prompt, so previously cached CLI entries will simply miss. That is expected and not a
  migration concern.
- In Baikai, ADR `docs/adr/0009-provider-capability-facts-live-in-the-generated-catalog-record.md`
  of `mori://shinzui/baikai` (the artifact-level ADR URI is pending in Mori) records that
  per-transport facts are declared by the provider, not hand-tabled by callers. This plan follows
  that direction for the CLI tags and records in the Decision Log why the HTTP guard stays.

No other ADR bears on this work.


## Plan of Work

### Milestone 1: Capability-driven adapter selection

Raise the Baikai lower bounds. In `shikumi/shikumi.cabal`, change both the library and the test-suite
stanzas: `baikai >=0.7.2.0 && <0.8`, `baikai-claude >=0.7.1.0 && <0.8`,
`baikai-openai >=0.7.1.0 && <0.8`. Leave the other packages' `baikai >=0.7.1.0` bounds as they are.
They reach the new behavior through `shikumi`'s own bound. In `shikumi-tools/shikumi-tools.cabal`,
raise the `shikumi` lower bound to the version Milestone 4 releases, so ReAct's new tool check cannot
pair with an old `shikumi`. Do this in Milestone 4 when the version number is fixed.

Rewrite `capabilityFor` in `shikumi/src/Shikumi/Adapter.hs` as the Decision Log states, using
`declaredStructuredOutput` from `Baikai`:

```haskell
capabilityFor :: Model -> ModelCapability
capabilityFor m = case declaredStructuredOutput (m ^. #api) of
  NoStructuredOutput -> PromptFallback
  NativeJsonSchema
    | cliTransport || firstPartyApi -> NativeSchema
    | otherwise -> PromptFallback
  where
    cliTransport = m ^. #api `elem` [AnthropicMessagesCli, OpenAICompletionsCli]
    firstPartyApi = (m ^. #provider, m ^. #api) `elem`
      [("openai", OpenAIChatCompletions), ("openai", OpenAIResponses), ("anthropic", AnthropicMessages)]
```

Update its Haddock and the module header so they explain the rule and why third-party Chat
Completions hosts stay on fallback.

In `shikumi-tools/src/Shikumi/Agent/ReAct.hs`, stop calling `capabilityFor` from
`resolveProtocolKind`. Add a private `nativeToolCalling :: Model -> Bool` holding exactly the old
three-pair table, with a comment that Baikai drops tools for CLI providers. `ProtocolAuto` then
resolves `ProtocolNative` only when it is true. Update the module header comment, which currently
says `ProtocolAuto` resolves "via `capabilityFor`". Drop the now-unused imports.

Add tests. In `shikumi/test/AdapterSpec.hs`, add these `capabilityFor` cases:
`AnthropicMessagesCli` → `NativeSchema`; `OpenAICompletionsCli` → `NativeSchema`; `deepseek` +
`OpenAIChatCompletions` → `PromptFallback`; `openrouter` + `OpenAIChatCompletions` →
`PromptFallback`; `anthropic` + `AnthropicMessages` still `NativeSchema`. In
`shikumi-tools/test/ProtocolSpec.hs`, add these cases: `ProtocolAuto` on an `AnthropicMessagesCli`
model resolves `ProtocolPrompt`, and the same for `OpenAICompletionsCli`. Add a routing case, modeled
on `shikumi/test/ResponsesSpec.hs`, with a model `B.mkModel B.AnthropicMessagesCli "fixture"
"https://example.invalid"`. It asserts that the transport receives
`responseFormat = Just (B.JsonSchema (B.jsonSchemaFormat "output" schema & #strict .~ True))`. Put it
in `ResponsesSpec.hs` or a new `CliSchemaSpec.hs` (the new module is created in Milestone 2 anyway).

Acceptance: `cabal test shikumi shikumi-tools` passes, and the new cases fail if `capabilityFor` is
reverted.

### Milestone 2: Decode a list of records through a schema-enforcing CLI stub

Create `shikumi/test/CliSchemaSpec.hs` and register it in `shikumi/test/Main.hs` and in the
`other-modules` of the `shikumi` test suite in `shikumi/shikumi.cabal`. Define local fixture types
that mirror Mina's failing judges:

```haskell
data Severity = Blocker | Major | Minor
  deriving stock (Generic, Show, Eq)
-- ToSchema, FromModel, ToPrompt/PromptValue instances as Fixtures.hs does for Sentiment

data Concern = Concern
  { statement :: !(Field "What is wrong" Text),
    severity :: !Severity
  }

data Assessment = Assessment
  { concerns :: !(Field "Readiness concerns" [Concern]),
    verdict :: !(Field "Overall verdict" Text)
  }
```

Copy the instance boilerplate from `shikumi/test/Fixtures.hs` and `shikumi/test/ProgramFixtures.hs`.
Add a `Validatable` instance if the fixtures need one. Use a simple input record, or reuse `Article`.

Build a registry with one provider registered under `AnthropicMessagesCli`, following
`mkRegistry` in `StubProvider.hs`. Its `complete` function records the `Options` it receives in an
`IORef` and branches on `o ^. #responseFormat`. With `Just (JsonSchema _)`, it returns the conforming
JSON `{"concerns":[{"statement":"No rollback path","severity":"Blocker"}],"verdict":"not ready"}` as
assistant text. With `Nothing`, it returns what an unconstrained model wrote in Mina: marker sections
whose `concerns` is `["No rollback path"]`. Its stream function can reuse the same logic or
`Stream.nil`, because `Predict` uses `complete`.

The first test runs `runProgram (Predict sig emptyParams) input` through
`runRouting cliModel . runLLMWith reg . routeLLM`, where
`cliModel = B.mkModel B.AnthropicMessagesCli "fixture" "https://example.invalid"`. It asserts `Right`
of the expected `Assessment`. It also asserts that the recorded schema equals
`deriveSchema @Assessment`. The second test registers the identical provider under `Custom
"no-schema"`, runs the same program on a model with that tag, and asserts that the result is a
`Left` whose rendered error mentions `expected object, got string`. This control proves that the
routing decision, not the stub, made the difference. Use whatever exact constructor and message the
decoder produces, and record it in Surprises if it differs from Mina's text.

Acceptance: `cabal test shikumi --test-options='-p CliSchema'` shows both cases passing.

### Milestone 3: Nested shapes in the fallback output guide

Change `fallbackOutputGuide` to `forall i o. (ToSchema o) => Signature i o -> Text`, computing
`schema = deriveSchema @o`. Update its single call site in `fallbackAdapter` (which already has
`ToSchema o`). Grep for other callers first.
For each output field, keep the marker line exactly as today. If the field's property schema,
after stripping a nullable `anyOf [s, {"type":"null"}]` wrapper, has `"type"` `"object"` or
`"array"`, emit one further line:

```text
JSON shape: <shape>
```

`<shape>` is produced by a new private `renderShape :: Value -> Text` with these rules. `string`,
`integer`, `number` and `boolean` render as the bare type name. A string with `"enum"` renders as the
quoted values joined by ` | `. An array renders as `[<items shape>, ...]`. An object renders as
`{"k": <shape>, …}`, with keys in `required` order and any remaining properties sorted after them.
A nullable wrapper renders as `<shape> | null`. Anything else renders as `any JSON value`. For the
Milestone 2 `Assessment`, the guide should read:

```text
Reply using these sections, each marker on its own line:
[[ ## concerns ## ]]  -- Readiness concerns
JSON shape: [{"statement": string, "severity": "Blocker" | "Major" | "Minor"}, ...]
[[ ## verdict ## ]]  -- Overall verdict
[[ ## completed ## ]]
```

Treat this as the target. If the implemented bytes differ in some trivial way, pin the actual output
and record the difference here. Confirm that the marker parser (`parseMarkers`) ignores the new line.
It appears only in the system prompt, never in the model's reply, so this should hold. A demo reply
rendered by `renderOutputSections` is unchanged.

Expose the guide to tests without widening the public API. The simplest route is to assert on the
system prompt that `render fallbackAdapter sig input` produces, as `AdapterSpec`'s `sysOf` helper
already does. Add `shikumi/test/FallbackGuideSpec.hs` (or extend `AdapterSpec`). It needs three pinned
assertions. The first is the full `Assessment` system prompt, as an inline expected `Text`. The second
is a scalar-only signature (two `Text` fields and one enum), whose system prompt equals the
pre-change text exactly. Write that expected text by hand from the current code before editing the
guide, so the test proves it did not change. The third checks that the `Summary` fixture gains
`JSON shape:` lines for `bullets` (`[string, ...]`) and `author` (`{"name": string}`) only.

Run the whole workspace next. Other packages' tests assert on fallback prompts or fixture replies
(`shikumi-compile`, `shikumi-optimize`, `shikumi-trace`, `shikumi-eval`), and any cache-key or
snapshot fixture computed from a prompt with structured fields will change. Update only the
fixtures whose change is explained by the new shape line, and record each in Surprises.

Update the user guide `docs/user/signatures-and-schemas.md` in the section "The adapter seam: native
schema vs. prompt fallback". Say that the CLI providers now take the native path and that the
fallback guide shows JSON shapes for structured fields.

Acceptance: `cabal test all` passes, and the scalar-only pin proves the unchanged prompt.

### Milestone 4: Release

Release is blocked until `baikai-claude-0.7.1.0` and `baikai-openai-0.7.1.0` are on Hackage (see
Surprises). Then:

1. Move `cabal.project.local` aside and prove that the workspace resolves and tests from Hackage alone
   (see Concrete Steps). Restore it afterwards.
2. Add Unreleased entries to `shikumi/CHANGELOG.md` covering capability-driven selection, CLI
   native routing, nested fallback shapes and the tightened bounds. Name Baikai packages by
   `mori://shinzui/baikai/packages/<name>` URIs, as the existing entries do. Add an entry to
   `shikumi-tools/CHANGELOG.md` saying that ReAct's tool-protocol choice is unchanged but now has its
   own check.
3. Bump the versions. The public API only grows (no export is removed or retyped), but routing
   behavior changes for CLI models and the fallback prompt text changes for structured outputs. Use
   a minor bump at least: `shikumi 0.4.1.0` and `shikumi-tools 0.4.1.0`. Choose a major bump instead
   if the pending Unreleased entries already demand one. Raise `shikumi-tools`' `shikumi` bound to
   `>=0.4.1.0`. Several other packages also have `## Unreleased` sections. Whether to release them in
   the same cohort is a separate release decision; record it in the Decision Log when made.
4. Upload with the repository's usual Hackage flow. Hackage uploads use a configured token and work
   non-interactively. Tag the releases.
5. Mark `docs/improvement-requests/enforce-typed-output-schemas-on-cli-providers.md` completed,
   listing evidence per acceptance criterion, as Baikai's IR-11 file does.

Acceptance: `https://hackage.haskell.org/package/shikumi-<new version>` returns 200, and its cabal
file shows the Baikai bounds from Milestone 1.


## Concrete Steps

All commands run from the repository root, `/Users/shinzui/Keikaku/bokuno/shikumi`, inside
`nix develop`.

Check that the Baikai source used locally is the IR-11 cohort:

```bash
git -C ../baikai log --oneline -1
grep -n "declaredStructuredOutput" ../baikai/baikai/src/Baikai/ResponseFormat.hs
```

Expected: the log shows `7dd44f9 chore(release): baikai 0.7.2.0, baikai-claude 0.7.1.0, baikai-openai
0.7.1.0` or later, and the grep finds the definition.

Build and test per milestone:

```bash
cabal build shikumi shikumi-tools
cabal test shikumi shikumi-tools
cabal test shikumi --test-options='-p CliSchema'
cabal test all
```

Check Hackage availability before Milestone 4:

```bash
for p in baikai-0.7.2.0 baikai-claude-0.7.1.0 baikai-openai-0.7.1.0; do
  printf "%s: " $p; curl -s -o /dev/null -w "%{http_code}\n" https://hackage.haskell.org/package/$p
done
```

Expected before release: three lines ending in `200`.

Prove the Hackage-only resolution:

```bash
mv cabal.project.local cabal.project.local.off
cabal update
cabal build all && cabal test all
mv cabal.project.local.off cabal.project.local
```

Commit at each milestone with Conventional Commit messages and both trailers, for example:

```text
feat(adapter): route CLI models through the native schema adapter

Derive schema capability from Baikai's declaredStructuredOutput; keep
ReAct's tool-calling choice on its own table.

ExecPlan: docs/plans/67-enforce-typed-output-schemas-on-cli-providers.md
Intention: intention_01m3scyv6pep0841b0j5rvkyhk
```


## Validation and Acceptance

The work is accepted when each of the following holds. Each maps to an IR-4 acceptance criterion.

1. With a Baikai CLI model, `adapterFor` selects the native adapter and the routed request carries
   `responseFormat = JsonSchema "output"` (strict) with the derived schema. With `Custom` hosts and
   third-party Chat Completions hosts, `capabilityFor` still returns `PromptFallback`. This is shown
   by the Milestone 1 tests.
2. A program whose output is `Assessment` (a list of `Concern` records with a `Severity` enum)
   decodes through the scripted `AnthropicMessagesCli` provider, and fails with an "expected object,
   got string" mismatch through the same provider under a fallback tag. This is shown by
   `CliSchemaSpec`.
3. The fallback guide for `Assessment` shows the nested keys and enum values, pinned by
   `FallbackGuideSpec`.
4. The existing `capabilityFor` HTTP cases, `ResponsesSpec`, ReAct's `ProtocolSpec` and the
   scalar-only fallback pin all pass unchanged.
5. `shikumi` is on Hackage with `baikai >=0.7.2.0`, `baikai-claude >=0.7.1.0` and
   `baikai-openai >=0.7.1.0`.

As an optional live check (not required, and it needs a logged-in CLI), run a small typed program
with an `Assessment`-like output against the real `claude-cli` or `codex-cli` model from
`shikumi-jitsurei` or a scratch executable, and observe a decoded record. Record the result in
Outcomes if you run it.


## Idempotence and Recovery

Every milestone is an additive source change plus tests, and every command can be re-run. If
Milestone 1's bounds fail to resolve against Hackage, the cause is the unpublished provider
packages. Keep `cabal.project.local` in place for development and stop before Milestone 4. The
Hackage-only check moves `cabal.project.local` aside. If that step is interrupted, restore it with
`mv cabal.project.local.off cabal.project.local`. A Hackage upload cannot be undone. If a released
version is wrong, publish a follow-up version, or deprecate the bad one through Hackage's maintainer
page. Do not re-upload the same version.


## Interfaces and Dependencies

These are the dependencies after this plan: `baikai >=0.7.2.0 && <0.8` (for `StructuredOutputSupport`
and `declaredStructuredOutput`, re-exported from `Baikai`), `baikai-claude >=0.7.1.0 && <0.8` and
`baikai-openai >=0.7.1.0 && <0.8` (for the CLI schema passthrough).

The public interface in `Shikumi.Adapter` is unchanged in type:

```haskell
data ModelCapability = NativeSchema | PromptFallback
capabilityFor :: Model -> ModelCapability   -- behavior changes for CLI api tags only
adapterFor :: (ToSchema o, FromModel o, Validatable o, ToPrompt i, ToPrompt o) => Model -> Adapter i o
```

These additions and changes are private:

```haskell
-- shikumi/src/Shikumi/Adapter.hs (not exported)
fallbackOutputGuide :: forall i o. (ToSchema o) => Signature i o -> Text
renderShape :: Value -> Text

-- shikumi-tools/src/Shikumi/Agent/ReAct.hs (not exported)
nativeToolCalling :: Model -> Bool
```

`Shikumi.Routing.translateForWire` is not edited. It already derives its native decision from
`capabilityFor`.
