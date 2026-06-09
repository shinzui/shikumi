# 仕組み — Shikumi

**Typed, structured, evaluable language-model programs in Haskell.**

Shikumi lets you declare an LM-powered function whose input and output are ordinary
Haskell record types, run it against any provider, and have the JSON schema, decoding,
validation, caching, tracing, evaluation, and optimization all fall out of the types —
without ever writing a raw prompt string or hand-parsing model output.

```haskell
summarize :: (LLM :> es, Trace :> es, Cache :> es) => Program Article Summary
summarize = predict @Summarize
```

You run `runProgram summarize article` inside an `Eff` stack and get back a fully decoded
`Summary` — the schema sent to the provider was derived from `Summary`'s structure, the
response was decoded and validated against it, and the call was cached and traced.

---

## The name: 仕組み

**仕組み** (*shikumi*) is a Japanese word meaning **"the mechanism — the system behind how
something works."** It's the word you reach for when you want to describe not the surface
of a thing but its inner workings: the gears, the structure, the *arrangement* that makes
it behave the way it does. 仕 (*shi*) — "to do / to make / to serve"; 組み (*kumi*) — "to
assemble, to join, to put together." Literally, *the way the parts are put together to
make something function.*

That is exactly the stance of this framework. A language-model program is usually a pile of
prompt strings held together by hope — a surface with no mechanism underneath. Shikumi is
the **仕組み**: the structure that turns "ask a model and pray" into ordinary, well-typed
software where the input is a record, the output is a record, the failure modes are an
enumerated type, and the whole thing composes, type-checks, and can be evaluated and
improved like any other program. The name *is* the thesis — there is a mechanism here, and
you can see it, inspect it, and rewrite it.

---

## Why

Building LM software in most languages means programming *with prompts*: f-strings,
brittle regex parsing of free text, runtime type coercion, and a mutable global config
object. Shikumi is inspired by [DSPy](https://github.com/stanfordnlp/dspy) — Stanford's
framework for *programming, not prompting* language models — but it is designed from first
principles around Haskell's type system rather than ported from Python's dynamism.

Where DSPy leans on runtime frame introspection, Pydantic coercion, and in-place mutation
of a module tree, shikumi uses static alternatives:

| Concern | DSPy (Python) | Shikumi (Haskell) |
|---|---|---|
| Field schemas | runtime frame introspection | `GHC.Generics`, derived at compile time |
| A program's capabilities | mutable global `settings` | `effectful` effects, visible in the type |
| Program as data | a mutable module tree | a typed **GADT deep embedding** of `Program i o` |
| Output decoding | Pydantic runtime coercion | total, schema-driven decode to a typed error |
| Invalid pipelines | runtime failure | **a compile error** |

It sits on top of [**baikai**](https://github.com/) (媒介 / *mediation*, the provider &
transport layer — Claude, OpenAI, DeepSeek, OpenRouter, Ollama, any OpenAI-compatible
host) and adds exactly the layers baikai deliberately omits: structured output, caching,
retries, hierarchical tracing, effect integration, and the whole
program/evaluate/compile/optimize stack.

---

## A first look: records in, records out

You never write a prompt. You write the *types*, and a one-line description per field:

```haskell
data Article = Article
  { title :: Field "The article's headline" Text
  , body  :: Field "The full article text"  Text
  } deriving stock Generic
    deriving anyclass (ToSchema, FromModel, ToPrompt)

data Summary = Summary
  { headline  :: Field "A one-line summary"      Text
  , bullets   :: Field "Three to five key points" [Text]
  , sentiment :: Sentiment                          -- an enum-like sum
  , note      :: Maybe Text                          -- optional
  } deriving stock Generic
    deriving anyclass (ToSchema, FromModel, ToPrompt)

-- A domain rule, checked after decode:
instance Validatable Summary where
  validate s
    | n < 3 || n > 5 = Left "bullets: must have 3 to 5 items"
    | otherwise      = Right s
    where n = length (unField (bullets s))
```

The `Field "description" a` wrapper attaches a compile-time description to a field; a single
`Generics` walk recovers both the field name and its description, so they can never drift.
A bare `Text` field simply has no description.

Now declare and run the program:

```haskell
summarize :: Signature Article Summary
summarize = mkSignature "Summarize the article into a headline and key points."

main :: IO ()
main = do
  OpenAI.register
  let cfg = defaultLLMConfig globalProviderRegistry
  result <-
    runEff . runErrorNoCallStack @ShikumiError . runLLMResilient cfg $
      runProgram (predict summarize) myArticle
  case result of
    Right s  -> print (headline s)          -- a fully-typed Summary
    Left err -> print (err :: ShikumiError) -- an enumerated failure
```

If the model returns malformed output, you don't get a parse exception buried in a string —
you get a precise, typed value: `MissingField "bullets"`, `SchemaMismatch "...",`
`ValidationFailure "bullets: must have 3 to 5 items"`, `BudgetExceeded ...`, and so on.
Free-text parsing is an explicit escape hatch, never the default.

---

## Errors are a type, not a vibe

Every call returns either a typed value or one of an *enumerated* set of failures:

```haskell
data ShikumiError
  = InvalidJSON        Text  -- provider returned text that isn't valid JSON
  | MissingField       Text  -- a required output field was absent
  | SchemaMismatch     Text  -- decoded JSON didn't match the expected schema
  | ValidationFailure  Text  -- a typed value failed a Validatable rule
  | ProviderFailure    Text  -- the transport failed (mapped from baikai)
  | Timeout            Text  -- the call exceeded its time budget
  | BudgetExceeded     Text  -- the running cost ceiling was reached
```

Decode errors carry a field-path breadcrumb (`"bullets.[2]"`) so a deeply-nested mismatch
is still legible. The resilience interpreter knows which of these are *transient*
(`ProviderFailure`, `Timeout`) and worth retrying, and which are deterministic and not.

---

## Motivating examples

> The snippets below assume the **full V0.1–V0.5 vision** of the master plan is available.
> See **[Implementation status](#implementation-status)** for what is built today versus
> planned. Anything marked 🔭 is the designed surface, not yet shipped.

### 1. Chain-of-thought is just a derived program

`chainOfThought` augments the output with a leading `reasoning` field, asks the model to
think first, then projects the answer back out — so your program type stays `Program i o`,
and the reasoning node is an ordinary `Predict` node the optimizer can tune with no special
casing:

```haskell
classify :: Program SupportTicket Category
classify = chainOfThought ticketSignature

-- Or keep the reasoning visible:
classifyRaw :: Program SupportTicket (WithReasoning Category)
classifyRaw = chainOfThoughtRaw ticketSignature
```

### 2. Compose typed programs — mismatches are compile errors

```haskell
-- extract :: Program RawEmail   Invoice
-- enrich  :: Program Invoice    EnrichedInvoice
-- approve :: Program EnrichedInvoice Decision

pipeline_ :: Program RawEmail Decision
pipeline_ = extract >>> enrich >>> approve
--          ^ typechecks only because each stage's output type
--            equals the next stage's input type. Reorder them and
--            it does not compile.
```

### 3. Control flow as combinators

Every combinator is a constructor of the same `Program` GADT, so the result stays runnable,
inspectable by the optimizer, and serializable:

```haskell
import Shikumi.Combinator

-- Re-run on transient failure, up to 3 attempts:
robust = retry 3 (predict extractSig)

-- Reject bad output and re-run:
checked = validateRetry 3 (\inv -> total inv > 0) "total must be positive"
                          (predict extractSig)

-- Self-consistency: sample 5 times, take the modal answer:
voted = majorityVote 5 (TempSpread 0.7 0.3) classify

-- Map over a list with bounded concurrency:
batch = mapP 8 summarizePost            -- Program [Post] [Summary]

-- Fan one input to several programs and fold the results:
panel = ensemble [gpt4Judge, claudeJudge, deepseekJudge] majorityLabel
```

`runProgram` runs everything sequentially; `runProgramConc` honours the concurrency widths —
concurrency is an execution choice, not part of a program's type.

### 4. Structured output enforced server-side

When a provider supports it, the derived JSON schema is attached to the request via
baikai's native `response_format` (OpenAI) / `output_config` (Anthropic), so the provider
*enforces* the shape — no prompt coaxing. For everything else, an adapter falls back to a
`[[ ## field ## ]]` prompt format that's parsed the same way. The program code is identical;
only the wire differs.

### 5. 🔭 Evaluate against a dataset with a typed metric

```haskell
report <- evaluate classify dataset accuracyMetric
print (score report)          -- 0.0 .. 1.0
print (latencyP95 report)     -- typed latency / token / cost breakdown
print (failures report)       -- per-example failure analysis
```

`Dataset i o`, `Metric o`, and `Report` are all typed by `i`/`o` — not the untyped bags
DSPy uses. Golden tests drop straight into the project's test runner.

### 6. 🔭 Compile, then optimize against data

```haskell
-- Compile a program few-shot / chain-of-thought / retrieval-augmented:
compiled <- compileFewShot classify trainset

-- Then let an optimizer search for better demos and instructions,
-- driven by evaluation against a metric:
optimized <- bootstrapFewShot
               BootstrapConfig { rounds = 8, candidates = 16 }
               classify trainset accuracyMetric

-- Save the tuned parameters and replay later:
saveProgram "classify.v2" optimized
```

This is the payoff of the GADT deep embedding: an optimizer **traverses and rewrites each
node's parameters** (its instruction override and few-shot demos) as data, without runtime
reflection — then serializes the tuned parameter vector. A program's parameter count equals
its number of `Predict` nodes; `foldParams` reads them, `mapParamsAt n` edits node *n*, and
`programParams` / `setProgramParams` save and load them.

### 7. 🔭 Typed tools and a ReAct agent loop

```haskell
weatherTool :: Tool City Forecast   -- argument schema is Generic-derived
weatherTool = tool "get_weather" lookupForecast

researcher :: Program Question Answer
researcher = react agentSig [weatherTool, searchTool, calcTool]
```

### 8. 🔭 Caching, tracing, and deterministic replay

```haskell
runEff
  . runErrorNoCallStack @ShikumiError
  . runTraceOTel                      -- hierarchical spans, OpenTelemetry
  . runCacheSQLite "cache.db"         -- memory / SQLite / Postgres / Redis
  . runLLMResilient cfg
  $ runProgram summarize article
```

The cache key is a BLAKE3 digest over the canonical request, so identical calls are served
from cache; stored traces let you **replay** an entire run deterministically — and the
`shikumi` CLI exposes `eval`, `trace`, `optimize`, and `replay` over the same machinery.

---

## How it fits together

```
        ┌─────────────────────────────────────────────┐
        │  shikumi                                      │
        │                                               │
        │   Program i o   (GADT deep embedding)         │  ← run / rewrite / serialize
        │   Signature i o + Generic-derived schema      │  ← records in, records out
        │   Adapter (native schema | prompt fallback)   │
        │   LLM effect + ShikumiError + resilience      │  ← retries, rate limit, budget
        └───────────────────────┬───────────────────────┘
                                │  Baikai effect (baikai-effectful)
        ┌───────────────────────┴───────────────────────┐
        │  baikai (媒介)                                 │
        │   provider dispatch · model catalog · Usage/Cost │
        │   Content/Message/Tool · streaming events · IO   │
        └─────────────────────────────────────────────────┘
```

A `Program i o` is a typed GADT that can be three things at once:

- **run** as a typed function — `runProgram` interprets it as an `Eff` computation;
- **rewritten as data** — `paramsTraversal` / `foldParams` / `mapParamsAt` read and replace
  each node's optimizable parameters without running it (what the optimizer needs);
- **serialized** — `programShape` + `programParams` save the structure and the tuned
  parameter vector so an optimized program can be stored and replayed.

The constructor set is deliberately minimal; richer modules (`chainOfThought`, every
combinator) are *derived functions* over the core constructors, not new ones.

Because shikumi's framework code dispatches through the `LLM` effect — built in terms of
baikai's policy-free `Baikai` transport effect — it never carries `IOE`. Only the bottom
interpreter touches `IO`, so each program's effect row stays an honest capability ledger:
its type tells you exactly what it can do.

---

## Implementation status

This is an in-progress framework decomposed into twelve ExecPlans across five phases (see
[`docs/masterplans/1-shikumi-typed-lm-programming-framework.md`](docs/masterplans/1-shikumi-typed-lm-programming-framework.md)).

| Area | Status |
|---|---|
| **Runtime substrate** — `LLM` effect over baikai, `ShikumiError`, retries / rate-limiting / budget | ✅ Done |
| **Native structured output** — `response_format` / `output_config` (upstreamed to baikai) | ✅ Done |
| **Signatures & structured I/O** — Generic-derived schema, total decode, the `Adapter` seam | ✅ Done |
| **Typed program core** — `Program i o` GADT, `runProgram`, `predict`, `chainOfThought`, parameter traversal & serialization | ✅ Done |
| **Combinators** — `>>>`, `mapP`, `parallel2`, `retry`, `validate`, `majorityVote`, `ensemble` | 🔧 In progress |
| Caching (memory / SQLite / Postgres / Redis) | 🔭 Planned |
| Hierarchical tracing, OTel, deterministic replay | 🔭 Planned |
| Evaluation — `Dataset` / `Metric` / `evaluate` / `Report` | 🔭 Planned |
| Compiler — zero-shot / few-shot / CoT / RAG | 🔭 Planned |
| Optimizer — demo selection, bootstrap few-shot, instruction & ensemble search | 🔭 Planned |
| Typed tools + ReAct agents | 🔭 Planned |
| `shikumi` CLI — `eval`, `trace`, `optimize`, `replay` | 🔭 Planned |

> Note: today `runProgram` dispatches every node against a provider-neutral model (the
> prompt-fallback adapter). Real provider/model routing is supplied by the evaluation and
> CLI layers (or a future `Reader Model` effect) and is being wired in.

---

## Building

Shikumi builds with **GHC 9.12.4** inside a Nix dev shell, and depends on local checkouts of
`baikai` and `baikai-effectful` (see `cabal.project`).

```bash
nix develop .#ghc9124
cabal build shikumi
cabal test  shikumi          # hermetic; no network

# Opt into the live provider smoke test:
SHIKUMI_LIVE=1 OPENAI_API_KEY=... cabal test shikumi
```

---

## License

BSD-3-Clause © Nadeem Bitar
