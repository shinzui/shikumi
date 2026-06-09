---
id: 3
slug: generic-derived-signatures-and-structured-io
title: "Generic-derived signatures and structured IO"
kind: exec-plan
created_at: 2026-06-08T02:44:16Z
intention: "intention_01ktjgkp10ef79vpwz1cmajek9"
master_plan: "docs/masterplans/1-shikumi-typed-lm-programming-framework.md"
---

# Generic-derived signatures and structured IO

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Shikumi (仕組み — "the mechanism behind how something works") is a Haskell framework for
writing language-model (LM) programs that behave like ordinary, well-typed software instead
of collections of prompt strings. An LM is a large language model — a service such as
Claude or GPT that takes text and returns text. The framework being built here lets a
developer declare an LM-powered function whose **input and output are ordinary Haskell
record types**, send a request to a provider, and get back a fully-decoded typed value —
without ever writing a raw prompt string or hand-parsing the model's reply.

This ExecPlan delivers the layer that makes that promise real: the bridge between a Haskell
**record type** and the **JSON the provider speaks**. Concretely, after this plan a
developer can write a pair of records like:

```haskell
data Article = Article
  { title :: Field "The article's headline" Text
  , body  :: Field "The full article text"  Text
  } deriving stock (Generic)

data Summary = Summary
  { headline :: Field "A one-line summary"        Text
  , bullets  :: Field "Three to five key points"  [Text]
  , sentiment :: Field "positive | neutral | negative" Sentiment
  } deriving stock (Generic)
```

and the framework will automatically: (1) derive a **JSON Schema** — a machine-readable
description of the shape of valid JSON, the same format OpenAI and Anthropic accept to
*force* a model's reply into a fixed structure — from the `Summary` record; (2) build a
provider request that attaches that schema and renders `Article` into the prompt; and
(3) decode the provider's JSON reply back into a `Summary` **totally**, meaning every
possible failure (malformed JSON, a missing field, a value of the wrong type, a value that
fails a validation rule) produces a precise, typed error value rather than a crash.

What you can do after this plan that you could not before, and how to see it working: you
can take a sample output record type, call `deriveSchema @Summary` and get back an aeson
`Value` (aeson is Haskell's standard JSON library; a `Value` is its in-memory JSON tree)
that equals a hand-written expected schema; and you can take a sample provider JSON string,
call `parseOutput @Summary`, and get back `Right (Summary {...})` for good input or
`Left (DecodeFailed ...)` with a pinpointed error for bad input. Every one of these is
checked by `cabal test` with golden fixtures (a "golden test" compares produced output
against a checked-in expected file), so success is observable without a live LM.

This plan also delivers the **`Signature`** — a value that bundles an *instruction* (the
natural-language task description, e.g. "Summarize the article") with the input and output
field metadata — and the **`Adapter`** seam, the swappable component that formats a request
and parses a response. Two adapters ship: a *native-schema* adapter that uses the
provider's structured-output mode, and a *prompt-based fallback* adapter for models that
lack native support. The instruction and the worked examples ("demonstrations") carried by
a `Signature` are **first-class, replaceable values** — later plans
(`docs/plans/9-compiler-layer.md`, `docs/plans/10-optimizer-framework.md`) rewrite them
automatically to improve quality, so this plan must expose them as data you can read and
swap, not as constants baked into code.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M0 (prototyping): **folded into M2/M3's real tests** rather than a throwaway
  `prototype/` package — the `GHC.Generics` schema + total-decode traversal is exercised
  directly by `SchemaSpec` (de-risk without a build-then-delete cycle; see Decision Log).
- [x] M1: `Shikumi.Schema.Types` — the `Field "desc" a` wrapper + `field`/`unField`,
  `FieldMeta`, `FieldPath` breadcrumbs (`pushField`/`pushIndex`/`renderPath`), and the
  JSON-Schema smart constructors (`objectSchema`/`stringSchema`/…/`nullableSchema`,
  `withDescription`).
- [x] M2: `Shikumi.Schema` — `ToSchema`/`deriveSchema` (record → aeson `Value`) over
  `Text`/`Int`/`Integer`/`Double`/`Bool`, `Maybe`, lists, `Vector`, nested records, and
  enum-like sums; `SchemaSpec` asserts `deriveSchema @Summary` equals the expected `Value`
  (descriptions, nested object, enum, optional `note`).
- [x] M3: `Shikumi.Schema` — total `FromModel`/`parseOutput` (`Value` → record) with the
  `InvalidJSON`/`MissingField`/`SchemaMismatch`/`ValidationFailure` taxonomy, each error
  carrying a rendered `FieldPath`; `Validatable` hook; all failing-case tests pass.
- [x] M4: `Shikumi.Signature` — `Signature i o` (instruction + demos + derived field
  metadata), `mkSignature`, and `getInstruction`/`setInstruction`/`getDemos`/`setDemos`
  (plus the free `#instruction`/`#demos` `generic-lens` optics via `Generic`).
- [x] M5: `Shikumi.Adapter` — the `Adapter` record seam, `render`/`parse`, `ToPrompt`, the
  prompt-based `[[ ## field ## ]]` fallback adapter, the native adapter (schema attach is a
  no-op `attachSchema` pending EP-2; native `parse` reads JSON from assistant text), and
  `capabilityFor`/`adapterFor`.
- [x] M6: `EndToEndSpec` drives a fake `LLM` interpreter through `Signature` + the fallback
  adapter, asserting a decoded `Summary` and a `MissingField` error.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **Error type reconciled to EP-1's actual shape.** This plan's draft assumed a richer
  `ShikumiError` with a structured `FieldPath` type (`MissingField FieldPath`,
  `SchemaMismatch FieldPath Text`, …). EP-1 (authoritative, already committed) ships
  `ShikumiError` with **flat `Text` payloads** (`MissingField !Text`, `SchemaMismatch !Text`,
  `InvalidJSON`, `ValidationFailure`, …) and **no `FieldPath` type**. Per the cross-plan rule
  (EP-1 is authoritative; adjust this plan's call sites), the decode walk threads a
  `FieldPath = [Text]` breadcrumb internally and renders it into the `Text` payload
  (`renderPath`, e.g. `"bullets"`, `"bullets.[2]"`). Precise location is preserved in the
  message without changing the committed shared type. Evidence: `Shikumi.Error.ShikumiError`
  in `shikumi/src/Shikumi/Error.hs`.
- **Project was already scaffolded by EP-1**, so all the placeholder `Shikumi.Error` / `LLM`
  shims and the `cabal.project`/package-creation steps in this plan's Context/Concrete Steps
  were skipped — the real modules exist.
- **baikai exports `flattenAssistantBlocks` but not a text flattener.** The plan referenced
  `Baikai.flattenAssistantText`; it does not exist (baikai's own tests define it locally).
  The adapter defines a small local `responseText` helper instead.
- **EP-2 has not landed**, so baikai's `Options` has no `responseFormat` field. `attachSchema`
  is a documented no-op and the native adapter's `parse` reads JSON from the assistant text;
  `capabilityFor` still reports the *true* capability (Anthropic/OpenAI non-CLI →
  `NativeSchema`) so its test is real. The fallback path is fully exercised.
- **`Validatable a` + `ToPrompt o` are required by the adapters** beyond the plan's sketched
  constraints: `Validatable o` so `parse` runs the post-decode rule, and `ToPrompt o` so demo
  outputs can be rendered as `[[ ## field ## ]]` sections (no JSON encoder exists for `o`).
  Documented in the Decision Log.


## Decision Log

Record every decision made while working on the plan.

- Decision: Use the **per-field wrapper newtype** `newtype Field (desc :: Symbol) a = Field a`
  (a `Symbol` is GHC's type-level string) as the field-description mechanism, rather than a
  separate `class FieldDoc` instance per record or a parallel description map.
  Rationale: three designs were weighed. (1) A separate value-level description map keyed by
  field name (`Map Text Text`) is simplest but lets the descriptions drift out of sync with
  the fields and offers no compile-time guarantee that every field is documented. (2) A
  per-record `class FieldDoc r where fieldDocs :: Map Text Text` keeps records clean (plain
  `Text` fields) but still relies on the author hand-writing and maintaining the map, and
  the `GHC.Generics` walk cannot recover the description, so the schema generator would need
  the class threaded through everywhere. (3) The `Field "desc" a` wrapper attaches the
  description *to the field's type*, so a single `Generic` traversal recovers both the field
  name (from the record selector metadata) and its description (from the `Symbol`, read via
  `KnownSymbol`/`symbolVal`), the description literally cannot drift from the field, and the
  type makes documentation visible at the use site. Its cost is ergonomic — fields are
  wrapped, so users write `Field x`/`unField` or use the `generic-lens` `#field` optics with
  a `coerce`. We mitigate by providing `field`/`unField` smart constructors, an
  `IsString`/`Num`-free but `Coercible`-friendly newtype, and `HasField`-style accessors. A
  bare-`Text`-field path is still supported (the schema generator falls back to "no
  description" when a field's type is not a `Field`), so the wrapper is opt-in per field.
  Date: 2026-06-08.

- Decision: Ship **two adapters behind one `Adapter` record-of-functions seam**, selected by
  a `ModelCapability` check, with the **native-schema adapter as the default** and the
  **prompt-based `[[ ## field ## ]]` fallback** used only when the model lacks native
  structured output.
  Rationale: provider-native structured output (the master plan's explicit choice, delivered
  upstream by `docs/plans/2-baikai-native-structured-output-extension.md`) is the reliable
  path — the provider enforces the schema — but not every model/endpoint supports it (older
  models, some OpenAI-compatible local hosts such as Ollama via baikai's `Custom` API tag).
  DSPy (the Python framework shikumi ports ideas from) solves the same problem with a
  `JSONAdapter` that prefers native structured output and falls back to a `ChatAdapter` that
  formats and re-parses `[[ ## field ## ]]`-delimited sections. Porting both gives shikumi
  the same robustness. A record-of-functions seam (rather than a typeclass) is chosen so an
  adapter is an ordinary value that can be swapped at call time and so capability selection
  is a pure function over a baikai `Model`, with no global state.
  Date: 2026-06-08.

- Decision: Hand-roll the schema/decoder derivation directly on `GHC.Generics` rather than
  pulling in a heavyweight schema library (e.g. `autodocodec`, `openapi3`, `aeson-schemas`).
  Rationale: the schema we emit is a small, fixed JSON-Schema subset shaped by what OpenAI's
  and Anthropic's structured-output endpoints accept (objects, `properties`, `required`,
  `type`, `items`, `enum`, `additionalProperties:false`), and we need *both* directions
  (schema-out and decode-in) plus our own error taxonomy and the `Field` description hook.
  A general library would impose its own schema model and error type and still not give us
  the description-from-`Symbol` mechanism for free, so hand-rolling on `GHC.Generics`
  (already a project dependency) is both lighter and a better fit. `aeson`'s own
  `GToJSON`/`GFromJSON` are reused where they fit (leaf decoding) but the schema walk is
  ours. Confirmed via `mori registry search aeson`: no in-tree schema library is registered;
  `aeson` itself is the only relevant dependency.
  Date: 2026-06-08.

- Decision: The shikumi error type (`Shikumi.Error.ShikumiError`) and the `LLM` effect are
  **owned by `docs/plans/1-shikumi-runtime-substrate-and-llm-effect-over-baikai.md`** (a hard
  dependency of this plan). This plan must *produce* `ShikumiError` values on decode failure
  and *consume* the `LLM` effect to issue calls; it must not define a competing error type.
  Until that sibling plan lands, this plan develops against a small local `ShikumiError`
  shim (described in Context and Orientation) that is deleted the moment the real type is
  available.
  Rationale: integration point #1 in the master plan mandates a single shared error type;
  inventing a second one would fork the taxonomy.
  Date: 2026-06-08.

- Decision (implementation, 2026-06-08): reconcile to EP-1's **flat-`Text`-payload**
  `ShikumiError` rather than the `FieldPath`-carrying shape this plan originally sketched.
  EP-1 is authoritative and already committed/consumed; changing its type would cascade. The
  decode walk threads a `FieldPath = [Text]` breadcrumb internally and renders it into the
  `Text` payload via `renderPath` (so `MissingField "bullets"`, `SchemaMismatch
  "bullets: expected array, got string"`). No change to the shared type. Date: 2026-06-08.

- Decision (implementation, 2026-06-08): **fold the M0 spike into the real `SchemaSpec`**
  instead of a throwaway `prototype/` package. The spike's purpose — de-risk the
  `GHC.Generics` schema + total-decode traversal — is met by `SchemaSpec`'s exact assertions,
  and EP-1 already proved the toolchain. This avoids a build-then-delete cycle. Date: 2026-06-08.

- Decision (implementation, 2026-06-08): **consolidate EP-3's specs into the existing
  `shikumi-test` suite** (`SchemaSpec`/`SignatureSpec`/`AdapterSpec`/`EndToEndSpec` as
  `other-modules`) rather than five separate `cabal` test-suite stanzas. One suite, one
  `cabal test shikumi-test`, less cabal churn; the named test groups still pinpoint each
  behavior. Date: 2026-06-08.

- Decision (implementation, 2026-06-08): the adapter constructors require `Validatable o`
  (so `parse` runs the post-decode rule) and `ToPrompt o` (so demo outputs render as
  `[[ ## field ## ]]` sections, since no JSON encoder for `o` exists), beyond the plan's
  sketched `(ToSchema o, FromModel o, ToPrompt i)`. `attachSchema` is a no-op until EP-2 adds
  `Options.responseFormat`; `capabilityFor` still reports the true native capability so its
  test is meaningful, while the fallback path is the one exercised end-to-end. Date: 2026-06-08.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

**Outcome (2026-06-08): EP-3 complete.** The record↔JSON bridge is real: a developer declares
`Article`/`Summary` records (with `Field "desc"`-typed fields), and the framework derives the
provider JSON Schema (`deriveSchema @Summary` equals the expected `Value`), totally decodes a
reply (`parseOutput`/`fromModel` → `Right Summary` or a precise located `ShikumiError`), bundles
the task as a `Signature Article Summary` with replaceable `instruction`/`demos`, and renders/
parses through an `Adapter` (the `[[ ## field ## ]]` fallback round-trips end-to-end through a
fake `LLM`). Integration point #3 (`Field`/`FieldMeta`, `ToSchema`/`FromModel`,
`Signature`/`Demo`/`mkSignature` + parameter accessors, `Adapter`/`capabilityFor`/`ToPrompt`)
exists with the documented signatures for EP-4/EP-9/EP-10/EP-11 to consume. `cabal test
shikumi-test` reports **All 35 tests passed** with no warnings, no network.

**Deviations from the written plan** (all in the Decision Log): error type reconciled to EP-1's
flat-`Text` `ShikumiError` (path rendered into the message); M0 spike folded into `SchemaSpec`;
specs consolidated into the one `shikumi-test` suite; adapters require `Validatable o` +
`ToPrompt o`; native schema attachment is a no-op pending EP-2 (fallback fully exercised).

**Gaps / future work:** the native structured-output path is implemented but inert until EP-2
lands `Options.responseFormat` (then flip `attachSchema` to set it and switch native `parse` to
read the structured payload — both are single, marked sites). Mixed sums (multiple constructors
*with* fields) are unsupported by `ToSchema` (only records → objects and nullary sums → enums);
they currently produce an ordinary "no instance" error rather than the plan's custom `TypeError`
— acceptable, noted for a later polish pass.


## Context and Orientation

This section assumes you know nothing about this repository. Read it fully before editing.

**The repository.** `shikumi` lives at `/Users/shinzui/Keikaku/bokuno/shikumi`. At the time
this plan begins, the repository contains only `docs/` (planning documents, including this
file) and `.claude/` (tooling). There is no Haskell code yet. The sibling plan
`docs/plans/1-shikumi-runtime-substrate-and-llm-effect-over-baikai.md` (referred to below as
"the substrate plan") is responsible for scaffolding the Cabal project — a `cabal.project`
at the repo root, a `shikumi` library package, and the `Shikumi.Error` and `Shikumi.LLM`
modules. This plan **hard-depends** on the substrate plan for two things: the shared error
type `Shikumi.Error.ShikumiError` and the `Shikumi.LLM` effect. It **soft-depends** on
`docs/plans/2-baikai-native-structured-output-extension.md` (referred to as "the baikai
schema plan") for the upstream ability to attach a JSON schema to a provider request.

Because both siblings may not yet exist when an implementer picks up this plan, the very
first thing to do is establish the build context. The recommended order is: implement the
substrate plan first (it scaffolds the project), then this plan. If you must start this plan
before the substrate plan is finished, create the minimum scaffolding yourself: a
`cabal.project` and a `shikumi` library package, plus a temporary
`Shikumi.Error` module containing only the `ShikumiError` shim described below, clearly
commented as a placeholder to be replaced. The Concrete Steps section spells this out.

**Cabal and the build.** "Cabal" is Haskell's build tool. A "package" is a unit of Haskell
code with a `.cabal` file listing its modules and dependencies. `cabal.project` at the repo
root tells Cabal which local packages exist and where to find non-Hackage dependencies.
Build everything with `cabal build all`; run tests with `cabal test all`. The shikumi
packages mirror the layout of `baikai` (the underlying provider library, see below): a
multi-package workspace with the core library named `shikumi`.

**baikai — the transport layer this builds on.** `baikai`
(`/Users/shinzui/Keikaku/bokuno/baikai`, "媒介 / mediation") is a published Haskell library
that talks to LM providers. Shikumi sits on top of it and never reimplements provider
dispatch. The pieces this plan touches:

- `Baikai.Context.Context` — the conversation part of a request:
  `Context { systemPrompt :: Maybe Text, messages :: Vector Message, tools :: Vector Tool }`.
  Build one from the empty base `_Context` using `generic-lens` optics, e.g.
  `_Context & #systemPrompt .~ Just "..." & #messages .~ msgs`. (`generic-lens` is a library
  that derives field accessors named `#fieldName`; `.~` sets a field; `&` is reverse
  application. These come in via `Baikai.Prelude`.)
- `Baikai.Options.Options` — the per-call knobs: `maxTokens`, `temperature`, `apiKey`,
  `timeoutMs`, `headers`, `metadata`, `toolChoice`, `cacheRetention`, `thinking`. Today
  there is **no** JSON-schema / `response_format` field. The baikai schema plan
  (`docs/plans/2-...`) adds one. This plan's native adapter writes into exactly that new
  field; until it exists, the native adapter is written but guarded behind a capability
  check that returns `False`, and the fallback adapter is the only one exercised by tests.
  See "Interfaces and Dependencies" for the agreed shape.
- `Baikai.Message.Message` — a sum of `UserMessage UserPayload | AssistantMessage
  AssistantPayload | ToolResultMessage ToolResultPayload`. Build user/assistant turns with
  the smart constructors `Baikai.Message.user :: Text -> Message`,
  `Baikai.Message.assistant :: Text -> Message` (both use a fixed fixture timestamp, which
  is exactly what we want for deterministic golden tests).
- `Baikai.Response.Response` — the provider reply:
  `Response { message :: AssistantPayload, model :: Model, api, provider, responseId,
  latencyMs }`. Pull the assistant text out with
  `Baikai.Response.flattenAssistantBlocks :: Response -> Vector AssistantContent` and
  `Baikai.flattenAssistantText :: Vector AssistantContent -> Text`. The native adapter
  reads the structured payload the baikai schema plan surfaces; the fallback adapter reads
  the flattened assistant text and re-parses the `[[ ## field ## ]]` sections.
- `Baikai.Model.Model` — the catalog record. The fields this plan inspects for capability
  selection are `modelId :: Text`, `provider :: Text`, `api :: Baikai.Api.Api`, and
  `compat :: Baikai.Compat.Compat`. The native-vs-fallback decision is a pure function of
  these (e.g. `provider == "openai"` or `"anthropic"` with a non-CLI `Api` ⇒ native capable;
  CLI APIs and unknown `Custom` hosts ⇒ fallback).
- `Baikai.Tool.Tool` — `Tool { name :: Text, description :: Text, parameters :: Value }`
  where `parameters` is a raw JSON-Schema `Value`. This plan's schema generator is the same
  one `docs/plans/11-typed-tools-and-react-agents.md` will reuse to fill `parameters`; this
  plan only needs to be aware that the generated schema must be shaped like a tool parameter
  schema (a JSON object schema).

To read baikai's API on disk, use `mori`: `mori registry show shinzui/baikai --full` lists
its packages and source path (`/Users/shinzui/Keikaku/bokuno/baikai`), and
`mori registry docs shinzui/baikai` lists guides such as
`/Users/shinzui/Keikaku/bokuno/baikai/docs/user/getting-started.md`. Do not search
`/nix/store` or the filesystem root.

**The shikumi error type (owned by the substrate plan).** Integration point #1 of the
master plan mandates a single enumerated error type, `Shikumi.Error.ShikumiError`, that the
substrate plan defines. This plan produces decode-side variants of it. The variants this
plan relies on (names are the contract; the substrate plan may add more):

```haskell
-- Owned by docs/plans/1-...; reproduced here as the contract this plan codes against.
data ShikumiError
  = InvalidJson    !Text              -- response body was not valid JSON at all
  | MissingField   !FieldPath         -- a required field was absent
  | SchemaMismatch !FieldPath !Text   -- a field had the wrong JSON type/shape (expected vs got)
  | ValidationFailed !FieldPath !Text -- a value parsed but failed a domain rule
  | ProviderFailure !Text             -- baikai-level failure (maps Baikai.Error.BaikaiError)
  | Timeout
  | BudgetExceeded
  deriving stock (Eq, Show)

-- A breadcrumb trail to the offending location, e.g. ["bullets", "[2]"].
newtype FieldPath = FieldPath [Text]
  deriving stock (Eq, Show)
```

If the substrate plan is not yet merged, create a temporary `Shikumi.Error` module with
exactly this content, marked with a comment `-- PLACEHOLDER: replace with the substrate
plan's Shikumi.Error`. When the real module lands, delete the placeholder and reconcile any
constructor-name differences (the substrate plan is authoritative; adjust this plan's call
sites, not the shared type).

**Key terms defined.**

- *JSON Schema*: a JSON document that describes the allowed shape of other JSON. Providers'
  structured-output modes accept a JSON Schema and constrain the model to emit conforming
  JSON. We emit the small subset providers accept: `{"type":"object","properties":{...},
  "required":[...],"additionalProperties":false}` for records; `{"type":"string"}` etc. for
  leaves; `{"type":"array","items":...}` for lists; `{"enum":[...]}` for enum-like sums.
- *Generic / `GHC.Generics`*: a GHC feature that gives a uniform, type-level representation
  of any `data`/`newtype` with `deriving Generic`. We walk that representation to discover a
  record's fields (names, types) without the user writing boilerplate.
- *`Symbol`*: a type-level string. `KnownSymbol s => symbolVal (Proxy @s) :: String` reads
  it back at value level. We carry per-field descriptions as `Symbol`s in the `Field`
  wrapper so the description travels with the field's type.
- *Adapter*: the swappable component that turns a `Signature` + inputs into a baikai request
  (`render`) and turns a baikai `Response` into a typed output (`parse`). DSPy's term; here
  it is a plain record of two functions.
- *Demonstration ("demo")*: a worked input→output example shown to the model in the prompt.
  Optimizers select and rewrite demos; we carry them as a list on the `Signature`.


## Plan of Work

The work proceeds in seven milestones. M0 is a throwaway spike that de-risks the single
biggest unknown — whether `GHC.Generics` can drive both schema emission and total decoding
of a record — before any real module is committed. M1–M3 build the schema engine
(`Shikumi.Schema`). M4 builds `Shikumi.Signature`. M5 builds the `Shikumi.Adapter` seam and
both adapters. M6 is the end-to-end acceptance test. Each milestone is independently
verifiable with `cabal test`.

### Milestone 0 — Prototyping spike: Generic schema + round-trip decode (throwaway)

**Scope.** Prove, in a single self-contained module with a `main`, that a `Generic`-derived
walk over a tiny record `Person { name :: Text, age :: Int }` can (a) emit the expected JSON
Schema `Value` and (b) decode a JSON object back into a `Person`, returning a precise error
for a missing or wrong-typed field. No `Field` wrapper, no adapters, no `Signature` — the
narrowest possible end-to-end slice.

**Why first.** The whole plan rests on the assumption that a hand-rolled `GHC.Generics`
walk can do *both* directions. If `GHC.Generics`'s record-selector metadata
(`Meta`/`Selector`/`selName`) and the `(:*:)`/`M1`/`K1` structure are awkward to traverse
for our purposes, we want to learn that on a 40-line spike, not after building five modules.
The spike also fixes the exact `Generic` traversal idiom the real modules will reuse.

**What will exist at the end.** A package directory `prototype/` with its own minimal
`.cabal` file and one executable module `Main.hs`. Running it prints the derived schema and
the decode results and exits non-zero if any assertion fails, so it doubles as a test.

**Work.** Create `prototype/prototype.cabal` declaring an executable `schema-spike`
depending on `base`, `aeson`, `text`, and `containers`. Create `prototype/Main.hs`. In it:

1. Define `data Person = Person { name :: Text, age :: Int } deriving (Generic, Show, Eq)`.
2. Define a class `GSchema (f :: Type -> Type)` with `gschema :: Proxy f -> [(Text, Value)]`
   returning per-field `(name, fieldSchema)` pairs, plus a top-level `schemaOf` that wraps
   those into a `{"type":"object","properties":...,"required":...}` object. Implement
   `GSchema` instances for `M1 D` (datatype), `M1 C` (constructor), `M1 S` (selector — read
   the field name via `selName`), `(:*:)` (product — concatenate), and `K1 R` for leaf types
   `Text` and `Int` via a small `LeafSchema` class (`leafSchema :: Proxy a -> Value`).
3. Define `GFromObj (f :: Type -> Type)` with
   `gfromObj :: Aeson.Object -> Either String (f p)` mirroring the same structure, reading
   each field by name with `KeyMap.lookup`, decoding the leaf with `aeson`'s
   `fromJSON`, and producing a `Left` describing the missing/mismatched field.
4. In `main`: assert `schemaOf (Proxy @Person)` equals the hand-written expected `Value`;
   assert decoding `{"name":"Ada","age":36}` yields `Right (Person "Ada" 36)`; assert
   decoding `{"name":"Ada"}` yields a `Left` mentioning `age`; assert decoding
   `{"name":"Ada","age":"x"}` yields a `Left` mentioning a type mismatch. Print PASS/FAIL
   and `exitFailure` on any failure.

**Commands & acceptance.** From the repo root:

```bash
cabal run schema-spike
```

Expected transcript (abridged):

```text
schema: {"type":"object","properties":{"name":{"type":"string"},"age":{"type":"integer"}},"required":["name","age"],"additionalProperties":false}
decode ok:        Right (Person {name = "Ada", age = 36})
decode missing:   Left "missing field: age"
decode mismatch:  Left "field age: expected integer, got string"
ALL ASSERTIONS PASSED
```

Acceptance: the command exits 0 and prints `ALL ASSERTIONS PASSED`. **Promotion/discard
criterion:** if the spike passes, the `GSchema`/`GFromObj` traversal idiom is promoted —
copied and generalized into `Shikumi.Schema` in M2/M3 — and the `prototype/` directory is
deleted in a later commit (record the deletion in Progress). If the spike reveals the
traversal is unworkable (e.g. selector metadata unavailable), stop and revise the Decision
Log with the alternative (e.g. `aeson`'s `GToJSON1`/Template Haskell) before proceeding.

### Milestone 1 — `Shikumi.Schema.Types`: error, schema helpers, and the `Field` wrapper

**Scope.** Establish the shared vocabulary the rest of the plan uses: the JSON-Schema
constructor helpers, a local `SchemaError` used internally during the walk (distinct from
the user-facing `ShikumiError`), the `Field` description wrapper, and the type-level
plumbing that recovers a field's description.

**What will exist at the end.** Module `Shikumi.Schema.Types` in the `shikumi` package
(file `shikumi/src/Shikumi/Schema/Types.hs`) exporting: the `Field` newtype and its
`field`/`unField` helpers; the `FieldMeta` record (`FieldMeta { fieldName :: Text,
fieldDesc :: Maybe Text }`); small smart constructors for schema `Value`s
(`objectSchema`, `stringSchema`, `integerSchema`, `numberSchema`, `boolSchema`,
`arraySchema`, `enumSchema`, `nullableSchema`); and a `module`-internal `DecodeCtx` carrying
the current `FieldPath` for error reporting.

**Work.** Create `shikumi/src/Shikumi/Schema/Types.hs`. Define:

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE KindSignatures #-}
newtype Field (desc :: Symbol) a = Field { unField :: a }
  deriving stock (Eq, Show)
  deriving newtype (...)   -- forward common instances via Coercible where useful

field :: a -> Field desc a
field = Field
```

Define `class KnownDesc (f :: Type -> Type)` only if needed for the generic walk; the
description is read where the field's type is `Field desc a` via `KnownSymbol desc =>
symbolVal (Proxy @desc)`. Provide the `FieldMeta` record and the schema smart constructors
returning `Data.Aeson.Value` (use `Data.Aeson.object`, `Data.Aeson.Array`,
`Data.Aeson.Key`/`Data.Aeson.KeyMap`). Add `nullableSchema :: Value -> Value` that wraps a
schema so it also permits JSON `null` (for `Maybe`), using the provider-accepted form
`{"type":["T","null"]}` or `{"anyOf":[<schema>,{"type":"null"}]}` — pick the `anyOf` form
(more portable across providers) and document the choice in a code comment.

**Acceptance.** A small unit test `test/SchemaTypesSpec.hs` (wired into the test suite in M2)
asserting `unField (field (5 :: Int)) == 5`, and that `stringSchema == object ["type" .=
("string" :: Text)]`, etc. Verified later with `cabal test`. At this milestone, ensure the
module compiles: `cabal build shikumi`.

### Milestone 2 — `Shikumi.Schema`: record → JSON Schema (`ToSchema`/`deriveSchema`)

**Scope.** The forward direction. Generalize the M0 spike into a real `ToSchema` class with
a default `GHC.Generics`-based method, covering the full type menu: `Text`, `Int`, `Double`,
`Bool`; `Maybe a` (optional/nullable); `[a]` and `Data.Vector.Vector a` (arrays); nested
records (objects); and enum-like sum types (constructors with no fields → a string `enum`).
Descriptions are recovered from `Field desc a`-typed fields.

**What will exist at the end.** Module `Shikumi.Schema` (file
`shikumi/src/Shikumi/Schema.hs`) exporting `class ToSchema a where toSchema :: Proxy a ->
Value` with a `default` method `genericToSchema` (via `Generic a, GToSchema (Rep a)`), the
top-level `deriveSchema :: forall a. ToSchema a => Value`, and base instances for the leaf
types and containers. Re-export `Field` and the schema helpers from `Shikumi.Schema.Types`.

**Work.** Create `shikumi/src/Shikumi/Schema.hs`. Define:

```haskell
class ToSchema a where
  toSchema :: Proxy a -> Value
  default toSchema :: (Generic a, GToSchema (Rep a)) => Proxy a -> Value
  toSchema _ = gToSchema (Proxy @(Rep a))

deriveSchema :: forall a. ToSchema a => Value
deriveSchema = toSchema (Proxy @a)
```

Implement `class GToSchema (f :: Type -> Type)` over the `GHC.Generics` representation:
`M1 D` delegates to the constructor layer; for a **single record constructor** the `(:*:)`
of `M1 S` selectors produces `properties` + `required`; for **multiple nullary
constructors** emit an `enumSchema` of the constructor names; mixed sums (multiple
constructors *with* fields) are out of scope for this milestone and must produce a clear
*compile-time* error via a custom `TypeError` (from `GHC.TypeLits`) so the user gets a
readable message rather than a confusing instance-resolution failure. For each record field
(`M1 S ('MetaSel ('Just name) ...) (K1 R t)`): the field name comes from the selector meta;
the field schema comes from `toSchema (Proxy @t)`; if `t` unifies with `Field desc u`, read
`desc` via `KnownSymbol` and attach `{"description": desc}` to the field schema and use
`toSchema (Proxy @u)` for the body; if `t` is `Maybe u`, the field is **omitted from
`required`** and its schema is `nullableSchema (toSchema (Proxy @u))`. Provide instances:
`ToSchema Text` (`stringSchema`), `ToSchema Int` (`integerSchema`), `ToSchema Double`
(`numberSchema`), `ToSchema Bool` (`boolSchema`), `ToSchema a => ToSchema [a]`
(`arraySchema (toSchema (Proxy @a))`), `ToSchema a => ToSchema (Vector a)` (same),
`ToSchema a => ToSchema (Maybe a)` (`nullableSchema (toSchema (Proxy @a))`), and
`(KnownSymbol d, ToSchema a) => ToSchema (Field d a)` (delegates to `toSchema (Proxy @a)`;
the description is attached at the record-field layer, not here, to keep this instance
composable — document this in a comment).

**Commands & acceptance.** Wire up a test suite (M1's spec joins it here). Create
`test/SchemaSpec.hs` with golden tests: a sample output record

```haskell
data Sentiment = Positive | Neutral | Negative deriving (Generic, Show, Eq)
instance ToSchema Sentiment
data Author = Author { name :: Field "Author full name" Text } deriving (Generic)
instance ToSchema Author
data Summary = Summary
  { headline  :: Field "A one-line summary" Text
  , bullets   :: Field "Three to five key points" [Text]
  , author    :: Author
  , sentiment :: Sentiment
  , note      :: Maybe Text
  } deriving (Generic)
instance ToSchema Summary
```

The test asserts `deriveSchema @Summary` equals a checked-in expected `Value`
(`test/golden/summary.schema.json`, read and compared as `Value` so key order does not
matter). Run:

```bash
cabal test shikumi:schema-test
```

Expected: the suite reports all cases passing. The golden file must contain
`headline`/`bullets`/`author`/`sentiment` in `required`, `note` absent from `required`,
`author` as a nested object schema, `sentiment` as a string `enum` of
`["Positive","Neutral","Negative"]`, and each `Field`-wrapped property carrying its
`description`. Acceptance is observable: editing a field's `Symbol` description and re-running
changes the golden comparison (demonstrating the description truly flows from the type).

### Milestone 3 — `Shikumi.Schema`: JSON → record, total (`FromModel`/`parseOutput`)

**Scope.** The inverse direction, and the heart of the totality guarantee. Given the
provider's JSON (an aeson `Value`), produce either the typed record or a precise
`ShikumiError`. Cover the same type menu as M2 and produce the right error variant for each
failure class: not-an-object / not valid JSON → `InvalidJson`; absent required field →
`MissingField path`; wrong JSON type → `SchemaMismatch path expected`; a value that decodes
but fails a user-supplied validation predicate → `ValidationFailed path msg`.

**What will exist at the end.** In `Shikumi.Schema`: `class FromModel a where fromModel ::
Value -> Either ShikumiError a` with a `default` `genericFromModel`, the convenience
`parseOutput :: forall a. FromModel a => Text -> Either ShikumiError a` (parses the `Text`
body to a `Value` first, mapping a JSON parse failure to `InvalidJson`), and base instances
for the leaf types/containers. A `GFromModel (Rep a)` class mirrors `GToSchema`.

**Work.** Add to `shikumi/src/Shikumi/Schema.hs`:

```haskell
class FromModel a where
  fromModel :: Value -> Either ShikumiError a
  default fromModel :: (Generic a, GFromModel (Rep a)) => Value -> Either ShikumiError a
  fromModel v = to <$> gFromModel (FieldPath []) v

parseOutput :: forall a. FromModel a => Text -> Either ShikumiError a
parseOutput body =
  case Data.Aeson.eitherDecodeStrict (Data.Text.Encoding.encodeUtf8 body) of
    Left  e -> Left (InvalidJson (Data.Text.pack e))
    Right v -> fromModel v
```

`GFromModel` threads a `FieldPath` (the breadcrumb to the current location) so every error
is precisely located. For a record constructor, for each selector: look the field up in the
JSON object by name; if absent and the field type is `Maybe u`, succeed with `Nothing`; if
absent otherwise, fail `MissingField (path <> [name])`; if present, recurse with
`path <> [name]`. Leaf instances (`FromModel Text/Int/Double/Bool`) check the JSON
constructor (`String`/`Number`/`Bool`) and fail `SchemaMismatch path "<expected>"` on
mismatch (e.g. a `String` where `Int` was wanted). `FromModel [a]`/`FromModel (Vector a)`
require a JSON `Array`, recursing into each element with the index appended to the path as
`"[i]"`. `FromModel (Maybe a)` maps JSON `null` to `Nothing` and anything else to
`Just <$> fromModel`. For enum-like sums, `genericFromModel` matches the JSON `String`
against the constructor names and fails `SchemaMismatch path "one of: ..."` otherwise.
`FromModel (Field d a)` delegates to `FromModel a` and re-wraps with `Field`. Provide a
hook for **validation**: a `Validatable a` companion class `validate :: a -> Either Text a`
defaulting to `Right`, applied after a successful decode so domain rules (e.g. "bullets has
3–5 elements") turn into `ValidationFailed path msg`. Wire `validate` into the record-field
recursion so the path is correct.

**Commands & acceptance.** Extend `test/SchemaSpec.hs` with round-trip and failing cases:

- Round-trip: take a `Summary` value, encode it to JSON with a matching `ToJSON` (or build
  the JSON literal by hand), feed the JSON to `fromModel`, and assert the result equals the
  original — for every supported type including the nested `Author`, the list, the enum, and
  a `Nothing`/`Just` `note`.
- Provider-JSON case: a checked-in `test/golden/summary.response.json` (a realistic provider
  reply) decodes to a specific expected `Summary`.
- Failing cases (one assertion each): missing required `headline` →
  `Left (MissingField (FieldPath ["headline"]))`; `bullets` given a string →
  `Left (SchemaMismatch (FieldPath ["bullets"]) "array")`; an out-of-set `sentiment` →
  `Left (SchemaMismatch (FieldPath ["sentiment"]) ...)`; a `bullets` list of length 1 with a
  `Validatable` rule requiring 3–5 → `Left (ValidationFailed (FieldPath ["bullets"]) ...)`;
  a non-JSON body `"not json"` via `parseOutput` → `Left (InvalidJson ...)`.

Run:

```bash
cabal test shikumi:schema-test
```

Acceptance: all cases pass; **each failing input yields the named error variant with the
exact `FieldPath`**. This is the master-plan acceptance for this plan's decode side: "a
sample provider JSON decodes to the expected value, with a failing case producing the right
shikumi error."

### Milestone 4 — `Shikumi.Signature`: instruction + demos + field metadata, replaceable

**Scope.** Bundle a task's instruction, its demonstrations, and the input/output field
metadata into a `Signature i o`, with the instruction and demos exposed as first-class,
replaceable values (the optimizable parameters of integration point #3).

**What will exist at the end.** Module `Shikumi.Signature` (file
`shikumi/src/Shikumi/Signature.hs`) exporting:

```haskell
data Demo i o = Demo { demoInput :: i, demoOutput :: o } deriving (Generic, Show, Eq)

data Signature i o = Signature
  { instruction  :: Text
  , demos        :: [Demo i o]
  , inputFields  :: [FieldMeta]   -- derived from i's record selectors + descriptions
  , outputFields :: [FieldMeta]   -- derived from o
  } deriving (Generic, Show)

mkSignature
  :: forall i o. (Generic i, Generic o, GFieldMetas (Rep i), GFieldMetas (Rep o))
  => Text -> Signature i o

-- first-class, replaceable parameters (lens-style read/replace)
getInstruction :: Signature i o -> Text
setInstruction :: Text -> Signature i o -> Signature i o
getDemos       :: Signature i o -> [Demo i o]
setDemos       :: [Demo i o] -> Signature i o -> Signature i o
```

**Work.** Create `shikumi/src/Shikumi/Signature.hs`. `mkSignature instr` builds a
`Signature` whose `inputFields`/`outputFields` come from a new `GFieldMetas` class that
walks `Rep i`/`Rep o` collecting `FieldMeta { fieldName, fieldDesc }` — reusing the exact
selector-and-`Field`-description traversal from M2 (factor that traversal into a shared
helper so M2 and M4 do not duplicate it). The `instruction` and `demos` start as the
supplied instruction and `[]`. Provide both record-update setters and, for downstream
optimizer ergonomics, expose `#instruction`/`#demos` `generic-lens` optics by deriving
`Generic` (the master plan's EP-9/EP-10 will use these to rewrite parameters). Document in a
comment that `inputFields`/`outputFields` are *derived metadata* (not optimizable) while
`instruction`/`demos` are *parameters* (optimizable, replaceable). Because `i` and `o` are
phantom-like in `FieldMeta` lists but real in `Demo`, the type keeps `i`/`o` so a downstream
program can hold a `Signature Article Summary` and the compiler enforces input/output types.

**Commands & acceptance.** Create `test/SignatureSpec.hs`: build
`sig = mkSignature @Article @Summary "Summarize the article"`; assert
`getInstruction sig == "Summarize the article"`; assert `getDemos sig == []`; assert
`outputFields sig` lists `headline`/`bullets`/`author`/`sentiment`/`note` with the expected
descriptions (proving metadata derivation matches M2's schema); assert
`getInstruction (setInstruction "New instruction" sig) == "New instruction"` and that
`setDemos [Demo a s] sig` is readable back via `getDemos` (proving replaceability). Run:

```bash
cabal test shikumi:signature-test
```

Acceptance: all pass; the replace-and-read assertions demonstrate the parameters are
first-class values.

### Milestone 5 — `Shikumi.Adapter`: the format/parse seam, native + fallback adapters

**Scope.** The seam between a typed `Signature`+inputs and the wire. `render` builds a
baikai `Context`+`Options` from a signature, an input value, and the demos; `parse` decodes
a baikai `Response` into the typed output via `Shikumi.Schema.FromModel`. Two adapters: the
**native-schema** adapter (attaches the derived JSON schema to baikai's `Options` via the
field added by `docs/plans/2-baikai-native-structured-output-extension.md`, and parses the
structured payload) and the **prompt-based fallback** (renders fields as
`[[ ## field ## ]]`-delimited sections in the prompt and re-parses them from the assistant
text). A capability check selects per model.

**What will exist at the end.** Module `Shikumi.Adapter` (file
`shikumi/src/Shikumi/Adapter.hs`) exporting:

```haskell
data Adapter i o = Adapter
  { render :: Signature i o -> i -> (Context, Options)
  , parse  :: Signature i o -> Response -> Either ShikumiError o
  }

data ModelCapability = NativeSchema | PromptFallback deriving (Eq, Show)

capabilityFor   :: Baikai.Model.Model -> ModelCapability
nativeAdapter   :: (ToSchema o, FromModel o, ToPrompt i) => Adapter i o
fallbackAdapter :: (ToSchema o, FromModel o, ToPrompt i) => Adapter i o
adapterFor      :: (ToSchema o, FromModel o, ToPrompt i) => Baikai.Model.Model -> Adapter i o
```

plus a small `ToPrompt i` class (`toPrompt :: i -> Text`) with a `Generic` default that
renders an input record's fields as labeled text (reusing the field-metadata traversal), so
inputs are presented to the model regardless of adapter.

**Work.** Create `shikumi/src/Shikumi/Adapter.hs`.

*`capabilityFor`* is a pure function over `Baikai.Model.Model`: return `NativeSchema` when
`provider model` is `"openai"` or `"anthropic"` and `api model` is a non-CLI API
(`OpenAIChatCompletions`/`AnthropicMessages`); otherwise `PromptFallback`. Keep the rule
small and documented; it can be refined as more models gain native support. `adapterFor m =
case capabilityFor m of NativeSchema -> nativeAdapter; PromptFallback -> fallbackAdapter`.

*Native adapter `render`*: build a system prompt from `getInstruction sig` plus the
output-field descriptions; build the `messages` vector from the demos (each demo rendered as
a user turn via `toPrompt` and an assistant turn carrying the demo output's JSON) followed by
the actual input rendered via `toPrompt`; set `Options` with the derived schema attached to
the new schema field. The exact field name/shape is the integration-point #2 contract
(see Interfaces and Dependencies); write the attachment behind a single helper
`attachSchema :: Value -> Options -> Options` so the one place that touches the baikai field
is easy to update when EP-2 finalizes the name. *Native adapter `parse`*: read the structured
payload baikai surfaces (per EP-2) — or, until EP-2 lands, fall back to reading the assistant
text as JSON — and run `fromModel`.

*Fallback adapter `render`*: build a system prompt that instructs the model to reply using
`[[ ## fieldName ## ]]` section markers, one per output field, followed by a final
`[[ ## completed ## ]]` marker (DSPy's convention). Render demos and the input the same way.
Attach **no** schema (the model is not capable). *Fallback adapter `parse`*: take
`flattenAssistantText (flattenAssistantBlocks resp)`, split it on the `[[ ## name ## ]]`
markers into a `Map fieldName Text`, assemble those into a JSON object `Value` (coercing each
section to the field's JSON type using the output schema as a guide — strings stay strings,
lists/numbers/bools are JSON-parsed), then run `fromModel`. A marker that is missing yields
the same `MissingField` error as the native path, so both adapters share the error taxonomy.

Write a single internal helper that turns the output schema + a `Map fieldName Text` into a
`Value` so the marker parser and any future adapter reuse it.

**Commands & acceptance.** Create `test/AdapterSpec.hs`:

- `capabilityFor`: assert a stub Anthropic `Model` (build from `Baikai.Model._Model` with
  `provider .~ "anthropic"`, `api .~ AnthropicMessages`) gives `NativeSchema`, and a
  `Custom "ollama"` model gives `PromptFallback`.
- Fallback `render`: assert the produced `Context`'s `systemPrompt` contains the instruction
  and `[[ ## headline ## ]]` etc., and that a demo appears as a user/assistant message pair.
- Fallback `parse`: hand it a `Response` (built from `Baikai.Response._Response` with a
  single `AssistantText` block whose text is a well-formed `[[ ## ... ## ]]` body) and assert
  it decodes to the expected `Summary`; hand it a body missing the `bullets` marker and assert
  `Left (MissingField (FieldPath ["bullets"]))`.
- Native `render`: assert `attachSchema` placed `deriveSchema @Summary` into the schema field
  of `Options` (guarded/skipped with a clear `pending` note if EP-2's field is not yet
  present in the local baikai checkout).

Run:

```bash
cabal test shikumi:adapter-test
```

Acceptance: all cases pass; the fallback round-trip and its missing-marker error are the
observable proof the seam works end to end without a live provider.

### Milestone 6 — End-to-end acceptance through a fake `LLM` interpreter

**Scope.** Tie schema + signature + adapter together against a *fake* `LLM` effect
interpreter (no network), proving the full path: input record → rendered request → fake
canned response → parsed output record, plus the error path.

**What will exist at the end.** A test `test/EndToEndSpec.hs` that defines a pure/in-memory
interpreter for the `Shikumi.LLM` effect (from the substrate plan) returning a canned
`Baikai.Response.Response`, runs a tiny `predict`-like driver
(`runSig :: (LLM :> es) => Adapter i o -> Signature i o -> i -> Eff es (Either ShikumiError o)`
defined locally in the test, since the real `predict` belongs to
`docs/plans/4-typed-program-representation-and-core-modules.md`), and asserts the decoded
`Summary` for a good canned response and the right `ShikumiError` for a malformed one.

**Work.** In the test, interpret `LLM` with `interpret` from `Effectful.Dispatch.Dynamic`
(the substrate plan exposes the effect's call as something like `complete :: Model -> Context
-> Options -> LLM m Response`). The interpreter ignores the request and returns a fixture
`Response`. `runSig adapter sig i = do { let (ctx, opts) = render adapter sig i; resp <-
complete someModel ctx opts; pure (parse adapter sig resp) }`. Assert the good and bad paths.
If the substrate plan's effect is not yet available, the Concrete Steps describe a minimal
local `LLM` effect shim used only by this test, deleted when the real effect lands.

**Commands & acceptance.**

```bash
cabal test shikumi:end-to-end-test
```

Expected (abridged):

```text
End-to-end (fallback adapter)
  good response decodes to Summary           OK
  malformed response -> MissingField bullets OK
All 2 tests passed.
```

Acceptance: the suite passes. This is the master-plan acceptance restated end-to-end: given
a sample output record type, a sample provider reply decodes to the expected value through a
`Signature`+`Adapter`, and a failing reply produces the right shikumi error.


## Concrete Steps

Run all commands from the repository root `/Users/shinzui/Keikaku/bokuno/shikumi` unless
stated otherwise.

**Step 0 — Confirm or create the build context.** Check whether the substrate plan has
scaffolded the project:

```bash
ls cabal.project shikumi/shikumi.cabal 2>/dev/null
```

If both exist, confirm `Shikumi.Error` and `Shikumi.LLM` are present:

```bash
ls shikumi/src/Shikumi/Error.hs shikumi/src/Shikumi/LLM.hs 2>/dev/null
```

If the project is **not** scaffolded, create the minimum: a `cabal.project` listing
`packages: shikumi/` and a `source-repository-package` (or `packages:
../baikai/baikai/`) stanza for baikai, a `shikumi/shikumi.cabal` declaring the `shikumi`
library with dependencies `base, aeson, text, containers, vector, bytestring, lens,
generic-lens, baikai`, and a placeholder `shikumi/src/Shikumi/Error.hs` containing the
`ShikumiError`/`FieldPath` shim shown in Context and Orientation, commented as a placeholder.
To locate baikai for the stanza, run `mori registry show shinzui/baikai --full` and use the
reported path `/Users/shinzui/Keikaku/bokuno/baikai`.

**Step 1 — M0 spike.** Create `prototype/prototype.cabal` and `prototype/Main.hs` as
described in Milestone 0. Add `packages: prototype/` to `cabal.project` temporarily. Then:

```bash
cabal run schema-spike
```

Confirm `ALL ASSERTIONS PASSED`. Record the result in Progress. Leave `prototype/` in place
until M3 is done, then remove it and its `cabal.project` entry in a dedicated commit.

**Step 2 — M1.** Create `shikumi/src/Shikumi/Schema/Types.hs`. Add the module to
`other-modules`/`exposed-modules` in `shikumi/shikumi.cabal`. Build:

```bash
cabal build shikumi
```

**Step 3 — M2.** Create `shikumi/src/Shikumi/Schema.hs` (forward direction) and the test
machinery. Add a test suite stanza to `shikumi/shikumi.cabal`:

```cabal
test-suite schema-test
  type:             exitcode-stdio-1.0
  main-is:          SchemaSpec.hs
  hs-source-dirs:   test
  build-depends:    base, aeson, text, containers, vector, shikumi
  default-language: GHC2024
```

Add `test/golden/summary.schema.json`. Run:

```bash
cabal test shikumi:schema-test
```

**Step 4 — M3.** Extend `Shikumi.Schema` with the decode direction and extend
`test/SchemaSpec.hs`; add `test/golden/summary.response.json`. Re-run
`cabal test shikumi:schema-test`. Then delete `prototype/` and its `cabal.project` line.

**Step 5 — M4.** Create `shikumi/src/Shikumi/Signature.hs` and `test/SignatureSpec.hs`; add
a `signature-test` suite stanza analogous to step 3. Run `cabal test shikumi:signature-test`.

**Step 6 — M5.** Create `shikumi/src/Shikumi/Adapter.hs` and `test/AdapterSpec.hs`; add an
`adapter-test` suite stanza. Run `cabal test shikumi:adapter-test`. If baikai's `Options`
does not yet carry the EP-2 schema field, the native-adapter schema-attachment assertion is
marked pending (a no-op `True` with a comment); the fallback path must still pass fully.

**Step 7 — M6.** Create `test/EndToEndSpec.hs` and an `end-to-end-test` suite stanza
(depending additionally on `effectful`). Run `cabal test shikumi:end-to-end-test`, then the
whole suite:

```bash
cabal test all
```

**Step 8 — Commit.** Commit after each green milestone with a Conventional Commit message
and the three trailers. Example for M3:

```text
feat(schema): total JSON->record decode with located shikumi errors

MasterPlan: docs/masterplans/1-shikumi-typed-lm-programming-framework.md
ExecPlan: docs/plans/3-generic-derived-signatures-and-structured-io.md
Intention: intention_01ktjgkp10ef79vpwz1cmajek9
```


## Validation and Acceptance

The plan is accepted when `cabal test all` is green and the following observable behaviors
hold, each backed by a named test:

- **Schema derivation matches an expected JSON** (M2, `schema-test`): `deriveSchema @Summary`
  equals `test/golden/summary.schema.json` compared as an aeson `Value`, including nested
  object schemas, the string `enum` for `Sentiment`, `note` excluded from `required`, and
  every `Field`-wrapped property carrying its `description`. Changing a field's `Symbol`
  description changes the comparison, proving the description flows from the type.
- **Provider JSON decodes to the expected value** (M3, `schema-test`):
  `test/golden/summary.response.json` decodes via `fromModel` to the expected `Summary`, and
  a hand-built `Summary` round-trips JSON → record → equal.
- **Each failure class yields the right located error** (M3, `schema-test`): missing field →
  `MissingField`, wrong type → `SchemaMismatch`, bad enum value → `SchemaMismatch`,
  validation-rule violation → `ValidationFailed`, non-JSON body → `InvalidJson`, each with the
  exact `FieldPath`.
- **Instruction and demos are replaceable** (M4, `signature-test`): `setInstruction`/
  `setDemos` write values that `getInstruction`/`getDemos` read back.
- **The adapter seam works without a live provider** (M5, `adapter-test`): the fallback
  adapter renders `[[ ## field ## ]]` sections and re-parses them into a `Summary`, with a
  missing marker producing `MissingField`; `capabilityFor` selects native vs fallback per
  model.
- **End-to-end through a fake interpreter** (M6, `end-to-end-test`): a canned good response
  decodes to a `Summary` and a malformed one produces the right `ShikumiError`.

Interpret results: each `cabal test` invocation prints `N tests passed` (or the framework's
equivalent). A non-zero exit or any `FAIL`/`Left` mismatch is a failure; the test name points
at the unmet behavior above.


## Idempotence and Recovery

All steps are additive and may be re-run. `cabal build`/`cabal test` are naturally
idempotent. Creating modules and test files is safe to repeat (overwrite with the same
content). The one removal — deleting `prototype/` after M3 — is safe because the spike's
traversal idiom has by then been promoted into `Shikumi.Schema`; if you later want it back,
it is reconstructable from Milestone 0's description. The temporary `Shikumi.Error` and
`LLM` shims are deleted only once the substrate plan's real modules exist; if you delete them
prematurely and the build breaks, re-create them from the snippets in Context and
Orientation / Milestone 6. Editing `cabal.project` and `.cabal` stanzas is reversible; keep
the baikai dependency stanza pointing at `/Users/shinzui/Keikaku/bokuno/baikai`.


## Interfaces and Dependencies

**Libraries.** `aeson` (JSON `Value`, `object`, `Key`, `KeyMap`, `eitherDecodeStrict`,
`fromJSON`) — the JSON model both directions speak; confirmed via
`mori registry search aeson` as the only relevant in-tree JSON library, so no schema library
is added. `text`, `containers`, `vector`, `bytestring` — standard data types
(`Text`/`Map`/`Vector`/`ByteString`). `GHC.Generics` + `GHC.TypeLits`
(`KnownSymbol`, `symbolVal`, `TypeError`) — the derivation engine and the type-level
descriptions. `lens` + `generic-lens` — `#field` optics for first-class parameter access on
`Signature` (these arrive via baikai's prelude conventions). `baikai` — `Context`,
`Options`, `Message`, `Response`, `Model`, `Tool`, and the `user`/`assistant`/
`flattenAssistantText` helpers. `effectful` — only in the M6 test, to interpret the `LLM`
effect.

**Owned by this plan (integration point #3 — the `Signature` + field-metadata mechanism).**
At completion these must exist with these signatures (full module paths):

- `Shikumi.Schema.Types.Field :: Symbol -> Type -> Type` (newtype `Field desc a`), with
  `field :: a -> Field desc a`, `unField :: Field desc a -> a`.
- `Shikumi.Schema.Types.FieldMeta` (`{ fieldName :: Text, fieldDesc :: Maybe Text }`) and the
  schema smart constructors (`objectSchema`, `stringSchema`, `integerSchema`, `numberSchema`,
  `boolSchema`, `arraySchema`, `enumSchema`, `nullableSchema`).
- `Shikumi.Schema.ToSchema (a :: Type)` with `toSchema :: Proxy a -> Value` and
  `deriveSchema :: forall a. ToSchema a => Value`.
- `Shikumi.Schema.FromModel (a :: Type)` with `fromModel :: Value -> Either ShikumiError a`
  and `parseOutput :: forall a. FromModel a => Text -> Either ShikumiError a`; plus the
  `Validatable a` hook (`validate :: a -> Either Text a`).
- `Shikumi.Signature.Signature i o`, `Shikumi.Signature.Demo i o`,
  `Shikumi.Signature.mkSignature`, and the parameter accessors
  `getInstruction`/`setInstruction`/`getDemos`/`setDemos` (plus `#instruction`/`#demos`
  optics). These are the first-class, replaceable optimizable parameters consumed by
  `docs/plans/4-typed-program-representation-and-core-modules.md`,
  `docs/plans/9-compiler-layer.md`, and `docs/plans/10-optimizer-framework.md`.
- `Shikumi.Adapter.Adapter i o`, `Shikumi.Adapter.ModelCapability`,
  `Shikumi.Adapter.capabilityFor`, `Shikumi.Adapter.nativeAdapter`,
  `Shikumi.Adapter.fallbackAdapter`, `Shikumi.Adapter.adapterFor`, and `ToPrompt i`.

**Consumed from siblings.**

- *Integration point #1 (hard dep,
  `docs/plans/1-shikumi-runtime-substrate-and-llm-effect-over-baikai.md`):*
  `Shikumi.Error.ShikumiError` and `FieldPath` (this plan emits decode-side variants), and
  the `Shikumi.LLM` effect (this plan issues calls through it in M6). This plan must not
  define its own error type or LLM effect; the local shims are temporary.
- *Integration point #2 (soft/integration dep,
  `docs/plans/2-baikai-native-structured-output-extension.md`):* the new
  `Baikai.Options.Options` field `responseFormat :: Maybe ResponseFormat` (EP-2 owns the type
  `ResponseFormat = JsonSchema { name :: Text, schema :: Value, strict :: Bool } | JsonObject`
  in `Baikai.ResponseFormat`), and the way the structured response is surfaced — EP-2 returns
  the structured JSON through the existing assistant `AssistantText` content, so no
  `Baikai.Response.Response` type change is needed. This plan touches that field in exactly
  one place, the `attachSchema :: Value -> Options -> Options` helper inside `Shikumi.Adapter`,
  and reads the structured payload in exactly one place, the native adapter's `parse`. The
  agreed contract (documented identically here and in EP-2) is: `attachSchema` sets
  `#responseFormat .~ Just (JsonSchema { name = <signature name>, schema = deriveSchema @o,
  strict = True })`, where `deriveSchema @o` is the aeson `Value` JSON-object schema this plan
  produces; when the field is left `Nothing` the request is an ordinary unconstrained call,
  and the native adapter's `parse` reads the JSON from the assistant text. Until EP-2 lands,
  `attachSchema` is a no-op stub and `capabilityFor` must return `PromptFallback` for all
  models so tests exercise the fallback path only.

**Reused by later siblings (no action here beyond the signatures above).** The schema
generator (`deriveSchema`) is reused by `docs/plans/11-typed-tools-and-react-agents.md` to
fill `Baikai.Tool.Tool.parameters`; the `Signature` parameters are reused by EP-4/EP-9/EP-10
as noted above. Keep `deriveSchema`'s output a plain JSON object schema so it drops directly
into a tool's `parameters` field.


---

Revision note (2026-06-08): Initial authoring of EP-3 from the skeleton. Fleshed out all
narrative sections per the ExecPlan specification: a Purpose grounded in user-visible
behavior (record → schema → typed value with total decoding), six implementation milestones
plus a throwaway prototyping spike (M0), concrete commands with expected transcripts,
behavior-phrased acceptance backed by named `cabal test` suites and golden fixtures, and the
full Interfaces and Dependencies contract for integration point #3 (owned) and points #1/#2
(consumed). Seeded the Decision Log with the four scoping decisions the prompt required: the
field-description mechanism (the `Field desc a` wrapper, with the alternatives weighed), the
two-adapter native-vs-fallback design, the hand-rolled-Generics-over-library choice, and the
shared-error-type ownership. Frontmatter, section names, and section order were left
unchanged. Reason: convert the planned-but-unauthored EP-3 into a fully self-contained,
implementable plan as directed by the master plan and research dossier.
