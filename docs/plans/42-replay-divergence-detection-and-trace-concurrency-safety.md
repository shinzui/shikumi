---
id: 42
slug: replay-divergence-detection-and-trace-concurrency-safety
title: "Replay Divergence Detection and Trace Concurrency Safety"
kind: exec-plan
created_at: 2026-07-02T03:30:16Z
intention: "intention_01kwjfeamsehst07eh4n7kp8a7"
master_plan: "docs/masterplans/7-cache-trace-and-replay-hardening.md"
---

# Replay Divergence Detection and Trace Concurrency Safety

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

Ordering prerequisite (hard): `docs/plans/40-cache-key-v2-endpoint-completeness.md` must be complete before this plan starts. Both plans revolve around the content-addressed cache key computed by `Shikumi.Cache.Key.cacheKey`; plan 40 changes its field set and bumps its namespace version, which changes every digest — including the golden digest pinned in this package's tests and every key this plan's new fixtures will compute. Every test written here must be written against the post-bump (v2) key function, or it will be invalidated the moment plan 40 lands.


## Purpose / Big Picture

shikumi-trace promises "fail-closed and loud" offline replay: re-run a program against a recorded trace and either reproduce it exactly or raise a typed `ReplayDivergence`. Today that promise has a hole and the trace builder has a safety gap, plus a tail of smaller fidelity bugs.

The hole: the replay index is a plain `Map` from cache key to recorded response, built with `Map.fromList` over all LM-call spans. When one recorded run contains *several* calls with the same key — which happens routinely: a `majorityVote k (TempFixed [])` program sends k byte-identical requests, and any rerun at temperature > 0 sends identical requests that got different answers — the map silently keeps a single winner and replay serves that one response for every occurrence. Which winner is even accidental: spans enumerate in the text ordering of their ids, where `"span-10" < "span-2"`. Nothing fails, nothing warns; replay just fabricates a run that never happened. After this plan, building a replay index from a trace with conflicting duplicates fails closed with a message naming the key, and duplicates whose recorded responses are identical (the benign majority-vote case) replay fine.

The safety gap: `runTrace` keeps its span stack and span map in `IORef`s mutated with non-atomic `modifyIORef'`. Compose `tracedLLM` with `runProgramConc` (the concurrent program executor) and concurrent effect sends interleave those read-modify-writes: spans vanish, the stack pops the wrong frame, the resulting tree is silently wrong. After this plan, all trace-state mutation is atomic and the span stack detects corruption loudly (closing a span verifies it is popping itself), and the documentation states plainly that `runTrace` supports sequential execution only.

The tail, folded in because each is a small trace-fidelity fix in the same package: a second top-level span is silently absent from rendering; `shikumi.retries` is always 0 because nothing ever calls `bumpRetry`; sibling ordering breaks at ten children when timestamps tie (same text-ordering bug as above); and trace files written before the v2 format bump are rejected even though v2 was additive.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] 2026-07-03: Confirm plan 40 is Complete (v2 key landed; both pinned digests updated)
- [x] 2026-07-03: M1: `replayIndex` returns `Either Text (Map CacheKey Value)`; equal duplicates dedupe, conflicting duplicates fail closed
- [x] 2026-07-03: M1: all four call sites updated (Demo, jitsurei TraceReplay, cli Runtime, trace tests); duplicate-key tests added
- [x] 2026-07-03: M2: all `TraceState` mutations atomic; `closeSpan` verifies its pop; concurrency contract documented on `runTrace` and `runCurrentNode`
- [x] 2026-07-03: M3: `renderTree` renders every parentless root (forest)
- [x] 2026-07-03: M3: `runProgramTraced` bumps retries on re-attempts; retry-count test with a fail-once stub
- [x] 2026-07-03: M3: `childrenOf` numeric sibling ordering; ≥10-siblings test
- [x] 2026-07-03: M3: `readTraceFile` accepts formatVersion 1..current; v1-acceptance test
- [x] 2026-07-03: Full suite green: `just test-one shikumi-trace` (27 tests) and `cabal build shikumi-jitsurei shikumi-cli`


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: On duplicate cache keys in a trace, dedupe when all recorded responses are equal and fail closed (`Left`) when they conflict, by changing `replayIndex`'s type to `Either Text (Map CacheKey Value)`. The alternative — indexing by `(key, occurrence)` and having the replay interpreter count occurrences per key — was rejected.
  Rationale: Occurrence-indexed replay would make replay order-sensitive in a way live execution is not (`runProgramConc` completes calls in nondeterministic order, so "the third occurrence" is not well-defined across runs), and it papers over the real situation: a run whose identical requests received different answers is not deterministically reproducible, and pretending otherwise violates the package's fail-closed contract. Failing at index-build time (not mid-replay) gives the user the earliest, clearest signal. Equal-response duplicates lose no information when collapsed, so the common `majorityVote k (TempFixed [])` + deterministic-stub case keeps working.
  Source: production-readiness code review; verified against `Shikumi.Trace.Store.replayIndex` and `Shikumi.Program` sampling semantics.
  Date: 2026-07-01

- Decision: For concurrency, harden rather than redesign: make every `TraceState` mutation atomic (no torn map updates), make `closeSpan` verify LIFO discipline and `error` loudly on violation, and document that `runTrace`/`tracedLLM`/`runCurrentNode` support sequential execution only (`runProgram`, not `runProgramConc`). A per-thread span-stack redesign is future work, recorded here so it is not forgotten.
  Rationale: Correct concurrent tree-building needs per-task stacks threaded through fork points — a redesign of `runTrace` and both capture interposers, out of proportion to this hardening plan. Atomic ops plus the LIFO check convert "silently wrong tree" into either a correct tree or an immediate, explicit failure, which is the contract this initiative demands.
  Date: 2026-07-01

- Decision: `readTraceFile` accepts formatVersions 1 through `currentFormatVersion` (2), rejecting others; the v1→v2 bump was additive (optional `nodePath`), so v1 files decode with `nodePath = Nothing`.
  Rationale: Fail-closed is for files we cannot understand; v1 files are fully understood. Rejecting them destroyed users' recorded traces on upgrade for no integrity gain. Future *non*-additive bumps should raise the new `minSupportedFormatVersion` in the same commit that breaks the schema.
  Date: 2026-07-01

- Decision: Fix sibling ordering by parsing the numeric suffix of `span-N` ids as a tie-break in `childrenOf`, instead of zero-padding ids or adding a sequence field to `Span`.
  Rationale: Zero-padding changes every recorded span id (a format-visible change); a new `Span` field forces a format bump and touches serialization. The numeric tie-break is read-side only, works for every existing file, and degrades to the old behavior for non-`span-N` ids.
  Date: 2026-07-01


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

2026-07-03: EP-42 is complete. Replay index construction now fails closed on conflicting duplicate cache keys while preserving deterministic duplicate calls with equal responses; all replay callers handle index-build errors explicitly. Trace-state writes are atomic and span closing verifies LIFO stack discipline, converting unsupported concurrent tracing into a loud failure instead of silent corruption. The fidelity tail is fixed: `renderTree` renders every parentless root, traced retry combinators increment `shikumi.retries`, sibling ordering uses numeric `span-N` ordering when timestamps tie, and additive formatVersion 1 trace files read successfully. Validation passed with `just test-one shikumi-trace` (27 tests) and `cabal build shikumi-jitsurei shikumi-cli`.


## Context and Orientation

This repository is a cabal multi-package Haskell project; work inside the Nix dev shell (`nix develop .#ghc9124` from the repo root) and run one package's tests with `just test-one shikumi-trace`.

The trace system, by file:

- `shikumi-trace/src/Shikumi/Trace.hs` — span types and the builder. A `Span` has a `SpanId` (a newtype over `Text`, values like `"span-7"`, allocated sequentially by the interpreter; its `Ord` is *textual*, so `"span-10" < "span-2"` — lines 104-107), a `parent`, a `SpanKind` (`ProgramSpan`/`ModuleSpan`/`CombinatorSpan`/`LlmCallSpan`), timestamps, and a `SpanAttrs` bag; an LM-call span's attrs carry the request's cache key (as text) and the recorded response JSON. A `TraceTree` is `{ root :: SpanId, spans :: Map SpanId Span }`. `runTrace` (lines 249-267) interprets the `Trace` effect against a `TraceState` of four `IORef`s (lines 234-241): a counter (already mutated with `atomicModifyIORef'`, line 278), a stack of open span ids, the span map, and the root. `openSpan` (276-288) pushes with plain `modifyIORef'` and records the *first* parentless span as root (line 286: `modifyIORef' (st ^. #root) (Just . fromMaybe sid)` keeps the existing value) — a second top-level span is stored in the map but never becomes reachable from `root`. `closeSpan` (291-295) stamps `endedAt` and pops with `modifyIORef' ... (drop 1)`, trusting blindly that the top of stack is the span being closed. `modifyActive` (298-303) read-then-modifies. None of this is atomic except the counter. `childrenOf` (187-192) sorts siblings by `(startedAt, spanId)` — with equal timestamps (coarse clocks, fast spans) ten-or-more siblings render as `span-1, span-10, span-11, span-2, …`. `renderTree` (365-395) walks only from `t ^. #root`. `bumpRetry` (217-219) increments the active span's `retries` attr — grep the workspace: no executor ever sends it, so exported retry counts are always 0.
- `shikumi-trace/src/Shikumi/Trace/Store.hs` — persistence and the replay index. `TraceFile` wraps a `formatVersion :: Int` plus the tree; `currentFormatVersion = 2` (lines 49-52; bumped from 1 when the additive, *optional* `SpanAttrs.nodePath` field arrived). `readTraceFile` (62-78) rejects any `formatVersion /= currentFormatVersion` — including 1, which decodes perfectly well since a missing optional field parses as `Nothing`. `replayIndex` (83-91) is the `Map.fromList` described in Purpose; note `Map.elems (spans t)` yields spans in ascending *textual* `SpanId` order, and `Map.fromList` keeps the last of duplicate keys, so the "winner" among duplicates is the textually greatest span id.
- `shikumi-trace/src/Shikumi/Trace/Replay.hs` — `runLLMReplay` (62-75) interprets the `LLM` effect by recomputing each request's cache key and looking it up in the index; a missing key raises the typed exception `ReplayDivergence` (44-53). It has no notion of occurrences; with today's index it happily serves one response for five identical calls that recorded five different answers.
- `shikumi-trace/src/Shikumi/Trace/Program.hs` — the node-correlated executor. `runCurrentNode` (113-126) holds the current node path in an `IORef` with non-atomic read/write pairs (same concurrency caveat as `TraceState`). `runProgramTraced`'s `Retry`/`RetryWhen` cases (174-177) delegate to `Shikumi.Program.retryWith` without ever calling `bumpRetry`.
- Duplicate keys in real programs: `shikumi/src/Shikumi/Program.hs` lines 269-270 (`runProgram (MajorityVote k sched p)`) run k samples; `sampleTemps` (lines 344-348) with `TempFixed []` yields `replicate k Nothing`, and a `Nothing` sample temperature leaves the request byte-identical — so all k calls share one cache key by construction.
- `replayIndex` call sites, all of which change type in M1: `shikumi-trace/src/Shikumi/Trace/Demo.hs:136`, `shikumi-jitsurei/app/TraceReplay.hs:96`, `shikumi-cli/src/Shikumi/Cli/Runtime.hs:83` (inside `runReplayProgram`), and `shikumi-trace/test/Main.hs` lines 180, 213, 230, 263.
- Tests: `shikumi-trace/test/Main.hs`. It has stub-LLM fixtures in `shikumi-trace/test/TraceFixtures.hs` (`runFixedLLM`, `runKeyedCountingLLM`, `stubModel`, `ctxFor`, `optsFor`, `mkResponse`), Cell-typed program fixtures (`chain2`, `cellSig`, `cellResp` around lines 407-428), the store round-trip generator, and the pinned key at line 305 (updated by plan 40).

Term: "fail closed" means refusing to proceed with an explicit error rather than continuing with possibly-wrong data.


## Plan of Work

### Milestone 1: the replay index fails closed on conflicting duplicates

Scope: `shikumi-trace/src/Shikumi/Trace/Store.hs`, its four call sites, and new tests. At the end, `replayIndex` has type `TraceTree -> Either Text (Map CacheKey Value)`; a conflicting-duplicate tree produces a `Left` naming the key and the span ids involved; the trace suite covers both duplicate flavors.

Rewrite `replayIndex` (Store.hs lines 83-91). Collect per-key occurrences, then validate:

```haskell
-- | The replay index: every LM-call span's content-addressed key mapped to its
-- recorded response JSON. A span missing either its @cacheKey@ or its
-- @response@ contributes nothing. Duplicate keys are legal only when every
-- occurrence recorded the __same__ response (e.g. a @majorityVote@ over
-- byte-identical requests answered by a deterministic stub); duplicates with
-- differing responses mean the run is not deterministically reproducible, and
-- the index refuses to build ('Left') rather than silently electing a winner.
replayIndex :: TraceTree -> Either Text (Map CacheKey Value)
replayIndex t =
  case conflicts of
    [] -> Right (Map.map (snd . NE.head) grouped')
    cs -> Left (T.intercalate "; " (map describe cs))
  where
    occurrences =
      [ (CacheKey ck, (s ^. #spanId, v))
      | s <- Map.elems (spans t),
        (s ^. #kind) == LlmCallSpan,
        Just ck <- [s ^. #attrs . #cacheKey],
        Just v <- [s ^. #attrs . #response]
      ]
    grouped' = Map.fromListWith (<>) [(k, NE.singleton sv) | (k, sv) <- occurrences]
    conflicts =
      [ (k, NE.toList svs)
      | (k, svs) <- Map.toList grouped',
        length (NE.nub (fmap snd svs)) > 1
      ]
    describe (CacheKey k, svs) =
      "replay index conflict: cache key "
        <> k
        <> " was recorded with differing responses by spans "
        <> T.intercalate ", " [sid | (SpanId sid, _) <- svs]
```

(Imports to add: `Data.List.NonEmpty qualified as NE`, and `SpanId (..)` alongside the existing `Shikumi.Trace` import. `NE.nub` needs `Eq Value` — aeson provides it.)

Update the call sites. Each already sits next to `readTraceFile`'s `Either Text` handling, so extend the same failure path:

- `shikumi-trace/src/Shikumi/Trace/Demo.hs:136` (`replayMode`): replace `let idx = replayIndex tree` with a `case`; on `Left err` print `"replay index error: " <> err` (mirroring the `trace load error` branch four lines up) and return.
- `shikumi-jitsurei/app/TraceReplay.hs:96`: the surrounding `case loaded of` already prints on `Left`; nest a second `case replayIndex tree' of` with a `Left err -> TIO.putStrLn ("[replay] index error: " <> err)` arm.
- `shikumi-cli/src/Shikumi/Cli/Runtime.hs:83` (`runReplayProgram`): the function returns `IO (Either ShikumiError o)`. Pattern-match first; on `Left err` surface it through the function's existing error type — inspect `Shikumi.Error.ShikumiError`'s constructors and use the one for malformed input (there is a constructor used for trace/parse problems; if none fits, `error . T.unpack` is *not* acceptable here — extend the `case` so the CLI prints the message and exits nonzero along whatever path `readTraceFile`'s `Left` takes in the calling code, `shikumi-cli`'s command handler).
- `shikumi-trace/test/Main.hs` lines 180, 213, 230, 263: these operate on traces with distinct keys, so unwrap with an explicit pattern: `let Right idx = replayIndex tree'` becomes a `case`/`either (assertFailure . T.unpack) pure` — prefer the latter so a regression yields a readable test failure.

New tests, in `shikumi-trace/test/Main.hs` under the `storeTests` group. Both build trees by hand exactly like the suite's existing `flattenShape` fixtures — a root `ProgramSpan` plus LM-call children whose `attrs` set `cacheKey` and `response` directly (no LLM run needed, so these are format-level tests independent of the key function; the *end-to-end* duplicate case below exercises the real keys):

1. "duplicate keys with equal responses dedupe": two `LlmCallSpan`s, same `cacheKey = Just "k"`, same `response = Just (object ["text" .= "same"])` → `replayIndex` is `Right` with `Map.size == 1`.
2. "duplicate keys with conflicting responses fail closed": same but the responses differ → `Left err` where `err` mentions `"k"` and both span ids. This test fails before this milestone (the old code returned a silent winner) — port it by writing it first against the old signature if you want to watch it fail.
3. End-to-end majority-vote replay (uses real v2 keys): run `majorityVote 3 (TempFixed []) (predict cellSig)` (fixtures `cellSig`/`cellResp` already exist in this file; run it under `runTrace . runFixedLLM cellResp . tracedLLM` with `runErrorNoCallStack @ShikumiError`, mirroring `runTraced` at lines 444-454 but with the plain `tracedLLM` capture) — the trace has three LM-call spans sharing one key with equal responses; assert `replayIndex` is `Right` and `runLLMReplay` over it reproduces the live output. This is the benign case that must keep working.

Acceptance: `just test-one shikumi-trace` green; `cabal build shikumi-jitsurei shikumi-cli shikumi-trace` green (proves all call sites updated).

### Milestone 2: atomic trace state and a loud LIFO check

Scope: `shikumi-trace/src/Shikumi/Trace.hs` (and a documentation touch in `Trace/Program.hs`). At the end, no `TraceState` mutation can be torn by a concurrent send, and a stack-discipline violation aborts with a named error instead of corrupting silently.

In `Trace.hs`, replace every `modifyIORef'` on `TraceState` fields with `atomicModifyIORef'` (the module already imports it for the counter). Concretely: `openSpan`'s span-map insert and stack push (lines 283-284) and root recording (286); `closeSpan`'s `endedAt` stamp (294); `modifyActive`'s attr update (302). For `modifyActive`, fold the read of the stack and the map update into a shape that reads the stack once (the stack read itself can stay `readIORef` — the hazard is torn *writes*):

```haskell
modifyActive st f = do
  stk <- readIORef (st ^. #stack)
  case stk of
    (sid : _) -> atomicModifyIORef' (st ^. #spans) (\m -> (m & ix sid . #attrs %~ f, ()))
    [] -> pure ()
```

Rewrite `closeSpan` (lines 291-295) to pop-and-verify:

```haskell
-- | Close a span: stamp its 'endedAt' and pop it off the stack. The pop is
-- verified: 'withSpan' brackets guarantee LIFO close order in sequential
-- execution, so popping anything other than the span being closed means the
-- interpreter's state was mutated concurrently (e.g. 'tracedLLM' composed
-- with 'runProgramConc'), which 'runTrace' does not support. Fail loudly
-- rather than record a silently wrong tree.
closeSpan :: (Prim :> es, Time :> es) => TraceState -> SpanId -> Eff es ()
closeSpan st sid = do
  now <- getCurrentTime
  atomicModifyIORef' (st ^. #spans) (\m -> (m & ix sid . #endedAt ?~ now, ()))
  popped <- atomicModifyIORef' (st ^. #stack) $ \case
    (top : rest) -> (rest, Just top)
    [] -> ([], Nothing)
  case popped of
    Just top | top == sid -> pure ()
    _ ->
      error
        ( "Shikumi.Trace.runTrace: span stack corrupted (closing "
            <> show sid
            <> " but popped "
            <> show popped
            <> "). runTrace supports sequential execution only; do not compose "
            <> "tracedLLM/tracedNodeLLM with runProgramConc."
        )
```

Document the contract in three haddocks: `runTrace` (state the sequential-only contract and that violations now fail loudly), `tracedLLM`, and `runCurrentNode` in `shikumi-trace/src/Shikumi/Trace/Program.hs` (its `IORef` cell has the same single-threaded assumption; a concurrent `localNode` would mis-scope node paths — say so).

There is deliberately no concurrency test here: a test that races `runProgramConc` under `runTrace` is nondeterministic by nature (it may pass by luck), and this suite stays deterministic. Acceptance is: the whole existing suite still green (sequential behavior unchanged — every existing test exercises the rewritten push/pop on every span), plus the documented contract. Record in Surprises anything the suite reveals.

### Milestone 3: the fidelity tail

Scope: `Trace.hs`, `Trace/Program.hs`, `Store.hs`, tests. Four independent fixes, each with a test that fails before and passes after.

(a) Render every root. In `renderTree` (Trace.hs 365-395), instead of walking only `t ^. #root`, compute all parentless spans and render each as a top-level tree, in start order with the same tie-break as (c) below:

```haskell
renderTree t
  | Map.null (t ^. #spans) = "(empty trace)\n"
  | otherwise = T.concat (concatMap (go 0) roots)
  where
    roots =
      map (^. #spanId) $
        sortOn (\s -> (s ^. #startedAt, spanOrdKey (s ^. #spanId))) $
          [s | s <- Map.elems (t ^. #spans), (s ^. #parent) == Nothing]
```

(`go` is unchanged.) `TraceTree.root` keeps meaning "the first root" — no format change. Test: run two *sequential* top-level `withSpan ProgramSpan` blocks under one `runTrace` (no nesting), then assert `renderTree` output contains both labels; before the fix the second label is absent.

(b) Live retry counts. In `Trace/Program.hs`, replace the `Retry`/`RetryWhen` delegation (lines 174-177) with a local loop that mirrors `Shikumi.Program.retryWith` (whose source is at `shikumi/src/Shikumi/Program.hs`, lines 382-394: try, and on an error matching the predicate with attempts left, rerun) but sends `bumpRetry` before each re-attempt, so the count lands on the open `Retry`/`RetryWhen` combinator span:

```haskell
go prefix (Retry n p) i =
  withSpan CombinatorSpan "Retry" (tracedRetry (go (StepRetry : prefix)) (const True) n p i)
go prefix (RetryWhen ok n p) i =
  withSpan CombinatorSpan "RetryWhen" (tracedRetry (go (StepRetryWhen : prefix)) ok n p i)
```

```haskell
-- | 'Shikumi.Program.retryWith', plus a 'bumpRetry' before every re-attempt so
-- the enclosing combinator span's @shikumi.retries@ reflects reality.
tracedRetry ::
  (Trace :> es, Error ShikumiError :> es) =>
  (Program x y -> x -> Eff es y) ->
  (ShikumiError -> Bool) ->
  Int ->
  Program x y ->
  x ->
  Eff es y
tracedRetry run ok n p i = attempt (max 1 n)
  where
    attempt left =
      run p i `catchError` \_cs e ->
        if ok e && left > 1
          then bumpRetry >> attempt (left - 1)
          else throwError e
```

(Imports: `bumpRetry` from `Shikumi.Trace`; `catchError`, `throwError` from `Effectful.Error.Static`; drop the now-unused `retryWith` import.) Test, in `shikumi-trace/test/Main.hs` next to `correlateTests`: add a sequenced stub to `TraceFixtures.hs` — `runSequencedLLM :: IORef [Response] -> Eff (LLM : es) a -> Eff es a` that pops and returns the head on each `Complete` (reuse `runFixedLLM` as the template) — then run `Retry 2 (predict cellSig)` (the `Retry` constructor is importable from `Shikumi.Program`; `predict`/`cellSig`/`cellResp` already exist here) with responses `[mkResponse "unparseable", cellResp]`. The first response fails the Cell parse, `tracedRetry` bumps and retries, the second succeeds. Assert the result is `Cell "echoed"` and the span labeled `"Retry"` has `retries == 1` (find it via `Map.elems (spans tree)`); before this fix it is 0.

(c) Numeric sibling ordering. In `Trace.hs`, give `childrenOf` (187-192) a numeric-aware key and export nothing new:

```haskell
-- | Order key for a span id: ids of the interpreter's @span-N@ shape order by
-- N; anything else keeps plain text order (and sorts before numbered ids only
-- by the Maybe ordering, deterministically).
spanOrdKey :: SpanId -> (Maybe Int, Text)
spanOrdKey (SpanId t) = (T.stripPrefix "span-" t >>= readMaybe . T.unpack, t)
```

and sort with `sortOn (\s -> (s ^. #startedAt, spanOrdKey (s ^. #spanId)))` (import `Text.Read (readMaybe)`). Test: hand-build a tree (reuse the `flattenShape` helpers or inline construction) with one root and eleven children `span-2` … `span-12` all sharing one `startedAt`; assert `childrenOf` returns them in numeric order — before the fix, `span-10`, `span-11`, `span-12` sort between `span-1x`-free neighbors (`span-2` comes after them textually).

(d) Accept v1 trace files. In `Store.hs`, add next to `currentFormatVersion`:

```haskell
-- | The oldest trace formatVersion this build still reads. v1→v2 was additive
-- (the optional @SpanAttrs.nodePath@), so v1 files decode with the field
-- absent. Raise this in the same commit as any non-additive schema break.
minSupportedFormatVersion :: Int
minSupportedFormatVersion = 1
```

and change `readTraceFile`'s guard (line 70) to reject only when `formatVersion tf < minSupportedFormatVersion || formatVersion tf > currentFormatVersion`, with the error message stating the supported range (e.g. `"unsupported trace formatVersion 999 (supported: 1..2)"`). Export `minSupportedFormatVersion`. Test: encode `TraceFile 1 tree` (for a tree built by `buildTree`, whose spans carry no `nodePath`) with `BL.writeFile` exactly as the existing foreign-version test does, and assert `readTraceFile` returns `Right`; keep the existing 999-rejection test (update its expected message for the new wording — it asserts the message contains `"999"`, which still holds).


## Concrete Steps

From the repository root, inside the dev shell:

```bash
nix develop .#ghc9124
cabal build shikumi-trace
just test-one shikumi-trace
```

After M1, also prove the downstream consumers compile:

```bash
cabal build shikumi-jitsurei shikumi-cli
```

Expected new-test lines in the tasty output when done:

```text
shikumi-trace
  store
    duplicate keys with equal responses dedupe:            OK
    duplicate keys with conflicting responses fail closed: OK
    majorityVote over identical requests replays:          OK
    reading a formatVersion 1 file succeeds:               OK
  tree
    renderTree shows every top-level root:                 OK
    childrenOf orders 10+ siblings numerically:            OK
  correlate
    Retry re-attempts are counted on the Retry span:       OK
```

Commit per milestone with conventional-commit subjects (e.g. `fix(trace): fail closed on conflicting duplicate keys in replayIndex`, `fix(trace): atomic span state and loud LIFO check in runTrace`, `feat(trace): render all roots, count retries, order siblings numerically, accept v1 files`), each with the trailers:

```text
MasterPlan: docs/masterplans/7-cache-trace-and-replay-hardening.md
ExecPlan: docs/plans/42-replay-divergence-detection-and-trace-concurrency-safety.md
Intention: intention_01kwjfeamsehst07eh4n7kp8a7
```


## Validation and Acceptance

Observable acceptance, each phrased as behavior with inputs and outputs:

1. Feed `replayIndex` a tree containing two LM-call spans with the same `cacheKey` and different `response` values: the result is `Left` and the message contains the key text and both span ids. Before this plan the result was a `Map` silently containing the response of the textually-greatest span id.
2. Run `majorityVote 3 (TempFixed []) (predict cellSig)` live under `tracedLLM` with a deterministic stub, build the index, replay: `Right` index, replay output equals live output, zero provider calls (the counting stub's `IORef` stays 0 during replay).
3. `renderTree` of a trace with two sequential top-level spans shows both subtrees. Before, the second was absent from the output entirely.
4. A `Retry 2` program whose first attempt fails to parse shows `retries = 1` on its `"Retry"` span. Before, 0.
5. `childrenOf` on eleven equal-timestamp siblings returns `span-2 … span-12` in numeric order. Before, `span-10/11/12` sorted before `span-2`.
6. A trace file with `formatVersion: 1` reads back `Right`; `formatVersion: 999` still reads back `Left` mentioning `999`.
7. The whole prior suite (spike/tree/store/replay/e2e/node/correlate/feedback groups) is green, proving sequential tracing semantics are unchanged by the atomicity work.

All are checked by `just test-one shikumi-trace`; item 1's "before" behavior can be witnessed by writing the test first.


## Idempotence and Recovery

Everything is source edits plus deterministic tests; rerun freely. The `replayIndex` signature change is find-the-compiler-errors mechanical — if a call site is missed, `cabal build shikumi-trace shikumi-jitsurei shikumi-cli` names it. The loud `closeSpan` check cannot fire for sequential programs (every existing test doubles as a regression witness); if it ever fires in legitimate sequential use, that is a real bug in the bracket discipline — capture it in Surprises & Discoveries and do not weaken the check to silence it. No stored data migrates; old v1 trace files become *more* readable, not less, and traces recorded before plan 40's key bump remain unreplayable by design (replay recomputes v2 keys and raises `ReplayDivergence` — the documented consequence of the version bump, not a defect of this plan).


## Interfaces and Dependencies

No new external dependencies. Modules and signatures that must exist at the end:

```haskell
-- shikumi-trace, module Shikumi.Trace.Store
replayIndex :: TraceTree -> Either Text (Map CacheKey Value)   -- changed
minSupportedFormatVersion :: Int                                -- new, = 1
currentFormatVersion :: Int                                     -- unchanged, = 2
readTraceFile :: FilePath -> IO (Either Text TraceTree)         -- unchanged shape, widened acceptance

-- shikumi-trace, module Shikumi.Trace
childrenOf :: TraceTree -> SpanId -> [SpanId]                   -- unchanged shape, numeric tie-break
renderTree :: TraceTree -> Text                                 -- unchanged shape, renders all roots
bumpRetry  :: (Trace :> es) => Eff es ()                        -- unchanged, now actually sent

-- shikumi-trace, module Shikumi.Trace.Program (internal helper, need not be exported)
tracedRetry ::
  (Trace :> es, Error ShikumiError :> es) =>
  (Program x y -> x -> Eff es y) -> (ShikumiError -> Bool) -> Int -> Program x y -> x -> Eff es y

-- shikumi-trace, test module TraceFixtures
runSequencedLLM :: (IOE :> es) => IORef [Response] -> Eff (LLM : es) a -> Eff es a
```

Upstream interface this plan consumes but must not touch: `Shikumi.Cache.Key.cacheKey` at its post-plan-40 v2 definition (owner: `docs/plans/40-cache-key-v2-endpoint-completeness.md`). Downstream consumers whose call sites change here and nowhere else: `Shikumi.Trace.Demo`, `shikumi-jitsurei/app/TraceReplay.hs`, `Shikumi.Cli.Runtime`.
