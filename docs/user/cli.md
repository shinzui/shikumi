# The CLI — under the covers

A shikumi `Program i o` is a typed Haskell *value*, so there is no generic "run any program"
binary — instead `shikumi-cli` is a **library of subcommand builders** you wire around *your
own* programs in a few lines. The bundled `shikumi` executable is exactly that `main`.

```haskell
main :: IO ()
main = cliMain exampleRegistry   -- register your typed programs, datasets, metrics
```

All five subcommands run **offline** by default — a deterministic in-process stub LM, no API
key, no network — which is what makes the CLI usable in CI and as a learning tool.

---

## The registry: bundling a task

The CLI dispatches on a name to a `Task`, an existential bundling everything needed to run,
evaluate, optimize, trace, and replay one program:

```haskell
data Task where
  Task :: (ToJSON i, ToJSON o)
       => Program i o                 -- the program
       -> Dataset i o                 -- a labeled dataset
       -> Metric o                    -- a metric
       -> i                           -- a canonical input (for trace/replay)
       -> (Context -> Response)       -- a deterministic offline stub responder
       -> Map Text (Optimizer i o)    -- named optimizers (e.g. "bootstrap-fewshot")
       -> Task

type Registry = Map Text Task

emptyRegistry :: Registry
register      :: Text -> Task -> Registry -> Registry
cliMain       :: Registry -> IO ()
```

Bundling all of a task's state under one existential keyed by name means the CLI needs only a
single `--program NAME` flag — no cross-type reunification of separate program/dataset/metric
maps. The shipped `exampleRegistry` (a tiny sentiment classifier) is the reference wiring; copy
its `Shikumi.Cli.Example` module to register your own.

---

## The subcommands

```bash
shikumi eval     --program sentiment                       # → a Report table
shikumi record   --program sentiment --store-dir .shikumi  # → writes .shikumi/sentiment.json
shikumi trace    sentiment --store-dir .shikumi            # → a nested span tree
shikumi optimize --program sentiment --optimizer bootstrap-fewshot --out p.json
shikumi replay   sentiment --store-dir .shikumi            # → identical output, 0 provider calls
```

| Subcommand | What it does | Built on |
|---|---|---|
| `eval` | Looks up the task, runs `evaluatePure` over its dataset, prints the `Report` via `renderReportText`. | [evaluation](./evaluation-and-optimization.md) |
| `trace` | Loads a stored trace JSON from the store dir and renders it via `renderTree`. | [tracing](./caching-tracing-replay.md#tracing) |
| `optimize` | Runs the named optimizer, serializes the resulting `CompiledProgram` to `--out`. | [optimization](./evaluation-and-optimization.md#optimization-shikumi-optimize) |
| `record` | Runs the program under the stub and persists the trace to the store dir. | tracing |
| `replay` | Loads a stored trace and re-runs via `runLLMReplay`, fail-closed with zero provider calls; checks the output matches. | [replay](./caching-tracing-replay.md#deterministic-replay) |

Global options: `--store-dir` (default `.shikumi`) and `--otel`.

Trace ids double as program names and are spliced into `--store-dir/<id>.json`, so `trace`,
`record`, and `replay` reject ids that are empty, `"."`, contain `/` or `\`, or contain `..`.
If a trace is missing, the error names the expected path and tells you to run `record` first.
If replay or the reference stub run fails, the command now reports which side errored instead
of collapsing both cases into a generic replay failure.

With `--otel`, `shikumi trace <id> --otel` also exports the loaded tree to a live OpenTelemetry
collector over OTLP/HTTP (in addition to printing it), then prints an
`Exported N spans via OTLP to <endpoint>` line. The endpoint comes from the standard OTel
environment variables (`OTEL_EXPORTER_OTLP_ENDPOINT`, default `http://localhost:4318`); each
LM-call span carries its model/provider/tokens/cost and — for traces produced by
`runProgramTraced` — its `shikumi.node_path`. With no collector reachable the spans are dropped
and the command still exits cleanly (the non-`--otel` output is byte-for-byte unchanged). See
[tracing → OpenTelemetry export](./caching-tracing-replay.md#opentelemetry-export).

---

## How "offline" is wired (`Shikumi.Cli.Runtime`)

The CLI discharges the `LLM` effect with a **pure responder function** instead of a provider:

```haskell
runStubLLM  :: (Context -> Response) -> Eff (LLM : es) a -> Eff es a
runStubEval :: (Context -> Response)
            -> Eff '[LLM, Concurrent, Error ShikumiError, Time, Prim, IOE] a
            -> IO (Either ShikumiError a)
```

`runStubLLM` answers every `Complete` call from `responder ctx` (ignoring `Stream`).
`runStubEval` discharges the full evaluation/optimization stack — note the row: `LLM`,
`Concurrent`, `Error ShikumiError`, `Time` (shikumi's clock effect, discharged via `runTime`),
`Prim` (the usage counters, discharged via `runPrim`), and `IOE` at the very bottom for the
real clock used by `runTime`. The stub LM itself is stateless and needs no `IOE`. This is the
same effect-stack discipline from
[Effects & the runtime](./effects-and-runtime.md) — the stub just swaps the bottom `LLM`
interpreter.

`replay` is special: it uses `runReplayProgram`, which drives the program purely from a stored
`TraceTree` via `runLLMReplay`, so it makes **zero** provider (or stub) calls and diverges
loudly if the trace is incomplete.

The same harness — the stub LM, the `markerResponse` / `mkTextResponse` /
`mkToolCallResponse` response builders, and the `systemContains` responder helper — is exposed
in [`Shikumi.Jitsurei.Stub`](../../shikumi-jitsurei/src/Shikumi/Jitsurei/Stub.hs) for the
worked examples and for your own offline tests.

---

## Building your own CLI

1. Define your programs, datasets, and metrics (the rest of this guide series).
2. Write a deterministic stub responder for offline runs (branch on `systemContains` if a
   pipeline has multiple stages).
3. Bundle each into a `Task` and `register` it under a name.
4. `main = cliMain myRegistry`.

You now have `eval` / `record` / `trace` / `optimize` / `replay` over your own typed programs,
runnable in CI with no credentials.
