---
id: 43
slug: otel-export-correctness-tail
title: "OTel Export Correctness Tail"
kind: exec-plan
created_at: 2026-07-02T03:30:16Z
intention: "intention_01kwgdyxm7ehh8yys1pp4wf1zr"
master_plan: "docs/masterplans/7-cache-trace-and-replay-hardening.md"
---

# OTel Export Correctness Tail

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

`shikumi-trace-otel` exports a finished shikumi trace tree (a recording of one LM-program run: nested spans for the program, its modules, its combinators, and each LM call) as OpenTelemetry spans, so users can view shikumi runs in any OTel backend (Jaeger, Honeycomb, an OTLP collector). A production-readiness review found five correctness bugs in this small package, all fixed by this plan:

1. If exporting throws partway, the tracer provider is never flushed or shut down — buffered spans are silently lost and the provider's resources leak.
2. Every exported span is stamped status `Ok`, including LM calls whose recorded response *reports a provider error* — and because OTel's status order is `Ok > Error > Unset`, that `Ok` is not just wrong, it is un-overridable downstream.
3. The GenAI attribute `gen_ai.response.model` is filled from the *request* model, so a routed/aliased call (ask for `claude-sonnet`, get `claude-sonnet-4-6-20250929`) reports a response model that is simply false.
4. A span that was never closed (`endedAt = Nothing`, e.g. the program crashed mid-span) is ended "now" — at export time — fabricating a duration of hours or days for a span that ran milliseconds.
5. The tree walk follows parent/child edges with no cycle guard, so a corrupt trace file with a self-parented span makes the exporter recurse forever.

After this plan: an exception during export still flushes-and-releases the provider (and propagates); error responses export as status `Error`; `gen_ai.response.model` comes from the recorded response (or is omitted); never-closed spans export with their start time as end plus a `shikumi.incomplete` marker; and a cyclic tree exports each reachable span at most once and terminates. Each behavior is locked by a new hermetic test using the in-memory exporter — no collector needed.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M1: `exportTreeWith` runs export inside `bracket`; provider shut down on all exit paths
- [ ] M2: cycle guard (visited set) in `exportTree`'s walk
- [ ] M2: status derived from the recorded response (`Error` for in-band failures, `Ok` otherwise)
- [ ] M2: `gen_ai.response.model` read from the recorded response's echoed model; omitted when absent
- [ ] M2: open spans ended at their start time with `shikumi.incomplete = true`
- [ ] M3: four new tests (exception-releases-provider, status propagation, open-span handling, cyclic-tree termination) green
- [ ] Full suite green: `just test-one shikumi-trace-otel`


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Detect "error span" from the recorded response JSON (`errorInfo` non-null, or `message.stopReason == "error"`, or `message.errorMessage` non-null) rather than adding an error field to `SpanAttrs`.
  Rationale: The response JSON already carries the truth and is already stored on every LM-call span; a new `SpanAttrs` field would change the trace-file schema (a format-version concern owned by shikumi-trace, not this package) for information that is derivable.
  Source: production-readiness code review; baikai's `Response` encodes `errorInfo :: Maybe BaikaiError` (null on success) and `StopReason` with the tag `"error"` for `ErrorReason`.
  Date: 2026-07-01

- Decision: A never-closed span exports with end = start (zero duration) plus attribute `shikumi.incomplete = true`, instead of end = export time or being skipped.
  Rationale: OTel spans must end to be exported at all, so skipping loses the span and its attributes; export-time "now" fabricates an arbitrary, potentially enormous duration (the current bug). Zero duration is visibly artificial, and the explicit marker makes it queryable.
  Date: 2026-07-01

- Decision: On a cycle, export each reachable span once and terminate (visited-set guard) rather than throwing on detection.
  Rationale: The exporter is a best-effort sink at the end of a run; salvaging the acyclic portion of a corrupt file is more useful than refusing it wholesale, and strict validation of trace files is the reader's job (`Shikumi.Trace.Store.readTraceFile`). Termination is the non-negotiable part.
  Date: 2026-07-01


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This repository is a cabal multi-package Haskell project; work inside the Nix dev shell (`nix develop .#ghc9124` from the repo root) and test with `just test-one shikumi-trace-otel`.

The package has two source modules and one test module:

- `shikumi-trace-otel/src/Shikumi/Trace/OpenTelemetry.hs` — `exportTree :: MonadIO m => Otel.Tracer -> TraceTree -> m ()`. A `TraceTree` (from `shikumi-trace`, module `Shikumi.Trace`) is a flat `Map SpanId Span` plus a `root :: SpanId`; each `Span` has `parent`, `kind`, `label`, `startedAt :: UTCTime`, `endedAt :: Maybe UTCTime`, and an attribute bag `SpanAttrs` whose LM-call-relevant fields are `model`, `provider`, `response :: Maybe Value` (the full recorded response as JSON), token counts, cost, latency, `retries`, and `nodePath`. `exportTree`'s local `go` (lines 49-57) walks depth-first from the root: `createSpan` with the recorded start time, `addAttributes`, `setStatus sp Otel.Ok` unconditionally (line 54 — bug 2), recurse into `childrenOf tree sid`, then `endSpan sp (utcToTimestamp <$> (s ^. #endedAt))` (line 57) — when `endedAt` is `Nothing` that argument is `Nothing` and the OTel SDK stamps the *current* time (bug 4). The walk has no visited set (bug 5): `childrenOf` returns every span whose `parent` equals the given id, so a self-parented span is its own child and `go` never returns. `genAiAttrs` (lines 88-97) inserts `SC.genAi_response_model` from `a ^. #model` — the request model (line 92, bug 3).
- `shikumi-trace-otel/src/Shikumi/Trace/LiveExport.hs` — `exportTreeWith :: MonadIO m => SpanProcessor -> Text -> TraceTree -> m ()` (lines 41-47): creates a `TracerProvider` around the given processor, makes a tracer, calls `exportTree`, then `shutdownTracerProvider` — sequentially, with no exception handling, so a throw from `exportTree` skips the shutdown (bug 1; the shutdown is what flushes the batch processor, so the live path also loses buffered spans). `exportTreeLive` builds the OTLP/HTTP exporter from `OTEL_*` env vars and delegates to `exportTreeWith`.
- `shikumi-trace-otel/test/Main.hs` — hermetic tests over `inMemoryListExporter` from `hs-opentelemetry-exporter-in-memory` (module `OpenTelemetry.Exporter.InMemory.Span`): it returns `(SpanProcessor, IORef [ImmutableSpan])`; ended spans are appended synchronously by the processor's `spanProcessorOnEnd`. The file already has `fixedTree` (five spans: a program root, two modules, two LM-call leaves, lines 114-126), a `node` builder, an `llmAttrs` fixture, and helpers `spanHasAttr` / `parentSpanId` that read a recorded span's mutable state via `readIORef (Otel.spanHot s)`.

Library facts you need (all verifiable in the hs-opentelemetry checkout registered with mori — run `mori registry list` and look for `iand675/hs-opentelemetry`; never search `/nix/store`):

- `SpanProcessor` (module `OpenTelemetry.Processor.Span`, re-exporting the record from the api package's `OpenTelemetry.Internal.Trace.Types`, lines 117-144) is a plain record: `spanProcessorOnStart :: ImmutableSpan -> Context -> IO ()`, `spanProcessorOnEnd :: ImmutableSpan -> IO ()`, `spanProcessorShutdown :: IO ShutdownResult`, `spanProcessorForceFlush :: IO FlushResult`. Being a record, a test can wrap one (e.g. make `onEnd` throw, or make `shutdown` tick an `IORef`) with ordinary record update.
- `SpanStatus` (in `OpenTelemetry.Trace.Core`) has constructors `Unset`, `Ok`, and `Error Text`, with the total order `Ok > Error > Unset` — `setStatus` keeps the maximum, so code must never set `Ok` on a span it might want to mark `Error`.
- A recorded `ImmutableSpan`'s live fields sit behind `Otel.spanHot :: ImmutableSpan -> IORef SpanHot`; `SpanHot` carries `hotAttributes` (already used by the existing tests), `hotStatus :: SpanStatus`, and `hotEnd`. If a `SpanHot` field accessor turns out not to be re-exported from `OpenTelemetry.Trace.Core`, import it from `OpenTelemetry.Internal.Trace.Types` (api package) — the existing test's use of `Otel.spanHot`/`Otel.hotAttributes` shows the pattern.

baikai response-JSON facts needed for status detection (source: the baikai checkout, `mori registry show baikai --full`): a `Response` serializes generically with keys `message`, `model`, `api`, `provider`, `responseId`, `latencyMs`, `errorInfo`; `errorInfo` is `null` on success (aeson default options do not omit `Nothing` fields). `message` contains `stopReason` (the tag for the error constructor is the string `"error"`) and `errorMessage` (`null` or a string). The echoed model is at `model.modelId`.


## Plan of Work

### Milestone 1: provider lifetime under `bracket`

Scope: `shikumi-trace-otel/src/Shikumi/Trace/LiveExport.hs` only. At the end, `exportTreeWith` shuts the provider down on every exit path, exceptional or not, and the exception still propagates to the caller.

Rewrite `exportTreeWith` (lines 41-47):

```haskell
-- | Build a 'TracerProvider' around the given processor, export the tree
-- through the shared 'exportTree' walker, then flush and shut the provider
-- down. The shutdown runs under 'bracket', so an exception thrown while
-- exporting still flushes buffered spans and releases the provider before
-- propagating to the caller.
exportTreeWith :: (MonadIO m) => SpanProcessor -> Text -> TraceTree -> m ()
exportTreeWith processor name tree =
  liftIO $
    bracket
      (Otel.createTracerProvider [processor] Otel.emptyTracerProviderOptions)
      (\tp -> Otel.shutdownTracerProvider tp Nothing)
      ( \tp -> do
          let tracer = Otel.makeTracer tp (fromString (T.unpack name)) Otel.tracerOptions
          exportTree tracer tree
      )
```

Add `import Control.Exception (bracket)` and extend the `Control.Monad.IO.Class` import with `liftIO`. `exportTreeLive` needs no change — it delegates.

Acceptance: package compiles; both existing tests still pass (`exportTreeWith` is exercised by the "recording processor" test).

### Milestone 2: the four walker fixes in `exportTree`

Scope: `shikumi-trace-otel/src/Shikumi/Trace/OpenTelemetry.hs`. All four fixes land in one coherent rewrite of `go` plus two helpers, because they touch the same ten lines.

Replace `exportTree`'s walker (lines 45-57) with a visited-set version that also computes status, honest end time, and the incomplete marker:

```haskell
exportTree :: (MonadIO m) => Otel.Tracer -> TraceTree -> m ()
exportTree tracer tree = liftIO (go Set.empty Context.empty (tree ^. #root) $> ())
  where
    smap = tree ^. #spans
    go visited ctx sid
      | Set.member sid visited = pure visited
      | otherwise = case Map.lookup sid smap of
          Nothing -> pure visited
          Just s -> do
            sp <- Otel.createSpan tracer ctx (s ^. #label) (argsFor s)
            Otel.addAttributes sp (attrsFor s)
            Otel.setStatus sp (statusFor s)
            let childCtx = Context.insertSpan sp Context.empty
                visited' = Set.insert sid visited
            visited'' <- foldM (\vs c -> go vs childCtx c) visited' (childrenOf tree sid)
            Otel.endSpan sp (Just (utcToTimestamp (endTimeOf s)))
            pure visited''
```

with imports `Data.Set qualified as Set`, `Control.Monad (foldM)`, `Data.Functor (($>))`, and these helpers in the same module:

```haskell
-- | The end instant to export. A span that never closed ('endedAt' =
-- 'Nothing' — the run crashed or the trace is truncated) is exported with its
-- own start time (zero duration) rather than the wall clock at export time,
-- which would fabricate an arbitrary duration; 'attrsFor' marks such spans
-- with @shikumi.incomplete@.
endTimeOf :: Span -> UTCTime
endTimeOf s = fromMaybe (s ^. #startedAt) (s ^. #endedAt)

-- | Status for an exported span: 'Otel.Error' when the recorded response
-- reports an in-band provider failure, 'Otel.Ok' otherwise. OTel's status
-- order is @Ok > Error > Unset@ (a status only ever increases), so 'Ok' must
-- be set only on spans that are definitely not errors.
statusFor :: Span -> Otel.SpanStatus
statusFor s
  | maybe False isErrorResponse (s ^. #attrs . #response) =
      Otel.Error "recorded response reports an in-band provider error"
  | otherwise = Otel.Ok

-- | Whether a recorded baikai response JSON reports failure: a non-null
-- top-level @errorInfo@, a @message.stopReason@ of @\"error\"@, or a non-null
-- @message.errorMessage@.
isErrorResponse :: Value -> Bool
isErrorResponse (Object o) =
  nonNull (KM.lookup "errorInfo" o) || messageErr (KM.lookup "message" o)
  where
    nonNull = maybe False (/= Null)
    messageErr (Just (Object m)) =
      KM.lookup "stopReason" m == Just (String "error")
        || nonNull (KM.lookup "errorMessage" m)
    messageErr _ = False
isErrorResponse _ = False

-- | The model the provider says actually answered, read from the recorded
-- response's echoed @model.modelId@. 'Nothing' when no response was recorded
-- or the field is absent — in which case @gen_ai.response.model@ is omitted
-- rather than guessed from the request.
responseModelOf :: SpanAttrs -> Maybe Text
responseModelOf a = do
  Object o <- a ^. #response
  Object m <- KM.lookup "model" o
  String mid <- KM.lookup "modelId" m
  pure mid
```

(New imports: `Data.Aeson (Value (..))`, `Data.Aeson.KeyMap qualified as KM`, `Data.Maybe (fromMaybe)`; `Span`, `SpanAttrs` are already imported from `Shikumi.Trace`. The `do`-block pattern matches in `responseModelOf` run in `Maybe`, whose `MonadFail` turns a mismatch into `Nothing`.)

Then two surgical edits:

- In `genAiAttrs` (lines 88-97), change the response-model line from `maybe id (AttrMap.insertByKey SC.genAi_response_model) (a ^. #model)` to `maybe id (AttrMap.insertByKey SC.genAi_response_model) (responseModelOf a)`. The request-model line (`SC.genAi_request_model` from `a ^. #model`) stays.
- In `attrsFor` (lines 71-84), add the incomplete marker to `base` — alongside `shikumi.span_kind`/`shikumi.retries`, insert `("shikumi.incomplete", Attr.toAttribute True)` when `(s ^. #endedAt) == Nothing` (e.g. build the base list conditionally: `[... ] <> [("shikumi.incomplete", Attr.toAttribute True) | (s ^. #endedAt) == Nothing]`).

Update the module haddock's attribute list to mention `shikumi.incomplete` and the response-model sourcing. Note the fixture consequence: `fixedTree`'s LM-call attrs in the test file carry no `response`, so after this milestone those spans export *without* `gen_ai.response.model` — the existing tests only assert `gen_ai.request.model`, so they stay green, and the new status test below adds a `response`-bearing fixture.

Acceptance: package compiles; the two existing tests pass unchanged.

### Milestone 3: the four new tests

Scope: `shikumi-trace-otel/test/Main.hs`. Each test is hermetic and deterministic. Add them to the top-level `testGroup` in `main`.

Test 1 — exception during export releases the provider (fails before M1: the shutdown ref stays `False`). Wrap the in-memory processor so `onEnd` throws and `shutdown` records:

```haskell
exceptionReleasesProviderTest :: TestTree
exceptionReleasesProviderTest =
  testCase "an exception during export still shuts the provider down" $ do
    (proc0, _spansRef :: IORef [Otel.ImmutableSpan]) <- inMemoryListExporter
    shutRef <- newIORef False
    let boom = userError "onEnd exploded"
        proc' =
          proc0
            { spanProcessorOnEnd = \_ -> throwIO boom,
              spanProcessorShutdown = writeIORef shutRef True >> spanProcessorShutdown proc0
            }
    r <- try (exportTreeWith proc' "shikumi-exc-test" fixedTree)
    case r of
      Left (e :: SomeException) -> pure ()  -- the export failure propagated
      Right () -> assertFailure "expected the onEnd exception to propagate"
    wasShut <- readIORef shutRef
    assertBool "provider shutdown ran despite the exception" wasShut
```

(Imports: `Control.Exception (SomeException, throwIO, try)`, `Data.IORef (newIORef, writeIORef)`, `OpenTelemetry.Processor.Span (SpanProcessor (..))`. `spanProcessorOnEnd` runs synchronously inside `endSpan` for a simple processor, which is why the throw surfaces inside `exportTree`.)

Test 2 — status propagation (fails before M2: every status is `Ok`). Build a variant of `fixedTree` where one LM-call span's attrs carry an error response and the other a success response:

```haskell
errorResponseAttrs :: SpanAttrs
errorResponseAttrs =
  llmAttrs
    { response =
        Just
          ( object
              [ "errorInfo" .= object ["category" .= ("overloaded" :: Text)],
                "message" .= object ["stopReason" .= ("error" :: Text)]
              ]
          )
    }

okResponseAttrs :: SpanAttrs
okResponseAttrs =
  llmAttrs
    { response =
        Just
          ( object
              [ "errorInfo" .= Null,
                "message" .= object ["stopReason" .= ("stop" :: Text), "errorMessage" .= Null],
                "model" .= object ["modelId" .= ("claude-sonnet-4-6-20250929" :: Text)]
              ]
          )
    }
```

Export with `newTracerWithInMemory`, then for each recorded LM-call span read `hotStatus <$> readIORef (Otel.spanHot s)` and assert the error one matches `Otel.Error _` and the success one is `Otel.Ok`. In the same test, assert the success span's attributes now contain `gen_ai.response.model` (it has a recorded `model.modelId`) while the error span (no `model` key in its response) does not — locking bug 3's fix and its omit-don't-guess behavior together.

Test 3 — open-span handling (fails before M2: no `shikumi.incomplete`, end stamped at export time). Build a `fixedTree` variant where one module span has `endedAt = Nothing` (adjust the `node` helper or override the record after building). Export; assert all five spans were emitted, the open one has attribute `shikumi.incomplete`, and (via `hotEnd` / the recorded end timestamp) its end equals its start rather than a 2026-07 export-time value — comparing against `utcToTimestamp` of the fixture start; if timestamp plumbing is awkward, the attribute plus "emitted at all" are the required assertions and the end-time equality is the preferred stronger one.

Test 4 — cyclic tree terminates (before M2 this recurses forever, so guard with a timeout to keep the failure finite):

```haskell
cyclicTreeTest :: TestTree
cyclicTreeTest =
  testCase "a corrupt self-parented tree exports finitely" $ do
    (tracer, getSpans) <- newTracerWithInMemory
    let cyclic =
          TraceTree
            { root = SpanId "s0",
              spans =
                Map.fromList
                  [ (SpanId "s0", node "s0" Nothing ProgramSpan "root" emptyAttrs 0),
                    -- s1 is its own parent: childrenOf yields s1 under s1.
                    (SpanId "s1", node "s1" (Just "s1") ModuleSpan "ouroboros" emptyAttrs 1)
                  ]
            }
    r <- timeout 5_000_000 (exportTree tracer cyclic)
    r @?= Just ()
    emitted <- getSpans
    assertBool "each span exported at most once" (length emitted <= 2)
```

(Imports: `System.Timeout (timeout)`; enable `NumericUnderscores` or write `5000000`. Note `s1` is unreachable from `s0` — its cycle is only entered via `childrenOf` if the walk reaches it, so *also* add a second cyclic fixture where the root itself is self-parented (`node "s0" (Just "s0") ...`): the walk starts at the root, `childrenOf` returns the root as its own child, and only the visited set stops it. Assert the same termination and at-most-once property there.)

Acceptance: `just test-one shikumi-trace-otel` runs six tests (two existing, four new), all green; temporarily reverting M1 makes test 1 fail on the shutdown assertion, and reverting M2 makes tests 2-4 fail (test 4 by timeout).


## Concrete Steps

From the repository root:

```bash
nix develop .#ghc9124
cabal build shikumi-trace-otel
just test-one shikumi-trace-otel
```

Expected final output shape:

```text
shikumi-trace-otel
  exportTree emits nested spans with GenAI attributes:                  OK
  exportTreeWith (recording processor) preserves nesting and node attrs: OK
  an exception during export still shuts the provider down:            OK
  error responses export as status Error; response model is honest:    OK
  a never-closed span exports as incomplete with zero duration:        OK
  a corrupt self-parented tree exports finitely:                       OK

All 6 tests passed
```

No services are needed; everything is in-process (the OTLP live path is exercised structurally through `exportTreeWith`, which is the same code path minus the network — see the comment on the existing `liveExportInMemoryTest`).

Commit per milestone with conventional-commit subjects (e.g. `fix(trace-otel): bracket the tracer provider around export`, `fix(trace-otel): honest status, response model, open spans, and cycle guard`, `test(trace-otel): cover export failure, status, open spans, cycles`), each carrying:

```text
MasterPlan: docs/masterplans/7-cache-trace-and-replay-hardening.md
ExecPlan: docs/plans/43-otel-export-correctness-tail.md
Intention: intention_01kwgdyxm7ehh8yys1pp4wf1zr
```


## Validation and Acceptance

Each numbered bug maps to one observable behavior, all checked by `just test-one shikumi-trace-otel`:

1. With a processor whose `onEnd` throws, `exportTreeWith` propagates the exception *and* the processor's `shutdown` has run (IORef witness). Before: shutdown never ran.
2. An LM-call span whose recorded response has non-null `errorInfo` (or `stopReason "error"`) exports with `SpanStatus` `Error _`; a success span exports `Ok`. Before: both `Ok`.
3. `gen_ai.response.model` equals the recorded response's `model.modelId` (`claude-sonnet-4-6-20250929` in the fixture, deliberately different from the request's `claude-sonnet-4-6`) and is absent when the response records no model. Before: always a copy of the request model.
4. A span with `endedAt = Nothing` exports with attribute `shikumi.incomplete` and end time equal to its start. Before: no marker, end time = wall clock at export.
5. Exporting a tree containing a self-parented span returns within the 5-second timeout with each span emitted at most once. Before: the test times out (infinite recursion).

Also re-run the two pre-existing tests: nesting, trace-id sharing, and GenAI request-model attributes must be byte-for-byte unaffected.


## Idempotence and Recovery

All steps are source edits with deterministic in-process tests; repeat freely. The only behavioral risk is the status-order trap: if a future edit reorders `setStatus` calls so `Ok` is set before the error determination, OTel's `Ok > Error` maximum makes the error unrecordable — the status test exists precisely to catch that regression, so do not weaken it. If `hotStatus`/`hotEnd` accessors are not exported where expected, the recovery path is importing from the api package's `OpenTelemetry.Internal.Trace.Types` (already an established pattern in this test file via `spanHot`); record whichever import was needed in Surprises & Discoveries.


## Interfaces and Dependencies

Dependencies are unchanged: `hs-opentelemetry-api` / `-sdk` (tracer, processor, span core), `hs-opentelemetry-exporter-in-memory` (tests), `aeson`, `containers` (`Data.Set` may need adding to the library's `build-depends` in `shikumi-trace-otel/shikumi-trace-otel.cabal` if not present — check), `shikumi-trace` (the `TraceTree`/`Span` types, consumed read-only). This plan must not modify anything in `shikumi-trace`; if the multi-root rendering work from `docs/plans/42-replay-divergence-detection-and-trace-concurrency-safety.md` lands first, note that `exportTree` still walks from `tree ^. #root` only — aligning the exporter with multi-root trees is explicitly out of scope here (record it in the master plan's Surprises section if it matters in practice).

Public signatures, unchanged in shape:

```haskell
-- shikumi-trace-otel, module Shikumi.Trace.OpenTelemetry
exportTree :: (MonadIO m) => Otel.Tracer -> TraceTree -> m ()

-- shikumi-trace-otel, module Shikumi.Trace.LiveExport
exportTreeWith :: (MonadIO m) => SpanProcessor -> Text -> TraceTree -> m ()
exportTreeLive :: (MonadIO m) => Text -> TraceTree -> m ()
```

New internal helpers (not necessarily exported): `endTimeOf :: Span -> UTCTime`, `statusFor :: Span -> Otel.SpanStatus`, `isErrorResponse :: Value -> Bool`, `responseModelOf :: SpanAttrs -> Maybe Text`.
