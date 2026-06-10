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

-- A domain rule. You enforce it at the program level with the `validate`
-- combinator (see example 1 below); this instance documents the rule.
instance Validatable Summary where
  validate s
    | n < 3 || n > 5 = Left "bullets: must have 3 to 5 items"
    | otherwise      = Right s
    where n = length (unField (bullets s))
```

The `Field "description" a` wrapper attaches a compile-time description to a field; a single
`Generics` walk recovers both the field name and its description, so they can never drift.
A bare `Text` field simply has no description.

> **A note on validation.** A `Validatable` rule is enforced where you ask for it — by wrapping
> a program with the [`validate`](#3-control-flow-as-combinators) combinator, which surfaces a
> rejection as a typed `ValidationFailure`. (`predict` on its own does *not* run a type's
> `Validatable` instance; the combinator is the program-level seam.) The runnable
> [`jitsurei-predict`](shikumi-jitsurei/app/Predict.hs) example shows all three outcomes:
> a clean decode, a `MissingField`, and a `ValidationFailure`.

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

> The snippets below reflect the **shipped** surface. The in-memory **and** persistent cache
> backends (SQLite, Redis, Postgres), ambient model routing, the embeddings backend,
> node-correlated tracing, and the CLI's live OpenTelemetry export all ship — see
> **[Implementation status](#implementation-status)**.

Every snippet below has a **runnable, offline counterpart** in the
[`shikumi-jitsurei`](shikumi-jitsurei) package (実例, *worked examples*). Each one runs against
a deterministic in-process stub LM — no API key, no network — so it is an executable
demonstration of the real API, not a sketch:

| Run | Shows | Source |
|---|---|---|
| `cabal run jitsurei-predict` | records in, records out; typed errors and `validate` | [`app/Predict.hs`](shikumi-jitsurei/app/Predict.hs) |
| `cabal run jitsurei-compose` | compose typed programs with `>>>` | [`app/Compose.hs`](shikumi-jitsurei/app/Compose.hs) |
| `cabal run jitsurei-combinators` | `retry` / `validate` / `mapP` / `majorityVote` / `ensemble` | [`app/Combinators.hs`](shikumi-jitsurei/app/Combinators.hs) |
| `cabal run jitsurei-evaluate` | a typed `Metric` over a `Dataset` → a `Report` | [`app/Evaluate.hs`](shikumi-jitsurei/app/Evaluate.hs) |
| `cabal run jitsurei-optimize` | optimize demos, then serialize & reload them | [`app/Optimize.hs`](shikumi-jitsurei/app/Optimize.hs) |
| `cabal run jitsurei-react` | a typed tool and a ReAct agent loop | [`app/ReActAgent.hs`](shikumi-jitsurei/app/ReActAgent.hs) |
| `cabal run jitsurei-trace-replay` | caching, hierarchical tracing, deterministic replay | [`app/TraceReplay.hs`](shikumi-jitsurei/app/TraceReplay.hs) |
| `cabal run jitsurei-multimodal` | an image input field the model actually sees | [`app/Multimodal.hs`](shikumi-jitsurei/app/Multimodal.hs) |
| `cabal run jitsurei-streaming` | program-level streaming: field chunks + status messages | [`app/Streaming.hs`](shikumi-jitsurei/app/Streaming.hs) |
| `cabal run jitsurei-adapters` | XML adapter, two-step extraction, declarative field constraints | [`app/Adapters.hs`](shikumi-jitsurei/app/Adapters.hs) |
| `cabal run jitsurei-codeexec` | `programOfThought` / `codeAct` over a hermetic sandbox | [`app/CodeExec.hs`](shikumi-jitsurei/app/CodeExec.hs) |

The shared offline harness (the stub LM and the response builders) lives in
[`Shikumi.Jitsurei.Stub`](shikumi-jitsurei/src/Shikumi/Jitsurei/Stub.hs); each `app/` module is a
self-contained `main` you can lift straight into your own project.

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

### 5. Evaluate against a dataset with a typed metric

```haskell
report <- evaluatePure dataset exactMatch classify
print  (aggregateScore report)   -- 0.0 .. 1.0
putStr (renderReportText report)  -- score, pass/fail, tokens, cost, latency
```

`Dataset i o`, `Metric o`, and `Report` are all typed by `i`/`o` — not the untyped bags
DSPy uses (`Metric o = o -> Prediction o -> Score`). A failing example scores zero rather
than aborting the run, so an optimizer scoring many candidates measures robustness. Golden
helpers drop straight into the project's test runner.

### 6. Compile, then optimize against data

```haskell
-- Compile a prompting strategy into the program (zero-shot / few-shot / CoT / RAG):
let compiled = compile chainOfThoughtCompiler classify

-- Then let an optimizer search for better demos and instructions,
-- driven by evaluation against a metric:
optimized <- optimize (bootstrapFewShot classify defaultBudget)
                       trainset exactMatch classify

-- Save the tuned parameter state, load it back onto a structural template:
BL.writeFile "classify.json" (encodeCompiled optimized)
-- decodeCompiledOnto classify <$> BL.readFile "classify.json"
```

This is the payoff of the GADT deep embedding: an optimizer **traverses and rewrites each
node's parameters** (its instruction override and few-shot demos) as data, without runtime
reflection — then serializes the tuned parameter vector. A program's parameter count equals
its number of `Predict` nodes; `foldParams` reads them, `mapParamsAt n` edits node *n*, and
`programParams` / `setProgramParams` save and load them. Nine optimizers ship — demo selection
(`labeledFewShot`, `bootstrapFewShot`, `bootstrapRandomSearch`, `knnFewShot`), instruction search
(`instructionSearch`, `copro`), joint instruction×demo search (`miprov2`), reflective evolution
(`gepa`), and ensembling (`ensembleSearch`) — all at DSPy parity, all returning the same
`CompiledProgram`. The instruction optimizers share one grounded LM proposer, and inference-time
self-refinement modules (`bestOfN`, `refine`, `multiChainComparison`) wrap any program to steer
its re-runs by a reward.

### 7. Typed tools and a ReAct agent loop

A tool is an ordinary function over record types; its argument schema is Generic-derived and
lowered to baikai's wire tool. A `react` agent is itself a `Program`, so it composes, traces,
and optimizes like any other:

```haskell
weatherTool :: Tool City Forecast
weatherTool = mkTool "get_weather" "Look up a city's forecast." (\c -> pure (lookupForecast c))

researcher :: Program Question Answer
researcher = react agentSig (mkRegistry [SomeTool weatherTool, SomeTool searchTool]) defaultReActConfig
```

The loop alternates *thought → action → observation* until the model finishes or a bound is
hit, then extracts the typed answer; malformed tool arguments become a typed `ToolError`
observation the model can recover from, never a crash. `reactWithTrajectory` exposes the
recorded steps for evaluation.

### 8. Caching, tracing, and deterministic replay

Caching, tracing, and replay are each an `interpose` over the same `LLM` effect, so you opt
into them by stacking interpreters:

```haskell
(result, tree) <-
  runEff . runErrorNoCallStack @ShikumiError . runTrace . cachedLLM . tracedLLM
    . runLLMResilient cfg
    $ runProgram summarize article

renderTree tree              -- a nested span outline with timings & token usage
writeTraceFile "run.json" tree
```

The cache key is a BLAKE3 digest over the canonical request, so identical calls are served
from the cache — in-memory by default, or persisted across runs by swapping in the SQLite,
Redis, or Postgres backend (same `Cache` effect, different interpreter). Stored traces let
you **replay** an entire run deterministically
via `runLLMReplay` (fail-closed: an unrecorded request is an error, never a network call) —
and the `shikumi` CLI exposes `eval`, `trace`, `optimize`, and `replay` over the same
machinery.

---

## The CLI

A shikumi `Program i o` is a typed Haskell *value*, so the CLI is a **library of subcommand
builders** you wire around your own programs in a few lines — the bundled `shikumi`
executable is exactly that `main`:

```haskell
main :: IO ()
main = cliMain exampleRegistry   -- register your typed programs, datasets, metrics
```

Four subcommands surface the framework, all runnable **offline** (a deterministic in-process
stub LM; no API key, no network):

```bash
shikumi eval     --program sentiment                       # → a Report table
shikumi trace    sentiment --store-dir .shikumi            # → a nested span tree
shikumi optimize --program sentiment --optimizer bootstrap-fewshot --out p.json
shikumi replay   sentiment --store-dir .shikumi            # → identical output, 0 provider calls
```

---

## How it fits together

```
        ┌─────────────────────────────────────────────┐
        │  shikumi                                      │
        │                                               │
        │   Program i o   (GADT deep embedding)         │  ← run / rewrite / serialize
        │   Signature i o + Generic-derived schema      │  ← records in, records out
        │   Adapter (native | fallback | XML opt-in)    │
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

The framework was built as twelve ExecPlans across five phases (see
[`docs/masterplans/1-shikumi-typed-lm-programming-framework.md`](docs/masterplans/1-shikumi-typed-lm-programming-framework.md)).
All twelve are delivered; `cabal test all` is green across every package, hermetically.
Since then, EP-6's persistent cache backends (SQLite, Redis, Postgres) landed, and an owned
clock effect (`Shikumi.Effect.Time`) was added as foundational plumbing. MasterPlan 4
([richer I/O & multimodal](docs/masterplans/4-shikumi-richer-io-and-multimodal.md)) then widened
the I/O surface: multimodal `Image` input fields, program-level streaming (`streamProgram`), the
XML adapter and declarative field constraints, and the `programOfThought` / `codeAct`
code-execution modules.

| Area | Package | Status |
|---|---|---|
| **Runtime substrate** — `LLM` effect over baikai, `ShikumiError`, retries / rate-limiting / budget | `shikumi` | ✅ Done |
| **Clock effect** — owned `Time` effect (wall + monotonic clock); callers need only `Time :> es`, not `IOE` | `shikumi` | ✅ Done |
| **Native structured output** — `response_format` / `output_config` (upstreamed to baikai) | *baikai* | ✅ Done |
| **Signatures & structured I/O** — Generic-derived schema, total decode, the `Adapter` seam (native / prompt-fallback / XML) | `shikumi` | ✅ Done |
| **Declarative field constraints** — `Constrained '[…]` (`MinLen`/`MaxLen`/`MinVal`/`MaxVal`/`EnumOneOf`) flow into both the JSON schema and the post-decode validator | `shikumi` | ✅ Done |
| **Multimodal input** — typed `Image` input fields lower to baikai's native inline image block (`UserImage`); image-only today, audio/document upstream-gated | `shikumi` (`Shikumi.Multimodal`) | ✅ Done |
| **Typed program core** — `Program i o` GADT, `runProgram`, `predict`, `chainOfThought`, `twoStep`, parameter traversal & serialization | `shikumi` | ✅ Done |
| **Combinators** — `>>>`, `mapP`, `parallel2`, `retry`, `validate`, `majorityVote`, `ensemble` | `shikumi` | ✅ Done |
| **Program-level streaming** — `streamProgram` surfaces field chunks + status messages via a per-event callback, still returning the typed `o` | `shikumi` (`Shikumi.Stream`) | ✅ Done |
| **Self-refinement** — `bestOfN`, `refine`, `multiChainComparison` over a `Reward` | `shikumi` (`Shikumi.Refine`) | ✅ Done |
| **Caching** — content-addressed key, `Cache` effect, in-memory + persistent backends | `shikumi-cache`, `-redis`, `-postgres` | ✅ Done — in-memory & SQLite (`shikumi-cache`), Redis, Postgres |
| **Hierarchical tracing, OTel, deterministic replay** | `shikumi-trace`(`-otel`) | ✅ Done |
| **Evaluation** — `Dataset` / `Metric` / `evaluate` / `Report` | `shikumi-eval` | ✅ Done |
| **Compiler** — zero-shot / few-shot / CoT / RAG | `shikumi-compile` | ✅ Done |
| **Optimizer** — demo selection, bootstrap few-shot, KNN few-shot, bootstrap random search, instruction search, COPRO, MIPROv2, GEPA, ensemble search | `shikumi-optimize` | ✅ Done — DSPy parity |
| **Typed tools + ReAct agents** | `shikumi-tools` | ✅ Done |
| **Code-execution modules** — `programOfThought` / `codeAct`: model writes code, a hermetic sandbox runs it, the result feeds back into a typed answer (real subprocess sandbox gated/off-CI) | `shikumi-tools` (`Shikumi.CodeExec`) | ✅ Done — hermetic |
| **Ambient model routing** — pick a real model by name; live native `responseFormat` + per-sample temperature | `shikumi` (`Shikumi.Routing`) | ✅ Done |
| **Embeddings backend** — OpenAI-compatible `/v1/embeddings`; `semanticSimilarity` runs end-to-end | *baikai*, `shikumi-eval` | ✅ Done |
| **Node-correlated tracing** — `runProgramTraced`, `NodePath` per LM-call span, per-node feedback channel | `shikumi-trace` | ✅ Done |
| **`shikumi` CLI** — `eval`, `trace`, `optimize`, `replay`, with live OTel export | `shikumi-cli` | ✅ Done |
| **Worked examples (実例)** — runnable, offline counterparts to every motivating example | `shikumi-jitsurei` | ✅ Done |

> Note: `runProgram` is model-agnostic — install an ambient model below the stack with
> `runRouting`/`routeLLM` (from `Shikumi.Routing`) and every `Predict` node dispatches against
> that named model, with the derived JSON schema enforced via `responseFormat` for
> native-capable providers and `MajorityVote`'s per-sample temperature applied on the wire. The
> offline CLI and tests drive runs through a deterministic stub LM instead. See
> [Effects & the runtime](docs/user/effects-and-runtime.md#ambient-model-routing).

---

## Building

Shikumi builds with **GHC 9.12.4** inside a Nix dev shell, and depends on local checkouts of
`baikai` and `baikai-effectful` (see `cabal.project`).

```bash
nix develop .#ghc9124
cabal build all
cabal test  all              # hermetic across every package; no network

# Try the CLI offline (no API key):
cabal run shikumi-cli:exe:shikumi -- eval --program sentiment

# Run the worked examples offline (no API key); list them with:
cabal run shikumi-jitsurei
cabal run jitsurei-predict        # …or any example from the table above

# Opt into the live provider smoke test:
SHIKUMI_LIVE=1 OPENAI_API_KEY=... cabal test shikumi
```

---

## License

BSD-3-Clause © Nadeem Bitar
