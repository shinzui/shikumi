---
id: 17
slug: live-opentelemetry-export-sink
title: "Live OpenTelemetry export sink"
kind: exec-plan
created_at: 2026-06-09T22:35:41Z
intention: "intention_01ktq80610e6nbe3d7yrct59an"
master_plan: "docs/masterplans/2-shikumi-substrate-routing-completion.md"
---

# Live OpenTelemetry export sink

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Shikumi is a typed library for writing programs that call language models (LMs). When you
run such a program it can build a *trace*: an in-memory tree of timed "spans," one per piece
of work (the whole program, each module, each combinator, and each individual LM call), with
the LM-call spans tagged with the model name, provider, token counts, and dollar cost. Today
that tree can be written to a JSON file and pretty-printed at the terminal, and there is an
*opt-in* package, `shikumi-trace-otel`, whose one function `exportTree` turns the tree into
nested **OpenTelemetry** spans. OpenTelemetry (often shortened to "OTel") is an
industry-standard format and protocol for traces; an "OTel collector" is a small server that
receives spans over the network and lets you view them (in Jaeger, Grafana Tempo, Honeycomb,
Datadog, and so on).

There is one gap. The `shikumi` command-line tool already accepts a `--otel` flag, but the
flag does nothing: it is parsed and then ignored, because no exporter is wired to a real
collector. `exportTree` only knows how to push spans into a `Tracer` you hand it; nothing in
the shipping code constructs a `Tracer` that actually sends spans over the network. The
project's own EP-12 retrospective records this precisely: "`--otel` is accepted but its live
sink is deferred (needs a collector; out of scope offline)."

After this change, a user who runs `shikumi trace <id> --otel` while an OTel collector is
listening (for example a local one on `http://localhost:4318`) will see the recorded program
appear in their tracing UI as a nested tree of spans, with each LM-call span carrying its
model, provider, token counts, and cost — and, once the sibling plan
`docs/plans/16-node-correlated-tracing-and-feedback-channel.md` (referred to below as EP-16)
has landed, each span also carrying the structural path of the `Program` node that produced
it. That node path is a short string like `compose.0/predict` identifying *which* node in the
typed program issued a given LM call.

Because a real collector is a network service we cannot assume exists in continuous
integration (CI, the automated build-and-test system that runs on every commit), the
*automated* proof of this plan is a **hermetic** test — "hermetic" meaning it needs no network
and no external server. That test uses an **in-memory recording exporter** (a fake collector
that simply remembers the spans it was handed, already a dependency of
`shikumi-trace-otel`'s test suite) and asserts that the spans the live path produces have the
right parent/child nesting and the right attributes. The live collector is a documented,
reproducible *manual* demonstration, not part of CI.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M1: Add `exportTreeLive` (and a small `LiveExport` helper module) to `shikumi-trace-otel`
      that builds a real OTLP `Tracer`, calls the existing `exportTree`, and flushes/shuts the
      provider down. Hermetic recording-exporter test green.
- [ ] M2: Wire the CLI so `shikumi trace <id> --otel` calls `exportTreeLive`; print a one-line
      summary; keep the no-`--otel` path byte-for-byte unchanged. CLI test green.
- [ ] M3: Carry EP-16's per-node `nodePath` (and any per-node attributes) into the exported
      span attributes when the trace contains them; additive and a no-op on traces without them.
- [ ] Update `docs/masterplans/2-shikumi-substrate-routing-completion.md` registry row 17 to
      `Complete` and tick its Progress bullet.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Keep the live exporter in the existing `shikumi-trace-otel` package rather than a
  new package.
  Rationale: that package already isolates the heavy `hs-opentelemetry-*` dependency tree and
  already owns `exportTree`; the live path is a thin wrapper around it. A new package would
  duplicate the dependency isolation for no benefit.
  Date: 2026-06-09.
- Decision: Make the CI-exercised acceptance a hermetic in-memory recording-exporter test; the
  real collector is a documented manual demo only.
  Rationale: a live OTLP collector is a network service; CI cannot depend on one. The in-memory
  exporter (`hs-opentelemetry-exporter-in-memory`) is already a test dependency of this package
  and exercises the *same* span-construction code path, so it proves nesting and attributes
  without a network.
  Date: 2026-06-09.
- Decision: Configure the collector endpoint purely through the standard OTel environment
  variables (`OTEL_EXPORTER_OTLP_ENDPOINT` / `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT`), not a new
  CLI flag.
  Rationale: `hs-opentelemetry-exporter-otlp` already reads exactly these via
  `loadExporterEnvironmentVariables`, and they are the conventions every OTel user already
  knows. Inventing a `--otel-endpoint` flag would duplicate and diverge from the standard.
  Date: 2026-06-09.
- Decision: M3 (per-node attributes) is additive and guarded behind a runtime check for the
  field's presence, so this plan compiles and passes whether or not EP-16 has landed.
  Rationale: the master plan marks EP-16 a *soft* dependency of EP-17; EP-17 must ship against
  today's `TraceTree` and merely export the richer attribute when it exists.
  Date: 2026-06-09.


## Context and Orientation

This section assumes no prior knowledge of the repository. Read it before touching code.

**Where the build happens.** Every build and test in this repository runs inside a Nix
development shell pinned to GHC (the Glasgow Haskell Compiler) version 9.12.4. The system
`ghc` on the PATH is the *wrong* compiler (9.10.3). From the repository root
`/Users/shinzui/Keikaku/bokuno/shikumi`, enter the shell with `nix develop .#ghc9124` and run
`cabal` commands inside it. The repository is a multi-package Cabal project; its
`cabal.project` lists the packages, including `shikumi-trace`, `shikumi-trace-otel`, and
`shikumi-cli`, plus sibling `baikai` packages referenced by local path. Haskell source is
formatted with **fourmolu** using two-space indentation; match the surrounding style.

**The trace tree (the data we export).** The package `shikumi-trace` defines, in
`/Users/shinzui/Keikaku/bokuno/shikumi/shikumi-trace/src/Shikumi/Trace.hs`, the types we
serialize and export. The relevant shapes (verbatim from that module) are:

```haskell
data SpanKind = ProgramSpan | ModuleSpan | CombinatorSpan | LlmCallSpan

newtype SpanId = SpanId Text

data SpanAttrs = SpanAttrs
  { model :: !(Maybe Text),
    provider :: !(Maybe Text),
    prompt :: !(Maybe Value),
    response :: !(Maybe Value),
    latencyMs :: !(Maybe Integer),
    inputTokens :: !(Maybe Natural),
    outputTokens :: !(Maybe Natural),
    costUsd :: !(Maybe Scientific),
    retries :: !Int,
    toolCalls :: ![ToolCallRecord],
    cacheKey :: !(Maybe Text)
  }

data Span = Span
  { spanId :: !SpanId,
    parent :: !(Maybe SpanId),
    kind :: !SpanKind,
    label :: !Text,
    startedAt :: !UTCTime,
    endedAt :: !(Maybe UTCTime),
    attrs :: !SpanAttrs
  }

data TraceTree = TraceTree
  { root :: !SpanId,
    spans :: !(Map SpanId Span)
  }

childrenOf :: TraceTree -> SpanId -> [SpanId]   -- children in creation order
```

A `TraceTree` is a flat `Map` from `SpanId` to `Span`, with each `Span` naming its `parent`;
`childrenOf` recovers the children of a node in order. The tree is *finished* — every span has
its `startedAt`, usually its `endedAt`, and its `attrs` filled in already. We never time
anything ourselves; we replay recorded timestamps.

**EP-16's addition (the soft dependency).** The master plan
`docs/masterplans/2-shikumi-substrate-routing-completion.md` states that EP-16 adds an
optional field to `SpanAttrs` — working name `nodePath :: Maybe NodePath` — identifying a
node's structural position in a `Program`, rendered to a short string. As of this writing
`SpanAttrs` (above) has **no** such field; EP-16 is checked in only as a skeleton at
`docs/plans/16-node-correlated-tracing-and-feedback-channel.md`. This plan therefore must
*not* assume the field exists at compile time. Milestone M3 adds the export of that field in
a way that degrades to a no-op when the field is absent, and the plan's M3 section spells out
exactly how to detect which case you are in when you implement it.

**The existing OTel adapter (what we build on).** The package `shikumi-trace-otel` has one
module, `/Users/shinzui/Keikaku/bokuno/shikumi/shikumi-trace-otel/src/Shikumi/Trace/OpenTelemetry.hs`,
exporting one function:

```haskell
exportTree :: (MonadIO m) => Otel.Tracer -> TraceTree -> m ()
```

`Otel.Tracer` is the OpenTelemetry library's handle for creating spans. `exportTree` walks the
tree depth-first from the root, creating one OTel span per node and nesting children under
their parent by threading an explicit `Context` (it calls `OpenTelemetry.Context.insertSpan`
to put the parent span into the context it uses for each child). It sets each span's
start/end from the recorded `startedAt`/`endedAt`, sets status `Ok`, and attaches attributes:
every span gets `shikumi.span_kind` and `shikumi.retries`; LM-call spans additionally get the
GenAI semantic-convention attributes (`gen_ai.provider.name`, `gen_ai.request.model`,
`gen_ai.response.model`, `gen_ai.usage.input_tokens`, `gen_ai.usage.output_tokens`,
`gen_ai.operation.name`) plus `shikumi.cost.usd` and `shikumi.latency_ms`. **This is the
span-construction logic we reuse unchanged.** Our job is only to give `exportTree` a `Tracer`
that points at a real collector, then flush and shut it down.

A `Tracer` does not export anything by itself. In the `hs-opentelemetry` library a `Tracer`
is made from a **`TracerProvider`**, which holds one or more **span processors**, each
wrapping an **exporter** (the thing that actually serializes spans and sends them somewhere).
The package's existing test (`shikumi-trace-otel/test/Main.hs`) already constructs a provider
whose exporter is *in-memory*:

```haskell
(proc, spansRef) <- inMemoryListExporter
tp <- Otel.createTracerProvider [proc] Otel.emptyTracerProviderOptions
let tracer = Otel.makeTracer tp "shikumi-trace-otel-test" Otel.tracerOptions
```

For the live path we keep the same shape but swap the in-memory exporter for the **OTLP
exporter** (OTLP = "OpenTelemetry Protocol," the wire format collectors speak over HTTP).

**The OTLP library API we depend on (verified on disk).** The exporter lives in the package
`hs-opentelemetry-exporter-otlp`, module `OpenTelemetry.Exporter.OTLP.Span`, with these exact
signatures (read from
`/Users/shinzui/Keikaku/hub/haskell/hs-opentelemetry-project/hs-opentelemetry/exporters/otlp/src/OpenTelemetry/Exporter/OTLP/Span.hs`):

```haskell
otlpExporter :: (MonadIO m) => OTLPExporterConfig -> m SpanExporter
loadExporterEnvironmentVariables :: (MonadIO m) => m OTLPExporterConfig
otlpExporterHttpEndpoint :: ByteString   -- "http://localhost:4318"
```

`loadExporterEnvironmentVariables` reads the standard OTel variables, importantly
`OTEL_EXPORTER_OTLP_ENDPOINT` (default `http://localhost:4318` for HTTP) and the
traces-specific override `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT`. So the endpoint is configured
by environment, never hard-coded: if the user sets neither, the exporter targets
`http://localhost:4318`, the conventional local-collector address.

The span processor and provider come from `hs-opentelemetry-sdk`. The batch processor (which
queues spans and flushes them on demand) has these signatures (from
`.../hs-opentelemetry/sdk/src/OpenTelemetry/Processor/Batch/Span.hs`):

```haskell
batchProcessor :: (MonadIO m) => BatchTimeoutConfig -> SpanExporter -> m SpanProcessor
batchTimeoutConfig :: BatchTimeoutConfig   -- sane defaults; 5s scheduled delay
```

and the provider/tracer/shutdown come from the API package
(`.../hs-opentelemetry/api/src/OpenTelemetry/Trace/Core.hs`):

```haskell
createTracerProvider :: (MonadIO m) => [SpanProcessor] -> TracerProviderOptions -> m TracerProvider
emptyTracerProviderOptions :: TracerProviderOptions
makeTracer :: TracerProvider -> InstrumentationLibrary -> TracerOptions -> Tracer
tracerOptions :: TracerOptions
forceFlushTracerProvider :: (MonadIO m) => TracerProvider -> Maybe Int -> m FlushResult
shutdownTracerProvider :: (MonadIO m) => TracerProvider -> Maybe Int -> m ShutdownResult
```

`shutdownTracerProvider` flushes any pending spans and then shuts the provider's processors
down (its `Maybe Int` is an optional timeout in microseconds, defaulting to 5 seconds). Because
the batch processor exports on a timer, **we must flush/shut down before the process exits** or
the spans never leave. The batch processor additionally *requires the `-threaded` runtime*
(it `error`s otherwise); both `shikumi-trace-otel`'s test suite and the `shikumi` executable
already pass `-threaded -with-rtsopts=-N`, so this is satisfied.

**The CLI (where `--otel` lives).** The package `shikumi-cli` defines the command-line tool.
The flag is declared in
`/Users/shinzui/Keikaku/bokuno/shikumi/shikumi-cli/src/Shikumi/Cli/Options.hs` as the field
`otel :: !Bool` on `GlobalOpts`, parsed by a `switch (long "otel" <> help "Export
OpenTelemetry spans for this run")`. Nothing reads it. The `trace` subcommand is handled in
`/Users/shinzui/Keikaku/bokuno/shikumi/shikumi-cli/src/Shikumi/Cli/Run.hs` by `runTraceCmd`:

```haskell
runTraceCmd :: GlobalOpts -> TraceOpts -> IO ()
runTraceCmd g (TraceOpts tid) = do
  let path = traceFilePath g tid
  exists <- doesFileExist path
  if not exists
    then die (...)
    else do
      e <- readTraceFile path
      case e of
        Left err -> die err
        Right tree -> TIO.putStr ("Trace " <> tid <> "\n\n" <> renderTree tree)
```

It loads a recorded `TraceTree` from a JSON file under the store directory and pretty-prints
it. `runTraceCmd` is the single place we hook the live export: after (or instead of) printing
the tree, when `otel g` is `True` we hand the same `tree` to the new live exporter.

**Why `shikumi-cli` cannot import `shikumi-trace-otel` today.** Looking at
`shikumi-cli/shikumi-cli.cabal`, the library's `build-depends` lists `shikumi-trace` but
**not** `shikumi-trace-otel`. That is deliberate: the heavy `hs-opentelemetry-*` tree is kept
out of the default CLI build. This plan adds `shikumi-trace-otel` (and, transitively through
it, nothing extra the CLI must name) to the CLI library's dependencies, because turning the
flag into real behavior necessarily pulls in the exporter. This is an accepted, explicit
trade: the `--otel` feature requires the OTel stack, so the CLI that offers it must depend on
it. (An alternative — a separate `shikumi-cli-otel` executable — is considered and rejected in
the Decision Log of M2.)


## Plan of Work

The work is three small, independently verifiable milestones, plus a final bookkeeping step.
M1 builds and proves the live exporter in isolation (hermetically). M2 wires it into the CLI
flag and proves the flag now does something. M3 enriches the exported attributes with EP-16's
per-node path when present. Each milestone leaves the tree green.


### Milestone M1 — A live OTLP exporter behind `exportTreeLive`

**Scope.** Add to `shikumi-trace-otel` a function that constructs a real OTLP-backed `Tracer`,
runs the existing `exportTree` against it, then flushes and shuts the provider down. Add the
OTLP exporter and SDK packages to the library's dependencies. Prove it with a hermetic test
that swaps the OTLP exporter for the in-memory recording exporter and asserts nesting +
attributes — the *same* code path, minus the network.

**What will exist at the end.** A new module
`/Users/shinzui/Keikaku/bokuno/shikumi/shikumi-trace-otel/src/Shikumi/Trace/LiveExport.hs`
exporting:

```haskell
-- | Build a TracerProvider whose single batch processor wraps the given
-- SpanExporter, make a tracer named by the first argument, export the tree
-- through the existing 'exportTree', then flush and shut the provider down.
-- Factored out so the hermetic test can pass an in-memory exporter and the CLI
-- can pass the OTLP exporter, exercising one code path.
exportTreeWith ::
  (MonadIO m) =>
  Otel.SpanExporter ->
  Text ->            -- instrumentation/service name, e.g. "shikumi"
  TraceTree ->
  m ()

-- | The live path: load OTLP config from the standard OTEL_* environment
-- variables, build the OTLP HTTP exporter, and export the tree to a real
-- collector (default endpoint http://localhost:4318). Flushes on completion.
exportTreeLive ::
  (MonadIO m) =>
  Text ->            -- service name
  TraceTree ->
  m ()
```

Keep `exportTree` (the span-construction walker) exactly as it is; `exportTreeWith` *calls*
it. Concretely, `exportTreeWith exporter name tree` does:

1. `proc <- batchProcessor batchTimeoutConfig exporter`
2. `tp <- createTracerProvider [proc] emptyTracerProviderOptions`
3. `let tracer = makeTracer tp (InstrumentationLibrary name "") tracerOptions` — match the
   constructor the SDK uses; the test file builds a tracer with `makeTracer tp
   "shikumi-trace-otel-test" tracerOptions`, so a bare string library name is acceptable
   (the SDK's `InstrumentationLibrary` has an `IsString` instance). Use whatever spelling
   compiles cleanly against the pinned library version; the existing test demonstrates the
   working form.
4. `exportTree tracer tree`
5. `_ <- shutdownTracerProvider tp Nothing` — this flushes the batch processor and stops it.
   (Equivalently `forceFlushTracerProvider tp Nothing` then `shutdownTracerProvider`; a plain
   shutdown already flushes, so one call suffices.)

`exportTreeLive name tree` does:

1. `cfg <- loadExporterEnvironmentVariables`
2. `exporter <- otlpExporter cfg`
3. `exportTreeWith exporter name tree`

**Dependencies to add.** In `shikumi-trace-otel/shikumi-trace-otel.cabal`, the `library`
stanza's `build-depends` currently names `hs-opentelemetry-api` and
`hs-opentelemetry-semantic-conventions`. Add `hs-opentelemetry-sdk` (for `batchProcessor`,
`createTracerProvider`) and `hs-opentelemetry-exporter-otlp` (for `otlpExporter`,
`loadExporterEnvironmentVariables`). Both already appear in the *test* stanza of a sibling or
this package (the SDK is in this package's test stanza; the OTLP exporter is a new addition),
so the version bounds to use are the ones the dev shell already resolves —
`hs-opentelemetry-sdk >=1.0 && <1.1` and `hs-opentelemetry-exporter-otlp >=1.0 && <1.1`. Also
add the `text` and `containers` deps if not already present (they are). Add the new module to
`exposed-modules`.

**The hermetic test.** Extend `shikumi-trace-otel/test/Main.hs` (do not delete the existing
`nestingTest`) with a second test, `liveExportInMemoryTest`, that proves the *factored* path:

```haskell
liveExportInMemoryTest :: TestTree
liveExportInMemoryTest =
  testCase "exportTreeWith (recording exporter) preserves nesting and attributes" $ do
    (exporter, getSpans) <- inMemoryListExporter
    exportTreeWith exporter "shikumi-live-test" fixedTree
    emitted <- getSpans
    assertEqual "one span per tree node" (Map.size (spans fixedTree)) (length emitted)
    -- ... same nesting + gen_ai.request.model assertions as nestingTest ...
```

`inMemoryListExporter` returns a *`SpanExporter`* (the same type `otlpExporter` returns), so
`exportTreeWith` accepts it directly — that is exactly why the function is factored on
`SpanExporter`. (The existing `nestingTest` wires the in-memory exporter through a manually
built provider and calls `exportTree` directly; the new test instead drives the *whole*
`exportTreeWith` orchestration — provider construction, batch processor, export, and
shutdown-flush — proving the live code path end to end without a network.) The test depends on
`hs-opentelemetry-exporter-in-memory`, already in the test stanza.

Because `exportTreeWith` shuts the provider down after exporting, the in-memory exporter will
have received and recorded the spans by the time `getSpans` runs; no sleeping is needed.

**Commands.**

```bash
cd /Users/shinzui/Keikaku/bokuno/shikumi
nix develop .#ghc9124 --command cabal build shikumi-trace-otel
nix develop .#ghc9124 --command cabal test shikumi-trace-otel
```

**Acceptance.** Before this milestone, `exportTreeWith` does not exist; the new test does not
compile. After it, `cabal test shikumi-trace-otel` runs two test cases and both pass; the new
case asserts that exporting `fixedTree` through the full live orchestration yields one
recorded span per tree node, two LM-call (`Client`-kind) spans each carrying
`gen_ai.request.model`, and a single root with every other span's parent present among the
emitted spans. Expected tail of the transcript:

```text
shikumi-trace-otel
  exportTree emits nested spans with GenAI attributes:                    OK
  exportTreeWith (recording exporter) preserves nesting and attributes:   OK

All 2 tests passed
```


### Milestone M2 — Wire `shikumi trace --otel` to the live exporter

**Scope.** Make the `--otel` flag do something: when set, `runTraceCmd` hands the loaded
`TraceTree` to `exportTreeLive` (in addition to printing it, so the existing golden output is
unchanged), prints a one-line confirmation naming the endpoint, and exits cleanly with spans
flushed. Add `shikumi-trace-otel` to the CLI library's dependencies.

**What will exist at the end.** `runTraceCmd` in
`/Users/shinzui/Keikaku/bokuno/shikumi/shikumi-cli/src/Shikumi/Cli/Run.hs` becomes (sketch):

```haskell
runTraceCmd :: GlobalOpts -> TraceOpts -> IO ()
runTraceCmd g (TraceOpts tid) = do
  let path = traceFilePath g tid
  exists <- doesFileExist path
  if not exists
    then die (...)
    else do
      e <- readTraceFile path
      case e of
        Left err -> die err
        Right tree -> do
          TIO.putStr ("Trace " <> tid <> "\n\n" <> renderTree tree)
          when (otel g) $ do
            exportTreeLive "shikumi" tree
            ep <- otlpEndpointForMessage     -- read OTEL_EXPORTER_OTLP_ENDPOINT, default note
            TIO.putStrLn ("\nExported " <> tshow (Map.size (treeSpans tree)) <> " spans via OTLP to " <> ep)
```

Add the imports: `Shikumi.Trace.OpenTelemetry`/`Shikumi.Trace.LiveExport` for `exportTreeLive`,
`Control.Monad (when)`, and whatever accessor reaches the span count (the trace tree's `spans`
map size; reuse the field accessor from `Shikumi.Trace`). The endpoint string for the message
is read from the environment with `System.Environment.lookupEnv "OTEL_EXPORTER_OTLP_ENDPOINT"`,
falling back to the literal `http://localhost:4318 (default)` so the user always sees where the
spans went. Keep this purely cosmetic — the *actual* endpoint resolution lives in the OTLP
library's `loadExporterEnvironmentVariables`; this message must not diverge in behavior, only
echo the same variable.

**Crucial: do not change the no-`--otel` output.** The existing CLI golden test
(`shikumi-cli/test/Main.hs`) exercises `trace` without `--otel`; the printed tree must remain
byte-for-byte identical. By printing the tree first and only *appending* OTel output guarded by
`when (otel g)`, the default path is untouched. Verify this explicitly (see Acceptance).

**Dependency edit.** In `shikumi-cli/shikumi-cli.cabal`, add `shikumi-trace-otel` to the
`library` stanza's `build-depends`. The executable and test stanzas need no change (the
executable depends on `shikumi-cli`; the test already builds the library).

**Decision recorded here (and in the Decision Log):** we add the OTel dependency to the
existing CLI library rather than splitting a separate `shikumi-cli-otel` executable. Splitting
would keep the default build lean but would mean the bundled `shikumi` binary — the one the
docs tell users to run — could not honor its own `--otel` flag, which is the whole point of
this plan. The heavier dependency closure is the accepted cost of a working flag.

**Commands.**

```bash
cd /Users/shinzui/Keikaku/bokuno/shikumi
nix develop .#ghc9124 --command cabal build shikumi-cli
nix develop .#ghc9124 --command cabal test shikumi-cli
```

**Acceptance.** The CLI test suite (which runs `trace` *without* `--otel`) still passes
unchanged, proving the default output is preserved. For the flag itself, the hermetic proof is
M1's test; the manual proof is the live scenario in "Validation and Acceptance" below. As a
quick local smoke check that the flag is wired and does not crash even with *no* collector
running, you can run it and observe that it prints the tree, attempts the export, and prints
the summary line; with no collector the OTLP HTTP POST will fail at the network layer but the
program still flushes and exits (export errors from a batch processor are swallowed by the
processor and surfaced as dropped spans, not as a crash). This is acceptable: a missing
collector must not make `shikumi trace --otel` abort with a stack trace.


### Milestone M3 — Carry EP-16's per-node path into exported attributes

**Scope.** When the loaded `TraceTree`'s spans carry EP-16's per-node `nodePath` (and any
sibling per-node attributes EP-16 adds, such as node feedback), include them as an OTel span
attribute (`shikumi.node_path`). This is purely additive to the attribute map built in
`Shikumi.Trace.OpenTelemetry.attrsFor`; it must be a no-op on traces (and on a pre-EP-16
`SpanAttrs`) that lack the field.

**Two cases — detect which you are in before writing code.** Re-read
`/Users/shinzui/Keikaku/bokuno/shikumi/shikumi-trace/src/Shikumi/Trace.hs` and the checked-in
state of `docs/plans/16-node-correlated-tracing-and-feedback-channel.md`:

- **If EP-16 has landed** and `SpanAttrs` now has a field of the form
  `nodePath :: Maybe NodePath` (or whatever the final name is — confirm against the source),
  then in `attrsFor` (the function in `Shikumi.Trace.OpenTelemetry` that builds the
  `HashMap Text Attr.Attribute` for a span) add, for *every* span kind, a line that — when the
  field is `Just p` — inserts `("shikumi.node_path", Attr.toAttribute (renderNodePath p))`,
  where `renderNodePath` is EP-16's rendering function (it exposes one, per the master plan's
  integration point #3, which renders the path to a `Text` like `compose.0/predict`). Leave
  the field absent from the attribute map when the value is `Nothing`. If EP-16 also adds a
  per-node feedback string, export it analogously as `shikumi.node_feedback`.

- **If EP-16 has not yet landed** (the current state: `SpanAttrs` has no such field), this
  milestone is a documentation-only stub: record in this plan's Progress and Decision Log that
  M3 is deferred pending EP-16, and add a clearly-marked comment at the `attrsFor` insertion
  site naming the attribute key (`shikumi.node_path`) and the exact one-line change to make
  once the field exists. Do **not** invent a `nodePath` field in `shikumi-trace` from this
  plan — that field is EP-16's to define, and duplicating it here would create a conflicting
  definition.

**What will exist at the end (landed case).** Each exported span whose source `Span` carries a
node path also carries `shikumi.node_path` in the tracing UI; LM-call spans thus show *both*
their model/provider/tokens/cost *and* the node that issued them.

**Test.** In the landed case, extend the hermetic test: give one LM-call span in a fixture a
`nodePath` value and assert the recorded span's attribute map contains `shikumi.node_path`
with the rendered string. In the deferred case, no test changes.

**Commands.** Same as M1 (`cabal test shikumi-trace-otel`) plus `cabal test all` to confirm
nothing else regressed.

**Acceptance.** Landed case: the new assertion passes and a manual run against a collector
shows the `shikumi.node_path` attribute on LM-call spans. Deferred case: this plan's Progress
records M3 as "deferred pending EP-16," with the stub comment present in
`Shikumi.Trace.OpenTelemetry`; `cabal test all` is green.


## Concrete Steps

All commands run from the repository root
`/Users/shinzui/Keikaku/bokuno/shikumi` inside the dev shell. You can either open the shell
once (`nix develop .#ghc9124`) and run the bare `cabal` lines, or prefix each with
`nix develop .#ghc9124 --command`.

M1 — create the module and edit the cabal:

```bash
cd /Users/shinzui/Keikaku/bokuno/shikumi
# 1. Create shikumi-trace-otel/src/Shikumi/Trace/LiveExport.hs with exportTreeWith / exportTreeLive (see M1).
# 2. Edit shikumi-trace-otel/shikumi-trace-otel.cabal:
#    - add Shikumi.Trace.LiveExport to library exposed-modules
#    - add hs-opentelemetry-sdk and hs-opentelemetry-exporter-otlp to the library build-depends
# 3. Extend shikumi-trace-otel/test/Main.hs with liveExportInMemoryTest (see M1).
nix develop .#ghc9124 --command cabal build shikumi-trace-otel
nix develop .#ghc9124 --command cabal test  shikumi-trace-otel
nix develop .#ghc9124 --command fourmolu --mode check shikumi-trace-otel/src shikumi-trace-otel/test
```

M2 — wire the CLI:

```bash
cd /Users/shinzui/Keikaku/bokuno/shikumi
# 1. Edit shikumi-cli/shikumi-cli.cabal: add shikumi-trace-otel to the library build-depends.
# 2. Edit shikumi-cli/src/Shikumi/Cli/Run.hs: import exportTreeLive + when; append the OTel branch to runTraceCmd.
nix develop .#ghc9124 --command cabal build shikumi-cli
nix develop .#ghc9124 --command cabal test  shikumi-cli
nix develop .#ghc9124 --command fourmolu --mode check shikumi-cli/src
```

M3 — per-node attribute (only if EP-16 has landed; otherwise leave the stub comment):

```bash
cd /Users/shinzui/Keikaku/bokuno/shikumi
# Edit shikumi-trace-otel/src/Shikumi/Trace/OpenTelemetry.hs attrsFor to insert shikumi.node_path when present.
nix develop .#ghc9124 --command cabal test shikumi-trace-otel
nix develop .#ghc9124 --command cabal test all
```

After all milestones, commit. Every commit message in this repository carries the master-plan,
exec-plan, and intention trailers, for example:

```text
feat(shikumi-trace-otel): live OTLP export sink behind `trace --otel`

MasterPlan: docs/masterplans/2-shikumi-substrate-routing-completion.md
ExecPlan: docs/plans/17-live-opentelemetry-export-sink.md
Intention: intention_01ktq80610e6nbe3d7yrct59an
```


## Validation and Acceptance

There are two complementary acceptances. The first is the CI-exercised, hermetic one; the
second is the manual live demo.

**(a) Hermetic recording-exporter test — the CI path.** This needs no network. It is the new
`liveExportInMemoryTest` from M1 (and, in the EP-16-landed case, the `shikumi.node_path`
assertion from M3). Run:

```bash
cd /Users/shinzui/Keikaku/bokuno/shikumi
nix develop .#ghc9124 --command cabal test shikumi-trace-otel
```

Expected: both test cases pass. This proves the full live orchestration — building a
`TracerProvider` with a batch processor, exporting the tree through `exportTree`, and flushing
on shutdown — produces correctly nested spans with the right attributes, *using the exact same
`exportTreeWith` the CLI calls*, only with the destination swapped to an in-memory recorder. It
fails before the milestone (the function does not exist) and passes after.

To convince yourself it is a real before/after, temporarily break `exportTreeWith` (for
example, drop the `batchProcessor` and pass `[]` to `createTracerProvider`) and observe the
test fail with zero recorded spans; then restore it.

**(b) Live collector — the manual demo.** This requires a collector and is *not* run in CI.
Start a local OpenTelemetry collector that accepts OTLP/HTTP on port 4318 and prints received
spans to its log. A one-liner using the official collector image:

```bash
docker run --rm -p 4318:4318 \
  otel/opentelemetry-collector:latest \
  2>&1 | tee /tmp/otelcol.log
```

The default config of that image enables an OTLP receiver on `4317` (gRPC) and `4318` (HTTP)
and a `debug`/`logging` exporter that prints spans to stdout, which is what we observe. (Any
collector works — Jaeger all-in-one with OTLP enabled, Grafana Tempo, a vendor agent — as long
as it listens for OTLP/HTTP on the endpoint you point `shikumi` at.)

In a second terminal, first make sure a recorded trace exists, then run the trace command with
`--otel`:

```bash
cd /Users/shinzui/Keikaku/bokuno/shikumi
# Record a trace fixture offline (no network, uses the deterministic stub LM):
nix develop .#ghc9124 --command cabal run shikumi -- record --program <name>
# Export it live to the local collector (default endpoint http://localhost:4318):
nix develop .#ghc9124 --command cabal run shikumi -- trace <name> --otel
```

`<name>` is one of the registered example program names; run `cabal run shikumi -- trace`
with a bad id to have the CLI print the registered names, or read
`shikumi-cli/src/Shikumi/Cli/Example.hs`. To target a non-default collector, set the standard
variable before the command, for example:

```bash
OTEL_EXPORTER_OTLP_ENDPOINT=http://my-collector:4318 \
  nix develop .#ghc9124 --command cabal run shikumi -- trace <name> --otel
```

Expected `shikumi` output (the printed tree is unchanged from the non-`--otel` run; only the
final line is new):

```text
Trace <name>

<the indented trace outline, one line per span, exactly as before>

Exported 5 spans via OTLP to http://localhost:4318 (default)
```

Expected in the collector log (`/tmp/otelcol.log`): a resource-spans block containing the
nested spans. You should see one span per tree node, the LM-call spans carrying
`gen_ai.request.model`, `gen_ai.provider.name`, `gen_ai.usage.input_tokens`,
`gen_ai.usage.output_tokens`, `shikumi.cost.usd`, and `shikumi.latency_ms`, and — if EP-16 has
landed (M3) — `shikumi.node_path`. A trimmed example of what the collector's debug exporter
prints for one LM-call span:

```text
Span #2
    Trace ID       : 6f1c...
    Parent ID      : 1a2b...
    Name           : anthropic/claude
    Kind           : Client
    Attributes:
         -> gen_ai.request.model: Str(claude-sonnet-4-6)
         -> gen_ai.provider.name: Str(anthropic)
         -> gen_ai.usage.input_tokens: Int(812)
         -> gen_ai.usage.output_tokens: Int(143)
         -> shikumi.cost.usd: Double(...)
         -> shikumi.span_kind: Str(llm-call)
         -> shikumi.node_path: Str(compose.0/predict)
```

Success is: the spans arrive nested (every non-root span names a parent that is another
emitted span, all sharing one trace id), and the LM-call spans carry the GenAI attributes. If
nothing arrives, the usual cause is the collector not listening on the endpoint you used; check
the `Exported ... to <endpoint>` line matches the collector's port, and that the batch
processor flushed (it does, because `exportTreeLive` shuts the provider down before
returning).


## Idempotence and Recovery

Every step here is safe to repeat. Re-running `cabal build`/`cabal test` is idempotent.
Re-running `shikumi trace <name> --otel` simply re-exports the same recorded trace again,
producing a fresh trace id each run (the OTel library generates new span/trace ids per
export), so repeated runs never corrupt anything; they just create duplicate traces in the
collector, which is harmless. The cabal edits are additive (new dependencies, a new module,
new test case, an appended CLI branch); if a build fails midway, fix and re-run — nothing is
deleted or migrated. If the live demo's collector is unreachable, the command still completes
(prints the tree and the summary line); only the spans fail to arrive, which you remedy by
starting the collector and re-running. The non-`--otel` path is never touched, so existing
golden output cannot drift.


## Interfaces and Dependencies

Libraries used and why:

- `hs-opentelemetry-exporter-otlp` (module `OpenTelemetry.Exporter.OTLP.Span`): provides
  `otlpExporter :: (MonadIO m) => OTLPExporterConfig -> m SpanExporter` and
  `loadExporterEnvironmentVariables :: (MonadIO m) => m OTLPExporterConfig`, which read
  `OTEL_EXPORTER_OTLP_ENDPOINT` / `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` (default
  `http://localhost:4318`). This is the real network sink.
- `hs-opentelemetry-sdk`: provides `batchProcessor :: (MonadIO m) => BatchTimeoutConfig ->
  SpanExporter -> m SpanProcessor` and `batchTimeoutConfig`, the queue-and-flush processor
  wrapping the exporter. Requires the `-threaded` runtime (already set on both the test suite
  and the `shikumi` executable).
- `hs-opentelemetry-api` (module `OpenTelemetry.Trace.Core`): provides
  `createTracerProvider :: (MonadIO m) => [SpanProcessor] -> TracerProviderOptions -> m
  TracerProvider`, `emptyTracerProviderOptions`, `makeTracer`, `tracerOptions`,
  `forceFlushTracerProvider`, and `shutdownTracerProvider :: (MonadIO m) => TracerProvider ->
  Maybe Int -> m ShutdownResult` (the flush-and-stop call). Already a dependency.
- `hs-opentelemetry-exporter-in-memory` (test only): provides `inMemoryListExporter :: IO
  (SpanExporter, IO [ImmutableSpan])`, the hermetic recorder used by both tests. Already a
  test dependency.
- `shikumi-trace`: provides `TraceTree`, `Span`, `SpanAttrs`, `SpanKind`, `childrenOf`, and
  (after EP-16) the per-node `nodePath` field and its renderer.

Signatures that must exist at the end of each milestone:

- End of M1 — in new module `Shikumi.Trace.LiveExport`:
  `exportTreeWith :: (MonadIO m) => Otel.SpanExporter -> Text -> TraceTree -> m ()` and
  `exportTreeLive :: (MonadIO m) => Text -> TraceTree -> m ()`. `Shikumi.Trace.OpenTelemetry`'s
  `exportTree` is unchanged.
- End of M2 — `Shikumi.Cli.Run.runTraceCmd :: GlobalOpts -> TraceOpts -> IO ()` unchanged in
  type but now branching on `otel g` to call `exportTreeLive`; `shikumi-cli` library depends on
  `shikumi-trace-otel`.
- End of M3 — in `Shikumi.Trace.OpenTelemetry.attrsFor`, an additive insertion of
  `shikumi.node_path` (and optionally `shikumi.node_feedback`) when the source span carries
  EP-16's per-node field; no change to any type signature.

Cross-plan dependency: this is EP-17 in
`docs/masterplans/2-shikumi-substrate-routing-completion.md`. It *soft-depends* on EP-16
(`docs/plans/16-node-correlated-tracing-and-feedback-channel.md`): M1 and M2 ship against
today's `TraceTree`; only M3's per-node attribute needs EP-16's field, and M3 is written to be
a no-op (or documented stub) when that field is absent. On completion, set this plan's registry
row in the master plan to `Complete` and tick its Progress bullet.
