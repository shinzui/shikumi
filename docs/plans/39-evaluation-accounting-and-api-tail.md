---
id: 39
slug: evaluation-accounting-and-api-tail
title: "Evaluation Accounting and API Tail"
kind: exec-plan
created_at: 2026-07-02T03:30:16Z
intention: "intention_01kwgdyxm7ehh8yys1pp4wf1zr"
master_plan: "docs/masterplans/6-optimizer-and-evaluation-correctness.md"
---

# Evaluation Accounting and API Tail

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

`shikumi-eval` is the evaluation layer: `evaluate` runs a typed language-model program
over a dataset, scores each example with a metric, and returns a `Report` (aggregate
score, pass/fail counts, token/cost usage totals, latency, per-example breakdown). The
optimizers and the CLI trust these numbers to decide which program is better and what a
run cost. A production-readiness review found five accounting/API defects, all small,
all in this package:

1. `withUsageTotals` — the seam that sums token usage and dollar cost across a run —
   interposes only the `Complete` operation of the `LLM` effect and passes `Stream`
   through unaccumulated (`shikumi-eval/src/Shikumi/Eval/Usage.hs:37`). Any streamed
   call is invisible to cost reporting. The gap is untestable today because every mock
   response carries zero usage.
2. The `TimedOut` failure variant (`shikumi-eval/src/Shikumi/Eval/Report.hs:47`) is
   dead code: nothing constructs it and `evaluate` has no timeout, so a hung example
   hangs the run.
3. `totalLatencyMs` sums per-example latencies measured under 4-way concurrency
   (`Report.hs:144`) but renders as the wall-time-looking `latency: X ms`
   (`Report.hs:180`) — a 4× overstatement of elapsed time in the default
   configuration.
4. The raw `Score` constructor is exported (`shikumi-eval/src/Shikumi/Eval/Types.hs:16`,
   `Score (..)`), letting callers bypass the documented [0,1] clamping invariant that
   `mkScore` exists to enforce and that ranking code relies on.
5. Untested paths worth pinning while here: `numSamples > 1`
   (`shikumi-eval/src/Shikumi/Eval/Evaluate.hs:130-145`), a custom `FailScore`, and
   multi-sample metrics; plus `passCount`'s exact-`1.0` semantics (`Report.hs:139`)
   deserves an explicit docs note for users of fractional metrics.

After this change: streamed LM calls contribute to usage totals (proven with a stub
stream carrying non-zero usage); `evaluateWith` can enforce a per-example timeout that
surfaces as `TimedOut` under the failure policy; the report labels the latency sum
honestly; `Score` values can only be built through the clamping smart constructors;
and the untested paths have tests.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M1: stream usage accumulation in `withUsageTotals`; usage-carrying mock fixtures;
      new `UsageSpec.hs` (failing-before for the stream path)
- [ ] M2: `exampleTimeoutMs` in `EvalConfig`, race-based enforcement in `evalOne`,
      `TimedOut` surfaced under both failure policies; timeout tests
- [ ] M3: latency relabel (`latency-sum: X ms`) + field haddock; ReportSpec expectation
      updated
- [ ] M4: `Score` constructor hidden (smart constructors only); TypesSpec updated;
      workspace-wide recompile check
- [ ] M5: passCount docs note; coverage tests for `numSamples > 1`, custom `FailScore`,
      multi-sample metric
- [ ] `cabal test all` green


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

- Decision: Implement the timeout (rather than deleting the `TimedOut` variant), using
  `Effectful.Concurrent.Async.race` with a `threadDelay`, configured by a new
  `exampleTimeoutMs :: Maybe Int` field on `EvalConfig` defaulting to `Nothing`.
  Rationale: `Concurrent` is already in `evaluate`'s effect row, so no row change (the
  `Optimizer` rank-2 row in shikumi-optimize pins that row; changing it would be a
  cross-package break). A timeout is genuinely needed for production evaluation of
  remote models; deleting the variant would just re-open the gap. Default `Nothing`
  preserves current behavior exactly.
  Date: 2026-07-01 (source: production-readiness code review)

- Decision: Under `FailAbort`, a timed-out example aborts the run by throwing
  `ShikumiError`'s existing `Timeout` constructor
  (`shikumi/src/Shikumi/Error.hs:36`), message
  `"evaluate: example timed out"`.
  Rationale: `FailAbort` must throw through `Error ShikumiError` (the only error
  channel in the row) and core already has a timeout constructor; inventing a second
  vocabulary would be worse.
  Date: 2026-07-01

- Decision: Fix the latency mislabel by relabeling the rendered line to
  `latency-sum: X ms` and documenting the field, not by adding a wall-clock field to
  `Report`.
  Rationale: `mkReport :: [ExampleResult] -> UsageTotals -> Report` is a pure
  aggregator with several call sites and golden expectations; adding wall time means
  changing its signature and threading a clock through. The sum is a meaningful number
  (total compute latency) — the defect is only the label. A wall-time field remains
  open as a possible follow-up; rejected here for scope.
  Date: 2026-07-01

- Decision: Narrow the export to `Score` (abstract) + `mkScore`/`scoreZero`/
  `scoreOne`/`boolScore`/`unScore`, accepting the breaking change without a
  deprecation cycle.
  Rationale: A workspace-wide survey (grep over all packages) found exactly one raw
  constructor use — `shikumi-eval/test/TypesSpec.hs:26` — which this plan rewrites.
  `Shikumi.Eval` re-exports the whole `Types` module, so downstreams narrow
  automatically; the project is pre-production.
  Date: 2026-07-01

- Decision: Count a streamed call's usage from its terminal event only (`EventDone` /
  `EventError` both carry the assembled message with final `Usage`), ignoring
  per-delta events.
  Rationale: The baikai stream algebra
  (`/…/baikai/baikai/src/Baikai/Stream/Event.hs`) guarantees exactly one terminal
  event carrying the fully assembled message with the final usage; deltas carry no
  usage. Also count `EventError` terminals: a failed call may still have consumed
  billable input tokens, and its assembled message reports whatever the provider
  metered.
  Date: 2026-07-01


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This section assumes no prior repository knowledge.

`shikumi-eval` sits over the core `shikumi` package, which defines the `LLM` effect
(`shikumi/src/Shikumi/LLM.hs`) with two operations: `Complete` (returns a full
`Response`) and `Stream :: Model -> Context -> Options -> LLM m [AssistantMessageEvent]`
(line 86 — it returns the *assembled list* of typed streaming events). The event type
comes from the `baikai` provider-abstraction library (source on disk at
`/Users/shinzui/Keikaku/bokuno/baikai`, registered in mori as `shinzui/baikai`):
`Baikai.Stream.Event.AssistantMessageEvent` is a closed algebra whose stream terminates
with exactly one `EventDone TerminalPayload` (success) or `EventError TerminalPayload`
(failure), and `TerminalPayload.message :: Message` is the fully assembled assistant
message carrying the final `Baikai.Usage.Usage` (fields `inputTokens`, `outputTokens`,
`totalTokens :: Natural`, `cost` with a `usd :: Rational` inside). A `Response` from
`Complete` wraps the same `Message` (hence the existing lens path
`#message . #usage . …` in `usageOf`).

Files this plan touches, all under `shikumi-eval` unless noted:

- `src/Shikumi/Eval/Usage.hs` — `withUsageTotals` creates an `IORef UsageTotals`
  (via the `Prim` effect) and `interpose`s the `LLM` effect: the `Complete` branch
  forwards the call and accumulates `usageOf resp`; the `Stream` branch (line 37) is
  `Stream m c o -> stream m c o` — forwarded, never accumulated. This is defect 1.
- `src/Shikumi/Eval/Report.hs` — `FailureReason` (`TimedOut` at line 47),
  `FailurePolicy` (`FailScore Score` / `FailAbort`), `EvalConfig { concurrency,
  failurePolicy, numSamples }` (lines 93–100) with `defaultEvalConfig` (4-way, score
  failures 0, one sample), `Report`, `mkReport` (line 144: `totalLatencyMs = sum (map
  latencyMs rs)`), and `renderReportText` (line 180: `"latency: " <> … <> " ms"`; the
  haddock example at lines 149–158 shows the exact rendered shape golden-pinned by
  `test/ReportSpec.hs:38-47`).
- `src/Shikumi/Eval/Evaluate.hs` — `evaluateWith` wraps a
  `pooledForConcurrentlyN`-driven per-example runner in `withUsageTotals` (lines
  80–85); `evalOne` (lines 89–101) times one example with the monotonic clock and has
  row `(LLM, Error ShikumiError, Time)` — note: no `Concurrent`, which M2 adds;
  `scoreExample` (lines 106–126) applies the `FailurePolicy` to program/metric errors;
  `buildPrediction` (lines 130–145) runs the program `numSamples` times.
- `src/Shikumi/Eval/Types.hs` — `Score` newtype with clamping `mkScore` (lines 42–62);
  the export list at line 16 says `Score (..)`, exposing the raw constructor (defect
  4). `Shikumi.Eval` (the umbrella module) re-exports `module Shikumi.Eval.Types`.
- `test/` — `EvalFixtures.hs` (mock LLM interpreters `runConstLLM`, `runScriptedLLM`;
  both answer `Stream {} -> pure []` and build responses via `_Response`, whose default
  usage is all zeros — why defect 1 is invisible), `EvaluateSpec.hs`, `ReportSpec.hs`,
  `TypesSpec.hs`, `Main.hs` (test group registration), and the cabal `other-modules`
  list in `shikumi-eval.cabal` (lines 68–77).

Cross-initiative note: `docs/plans/34-route-and-unify-program-streaming.md` (under
`docs/masterplans/5-core-runtime-correctness-and-wire-fidelity.md`) routes program
execution through the `Stream` operation. That work is *not* a prerequisite — this
plan's stream-usage fix is exercised directly with stub streams — but once both land,
streamed program runs will be metered by this seam; if plan 34 is in flight, tell its
implementer that `withUsageTotals` now accumulates `Stream` terminals so they do not
add a second accumulation.

Build/test: repository root, `nix develop .#ghc9124`, then `cabal test shikumi-eval`
(or `just test-one shikumi-eval`).


## Plan of Work

### Milestone 1 — stream usage accounting

Scope: `withUsageTotals` accumulates streamed calls; fixtures gain non-zero usage so
both paths are actually measured. In `src/Shikumi/Eval/Usage.hs`:

- Refactor `usageOf :: Response -> UsageTotals` into
  `usageOfMessage :: Message -> UsageTotals` (same four lens reads, starting at
  `#usage` on the message) with `usageOf = usageOfMessage . view #message`.
- Replace the `Stream` branch:

  ```haskell
  Stream m c o -> do
    events <- stream m c o
    atomicModifyIORef' ref (\u -> (u <> streamUsage events, ()))
    pure events
  ```

  with

  ```haskell
  -- | The usage of one streamed call: read off the terminal event(s). The baikai
  -- stream algebra emits exactly one EventDone or EventError, whose payload
  -- carries the fully assembled message with final usage; deltas carry none.
  streamUsage :: [AssistantMessageEvent] -> UsageTotals
  streamUsage evs =
    mconcat
      [ usageOfMessage (msg tp)
      | ev <- evs
      , tp <- case ev of
          EventDone p -> [p]
          EventError p -> [p]
          _ -> []
      ]
  ```

  (field access to `TerminalPayload.message` — use the generic label lens or a
  qualified record selector, matching house style in this file). Import
  `AssistantMessageEvent (..)` and `TerminalPayload` — check what `Baikai` re-exports
  (the workspace imports `Baikai` broadly elsewhere, e.g.
  `shikumi-optimize/test/StubLM.hs` imports `Response`, `_Response` from `Baikai`);
  if the event type is not re-exported from the `Baikai` umbrella, import
  `Baikai.Stream.Event` directly.

In `test/EvalFixtures.hs`, add and export: `usageResponse :: Text -> Response` — an
`answerResponse` whose message usage is set to a known non-zero value (e.g. 100 input,
20 output, 120 total, cost 1/1000 USD) via the label lenses
(`_Response & #message . #content .~ … & #message . #usage .~ (_Usage & #inputTokens
.~ 100 & …)`; `_Usage` is baikai's zero-usage default); and `runStreamLLM ::
[AssistantMessageEvent] -> Eff (LLM : es) a -> Eff es a` — a mock whose `Stream`
branch returns the given events and whose `Complete` branch returns a fixed response
(it will not be exercised).

New test module `test/UsageSpec.hs` (register in `shikumi-eval.cabal` `other-modules`
and `test/Main.hs`):

- "complete calls accumulate non-zero usage": run
  `withUsageTotals (runProgram qaProg (Question "q"))` under
  `runConstLLM (usageResponse "yes")` and assert the totals equal the known values;
  with two program runs, assert they double (the `Semigroup` path).
- "stream calls accumulate usage" (the failing-before test): under
  `runStreamLLM [EventDone (doneTerminal EndTurn msgWithUsage)]` (build
  `msgWithUsage` with the same non-zero usage; `doneTerminal` is exported by
  `Baikai.Stream.Event`; pick any available `StopReason` constructor — check
  `Baikai.StopReason` for the exact name), run
  `withUsageTotals (stream model ctx opts)` directly (a program is not needed; call
  the `stream` smart constructor with any well-formed arguments, e.g. reuse whatever
  model/context values other specs construct) and assert the totals are the known
  non-zero values. Before the fix this returns `emptyUsageTotals` — write it first
  and record the zero.
- "evaluate reports non-zero usage end-to-end": `evaluatePure` over a 3-example
  dataset under `runConstLLM (usageResponse "yes")`; assert
  `usage report == 3 × per-call` (closes the "mocks carry zero usage" blind spot for
  the whole report pipeline).

### Milestone 2 — the per-example timeout

Scope: a configurable timeout that produces the hitherto-dead `TimedOut` reason. In
`src/Shikumi/Eval/Report.hs`, add `exampleTimeoutMs :: !(Maybe Int)` to `EvalConfig`
(haddock: "wall-clock budget per example; `Nothing` = no timeout") and
`exampleTimeoutMs = Nothing` to `defaultEvalConfig`. In `src/Shikumi/Eval/Evaluate.hs`:

- Add `Concurrent :> es` to `evalOne`'s and `scoreExample`'s constraint rows (the
  caller `evaluateWith` already has it). Import `Effectful.Concurrent (threadDelay)`
  and `Effectful.Concurrent.Async (race)`.
- In `evalOne`, wrap the `scoreExample` call:

  ```haskell
  outcome <- case exampleTimeoutMs cfg of
    Nothing -> Right <$> scoreExample cfg metric prog inp expd
    Just ms -> race (threadDelay (max 0 ms * 1000)) (scoreExample cfg metric prog inp expd)
  (s, mFail) <- case outcome of
    Right r -> pure r
    Left () -> case failurePolicy cfg of
      FailAbort -> throwError (Timeout "evaluate: example timed out")
      FailScore sc -> pure (sc, Just TimedOut)
  ```

  keeping the existing monotonic-clock timing around the whole thing so a timed-out
  example records ≈ the timeout as its latency. Note in the haddock: `race` cancels
  the losing branch, so an in-flight LM call is abandoned; its usage is not
  accumulated (the interposed handler never returns), and `FailAbort` maps a timeout
  onto core's `ShikumiError.Timeout`.

Tests in `test/EvaluateSpec.hs`: add a mock `runSlowLLM :: Int -> Response ->
Eff (LLM : es) a -> Eff es a` to `EvalFixtures.hs` whose `Complete` branch
`threadDelay`s the given microseconds before answering (needs `Concurrent :> es`).
With a 1-example dataset, `evaluateWith defaultEvalConfig { exampleTimeoutMs =
Just 20 }` under `runSlowLLM 500_000 (answerResponse "yes")`: assert the single
result has `failure = Just TimedOut` and `score = scoreZero`, and the run completes
(no hang). With `failurePolicy = FailAbort`, assert the run returns
`Left (Timeout _)`. Use a generous gap (20 ms versus 500 ms) so the test cannot
flake; both cases run in well under a second. Also assert a `Nothing`-timeout run
behaves exactly as before (existing specs already cover this — just keep them green).

### Milestone 3 — honest latency label

Scope: relabel and document. In `src/Shikumi/Eval/Report.hs`: change line 180 to
`"latency-sum: " <> tshow (totalLatencyMs r) <> " ms"`; update the haddock transcript
(lines 149–158) to match; extend the `totalLatencyMs` field haddock (line 124):
"sum of per-example latencies — under concurrent evaluation this exceeds wall-clock
time (it is total compute latency, not elapsed time)". Update the pinned rendering in
`test/ReportSpec.hs` (line 45 expects `latency: 1234 ms`). Check for other consumers
of the rendered line: `renderReportText` is used by `shikumi-cli` and by golden tests —
`shikumi-eval/test/golden/qa-program.golden` pins per-example outputs only (no latency
line), but grep the workspace for `"latency: "` to be sure and record findings.

### Milestone 4 — Score becomes abstract

Scope: close the clamp bypass. In `src/Shikumi/Eval/Types.hs` line 16, change
`Score (..)` to `Score` (the type only; `mkScore`, `scoreZero`, `scoreOne`,
`boolScore`, `unScore` stay exported). Rewrite
`test/TypesSpec.hs` (its import at line 7 and the case at line 26,
`mkScore 0.5 @?= Score 0.5`) to `unScore (mkScore 0.5) @?= 0.5`. Then rebuild the
whole workspace: the survey found no other raw-constructor uses (GEPA and the metric
modules import the type and smart constructors only), but the recompile is the proof —
`cabal build all`. If anything outside `shikumi-eval` fails to compile, fix it with
smart constructors and record it in Surprises & Discoveries.

### Milestone 5 — docs note and coverage tests

Scope: pin the remaining reviewed-but-untested behavior. In
`src/Shikumi/Eval/Report.hs`, extend the `passCount` haddocks (field, line 116–117,
and `mkReport`, lines 128–131): "an example passes only when its score is exactly 1.0;
fractional metrics (embedding similarity, partial credit) therefore report
`passCount = 0` even for good runs — read `aggregateScore` for those." In
`test/EvaluateSpec.hs` add:

- "numSamples > 1 produces a multi-sample prediction": `evaluateWith
  defaultEvalConfig { concurrency = 1, numSamples = 3 }` under
  `runScriptedLLM` popping `yes`, `no`, `yes` for one example, with a metric that
  reads `predictionSamples` (write a small inline `MetricM`/lifted metric, e.g.
  majority-equals-expected via `boolScore`); assert the score reflects all three
  samples (majority `yes` → 1.0) — this exercises `buildPrediction`'s
  `replicateM` path (`Evaluate.hs:130-145`), currently untested.
- "custom FailScore is honored": `failurePolicy = FailScore (mkScore 0.25)` with a
  scripted `MockFail`; assert the failed example's score is 0.25 and the aggregate
  reflects it (today only the 0-score default is tested).


## Concrete Steps

All commands from the repository root, inside the dev shell:

```bash
cd /path/to/shikumi
nix develop .#ghc9124
cabal build shikumi-eval
cabal test shikumi-eval              # or: just test-one shikumi-eval
```

Write each milestone's failing-before test first where one exists (M1 stream case, M2
both cases, M3 the ReportSpec expectation flips, M4 the TypesSpec rewrite). Expected
failing transcript for the M1 stream case on the unfixed tree:

```text
    usage
      stream calls accumulate usage: FAIL
        expected UsageTotals {totalInputTokens = 100, …}, got UsageTotals {totalInputTokens = 0, …}
```

After M4 and again before finishing:

```bash
cabal build all
cabal test all
```

Commit at green milestone boundaries with Conventional Commits subjects and these
exact trailers on every commit:

```text
fix(eval): accumulate streamed-call usage in withUsageTotals

MasterPlan: docs/masterplans/6-optimizer-and-evaluation-correctness.md
ExecPlan: docs/plans/39-evaluation-accounting-and-api-tail.md
Intention: intention_01kwgdyxm7ehh8yys1pp4wf1zr
```

(Per-commit subjects: `feat(eval): add a per-example timeout surfacing TimedOut`,
`fix(eval)!: hide the raw Score constructor` — note the `!` on the breaking export
change — `docs(eval): …`, `test(eval): …`.)


## Validation and Acceptance

Accepted when:

1. `withUsageTotals` over a stubbed `stream` call whose terminal event carries known
   non-zero usage returns exactly those totals (fails with zeros before M1), and an
   end-to-end `evaluatePure` under a non-zero-usage `Complete` mock reports
   `n × per-call` totals.
2. An `evaluateWith` run with `exampleTimeoutMs = Just 20` over a mock that answers in
   500 ms completes promptly with `failure = Just TimedOut` under the default policy,
   and aborts with `Left (Timeout _)` under `FailAbort` (both impossible before M2 —
   the variant was unconstructible in practice and the run would block on the mock).
3. `renderReportText` emits `latency-sum: X ms`, the haddock transcript matches, and
   `ReportSpec`'s pinned rendering passes.
4. `Score`'s raw constructor no longer compiles outside `Shikumi.Eval.Types`
   (demonstrate: a scratch expression `Score 2.0` in a test fails to compile; do not
   commit it) and `cabal build all` is green.
5. The `numSamples > 1` and custom-`FailScore` tests pass, and `passCount`'s docs
   state the exact-1.0 rule.
6. `cabal test all` inside `nix develop .#ghc9124` passes — in particular
   `shikumi-optimize` (whose `scoreOn` consumes `aggregateScore`) and `shikumi-cli`
   (which renders reports) are unaffected apart from the relabeled latency line.


## Idempotence and Recovery

All steps are source edits plus deterministic offline tests; re-running is safe. The
timeout test is the only timing-sensitive piece — its 25× margin (20 ms limit versus
500 ms delay) makes flakes implausible, but if CI ever shows one, widen the delay, not
the limit. M4 is the only breaking change; if an unexpected downstream use of the raw
constructor blocks a merge, the fallback is to keep `Score (..)` exported with a
`{-# DEPRECATED #-}`-style haddock warning for one cycle and record the deferral in
the Decision Log. Each milestone is revertible per file.


## Interfaces and Dependencies

No new package dependencies: `effectful`'s `Concurrent`/`race`/`threadDelay` and the
baikai event types are already transitive dependencies of `shikumi-eval` via `shikumi`
(verify `baikai` is a direct build-depends of `shikumi-eval`; if the event-type import
fails to resolve, add `baikai` to `shikumi-eval.cabal` build-depends — it is already
in the workspace's package set). Source layout of baikai on disk (for reading, not
editing): `/Users/shinzui/Keikaku/bokuno/baikai` (via `mori registry show baikai`).

End-state surface, all in `shikumi-eval`:

- `Shikumi.Eval.Usage`: `withUsageTotals :: (LLM :> es, Prim :> es) => Eff es a ->
  Eff es (a, UsageTotals)` (unchanged type; now also meters `Stream`); internal
  `usageOfMessage`, `streamUsage`.
- `Shikumi.Eval.Report`: `EvalConfig` gains `exampleTimeoutMs :: Maybe Int`
  (record-construction sites must add the field or use `defaultEvalConfig { … }` —
  grep shows all workspace sites already use record-update on `defaultEvalConfig`);
  rendered latency line relabeled.
- `Shikumi.Eval.Evaluate`: `evaluate`/`evaluatePure`/`evaluateWith` types unchanged;
  `evalOne`/`scoreExample` gain a `Concurrent` constraint (internal).
- `Shikumi.Eval.Types`: exports narrow to `Score` (abstract) — the one breaking
  change, propagated automatically through the `Shikumi.Eval` umbrella re-export.
- Test suite: new `UsageSpec.hs`; extended `EvalFixtures.hs` (`usageResponse`,
  `runStreamLLM`, `runSlowLLM`), `EvaluateSpec.hs`, `ReportSpec.hs`, `TypesSpec.hs`;
  cabal `other-modules` updated.

This plan is independent of plans 36–38 and may land in any order relative to them.
The soft cross-initiative relationship with
`docs/plans/34-route-and-unify-program-streaming.md` is described in Context and
Orientation: no ordering constraint, one courtesy notification.
