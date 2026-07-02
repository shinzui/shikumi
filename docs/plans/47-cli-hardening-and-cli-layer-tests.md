---
id: 47
slug: cli-hardening-and-cli-layer-tests
title: "CLI Hardening and CLI-Layer Tests"
kind: exec-plan
created_at: 2026-07-02T03:30:16Z
intention: "intention_01kwgdyxm7ehh8yys1pp4wf1zr"
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

- [ ] M1: `validTraceId` guard in Run.hs; wired into trace, replay, and record
      handlers; replay failure messages split.
- [ ] M2: capture helper + `parseCommand` cases + `dispatch` golden cases in the
      shikumi-cli test suite; `optparse-applicative` added to test build-depends.
- [ ] Final: `just test-one shikumi-cli` green; commits carry the required trailers.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


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


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


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

Test helpers (top of `test/Main.hs`, alongside the existing `contains`):

```haskell
-- | Run an IO action with stdout+stderr redirected to temp files, catching an
-- ExitCode if thrown. Returns (stdout text, stderr text, Just code if exited).
captureRun :: IO () -> IO (Text, Text, Maybe ExitCode)
```

Implementation sketch (embed this in the file; it is the whole trick): flush both
handles; `hDuplicate` stdout/stderr to keep restore handles; open two temp files
(`openTempFile` under `getTemporaryDirectory`); `hDuplicateTo` the file handles
onto stdout/stderr; run `try @ExitCode action`; flush; restore the saved handles
with `hDuplicateTo`; close and read the temp files with `TIO.readFile`; remove
them. Wrap the middle in `finally` so handles are always restored (imports:
`GHC.IO.Handle (hDuplicate, hDuplicateTo)`, `Control.Exception (try, finally)`,
`System.Exit (ExitCode (..))`, `System.IO`). A small
`parses :: [String] -> Maybe (GlobalOpts, Command)` helper wraps
`execParserPure defaultPrefs parseCommand args` and maps `Success` to `Just`.

The cases, all in one new `testGroup "cli-layer"` appended to the existing tree
(every dispatch case uses `exampleRegistry` from `Shikumi.Cli.Example` and a fresh
temp store dir so cases are independent and re-runnable):

1. *Parsing*: `["trace", "sentiment"]` parses to
   `(GlobalOpts ".shikumi" False, CmdTrace (TraceOpts "sentiment"))` — pins the
   store-dir default and the positional id.
   `["--store-dir", "/tmp/x", "--otel", "trace", "t"]` pins flag handling.
   `["eval", "--program", "sentiment"]` parses to `CmdEval`; `["bogus-command"]`
   and `["eval"]` (missing required flag) both produce a parse `Failure`
   (`parses … @?= Nothing`).
2. *Unknown program*: `captureRun (dispatch exampleRegistry gopts (CmdEval
   (EvalOpts "nope")))` exits `Just (ExitFailure 1)` and stderr contains both
   `"Unknown program: nope"` and `"Registered programs: sentiment"` — pins
   `withTask`'s message.
3. *Trace-id rejection* (fails before M1): dispatching
   `CmdTrace (TraceOpts "../../escape")` exits `ExitFailure 1` with stderr
   containing `"Invalid trace id"`, and asserts that no file named `escape.json`
   was created anywhere under the temp parent (check the two candidate paths).
   Same for `CmdReplay (ReplayOpts "../oops")` and
   `CmdRecord (RecordOpts "../oops")` — the record case additionally asserts the
   store dir was **not** created (`doesDirectoryExist` is False), proving
   validation precedes IO.
4. *Missing trace*: `CmdTrace (TraceOpts "sentiment")` against an empty temp
   store dir exits nonzero with stderr containing `"No trace found with id:
   sentiment"` — pins the miss message and that a *valid* id is accepted.
5. *Record → trace → replay happy path* (golden): with
   `gopts = GlobalOpts tmpStore False`, dispatch `CmdRecord (RecordOpts
   "sentiment")` — exits cleanly (`Nothing`), stdout contains `"Recorded trace
   to"`, and `tmpStore </> "sentiment.json"` exists (store-dir creation
   verified). Then `CmdTrace (TraceOpts "sentiment")` — stdout contains
   `"Trace sentiment"` and `"llm-call"`. Then `CmdReplay (ReplayOpts
   "sentiment")` — stdout contains `"replay: output identical to recorded run,
   provider calls: 0"`. This is the CLI-through-dispatch mirror of the existing
   capability tests, and it pins the user-visible transcript fragments.
6. *Replay failure distinguishes sides* (fails before M1): dispatch
   `CmdReplay (ReplayOpts "sentiment")` with a store file recorded for a
   *different* input — simplest construction: record normally, then overwrite the
   trace file with a valid-JSON-but-wrong-content trace by recording under a
   modified responder… if that plumbing fights back, the pragmatic variant is to
   corrupt the recorded file's response payloads (`writeTraceFile` a tree
   recorded from a responder that errors) so the replayed run fails; assert
   stderr contains `"the replayed run errored"` rather than the old
   `"program error during replay or reference run"`. If constructing a
   replay-side failure proves disproportionate, keep the message-split assertion
   at unit granularity instead: extract the two arms into a helper returning the
   message and pin both strings — record the substitution in this plan's
   Decision Log.


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
      parseCommand: trace positional id and store-dir default: OK
      parseCommand: rejects unknown command and missing --program: OK
      dispatch: unknown program lists registered names, exit 1:  OK
      dispatch: path-escaping trace ids are rejected before IO:  OK
      dispatch: missing trace reports a helpful miss, exit 1:    OK
      dispatch: record/trace/replay golden transcript:           OK
      dispatch: replay failure names the failing side:           OK

All N tests passed
```

Commits (Conventional Commits; both must carry the three trailers):

```text
fix(cli): reject path-escaping trace ids; split replay failure messages

MasterPlan: docs/masterplans/8-tools-agents-and-cli-hardening.md
ExecPlan: docs/plans/47-cli-hardening-and-cli-layer-tests.md
Intention: intention_01kwgdyxm7ehh8yys1pp4wf1zr
```

```text
test(cli): golden CLI-layer tests through parseCommand and dispatch

MasterPlan: docs/masterplans/8-tools-agents-and-cli-hardening.md
ExecPlan: docs/plans/47-cli-hardening-and-cli-layer-tests.md
Intention: intention_01kwgdyxm7ehh8yys1pp4wf1zr
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
3. `just test-one shikumi-cli` passes with the new "cli-layer" group; the
   trace-id-rejection and replay-message cases fail when the M1 change to
   `Run.hs` is stashed (`git stash push shikumi-cli/src/Shikumi/Cli/Run.hs`,
   re-run, observe failures, `git stash pop`) — the failing-before evidence.
4. The happy-path golden case proves store-dir handling end-to-end: the temp
   store dir is created by `record`, the trace file lands inside it, and
   `trace`/`replay` read it back — all through `dispatch`, not through the
   runtime helpers.


## Idempotence and Recovery

All test cases create their own fresh temp store directories (derive a unique path
under `getTemporaryDirectory`, e.g. with the test name, and remove it with
`removePathForcibly` in a bracket), so re-runs are clean. `captureRun` restores
stdout/stderr in a `finally`; a crashed assertion cannot leave the suite's handles
redirected. The M1 validator is a pure function guarding existing handlers —
reverting the commit restores prior behavior exactly. Nothing here migrates or
mutates persistent state outside temp directories.


## Interfaces and Dependencies

- `shikumi-cli/src/Shikumi/Cli/Run.hs`: private `validTraceId :: Text -> Either
  Text Text` and `withValidTraceId :: Text -> (Text -> IO ()) -> IO ()`; handlers
  `runTraceCmd`, `runReplayCmd`, `runRecordCmd` keep their exact signatures.
- `shikumi-cli/test/Main.hs`: helpers `captureRun :: IO () -> IO (Text, Text,
  Maybe ExitCode)` and `parses :: [String] -> Maybe (GlobalOpts, Command)`; new
  imports `Shikumi.Cli (dispatch)`, `Shikumi.Cli.Options (..)` (the opts
  constructors are already exported), `Shikumi.Cli.Example (exampleRegistry)`,
  `Options.Applicative (execParserPure, defaultPrefs, getParseResult)`,
  `GHC.IO.Handle`, `System.Exit`.
- `shikumi-cli/shikumi-cli.cabal`: test stanza gains `optparse-applicative`. No
  other dependency changes; no version bumps required (no exported API changes).

Cross-plan coordination: none — per the master plan, EP-47 shares no files with
EP-44/45/46 and may land at any time.
