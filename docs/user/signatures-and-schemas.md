# Signatures & schemas — under the covers

This guide opens the schema engine: **how a Haskell record becomes a JSON schema**, **how a
provider reply becomes a typed value (totally)**, and **the adapter seam** that bridges the
two depending on what the model supports. If you only ever derive the four classes and run
programs, you never need this — but when output decodes oddly, this is where the answer is.

The engine lives in `Shikumi.Schema`, `Shikumi.Schema.Types`, and `Shikumi.Adapter`. Both
directions are hand-rolled on `GHC.Generics`; the schema we emit is the small subset
OpenAI/Anthropic structured-output endpoints accept.

---

## Forward: record → JSON Schema (`ToSchema`)

```haskell
class ToSchema a where
  toSchema :: Proxy a -> Value          -- generic default for records

deriveSchema :: forall a. ToSchema a => Value
```

A single generic walk turns a type into a schema:

- **A record** (one constructor with named fields) becomes an `object` schema with
  `properties`, a `required` list, and `additionalProperties: false`.
- **A sum of nullary constructors** (an enum-like type) becomes a string `enum` of the
  constructor names.
- **Leaves** have explicit instances: `Text → string`, `Int`/`Integer → integer`,
  `Double → number`, `Bool → boolean`.
- **Containers**: `[a]` / `Vector a → array` of the element schema; `Maybe a` becomes a
  *nullable* schema using the portable `anyOf: [<a>, {type: null}]` form.

### Required vs. optional, and where descriptions attach

Per-field requiredness is decided field-by-field:

- The general case is **required**, no description.
- A `Maybe a` field is **optional / nullable** (it drops out of `required`).
- A `Field "desc" a` field attaches `desc` as the schema's `"description"` and preserves the
  inner field's requiredness. The description is attached at the *record-field* layer, not on
  the inner type, so a `Field` composes cleanly even when nested.

So this type:

```haskell
data Summary = Summary
  { headline  :: Field "A one-line summary" Text
  , bullets   :: Field "3–5 key points"     [Text]
  , sentiment :: Sentiment            -- data Sentiment = Positive | Neutral | Negative
  , note      :: Maybe Text
  }
```

derives (shape, abbreviated):

```json
{
  "type": "object",
  "properties": {
    "headline":  { "type": "string", "description": "A one-line summary" },
    "bullets":   { "type": "array", "items": {"type":"string"}, "description": "3–5 key points" },
    "sentiment": { "enum": ["Positive", "Neutral", "Negative"] },
    "note":      { "anyOf": [ {"type":"string"}, {"type":"null"} ] }
  },
  "required": ["headline", "bullets", "sentiment"],
  "additionalProperties": false
}
```

`note` is absent from `required` because it is a `Maybe`. The smart constructors that build
these fragments (`objectSchema`, `stringSchema`, `arraySchema`, `enumSchema`,
`nullableSchema`, `withDescription`, …) are exported from `Shikumi.Schema.Types` if you ever
hand-roll a schema instance (as `WithReasoning` does — see
[chainOfThought](./programs-and-combinators.md#chain-of-thought)).

---

## Inverse: JSON → record, totally (`FromModel`)

```haskell
class FromModel a where
  fromModelP :: FieldPath -> Value -> Either ShikumiError a   -- path-carrying

fromModel        :: FromModel a => Value -> Either ShikumiError a
fromModelChecked :: (FromModel a, Validatable a) => Value -> Either ShikumiError a
parseOutput      :: (FromModel a, Validatable a) => Text  -> Either ShikumiError a
```

Decoding is **total**: it never throws, it returns `Either ShikumiError a`. The walk threads
a `FieldPath` breadcrumb so every error names its location:

- A missing required key → `MissingField "bullets"` (located).
- A type mismatch → `SchemaMismatch "bullets.[2]: expected string, got number"`.
- An enum value that matches no constructor → `SchemaMismatch "(root): expected one of [Positive, Neutral, Negative]"`.

The three entry points differ only in how much they do:

| Function | Input | Validates? | Use |
|---|---|---|---|
| `fromModel` | `Value` | no | decode a JSON value |
| `fromModelChecked` | `Value` | yes | decode, then run the type's `Validatable` rule |
| `parseOutput` | raw `Text` | yes | parse text → JSON (→ `InvalidJSON` on failure), decode, validate |

### How `Maybe` decodes

A `Maybe a` field succeeds as `Nothing` when the key is **absent** *or* present as JSON
`null`; otherwise it decodes the value as `Just`. This is what makes optional fields robust
to providers that omit vs. null them.

---

## The validation hook (`Validatable`)

```haskell
class Validatable a where
  validate :: a -> Either Text a
  validate = Right          -- default: always valid
```

`Validatable` is a domain rule applied *after* a successful decode. It defaults to "always
valid," so types opt in by writing an instance. `fromModelChecked` runs it and turns a
rejection into a located `ValidationFailure`.

> **Important seam.** A bare `predict` node does **not** run your `Validatable` instance
> at the program level — the adapter's `parse` uses `fromModelChecked`, so type-level
> validation runs during decode, but program-level enforcement of *your own* predicates is
> the job of the [`validate`](./programs-and-combinators.md#validate) combinator. Use the
> combinator when you want a rejection to drive a retry or surface as a program failure.

---

## The adapter seam: native schema vs. prompt fallback

A `Signature i o` plus an input must become a wire request, and a reply must become a typed
`o`. That bridge is the `Adapter`:

```haskell
data Adapter i o = Adapter
  { render :: Signature i o -> i -> (Context, Options)
  , parse  :: Signature i o -> Response -> Either ShikumiError o
  }
```

Two adapters ship, and `adapterFor` / `capabilityFor` select per model:

```haskell
data ModelCapability = NativeSchema | PromptFallback

capabilityFor :: Model -> ModelCapability    -- pure check on (provider, api)
adapterFor    :: Model -> Adapter i o
```

- **`nativeAdapter` (the reliable path).** For models that support provider-native structured
  output (OpenAI Chat Completions, Anthropic Messages), the derived JSON schema is attached to
  the request and the provider *enforces* the shape. `parse` reads the structured JSON and
  decodes it.
- **`fallbackAdapter` (everything else).** For models without native structured output, the
  request asks for one `[[ ## fieldname ## ]]` section per output field, followed by a final
  `[[ ## completed ## ]]` marker (DSPy's convention). `parse` splits the sections, coerces
  each to its schema type (string-like fields stay strings; everything else is JSON-parsed),
  assembles a JSON object, and decodes it the same way.

The crucial property: **the program code is identical under either adapter** — only the wire
format differs. A field that is missing from the model's reply yields the same
`MissingField` downstream regardless of which adapter parsed it.

### Demos render the same way under both adapters

When a signature carries few-shot demos, both adapters render them as user/assistant message
pairs, the assistant side written as `[[ ## field ## ]]` sections. So an optimizer's
bootstrapped demos look consistent to the model whichever path is active.

### A note on the current native path

baikai's `Options` is gaining a native `response_format` / `output_config` field (delivered
as a separate extension). Until that lands in the local checkout, the native adapter's
`attachSchema` is a no-op and the native path reads the JSON from the assistant text — there
is exactly one place (`attachSchema`) that will set the field when it arrives. In practice the
prompt-fallback path is the exercised one today; the native path is wired and verified for
OpenAI. This does not change any of your code.

---

## Putting it together: what `runPredict` actually does

A single `Predict` node, when run, performs this sequence (in `Shikumi.Program.runPredict`):

1. **Overlay the node's parameters** onto the signature: substitute the instruction override
   if present, and decode the node's JSON demos back into the signature's typed demo channel.
   A demo whose JSON doesn't decode surfaces as a located `ShikumiError`.
2. **Pick the adapter** for the dispatch model via `adapterFor`.
3. **`render`** the effective signature + input into a baikai `(Context, Options)`.
4. **Issue the `LLM` call** (`complete`).
5. **`parse`** the response back into a typed `o`, throwing a `ShikumiError` on failure.

That is the entire wire behaviour, defined once and shared by both the sequential and the
concurrent executor. Everything above it (caching, tracing) wraps the `LLM` call in step 4;
everything below it (resilience, transport) is the interpreter that handles it. See
[Effects & the runtime](./effects-and-runtime.md).
