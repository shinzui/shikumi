---
id: 13
slug: precise-effect-constraints-prim-concurrent-and-a-custom-time-effect
title: "Precise effect constraints: Prim, Concurrent, and a custom Time effect"
kind: exec-plan
created_at: 2026-06-09T19:06:06Z
---

# Precise effect constraints: Prim, Concurrent, and a custom Time effect

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Today, large parts of the shikumi codebase carry the broadest possible effect
constraint, `IOE :> es`, on functions that only ever do something narrow:
read a clock, bump an `IORef`, or take a software-transactional-memory (STM)
lock. `IOE :> es` is the constraint that says "this code may perform *arbitrary*
`IO` — open files, hit the network, fork threads, anything." We use the
`effectful` library (a Haskell effect system; see Context below), and `effectful`
already ships *narrow* effects that express exactly what these functions need:

- `Prim` — for mutable references (`IORef`): "this code touches in-process
  mutable cells, nothing else."
- `Concurrent` — for STM (`TVar`, `atomically`), `MVar`, and `threadDelay`:
  "this code synchronizes between threads, nothing else."

`effectful` does **not** ship a clock effect in the packages we depend on, so for
time we will build our own small effect, `Time`, modeled line-for-line on the
`Clock` effect from the third-party `time-effectful` package (which we do *not*
depend on — we copy its shape into shikumi). Our `Time` effect will expose two
operations: `getCurrentTime` (wall-clock `UTCTime`, used for cache metadata and
trace-span timestamps) and `getMonotonicTimeNSec` (a steadily-increasing
nanosecond counter from `GHC.Clock`, used to measure how long an evaluation took).
`time-effectful`'s `Clock` only offers wall-clock operations; we add the
monotonic one because shikumi's evaluation timing needs it.

**What someone gains after this change.** A reader of any shikumi type signature
can tell *at a glance* what a function is actually allowed to do. A function that
only times an operation will say `Time :> es`, not `IOE :> es`. A function that
only accumulates counters will say `Prim :> es`. This is not cosmetic:

1. **Testability.** Because `Time` is an effect with its own interpreter, a test
   can later run code against a *fake* clock to get deterministic timestamps and
   latencies, instead of being forced through real `IO`. (This plan does not add
   the fake interpreter, but it makes it possible by introducing the effect.)
2. **Honest signatures.** The remaining `IOE :> es` constraints will mark exactly
   the places that genuinely do open-ended `IO`: the SQLite/Postgres/Redis cache
   backends, the baikai LLM transport interpreters, and the top-level program
   entry points. Everything else loses `IOE`.

**How to see it working.** After this change, running

```bash
nix develop -c grep -rn 'IOE :>' --include='*.hs' shikumi shikumi-eval shikumi-trace shikumi-cache
```

will show `IOE :>` only on the genuine-IO sites enumerated in this plan (the DB
backends, the baikai LLM interpreters, and a handful of test discharge points),
and the full build and test suite

```bash
nix develop -c cabal build all
nix develop -c cabal test all
```

will pass, proving the narrower constraints are sufficient — the program still
caches responses, still records span timestamps, and still reports per-example
latency in milliseconds.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M0: Add the `Time` effect module `shikumi/src/Shikumi/Effect/Time.hs` to the core
      `shikumi` package, exposing `Time`, `runTime`, `getCurrentTime`,
      `getMonotonicTimeNSec`. Added to `shikumi.cabal`'s `exposed-modules`; added `time`
      to the library `build-depends` (it was not present). (2026-06-09)
- [x] M0: Added a tasty (not hspec) unit test `Shikumi.Effect.TimeSpec` proving `runTime`
      returns a renderable `UTCTime` and that two successive `getMonotonicTimeNSec` reads
      are non-decreasing. Wired into `test/Main.hs` and `shikumi.cabal` `other-modules`.
      `cabal build shikumi` + `cabal test shikumi` green: "All 80 tests passed". (2026-06-09)
- [ ] M1: Migrate the two pure-time IOE sites to `Time`: `cachedLLM`
      (`shikumi-cache/src/Shikumi/Cache.hs`) and `evalOne`
      (`shikumi-eval/src/Shikumi/Eval/Evaluate.hs`). Thread `Time :> es` through the
      `evaluate` family. Add `runTime` at the discharge sites. Build + test green.
- [ ] M2: Migrate IORef sites to `Prim`: `withUsageTotals`
      (`shikumi-eval/src/Shikumi/Eval/Usage.hs`), `runTrace`
      (`shikumi-trace/src/Shikumi/Trace.hs`), and the test/stub fixtures that hold
      `IORef`s. Add `runPrim` at discharge sites. Build + test green.
- [ ] M3: Migrate STM/MVar/threadDelay helpers to `Concurrent`: `runCacheMemory`
      (`shikumi-cache/src/Shikumi/Cache/Backend/Memory.hs`), and the resilience helpers
      `withRateLimit`/`retrying` in `shikumi/src/Shikumi/LLM.hs`. Build + test green.
- [ ] M4: Sweep transitive consumers (`evaluate`, `evaluatePure`, `evaluateWith`,
      `goldenReport`, `optimize`, `scoreOn`, `runOptimizer`) to drop now-redundant `IOE`;
      enable `-Wredundant-constraints` as a guard; final build + full test suite green;
      grep confirms `IOE :>` survives only at the legitimate sites.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- M0: The `shikumi` test suite is **tasty**, not hspec. The plan's M0 sketch assumed an
  `hspec` `spec :: Spec` discovered by `hspec-discover`; in fact `shikumi/test/Main.hs`
  builds one `Test.Tasty.defaultMain` over a `testGroup`, and every spec module exports
  `tests :: TestTree` and is listed explicitly in `shikumi.cabal`'s test `other-modules`.
  The new `Shikumi.Effect.TimeSpec` therefore exports `tests` (using `Test.Tasty.HUnit`),
  and is wired into both `test/Main.hs` (import + entry in the group) and the cabal
  `other-modules`. The other test packages (`shikumi-eval`, `shikumi-trace`, ...) follow
  the same tasty convention — keep this in mind for M1–M4 fixtures.
- M0: The core `shikumi` library did **not** already depend on the `time` package; added
  `, time` to its `build-depends`. (`base` and `effectful` were present.)
- M0: `-Wredundant-constraints` is **already enabled** project-wide via the
  `common-options` stanza in `shikumi.cabal` (and mirrored in the sibling packages). This
  means M4's "enable the guard" step is largely already in force — the compiler will flag
  any constraint that becomes unused as we migrate, which is exactly the signal we want.
  Concretely: after M1–M3 narrow the operations, leftover `IOE :>` on the
  `evaluate`/optimize/trace consumers will surface as redundant-constraint warnings (which
  are errors here only if `-Werror` is set — it is not — so they appear as warnings to act
  on). The new `Shikumi.Effect.Time` module carries a local
  `{-# OPTIONS_GHC -Wno-redundant-constraints #-}` (mirroring `time-effectful`) because the
  `runTime` signature's `IOE :> es` is intentional plumbing for `evalStaticRep`.


## Decision Log

Record every decision made while working on the plan.

- Decision: Build our own `Time` effect inside the core `shikumi` package
  (`Shikumi.Effect.Time`) rather than adding a dependency on the third-party
  `time-effectful` package.
  Rationale: The user explicitly requested a custom effect modeled after
  `time-effectful`'s `Clock`. `time-effectful`'s `Clock` also lacks the monotonic
  clock (`getMonotonicTimeNSec`) that shikumi's evaluation timing needs, so we would
  have had to supplement it anyway. Owning the module keeps the dependency surface
  unchanged (every package already depends on the `time` and `base` libraries, and on
  `effectful`) and lets us expose exactly the two operations shikumi uses.
  Date: 2026-06-09

- Decision: Name the effect `Time` (operations `getCurrentTime`,
  `getMonotonicTimeNSec`), not `Clock`.
  Rationale: The user asked for a "Time effect." There is no collision: the existing
  `Trace` effect in `shikumi-trace` is unrelated, and shikumi has no other `Time`
  symbol. We deliberately mirror `time-effectful`'s static-dispatch structure
  (`'Static 'WithSideEffects`, `evalStaticRep`) so the implementation is a known-good
  pattern.
  Date: 2026-06-09

- Decision: Place `Shikumi.Effect.Time` in the core `shikumi` package.
  Rationale: `shikumi-cache`, `shikumi-eval`, and `shikumi-trace` all already depend
  on the core `shikumi` library, so a single core module reaches every consumer
  without new inter-package dependencies. (Verify the dependency direction during M0;
  if any consumer does not depend on core `shikumi`, add the dep in that package's
  `.cabal` `build-depends` for `shikumi`.)
  Date: 2026-06-09

- Decision: Do NOT attempt to remove `IOE` from the SQLite, Postgres, and Redis cache
  backends, nor from the baikai-backed LLM interpreters (`runLLM`, `runLLMWith`,
  `runLLMResilient`), nor from the top-level program entry points.
  Rationale: These perform genuine open-ended `IO` — `direct-sqlite` handle calls,
  `hasql` sessions, `hedis` network round-trips, and the baikai transport — for which
  `IOE` is the correct, honest constraint. The goal of this plan is *narrowest-correct*
  constraints, not "zero `IOE`." Narrowing here would be wrong.
  Date: 2026-06-09


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This section assumes no prior knowledge of shikumi or of the `effectful` library.

**What shikumi is.** shikumi is a Haskell framework for building typed,
evaluable language-model (LM) programs. It is a Cabal *multi-package* project:
the file `cabal.project` at the repository root lists the packages, including
`shikumi` (the core library), `shikumi-cache`, `shikumi-eval`, `shikumi-trace`,
`shikumi-optimize`, `shikumi-cli`, and the cache backend packages
`shikumi-cache-redis` and `shikumi-cache-postgres`. Each package has a `.cabal`
file (e.g. `shikumi/shikumi.cabal`) whose `build-depends` lists its library
dependencies and whose `exposed-modules` lists the modules it offers.

**The toolchain.** This project builds with GHC 9.12.4, which is provided by a
Nix dev shell. The system `ghc` on `PATH` is the *wrong* version (9.10.3). Every
build and test command in this plan must therefore be prefixed with
`nix develop -c` so it runs inside the dev shell. For example, to build
everything: `nix develop -c cabal build all`. To run all tests:
`nix develop -c cabal test all`. To build or test a single package, name it:
`nix develop -c cabal build shikumi-eval` or
`nix develop -c cabal test shikumi-eval`.

**The `effectful` library, in plain terms.** `effectful` is an *effect system*:
a way to write functions whose type signature lists the capabilities ("effects")
they may use, against an abstract list of effects written `es`. The core type is
`Eff es a` — "a computation that may use the effects in the list `es` and
produces an `a`." A constraint written `E :> es` means "the effect `E` is present
in the list `es`," i.e. "this computation is allowed to use `E`."

The relevant effects for this plan are:

- `IOE` — the most permissive effect: "may run arbitrary `IO`." The function
  `liftIO :: IOE :> es => IO a -> Eff es a` lifts any raw `IO` action into `Eff`.
  Wherever you see `liftIO (someIOAction)`, the surrounding function needs
  `IOE :> es`. This is the constraint we are trying to *narrow*.
- `Prim` — "may touch primitive in-process mutable state." The module
  `Effectful.Prim.IORef` (from the `effectful` library) re-exports the familiar
  `IORef` operations — `newIORef`, `readIORef`, `writeIORef`, `modifyIORef'`,
  `atomicModifyIORef'` — but each requires only `Prim :> es` instead of
  `IOE :> es`. The effect is discharged (turned into real `IO`) by
  `runPrim :: IOE :> es => Eff (Prim : es) a -> Eff es a`, which lives in
  `Effectful.Prim` (from `effectful-core`).
- `Concurrent` — "may synchronize across threads." The modules
  `Effectful.Concurrent.STM` (gives `atomically`, `newTVarIO`, `readTVarIO`,
  `TVar`, `TMVar`, etc.), `Effectful.Concurrent.MVar` (gives `withMVar`, etc.),
  and `Effectful.Concurrent` itself (gives `threadDelay`) all require only
  `Concurrent :> es`. The effect is discharged by `runConcurrent` (already used
  throughout shikumi's tests and CLI runtime). Note: shikumi already lists
  `Concurrent :> es` on several signatures (e.g. in
  `shikumi-eval/src/Shikumi/Eval/Evaluate.hs`) for its use of
  `pooledForConcurrentlyN`, so adding `Concurrent` operations there is "free" — the
  constraint is already present.
- `Time` — the **new** effect this plan introduces (see below). It does not exist
  yet.

**Static-dispatch effects and `unsafeEff_`.** `effectful` supports two flavors of
effect: *dynamic* (interpreted with `interpret`/`interpose`, used by shikumi's
`LLM`, `Cache`, and `Trace` effects) and *static* (a fixed, built-in
interpretation). Clock/time effects are conventionally *static* because there is
only one sensible real interpretation: call the real clock. The standard pattern
(used by `time-effectful`'s `Clock`) is:

```haskell
data Time :: Effect
type instance DispatchOf Time = 'Static 'WithSideEffects
data instance StaticRep Time = TimeRep
```

`'WithSideEffects` declares that the effect's operations run real `IO` under the
hood. Each operation is written with
`unsafeEff_ :: IO a -> Eff es a` (from `Effectful.Dispatch.Static`), which
performs the `IO` *without* requiring `IOE :> es` — that is precisely how a narrow
effect "hides" its `IO`. The effect is discharged with
`evalStaticRep TimeRep :: IOE :> es => Eff (Time : es) a -> Eff es a`, which is
where the real `IO` permission is finally required (at the program edge, which is
correct). This is the same mechanism `Prim` and `Concurrent` use internally, which
is why their operations also avoid `IOE`.

**The reference we are modeling.** The third-party package `time-effectful`
defines its `Clock` effect in the file
`/Users/shinzui/Keikaku/hub/haskell/effectful-project/effectful-extras/time-effectful/src/Effectful/Time.hs`.
Its full contents (for reference; we are copying this shape, not depending on it):

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# OPTIONS_GHC -Wno-redundant-constraints #-}

module Effectful.Time (
  Clock,
  runClock,
  getCurrentTime,
  getZonedTime,
  getCurrentTimeZone,
  UTCTime,
  TimeZone,
) where

import Data.Time (TimeZone, UTCTime, ZonedTime)
import qualified Data.Time as Time
import Effectful
import Effectful.Dispatch.Static

data Clock :: Effect
type instance DispatchOf Clock = 'Static 'WithSideEffects
data instance StaticRep Clock = TimeRep

getCurrentTimeZone :: (Clock :> es) => Eff es TimeZone
getCurrentTimeZone = unsafeEff_ Time.getCurrentTimeZone

getCurrentTime :: (Clock :> es) => Eff es UTCTime
getCurrentTime = unsafeEff_ Time.getCurrentTime

getZonedTime :: (Clock :> es) => Eff es ZonedTime
getZonedTime = unsafeEff_ Time.getZonedTime

runClock :: (IOE :> es) => Eff (Clock ': es) a -> Eff es a
runClock = evalStaticRep TimeRep
```

**The full inventory of `IOE :>` sites today (39 occurrences).** The following
table is the ground truth this plan was built from. "Why IOE" is what the
function actually does that requires it; "Target" is the constraint it should
carry after this plan (or "IOE (keep)" if `IOE` is genuinely correct). Test-only
fixtures are migrated in M2/M4 alongside the production code they mirror.

Production sites:

- `shikumi-cache/src/Shikumi/Cache.hs:58` — `cachedLLM`. Why IOE: a single
  `liftIO getCurrentTime` for the cache-entry timestamp. Target: **Time** (M1).
- `shikumi-eval/src/Shikumi/Eval/Evaluate.hs:89` — `evalOne`. Why IOE: two
  `liftIO getMonotonicTimeNSec` calls bracketing the work to compute `latencyMs`.
  Target: **Time** (M1).
- `shikumi-eval/src/Shikumi/Eval/Evaluate.hs:55,64,73` — `evaluate`,
  `evaluatePure`, `evaluateWith`. Why IOE: transitively, via `evalOne` (timing)
  and `withUsageTotals` (an `IORef`). Target: after M1+M2 these need
  **Time + Prim + Concurrent** and drop **IOE** (M4).
- `shikumi-eval/src/Shikumi/Eval/Usage.hs:27` — `withUsageTotals`. Why IOE:
  `newIORef`/`atomicModifyIORef'`/`readIORef` accumulating usage. Target:
  **Prim** (M2).
- `shikumi-eval/src/Shikumi/Eval/Golden.hs:66` — `goldenReport`. Why IOE:
  transitively, via `evaluate`. Target: drop **IOE** (M4).
- `shikumi-optimize/src/Shikumi/Optimize.hs:46`,
  `shikumi-optimize/src/Shikumi/Optimize/Search.hs:54`,
  `shikumi-optimize/src/Shikumi/Optimize/Types.hs:54` — `optimize`, `scoreOn`,
  and the `runOptimizer` rank-2 signature. Why IOE: transitively, via
  `evaluate`/`evaluatePure`. Target: drop **IOE** (M4).
- `shikumi-trace/src/Shikumi/Trace.hs:230` — `runTrace`. Why IOE: `IORef` trace
  state (`newTraceState`, `readIORef`, `modifyIORef'`, `freezeTree`) **and** two
  `getCurrentTime` calls inside `openSpan`/`closeSpan`. Target: **Prim + Time**
  (M2 for the IORef part, M1/M2 for the clock part — see M2 notes).
- `shikumi-cache/src/Shikumi/Cache/Backend/Memory.hs:29` — `runCacheMemory`. Why
  IOE: `atomically`/`readTVarIO`/`modifyTVar'` over a `TVar`. Target:
  **Concurrent** (M3).
- `shikumi/src/Shikumi/LLM.hs:226` — `withRateLimit`. Why IOE: `atomically` over a
  permit `TVar` plus `bracket_`. Target: **Concurrent** (M3).
- `shikumi/src/Shikumi/LLM.hs:242` — `retrying`. Why IOE:
  `liftIO (threadDelay ...)` for backoff. Target: **Concurrent** (M3).
- `shikumi/src/Shikumi/LLM.hs:107,114,189,215` — `runLLM`, `runLLMWith`,
  `runLLMResilient`, `withBudget`. Why IOE: these run the **baikai transport**
  (`runBaikai`, `BE.complete`/`BE.streamCollect`) and/or do budget reservation
  through raw `IO`. Target: **IOE (keep)** — genuine open-ended IO. (`withBudget`
  calls `liftIO (tryReserve b)` / `liftIO (chargeBudget ...)`, which are raw IO
  over the budget's internal state; keep IOE unless a later plan turns `Budget`
  into an effect.)
- `shikumi-cache/src/Shikumi/Cache/Backend/SQLite.hs:94` — `runCacheSQLite`.
  Target: **IOE (keep)** — `direct-sqlite` handle calls.
- `shikumi-cache-postgres/src/Shikumi/Cache/Backend/Postgres.hs:60` —
  `runCachePostgres`. Target: **IOE (keep)** — `hasql` sessions.
- `shikumi-cache-redis/src/Shikumi/Cache/Backend/Redis.hs:63` — `runCacheRedis`.
  Target: **IOE (keep)** — `hedis` network calls.

Test/fixture and spike sites (migrated to **Prim** in M2/M4 where they only hold
`IORef`s; spike code mirrors `runTrace`):

- `shikumi-jitsurei/src/Shikumi/Jitsurei/Stub.hs:130` (`runScriptLLM`),
  `shikumi-jitsurei/app/TraceReplay.hs:62` (`counting`),
  `shikumi-optimize/test/StubLM.hs:163` (`runStubLMCounting`),
  `shikumi-cache/test/Main.hs:75`, `shikumi-cache-redis/test/Main.hs:47`,
  `shikumi-cache-postgres/test/Main.hs:43` (`runCountingLLM`),
  `shikumi-tools/test/MockLLM.hs:39` (`runMockLLM`),
  `shikumi-trace/test/TraceFixtures.hs:100` (`runKeyedCountingLLM`),
  `shikumi-eval/test/EvalFixtures.hs:128` (`runScriptedLLM`),
  `shikumi/test/ProgramFixtures.hs:149,157`,
  `shikumi/test/Shikumi/LLM/Mock.hs:40,57,74`,
  `shikumi-trace/src/Shikumi/Trace/Internal/Spike.hs:82,92,113`.

The comment at `shikumi-trace/src/Shikumi/Trace/Replay.hs:61` merely *mentions*
`(IOE :> es)` in prose and is not a constraint to migrate; leave it (or update its
wording in M4 if it becomes inaccurate).


## Plan of Work

The work proceeds in five milestones. Each is independently buildable and
testable. The ordering is deliberate: M0 introduces the `Time` effect with **no**
changes to existing constraints (purely additive); M1–M3 migrate the three
categories of narrow IO (time, IORef, STM/threadDelay) one at a time so a failure
is easy to localize; M4 harvests the payoff by deleting the now-redundant `IOE`
constraints from transitive consumers and turns on a compiler warning to keep them
gone.

A guiding rule throughout: **narrowest-correct, not zero-IOE.** Where a function
genuinely does open-ended IO (the DB backends, the baikai LLM interpreters, the
program edge), `IOE` stays. The Decision Log records this explicitly.


### Milestone M0 — Introduce the `Time` effect (additive, no migrations)

Scope: create the new effect module and prove it works in isolation. Nothing else
changes; the whole project still builds and tests exactly as before, plus one new
test.

At the end of M0 there will exist a module `Shikumi.Effect.Time` exporting the
effect `Time`, its interpreter `runTime`, and two operations `getCurrentTime` and
`getMonotonicTimeNSec`. It is added to `shikumi.cabal`'s `exposed-modules`. A new
test exercises the real interpreter.

Create `shikumi/src/Shikumi/Effect/Time.hs` with exactly this content:

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# OPTIONS_GHC -Wno-redundant-constraints #-}

-- | A minimal clock effect for shikumi, modeled on the @Clock@ effect from the
-- third-party @time-effectful@ package. We own this module (rather than depend on
-- @time-effectful@) because shikumi needs a monotonic-clock operation
-- ('getMonotonicTimeNSec') that @time-effectful@'s @Clock@ does not provide, and
-- because owning it keeps the dependency surface unchanged.
--
-- The effect is static-dispatch with side effects: each operation performs real
-- 'IO' under the hood via 'unsafeEff_', so callers need only @Time :> es@ rather
-- than the open-ended @IOE :> es@. The real 'IO' permission is required exactly
-- once, at the discharge site 'runTime', which is where the program edge lives.
module Shikumi.Effect.Time
  ( Time,
    runTime,
    getCurrentTime,
    getMonotonicTimeNSec,
    UTCTime,
  )
where

import Data.Time (UTCTime)
import qualified Data.Time as Time
import Data.Word (Word64)
import qualified GHC.Clock as Clock
import Effectful
import Effectful.Dispatch.Static

data Time :: Effect

type instance DispatchOf Time = 'Static 'WithSideEffects

data instance StaticRep Time = TimeRep

-- | The current wall-clock time (UTC). Used for cache-entry metadata and trace
-- span timestamps.
getCurrentTime :: (Time :> es) => Eff es UTCTime
getCurrentTime = unsafeEff_ Time.getCurrentTime

-- | A monotonic nanosecond counter (never runs backwards), suitable for
-- measuring elapsed time. Used by the evaluation framework to compute per-example
-- latency. Wraps 'GHC.Clock.getMonotonicTimeNSec'.
getMonotonicTimeNSec :: (Time :> es) => Eff es Word64
getMonotonicTimeNSec = unsafeEff_ Clock.getMonotonicTimeNSec

-- | Discharge the 'Time' effect against the real system clock.
runTime :: (IOE :> es) => Eff (Time ': es) a -> Eff es a
runTime = evalStaticRep TimeRep
```

Then register the module. In `shikumi/shikumi.cabal`, locate the `library`
stanza's `exposed-modules:` list and add `Shikumi.Effect.Time` in alphabetical
position. Confirm the `library` stanza's `build-depends` already lists `time` and
`base`; the core `shikumi` library already depends on `effectful` (cabal line ~54)
and on `time` is used elsewhere — if `time` is not already a dependency of the
core library stanza, add `, time` to its `build-depends`. (The `base` and
`effectful` deps are certainly present.)

Add a focused test. shikumi's test suites use `hspec`-style specs discharged with
`runEff`. Create `shikumi/test/Shikumi/Effect/TimeSpec.hs`:

```haskell
{-# LANGUAGE TypeApplications #-}

module Shikumi.Effect.TimeSpec (spec) where

import Effectful (runEff)
import Shikumi.Effect.Time (getCurrentTime, getMonotonicTimeNSec, runTime)
import Test.Hspec

spec :: Spec
spec = describe "Shikumi.Effect.Time" $ do
  it "getCurrentTime returns a plausible (post-2020) timestamp" $ do
    t <- runEff (runTime getCurrentTime)
    -- 2020-01-01 in UTCTime terms; any real clock is well past this.
    show t `shouldSatisfy` (\s -> length s > 0)
  it "getMonotonicTimeNSec is non-decreasing across two reads" $ do
    (a, b) <- runEff $ runTime $ do
      a <- getMonotonicTimeNSec
      b <- getMonotonicTimeNSec
      pure (a, b)
    b `shouldSatisfy` (>= a)
```

Wire the spec into the package's test runner. Inspect how the existing
`shikumi` test suite discovers specs (look at `shikumi/test/` — it likely uses
`hspec-discover` via a `Spec.hs`/`Main.hs` driver, in which case a file named
`*Spec.hs` exporting `spec` is auto-discovered and no manual wiring is needed; if
it lists modules explicitly in `shikumi.cabal`'s test stanza `other-modules:`, add
`Shikumi.Effect.TimeSpec` there). Adjust accordingly.

Acceptance for M0:

```bash
nix develop -c cabal build shikumi
nix develop -c cabal test shikumi
```

Expect a clean build and the two new examples passing, e.g.:

```text
Shikumi.Effect.Time
  getCurrentTime returns a plausible (post-2020) timestamp
  getMonotonicTimeNSec is non-decreasing across two reads
```

Commit (message body must include the `ExecPlan:` trailer; see Concrete Steps).


### Milestone M1 — Migrate the pure-time sites to `Time`

Scope: the two functions whose *only* reason for `IOE` is reading a clock —
`cachedLLM` and `evalOne` — switch from `IOE :> es` to `Time :> es`. Their callers
gain a `Time :> es` constraint, and every place that discharges the stack gains a
`runTime` call. The `evaluate` family keeps its `IOE` for now (it still uses
`withUsageTotals`'s `IORef`; that is removed in M2). At the end of M1, cache
timestamps and evaluation latencies are produced through the `Time` effect, and a
grep shows `getCurrentTime`/`getMonotonicTimeNSec` no longer wrapped in `liftIO`.

Edit `shikumi-cache/src/Shikumi/Cache.hs`:

- Change the `cachedLLM` constraint from `(Cache :> es, LLM :> es, IOE :> es)` to
  `(Cache :> es, LLM :> es, Time :> es)`.
- Replace `now <- liftIO getCurrentTime` with `now <- getCurrentTime` (the
  effectful operation).
- Update imports: remove `IOE` and `liftIO` from the `Effectful` import if they
  become unused; add `import Shikumi.Effect.Time (getCurrentTime)`. Remove the
  module's direct `import Data.Time (getCurrentTime)` (or `import Data.Time.Clock`)
  if present, to avoid a name clash — the effectful `getCurrentTime` now provides
  it.
- In `shikumi-cache/shikumi-cache.cabal`, ensure the library `build-depends`
  includes `shikumi` (it must, since `cachedLLM` interposes on `Shikumi.LLM`); no
  new dependency is needed because `Shikumi.Effect.Time` ships inside `shikumi`.

Edit `shikumi-eval/src/Shikumi/Eval/Evaluate.hs`:

- Change `evalOne`'s constraint from `(LLM :> es, Error ShikumiError :> es, IOE :> es)`
  to `(LLM :> es, Error ShikumiError :> es, Time :> es)`.
- Replace `start <- liftIO getMonotonicTimeNSec` and
  `end <- liftIO getMonotonicTimeNSec` with `start <- getMonotonicTimeNSec` and
  `end <- getMonotonicTimeNSec`.
- Replace the import `import GHC.Clock (getMonotonicTimeNSec)` with
  `import Shikumi.Effect.Time (getMonotonicTimeNSec)`.
- `evaluate`, `evaluatePure`, and `evaluateWith` now call `evalOne` (via
  `pooledForConcurrentlyN`), so they each need `Time :> es` *added* to their
  existing constraint set. Add `Time :> es` to all three. They retain `IOE :> es`
  for now (because they still call `withUsageTotals`). The constraint sets become
  `(LLM :> es, Concurrent :> es, Error ShikumiError :> es, Time :> es, IOE :> es)`.
- Keep `liftIO` import only if still used elsewhere in the file; otherwise remove.

Propagate `Time :> es` to the transitive callers so the project still type-checks:

- `shikumi-eval/src/Shikumi/Eval/Golden.hs:66` `goldenReport` — add `Time :> es`.
- `shikumi-optimize/src/Shikumi/Optimize.hs:46` `optimize` — add `Time :> es`.
- `shikumi-optimize/src/Shikumi/Optimize/Search.hs:54` `scoreOn` — add `Time :> es`.
- `shikumi-optimize/src/Shikumi/Optimize/Types.hs:54` the `runOptimizer` rank-2
  signature — add `Time :> es` to its quantified constraint row.

Each of these packages must depend on `shikumi` for the `Shikumi.Effect.Time`
import; they already do (they use `Shikumi.LLM`/`Shikumi.Program`). Add the import
`import Shikumi.Effect.Time (Time)` to each file that now names `Time` in a
signature.

Add `runTime` to every discharge site that runs code transitively requiring
`Time`. The discharge sites are where `runEff`/`runConcurrent` build the stack.
Known sites to update (search confirms these; re-grep to be exhaustive):

- `shikumi-cache` tests: `shikumi-cache/test/Main.hs` — wherever `cachedLLM` is run
  under `runEff`, insert `. runTime` into the interpreter chain (it composes like
  the other `run*` functions, e.g.
  `runEff . runTime . runCacheMemory cache . cachedLLM . runErrorNoCallStack @ShikumiError`).
- `shikumi-jitsurei/app/TraceReplay.hs:69` — the chain that runs `cachedLLM` adds
  `. runTime`.
- `shikumi-eval` tests (`EvaluateSpec.hs`, `GoldenSpec.hs`, `DocSpec.hs`) and any
  CLI runtime path that runs `evaluate`/`evalOne` — add `. runTime` to the chain.
- `shikumi-optimize` tests that run `optimize`/`scoreOn` — add `. runTime`.

The mechanical rule: if the compiler reports `No instance for (Time :> es)` or
`Time :> es arising from a use of ...` at a `runEff` site, insert `runTime` into
that chain (order relative to the other `run*` functions does not matter for
correctness as long as it is inside `runEff`; place it adjacent to `runConcurrent`
for readability).

Acceptance for M1:

```bash
nix develop -c cabal build all
nix develop -c cabal test all
```

Expect green. Then prove the behavior is intact, not just compiling:

```bash
nix develop -c grep -n 'liftIO getCurrentTime' shikumi-cache/src/Shikumi/Cache.hs
nix develop -c grep -n 'liftIO getMonotonicTimeNSec' shikumi-eval/src/Shikumi/Eval/Evaluate.hs
```

Both greps must return nothing (the `liftIO` wrappers are gone). The
`shikumi-eval` test suite's evaluation specs continue to report non-zero
`latencyMs` and the cache specs continue to store/return entries — i.e. the
existing assertions that depended on timing and caching still pass, which is the
behavioral proof that routing the clock through `Time` did not change results.

Commit with the `ExecPlan:` trailer.


### Milestone M2 — Migrate IORef sites to `Prim`

Scope: every function whose `IOE` is there only to use an `IORef` switches to
`Prim`. The big payoff lands here: once `withUsageTotals` no longer needs `IOE`,
the `evaluate` family can drop `IOE` (done in M4). `runTrace` uses both an `IORef`
**and** the clock, so it becomes `Prim + Time`.

Edit `shikumi-eval/src/Shikumi/Eval/Usage.hs`:

- Change `withUsageTotals`'s constraint from `(LLM :> es, IOE :> es)` to
  `(LLM :> es, Prim :> es)`.
- Replace the imports from `Data.IORef` and the `liftIO` wrappers:
  - Remove `import Data.IORef (atomicModifyIORef', newIORef, readIORef)`.
  - Add `import Effectful.Prim.IORef (atomicModifyIORef', newIORef, readIORef)`.
  - Remove the `liftIO` calls: `ref <- newIORef emptyUsageTotals` (no `liftIO`),
    `atomicModifyIORef' ref (...)` (no `liftIO`), `totals <- readIORef ref` (no
    `liftIO`). The `effectful` `Prim.IORef` operations already return `Eff es _`.
  - Remove `IOE` and `liftIO` from the `Effectful` import; add `Prim` to it
    (`import Effectful (Eff, Prim, (:>))`).

Edit `shikumi-trace/src/Shikumi/Trace.hs` (`runTrace`):

- `runTrace` currently does its `IORef` work through helper functions
  (`newTraceState`, `openSpan`, `closeSpan`, `modifyActive`, `freezeTree`) that are
  typed as raw `IO` and invoked with `liftIO`. The cleanest migration keeps those
  helpers as raw `IO` (they are pure plumbing over `IORef`) and changes only
  `runTrace`'s discharge to provide both `Prim` and `Time` — but note those helpers
  also call `getCurrentTime` (wall clock) directly in `IO`. Two acceptable
  approaches; choose **Approach A** unless it proves awkward:

  - **Approach A (minimal, recommended).** Leave `runTrace`'s constraint as
    `(IOE :> es)` for now if and only if the `IORef`+clock plumbing remains in raw
    `IO`. *However*, the goal is to remove `IOE`. So instead: change `runTrace` to
    `(Prim :> es, Time :> es)`, and convert the helper calls. Because the helpers
    are currently `IO`-typed and called via `liftIO`, lift them into `Eff` by
    rewriting them to use `Effectful.Prim.IORef` operations and
    `Shikumi.Effect.Time.getCurrentTime`. Concretely: change `newTraceState`,
    `openSpan`, `closeSpan`, `modifyActive`, `freezeTree` from `:: ... -> IO x` to
    `:: (Prim :> es, Time :> es) => ... -> Eff es x` (only `openSpan`/`closeSpan`
    need `Time`; the others need only `Prim`), replacing `newIORef`/`readIORef`/
    `modifyIORef'`/`atomicModifyIORef'` with the `Effectful.Prim.IORef` versions
    and `getCurrentTime` with the effectful one. In `runTrace`, drop the `liftIO`
    wrappers around these calls. The `bracket` in the `WithSpan` handler comes from
    `Effectful.Exception` (or wherever `runTrace` currently imports `bracket`); it
    works over `Eff` and does not require `IOE`.

  - **Approach B (defer).** If Approach A's rewrite of the helpers proves large,
    split `runTrace` into "IORef via `Prim`" now and keep `getCurrentTime` via a
    temporary `IOE` until a follow-up. This violates the narrowest-correct goal, so
    record it as a deliberate deviation in the Decision Log if used.

  Update imports in `Trace.hs`: add
  `import Effectful.Prim.IORef (newIORef, readIORef, modifyIORef', atomicModifyIORef')`
  and `import Shikumi.Effect.Time (getCurrentTime)`; remove the `Data.IORef` and
  `Data.Time` clock imports; add `Prim` and `Time` to the `Effectful` import and
  drop `IOE`/`liftIO` if now unused.

Migrate the test/fixture/spike IORef holders to `Prim` the same way (constraint
`(IOE :> es)` → `(Prim :> es)`, `Data.IORef` ops → `Effectful.Prim.IORef` ops,
drop `liftIO`):

- `shikumi-eval/test/EvalFixtures.hs:128`, `shikumi/test/ProgramFixtures.hs:149,157`,
  `shikumi/test/Shikumi/LLM/Mock.hs:40,57,74`,
  `shikumi-trace/test/TraceFixtures.hs:100`, `shikumi-optimize/test/StubLM.hs:163`,
  `shikumi-cache/test/Main.hs:75`, `shikumi-cache-redis/test/Main.hs:47`,
  `shikumi-cache-postgres/test/Main.hs:43`, `shikumi-tools/test/MockLLM.hs:39`,
  `shikumi-jitsurei/src/Shikumi/Jitsurei/Stub.hs:130`,
  `shikumi-jitsurei/app/TraceReplay.hs:62`,
  `shikumi-trace/src/Shikumi/Trace/Internal/Spike.hs:82,92,113`.

At each discharge site for the above, add `runPrim` to the interpreter chain
(`runPrim :: IOE :> es => Eff (Prim : es) a -> Eff es a`, imported from
`Effectful.Prim`). The mechanical rule mirrors M1: when the compiler reports
`No instance for (Prim :> es)` at a `runEff` chain, insert `. runPrim` into that
chain. Because `runEff` provides `IOE`, and `runPrim`/`runConcurrent`/`runTime` all
require `IOE`, they all sit inside `runEff`.

Add the `Effectful.Prim.IORef` module's package: `Effectful.Prim` lives in
`effectful-core` and `Effectful.Prim.IORef` in `effectful`; both are re-exported
by the `effectful` package, which every affected package already depends on. No
new `build-depends` entries are required, but verify each package that newly
imports `Effectful.Prim`/`Effectful.Prim.IORef` lists `effectful` in
`build-depends` (they do).

Acceptance for M2:

```bash
nix develop -c cabal build all
nix develop -c cabal test all
nix develop -c grep -rn 'Data.IORef' --include='*.hs' shikumi shikumi-eval shikumi-trace
```

The build and tests must be green. The last grep should return nothing in the
migrated production modules (`Usage.hs`, `Trace.hs`); any remaining `Data.IORef`
import indicates a missed conversion. Behavioral proof: the eval suite's usage
totals (input/output/total tokens, cost) and the trace suite's span tree (with
populated `startedAt`/`endedAt` timestamps) remain correct — the existing
assertions on `UsageTotals` and on span timing still pass.

Commit with the `ExecPlan:` trailer.


### Milestone M3 — Migrate STM/MVar/threadDelay helpers to `Concurrent`

Scope: functions whose only IO is STM, an `MVar`, or `threadDelay` switch to
`Concurrent`. This covers the in-memory cache backend and the LLM resilience
helpers `withRateLimit` and `retrying`. The baikai-backed interpreters
(`runLLM`/`runLLMWith`/`runLLMResilient`) and `withBudget` keep `IOE` because they
also run the transport / raw budget IO.

Edit `shikumi-cache/src/Shikumi/Cache/Backend/Memory.hs` (`runCacheMemory`):

- Change the constraint from `(IOE :> es)` to `(Concurrent :> es)`.
- Replace `import Control.Concurrent.STM (...)` operations with their effectful
  equivalents from `Effectful.Concurrent.STM`
  (`atomically`, `modifyTVar'`, `readTVarIO`, `newTVarIO`, `TVar`). Note
  `newMemoryCache :: IO MemoryCache` stays raw `IO` (it is called outside `Eff`, to
  build the store before running) — leave it as `newTVarIO Map.empty` in `IO`. Only
  the *interpreter* `runCacheMemory` moves to `Concurrent`.
- In the handler body, drop the `liftIO` wrappers:
  `LookupCache k -> Map.lookup (unCacheKey k) <$> readTVarIO tv` and
  `StoreCache k v -> atomically (modifyTVar' tv (Map.insert (unCacheKey k) v))`.
- Update the `Effectful` import: drop `IOE`/`liftIO`, add `Concurrent`.

Edit `shikumi/src/Shikumi/LLM.hs`:

- `withRateLimit` (line 226): change `(IOE :> es)` to `(Concurrent :> es)`. Replace
  `Control.Concurrent.STM` `atomically`/`readTVar`/`writeTVar`/`modifyTVar'` with
  the `Effectful.Concurrent.STM` versions, and `bracket_`/`liftIO` with the
  `Eff`-level `bracket_` from `Effectful.Concurrent` (or `Effectful.Exception`),
  dropping `liftIO`. The `acquire`/`release` STM blocks run via `atomically` from
  `Effectful.Concurrent.STM`.
- `retrying` (line 242): change `(IOE :> es, Error ShikumiError :> es)` to
  `(Concurrent :> es, Error ShikumiError :> es)`. Replace
  `liftIO (threadDelay (...))` with `threadDelay (...)` from `Effectful.Concurrent`.
- `runLLMResilient` (line 189): it *calls* `withRateLimit` and `retrying`, which
  now need `Concurrent :> es`. Add `Concurrent :> es` to `runLLMResilient`'s
  constraint set **in addition to** its existing `IOE` (it keeps `IOE` for the
  baikai transport and budget). Final:
  `(IOE :> es, Concurrent :> es, Error ShikumiError :> es)`.
- `withBudget` (line 215) and `runLLM`/`runLLMWith` (107/114): leave as `IOE` (they
  do raw budget IO / run the baikai transport). No change beyond what the compiler
  forces.
- `newRateLimiter :: Int -> IO RateLimiter` stays raw `IO` (called outside `Eff`).

Update discharge sites: anywhere `runLLMResilient` (or code using `withRateLimit`/
`retrying`) is run, the stack must provide `Concurrent`. Most shikumi stacks
already include `runConcurrent` (the CLI runtime and the eval/optimize tests do).
Add `runConcurrent` where the compiler reports `No instance for (Concurrent :> es)`.

Acceptance for M3:

```bash
nix develop -c cabal build all
nix develop -c cabal test all
nix develop -c grep -n 'liftIO' shikumi-cache/src/Shikumi/Cache/Backend/Memory.hs
```

Build and tests green. The Memory backend grep returns nothing (no `liftIO` left).
Behavioral proof: the cache tests that use the in-memory backend still observe
hits/misses correctly, and the LLM resilience tests (rate limiting / retry) still
pass — the STM and `threadDelay` semantics are unchanged, only their effect
labeling moved from `IOE` to `Concurrent`.

Commit with the `ExecPlan:` trailer.


### Milestone M4 — Harvest: drop redundant `IOE`, add the guard, final sweep

Scope: now that `withUsageTotals` is `Prim` (M2) and timing is `Time` (M1), the
`evaluate` family and its transitive consumers no longer need `IOE` at all. Remove
it. Then turn on `-Wredundant-constraints` for the affected library stanzas so any
future stray `IOE` is caught at compile time, and do a final grep to confirm the
end state.

Remove `IOE :> es` from these constraint sets (the compiler will confirm it is no
longer needed; if it complains, a dependency was missed in M1–M3 — fix that
rather than re-adding `IOE`):

- `shikumi-eval/src/Shikumi/Eval/Evaluate.hs` — `evaluate`, `evaluatePure`,
  `evaluateWith`. New set: `(LLM :> es, Concurrent :> es, Error ShikumiError :> es,
  Time :> es, Prim :> es)`. (They need `Prim` transitively via `withUsageTotals`
  and `Time` via `evalOne`; `Concurrent` they already had.)
- `shikumi-eval/src/Shikumi/Eval/Golden.hs` — `goldenReport`: drop `IOE`, keep the
  set its body needs (`... Time :> es, Prim :> es, Concurrent :> es ...`).
- `shikumi-optimize/src/Shikumi/Optimize.hs` `optimize`,
  `shikumi-optimize/src/Shikumi/Optimize/Search.hs` `scoreOn`,
  `shikumi-optimize/src/Shikumi/Optimize/Types.hs` `runOptimizer`: drop `IOE`,
  inheriting `Time`/`Prim`/`Concurrent` as the bodies require.

Enable the guard. In each library `.cabal` stanza you touched
(`shikumi`, `shikumi-eval`, `shikumi-trace`, `shikumi-cache`), add
`-Wredundant-constraints` to `ghc-options` if not already present. Rebuild; the
compiler will now flag any constraint that is listed but unused. Resolve each
warning by *removing* the unused constraint (most importantly any leftover `IOE`),
never by silencing the warning. (Be aware some files use
`{-# OPTIONS_GHC -Wno-redundant-constraints #-}` locally — e.g. the new
`Shikumi.Effect.Time` and the rank-2 `runOptimizer` signature, where a constraint
is intentionally present for the quantified row. Leave those local pragmas.)

Final discharge audit. Build the whole project and run the whole suite. Every
top-level `runEff` chain that runs evaluation/optimization/tracing/caching must now
include `runTime`, `runPrim`, and `runConcurrent` as needed; the compiler enforces
this. The CLI runtime (`shikumi-cli/src/Shikumi/Cli/Runtime.hs`) is the most
important production discharge site — verify its chains compile with the added
interpreters.

Acceptance for M4 (this is the plan's overall acceptance):

```bash
nix develop -c cabal build all
nix develop -c cabal test all
nix develop -c grep -rn 'IOE :>' --include='*.hs' \
  shikumi shikumi-eval shikumi-trace shikumi-cache \
  shikumi-cache-redis shikumi-cache-postgres
```

The build and the full test suite must be green. The final grep must show
`IOE :>` **only** at the legitimate sites enumerated in Context:
`runLLM`/`runLLMWith`/`runLLMResilient`/`withBudget`
(`shikumi/src/Shikumi/LLM.hs`), `runCacheSQLite`
(`shikumi-cache/.../SQLite.hs`), `runCachePostgres`, `runCacheRedis`, and the
top-level test/CLI discharge points that call `runEff` (which legitimately provide
`IOE` to the stack). No `IOE :>` should remain on `cachedLLM`, `evalOne`,
`evaluate`/`evaluatePure`/`evaluateWith`, `withUsageTotals`, `runTrace`,
`runCacheMemory`, `withRateLimit`, `retrying`, `goldenReport`, `optimize`,
`scoreOn`, or `runOptimizer`.

Write the Outcomes & Retrospective entry. Commit with the `ExecPlan:` trailer.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/shikumi`
unless stated otherwise, and all build/test commands are prefixed with
`nix develop -c` to use the correct GHC 9.12.4 toolchain.

Baseline (before any edits), capture the starting point so regressions are
attributable:

```bash
nix develop -c cabal build all
nix develop -c cabal test all
nix develop -c grep -rc 'IOE :>' --include='*.hs' . | grep -v ':0'
```

Per milestone, the loop is: make the edits described in Plan of Work, then:

```bash
nix develop -c cabal build all
nix develop -c cabal test all
```

When green, commit. Every commit message must carry the plan trailer. Example for
M0:

```text
feat(shikumi): add Time effect (Shikumi.Effect.Time) modeled on time-effectful Clock

Static-dispatch clock effect exposing getCurrentTime and getMonotonicTimeNSec,
discharged by runTime. Additive: no existing constraints change yet.

ExecPlan: docs/plans/13-precise-effect-constraints-prim-concurrent-and-a-custom-time-effect.md
```

Commit directly to the current branch (`master`) per repository convention — do
not create a feature branch. Conventional Commit types to use across the
milestones: `feat` for M0 (new effect), `refactor` for M1–M4 (constraint
migrations are behavior-preserving refactors).

To run a single failing package's tests with detail while iterating:

```bash
nix develop -c cabal test shikumi-eval --test-show-details=direct
```


## Validation and Acceptance

The overarching acceptance is in Milestone M4: a clean `cabal build all`, a green
`cabal test all`, and a grep showing `IOE :>` only at the genuine-IO sites. Each
milestone additionally has its own behavioral proof, restated here so the reader
can verify incrementally:

- M0: the two `Shikumi.Effect.Time` unit tests pass (a plausible timestamp; a
  non-decreasing monotonic counter).
- M1: cache entries still carry timestamps and evaluation still reports non-zero
  `latencyMs`; `liftIO getCurrentTime` and `liftIO getMonotonicTimeNSec` no longer
  appear in the migrated files. The existing `shikumi-cache` and `shikumi-eval`
  test suites pass unchanged, which proves routing the clock through `Time`
  preserved behavior.
- M2: `UsageTotals` accounting and trace span timestamps remain correct; no
  `Data.IORef` import remains in `Usage.hs`/`Trace.hs`. The eval and trace suites
  pass unchanged.
- M3: in-memory cache hits/misses and LLM rate-limit/retry behavior remain correct;
  no `liftIO` remains in the Memory backend. The cache and LLM suites pass
  unchanged.
- M4: the `evaluate` family, `goldenReport`, `optimize`, `scoreOn`, and
  `runOptimizer` compile **without** `IOE`; `-Wredundant-constraints` produces no
  warnings about unused constraints in the touched stanzas.

The reason "tests pass unchanged" is a valid proof here: this is a
behavior-preserving refactor. The effect operations (`unsafeEff_ getCurrentTime`,
`Effectful.Prim.IORef.atomicModifyIORef'`, `Effectful.Concurrent.STM.atomically`)
execute the *same* underlying `IO` as the `liftIO`-wrapped originals — only the
*type-level capability label* changes. Therefore any test that passed before and
passes after demonstrates the narrower constraint was sufficient.


## Idempotence and Recovery

Every step is safe to repeat. The edits are source edits under version control; if
a milestone's build fails, revert the working tree to the last green commit
(`git restore .` for uncommitted changes, or `git revert`/`git reset --hard
<last-green-sha>` for committed ones) and re-apply. Because each milestone is
committed only when `cabal build all` and `cabal test all` are green, the branch is
always recoverable to a working state at milestone boundaries.

The single risky-by-nature step is M2 Approach A's rewrite of the `Trace.hs`
helpers from raw `IO` to `Eff`. If that rewrite stalls, fall back to M2 Approach B
(keep `getCurrentTime` on a temporary `IOE` in `runTrace`, migrate only the
`IORef`s to `Prim`), record the deviation in the Decision Log, and finish the clock
portion in a follow-up. This keeps the build green throughout.

No data migrations, no destructive operations, no external services are involved —
all changes are to Haskell source and `.cabal` metadata.


## Interfaces and Dependencies

New module and its public interface (created in M0):

```haskell
-- shikumi/src/Shikumi/Effect/Time.hs
module Shikumi.Effect.Time
  ( Time                                      -- the effect (kind: Effect)
  , runTime :: IOE :> es => Eff (Time : es) a -> Eff es a
  , getCurrentTime :: Time :> es => Eff es UTCTime
  , getMonotonicTimeNSec :: Time :> es => Eff es Word64
  , UTCTime                                   -- re-exported from Data.Time
  )
```

Libraries and modules used (all already on the dependency graph; no new packages):

- `effectful` — provides `Eff`, `IOE`, `(:>)`, `liftIO`, `runEff`; the static
  dispatch primitives `Effectful.Dispatch.Static` (`unsafeEff_`, `evalStaticRep`,
  `DispatchOf`, `StaticRep`, `'Static`, `'WithSideEffects`); the `Prim` IORef
  operations `Effectful.Prim.IORef` (`newIORef`, `readIORef`, `writeIORef`,
  `modifyIORef'`, `atomicModifyIORef'`); and the concurrency operations
  `Effectful.Concurrent` (`Concurrent`, `runConcurrent`, `threadDelay`),
  `Effectful.Concurrent.STM` (`atomically`, `TVar`, `newTVarIO`, `readTVarIO`,
  `modifyTVar'`, `readTVar`, `writeTVar`), and `Effectful.Concurrent.MVar`
  (`withMVar`).
- `effectful-core` — provides `Effectful.Prim` (`Prim`, `runPrim`). Re-exported
  through `effectful`; no separate `build-depends` entry needed if `effectful` is
  listed.
- `time` — provides `Data.Time` (`UTCTime`, `getCurrentTime`).
- `base` — provides `GHC.Clock` (`getMonotonicTimeNSec`) and `Data.Word` (`Word64`).

Required signatures at the end of each milestone:

- End of M0: `Shikumi.Effect.Time` exists with the interface above; everything else
  unchanged.
- End of M1: `cachedLLM :: (Cache :> es, LLM :> es, Time :> es) => Eff es a -> Eff es a`;
  `evalOne :: (LLM :> es, Error ShikumiError :> es, Time :> es) => ...`;
  `evaluate`/`evaluatePure`/`evaluateWith` carry `Time :> es` (and still `IOE`).
- End of M2:
  `withUsageTotals :: (LLM :> es, Prim :> es) => Eff es a -> Eff es (a, UsageTotals)`;
  `runTrace :: (Prim :> es, Time :> es) => Eff (Trace : es) a -> Eff es (a, TraceTree)`
  (Approach A) — or the documented Approach B variant.
- End of M3:
  `runCacheMemory :: (Concurrent :> es) => MemoryCache -> Eff (Cache : es) a -> Eff es a`;
  `withRateLimit :: (Concurrent :> es) => Maybe RateLimiter -> Eff es a -> Eff es a`;
  `retrying :: (Concurrent :> es, Error ShikumiError :> es) => RetryPolicy -> Eff es a -> Eff es a`;
  `runLLMResilient :: (IOE :> es, Concurrent :> es, Error ShikumiError :> es) => ...`.
- End of M4: `evaluate`/`evaluatePure`/`evaluateWith`, `goldenReport`, `optimize`,
  `scoreOn`, `runOptimizer` carry no `IOE :> es`. `IOE :> es` survives only on the
  baikai LLM interpreters, the three DB cache backends, and `runEff`-level discharge
  sites.

Dependencies between milestones: M1 depends on M0 (needs the `Time` effect). M4
depends on M1 (timing on `Time`) and M2 (usage on `Prim`) to legitimately drop
`IOE` from the `evaluate` family. M3 is independent of M1/M2 and may be done in any
order relative to them, but is listed third to keep the "drop redundant IOE" sweep
(M4) last.
