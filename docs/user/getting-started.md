# Getting started

This guide takes you from nothing to a running, fully-typed LM program — offline, with no
API key. By the end you will understand the shape of every shikumi program: **records in,
records out, typed errors, no prompt strings.**

---

## Prerequisites

Shikumi builds with **GHC 9.12.4** inside a Nix dev shell and depends on local checkouts of
[`baikai`](../../README.md) and `baikai-effectful` (wired in `cabal.project`).

```bash
nix develop .#ghc9124
cabal build all
cabal test  all              # hermetic across every package; no network
```

The packages, at a glance:

| Package | What it gives you |
|---|---|
| `shikumi` | The core: `Field`, `Signature`, `Program`, the `LLM` effect, `ShikumiError`, schema derivation, combinators. |
| `shikumi-cache` (`-redis`, `-postgres`) | The `Cache` effect and its backends (in-memory, SQLite, Redis, Postgres). |
| `shikumi-trace` (`-otel`) | Hierarchical tracing, trace files, deterministic replay, OpenTelemetry export. |
| `shikumi-eval` | `Dataset` / `Metric` / `Report` and the evaluation runner. |
| `shikumi-compile` | Prompting strategies (zero-shot / few-shot / CoT / RAG) compiled into a program. |
| `shikumi-optimize` | Four optimizers that search for better demos and instructions. |
| `shikumi-tools` | Typed tools and the ReAct agent loop. |
| `shikumi-cli` | The `shikumi` executable: `eval` / `trace` / `optimize` / `replay`. |
| `shikumi-jitsurei` | 実例 — runnable, offline worked examples of everything above. |

---

## See it run before you write anything

Every concept in this guide has a **runnable, offline counterpart** in the
[`shikumi-jitsurei`](../../shikumi-jitsurei) package. Each runs against a deterministic
in-process stub LM — no API key, no network — so it is an executable demonstration of the
real API. List them, then run one:

```bash
cabal run shikumi-jitsurei        # lists every example
cabal run jitsurei-predict        # records in, records out; typed errors and validate
```

| Run | Shows |
|---|---|
| `jitsurei-predict` | records in, records out; typed errors and `validate` |
| `jitsurei-compose` | compose typed programs with `>>>` |
| `jitsurei-combinators` | `retry` / `validate` / `mapP` / `majorityVote` / `ensemble` |
| `jitsurei-evaluate` | a typed `Metric` over a `Dataset` → a `Report` |
| `jitsurei-optimize` | optimize demos, then serialize & reload them |
| `jitsurei-react` | a typed tool and a ReAct agent loop |
| `jitsurei-trace-replay` | caching, hierarchical tracing, deterministic replay |

The shared offline harness lives in
[`Shikumi.Jitsurei.Stub`](../../shikumi-jitsurei/src/Shikumi/Jitsurei/Stub.hs); each
`app/` module is a self-contained `main` you can lift into your own project.

---

## Your first program

### 1. Declare the types

You never write a prompt. You write the input and output *records*, and a one-line
description per field. The `Field "description" a` wrapper attaches a compile-time
description; a bare field simply has no description.

```haskell
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}

import Shikumi.Schema           -- ToSchema, FromModel, Validatable, Field
import Shikumi.Adapter          -- ToPrompt

data Article = Article
  { title :: Field "The article's headline" Text
  , body  :: Field "The full article text"  Text
  } deriving stock Generic
    deriving anyclass (ToSchema, FromModel, ToPrompt)

data Sentiment = Positive | Neutral | Negative   -- an enum-like sum
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToSchema, FromModel, ToPrompt)

data Summary = Summary
  { headline  :: Field "A one-line summary"      Text
  , bullets   :: Field "Three to five key points" [Text]
  , sentiment :: Sentiment
  , note      :: Maybe Text                        -- optional / nullable
  } deriving stock Generic
    deriving anyclass (ToSchema, FromModel, ToPrompt)
```

Those four derived classes are the whole contract:

- **`ToSchema`** — derive the JSON schema sent to the provider.
- **`FromModel`** — totally decode the reply back into the record (every failure is a typed error).
- **`ToPrompt`** — render the record as labeled text for the prompt fallback / demos.
- **`Validatable`** — an optional domain rule, defaulting to "always valid".

### 2. Declare a domain rule (optional)

```haskell
instance Validatable Summary where
  validate s
    | n < 3 || n > 5 = Left "bullets: must have 3 to 5 items"
    | otherwise      = Right s
    where n = length (unField (bullets s))
```

A `Validatable` rule is enforced where you ask for it — by wrapping a program with the
[`validate`](./programs-and-combinators.md#validate) combinator, which surfaces a rejection
as a typed `ValidationFailure`. (`predict` on its own does *not* run a type's `Validatable`
instance; the combinator is the program-level seam.)

### 3. Build the signature and the program

```haskell
import Shikumi.Signature (Signature, mkSignature)
import Shikumi.Module    (predict)

summarize :: Signature Article Summary
summarize = mkSignature "Summarize the article into a headline and key points."

summarizeP :: Program Article Summary
summarizeP = predict summarize
```

A `Signature i o` bundles the task instruction, worked demos, and the field metadata derived
from `i`/`o`. `predict` turns it into a one-node `Program`.

### 4. Run it

`runProgram` interprets the program as an `Eff` computation. You discharge the `LLM` effect
at the bottom of the stack — against a real provider via baikai, or (here) against the
offline stub:

```haskell
import Shikumi.Program (runProgram)
import Effectful (runEff)
import Effectful.Error.Static (runErrorNoCallStack)
import Shikumi.Jitsurei.Stub (runStub, markerResponse)

main :: IO ()
main = do
  let stub _ctx = markerResponse
        [ ("headline", "Rates held steady")
        , ("bullets", "[\"point one\",\"point two\",\"point three\"]")
        , ("sentiment", "Neutral")
        ]
  result <- runStub stub summarizeP (Article (field "…") (field "…"))
  case result of
    Right s  -> print (unField (headline s))   -- a fully-typed Summary
    Left err -> print (err :: ShikumiError)     -- an enumerated failure
```

Against a real provider, the bottom of the stack is `runLLMResilient` instead of the stub —
see [Effects & the runtime](./effects-and-runtime.md). The program code is identical; only
the bottom interpreter differs.

---

## What you get when it goes wrong

If the model returns malformed output, you don't get a parse exception buried in a string —
you get a precise, typed value:

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

Decode errors carry a field-path breadcrumb (`"bullets.[2]"`) so a deeply-nested mismatch
is still legible. See [Core concepts](./concepts.md#errors-are-a-type-not-a-vibe).

---

## Where to go next

- Not sure shikumi is even the right tool? Read
  [When to use shikumi](./when-to-use-shikumi.md) first.
- Want the mental model before more code? [Core concepts](./concepts.md).
- Want to know *how* the schema and decode work? [Signatures & schemas](./signatures-and-schemas.md).
