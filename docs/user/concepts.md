# Core concepts & mental model

This guide is the conceptual spine. Read it once and every other reference will slot into
place. There is really only one big idea, plus four types that express it.

---

## The one big idea: a program is *data you can also run*

In most languages an LM "program" is a pile of prompt strings held together by hope. In
shikumi a program is a **typed value** — a `Program i o` — that is three things at once:

1. **Runnable.** `runProgram` interprets it as an `Eff` computation that issues model calls
   and returns a typed `o` (or throws a typed `ShikumiError`).
2. **Rewritable as data.** Its optimizable parameters (each node's instruction and few-shot
   demos) can be *read and replaced without running it* and without runtime reflection — this
   is what lets an optimizer tune it.
3. **Serializable.** Its structure and its tuned parameter vector can be saved and reloaded,
   so an optimized program persists across runs.

That triple is the thesis. Everything else — schemas, decoders, caching, evaluation — falls
out of taking it seriously. The name 仕組み (*shikumi*, "the mechanism") *is* the point:
there is a mechanism here, and you can see it, inspect it, and rewrite it.

---

## The four types you actually touch

### 1. `Field "description" a` — a documented field

```haskell
newtype Field (desc :: Symbol) a = Field { unField :: a }
```

A `Field "desc" a` wraps a value with a **compile-time description** carried as a type-level
string. A single `GHC.Generics` traversal recovers both the field *name* (from the record
selector) and its *description* (from `desc`), so the two can never drift. The wrapper is
opt-in per field — a bare `Text` field simply has no description.

```haskell
data Summary = Summary
  { headline :: Field "A one-line summary"      Text
  , bullets  :: Field "Three to five key points" [Text]
  , note     :: Maybe Text                        -- bare field, no description, optional
  }
```

### 2. `Signature i o` — a typed task description

```haskell
data Signature i o = Signature
  { instruction  :: Text          -- optimizable: the task description
  , demos        :: [Demo i o]     -- optimizable: worked examples
  , inputFields  :: [FieldMeta]    -- derived metadata (not optimizable)
  , outputFields :: [FieldMeta]    -- derived metadata (not optimizable)
  }
```

A signature bundles the natural-language instruction, worked demonstrations, and the field
metadata derived from `i`/`o`. The `instruction` and `demos` are the framework's
**optimizable parameters** — the compiler and optimizer rewrite them. The field lists are
*derived* and fixed. Build one with `mkSignature "…"`; the field metadata is recovered from
the types automatically.

### 3. `Program i o` — the runnable/rewritable/serializable value

A small GADT (a *deep embedding*) with a deliberately minimal constructor set. You rarely
write its constructors directly; you build programs with `predict`, `chainOfThought`, and the
combinators (`>>>`, `retry`, `validate`, `majorityVote`, `ensemble`, …). The full anatomy is
in [Programs & combinators](./programs-and-combinators.md).

```haskell
summarize :: Program Article Summary
summarize = predict summarizeSig
```

### 4. `ShikumiError` — the enumerated failure type

Every call returns either a typed value or one of a *closed set* of failures (below).

---

## Records in, records out

You declare the input and output types and derive four classes; that derivation *is* the
prompt engineering:

```haskell
data Article = Article
  { title :: Field "The article's headline" Text
  , body  :: Field "The full article text"  Text
  } deriving stock Generic
    deriving anyclass (ToSchema, FromModel, ToPrompt)
```

| Class | Direction | Role |
|---|---|---|
| `ToSchema` | type → JSON Schema | the shape sent to the provider |
| `FromModel` | JSON → type | total decode of the reply (failures are typed) |
| `ToPrompt` | type → labeled text | render input/demos for the prompt-fallback path |
| `Validatable` | type → `Either Text` | optional domain rule, defaults to "always valid" |

The mechanics — exactly how a record becomes a schema and how a reply becomes a value — are
in [Signatures & schemas](./signatures-and-schemas.md).

---

## Errors are a type, not a vibe

```haskell
data ShikumiError
  = InvalidJSON       Text  -- provider returned text that isn't valid JSON
  | MissingField      Text  -- a required output field was absent
  | SchemaMismatch    Text  -- decoded JSON didn't match the expected schema
  | ValidationFailure Text  -- a typed value failed a Validatable rule
  | ProviderFailure   Text  -- the transport failed (mapped from baikai)
  | Timeout           Text  -- the call exceeded its time budget
  | BudgetExceeded    Text  -- the running cost ceiling was reached
```

Three things make this more than a sum type:

- **Located decode errors.** `MissingField` / `SchemaMismatch` carry a field-path breadcrumb
  (`"bullets.[2]"`) so a deeply-nested mismatch is still legible. The breadcrumb renders the
  empty path as `(root)`.
- **A total mapping from baikai.** Transport-level `BaikaiError`s are mapped into this
  vocabulary by `fromBaikaiError`, so the whole framework shares one error type.
- **A transience policy.** `isTransient` decides which errors are worth retrying:
  `ProviderFailure` and `Timeout` are transient; decode, schema, validation, and budget
  errors are deterministic and retrying cannot fix them. The resilience interpreter consults
  exactly this predicate.

---

## How the pieces fit together

```
   Article ─┐
            │   predict summarizeSig
            ▼
   ┌──────────────────────────────────────────────┐
   │ Program Article Summary  (a typed value)       │
   │                                                 │
   │   • run        → runProgram   → Eff es Summary  │
   │   • rewrite    → mapParamsAt  → Program …       │  (optimizer)
   │   • serialize  → programShape + programParams   │  (save/load)
   └──────────────────────────────────────────────┘
            │  runProgram dispatches each node's LLM call
            ▼
   ┌──────────────────────────────────────────────┐
   │ LLM effect  →  (cache? trace? replay?)  →       │  stackable interpreters
   │ runLLMResilient  →  Baikai transport  →  IO     │  IO only at the bottom
   └──────────────────────────────────────────────┘
            ▼
        Summary  (or a typed ShikumiError)
```

The key property visible here: shikumi's framework code dispatches through the **`LLM`
effect**, which is built in terms of baikai's policy-free transport effect — so it **never
carries `IOE`**. Only the bottom interpreter touches `IO`. Each program's effect row is an
honest capability ledger: its type tells you exactly what it can do. That is the subject of
[Effects & the runtime](./effects-and-runtime.md).

---

## Where to go next

- The mechanics of schema/decode: [Signatures & schemas](./signatures-and-schemas.md).
- The full GADT and every combinator: [Programs & combinators](./programs-and-combinators.md).
- The effect stack and resilience: [Effects & the runtime](./effects-and-runtime.md).
