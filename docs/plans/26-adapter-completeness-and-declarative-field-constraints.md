---
id: 26
slug: adapter-completeness-and-declarative-field-constraints
title: "Adapter completeness and declarative field constraints"
kind: exec-plan
created_at: 2026-06-09T22:35:42Z
intention: "intention_01ktq812wfebgvf1dtbvg3v826"
master_plan: "docs/masterplans/4-shikumi-richer-io-and-multimodal.md"
---

# Adapter completeness and declarative field constraints

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Shikumi is a Haskell framework for writing programs whose steps are calls to a
large language model (an "LM" — a text-in, text-out model such as GPT or Claude).
A *signature* is a typed description of one such step: an input record type `i`,
an output record type `o`, and a natural-language instruction. An *adapter* is the
piece that turns a signature plus an input value into the exact bytes sent to the
model, and turns the model's reply back into a typed `o`. Today Shikumi ships two
adapters: a *native* one that asks the model to reply with a JSON object, and a
*fallback* one that asks the model to reply in labeled `[[ ## field ## ]]`
sections (a convention borrowed from the Python framework DSPy) for models that
are bad at producing clean JSON.

After this change a Shikumi user can do two new things.

First, they can choose two additional adapters. **`xmlAdapter`** asks the model to
wrap each output field in XML tags — `<headline>…</headline>` — and parses those
tags back into the typed output. Some models follow an XML shape more reliably
than JSON or the `[[ ## … ## ]]` markers, so this is a third wire format on the
same typed seam. **`twoStepAdapter`** is for models that are strong reasoners but
weak at producing structured output (a common trait of "reasoning" models): it
makes **two** model calls. The first call asks the question in plain prose and
lets the model answer in free-form text. The second call hands that free-form text
to a (possibly smaller, cheaper) *extraction* model and asks it to pull the
structured fields out. The caller gets a normal typed `o`; the two-call dance is
hidden inside.

Second, they can attach **declarative field constraints** to a signature field —
for example "this string must be at least 10 characters", "this number must be
between 0 and 100", or "this field must be one of these enum values" — and have
those constraints do two things automatically: (a) appear as the right keywords in
the JSON Schema we generate (`minLength`, `maximum`, `minimum`, `enum`), so a
provider that enforces schemas on its side will reject a violating answer; and
(b) be enforced again locally after we parse the reply, so a violating value
becomes a typed `ValidationFailure` error instead of slipping through. Today a
field can already carry a *description* (via the `Field "desc" a` wrapper) but it
cannot carry a *constraint*; this plan adds that.

You can see all of this working without a network. For the adapters, a test
renders a signature through `xmlAdapter` and feeds a hand-written XML reply back
through `parse`, asserting it decodes to the expected typed value; and a test
drives `twoStepAdapter` against a *stub* LM (a fake in-process model) scripted to
return free-form prose on the first call and structured output on the second,
asserting the final typed value is correct. For constraints, a test asserts that a
constrained field's generated schema `Value` contains the expected keyword
(e.g. `"minLength": 10`) and that decoding a violating reply fails with a
`ValidationFailure` while a conforming reply succeeds — the same decode failing
before the constraint is added and passing after.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be
documented here, even if it requires splitting a partially completed task into two
("done" vs. "remaining"). This section must always reflect the actual current
state of the work.

- [x] M0: Read the four ground-truth files named in *Context and Orientation*;
      confirm the signatures in this plan still match the source (the plan quotes
      them verbatim, but the source is the authority).
- [x] M1: `xmlAdapter` exists in `Shikumi.Adapter`, exported, selectable; its
      `render` wraps demo outputs and asks for XML-tagged output, its `parse`
      reads `<field>…</field>` tags and decodes to the typed `o`. New
      `XmlAdapterSpec` proves a render→parse round-trip and a missing-tag error.
- [ ] M2: Declarative field constraints exist. A `Constrained cs a` field wrapper
      (or equivalently-named mechanism chosen below) carries type-level constraint
      descriptors; `ToSchema` emits the matching JSON-Schema keywords; a derived
      check enforces them after decode. New `ConstraintSpec` proves the schema
      `Value` carries the keyword AND that an out-of-bounds decode fails while an
      in-bounds decode passes.
- [ ] M3: `twoStepAdapter` exists as a small program combinator (`twoStep`) that
      issues a free-form call then an extraction call. New `TwoStepSpec` drives it
      against a two-call stub LM and asserts the final typed `o`.
- [ ] M4: `AdapterSpec`, `SchemaSpec`, `EndToEndSpec` still pass unchanged (the
      existing text-field path is untouched); the new specs are wired into
      `shikumi/test/Main.hs`; `cabal test shikumi` is green.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **M0: the plan's `defaultModel` reference is stale; the real placeholder is
  private.** `Shikumi.Program` does *not* export `defaultModel`; the inert
  placeholder model is `placeholderModel = _Model` (private). For `twoStep` (M3)
  the two `complete` calls therefore pass `_Model` (imported from `Baikai`)
  directly — `adapterFor _Model` resolves to the fallback adapter exactly as the
  plan intends. No behavior change; only the name differs.
- **M0: post-EP-24 the adapters render the live input via `userTurn i`, not
  `user (toPrompt i)`.** `xmlAdapter` follows suit (`xmlDemoMessages sig ++
  [userTurn i]`), so an image-bearing input would lower through XML's render too;
  the all-text path is byte-identical to the marker fallback. Demo turns stay text
  (`user (toPrompt i)`), matching `demoMessages`.


## Decision Log

Record every decision made while working on the plan.

- Decision: Express `twoStepAdapter` as a small **program combinator** named
  `twoStep` (built at the module layer, returning a `Program i o`), not as a
  single `Adapter i o` value.
  Rationale: the `Adapter` record is `render :: Signature i o -> i -> (Context,
  Options)` and `parse :: Signature i o -> Response -> Either ShikumiError o` (see
  *Context and Orientation*). A two-step flow needs to issue a *second* model call
  from inside `parse`, but `parse` is a pure `Response -> Either ShikumiError o`
  with no access to the `LLM` effect. Forcing two calls into one `Adapter` would
  require smuggling an effectful action through a pure field, which the type does
  not allow. The DSPy `TwoStepAdapter` gets away with this because its `parse`
  closes over a live `BaseLM` handle and calls it synchronously; Haskell's effect
  discipline makes that dishonest. The clean expression is an `Embed` program node
  (the same escape hatch `react` uses, per the dossier §H.4) that runs a free-form
  predict, then an extraction predict. The XML adapter, by contrast, *is* a pure
  render/parse and so stays a plain `Adapter i o` value.
  Date: 2026-06-09.
- Decision: Carry constraints with a new wrapper `Constrained (cs :: [Constraint])
  a` parallel to the existing `Field (desc :: Symbol) a`, where `Constraint` is a
  small closed type-level vocabulary (`MinLen`, `MaxLen`, `Min`, `Max`,
  `EnumOneOf`), rather than reusing `Field`'s `Symbol` for both description and
  constraints.
  Rationale: keeping `Field` exactly as-is means the existing text-field path and
  EP-24's media-field path (which both pattern-match `Field d a`) keep compiling
  unchanged (integration point #1). A description and a constraint are different
  axes; combining them into one wrapper would force every existing `Field "desc"
  a` to also name an (empty) constraint list, a breaking change. A separate
  wrapper is additive. The two wrappers compose: `Field "desc" (Constrained
  '[MinLen 10] Text)` carries both.
  Date: 2026-06-09.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at
completion. Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This section assumes you know nothing about the repository. Read it fully before
touching code.

**Where things live.** The project root is
`/Users/shinzui/Keikaku/bokuno/shikumi`. The library package is the `shikumi/`
subdirectory. The four files this plan edits or extends are:

- `shikumi/src/Shikumi/Adapter.hs` — the adapter seam (`Adapter`, `ToPrompt`,
  `nativeAdapter`, `fallbackAdapter`, `adapterFor`, `capabilityFor`).
- `shikumi/src/Shikumi/Schema.hs` — schema generation (`ToSchema`/`deriveSchema`),
  total decoding (`FromModel`/`fromModel`/`fromModelChecked`/`parseOutput`), and
  the `Validatable` hook.
- `shikumi/src/Shikumi/Schema/Types.hs` — the `Field` wrapper, `FieldMeta`, the
  JSON-Schema smart constructors (`objectSchema`, `stringSchema`, …,
  `withDescription`), and the `FieldPath` breadcrumb.
- `shikumi/src/Shikumi/Module.hs` — where the `twoStep` combinator goes
  (alongside `predict`, `chainOfThought`).

Tests live under `shikumi/test/`. The test entry point is
`shikumi/test/Main.hs`, a single `Test.Tasty.defaultMain` that lists each spec's
`tests :: TestTree`. Shared record fixtures (an `Article` input and a `Summary`
output) are in `shikumi/test/Fixtures.hs`.

**The adapter seam, verbatim from `Shikumi/Adapter.hs`.** This is the contract you
extend. Do not change these two type signatures.

```haskell
-- | A record of two functions: format a request, parse a response.
data Adapter i o = Adapter
  { render :: Signature i o -> i -> (Context, Options),
    parse :: Signature i o -> Response -> Either ShikumiError o
  }

class ToPrompt a where
  toPromptFields :: a -> [(Text, Text)]
  toPrompt :: a -> Text
```

`Context` and `Options` and `Response` are types from the transport library
*baikai* (re-exported through the `Baikai` module). A `Context` is a system prompt
plus a vector of `Message`s; you build one with `_Context & #systemPrompt .~ Just
sys & #messages .~ V.fromList msgs` (see `buildContext` in `Shikumi/Adapter.hs`).
A `Message` is built with `user :: Text -> Message` and `assistant :: Text ->
Message`. A `Response` carries assistant content blocks; `flattenAssistantBlocks ::
Response -> Vector AssistantContent` yields them, and the existing helper
`responseText :: Response -> Text` (in `Shikumi/Adapter.hs`) concatenates the text
blocks. Reuse `responseText`; do not re-derive it.

The two existing adapters are built like this (abbreviated, from the source):

```haskell
nativeAdapter =
  Adapter
    { render = \sig i ->
        let sys = systemHeader sig <> nativeOutputGuide sig
            ctx = buildContext sys (demoMessages sig ++ [user (toPrompt i)])
            opts = attachSchema (deriveSchema @o) _Options
         in (ctx, opts),
      parse = \_sig resp -> assistantJSON resp >>= fromModelChecked
    }

fallbackAdapter =
  Adapter
    { render = \sig i ->
        let sys = systemHeader sig <> fallbackOutputGuide sig
            ctx = buildContext sys (demoMessages sig ++ [user (toPrompt i)])
         in (ctx, _Options),
      parse = \_sig resp ->
        let sections = parseMarkers (responseText resp)
            obj = sectionsToObject (deriveSchema @o) sections
         in fromModelChecked obj
    }
```

Note the shape: `render` builds a system header from the instruction
(`systemHeader`), appends an output guide (`nativeOutputGuide` /
`fallbackOutputGuide`), renders demos as user/assistant message pairs
(`demoMessages`), and appends the live input as a `user` message. `parse` turns
the raw reply into a JSON `Value` and runs `fromModelChecked` (decode + validate).
Your `xmlAdapter` follows exactly this shape with an XML output guide and an
XML-tag parser.

**Adapter selection, verbatim.**

```haskell
data ModelCapability = NativeSchema | PromptFallback

capabilityFor :: Model -> ModelCapability
capabilityFor m = case (m ^. #provider, m ^. #api) of
  ("openai", OpenAIChatCompletions) -> NativeSchema
  ("anthropic", AnthropicMessages) -> NativeSchema
  _ -> PromptFallback

adapterFor ::
  forall i o.
  (ToSchema o, FromModel o, Validatable o, ToPrompt i, ToPrompt o) =>
  Model -> Adapter i o
adapterFor m = case capabilityFor m of
  NativeSchema -> nativeAdapter
  PromptFallback -> fallbackAdapter
```

`capabilityFor` is a two-way classifier today. `xmlAdapter` and `twoStepAdapter`
are *opt-in* — a caller picks them explicitly rather than the framework
auto-selecting them — so `adapterFor`'s body does **not** need to change. (We add
an explicit selector helper instead; see M1.) We do not widen `ModelCapability`,
because XML and two-step are not capabilities the framework can detect from a
`Model`; they are deliberate caller choices.

**The schema/decode/validate path, verbatim from `Shikumi/Schema.hs`.** A record's
schema comes from the generic `ToSchema` walk: each field becomes a property via
the `FieldSchema` class, and `Field d a` adds the description:

```haskell
class FieldSchema t where
  fieldSchema :: Proxy t -> (Value, Bool)   -- (schema, isRequired)

instance {-# OVERLAPPABLE #-} (ToSchema a) => FieldSchema a where
  fieldSchema _ = (toSchema (Proxy @a), True)

instance (ToSchema a) => FieldSchema (Maybe a) where
  fieldSchema _ = (nullableSchema (toSchema (Proxy @a)), False)

instance (KnownSymbol d, FieldSchema a) => FieldSchema (Field d a) where
  fieldSchema _ =
    let (s, req) = fieldSchema (Proxy @a)
     in (withDescription (T.pack (symbolVal (Proxy @d))) s, req)
```

Decoding mirrors it through `FromModel`/`FromField`, and `Field d a` decodes by
unwrapping (`Field <$> …`). Validation is a separate hook:

```haskell
class Validatable a where
  validate :: a -> Either Text a
  validate = Right

instance {-# OVERLAPPABLE #-} Validatable a

fromModelChecked :: (FromModel a, Validatable a) => Value -> Either ShikumiError a
fromModelChecked v = do
  a <- fromModel v
  first ValidationFailure (validate a)
```

Crucially `validate` is called **on the whole output record** (e.g. the `Summary`
in `Fixtures.hs` validates that `bullets` has 3–5 items). It is *not* called
per-field. This matters for the constraints design: a per-field constraint must be
surfaced to the record's `Validatable` instance. The plan threads it through a new
generic helper (`validateConstraints`, M2) that a record's `validate` can call, so
constraint checks compose with any hand-written record rule.

**The JSON-Schema smart constructors, verbatim from `Shikumi/Schema/Types.hs`.**
You will add constraint-aware variants beside these:

```haskell
objectSchema :: [(Text, Value)] -> [Text] -> Value
stringSchema, integerSchema, numberSchema, boolSchema :: Value
arraySchema :: Value -> Value
enumSchema :: [Text] -> Value
nullableSchema :: Value -> Value
withDescription :: Text -> Value -> Value   -- inserts "description" key; no-op on non-objects
```

`withDescription` is the model to follow: it inserts a key into a schema `Value`
that is a JSON object and is a no-op otherwise. Your new helpers
(`withMinLength`, `withMaxLength`, `withMinimum`, `withMaximum`, `withEnum`) do the
same — insert `"minLength"`, `"maxLength"`, `"minimum"`, `"maximum"`, `"enum"`.

**The stub LM, verbatim from `EndToEndSpec.hs`.** Tests interpret the `LLM` effect
in-process with no network:

```haskell
runFakeLLM :: Response -> Eff (LLM : es) a -> Eff es a
runFakeLLM canned = interpret $ \_ -> \case
  Complete _ _ _ -> pure canned
  Stream _ _ _ -> pure []
```

`runFakeLLM` returns the *same* canned response for every call. The two-step test
needs a stub that returns a **different** response on the first vs. second call;
M3 specifies a scripted variant `runScriptedLLM :: [Response] -> …` that pops the
next response from a list held in an `IORef`.

**Terms used in this plan.**

- *Adapter*: the `Adapter i o` record above — one render function, one parse
  function. A wire format.
- *Constraint*: a declarative rule on a field's value (minimum length, numeric
  bound, enum membership). Here it is a type-level descriptor that drives both
  schema emission and post-decode validation.
- *Stub LM* / *fake LM*: an in-process interpreter of the `LLM` effect that
  returns canned responses, used so tests run without a network.
- *Combinator*: a function returning a `Program i o`, composable with other
  programs. `twoStep` is one.
- *`Embed` node*: a `Program` constructor that wraps an arbitrary effectful
  function `forall es. (LLM :> es, Error ShikumiError :> es) => i -> Eff es o`.
  It is how `react` and `twoStep` run multi-call flows as ordinary programs (see
  the dossier §A.1 and §H.4).

**Build and test environment.** All builds and tests run inside the project's Nix
development shell, which pins GHC 9.12.4, cabal, and HLS. Enter it from the project
root with `nix develop .#ghc9124`. Inside that shell, build with `cabal build
shikumi` and test with `cabal test shikumi` (or `cabal test all` to run every
package's suite). The code style is enforced by *fourmolu* (config:
`fourmolu.yaml`, 2-space indentation, `indent-wheres: true`); run `fourmolu -i` on
any file you edit before committing.

**Sibling plan coordination (integration point #1).** This is EP-26. Its sibling
**EP-24** (`docs/plans/24-multimodal-field-types.md`) also edits
`Shikumi.Schema`/`Shikumi.Adapter` to add *media* field types (an image field that
lowers to baikai's `UserImage` content). As of this writing EP-24 is *Not Started*
(its plan file is still a skeleton), so this plan does not depend on any code it
will add; the soft dependency in the master plan
(`docs/masterplans/4-shikumi-richer-io-and-multimodal.md`, integration point #1) is
a *sequencing preference*, not a compile requirement. The two plans coexist by
construction:

- EP-24 owns the *media-field* mechanism (a new field wrapper / `FieldSchema`
  instance that lowers to image content). EP-26 owns the *constraint* mechanism (a
  new `Constrained` wrapper). They are distinct wrappers and distinct
  `FieldSchema`/`FromField`/`FieldDoc` instances; neither pattern-matches the
  other's wrapper, so adding one cannot break the other.
- Both must leave the existing plain `Field d a` path and the bare-`Text`-field
  path **unchanged** (master-plan integration point #1; V1 integration point #3).
  This plan does so: it adds instances, never alters or removes the `Field`
  instances quoted above.
- If EP-24 lands first, the only shared surface is the `FieldSchema`/`FromField`/
  `FieldDoc` *classes* (open classes; both add instances). If EP-26 lands first,
  the same holds in reverse. The merge is additive either way. If a true conflict
  arises (e.g. both want to change `gRecordFields`), that is a signal the two
  mechanisms should share a helper; coordinate via the master plan's integration
  point #1 and record the resolution in this plan's Decision Log.

The XML and two-step adapters are entirely new values/functions and touch no
EP-24 surface, so they never conflict.


## Plan of Work

The work is three milestones plus a final integration check. M1 (XML adapter) and
M3 (two-step combinator) are independent of M2 (constraints) and of each other;
M2 is independent of both. They are ordered M1 → M2 → M3 because M1 is the
simplest (pure render/parse, mirrors the existing adapters), M2 is the deepest
(type-level machinery), and M3 reuses the stub-LM scaffolding most directly. Do
them in order, committing after each, but any order is valid.

### Milestone M1 — `xmlAdapter`

**Scope.** Add a third `Adapter i o` value, `xmlAdapter`, to `Shikumi/Adapter.hs`,
mirroring `fallbackAdapter` but with an XML wire format. At the end of M1,
`xmlAdapter` is exported, a caller can pick it explicitly, a signature renders to a
system prompt that asks for `<field>…</field>` output, and a hand-written XML reply
parses back into the typed `o`.

**What to add.** In `Shikumi/Adapter.hs`:

1. Export `xmlAdapter` from the module's export list (add it next to
   `fallbackAdapter`).

2. An XML output guide, mirroring `fallbackOutputGuide`:

   ```haskell
   -- | An XML-output guide: ask for one <field>…</field> element per output field.
   xmlOutputGuide :: Signature i o -> Text
   xmlOutputGuide sig =
     "Reply with each output field wrapped in an XML tag, on its own lines:\n"
       <> T.unlines [openTag (fieldName f) <> "…" <> closeTag (fieldName f) <> describeSuffix f | f <- outputFields sig]
   ```

   with tiny helpers `openTag name = "<" <> name <> ">"` and `closeTag name = "</"
   <> name <> ">"`. Reuse the existing `describeSuffix` and `fieldName`.

3. A demo renderer in XML form, mirroring `renderOutputSections` (which uses
   `[[ ## … ## ]]`):

   ```haskell
   renderOutputXml :: (ToPrompt o) => o -> Text
   renderOutputXml o =
     T.unlines [openTag k <> "\n" <> v <> "\n" <> closeTag k | (k, v) <- toPromptFields o]
   ```

   and a demo-message builder `xmlDemoMessages` that pairs `user (toPrompt i)` with
   `assistant (renderOutputXml o)` (mirror `demoMessages`, which currently always
   uses the marker form). Keep `demoMessages` as-is for the other adapters; add a
   parallel `xmlDemoMessages` so the XML adapter's demos are XML-shaped. (Demo
   shape should match the adapter's wire format so the model sees a consistent
   example.)

4. An XML parser. DSPy's `XMLAdapter` uses the regex
   `<(?P<name>\w+)>(?P<content>.*?)</\1>` with DOTALL and keeps the first match per
   output-field name. Mirror that in Haskell without a regex dependency by a small
   line/segment scanner, or with `Text` splitting on `<name>`/`</name>`. The
   cleanest approach reusing existing helpers: build a `Map Text Text` of
   tag-name → inner-text, then feed it through the **existing**
   `sectionsToObject :: Value -> Map Text Text -> Value` and `fromModelChecked`,
   exactly as `fallbackAdapter` does with `parseMarkers`. So implement:

   ```haskell
   -- | Extract <name>…</name> sections into a name->text map, first match wins,
   -- only names that appear as output fields are kept (DSPy parity).
   parseXmlTags :: [Text] -> Text -> Map Text Text
   ```

   taking the output-field names (`map fieldName (outputFields sig)`) so unknown
   tags are ignored and nesting is handled by taking the content between the first
   `<name>` and its matching `</name>`. Then:

   ```haskell
   xmlAdapter =
     Adapter
       { render = \sig i ->
           let sys = systemHeader sig <> xmlOutputGuide sig
               ctx = buildContext sys (xmlDemoMessages sig ++ [user (toPrompt i)])
            in (ctx, _Options),
         parse = \sig resp ->
           let names = map fieldName (outputFields sig)
               sections = parseXmlTags names (responseText resp)
               obj = sectionsToObject (deriveSchema @o) sections
            in fromModelChecked obj
       }
   ```

   Note `parse` now uses its `sig` argument (the marker adapters ignore it with
   `_sig`) because the XML parser needs the output-field names to know which tags
   to keep. `sectionsToObject` already coerces each section's text to its
   schema-typed `Value` (strings stay strings, JSON-looking values are parsed), so
   nested records and lists in tags work the same way the marker adapter handles
   them.

**Acceptance (observable).** A new spec `shikumi/test/XmlAdapterSpec.hs`:

- *Render carries the instruction and XML tags.* `render xmlAdapter sig
  sampleArticle` produces a system prompt containing `Summarize the article` and
  `<headline>`.
- *Round-trip.* Feeding a hand-written XML reply (a `Response` whose text wraps
  each `Summary` field in tags) through `parse xmlAdapter sig` yields `Right
  expectedSummary` — the same `expectedSummary` value used in `AdapterSpec`.
- *Missing tag → located error.* An XML reply missing the `<bullets>` tag yields
  `Left (MissingField "bullets")` (because `sectionsToObject` omits the absent
  field and the required-field decode reports it — identical to the fallback
  adapter's behavior, verifying the reuse).

Run: inside `nix develop .#ghc9124`, `cabal test shikumi`. The `XmlAdapterSpec`
group passes.

### Milestone M2 — declarative field constraints

**Scope.** Add a type-level constraint mechanism so a signature field can declare a
minimum/maximum string length, a numeric lower/upper bound, or an enum membership,
and have it (a) appear in the generated JSON Schema and (b) be enforced after
decode. At the end of M2 a constrained field's `deriveSchema` `Value` contains the
right keyword, and a decode of a violating value fails with `ValidationFailure`
while a conforming value passes.

**The mechanism.** Add to `Shikumi/Schema/Types.hs`:

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE KindSignatures #-}

-- | A type-level vocabulary of field constraints. Each constructor names one
-- JSON-Schema-expressible rule. 'Nat' bounds are non-negative; signed numeric
-- bounds use 'MinVal'/'MaxVal' carrying an integer literal as a Symbol so we can
-- represent negatives and decimals as text the schema and validator both parse.
data Constraint
  = MinLen Nat          -- ^ string minimum length  -> "minLength"
  | MaxLen Nat          -- ^ string maximum length  -> "maxLength"
  | MinVal Symbol       -- ^ numeric lower bound     -> "minimum"
  | MaxVal Symbol       -- ^ numeric upper bound     -> "maximum"
  | EnumOneOf [Symbol]  -- ^ allowed string values   -> "enum"

-- | A field value carrying a (compile-time) list of constraints. Parallel to
-- 'Field'; the two compose: @Field "desc" (Constrained '[MinLen 10] Text)@.
newtype Constrained (cs :: [Constraint]) a = Constrained {unConstrained :: a}
  deriving stock (Eq, Show)

constrained :: a -> Constrained cs a
constrained = Constrained
```

> Implementation note on numeric bounds: `Nat` only models non-negative integers,
> which is fine for `MinLen`/`MaxLen`. For `MinVal`/`MaxVal` we carry the bound as
> a `Symbol` (e.g. `MinVal "0"`, `MaxVal "100"`, `MinVal "-3.5"`) so negatives and
> decimals are expressible; both the schema emitter and the validator parse that
> `Symbol` to a `Scientific`. If the implementer prefers, an alternative is a
> dedicated `data Bound = …` promoted type; the `Symbol` form is chosen because it
> needs no extra promotion machinery and round-trips through `Data.Scientific`.

Add new schema-keyword helpers to `Shikumi/Schema/Types.hs`, each mirroring
`withDescription` (insert a key into an object schema, no-op otherwise), and export
them:

```haskell
withMinLength :: Int -> Value -> Value
withMaxLength :: Int -> Value -> Value
withMinimum   :: Scientific -> Value -> Value
withMaximum   :: Scientific -> Value -> Value
withEnum      :: [Text] -> Value -> Value   -- inserts "enum"
```

Add to `Shikumi/Schema.hs` a typeclass that reflects a constraint list to both a
schema transformer and a value checker:

```haskell
-- | Reflect a type-level constraint list to (a) a schema-decorating function and
-- (b) a runtime validator over the decoded leaf value.
class ReflectConstraints (cs :: [Constraint]) a where
  constraintSchema :: Proxy cs -> Value -> Value          -- compose all keyword inserts
  checkConstraints :: Proxy cs -> a -> Either Text a       -- left = which rule failed

instance ReflectConstraints '[] a where
  constraintSchema _ = id
  checkConstraints _ = Right
```

with per-constructor instances, e.g. for string length over `Text`:

```haskell
instance (KnownNat n, ReflectConstraints cs Text) => ReflectConstraints ('MinLen n ': cs) Text where
  constraintSchema _ = constraintSchema (Proxy @cs) . withMinLength (fromIntegral (natVal (Proxy @n)))
  checkConstraints _ t
    | T.length t < fromIntegral (natVal (Proxy @n)) = Left ("minLength " <> tshow (natVal (Proxy @n)) <> " violated")
    | otherwise = checkConstraints (Proxy @cs) t
```

and analogous instances for `MaxLen` over `Text`, `MinVal`/`MaxVal` over a numeric
`a` (parse the `Symbol` to `Scientific`, compare; require the leaf to be
`Real`/`Ord` and comparable — implement for `Int`, `Integer`, `Double` via a small
`Num`/`Ord`+`Real` constraint or a `ToScientificLeaf a` helper), and `EnumOneOf`
over `Text` (membership; also emits `withEnum`). Keep the instance set small and
concrete (the five constraint constructors over `Text` and the numeric leaves);
this is a closed, finite vocabulary, not an open extension point.

Wire `Constrained` into the three generic walks, mirroring how `Field` is wired:

- **`FieldSchema` (in `Shikumi/Schema.hs`)** — emit keywords on the inner schema:

  ```haskell
  instance (ReflectConstraints cs a, FieldSchema a) => FieldSchema (Constrained cs a) where
    fieldSchema _ =
      let (s, req) = fieldSchema (Proxy @a)
       in (constraintSchema (Proxy @cs) s, req)
  ```

- **`FromModel`/`FromField`** — decode by unwrapping then checking the constraints,
  turning a violation into a `ValidationFailure` located at the field:

  ```haskell
  instance (FromModel a, ReflectConstraints cs a) => FromModel (Constrained cs a) where
    fromModelP path v = do
      a <- fromModelP path v
      case checkConstraints (Proxy @cs) a of
        Right ok -> Right (Constrained ok)
        Left msg -> Left (ValidationFailure (renderPath path <> ": " <> msg))
  ```

  and a matching `FromField (Constrained cs a)` instance that delegates through
  `fromField` then checks (mirror the existing `FromField (Field d a)` instance).
  This makes constraints enforced *during decode*, so they compose with the
  record-level `Validatable` rule automatically — no change to `fromModelChecked`
  is needed, and a record with no custom `Validatable` instance still gets
  constraint enforcement for free.

- **`FieldDoc`/`GFieldMetas`** — a `Constrained cs a` field has no description by
  itself (description still comes from a surrounding `Field`), so add the
  overlappable-style instance `instance FieldDoc (Constrained cs a) where fieldDoc
  _ = Nothing` only if the compiler needs it to resolve; the existing
  `{-# OVERLAPPABLE #-} FieldDoc a` already covers it, so likely no new instance is
  required. Verify by building.

- **`ToPrompt`'s `PromptValue` (in `Shikumi/Adapter.hs`)** — add `instance
  (PromptValue a) => PromptValue (Constrained cs a) where promptValue =
  promptValue . unConstrained`, mirroring how `Field` unwraps (there is already a
  `PromptValue (Field d a)`-style path; if not, the overlappable `Show` instance
  would misbehave, so add the explicit unwrap).

Re-export `Constraint(..)`, `Constrained(..)`, `constrained`, and the new
`with*` helpers from `Shikumi.Schema.Types`, and (since `Shikumi.Schema`
re-exports `module Shikumi.Schema.Types`) they flow out of `Shikumi.Schema` too.

**Acceptance (observable).** A new spec `shikumi/test/ConstraintSpec.hs` defines a
small constrained record, e.g.:

```haskell
data Bio = Bio
  { tagline :: Constrained '[MinLen 10] Text,
    score   :: Constrained '[MinVal "0", MaxVal "100"] Int
  }
  deriving stock (Generic, Show, Eq)
instance ToSchema Bio
instance FromModel Bio
instance Validatable Bio
```

and asserts:

- *Schema carries the keywords.* `deriveSchema @Bio` is a JSON object whose
  `properties.tagline` contains `"minLength": 10` and whose `properties.score`
  contains `"minimum": 0` and `"maximum": 100`. (Drill into the `Value` with
  aeson lenses or `KM.lookup`; assert the exact sub-values.)
- *Violating decode fails (fails before, passes after).* Decoding the JSON
  `{"tagline":"short","score":50}` via `fromModel @Bio` yields `Left
  (ValidationFailure "tagline: minLength 10 violated")` (the `tagline` is 5 chars).
  Decoding `{"tagline":"long enough tagline","score":50}` yields `Right …`. To make
  "fails before, passes after" concrete and self-contained, the spec also includes
  the *same record without the constraint* (`tagline :: Text`) and shows that
  record decodes `"short"` happily — demonstrating that the constraint is what
  rejects it.
- *Out-of-range number fails.* `{"tagline":"long enough tagline","score":150}`
  yields `Left (ValidationFailure "score: maximum 100 violated")`.

Run: `cabal test shikumi`; the `ConstraintSpec` group passes.

### Milestone M3 — `twoStepAdapter` as the `twoStep` combinator

**Scope.** Add a `twoStep` combinator that issues two model calls — a free-form
answer, then a structured extraction — and returns a typed `o`. At the end of M3,
`twoStep` is callable, and a test drives it against a stub LM scripted to return
prose then structured output, asserting the final typed value.

**Why a combinator, not an `Adapter` (recap of the Decision Log).** The `Adapter`
record's `parse` is pure (`Response -> Either ShikumiError o`) and cannot issue a
second model call. A two-step flow needs an effectful second call, so it is built
as a `Program i o` via the `Embed` constructor (the same node `react` uses). This
is the honest expression in Shikumi's effect-typed world.

**What to add.** In `Shikumi/Module.hs`, beside `predict`/`chainOfThought`:

```haskell
-- | A two-call adapter: ask the main model for a free-form answer, then ask an
-- extraction model to coerce that prose into the typed output @o@. Useful for
-- strong reasoners that are weak at structured output.
twoStep ::
  (FromModel i, FromModel o, ToSchema o, Validatable o, ToPrompt i, ToPrompt o) =>
  Signature i o ->
  Program i o
```

Implement it as an `Embed` node whose body, given the input `i`:

1. **Free-form call.** Build a "plain prose" context from the signature: a system
   prompt that states the instruction and lists the input/output fields in words
   (mirroring DSPy `TwoStepAdapter.format_task_description`: "You are a helpful
   assistant… As input you will be provided with: <input field descriptions>. Your
   outputs must contain: <output field descriptions>. Lay out your outputs in
   detail."), plus the input rendered with `toPrompt i`. Do **not** ask for JSON or
   tags. Call `complete defaultModel ctx _Options` (using the existing
   `Shikumi.LLM.complete` and `Shikumi.Program.defaultModel`), and take the reply
   text with `responseText`.

2. **Extraction call.** Construct an *extraction signature* `text -> o`: an input
   record carrying a single `text :: Text` field holding the free-form answer, and
   the original output type `o`. Render it with the existing `fallbackAdapter`
   (the marker format is a robust extraction target and already round-trips), whose
   instruction is "The text below contains the answer. Extract these fields
   verbatim." Call the model again, and `parse` the structured reply with
   `fallbackAdapter` into `o`. Return that `o` (a decode/validation failure
   propagates as the `Embed` body's `ShikumiError`).

   The extraction input type is a tiny internal record:

   ```haskell
   newtype ExtractIn = ExtractIn { text :: Text }
     deriving stock (Generic, Show)
   instance ToPrompt ExtractIn
   instance FromModel ExtractIn
   ```

   Reuse `adapterFor defaultModel` or `fallbackAdapter` directly for the
   extraction step; `fallbackAdapter` is the safe default because the stub LM in
   the test does not implement native structured output. (DSPy uses `ChatAdapter`,
   the marker-style adapter, for the same reason — see the source comment "uses a
   smaller LM with chat adapter to extract structured data".)

   Both calls use the same `LLM` effect, so under `runProgram` they go to the same
   ambient model; a caller wanting a *separate, smaller* extraction model can run
   the extraction sub-program under a different interpreter, but that wiring is out
   of scope here (note it in the Decision Log as a known limitation, matching
   DSPy's own "the extraction model is fixed at construction" note). The headline
   capability — two calls, free-form then structured — is delivered.

Because `twoStep` returns an `Embed`-based `Program i o`, it automatically honors
the `Program` invariants from the dossier (§A.5/§A.6): `Embed` carries no `Params`,
so the parameter-count invariant (count == number of `Predict` nodes) holds and the
serializers/compilers pass it through unchanged. No `Program` GADT change is
needed.

**The scripted stub LM (test infrastructure).** Add to the new spec a two-call
interpreter:

```haskell
-- | Interpret 'LLM' by returning the next scripted response per call, in order.
runScriptedLLM :: IORef [Response] -> Eff (LLM : es) a -> Eff es a
runScriptedLLM ref = interpret $ \_ -> \case
  Complete _ _ _ -> do
    rs <- liftIO (readIORef ref)
    case rs of
      (r : rest) -> liftIO (writeIORef ref rest) >> pure r
      []         -> pure (mkResponse "")   -- exhausted: empty
  Stream _ _ _ -> pure []
```

seeded with `[freeFormResponse, structuredResponse]`. (This needs `IOE :> es` /
`liftIO`; the test runs under `runEff`, which provides `IOE`. Mirror the import
style of `EndToEndSpec`.)

**Acceptance (observable).** A new spec `shikumi/test/TwoStepSpec.hs`:

- Build `prog = twoStep sig` for the `Summary` signature from `Fixtures`.
- Script the stub LM with two responses: first a *free-form prose* answer
  (e.g. `"The headline is 'Shikumi types LM programs'. Three points: records in,
  records out, errors are typed. Author Ada. Sentiment positive."`), then a
  *structured marker* reply identical to `goodResponse` in `EndToEndSpec`.
- Run `runEff . runScriptedLLM ref $ runProgram prog sampleArticle` and assert the
  result is `Right expectedSummary` (the same `expectedSummary` fixture).
- Assert the script was fully consumed (the `IORef` is empty afterward), proving
  *two* calls happened — this is the observable that distinguishes `twoStep` from a
  single-call adapter.

Run: `cabal test shikumi`; the `TwoStepSpec` group passes.

### Milestone M4 — integration and regression check

Wire the three new specs into `shikumi/test/Main.hs` (add `XmlAdapterSpec
qualified`, `ConstraintSpec qualified`, `TwoStepSpec qualified` imports and their
`.tests` to the `testGroup "shikumi"` list), and add the three modules to the
`other-modules` of the `shikumi-test` test-suite in the package's `.cabal` file
(the suite is named `shikumi-test`; its `other-modules` currently lists
`AdapterSpec`, `SchemaSpec`, etc.). Run the full suite and confirm the pre-existing
specs — especially `AdapterSpec`, `SchemaSpec`, `EndToEndSpec` — still pass
unchanged, proving the existing text-field and marker/JSON paths are untouched
(integration point #1).


## Concrete Steps

Run everything from the project root `/Users/shinzui/Keikaku/bokuno/shikumi`,
inside the dev shell.

```bash
cd /Users/shinzui/Keikaku/bokuno/shikumi
nix develop .#ghc9124
```

Then, per milestone:

```bash
# After editing Shikumi/Adapter.hs (M1):
fourmolu -i shikumi/src/Shikumi/Adapter.hs shikumi/test/XmlAdapterSpec.hs
cabal build shikumi
cabal test shikumi --test-options='--pattern XmlAdapterSpec'

# After editing Schema.hs / Schema/Types.hs (M2):
fourmolu -i shikumi/src/Shikumi/Schema.hs shikumi/src/Shikumi/Schema/Types.hs shikumi/test/ConstraintSpec.hs
cabal build shikumi
cabal test shikumi --test-options='--pattern ConstraintSpec'

# After editing Module.hs (M3):
fourmolu -i shikumi/src/Shikumi/Module.hs shikumi/test/TwoStepSpec.hs
cabal build shikumi
cabal test shikumi --test-options='--pattern TwoStepSpec'

# M4 — full suite:
cabal test shikumi
cabal test all
```

Expected final transcript (abridged) for `cabal test shikumi`:

```text
shikumi
  ...
  XmlAdapterSpec
    xml render: system prompt has the instruction and a tag:      OK
    xml parse: tagged body decodes to the expected Summary:        OK
    xml parse: a missing tag -> MissingField (located):            OK
  ConstraintSpec
    schema: tagline carries minLength 10:                          OK
    schema: score carries minimum 0 and maximum 100:               OK
    decode: short tagline -> ValidationFailure:                    OK
    decode: conforming value -> Right:                             OK
    decode: out-of-range score -> ValidationFailure:               OK
  TwoStepSpec
    twoStep: free-form then extract yields expected Summary:        OK
    twoStep: both scripted calls consumed:                          OK

All N tests passed
```

Commit after each milestone. Commit messages follow Conventional Commits and carry
the trailers used across this repo:

```text
feat(shikumi): add xmlAdapter (XML-tagged I/O) on the adapter seam (M1)

MasterPlan: docs/masterplans/4-shikumi-richer-io-and-multimodal.md
ExecPlan: docs/plans/26-adapter-completeness-and-declarative-field-constraints.md
Intention: intention_01ktq812wfebgvf1dtbvg3v826
```


## Validation and Acceptance

The change is proven by behavior, not compilation:

- **XML adapter (M1).** Render a real signature and observe the system prompt asks
  for `<field>` tags; parse a concrete XML reply and observe it becomes the exact
  `expectedSummary` record; parse a reply with a tag removed and observe the
  precise `MissingField "bullets"` error. This shows the new wire format
  round-trips through the existing typed decode.
- **Constraints (M2).** Inspect the generated schema `Value` and observe the
  literal keywords (`"minLength": 10`, `"minimum": 0`, `"maximum": 100`); decode a
  violating reply and observe a `ValidationFailure` naming the field and rule;
  decode a conforming reply and observe success; and observe that the *same record
  without the constraint* accepts the violating value — the contrast proves the
  constraint is doing the work. Both schema and validation are driven from the one
  declaration, satisfying the master-plan goal "flow into both the JSON schema and
  the `Validatable` check."
- **Two-step (M3).** Drive `twoStep` against a stub LM scripted with prose then
  structure; observe the final typed `Summary`; observe the script is fully
  consumed (two calls). This shows the free-form-then-extract behavior end to end
  without a network.
- **No regression (M4).** `AdapterSpec`, `SchemaSpec`, `EndToEndSpec` pass with no
  edits to their assertions, showing the existing text-field path is intact.

Acceptance for the whole plan: `cabal test shikumi` is green with the three new
spec groups present and all pre-existing groups still passing.


## Idempotence and Recovery

All steps are additive and re-runnable. The plan adds new exported names
(`xmlAdapter`, `Constrained`, `Constraint`, `constrained`, the `with*` helpers,
`twoStep`) and new instances; it does not delete or rename existing ones, so
re-running edits is safe and partial progress never corrupts a working tree. If a
milestone's build fails, the other milestones' files are independent (M1 touches
only `Adapter.hs` + its spec; M2 touches `Schema*.hs` + its spec; M3 touches
`Module.hs` + its spec), so you can revert one file with `git checkout --
<file>` and retry that milestone alone. `fourmolu -i` is idempotent. Running
`cabal test` repeatedly has no side effects (the stub LMs are in-process; no
network, no files written).

The riskiest single edit is wiring `Constrained` into the generic `FieldSchema`/
`FromModel` walks (M2), because a too-broad instance could overlap the existing
`Field`/`Maybe` instances. Mitigation: the `Constrained` instances match only the
`Constrained cs a` head, which is disjoint from `Field d a`, `Maybe a`, and the
overlappable base case, so no `OVERLAPPING`/`OVERLAPPABLE` pragma juggling beyond
what already exists should be needed. If GHC reports an overlap, prefer adding
`{-# OVERLAPPING #-}` to the `Constrained` instance over weakening the existing
ones, and record the resolution in Surprises & Discoveries.


## Interfaces and Dependencies

No new external libraries. The plan uses what is already in scope: `Data.Aeson`
(`Value`, object construction), `Data.Aeson.KeyMap`, `Data.Scientific`
(`Scientific`, parsing numeric bound `Symbol`s), `Data.Text`, `GHC.Generics`,
`GHC.TypeLits` (`KnownSymbol`/`symbolVal`, `KnownNat`/`natVal`), `Data.Proxy`, the
`effectful` machinery (`interpret`, `Eff`, `runEff`, `liftIO`, `IORef`), and the
baikai re-exports (`Context`, `Options`, `Response`, `user`, `assistant`,
`flattenAssistantBlocks`, `_Options`, `_Context`).

Types and functions that must exist at the end of each milestone:

- **M1.** `xmlAdapter :: (ToSchema o, FromModel o, Validatable o, ToPrompt i,
  ToPrompt o) => Adapter i o`, exported from `Shikumi.Adapter`. Internal helpers
  `xmlOutputGuide`, `renderOutputXml`, `xmlDemoMessages`, `parseXmlTags`. The
  `Adapter`/`ToPrompt`/`Signature`/`Response` types are unchanged.

- **M2.** In `Shikumi.Schema.Types`: `data Constraint = MinLen Nat | MaxLen Nat |
  MinVal Symbol | MaxVal Symbol | EnumOneOf [Symbol]` (a kind, used promoted);
  `newtype Constrained (cs :: [Constraint]) a = Constrained { unConstrained :: a }`;
  `constrained :: a -> Constrained cs a`; and `withMinLength`, `withMaxLength`,
  `withMinimum`, `withMaximum`, `withEnum`, all exported. In `Shikumi.Schema`:
  `class ReflectConstraints (cs :: [Constraint]) a` with `constraintSchema` and
  `checkConstraints`, instances for the empty list and each constructor over the
  supported leaves, plus `FieldSchema`, `FromModel`, `FromField` instances for
  `Constrained cs a`. `Validatable`, `fromModelChecked`, `parseOutput` keep their
  current signatures; constraints enforce *inside* the existing decode path.

- **M3.** In `Shikumi.Module`: `twoStep :: (FromModel i, FromModel o, ToSchema o,
  Validatable o, ToPrompt i, ToPrompt o) => Signature i o -> Program i o`,
  exported. It builds an `Embed` node calling `Shikumi.LLM.complete` twice and the
  existing `fallbackAdapter` for extraction. The internal `ExtractIn` record is not
  exported. The `Program` GADT, `runProgram`, and the serializers are unchanged.

The reader needs no prior plan to proceed: every signature this plan builds on is
quoted in *Context and Orientation* above, and the authority is the four source
files named there.


---

Revision note (2026-06-09): Initial authored version of EP-26. Fleshed the
skeleton into a full ExecPlan: three milestones (XML adapter, declarative field
constraints, two-step combinator) plus an integration/regression milestone. Key
design decisions recorded in the Decision Log: `twoStepAdapter` is expressed as the
`twoStep` *program combinator* (an `Embed` node) rather than a single `Adapter`
value, because the `Adapter` record's `parse` is pure and cannot issue the second
model call; and constraints are carried by a new `Constrained` wrapper parallel to
the existing `Field` wrapper so the existing text-field path and EP-24's media-field
path keep compiling unchanged (integration point #1). All signatures were quoted
verbatim from `Shikumi/Adapter.hs`, `Shikumi/Schema.hs`, `Shikumi/Schema/Types.hs`,
and `Shikumi/Signature.hs` at repo HEAD, and the stub-LM and fixture patterns from
`shikumi/test/EndToEndSpec.hs` and `shikumi/test/Fixtures.hs`.
