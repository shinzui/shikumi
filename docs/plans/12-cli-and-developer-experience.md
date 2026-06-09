---
id: 12
slug: cli-and-developer-experience
title: "CLI and developer experience"
kind: exec-plan
created_at: 2026-06-08T02:44:17Z
intention: "intention_01ktjgkp10ef79vpwz1cmajek9"
master_plan: "docs/masterplans/1-shikumi-typed-lm-programming-framework.md"
---

# CLI and developer experience

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Shikumi (仕組み — "the mechanism behind how something works") is a Haskell framework for
building language-model (LM) programs as ordinary typed software. By the time this plan is
implemented, the rest of the framework already exists: a user can declare a typed
`Program i o` (a language-model program whose input `i` and output `o` are ordinary Haskell
record types), run it, cache and trace every call, evaluate it against a dataset with a
metric, and optimize it. What is still missing is the *user-facing command line*: a way to
drive those capabilities from a terminal rather than only from Haskell source. This plan
delivers that command line.

After this change, a developer building LM programs with shikumi gains a `shikumi`
executable exposing four subcommands, each of which surfaces a major framework capability:

- `shikumi eval` — run a program over a dataset with a metric and print a human-readable
  **Report** (a table of score, latency, token usage, cost, and per-example pass/fail).
- `shikumi trace` — render the **hierarchical trace tree** of a recorded run as a readable
  nested outline, so you can see which sub-call invoked which, with timings and token usage
  at each node.
- `shikumi optimize` — run an optimizer over a dataset and metric and **save the resulting
  compiled program** to a file on disk, so the improved program can be loaded and reused.
- `shikumi replay <trace-id>` — **deterministically re-run a stored trace** and show that
  the output is byte-for-byte identical to the original recorded run, with no network calls.

The single most important design problem this plan solves is a consequence of Haskell being
a *statically compiled* language. In DSPy (the Python framework shikumi is inspired by) a
CLI can `import` a user's program by module path at runtime, because Python resolves names
dynamically. Haskell cannot: a `Program Article Summary` is a typed Haskell *value*, not a
config file, and there is no portable way for a precompiled `shikumi` binary to load an
arbitrary user's typed program, dataset, and metric at runtime and have them typecheck. So
the realistic shape of "the shikumi CLI" is not a single prebuilt binary that magically
finds your programs. Instead, this plan ships a **library of reusable subcommand builders**
(`shikumi-cli`) plus a **small example executable** (also named `shikumi`, built from a
bundled example) that wires those builders together around concrete typed programs. A user
who wants the CLI for *their own* programs writes a tiny `main` (a dozen lines) that
registers their programs, datasets, and metrics and calls the builders — exactly the
pattern the bundled example demonstrates. This is the standard Haskell answer to "a CLI over
user-supplied typed values" (it is how test frameworks like `tasty` and benchmark
frameworks like `criterion` work: you write a `main` that hands the framework your typed
values, and the framework provides the argument parsing, dispatch, and rendering). The
"Decision Log" records why this beats the alternatives.

You can see it working at the end of this plan by building the bundled example executable
and running all four subcommands offline (no API key, no network) against a tiny bundled
program and dataset. The transcripts in "Validation and Acceptance" show exactly what each
command prints: a Report table for `eval`, a nested tree for `trace`, a saved
compiled-program file for `optimize`, and identical output for `replay`.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M0: `shikumi-cli` package scaffolded; builds; depends on sibling packages
      (`shikumi`, `shikumi-eval`, `shikumi-compile`, `shikumi-optimize`, `shikumi-trace`)
      + `optparse-applicative` (2026-06-09). Added to `cabal.project`.
- [x] M1: CLI skeleton — the `shikumi` executable parses `eval`/`trace`/`optimize`/`replay`
      (plus a DX `record` helper) and `--help`/global `--store-dir`/`--otel`, dispatching via
      `Shikumi.Cli.dispatch`. (Per-subcommand handlers were implemented directly rather than
      as separate stub then real, since the real handlers were small.)
- [x] M2: `Registry` of existential `Task`s (bundling program + dataset + metric + canonical
      input + offline stub responder + named optimizers, one `i`/`o` per task — avoids the
      cross-existential `Typeable` reunification the sketch implied; see Decision Log); the
      offline runtime (`Shikumi.Cli.Runtime`: `runStubEval`/`runStubProgram`/
      `runReplayProgram`/`recordTrace`); and the bundled `exampleRegistry` (the `sentiment`
      task). A unit test asserts the example runs.
- [x] M3: `eval` evaluates the named task offline and prints EP-8's `renderReportText`
      (reused, not reinvented). Bundled example → `score=0.5000`, `pass=2/4`.
- [x] M4: `trace` loads a stored trace (`readTraceFile`) and renders it with EP-7's
      `renderTree` (reused). Bundled example → a program span over an `llm-call` leaf.
- [x] M5: `optimize` runs the named optimizer and writes EP-9's `encodeCompiled` JSON to
      `--out`. (`encodeCompiled`/`decodeCompiledOnto`, not the sketch's `saveCompiled`/
      `loadCompiled` which EP-9 never shipped.) Bundled example → a demos-bearing JSON file.
- [x] M6: `replay` re-runs the program purely from the trace via EP-7's fail-closed
      `runLLMReplay`, and confirms the output is identical to a fresh stub run with
      `provider calls: 0`.
- [x] M7: Hermetic acceptance tests over the four capabilities (`shikumi-cli-test`, 5 tests):
      deterministic Report assertions, trace span + on-disk round-trip, optimize-saves-demos,
      and replay-identity. (Used direct HUnit transcript assertions rather than `tasty-golden`
      to avoid a new dep and the non-determinism of wall-clock trace timings — see Surprises.)
      The `--otel` flag is accepted and the stack builds with it; wiring EP-7's live OTel sink
      is deferred (offline acceptance does not exercise a collector — see Decision Log).
- [x] M8: All four behaviors reproduced offline from the bundled example with no network; a
      committed trace fixture under `shikumi-cli/example/fixture/sentiment.json` (generated
      offline via `record`, not via a live API key) makes `trace`/`replay` work from a clean
      checkout. `cabal test all` green across every package.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **The sibling contracts drifted from the sketch; the behavior held.** Every sibling shipped
  with names/rows different from the Context section's pre-authored contract: `evaluate`/
  `optimize` carry `(LLM, Concurrent, Error ShikumiError, IOE)` (not just `LLM`); EP-9 ships
  `encodeCompiled`/`decodeCompiledOnto` (not `saveCompiled`/`loadCompiled`); EP-7 ships
  `readTraceFile`/`writeTraceFile`/`replayIndex`/`runLLMReplay` + `renderTree` (not
  `loadTrace`/`listTraces`/`runReplay`); EP-8 ships `renderReportText` (so the CLI reuses it
  rather than writing `renderReport`); `Metric o = o -> Prediction o -> Score` (not
  `o -> o -> Double`). All call sites were adjusted; the four behaviors are unchanged. The
  plan anticipated exactly this ("adjust the call sites and record the deviation").
- **EP-6's persistent cache was deferred, so the sketch's on-disk cache fixture does not
  exist.** Offline determinism instead comes from a deterministic in-process /stub/ LM (the
  framework's standard hermetic pattern, mirroring `Shikumi.Trace.Demo`'s `runStubLLM`):
  `eval`/`optimize` run against the stub; `record` captures a real `TraceTree` from a stub run
  and persists it; `replay` re-runs purely from that trace. No network is touched even to
  /record/ the fixture — strictly better than the sketch's "record with an API key" M8 step.
- **`cabal list-bin shikumi` is ambiguous** — it resolves to the core package's `shikumi-test`
  rather than the CLI executable. Use the fully-qualified `cabal list-bin shikumi-cli:exe:shikumi`
  (or `cabal run shikumi-cli:exe:shikumi`). Evidence: the first acceptance run printed the
  tasty help screen instead of the CLI help.
- **Trace rendering embeds wall-clock durations, so the trace transcript is not byte-stable.**
  `renderTree` prints e.g. `8ms`/`6ms`, which vary per run. The golden-style test therefore
  asserts the deterministic fragments (span names `sentiment`/`llm-call`, token counts
  `in=18 out=5`) and a write→read→render round-trip identity, rather than an exact transcript
  match. Token counts and scores ARE deterministic (read from the stub response's fixed usage).
- **`Task`'s existential cannot use record selectors.** A GADT record whose fields mention the
  existential `i`/`o` cannot generate usable selectors, so `Task` is a positional existential
  matched as `Task prog ds metric input responder opts`; handlers bring the hidden types into
  scope by pattern-matching, never by a selector.


## Decision Log

Record every decision made while working on the plan.

- Decision: Ship the CLI as a **library of subcommand builders (`shikumi-cli`) plus a small
  bundled example executable**, rather than as a single standalone binary that loads
  user programs at runtime.
  Rationale: A shikumi `Program i o` is a typed Haskell value, not a config file. A
  precompiled binary cannot load an arbitrary user's typed program/dataset/metric at runtime
  and have it typecheck — Haskell resolves names at compile time. The two theoretical
  escape hatches are both worse: (a) a *plugin* approach using the GHC runtime linker
  (`hint`/`plugins`) to compile-and-load user source at runtime is fragile (must match the
  exact GHC + package set, slow, and a frequent source of segfaults); (b) a *config DSL*
  that re-expresses programs as data (YAML/JSON) throws away the static typing that is
  shikumi's entire reason to exist. The library-of-builders pattern is how mature Haskell
  tooling (`tasty`, `criterion`, `hspec`) exposes a CLI over user-supplied typed values:
  the user writes a tiny `main` that hands the framework typed values and the framework
  owns parsing/dispatch/rendering. The bundled example *is* that `main`, demonstrating all
  four commands end-to-end and doubling as the acceptance fixture.
  Date: 2026-06-07.
- Decision: Programs/datasets/metrics are supplied to the CLI through a typed **`Registry`**
  keyed by `Text` names, with each entry hiding its `i`/`o` behind an existential wrapper
  that carries the evidence (JSON codecs, schema) needed to run, evaluate, and serialize it.
  Rationale: Subcommands take a program *name* on the command line (a `Text`), but programs
  have heterogeneous types. An existential wrapper (`SomeEntry`) lets the CLI store
  differently-typed entries in one `Map Text` and dispatch by name while preserving enough
  per-entry capability (serialize, run, score) to do the job. This keeps the user's `main`
  to a handful of `register` calls.
  Date: 2026-06-07.
- Decision: Serialization format for saved compiled programs is **JSON** (via the
  serializer owned by `docs/plans/9-compiler-layer.md`), written to a user-named `.json`
  file; trace files are the JSON trace store owned by
  `docs/plans/7-hierarchical-tracing-observability-and-replay.md`.
  Rationale: JSON is human-inspectable (a DX win — you can open a saved compiled program and
  read its chosen demos/instructions), is already the on-disk format those sibling plans
  define, and avoids inventing a second format. The CLI does not define new serialization;
  it calls the siblings' load/save functions.
  Date: 2026-06-07.
- Decision: All acceptance runs are **offline**, driven by the cache
  (`docs/plans/6-caching-subsystem.md`) and replay engine
  (`docs/plans/7-hierarchical-tracing-observability-and-replay.md`), with a bundled
  prerecorded cache/trace fixture committed to the repo.
  Rationale: CLI acceptance must be deterministic and runnable in CI with no API key. The
  framework already provides content-addressed caching and deterministic replay; the CLI's
  job is to exercise them, not to make live calls. A committed fixture makes every transcript
  reproducible from a clean checkout.
  Date: 2026-06-07.
- Decision: Use **`optparse-applicative`** for argument parsing.
  Rationale: It is the de-facto Haskell CLI library (applicative-style declarative parsers,
  auto-generated `--help`, subcommands via `hsubparser`/`command`), and is registered in the
  environment (`mori registry show pcapriotti/optparse-applicative`).
  Date: 2026-06-07.
- Decision: **Bundle each task's program + dataset + metric + optimizers + offline stub into
  one existential `Task`, keyed by name**, and have subcommands take a single `--program NAME`
  rather than separate `--dataset`/`--metric` flags. Rationale: the sketch's three independent
  existential maps (programs/datasets/metrics) would force a runtime `Typeable` reunification
  to prove a program, dataset, and metric share `i`/`o` before `evaluate` could be called.
  Bundling makes a name resolve to one fully-typed unit, so dispatch is type-safe with no
  reflection. The bundled example registers exactly one task, matching the plan's single-program
  acceptance. Date: 2026-06-09.
- Decision: **Drive offline runs with a deterministic in-process stub LM, not a committed
  cache fixture.** EP-6 shipped only the in-memory cache (persistent backends deferred), so the
  sketch's disk-cache offline story has no implementation. The stub (the framework's hermetic
  pattern) makes `eval`/`optimize` deterministic with zero network, and the committed trace
  fixture is itself generated offline via `record` (the stub), so even fixture regeneration
  needs no API key. Date: 2026-06-09.
- Decision: **Acceptance is HUnit transcript assertions over the four capabilities, not
  `tasty-golden` files.** Rationale: avoids adding a dependency, and trace timings are
  wall-clock (non-deterministic), so the robust check asserts the deterministic fragments plus
  a store round-trip rather than an exact-byte golden. The `--otel` flag is accepted (the stack
  builds and runs with it) but the live EP-7 OTel sink is not installed in the offline runs;
  live export needs a collector and is out of scope for hermetic acceptance. Date: 2026-06-09.
- Decision: **Reuse EP-8's `renderReportText` and EP-7's `renderTree` verbatim** rather than
  writing the sketch's `renderReport`/`renderTraceTree`. Rationale: the siblings already ship
  deterministic, tested renderers; reusing them avoids a second format to maintain and keeps
  the CLI a thin driver. Date: 2026-06-09.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

**Delivered (2026-06-09).** The `shikumi-cli` package ships a `shikumi` executable with the
four headline subcommands — `eval`, `trace`, `optimize`, `replay` — plus a `record` DX helper
and a global `--store-dir`/`--otel`. All run offline against the bundled `sentiment` example
with zero network: `eval` prints a Report (`score=0.5000`, `pass=2/4`), `trace` renders a
program→llm-call span tree, `optimize` writes a demos-bearing compiled-program JSON, and
`replay` reproduces the recorded output with `provider calls: 0`. `cabal test shikumi-cli-test`
is green (5 hermetic tests) and `cabal test all` is green across every package. The
library-of-builders shape held up exactly as designed: the bundled `Shikumi.Cli.Example` *is*
the user's `main` (`cliMain exampleRegistry`), a handful of typed registrations.

**Against the original purpose.** The end state the MasterPlan named is reached — a developer
drives eval/trace/optimize/replay from a terminal over typed programs. The one honest gap vs.
the sketch: offline determinism comes from an in-process stub LM rather than a persistent cache
fixture (EP-6 deferred its persistent backends), and `--otel` is accepted but its live sink is
not wired (needs a collector). Neither weakens the four behaviors; both are documented in the
Decision Log and are clean future work. The CLI reuses the siblings' renderers/serializers
verbatim, so it stays a thin, faithful driver over the framework rather than a second source of
truth.


## Context and Orientation

This section assumes you know nothing about the repository. Read it fully before editing.

The repository root is `/Users/shinzui/Keikaku/bokuno/shikumi`. It is a multi-package
Haskell project (a "Cabal project": several library packages and executables described by
`.cabal` files and tied together by a top-level `cabal.project` file). You build everything
with `cabal build all` from the repo root and run tests with `cabal test all`. The Haskell
language edition is `GHC2024` (a bundle of modern language extensions enabled by default).

Shikumi is layered on top of **baikai** (`/Users/shinzui/Keikaku/bokuno/baikai`), a separate
published Haskell library that owns the *transport layer*: it talks to LM providers (Claude,
OpenAI, DeepSeek, OpenRouter, any OpenAI-compatible host), exposes a `completeRequest`
function in `IO`, a generated model catalog, typed messages, and token/cost accounting.
Shikumi adds everything above the wire. You do not need to touch baikai for this plan.

This plan is the last one in the framework. It depends on several sibling plans. **At the
time this plan is authored, those siblings are skeleton files; their full content is being
written in parallel.** Therefore this section embeds, in plain language, the exact pieces of
those plans this CLI consumes. Reference the sibling files by path for the authoritative
definitions, but treat the descriptions here as the contract this plan codes against:

- **`docs/plans/4-typed-program-representation-and-core-modules.md` (EP-4)** owns
  `Program i o`. A `Program i o` is a typed value describing a language-model program from
  input record type `i` to output record type `o`. It is interpreted by
  `runProgram :: (LLM :> es) => Program i o -> i -> Eff es o`, where `Eff es` is an
  `effectful` computation (a monadic action carrying a type-level list `es` of *effects* —
  capabilities like LM access — that it is allowed to use, and `LLM :> es` means "the `LLM`
  effect is available in `es`"). The CLI never *constructs* programs; the user supplies them
  and the CLI runs them via `runProgram`.

- **`docs/plans/1-shikumi-runtime-substrate-and-llm-effect-over-baikai.md` (EP-1)** owns the
  `LLM` effect and the shikumi error type `ShikumiError`. `LLM` is the `effectful` effect
  that performs one model call. The CLI builds an `Eff` *effect stack* — concretely a
  function that takes an `Eff '[LLM, Cache, Trace, Error ShikumiError, IOE] a` and runs it
  down to `IO (Either ShikumiError a)` — by stacking the interpreters from EP-1/6/7. (`IOE`
  is `effectful`'s effect for "may perform arbitrary `IO`".)

- **`docs/plans/6-caching-subsystem.md` (EP-6)** owns the `Cache` effect and its
  interpreters, including a content-addressed cache that keys each request on
  (model + prompt + temperature + system + tools + schema). The CLI uses the cache so that
  offline runs hit recorded responses instead of the network.

- **`docs/plans/7-hierarchical-tracing-observability-and-replay.md` (EP-7)** owns the
  `Trace` effect, the hierarchical **trace tree**, the on-disk trace store, and the replay
  engine. A trace tree is a tree of *spans* (a span is one named unit of work with a start
  time, end time, and attributes such as token usage); the root span is the whole program
  run and children are nested sub-calls. EP-7 exposes (treated as the contract here):
  `data TraceTree` with a root span and children; `data Span` with fields `spanId :: Text`,
  `name :: Text`, `startNs :: Integer`, `endNs :: Integer`, `attributes :: Map Text Text`,
  and `children :: [Span]`; functions `loadTrace :: FilePath -> Text -> IO (Maybe TraceTree)`
  (load a trace by its trace-id from a store directory), `listTraces :: FilePath -> IO [Text]`,
  and a replay interpreter `runReplay :: TraceTree -> Eff (LLM : es) a -> Eff es a` that
  answers each LM call from the recorded trace instead of the network. EP-7 also provides an
  OpenTelemetry export sink the CLI exposes as a flag.

- **`docs/plans/8-evaluation-framework.md` (EP-8)** owns the evaluation data model:
  `data Dataset i o` (a list of typed `Example i o`, each holding a typed input and the
  expected/labelled output), `type Metric o` (a function scoring a predicted `o` against the
  expected `o`, conventionally `Metric o = o -> o -> Double` returning a score in `[0,1]`),
  and `data Report` summarizing an evaluation (total examples, mean score, total/mean
  latency, total token usage, total cost, and a list of per-example results with pass/fail).
  EP-8 exposes `evaluate :: (LLM :> es) => Program i o -> Dataset i o -> Metric o -> Eff es Report`.
  The CLI renders a `Report` as a text table.

- **`docs/plans/10-optimizer-framework.md` (EP-10)** owns optimizers. An optimizer is a
  search procedure that, given a program, a dataset, and a metric, produces an improved
  compiled program. EP-10 exposes (contract here)
  `data Optimizer` (a named optimization strategy, e.g. bootstrap few-shot) and
  `optimize :: (LLM :> es) => Optimizer -> Program i o -> Dataset i o -> Metric o -> Eff es (CompiledProgram i o)`.
  The CLI exposes the optimizer by name and saves the result.

- **`docs/plans/9-compiler-layer.md` (EP-9)** owns `CompiledProgram i o` — a `Program i o`
  together with a frozen set of per-node parameters (chosen demonstrations and instructions)
  — and its JSON serialization. EP-9 exposes (contract here)
  `saveCompiled :: ToJSON ... => FilePath -> CompiledProgram i o -> IO ()` and
  `loadCompiled :: FromJSON ... => FilePath -> IO (Either String (CompiledProgram i o))`,
  plus `runCompiled :: (LLM :> es) => CompiledProgram i o -> i -> Eff es o`.

- **`docs/plans/11-typed-tools-and-react-agents.md` (EP-11)** owns typed tools and the ReAct
  agent loop. This is a *soft* dependency: the bundled example optionally includes a
  ReAct-based program to demonstrate agents in the CLI, but the four core subcommands work
  without it. If EP-11 is not yet available when this plan is implemented, omit the agent
  example and proceed; the acceptance criteria do not require it.

The new code for this plan lives in a new package **`shikumi-cli`** under
`shikumi-cli/` at the repo root, mirroring the layout of the other `shikumi-*` packages.
Its module home is `Shikumi.Cli.*`, and it provides one executable named `shikumi`.

Two terms used throughout: an **existential wrapper** is a data constructor that hides a
type variable so values of different types can be stored together (here, programs of
different `i`/`o`); a **golden test** is a test that compares a program's output against a
committed "golden" reference file and fails if they differ (used here to lock the CLI's
rendered transcripts).


## Plan of Work

The work proceeds in nine milestones (M0–M8). Each is independently verifiable: after each,
you can run a concrete command and observe a specific result. The early milestones build the
package and the dispatch skeleton; the middle milestones implement one subcommand each
against real framework calls; the last milestones add the DX features and the full
end-to-end acceptance. Throughout, all model interaction is offline (cache + replay) so the
acceptance is deterministic and needs no API key.

### Milestone M0 — Scaffold the `shikumi-cli` package

Scope: create the package so the rest of the framework can be wired in. At the end, a new
`shikumi-cli/` directory exists with a `shikumi-cli.cabal` that declares one library and one
executable `shikumi`, the top-level `cabal.project` includes it, and `cabal build
shikumi-cli` succeeds with an empty-but-valid module.

Create `shikumi-cli/shikumi-cli.cabal` declaring a library exposing `Shikumi.Cli` (initially
just a placeholder value) and an executable `shikumi` whose `main-is` is `app/Main.hs`. The
library `build-depends` must include `base`, `text`, `containers`, `aeson`,
`optparse-applicative`, `effectful`, and the sibling shikumi packages it consumes:
`shikumi` (core, for `Program`/`runProgram`/`LLM`), `shikumi-cache`, `shikumi-trace`,
`shikumi-eval`, `shikumi-compile`, and `shikumi-optimize`. (Depend on `shikumi-tools` only
if EP-11 is available; otherwise leave it out — see M2.) Add the package to
`cabal.project`'s `packages:` stanza.

Acceptance: `cabal build shikumi-cli` succeeds. `cabal run shikumi -- --help` prints a
usage line (even if it lists no real subcommands yet). The exact transcript appears under
"Concrete Steps".

### Milestone M1 — Subcommand dispatch skeleton

Scope: define the top-level argument parser with the four subcommands and global options,
dispatching to stub handlers that simply echo their parsed arguments. At the end,
`shikumi eval --help`, `shikumi trace --help`, `shikumi optimize --help`, and
`shikumi replay --help` each print a correct, distinct help screen, and invoking each
subcommand with valid arguments prints a one-line "would run …" stub.

In `shikumi-cli/src/Shikumi/Cli/Options.hs` define the parsed-command algebra and its
parser. The command type is:

```haskell
data Command
  = CmdEval EvalOpts
  | CmdTrace TraceOpts
  | CmdOptimize OptimizeOpts
  | CmdReplay ReplayOpts

data GlobalOpts = GlobalOpts
  { storeDir :: FilePath   -- directory holding the cache + trace store (default ".shikumi")
  , otel     :: Bool       -- emit OpenTelemetry spans for this run (default False)
  }

data EvalOpts = EvalOpts
  { evalProgram :: Text     -- program name to look up in the Registry
  , evalDataset :: Text     -- dataset name
  , evalMetric  :: Text     -- metric name
  }

data TraceOpts = TraceOpts
  { traceId :: Text }       -- which stored trace to render

data OptimizeOpts = OptimizeOpts
  { optProgram   :: Text
  , optDataset   :: Text
  , optMetric    :: Text
  , optOptimizer :: Text    -- optimizer name (e.g. "bootstrap-fewshot")
  , optOut       :: FilePath -- where to save the compiled program (.json)
  }

data ReplayOpts = ReplayOpts
  { replayId :: Text }      -- trace-id to replay
```

Build the parser with `optparse-applicative`: a `Parser GlobalOpts` (using `strOption`,
`switch`), a `Parser Command` built from `hsubparser` over four `command "eval" …` /
`command "trace" …` / `command "optimize" …` / `command "replay" …` entries (each wrapped in
`info` with a `progDesc`), and a top-level `info (… <**> helper) (fullDesc <> progDesc …
<> header "shikumi — typed LM program CLI")`. Each subcommand parser uses `strOption` /
`argument str` for its fields (for example, `replay` takes the trace-id as a positional
`argument str (metavar "TRACE-ID")`).

In `shikumi-cli/app/Main.hs`, `main = customExecParser (prefs showHelpOnEmpty) opts >>=
dispatch`, where `dispatch` pattern-matches the `Command` and, for now, calls stub handlers
in `Shikumi/Cli/Run.hs` that print, e.g., `"[stub] eval program=… dataset=… metric=…"`.

Acceptance: the four `--help` screens render distinctly and correctly; each subcommand with
valid args prints its stub line. Transcript under "Concrete Steps".

### Milestone M2 — The `Registry`, offline interpreter, and bundled example values

Scope: define how typed programs/datasets/metrics reach the CLI, and the offline effect
stack the subcommands run in. At the end, a bundled example program, dataset, and metric are
registered, and a shared `runOffline` helper exists that runs an `Eff` action against the
cache/replay store with no network.

In `shikumi-cli/src/Shikumi/Cli/Registry.hs` define the registry. Because programs have
heterogeneous `i`/`o`, each entry hides its types behind an existential wrapper that carries
the evidence needed to run, evaluate, serialize, and optimize it:

```haskell
data ProgramEntry where
  ProgramEntry ::
    ( ToJSON o, FromJSON o, FromJSON i, ToJSON i ) =>
    { peProgram :: Program i o
    , peDecodeInput :: Value -> Either String i   -- parse a dataset row's input
    } -> ProgramEntry

data DatasetEntry where
  DatasetEntry :: { deDataset :: Dataset i o, deProxy :: Proxy (i, o) } -> DatasetEntry

data MetricEntry where
  MetricEntry :: { meMetric :: Metric o } -> MetricEntry

data Registry = Registry
  { programs   :: Map Text ProgramEntry
  , datasets   :: Map Text DatasetEntry
  , metrics    :: Map Text MetricEntry
  , optimizers :: Map Text Optimizer
  }

emptyRegistry :: Registry
registerProgram :: Text -> ProgramEntry -> Registry -> Registry
registerDataset :: Text -> DatasetEntry -> Registry -> Registry
registerMetric  :: Text -> MetricEntry  -> Registry -> Registry
registerOptimizer :: Text -> Optimizer  -> Registry -> Registry
```

The precise constraints carried by each existential are whatever the sibling plans require
for run/eval/serialize; if EP-8/EP-9/EP-10 expose a single capability typeclass for an
entry, use it instead of enumerating constraints. The intent is fixed: an entry must be
runnable, evaluable, and serializable by name without the caller knowing its `i`/`o`.

In `shikumi-cli/src/Shikumi/Cli/Runtime.hs` define the offline interpreter:

```haskell
runOffline
  :: GlobalOpts
  -> Eff '[LLM, Cache, Trace, Error ShikumiError, IOE] a
  -> IO (Either ShikumiError a)
```

`runOffline` stacks the interpreters from EP-1/6/7: it opens the cache backend rooted at
`storeDir` (EP-6), installs the trace interpreter that writes the trace store under
`storeDir` (EP-7), and — crucially for offline determinism — installs the LM interpreter in
*cache-only / replay* mode so that a missing cache entry is an error rather than a network
call. Use exactly the interpreter-construction functions those plans export; this plan does
not reimplement caching or tracing.

In `shikumi-cli/example/Shikumi/Cli/Example.hs` define the bundled fixtures and the
`Registry` that the example `main` uses. Define a tiny self-contained program — e.g.
`sentiment :: Program ReviewInput SentimentOutput` where `ReviewInput { reviewText :: Text }`
and `SentimentOutput { label :: Text }` — built with `predict` from the core package; a
`Dataset ReviewInput SentimentOutput` of three or four labelled examples; and an exact-match
`Metric SentimentOutput`. Register them under the names `"sentiment"`, `"reviews"`, and
`"exact"`. Register one optimizer (e.g. `"bootstrap-fewshot"`) from EP-10. Commit a
prerecorded cache + trace fixture (see M8) under `shikumi-cli/example/fixture/` so the
example runs offline.

Acceptance: `cabal build shikumi-cli` still succeeds with the registry and example wired in;
a small unit test (`cabal test shikumi-cli`) asserts `Map.keys (programs exampleRegistry) ==
["sentiment"]` and similar, proving the registry is populated. No network is touched.

### Milestone M3 — `eval`: render a Report table

Scope: make `shikumi eval` actually evaluate the named program over the named dataset with
the named metric, offline, and print a Report table. At the end, running the bundled example
`eval` prints a deterministic table.

In `shikumi-cli/src/Shikumi/Cli/Run.hs`, implement the real `eval` handler. It receives the
`Registry`, the `GlobalOpts`, and the `EvalOpts`; looks up the program/dataset/metric by
name (erroring with a clear message listing available names if a name is missing); then runs
`evaluate program dataset metric` (EP-8) inside `runOffline`. Because the registry entry,
dataset entry, and metric entry are independent existentials, you must reunify their hidden
types: provide a small helper that, given a `ProgramEntry`, `DatasetEntry`, and
`MetricEntry`, checks (via the entry's `Proxy`/`Typeable` evidence) that they agree on `i`
and `o` and otherwise returns a typed "type mismatch between program X and dataset Y" error.
This runtime type-check is the price of name-based dispatch over heterogeneous typed values;
state it plainly in the error message.

Add `shikumi-cli/src/Shikumi/Cli/Render.hs` with `renderReport :: Report -> Text` producing
a fixed-width table: a header line (Examples, Mean Score, Mean Latency, Total Tokens, Total
Cost) and one row per example with its index, pass/fail mark, and per-example score, followed
by the aggregate summary. Keep the layout deterministic (no timestamps in the rendered output)
so it is golden-testable.

Acceptance: `cabal run shikumi -- eval --program sentiment --dataset reviews --metric exact
--store-dir shikumi-cli/example/fixture` prints the Report table shown in "Validation and
Acceptance". A clear error is printed (and a non-zero exit code returned) when a name is
unknown.

### Milestone M4 — `trace`: render the hierarchical trace tree

Scope: make `shikumi trace <trace-id>` load a stored trace and print it as a nested outline.
At the end, running it against the bundled fixture prints a readable tree with one line per
span, indented by depth, showing span name, duration, and token usage.

In `Shikumi/Cli/Render.hs` add `renderTraceTree :: TraceTree -> Text`. Walk the tree
depth-first; for each `Span`, emit a line `"<indent>• <name>  (<durationMs> ms"` plus, when
the span has token attributes, `", <n> tok"`, then `")"`, where `<indent>` is two spaces per
depth level. Compute `durationMs` from `endNs - startNs`. Pull token counts from
`attributes` (the key shikumi uses for token usage, per EP-7). Keep the format stable for
golden tests.

In `Shikumi/Cli/Run.hs`, implement the `trace` handler: call `loadTrace storeDir traceId`
(EP-7); on `Nothing`, print `"No trace found with id: <id>"` plus the output of
`listTraces storeDir` so the user can discover valid ids, and exit non-zero; on `Just tree`,
print `renderTraceTree tree`.

Acceptance: `cabal run shikumi -- trace <fixture-trace-id> --store-dir
shikumi-cli/example/fixture` prints the nested tree shown in "Validation and Acceptance".

### Milestone M5 — `optimize`: run an optimizer and save a CompiledProgram

Scope: make `shikumi optimize` run the named optimizer over the named dataset/metric and
write the resulting compiled program to the `--out` file. At the end, running it against the
bundled fixture produces a `.json` file on disk whose contents are stable and inspectable.

In `Shikumi/Cli/Run.hs`, implement the `optimize` handler: look up program/dataset/metric/
optimizer by name (same reunification + error handling as `eval`); run
`optimize optimizer program dataset metric` (EP-10) inside `runOffline`, obtaining a
`CompiledProgram i o`; then call `saveCompiled optOut compiled` (EP-9). Print a one-line
confirmation `"Saved compiled program to <path> (optimizer=<name>, score=<n>)"`, where the
score is the optimizer's reported validation score if EP-10 returns one (otherwise omit the
score clause). To keep the offline run deterministic, the bundled fixture's cache must
contain every request the optimizer issues; M8 records that fixture by running the optimizer
once with live calls and committing the resulting cache.

Acceptance: `cabal run shikumi -- optimize --program sentiment --dataset reviews --metric
exact --optimizer bootstrap-fewshot --out /tmp/sentiment.json --store-dir
shikumi-cli/example/fixture` writes `/tmp/sentiment.json` and prints the confirmation line.
`loadCompiled "/tmp/sentiment.json"` (exercised by a test) round-trips to a usable
`CompiledProgram`. The transcript appears in "Validation and Acceptance".

### Milestone M6 — `replay`: deterministic identical output

Scope: make `shikumi replay <trace-id>` re-run a stored trace through the replay interpreter
and demonstrate that the output is identical to the original. At the end, running it prints
the program's decoded output and an explicit "identical to recorded output" confirmation.

In `Shikumi/Cli/Run.hs`, implement the `replay` handler: `loadTrace storeDir replayId`
(EP-7) → on `Just tree`, recover the program and original input recorded in the trace's root
span attributes (EP-7 records the program name and the JSON-encoded input), look the program
up in the `Registry` by name, decode the input via the entry's `peDecodeInput`, then run the
program under the replay interpreter: `runReplay tree` wrapped around `runProgram program
input`, executed via the non-network part of `runOffline`. Render the resulting `o` as JSON.
Then read the *recorded* output JSON from the trace's root span and assert byte-equality with
the freshly computed output; print the output followed by either
`"replay: output identical to recorded run ✓"` or, if they differ, a unified diff and a
non-zero exit. Identity is the whole point: replay must reproduce the recorded run exactly
because every LM call is answered from the trace, not the network.

Acceptance: `cabal run shikumi -- replay <fixture-trace-id> --store-dir
shikumi-cli/example/fixture` prints the recorded output and the "identical" confirmation,
with no network access (verifiable by running with networking disabled). Transcript in
"Validation and Acceptance".

### Milestone M7 — DX features: golden tests and OTel flag

Scope: lock the four transcripts with golden tests and wire the OpenTelemetry export flag.
At the end, `cabal test shikumi-cli` runs golden tests that fail if any transcript changes,
and `--otel` causes the run's spans to be exported via EP-7's OTel sink.

Add `shikumi-cli/test/Golden.hs` using a golden-test approach: each test runs one subcommand
against the bundled fixture, captures stdout, and compares it to a committed golden file
under `shikumi-cli/test/golden/{eval,trace,optimize,replay}.txt`. Use `tasty` +
`tasty-golden` (or the project's existing golden mechanism if one is established by EP-8 —
prefer reusing it). The optimize golden compares the *saved compiled-program JSON* (written
to a temp path) against `optimize.json` golden, plus the confirmation line against
`optimize.txt`. Provide a documented way to regenerate goldens (an env var or `--accept`
flag honored by the test driver).

Wire `--otel`: when `GlobalOpts.otel` is `True`, `runOffline` additionally installs EP-7's
OpenTelemetry span sink so the run's hierarchical spans are exported (to the OTLP endpoint
configured by the standard `OTEL_EXPORTER_OTLP_ENDPOINT` environment variable, per EP-7). The
flag changes only observability, not output, so the goldens are unaffected. Document that
verifying live OTel export requires a collector and is out of scope for offline acceptance;
the verifiable behavior here is that `--otel` builds the stack without error and the spans
appear when a collector is present.

Acceptance: `cabal test shikumi-cli` passes; deliberately editing a golden file makes the
corresponding test fail (proving the golden actually guards the transcript); `cabal run
shikumi -- eval … --otel …` runs successfully.

### Milestone M8 — End-to-end acceptance from a clean checkout

Scope: prove the whole thing works together. At the end, a documented sequence reproduces
all four transcripts from a clean checkout offline.

First, record the fixture once (the only step that may touch the network, done by the
implementer, not by CI): with a valid API key set, run `eval`, `optimize`, and a program run
that produces a trace, with the cache and trace store pointed at
`shikumi-cli/example/fixture/`. Commit the resulting cache database and trace store files so
all later runs are offline. Document the exact recording commands in "Concrete Steps" so the
fixture can be regenerated if the example program changes. Note the recorded fixture's
trace-id (printed by the recording run) and substitute it into the acceptance commands and
goldens.

Then verify offline: from a clean checkout (no API key in the environment), run the four
acceptance commands in "Validation and Acceptance" and confirm each transcript matches, and
run `cabal test shikumi-cli` to confirm the goldens pass. This milestone's acceptance is
exactly the four transcripts plus a green test suite, reproduced with networking disabled.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/shikumi` unless
stated otherwise. Replace `<TRACE-ID>` with the fixture trace-id recorded in M8.

Build and the empty-CLI help (after M0/M1):

```bash
cabal build shikumi-cli
cabal run shikumi -- --help
```

Expected (abbreviated) help after M1:

```text
shikumi — typed LM program CLI

Usage: shikumi [--store-dir DIR] [--otel] COMMAND

Available commands:
  eval        Evaluate a program over a dataset with a metric
  trace       Render the hierarchical trace tree for a run
  optimize    Optimize a program and save the compiled result
  replay      Deterministically replay a stored trace

Available options:
  --store-dir DIR  Directory holding the cache and trace store (default ".shikumi")
  --otel           Export OpenTelemetry spans for this run
  -h,--help        Show this help text
```

Per-subcommand help (after M1):

```bash
cabal run shikumi -- eval --help
cabal run shikumi -- replay --help
```

Expected `replay --help`:

```text
Usage: shikumi replay TRACE-ID

  Deterministically replay a stored trace

Available options:
  TRACE-ID    Trace id to replay
  -h,--help   Show this help text
```

Recording the offline fixture (M8, requires an API key; run once by the implementer):

```bash
export ANTHROPIC_API_KEY=sk-...            # provider key for the recording run only
cabal run shikumi -- eval --program sentiment --dataset reviews --metric exact \
  --store-dir shikumi-cli/example/fixture
cabal run shikumi -- optimize --program sentiment --dataset reviews --metric exact \
  --optimizer bootstrap-fewshot --out /tmp/sentiment.json \
  --store-dir shikumi-cli/example/fixture
# the run above also writes a trace; note its printed TRACE-ID
git add shikumi-cli/example/fixture
```

Offline acceptance (M3–M6, no API key needed):

```bash
unset ANTHROPIC_API_KEY
cabal run shikumi -- eval --program sentiment --dataset reviews --metric exact \
  --store-dir shikumi-cli/example/fixture
cabal run shikumi -- trace <TRACE-ID> --store-dir shikumi-cli/example/fixture
cabal run shikumi -- optimize --program sentiment --dataset reviews --metric exact \
  --optimizer bootstrap-fewshot --out /tmp/sentiment.json \
  --store-dir shikumi-cli/example/fixture
cabal run shikumi -- replay <TRACE-ID> --store-dir shikumi-cli/example/fixture
```

Tests:

```bash
cabal test shikumi-cli
```

Update this section with the literal observed transcripts as each milestone lands.


## Validation and Acceptance

Acceptance is the four subcommands producing the expected transcripts offline against the
bundled example, plus a green golden-test suite. The transcripts below are the *target*
shapes (exact numbers depend on the recorded fixture; lock the real values into the goldens
in M7/M8).

`eval` — a Report table:

```text
Report for program "sentiment" over dataset "reviews" (metric: exact)

  #   result   score
  1   PASS     1.00
  2   PASS     1.00
  3   FAIL     0.00
  4   PASS     1.00

  Examples:     4
  Mean score:   0.75
  Mean latency: 412 ms
  Total tokens: 1280
  Total cost:   $0.0041
```

`trace` — a nested tree (indentation shows nesting; root is the whole program run):

```text
Trace <TRACE-ID>

• sentiment (program)            (412 ms, 320 tok)
  • predict                      (404 ms, 320 tok)
    • llm.complete                (399 ms, 320 tok)
```

`optimize` — a saved compiled-program file plus a confirmation line:

```text
Saved compiled program to /tmp/sentiment.json (optimizer=bootstrap-fewshot, score=0.92)
```

with `/tmp/sentiment.json` being inspectable JSON (the golden compares its contents):

```json
{
  "program": "sentiment",
  "optimizer": "bootstrap-fewshot",
  "parameters": {
    "predict": {
      "instruction": "Classify the sentiment of the review as positive or negative.",
      "demos": [
        { "reviewText": "Loved it, would buy again", "label": "positive" },
        { "reviewText": "Total waste of money", "label": "negative" }
      ]
    }
  }
}
```

`replay` — identical output:

```text
Replaying <TRACE-ID> (program "sentiment")

Output:
{ "label": "positive" }

replay: output identical to recorded run ✓
```

The behavioral acceptance, stated as observable facts: (1) `eval` prints a table whose Mean
score equals the mean of the per-example scores; (2) `trace` prints one indented line per
span with depth matching the recorded nesting; (3) `optimize` creates the `--out` file and
`loadCompiled` of it succeeds; (4) `replay` prints `identical` and exits 0, and does so with
networking disabled (e.g. run under a network-namespace sandbox or with the provider host
blocked) — proving no live call occurs. The golden suite (`cabal test shikumi-cli`) passes,
and editing any golden file makes its test fail.

The "fail-before / pass-after" demonstration for an internal change: before M3, `shikumi
eval …` prints only the stub line `[stub] eval …`; after M3, it prints the Report table.
Likewise the golden tests added in M7 fail if pointed at the pre-M3 stub output and pass
against the real renderer, proving the renderer is exercised end-to-end rather than merely
compiled.


## Idempotence and Recovery

All build, run, and test commands are safe to repeat. `shikumi optimize --out PATH`
overwrites `PATH` each run; pick a fresh path or accept overwrite. The offline subcommands
only read the committed fixture and never mutate it, so they are fully idempotent. Recording
the fixture (M8) is the one non-idempotent, network-touching step; it is rerun only when the
example program changes, and rerunning it simply regenerates the committed cache/trace files
(re-`git add` them). If a subcommand fails because a name is unknown, the error lists the
available names — rerun with a valid one. If `replay` reports a non-identical output, the
fixture is stale relative to the program; regenerate the fixture (M8) and re-record the
goldens (M7's `--accept` path). Regenerating goldens is idempotent: it rewrites the golden
files from the current output, after which the tests pass.


## Interfaces and Dependencies

This plan depends on `optparse-applicative` (CLI parsing; registered at
`pcapriotti/optparse-applicative`), `aeson` (JSON for inputs/outputs and the compiled-program
file), `containers` (the `Registry` maps), `text`, `effectful` (the effect stack), and the
sibling shikumi packages: `shikumi` (core: `Program`, `runProgram`, the `LLM` effect,
`ShikumiError`), `shikumi-cache` (`Cache` effect + offline cache backend),
`shikumi-trace` (`Trace` effect, `TraceTree`, `Span`, `loadTrace`, `listTraces`,
`runReplay`, OTel sink), `shikumi-eval` (`Dataset`, `Metric`, `Report`, `evaluate`),
`shikumi-compile` (`CompiledProgram`, `saveCompiled`, `loadCompiled`, `runCompiled`),
`shikumi-optimize` (`Optimizer`, `optimize`), and optionally `shikumi-tools` (EP-11 agents)
for the agent example. Test-time dependencies: `tasty` and `tasty-golden` (or the project's
established golden mechanism).

The new modules and the types/signatures that must exist at the end of each milestone:

- After M0: package `shikumi-cli` with library module `Shikumi.Cli` and executable `shikumi`
  (`shikumi-cli/app/Main.hs`); included in `cabal.project`.
- After M1: `Shikumi.Cli.Options` exporting `Command`, `GlobalOpts`, `EvalOpts`,
  `TraceOpts`, `OptimizeOpts`, `ReplayOpts`, and
  `parseCommand :: ParserInfo (GlobalOpts, Command)`; `Shikumi.Cli.Run` exporting stub
  handlers `runEval`, `runTrace`, `runOptimize`, `runReplay`; `main` in `app/Main.hs`
  dispatching over `Command`.
- After M2: `Shikumi.Cli.Registry` exporting `Registry`, `ProgramEntry`, `DatasetEntry`,
  `MetricEntry`, `emptyRegistry`, and the `register*` functions; `Shikumi.Cli.Runtime`
  exporting `runOffline :: GlobalOpts -> Eff '[LLM, Cache, Trace, Error ShikumiError, IOE] a
  -> IO (Either ShikumiError a)`; example module `Shikumi.Cli.Example` exporting
  `exampleRegistry :: Registry`.
- After M3: `Shikumi.Cli.Render` exporting `renderReport :: Report -> Text`; `runEval ::
  Registry -> GlobalOpts -> EvalOpts -> IO ()` runs `evaluate` and prints the table.
- After M4: `Shikumi.Cli.Render` additionally exporting
  `renderTraceTree :: TraceTree -> Text`; `runTrace :: GlobalOpts -> TraceOpts -> IO ()`.
- After M5: `runOptimize :: Registry -> GlobalOpts -> OptimizeOpts -> IO ()` runs `optimize`
  and `saveCompiled`.
- After M6: `runReplay :: Registry -> GlobalOpts -> ReplayOpts -> IO ()` replays via
  `runReplay`/`runProgram` and asserts identity.
- After M7: `shikumi-cli/test/Golden.hs` with one golden test per subcommand; `runOffline`
  honors `GlobalOpts.otel` by installing EP-7's OTel sink.
- After M8: committed fixture under `shikumi-cli/example/fixture/` and committed goldens
  under `shikumi-cli/test/golden/`; all acceptance transcripts reproduced offline.

The signatures consumed from siblings (authoritative definitions in the referenced files):
`runProgram :: (LLM :> es) => Program i o -> i -> Eff es o`
(`docs/plans/4-typed-program-representation-and-core-modules.md`);
`evaluate :: (LLM :> es) => Program i o -> Dataset i o -> Metric o -> Eff es Report`
(`docs/plans/8-evaluation-framework.md`);
`optimize :: (LLM :> es) => Optimizer -> Program i o -> Dataset i o -> Metric o -> Eff es (CompiledProgram i o)`
(`docs/plans/10-optimizer-framework.md`);
`saveCompiled`/`loadCompiled`/`runCompiled`
(`docs/plans/9-compiler-layer.md`);
`loadTrace`/`listTraces`/`runReplay`/`TraceTree`/`Span` and the OTel sink
(`docs/plans/7-hierarchical-tracing-observability-and-replay.md`);
the `LLM` effect and `ShikumiError`
(`docs/plans/1-shikumi-runtime-substrate-and-llm-effect-over-baikai.md`); the `Cache` effect
and offline backend (`docs/plans/6-caching-subsystem.md`). If any sibling's final names
differ from the contract embedded here, adjust the call sites and record the deviation in the
Decision Log; the *behavior* (run/eval/trace/optimize/replay offline) is the fixed
requirement.
