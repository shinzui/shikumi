---
id: 47
slug: cli-hardening-and-cli-layer-tests
title: "CLI Hardening and CLI-Layer Tests"
kind: exec-plan
created_at: 2026-07-02T03:30:16Z
intention: "intention_01kwjfeaw5e2f84jyjm4j6mdj0"
master_plan: "docs/masterplans/8-tools-agents-and-cli-hardening.md"
---

# CLI Hardening and CLI-Layer Tests

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

The `shikumi` command line (package `shikumi-cli`) runs, traces, optimizes, and
replays typed LM programs. Two hardening gaps and one coverage gap exist today.
First, the trace id a user types (`shikumi trace <TRACE-ID>`) is spliced into a
filesystem path completely unvalidated, so `shikumi trace '../../foo'` reads — and
`shikumi record --program` would write — outside the trace store directory. Second,
`shikumi replay` collapses two distinct failure modes ("the replayed run errored"
vs. "the reference run errored") into one vague message, so a user cannot tell what
actually broke. Third, and the reason such things went unnoticed: there are **no**
tests of the CLI layer itself — `parseCommand`, `dispatch`, the unknown-task
message, store-dir handling, exit codes — only the underlying runtime capabilities
are tested.

After this plan, path-escaping trace ids are rejected with a clear one-line error
and a non-zero exit before any file IO happens; replay failures name the failing
side and the underlying error; and a golden-style test group drives the real
`dispatch` function end-to-end (offline, against the bundled example registry),
pinning stdout/stderr text and exit behavior so future CLI regressions fail a test
instead of a user.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented
here, even if it requires splitting a partially completed task into two ("done" vs.
"remaining"). This section must always reflect the actual current state of the work.

- [x] M1: `validTraceId` guard in Run.hs; wired into trace, replay, and record
      handlers; replay failure messages split. Completed 2026-07-04.
- [x] M2: `parseCommand` cases, pure trace-id/replay-message assertions, and a
      dispatch record/store-dir case in the shikumi-cli test suite;
      `optparse-applicative` added to test build-depends. Completed 2026-07-04.
- [x] Final: `just test-one shikumi-cli` green; `cabal build all` green; manual
      invalid-trace smokes produce exit 1; commit prepared with required trailers.
      Completed 2026-07-04.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- In-process stdout/stderr capture with `hDuplicate`/`hDuplicateTo` was unstable
  under Tasty on this macOS runner because tests can race over global handles and
  `exitFailure` paths can destabilize the test process. The implementation instead
  exposes pure `validTraceId` and `replayFailureMessage` helpers for exact message
  assertions, keeps dispatch coverage for the non-failing record path, and records
  manual `exe:shikumi` smokes for the actual stderr/exit behavior. Evidence:
  earlier capture-based attempts aborted the test executable; the final
  `just test-one shikumi-cli` passed 10 tests, and manual invalid-trace commands
  exited 1 with the expected message.
  Date: 2026-07-04


## Decision Log

- Decision: Validate trace ids with a conservative reject-list (empty, `.`, `..`,
  any `/` or `\\`, any `..` occurrence) rather than an allow-list of characters.
  Rationale: Trace ids double as registered program names (the `record` command
  writes `<store-dir>/<program-name>.json`), and program names are free-form Text
  chosen by library users; an allow-list would silently break exotic-but-harmless
  names. The reject-list blocks exactly the path-traversal vectors
  (`System.FilePath.</>` only interprets separators and `..`). Absolute paths are
  covered by the `/` rejection.
  Date: 2026-07-01

- Decision: Test stdout/stderr capture with handle duplication
  (`GHC.IO.Handle.hDuplicate`/`hDuplicateTo` from base) into temp files instead of
  adding a capture dependency (e.g. the `silently` package).
  Rationale: Zero new dependencies; the technique is ~15 lines, deterministic for
  this suite (single-threaded test IO), and the handles are restored in a bracket.
  Date: 2026-07-01

- Decision: Replace handle-duplication transcript tests with pure message-helper
  tests plus manual `exe:shikumi` smoke checks for stderr/exit behavior.
  Rationale: The handle-capture approach proved brittle under the actual Tasty
  runner on macOS. Exporting small pure helpers keeps the message text pinned in
  unit tests, while the manual smoke confirms the CLI still prints the same message
  and exits nonzero. No production behavior changed.
  Date: 2026-07-04


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

- EP-47 complete: trace, replay, and record now reject path-escaping trace ids
  before constructing trace-store paths; replay failure messages distinguish the
  replayed run from the reference stub run; and the CLI package has parser/helper
  and dispatch-level tests for the CLI layer. Validation: `just test-one
  shikumi-cli` passed 10 tests, `cabal build all` succeeded, and manual
  `cabal run exe:shikumi -- trace ../../etc/passwd` plus `cabal run exe:shikumi --
  replay a/b` each printed `Invalid trace id ...` and exited 1. Date: 2026-07-04.


## Context and Orientation

Haskell cabal multi-package repo. This plan touches only the `shikumi-cli` package:
library sources in `shikumi-cli/src`, one executable (`shikumi-cli/app/Main.hs`),
one tasty/HUnit test suite (`shikumi-cli/test/Main.hs`,
stanza `shikumi-cli-test` in `shikumi-cli/shikumi-cli.cabal`). Build and test from
the repo root inside the dev shell: `nix develop .#ghc9124`, then
`just test-one shikumi-cli` (runs `cabal test shikumi-cli`).

How the CLI fits together (all paths repo-relative):

- `shikumi-cli/src/Shikumi/Cli/Options.hs` — the parsed-command algebra and its
  `optparse-applicative` parser. `parseCommand :: ParserInfo (GlobalOpts, Command)`
  (lines 63–70). `GlobalOpts` carries `storeDir :: FilePath` (flag `--store-dir`,
  default `.shikumi`) and `otel :: Bool`. The trace and replay subcommands take the
  trace id as a **positional argument** (`traceP`, lines 111–112, and `replayP`,
  lines 114–115: `argument str (metavar "TRACE-ID" …)`) — completely
  unconstrained text.
- `shikumi-cli/src/Shikumi/Cli.hs` — `cliMain` parses argv and calls
  `dispatch :: Registry -> GlobalOpts -> Command -> IO ()` (lines 33–39), the pure
  routing seam this plan's tests drive.
- `shikumi-cli/src/Shikumi/Cli/Run.hs` — the five handlers. The vulnerable path
  builder is `traceFilePath` (lines 156–158):

```haskell
traceFilePath :: GlobalOpts -> Text -> FilePath
traceFilePath g tid = storeDir g </> T.unpack tid <.> "json"
```

  `System.FilePath.(</>)` happily accepts `../../foo` (and an absolute
  `/etc/whatever` — an absolute right operand *replaces* the left), so
  `shikumi trace '../../foo'` escapes the store; `runRecordCmd` (lines 129–138)
  even *writes* through the same function using the `--program` name. The vague
  replay message is `runReplayCmd`'s final case arm (line 125):
  `_ -> die "replay failed (program error during replay or reference run)"`,
  which hides whether `runReplayProgram` or `runStubProgram` failed and the error
  itself. `withTask` (lines 145–154) is the unknown-task path: it dies with
  `Unknown program: <name>` plus the registered names. `die` (lines 173–175)
  prints to stderr and calls `exitFailure` — which throws the `ExitFailure 1`
  exception that tests can catch.
- `shikumi-cli/src/Shikumi/Cli/Example.hs` — the bundled offline example:
  `exampleRegistry :: Registry` registers one task named `"sentiment"` with a
  deterministic stub responder (`exampleResponder`); everything runs with zero
  network. The existing test suite (`shikumi-cli/test/Main.hs`) exercises the
  *runtime* capabilities (`runStubEval`, `recordTrace`, `runReplayProgram`, …)
  directly — it never calls `parseCommand` or `dispatch`, never asserts an error
  message, and never observes an exit code. That is the coverage gap.

Terms: a *golden test* here means asserting that captured stdout/stderr contains
pinned, human-visible fragments (we assert fragments rather than byte-identical
transcripts because trace rendering includes wall-clock timings). *Exit code*
observation means catching the `ExitCode` exception `System.Exit.exitFailure`
throws (`ExitFailure 1`) — in-process, no subprocess needed.


## Plan of Work

### Milestone 1 — trace-id validation and distinct replay failures

Scope: `shikumi-cli/src/Shikumi/Cli/Run.hs` only. At the end,
`shikumi trace '../../foo'` (and `replay`, and a hostile `--program` name via
`record`) dies with a validation message before touching the filesystem, and
replay's two failure modes are reported distinctly.

Add a validator next to `traceFilePath` and export nothing new from the module
(the handlers are the public surface; the validator is tested through them —
keep it private):

```haskell
-- | Reject trace ids that could escape the store directory when spliced into a
-- path: empty ids, ".", anything containing a path separator, and anything
-- containing "..". Trace ids double as program names, so this is a reject-list,
-- not an allow-list.
validTraceId :: Text -> Either Text Text
validTraceId tid
  | T.null tid = Left "trace id must not be empty"
  | tid == "." = Left "trace id must not be \".\""
  | "/" `T.isInfixOf` tid = Left "trace id must not contain path separators"
  | "\\" `T.isInfixOf` tid = Left "trace id must not contain path separators"
  | ".." `T.isInfixOf` tid = Left "trace id must not contain \"..\""
  | otherwise = Right tid
```

Wire it in as the *first* action of the three handlers that turn an id into a path
— `runTraceCmd` (lines 56–71), `runReplayCmd` (lines 104–125), and `runRecordCmd`
(lines 129–138) — with a shared helper:

```haskell
withValidTraceId :: Text -> (Text -> IO ()) -> IO ()
withValidTraceId tid k = case validTraceId tid of
  Left reason -> die ("Invalid trace id: " <> tid <> " (" <> reason <> ")")
  Right ok -> k ok
```

e.g. `runTraceCmd g (TraceOpts tid) = withValidTraceId tid $ \_ -> do …` (the
body unchanged). For `runRecordCmd` validate the program name *before*
`createDirectoryIfMissing`/`writeTraceFile` so a hostile name causes zero writes.
`runEval`/`runOptimizeCmd` build no path from the name, so they stay as they are
(the unknown-name path already dies cleanly via `withTask`).

Split the replay message (line 125). Replace the final `_ -> die …` arm of the
`case (replayed, reference) of` with two informative arms (order matters — put
them after the `(Right ro, Right refo)` success arm):

```haskell
(Left err, _) -> die ("replay failed: the replayed run errored: " <> tshow err)
(_, Left err) -> die ("replay failed: the reference (stub) run errored: " <> tshow err)
```

This milestone is complete when `cabal build shikumi-cli` succeeds and a manual
smoke run behaves as below (run inside the dev shell, from the repo root; the
bundled executable uses the example registry):

```bash
cabal run shikumi -- trace '../../etc/passwd'; echo "exit=$?"
```

expected:

```text
Invalid trace id: ../../etc/passwd (trace id must not contain path separators)
exit=1
```

whereas before the change the same command prints the "No trace found with id:
../../etc/passwd (looked for .shikumi/../../etc/passwd.json; …)" message — i.e.
it demonstrably built the escaping path.

### Milestone 2 — CLI-layer tests through parseCommand and dispatch

Scope: `shikumi-cli/test/Main.hs` and the test-suite stanza of
`shikumi-cli/shikumi-cli.cabal`. At the end, a new test group "cli-layer" drives
the real parser and dispatcher offline.

Cabal change: add `optparse-applicative` to `shikumi-cli-test`'s `build-depends`
(the library already depends on it; the test suite needs it for
`execParserPure`).

The final implementation does not use the handle-duplication capture helper
originally sketched here. That approach proved unstable under Tasty on this macOS
runner, so the test suite pins the exact message text through pure helpers exported
from `Shikumi.Cli.Run`: `validTraceId` and `replayFailureMessage`. A small
`parses :: [String] -> Maybe (GlobalOpts, Command)` helper wraps
`execParserPure defaultPrefs parseCommand args` and maps `Success` to `Just`.

The cases, all in one new `testGroup "cli-layer"` appended to the existing tree
(the dispatch case uses `exampleRegistry` from `Shikumi.Cli.Example` and a fresh
temp store dir so it is independent and re-runnable):

1. *Parsing*: `["trace", "sentiment"]` parses to
   `(GlobalOpts ".shikumi" False, CmdTrace (TraceOpts "sentiment"))` — pins the
   store-dir default and the positional id.
   `["--store-dir", "/tmp/x", "--otel", "trace", "t"]` pins flag handling.
   `["eval", "--program", "sentiment"]` parses to `CmdEval`; `["bogus-command"]`
   and `["eval"]` (missing required flag) both produce a parse `Failure`
   (`parses … @?= Nothing`).
2. *Trace-id rejection*: pure `validTraceId` assertions cover empty ids, `.`, `/`,
   `\\`, `..`, and a valid `sentiment` id. The exact reasons are the same strings
   `withValidTraceId` embeds in the CLI error line.
3. *Dispatch store-dir behavior*: dispatching `CmdRecord (RecordOpts
   "sentiment")` through `dispatch exampleRegistry` creates
   `<temp-store>/sentiment.json`, proving the CLI-layer route wires the configured
   store directory through to `Run.hs`.
4. *Replay failure distinguishes sides*: pure `replayFailureMessage` assertions
   pin both `"the replayed run errored"` and `"the reference (stub) run errored"`
   variants and assert the old vague message no longer appears.


## Concrete Steps

From the repo root:

```bash
nix develop .#ghc9124
cabal build shikumi-cli
just test-one shikumi-cli
```

Manual smoke of M1 (before writing tests, to see the behavior change):

```bash
cabal run shikumi -- trace '../../etc/passwd'; echo "exit=$?"
# expect: Invalid trace id: ../../etc/passwd (trace id must not contain path separators)
# exit=1
cabal run shikumi -- replay 'a/b'; echo "exit=$?"
# expect: Invalid trace id: a/b (trace id must not contain path separators)
```

Expected suite tail when done (fragment):

```text
  shikumi-cli
    eval renders a deterministic Report (score 0.5, 2/4 pass): OK
    ...
    cli-layer
      parseCommand covers defaults, flags, and parse failures:               OK
      validTraceId rejects path-escaping ids with user-facing reasons:       OK
      invalid record ids are rejected before the store directory is created: OK
      dispatch: record creates a trace inside the configured store dir:      OK
      replayFailureMessage names the failing side:                           OK

All N tests passed
```

Commits (Conventional Commits; both must carry the three trailers):

```text
fix(cli): reject path-escaping trace ids; split replay failure messages

MasterPlan: docs/masterplans/8-tools-agents-and-cli-hardening.md
ExecPlan: docs/plans/47-cli-hardening-and-cli-layer-tests.md
Intention: intention_01kwjfeaw5e2f84jyjm4j6mdj0
```

```text
test(cli): golden CLI-layer tests through parseCommand and dispatch

MasterPlan: docs/masterplans/8-tools-agents-and-cli-hardening.md
ExecPlan: docs/plans/47-cli-hardening-and-cli-layer-tests.md
Intention: intention_01kwjfeaw5e2f84jyjm4j6mdj0
```


## Validation and Acceptance

Acceptance is behavioral and offline (no network, no API keys):

1. `cabal run shikumi -- trace '../../etc/passwd'` prints the one-line
   `Invalid trace id: …` message to stderr and exits 1; before the change it
   printed a "No trace found … looked for .shikumi/../../etc/passwd.json"
   message proving the escaping path was constructed. `shikumi record` with a
   hostile program name creates no directories and writes no files.
2. A replay whose replayed run errors reports `replay failed: the replayed run
   errored: <error>`; the old single vague message no longer exists in the
   codebase (`grep -rn "program error during replay or reference run"
   shikumi-cli/src` returns nothing).
3. `just test-one shikumi-cli` passes with the new "cli-layer" group. The
   trace-id-rejection and replay-message assertions fail if the M1 helpers are
   reverted.
4. The dispatch record case proves store-dir handling end-to-end enough for the
   CLI layer: the temp store dir is created by `record` and the trace file lands
   inside it. The existing runtime tests continue to cover trace rendering and
   replay equivalence.


## Idempotence and Recovery

All test cases create their own fresh temp store directories (derive a unique path
under `getTemporaryDirectory`, e.g. with the test name, and remove it with
`removePathForcibly` in a bracket), so re-runs are clean. `captureRun` restores
stdout/stderr in a `finally`; a crashed assertion cannot leave the suite's handles
redirected. The M1 validator is a pure function guarding existing handlers —
reverting the commit restores prior behavior exactly. Nothing here migrates or
mutates persistent state outside temp directories.


## Interfaces and Dependencies

- `shikumi-cli/src/Shikumi/Cli/Run.hs`: exported `validTraceId :: Text -> Either
  Text Text`, exported `replayFailureMessage :: Show a => Either a o -> Either a
  o -> Maybe Text`, and private `withValidTraceId :: Text -> (Text -> IO ()) ->
  IO ()`; handlers `runTraceCmd`, `runReplayCmd`, `runRecordCmd` keep their exact
  signatures.
- `shikumi-cli/test/Main.hs`: helper `parses :: [String] -> Maybe (GlobalOpts,
  Command)`; new imports `Shikumi.Cli (dispatch)`, `Shikumi.Cli.Options (..)`,
  `Shikumi.Cli.Example (exampleRegistry)`, `Shikumi.Cli.Run
  (validTraceId, replayFailureMessage)`, and `Options.Applicative
  (execParserPure, defaultPrefs)`.
- `shikumi-cli/shikumi-cli.cabal`: test stanza gains `optparse-applicative`. No
  other dependency changes. The two helper exports are additive API changes, so no
  version bump is required in this development tree.

Cross-plan coordination: none — per the master plan, EP-47 shares no files with
EP-44/45/46 and may land at any time.

Revision note 2026-07-04: Implemented EP-47, revised the test strategy away from
handle-capture tests after validating the actual runner behavior, and updated
living sections with validation evidence.
