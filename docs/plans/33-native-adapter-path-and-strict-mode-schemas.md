---
id: 33
slug: native-adapter-path-and-strict-mode-schemas
title: "Native Adapter Path and Strict-Mode Schemas"
kind: exec-plan
created_at: 2026-07-02T03:30:15Z
intention: "intention_01kwjfe4dhetqa7m7g3n6zq03a"
master_plan: "docs/masterplans/5-core-runtime-correctness-and-wire-fidelity.md"
---

# Native Adapter Path and Strict-Mode Schemas

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

When a shikumi program runs against a provider with native structured output (OpenAI Chat
Completions, Anthropic Messages), the request is self-contradictory today: the router
forces a strict JSON `responseFormat`, while the prompt instructs the model to answer in
`[[ ## field ## ]]` marker sections and shows it marker-formatted examples. It mostly works
only because constrained decoding overrides the prompt. Three concrete harms follow:
(a) when a native JSON reply fails to decode, the user sees a misleading `MissingField`
error from the marker parser instead of the real JSON decode error; (b) the derived JSON
Schemas violate OpenAI strict mode (`strict: true` requires every property listed in
`required` — optional fields must be required-but-nullable — and enum schemas must carry a
type), so real strict-mode calls can be rejected by the provider; (c) the native prompt
guide and demo rendering are dead code, so the model is taught the wrong reply format.

After this change: a native model receives a prompt that describes the JSON object it must
produce and demos rendered as JSON; a fallback model receives exactly today's marker
prompt, byte for byte; a JSON reply that fails to decode reports the precise, located
native error; and `deriveSchema` output is accepted by OpenAI strict mode. All of it is
provable offline with the existing capturing-stub router tests plus deliberately updated
schema goldens.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1 (2026-07-03): `parseResponse` keeps the native error when the body parses as JSON; regression test added (`ProgramSpec` "EP-33: a native JSON body of the wrong shape keeps the located native error" — asserts `Left (SchemaMismatch "points: expected array, got number")`, green)
- [ ] M2: `Maybe` fields required-but-nullable; `enumSchema` gains `"type": "string"`; `SchemaSpec` golden deliberately updated; repo-wide schema-pin survey done
- [ ] M3: native demo rendering (`nativeDemoMessages`) implemented in `nativeAdapter`
- [ ] M3: native render channel — `runPredict` stamps the native system prompt and demo texts; `translateForWire` swaps them in for native-capable models and strips the keys; router tests added
- [ ] Docs: `xmlAdapter` reachability documented; haddocks updated; CHANGELOG entry


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

- Decision: Resolve the render/format contradiction with a per-run adapter-selection
  channel realized on the existing private request-metadata channel: `runPredict` renders
  the fallback prompt exactly as today and additionally stamps the native alternative (the
  native system prompt text and the native demo texts) under two new reserved metadata
  keys; the router (`translateForWire`), which is the first place the real model is known,
  swaps them in for native-capable models and strips the keys before transport.
  Rationale: `runProgram`'s constraint row `(LLM :> es, Error ShikumiError :> es)` is a
  frozen integration point (master plan 1, integration point #4), so `runPredict` cannot
  ask a `Routing` effect which model is ambient; rendering must stay model-agnostic and
  the decision must move to the router. Alternatives rejected: stamping a whole
  re-rendered `Context` as JSON (rejected: `Baikai.Context` has `ToJSON` but no `FromJSON`,
  and adding one is an out-of-scope cross-repo change); adding an adapter argument to the
  `Predict` constructor (rejected: GADT change rippling through traversal, serialization,
  and every downstream pattern match, for a decision that is per-model, not per-node);
  keeping the contradiction and relying on constrained decoding (rejected: wastes prompt
  tokens, teaches demos in the wrong format, and Anthropic's native path is
  prompt-sensitive). Un-routed runs (no `routeLLM` installed — the hermetic stub path)
  keep today's fallback prompt byte-for-byte; the stamps are inert there, exactly like the
  existing schema/temperature stamps.
  Date: 2026-07-01

- Decision: Optional (`Maybe`) fields become required-but-nullable in derived object
  schemas, and `enumSchema` gains `"type": "string"`. The pinned golden in
  `shikumi/test/SchemaSpec.hs` is updated as part of the same milestone.
  Rationale: OpenAI strict mode (`strict: true`, which `routeLLM` already always sets at
  `shikumi/src/Shikumi/Routing.hs:100-103`) requires every property to appear in
  `required`, expressing optionality as nullability; and requires every schema node to
  carry a type. The current golden pins the wrong (strict-mode-violating) shape — the
  update is deliberate and called out, not a test regression. The decode path is already
  tolerant of both absent keys and explicit `null` for `Maybe` fields
  (`shikumi/src/Shikumi/Schema.hs:280-284`), so no decode change is needed.
  Date: 2026-07-01

- Decision: Native demos are rendered by reusing the fallback path's typed coercion:
  the demo output's prompt fields are assembled into a JSON object via the existing
  `sectionsToObject` (which coerces each field's text against the derived schema), then
  encoded to text. `xmlAdapter` remains explicitly out of the runtime's automatic
  selection: it is a caller-directed wire format used via direct `Adapter` values (as
  `twoStep` uses `fallbackAdapter`), and this plan documents that instead of inventing a
  per-node adapter field.
  Rationale: `sectionsToObject` already implements exactly the text-to-typed-JSON coercion
  needed and keeps one source of truth; there is no `o -> Value` inverse (`FromModel` has
  no dual) so a direct JSON render would require a new class on every output type.
  Per-node XML selection needs a `Program` GADT change disproportionate to a MEDIUM
  finding; documenting reachability honestly closes the review item.
  Date: 2026-07-01


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This is a cabal multi-package Haskell repo built with GHC 9.12.4 inside the Nix dev shell:
run `nix develop .#ghc9124` from the repository root before any `cabal` command. All tests
are hermetic. The work here is confined to the core `shikumi/` package and its test suite,
plus a survey of schema pins in sibling packages.

How a `Predict` node reaches the wire today. `runPredict`
(`shikumi/src/Shikumi/Program.hs:304-321`) renders model-agnostically: it always calls
`adapterFor placeholderModel` (line 314), and `placeholderModel = _Model` (an inert empty
model, lines 248-249) maps to `PromptFallback` capability
(`shikumi/src/Shikumi/Adapter.hs:170-174`), so the prompt is always the fallback adapter's:
a system prompt ending in `fallbackOutputGuide` (Adapter.hs:315-319, the
"Reply using these sections… `[[ ## field ## ]]`" text) and demos rendered as marker
sections (`demoMessages`/`renderOutputSections`, Adapter.hs:331-340). It then stamps the
derived JSON schema onto the request's private metadata channel (`attachSchema`, line 319
of Program.hs; keys defined in Adapter.hs:191-198) and issues `complete placeholderModel …`
through the `LLM` effect.

The router. `routeLLM` (`shikumi/src/Shikumi/Routing.hs:84-88`) intercepts each outgoing
`Complete`, reads the ambient model, and calls `translateForWire` (Routing.hs:94-107),
which turns the stamped schema into
`responseFormat = JsonSchema {name = "output", schema = s, strict = True}` for
native-capable models (lines 100-103), sets any stamped temperature, and strips the private
keys. Nothing touches the `Context` — so the marker prompt goes out even when the JSON
`responseFormat` is set. `nativeAdapter`'s `render` (Adapter.hs:220-232) and its
`nativeOutputGuide` (Adapter.hs:308-311) are unreachable from the runtime; only
`nativeAdapter`'s `parse` is exercised (via `parseResponse`, next paragraph). `xmlAdapter`
(Adapter.hs:260-275) is likewise unreachable from `runProgram`; it is only usable by code
that holds an `Adapter` value directly.

The parse path. `parseResponse` (Program.hs:330-339) cannot know which wire shape came
back, so it tries the native parse (whole-body JSON, then typed decode) and falls back to
the marker parser:

```haskell
parseResponse sig' resp =
  case parse (nativeAdapter @i @o) sig' resp of
    Right o -> Right o
    Left _ -> parse (fallbackAdapter @i @o) sig' resp
```

The `Left _` discards the native error. If a native model replies with JSON that fails the
typed decode (say `{"points": 42}` where a string array is required), the real error is
`SchemaMismatch "points: expected array, got number"` — but the marker parser then finds no
`[[ ## … ## ]]` sections in the JSON body, produces an empty object, and reports
`MissingField "points"`, which is what the user sees. Misleading and mislocated.

The schemas. `objectSchema` (`shikumi/src/Shikumi/Schema/Types.hs:125-132`) builds
`required` from per-field required flags; `FieldSchema (Maybe a)`
(`shikumi/src/Shikumi/Schema.hs:133-134`) returns `(nullableSchema …, False)`, excluding
`Maybe` fields from `required`. `enumSchema` (Schema.Types.hs:155-156) emits
`{"enum": […]}` with no `"type"`. Both shapes violate OpenAI strict mode, which the router
unconditionally requests (`strict = True`). The current shape is pinned by
`expectedSummarySchema` in `shikumi/test/SchemaSpec.hs:18-45` — line 43 omits `note`
(a `Maybe Text` field) from `required`, and line 40 pins the type-less enum. That golden
pins the wrong shape today and must be updated deliberately by this plan.

Terms. "Native-capable" means `capabilityFor model == NativeSchema` (OpenAI Chat
Completions or Anthropic Messages APIs; Adapter.hs:170-174). The "metadata channel" is
`Options.metadata`, a `Map Text Value` shikumi uses for private stamps the router consumes
and strips (`metaResponseSchemaKey`, `metaTemperatureKey`). A "demo" is a worked
input/output example attached to a signature; on the wire it becomes a user/assistant
message pair before the real user turn.

Related plans (this plan is self-contained; these are coordination notes): EP-32
(`docs/plans/32-fix-validatable-dispatch-in-program-runners.md`) adds a `Validatable o`
constraint to `runPredict` — rebase constraint rows if it lands first. EP-34
(`docs/plans/34-route-and-unify-program-streaming.md`) adds a `Stream` case to `routeLLM`
that must reuse the `translateForWire` this plan widens (master plan integration point 3)
and re-exports `parseResponse` — keep both names and modules stable.


## Plan of Work

Milestone 1 — keep the native error when the body is JSON. Scope: `parseResponse` only.
At the end, a JSON reply that fails typed decode reports the native, located error;
non-JSON (marker) replies behave exactly as before; one new regression test proves it.

Export `assistantJSON` from `shikumi/src/Shikumi/Adapter.hs` (it exists, private, at lines
380-384: it concatenates the assistant text blocks and JSON-parses them, returning
`Left (InvalidJSON …)` on parse failure). Add it to the module export list with a haddock
noting it is the native path's pre-parse, exported for `parseResponse`'s format detection.

Rewrite `parseResponse` (`shikumi/src/Shikumi/Program.hs:330-339`) to branch on whether the
body is JSON at all, rather than on whether the whole native parse succeeded:

```haskell
parseResponse sig' resp =
  case assistantJSON resp of
    -- The body is JSON: this is the native wire shape. Keep the native
    -- parser's error — falling back to the marker parser on a JSON body
    -- produced a misleading MissingField before.
    Right _ -> parse (nativeAdapter @i @o) sig' resp
    -- Not JSON: the fallback / marker wire shape (un-routed runs and
    -- fallback-capability models). Exact prior behavior.
    Left _ -> parse (fallbackAdapter @i @o) sig' resp
```

Update the function's haddock (lines 323-329) to describe the new rule, including the
accepted edge case: a body that is a bare JSON scalar (e.g. `42`) now reports the native
`SchemaMismatch` ("expected object") instead of a marker `MissingField` — strictly more
accurate. `assistantJSON` runs twice on the native path (detection, then inside `parse`);
that is fine at this call rate.

Test (failing before, passing after), added to `shikumi/test/ProgramSpec.hs` using
`ProgramFixtures.runScriptedLLM` and `ProgramFixtures.mkResponse`: script the response body
`{"points": 42}` for `runProgram (Predict topicToOutline emptyParams) (Topic "haskell")`
(output `Outline` has `points :: [Text]`) and assert
`Left (SchemaMismatch "points: expected array, got number")`. Before this change the result
is `Left (MissingField "points")`.

Milestone 2 — strict-mode schema shape. Scope: the two schema emitters and every test that
pins their output. At the end, `deriveSchema` output satisfies OpenAI strict mode and the
goldens pin the new shape.

Edit `shikumi/src/Shikumi/Schema.hs:133-134` — the `FieldSchema (Maybe a)` instance keeps
its nullable schema but becomes required:

```haskell
instance (ToSchema a) => FieldSchema (Maybe a) where
  fieldSchema _ = (nullableSchema (toSchema (Proxy @a)), True)
```

Update the `FieldSchema` class haddock (lines 124-126): "'Maybe' is optional/nullable"
becomes "required-but-nullable, per OpenAI strict mode". The decode side needs no change:
`FromField (Maybe a)` (Schema.hs:280-284) already accepts a missing key, an explicit
`null`, or a value — so fallback-model replies that omit the field still decode.

Edit `shikumi/src/Shikumi/Schema/Types.hs:155-156`:

```haskell
-- | @{"type":"string","enum":[...]}@ for an enum-like sum of nullary
-- constructors. Strict mode requires the explicit type.
enumSchema :: [Text] -> Value
enumSchema names = object ["type" .= ("string" :: Text), "enum" .= names]
```

Update the pinned golden `expectedSummarySchema` in `shikumi/test/SchemaSpec.hs:18-45`:
`sentiment` gains `"type" .= s "string"` (line 40) and `required` (line 43) becomes
`["headline", "bullets", "author", "sentiment", "note"]`. Add a comment above the golden
stating the pre-EP-33 shape violated OpenAI strict mode and the pin was updated
deliberately (this plan's id as the reference). Then survey the repo for other pins of the
old shape and fix any found (tool schemas in `shikumi-tools` are built from the same
`objectSchema`, so their tests may pin `required` lists that now include `Maybe` fields);
`shikumi/test/RoutingSpec.hs:120` compares against `deriveSchema @Outline` symbolically and
self-updates. Record the survey result in Surprises & Discoveries.

Milestone 3 — native render channel and native demos. Scope: `Shikumi.Adapter`,
`Shikumi.Program.runPredict`, `Shikumi.Routing`, router tests. At the end a routed
native-capable request carries the native guide and JSON demos; a routed fallback request
and every un-routed request are byte-for-byte unchanged.

Step 3a — native demo rendering in the adapter (single source of the demo texts, and a fix
for direct `nativeAdapter` users). In `shikumi/src/Shikumi/Adapter.hs` add:

```haskell
-- | Render a demo output as the JSON object a native model is asked to reply
-- with. Reuses 'sectionsToObject' so each field's text coerces against the
-- derived schema exactly as the fallback parse path coerces marker sections.
renderOutputNative :: forall o. (ToSchema o, ToPrompt o) => o -> Text
renderOutputNative o =
  decodeUtf8 (LBS.toStrict (Aeson.encode obj))
  where
    obj = sectionsToObject (deriveSchema @o) (Map.fromList (toPromptFields o))

-- | Demo turns for the native path: user prompt as usual, assistant turn as
-- the JSON object (not marker sections).
nativeDemoMessages ::
  forall i o. (ToSchema o, ToPrompt i, ToPrompt o) => Signature i o -> [Message]
nativeDemoMessages sig = concatMap one (getDemos sig)
  where
    one (Demo i o) = [user (toPrompt i), assistant (renderOutputNative @o o)]
```

(`Aeson.encode` is lazy bytes; add imports for `Data.Aeson qualified as Aeson`,
`Data.ByteString.Lazy qualified as LBS`, and `Data.Text.Encoding (decodeUtf8)`.) Switch
`nativeAdapter`'s `render` (Adapter.hs:224-232) from `demoMessages sig` to
`nativeDemoMessages sig`. `fallbackAdapter` and `xmlAdapter` keep their demo renderers.

Step 3b — the channel keys, defined next to the existing ones (after Adapter.hs:198):

```haskell
-- | Reserved metadata key carrying the full native-format system prompt
-- (instruction + native output guide) as a JSON string. Stamped by
-- 'Shikumi.Program.runPredict'; the router swaps it in for native-capable
-- models and strips it before transport.
metaNativePromptKey :: Text
metaNativePromptKey = "shikumi.native.systemPrompt"

-- | Reserved metadata key carrying the native-format demo assistant turns, in
-- order, as a JSON array of strings. Same lifecycle as 'metaNativePromptKey'.
metaNativeDemosKey :: Text
metaNativeDemosKey = "shikumi.native.demos"
```

Add two exported helpers: `attachNativeRender :: Text -> [Text] -> Options -> Options`
(stamps both keys, mirroring `attachSchema`'s lens usage) and
`nativeRenderPieces :: (ToSchema o, ToPrompt i, ToPrompt o) => Signature i o -> (Text,
[Text])` returning
`(systemHeader sig <> nativeOutputGuide sig, [renderOutputNative @o o | Demo _ o <- getDemos sig])`
— this keeps `systemHeader`/`nativeOutputGuide` private. Export the two keys and both
helpers.

Step 3c — stamp in `runPredict` (`shikumi/src/Shikumi/Program.hs:312-321`). After the
existing `attachSchema` line, using the effective (post-`Params`-overlay) signature
`sig'`:

```haskell
let (nativeSys, nativeDemos) = nativeRenderPieces @i @o sig'
    opts = attachNativeRender nativeSys nativeDemos (attachSchema (deriveSchema @o) opts0)
```

Un-routed runs simply carry two extra inert metadata entries, exactly as the schema stamp
already does; the hermetic stub interpreters ignore metadata.

Step 3d — teach the router. Widen `translateForWire`
(`shikumi/src/Shikumi/Routing.hs:94-107`) to
`Model -> Context -> Options -> (Context, Options)`. For a native-capable model with both
stamps present: replace `Context`'s `systemPrompt` with the stamped native prompt, and
replace the text of the assistant messages in `Context.messages`, in order, with the
stamped demo texts. A `Predict`-rendered context's assistant turns are exactly the demo
outputs in order; if the assistant-turn count differs from the stamped list length, leave
the messages untouched (defensive — also covers non-`Predict` `Complete` calls, which carry
no stamps at all and are never rewritten). For fallback-capability models the context is
unchanged. In all cases strip `metaNativePromptKey` and `metaNativeDemosKey` along with the
existing two keys. Update `routeLLM`'s `Complete` case to
`let (ctx', opts') = translateForWire m ctx opts in complete m ctx' opts'`.

Step 3e — tests, in `shikumi/test/RoutingSpec.hs`. Extend its capturing stub to also record
the `Context` (today it records `(Model, Options)`; make it `(Model, Context, Options)` and
mechanically update the existing cases). New cases:

- "native model receives the native output guide": route `predict topicToOutline` to
  `openai_gpt_4o_mini`; assert the captured system prompt contains
  `"Reply with a JSON object containing these fields:"` and does not contain `"[[ ##"`.
  Fails before (marker guide on the wire), passes after.
- "native model receives JSON demos": build the signature with one demo via
  `Shikumi.Signature.setDemos`, route it, and assert the assistant demo turn's text parses
  as a JSON object carrying the demo's field, with no `"[[ ##"` marker. Fails before,
  passes after.
- "fallback model prompt unchanged and native stamps stripped": route to `_Model`; assert
  the system prompt still contains the marker guide, `responseFormat` is `Nothing`, and
  neither native key appears in the captured metadata.
- The existing cases (`routesModelId`, `nativeAttachesSchema`, `fallbackLeavesSchemaUnset`,
  the three temperature cases) must keep passing.

Step 3f — documentation. Haddock on `xmlAdapter` (Adapter.hs:252-259) gains an explicit
reachability paragraph: it is not selectable by the runtime router by design; use it by
holding the `Adapter` value directly inside an `embed` node, the way
`Shikumi.Module.twoStep` uses `fallbackAdapter`. Update the module headers of
`Shikumi.Adapter` (lines 7-25) and `Shikumi.Routing` (lines 4-33) to describe the widened
channel. Add a `shikumi/CHANGELOG.md` entry covering the provider-visible schema-shape
change and the native prompt change.


## Concrete Steps

All commands run from the repository root (`/Users/shinzui/Keikaku/bokuno/shikumi`), inside
the dev shell — the project requires GHC 9.12.4, which only the shell provides:

```bash
nix develop .#ghc9124
cabal build shikumi
cabal test shikumi          # or: just test-one shikumi
```

Work milestone by milestone; each is independently green. For M1, write the parse-error
test first and watch it fail:

```text
  native JSON decode failure keeps the native error: FAIL
    expected: Left (SchemaMismatch "points: expected array, got number")
     but got: Left (MissingField "points")
```

For M2, after editing the emitters, `cabal test shikumi` fails only on
"deriveSchema @Summary matches the expected JSON Schema" until the golden is updated — that
failure is the deliberate pin update, not a regression. Then run the repo-wide survey and
full build:

```bash
grep -rn '"required"\|"enum"' --include='*.hs' shikumi shikumi-tools shikumi-compile shikumi-eval shikumi-optimize shikumi-okf shikumi-trace | grep -v dist-newstyle
cabal build all && cabal test all
```

For M3, iterate on the routing suite:

```bash
cabal test shikumi --test-options='-p Routing'
```

Every commit uses a conventional-commit subject and MUST carry these trailers:

```text
MasterPlan: docs/masterplans/5-core-runtime-correctness-and-wire-fidelity.md
ExecPlan: docs/plans/33-native-adapter-path-and-strict-mode-schemas.md
Intention: intention_01kwjfe4dhetqa7m7g3n6zq03a
```

Suggested split, one commit per milestone: `fix(program): keep native parse errors for
JSON bodies`, `fix(schema)!: strict-mode required/enum shape`, `feat(adapter): native
render channel and JSON demos`.


## Validation and Acceptance

Acceptance is behavioral, all offline:

1. Parse fidelity: for a scripted reply `{"points": 42}` against a `Topic -> Outline`
   predict, `runProgram` returns
   `Left (SchemaMismatch "points: expected array, got number")` (before:
   `Left (MissingField "points")`). Marker-format replies decode exactly as before — the
   whole existing suite stays green.
2. Schema shape: `deriveSchema @Summary` (fixture in `shikumi/test/Fixtures.hs`) lists
   `note` in `required` with its `anyOf [string, null]` schema, and the `sentiment` enum
   carries `"type": "string"` — pinned by the updated `SchemaSpec` golden. `cabal test all`
   passes after the pin survey.
3. Wire coherence: under `runRouting openai_gpt_4o_mini … routeLLM`, the captured request
   carries (a) `responseFormat = JsonSchema {…, strict = True}` (existing test), (b) a
   system prompt containing the native guide and no `[[ ##` markers (new test, fails
   before), (c) demo assistant turns that are JSON objects (new test, fails before), and
   (d) no `shikumi.*` metadata keys. Under `runRouting _Model` the prompt is today's marker
   prompt and `responseFormat` stays unset.
4. Un-routed behavior unchanged: `ProgramSpec`, `EndToEndSpec`, `ModuleSpec`, `StreamSpec`
   pass unmodified (aside from any goldens M2 updates).


## Idempotence and Recovery

All steps are source edits plus hermetic tests; safe to re-run indefinitely. M2 is
provider-visible (it changes what real OpenAI/Anthropic calls send) — if a live regression
is suspected after deployment, the emitter edits are two small, independently revertible
hunks (`FieldSchema (Maybe a)`, `enumSchema`). M3 degrades gracefully if landed partially:
with stamps but no router support the extra metadata is stripped-or-inert; with router
support but no stamps the swap never triggers; both halves default to today's behavior.
The optional live smoke test (`SHIKUMI_LIVE=1 OPENAI_API_KEY=… cabal test shikumi`) is a
useful post-merge check that strict mode now accepts the schemas.


## Interfaces and Dependencies

End state of the touched surfaces (full module paths):

- `Shikumi.Program.parseResponse` — same name and module (EP-34 will export it; do not
  rename), same type:
  `(FromModel o, ToSchema o, Validatable o, ToPrompt i, ToPrompt o) => Signature i o ->
  Response -> Either ShikumiError o`; new JSON-detection behavior.
- `Shikumi.Adapter` — newly exported:
  `assistantJSON :: Response -> Either ShikumiError Value`;
  `metaNativePromptKey :: Text`; `metaNativeDemosKey :: Text`;
  `attachNativeRender :: Text -> [Text] -> Options -> Options`;
  `nativeRenderPieces :: (ToSchema o, ToPrompt i, ToPrompt o) => Signature i o -> (Text, [Text])`.
  `nativeAdapter` renders demos natively; `fallbackAdapter`/`xmlAdapter` unchanged.
- `Shikumi.Schema` / `Shikumi.Schema.Types` — `FieldSchema (Maybe a)` required flag `True`;
  `enumSchema` emits `"type": "string"`. No exported-name changes.
- `Shikumi.Routing.translateForWire` — widened to
  `Model -> Context -> Options -> (Context, Options)`; `routeLLM`'s `Complete` case uses
  it. EP-34 adds a `Stream` case that must call this same function (master plan integration
  point 3) — do not fork a second translation path.

Dependencies: only existing ones. `aeson` for encoding; `lens` + `generic-lens` labels for
`Context`/`Options` edits (`Context` carries `systemPrompt :: Maybe Text` and
`messages :: Vector Message`, edited via `#systemPrompt`/`#messages` exactly as
`buildContext` in Adapter.hs:281-283 does); `baikai`'s `assistant`/`user` message
constructors. Soft coordination with EP-32 (constraint rows on `runPredict`/
`parseResponse`) and EP-34 (consumes `translateForWire` and `parseResponse`) per the master
plan's integration points 1, 3, and 4.
