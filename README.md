# 仕組み — Shikumi

**Typed, structured, evaluable language-model programs in Haskell.**

Shikumi lets you describe an LM-powered function with ordinary Haskell input and
output types. From those types it derives the provider schema, renders inputs,
decodes model output, reports typed failures, and gives the program a structure
that can be composed, traced, cached, evaluated, optimized, serialized, and
replayed.

```haskell
data Article = Article
  { title :: Field "The article headline" Text
  , body  :: Field "The full article text" Text
  }
  deriving stock Generic
  deriving anyclass (ToSchema, FromModel, ToPrompt)

data Summary = Summary
  { headline :: Field "One-line summary" Text
  , bullets  :: Field "Three to five key points" [Text]
  }
  deriving stock Generic
  deriving anyclass (ToSchema, FromModel, ToPrompt)

summarize :: Program Article Summary
summarize = predict (mkSignature "Summarize the article.")
```

Run the program under an `effectful` stack and the result is a decoded
`Summary`, or an enumerated `ShikumiError` such as `InvalidJSON`,
`MissingField`, `SchemaMismatch`, `ValidationFailure`, `ProviderFailure`,
`Timeout`, or `BudgetExceeded`.

Shikumi sits on top of [baikai](https://hackage.haskell.org/package/baikai), the
provider and transport layer, and adds the language-programming layer: structured
output, typed programs, combinators, caching, tracing, replay, evaluation,
compilation, optimization, tools, agents, streaming, multimodal input, and code
execution modules.

## The Name: 仕組み

**仕組み** (*shikumi*) is a Japanese word meaning **"the mechanism — the system
behind how something works."** It is the word you reach for when you want to
describe not the surface of a thing but its inner workings: the gears, the
structure, the arrangement that makes it behave the way it does. 仕 (*shi*) means
"to do / to make / to serve"; 組み (*kumi*) means "to assemble, to join, to put
together." Literally, it is *the way the parts are put together to make
something function.*

That is the stance of this framework. A language-model program is often a pile
of prompt strings held together by convention, with no inspectable mechanism
underneath. Shikumi is the **仕組み**: the structure that turns "ask a model and
hope" into ordinary, well-typed software where the input is a record, the output
is a record, the failure modes are enumerated, and the whole thing composes,
type-checks, and can be evaluated and improved like any other program. The name
is the thesis: there is a mechanism here, and you can see it, inspect it, and
rewrite it.

## Why Shikumi

Most LM application code treats prompts as the program: string templates,
runtime JSON parsing, ad hoc retries, and global provider configuration.
Shikumi treats the program as a typed Haskell value:

- `Signature i o` describes a model task over input type `i` and output type
  `o`.
- `Program i o` is a GADT that can be run, composed, inspected, rewritten, and
  serialized.
- `Field "description" a`, `ToSchema`, `ToPrompt`, and `FromModel` derive the
  wire contract from record types.
- `effectful` interpreters install providers, retries, budgets, routing,
  caching, tracing, replay, and streaming without changing the program.
- Evaluation and optimizers operate on the same `Program i o` values that run in
  production.

## What Ships

The repository is split into focused Cabal packages:

| Package | Role |
|---|---|
| `shikumi` | Core runtime, schemas, adapters, `Program`, combinators, routing, streaming, multimodal input, self-refinement |
| `shikumi-cache` | Content-addressed cache effect, in-memory backend, SQLite backend |
| `shikumi-cache-redis` | Redis cache backend |
| `shikumi-cache-postgres` | Postgres cache backend |
| `shikumi-trace` | Hierarchical tracing and deterministic replay |
| `shikumi-trace-otel` | OpenTelemetry export |
| `shikumi-eval` | Typed datasets, metrics, reports, and golden helpers |
| `shikumi-compile` | Zero-shot, few-shot, chain-of-thought, and RAG compilation |
| `shikumi-optimize` | Demo selection, instruction search, MIPROv2, COPRO, GEPA, KNN, bootstrap random search, ensemble search |
| `shikumi-tools` | Typed tools, ReAct agents, `programOfThought`, and `codeAct` |
| `shikumi-cli` | Offline-capable CLI for eval, trace, optimize, and replay |
| `shikumi-jitsurei` | Runnable worked examples |

The implemented surface includes:

- Generic-derived JSON schemas and total decoding.
- Native structured output for capable providers, plus prompt-fallback and XML
  adapters.
- Declarative field constraints with schema and post-decode validation.
- Typed `Image` input fields.
- Sequential and concurrent program runners.
- `>>>`, `mapP`, `parallel2`, `retry`, `validate`, `majorityVote`, and
  `ensemble`.
- Ambient model routing, retries, rate limiting, and budgets.
- Content-addressed caching with in-memory, SQLite, Redis, and Postgres
  backends.
- Hierarchical traces, node-correlated spans, live OTel export, and fail-closed
  replay.
- Typed evaluation reports and optimizers that rewrite program parameters.
- Typed tools, ReAct agents, reward-driven self-refinement, program-level
  streaming, and hermetic code-execution modules.

## Try It Offline

All worked examples run against deterministic in-process stub LMs. They do not
need API keys or network access.

```bash
nix develop .#ghc9124
cabal run shikumi-jitsurei
cabal run jitsurei-predict
cabal run jitsurei-compose
cabal run jitsurei-combinators
cabal run jitsurei-evaluate
cabal run jitsurei-optimize
cabal run jitsurei-react
cabal run jitsurei-trace-replay
cabal run jitsurei-multimodal
cabal run jitsurei-streaming
cabal run jitsurei-adapters
cabal run jitsurei-codeexec
```

The bundled CLI is also offline by default:

```bash
cabal run shikumi-cli:exe:shikumi -- eval --program sentiment
cabal run shikumi-cli:exe:shikumi -- trace sentiment --store-dir .shikumi
cabal run shikumi-cli:exe:shikumi -- optimize --program sentiment --optimizer bootstrap-fewshot --out sentiment.json
cabal run shikumi-cli:exe:shikumi -- replay sentiment --store-dir .shikumi
```

## Core Examples

Compose typed programs. Reordering incompatible stages is a compile error.

```haskell
pipeline :: Program RawEmail Decision
pipeline = extractInvoice >>> enrichInvoice >>> approveInvoice
```

Add control flow without leaving the `Program` representation:

```haskell
robust :: Program Review Label
robust =
  majorityVote 5 (TempSpread 0.7 0.3) $
    validateRetry 3 validLabel "label must be valid" $
      retry 2 classify
```

Evaluate a program against a typed dataset:

```haskell
report <- evaluate dataset exactMatch classify
print (aggregateScore report)
putStr (renderReportText report)
```

Optimize the same program value:

```haskell
optimized <- optimize (bootstrapFewShot classify defaultBudget) trainset exactMatch classify
BL.writeFile "classify.json" (encodeCompiled optimized)
```

Trace, cache, and replay by changing interpreters around the same program:

```haskell
(result, tree) <-
  runEff
    . runErrorNoCallStack @ShikumiError
    . runTrace
    . cachedLLM
    . tracedLLM
    . runLLMResilient cfg
    $ runProgram summarize article
```

## Documentation

Start with the [user guide](docs/user/README.md):

| Guide | Covers |
|---|---|
| [Getting started](docs/user/getting-started.md) | Install, run examples, write a first record-in/record-out program |
| [When to use shikumi](docs/user/when-to-use-shikumi.md) | Choosing shikumi vs. using baikai directly |
| [Core concepts](docs/user/concepts.md) | `Field`, `Signature`, `Program`, and `ShikumiError` |
| [Signatures & schemas](docs/user/signatures-and-schemas.md) | Schema derivation, adapters, constraints, multimodal input |
| [Programs & combinators](docs/user/programs-and-combinators.md) | Program nodes, runners, combinators, serialization |
| [Effects & runtime](docs/user/effects-and-runtime.md) | `LLM`, routing, retries, rate limits, budgets, streaming |
| [Caching, tracing & replay](docs/user/caching-tracing-replay.md) | Cache keys, trace trees, OTel, deterministic replay |
| [Evaluation & optimization](docs/user/evaluation-and-optimization.md) | Datasets, metrics, reports, compilers, optimizers |
| [Tools & agents](docs/user/tools-and-agents.md) | Typed tools, ReAct agents, code execution |
| [CLI](docs/user/cli.md) | Registry wiring and offline subcommands |

The implementation history lives under [docs/plans](docs/plans) and
[docs/masterplans](docs/masterplans). Those files are useful for design context, but the
user guide is the maintained usage documentation.

## Building

Shikumi builds with **GHC 9.12.4** inside the Nix dev shell. The system compiler
may be different; use the shell.

```bash
nix develop .#ghc9124
cabal build all
cabal test all
```

Tests are hermetic by default. To opt into the live provider smoke test:

```bash
SHIKUMI_LIVE=1 OPENAI_API_KEY=... cabal test shikumi
```

## License

BSD-3-Clause © Nadeem Bitar
