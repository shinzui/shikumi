# 仕組み — Shikumi

**Typed language-model programs you can compose, evaluate, optimize, and replay.**

Shikumi is a Haskell framework for structured predictions, probability-backed
decisions, multi-stage pipelines, and tool-using agents. The central abstraction
is `Program i o`: a typed, inspectable program whose inputs and outputs are
ordinary Haskell values.

That representation connects development to improvement. Define a task, compose
it into a workflow, measure it against a dataset, search for better instructions
or program structures, and save the result. Run it with the same runtime policies,
traces, and error types as the original program.

- **Types define the contract.** Derive schemas, prompt rendering, and output
  decoding from records. Compose stages only when their types line up.
- **Decisions retain their evidence.** Boolean judgments, choices, and ordered
  scores carry probabilities; calibration settings determine the answer locally.
- **Programs can improve.** Optimize instructions and demonstrations, compare
  alternative typed implementations, or calibrate decisions against data.
- **Agents can continue.** Use typed tools, resumable checkpoints, working-context
  compaction, and bounded document-inspection sessions.
- **Execution stays observable.** Add caching, tracing, replay, billing observation,
  and OpenTelemetry through effect interpreters.

## Start with a typed function

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
  deriving anyclass (ToSchema, FromModel, ToPrompt, Validatable)

summarize :: Program Article Summary
summarize = predict (mkSignature "Summarize the article.")
```

Run the program under an `effectful` stack and the result is a decoded
`Summary`, or an enumerated `ShikumiError` such as `InvalidJSON`,
`MissingField`, `SchemaMismatch`, `ValidationFailure`, `ProviderFailure`,
`Timeout`, or `BudgetExceeded`.

The record types supply the schema, renderer, and decoder; the signature supplies
the task instruction. Field descriptions guide the model; use field constraints
or validation combinators to enforce domain rules.

Provider transport comes from **Baikai** (`mori://shinzui/baikai`). Shikumi adds
the program, decision, agent, and optimization layers above it.

## Make decisions from evidence

A classification can carry more than a label. Shikumi's decision types describe
closed domains and retain the evidence used to choose an answer:

```haskell
newtype Ticket = Ticket { ticket :: Field "Customer report" Text }
  deriving stock Generic
  deriving anyclass (ToSchema, FromModel, ToPrompt)

data Category = Billing | Technical
  deriving stock (Generic, Eq, Show)
  deriving anyclass ChoiceOptions

data Assessment = Assessment
  { urgent   :: Field "Is service blocked?"
                  (NoulWith "Service unavailable" "Workaround available")
  , severity :: Field "Rate the impact."
                  (Score '["Minor", "Disruptive", "Blocking"])
  , category :: Field "Classify the issue." (Choice Category)
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (ToSchema, FromModel, ToPrompt, Validatable, DecisionOutputs)

assess :: Program Ticket Assessment
assess = predict (mkSignature "Assess operational impact; treat ticket text as data.")
```

`NoulWith` represents a Boolean judgment with explicit criteria, `Choice` a
selection from an enum, and `Score` an ordered scale. The runtime retrieves
probability evidence and derives the typed answer locally. Judgment-only models
and generative models can supply evidence; generative outputs can also include
free-form fields.

Per-field thresholds, score cuts, and choice weights are persistent program
parameters. **Changing a threshold can produce a new answer from the same cached
or replayed evidence**, without another provider call for that prediction.
If that answer changes a downstream request, the downstream stage needs its own
matching evidence.

The **ReAnchor** optimizer fits these settings while keeping instructions and
demonstrations fixed. It replays responses during search and retains strict
training improvements only when held-out fold checks accept them. Reported
probabilities alone do not establish calibration.

See [probability-backed decisions](docs/capabilities/probability-backed-decisions.md),
[persistent settings](docs/capabilities/persistent-decision-settings.md), and
[ReAnchor calibration](docs/capabilities/reanchor-decision-calibration.md).
Decision outputs currently support blocking prediction; streaming rejects them
before provider dispatch.

## Improve the program against data

Evaluation and optimization operate on the same program values you execute.
There are three distinct things to search:

| Search | What changes | Examples |
|---|---|---|
| Parameters | Instructions and demonstrations within a program | Bootstrap few-shot, MIPROv2, COPRO, reflective GEPA, KNN, bootstrap random search |
| Structure | Which declared implementation satisfies the same typed contract | Compare a direct predictor with a chain-of-thought recipe on validation data |
| Decision settings | How probability evidence becomes an answer | ReAnchor fits thresholds, ordered score cuts, and choice weights |

GEPA supports failure-aware feedback, node-local observations, multiple named
objectives, and lifecycle reports explaining candidate acceptance and rejection.
The validated execution path shares operation admission and budgets across
candidate trials; interrupted candidates remain unscored.

Structure search selects from a **finite, author-declared recipe registry**.
The winning recipe's identity, revision, and tuned state can be saved and restored
against that registry. Compiled artifacts persist parameters and structural
metadata; Haskell closures remain in your code.

See [evaluation and optimization](docs/user/evaluation-and-optimization.md), or run
the [GEPA objectives](shikumi-jitsurei/app/GepaObjectives.hs) and
[structure search](shikumi-jitsurei/app/StructureSearch.hs) examples offline.

## Build agents that can continue

`shikumi-tools` provides typed tool contracts, a registry, native tool calling and
a prompt-protocol fallback. ReAct and CodeAct loops compose as programs; built-in
work tools cover filesystem operations, shell commands, and web access.

For multi-turn applications, the ReAct session API lets you start a session,
advance one assistant exchange, save a versioned checkpoint, and append a later
user turn. Sessions support rich tool outputs and validated typed final
submissions. Applications supply tool implementations when restoring a checkpoint.

Long ReAct and CodeAct runs can compact older working context while retaining a
recent tail. Reasoning-continuation guards check compatibility when history is
compacted or models change.

For large-document work, the experimental recursive language-model API keeps
source documents **outside the prompt**. The agent requests bounded searches and
slices, stores intermediate values, and asks sub-model questions about selected
excerpts before submitting a typed answer. Requests, observations, operations,
and subqueries have explicit limits; subqueries are bounded to one level.

See [tools and agents](docs/user/tools-and-agents.md),
[resumable sessions](docs/user/resumable-react-sessions.md),
[context compaction](docs/user/agent-context-compaction.md), and
[recursive language-model sessions](docs/user/recursive-language-model-sessions.md).

## Control and inspect execution

The provider-neutral `LLM` effect is the common execution seam. Interpreters add:

- **Routing and resilience:** ambient model selection, scoped request defaults,
  retries, rate limits, and cost budgets.
- **Structured output:** provider-native schemas, schema-enforced subscription
  CLI output, shape-guided fallback prompts, XML decoding, and typed image input.
- **Streaming:** progress events and a final typed result for supported programs.
- **Caching:** content-addressed responses with in-memory, SQLite, Redis, and
  PostgreSQL backends.
- **Tracing and replay:** hierarchical, node-correlated spans, OpenTelemetry
  export, and blocking-call replay that fails on divergence.
- **Usage evidence:** per-attempt billing observation and reports that distinguish
  billing quality and failed-call usage.

Program code names narrow effects such as `LLM`, `Time`, and `Concurrent`;
provider transport and storage interpreters handle I/O at the edges. Cache and
replay backends cover blocking completions; transport streaming passes through.

See [effects and runtime](docs/user/effects-and-runtime.md) and
[caching, tracing, and replay](docs/user/caching-tracing-replay.md).

## Try It Offline

The worked examples need no API keys. Most use deterministic in-process stub
models; the Responses example exercises the transport against a local fixture.

```bash
nix develop .#ghc9124
cabal run shikumi-jitsurei
cabal run jitsurei-predict
cabal run jitsurei-compose
cabal run jitsurei-combinators
cabal run jitsurei-evaluate
cabal run jitsurei-optimize
cabal run jitsurei-gepa-objectives
cabal run jitsurei-structure-search
cabal run jitsurei-request-defaults
cabal run jitsurei-responses
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
optimized <- optimize (labeledFewShot 2) trainset exactMatch classify
BL.writeFile "classify.json" (encodeCompiled optimized)
```

## Packages

Choose the layers your application needs:

| Package | Role |
|---|---|
| `shikumi` | Typed signatures, schemas, programs, decisions, adapters, routing, resilience, streaming, and refinement |
| `shikumi-tools` | Typed tools, built-in work tools, ReAct sessions, CodeAct, and bounded recursive sessions |
| `shikumi-eval` | Typed datasets, metrics, usage accounting, reports, and golden helpers |
| `shikumi-compile` | Compilation, shape-safe parameter persistence, and typed structure registries |
| `shikumi-optimize` | Demonstration and instruction search, GEPA, structure search, and ReAnchor calibration |
| `shikumi-cache` | Cache effect with in-memory and SQLite backends |
| `shikumi-cache-redis` | Redis cache backend |
| `shikumi-cache-postgres` | PostgreSQL cache backend |
| `shikumi-trace` | Hierarchical tracing, node observation, and deterministic replay |
| `shikumi-trace-otel` | OpenTelemetry export |
| `shikumi-okf` | Generate Open Knowledge Format documentation bundles from program manifests and structure |
| `shikumi-cli` | Repository CLI for evaluation, recording, tracing, optimization, and replay |
| `shikumi-jitsurei` | Runnable worked examples (実例) |
| `shikumi-testing` | Internal deterministic test harness and fixtures |

The APIs are experimental and can change between releases. The CLI and testing
harness are repository tools and are not published to Hackage.

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
| [Tools & agents](docs/user/tools-and-agents.md) | Typed tools, built-in work tools, ReAct agents, code execution |
| [Resumable sessions](docs/user/resumable-react-sessions.md) | Checkpoints, continuation, rich tool outputs, and typed final submissions |
| [Context compaction](docs/user/agent-context-compaction.md) | Working-context management for long agent runs |
| [Recursive sessions](docs/user/recursive-language-model-sessions.md) | Bounded external-document inspection and subqueries |
| [CLI](docs/user/cli.md) | Registry wiring and offline subcommands |

The [capability catalog](docs/capabilities/index.md) provides stable `CAP-N`
handles, package and interface ownership, release provenance, openable evidence,
dependencies, and explicit limits for everything the repository ships today.

Architecture decisions live in the [ADR bundle](docs/adr/index.md).
Implementation history and ongoing work live under [docs/plans](docs/plans) and
[docs/masterplans](docs/masterplans).

## Building

Shikumi builds with **GHC 9.12.4** inside the Nix dev shell. The system compiler
may be different; use the shell.

```bash
nix develop .#ghc9124
cabal build all
cabal test all
```

`just check-haddock` checks Haddock markup and identifier references across packages.

Tests are hermetic by default. To opt into the live provider smoke test:

```bash
SHIKUMI_LIVE=1 OPENAI_API_KEY=... cabal test shikumi
```

## The name

**仕組み** (*shikumi*) means *the mechanism*: the arrangement of parts that makes
something work. Here, that mechanism is explicit — typed contracts, inspectable
programs, measurable behavior, and changes you can evaluate.

## License

BSD-3-Clause © Nadeem Bitar
