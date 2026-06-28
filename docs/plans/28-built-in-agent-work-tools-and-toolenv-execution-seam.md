---
id: 28
slug: built-in-agent-work-tools-and-toolenv-execution-seam
title: "Built-in agent work tools and ToolEnv execution seam"
kind: exec-plan
created_at: 2026-06-27T16:24:02Z
intention: "intention_01kw4y7rs9ep589hq39ee5zacj"
---

# Built-in agent work tools and ToolEnv execution seam

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Today a shikumi agent can think and talk, but it cannot *act on the world*. The typed-tool
machinery exists (`Shikumi.Tool` and the ReAct loop in `Shikumi.Agent.ReAct`), and there is one
toy executor — `restrictedInterpreter` in `Shikumi.CodeExec.Interpreter`, a hermetic arithmetic
and string calculator with no filesystem, no shell, and no network. There is no built-in tool
that reads a repository file, writes or edits one, runs a shell command, searches text, or
fetches a web page. An agent built on this stack can therefore only produce text, digests,
signals, and judgments. It cannot do the work.

This plan delivers the **work-tool surface**: a small catalog of built-in tools —
`read`, `write`, `edit`, `bash`, `grep`, `glob`, `web_fetch`, `web_search` — each defined with
shikumi's existing typed `Tool i o` mechanism and assembled into a `ToolRegistry` that any agent
runtime can install. After this change, a developer can build a ReAct agent over
`builtinRegistry`, hand it a task such as "read `README.md`, fix the title, and confirm the change
with `grep`", and watch the agent read the file, edit it, run a shell command to verify, and
search the result — all through the catalog, with every failure surfaced as a recoverable
observation rather than a crash.

The second deliverable is the **`ToolEnv` execution-environment seam**. The filesystem and shell
tools never touch the operating system directly; they call operations on a `ToolEnv` value —
`exec`, `readFile`, `writeFile`, `stat`, `readdir`, `exists`, `mkdir`, `rm`, `cwd`. This plan ships
one `ToolEnv` implementation: `localToolEnv`, backed by the local process and real filesystem.
**Sandboxing is explicitly out of scope.** The point of the seam is that a sandbox (a container, a
jailed scratch directory, a remote executor) can be introduced *later* as a different `ToolEnv`
value, swapped in at agent-construction time, **without editing a single tool definition**. The
web tools need no execution environment at all — they speak HTTP — so they run against a separate,
swappable `WebClient` value and can ship immediately.

You will know it works when the acceptance test (Milestone 5) runs a scripted agent that reads a
temporary file, edits it, runs `bash` to print the edited contents, greps for the edited line, and
fetches a URL through a stubbed `WebClient` — asserting on each observation — and when a manual,
network-enabled invocation of `web_fetch` against a real URL returns an HTTP 200 body.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1: add the `Shikumi.Tool.Env` module — value types (`Path`, `ExecRequest`, `ExecResult`, `FileStat`, `DirEntry`), the `EnvRow` constraint synonym, the `ToolEnv` record of functions, and `localToolEnv` (process/filesystem-backed). Completed 2026-06-28T16:33:11Z.
- [x] M1: add `directory`, `filepath`, `process` (GHC boot libraries) to `shikumi-tools.cabal` and expose `Shikumi.Tool.Env`. Completed 2026-06-28T16:33:11Z.
- [x] M1: unit-test `localToolEnv` against a temporary directory (write → read → stat → readdir → exists → mkdir → rm → exec) under the mock-LLM effect stack. Completed 2026-06-28T16:33:11Z; `nix develop --command cabal test shikumi-tools` passed with all 30 tests green.
- [ ] M2: add the `Shikumi.Tool.Web` module — the `WebClient` record (`webFetch`, `webSearch`), value types (`FetchResult`, `SearchResult`, `SearchHit`), and `localWebClient` over `http-client` + `http-client-tls`; add those two deps.
- [ ] M2: add `Shikumi.Tool.Builtin.Web` — `webFetchTool` and `webSearchTool` typed `Tool`s built over a `WebClient`.
- [ ] M2: unit-test the web tools against a *stub* `WebClient` (no network); add a manual, network-gated check for `web_fetch` against a live URL.
- [ ] M3: add `Shikumi.Tool.Builtin.Fs` — `readTool`, `writeTool`, `editTool`, `grepTool`, `globTool`, each `:: ToolEnv -> Tool i o`, with their input/output records. `grep`/`glob` are the hybrid: hardened in-process baseline (skip-list, binary detection, size/match/depth caps) using `regex-tdfa`, an `rg`/`fd` fast path via `envExec` when present, with `bash` as the escape hatch.
- [ ] M3: add `regex-tdfa` to `shikumi-tools.cabal`'s `library` `build-depends`; add `ripgrep` and `fd` to the nix dev shell (`nix/haskell.nix`).
- [ ] M3: unit-test the fs tools end-to-end against `localToolEnv` in a temp directory; run grep/glob **twice** (fast path via `localToolEnv`, in-process baseline via a stub `ToolEnv` reporting `rg`/`fd` absent), and add a hardening-bounds test (skips `.git`/`node_modules`/binary files).
- [ ] M4: add `Shikumi.Tool.Builtin.Shell` — `bashTool :: ToolEnv -> Tool BashReq BashResp` over `ToolEnv`'s `exec`.
- [ ] M4: unit-test `bashTool` (exit code, stdout, stderr, non-zero exit as a value).
- [ ] M5: add `Shikumi.Tool.Builtin` — `builtinFsTools`, `builtinWebTools`, `builtinTools`, and `builtinRegistry`, assembling the erased catalog.
- [ ] M5: write the end-to-end acceptance test: a scripted ReAct agent that reads → edits → bash-verifies → greps → web-fetches through `builtinRegistry`, asserting each observation.
- [ ] Wire the new test modules into `shikumi-tools.cabal`'s `other-modules` and confirm `cabal test shikumi-tools` is green.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: model `ToolEnv` as a **record of rank-2 functions captured by closure**, not as an
  `effectful` effect or a typeclass.
  Rationale: the body of a `Tool i o` is fixed to the effect row `(LLM :> es, Error ShikumiError
  :> es)` — see `Shikumi.Tool.Tool` and `Shikumi.Program.Embed`, whose constructor pins exactly
  that row so an embedded agent runs under `runProgram` without widening it. Introducing a
  `ToolEnv` *effect* would force `ToolEnv :> es` into the tool body's row, which would ripple into
  `SomeTool`, `runErased`, `runToolCall`, and the whole ReAct loop, and break the composability of
  `Embed`/`runProgram`. The codebase already has the exact precedent for the chosen approach:
  `Shikumi.CodeExec.Interpreter.CodeInterpreter` is a record of rank-2 functions captured in an
  `Embed` closure rather than added to the row. `ToolEnv` is the same shape.
  Date: 2026-06-27 (authoring)

- Decision: `localToolEnv`'s operations perform real `IO` and are lifted into the tool body row via
  `Effectful.Dispatch.Static.unsafeEff_`.
  Rationale: the tool body row lacks `IOE`, yet filesystem and shell tools must do `IO`. The
  sanctioned in-repo pattern for "real `IO` under a non-`IOE` row" is `Shikumi.Effect.Time`, whose
  `getCurrentTime`/`getMonotonicTimeNSec` call `unsafeEff_ Time.getCurrentTime` so callers need
  only `Time :> es`. `localToolEnv` uses the same bridge. A *sandboxed* `ToolEnv` can use the same
  bridge to a different backend (a subprocess into a container, an RPC to a remote executor), still
  without changing tool definitions. This is the seam.
  Date: 2026-06-27 (authoring)

- Decision: use `http-client` + `http-client-tls` for the web tools.
  Rationale: these are mature, widely-used HTTP/TLS libraries and the natural choice for the web
  tools; `localWebClient` takes a shared `Manager` so connection pooling and TLS configuration live
  in one place. **Correction (2026-06-28):** an earlier version of this rationale claimed these were
  "already in the dependency closure via baikai" and so added "no new third-party HTTP stack." That
  is wrong — verified against `/Users/shinzui/Keikaku/bokuno/baikai/baikai/baikai.cabal`: the baikai
  *library* stanza (lines 35–88, which is what `shikumi-tools` depends on) does **not** list
  `http-client`/`http-client-tls`; only baikai's executable and test-suite stanzas do. Adding these
  to `shikumi-tools` therefore introduces two genuinely **new** library dependencies. The choice
  stands (they are the right libraries), but the dependency-risk note was inaccurate and is hereby
  corrected: this is a real, if small, dependency-surface addition.
  Date: 2026-06-27 (authoring); corrected 2026-06-28

- Decision: implement `grep` and `glob` as a **hardened in-process baseline over `ToolEnv`, with an
  optional `rg`/`fd` fast path through `ToolEnv.exec`, and `bash` as the general escape hatch** —
  not as a single fixed strategy.
  Rationale (revised 2026-06-28 after validation and review): three facts shaped this. (1) `rg`/`fd`
  are **not** in the dev shell today (`nix/haskell.nix` has no ripgrep/fd), and grep-over-`ToolEnv`
  is the *purest* expression of the seam — it needs only the file primitives the seam already
  guarantees, so it is automatically sandbox-correct and works in a container that has no search
  binary baked in. That argues for an in-process implementation existing as the guaranteed baseline.
  (2) But the plan also ships `bash`, which shells out via `bash -c` through the same `ToolEnv.exec`;
  once the agent has `bash` it can already run `rg`/`grep`/`find` when the host provides them. So
  dedicated `grep`/`glob` are not a security boundary — they are a *structured, deterministic,
  always-available* convenience whose value is typed `GrepMatch`/`GlobResp` output the model can
  parse reliably. (3) The original spec ("walk recursively, match literal substring") was
  under-designed to the point of being incorrect on a real repository: with no bounds it reads
  `.git` pack files, `node_modules`, and binaries, matches inside them, and is pathologically slow —
  exactly the work `rg`'s gitignore-awareness and binary detection do for free. The resolution:
  the **in-process baseline is hardened** (skip-list for `.git`/`node_modules`/other VCS-build dirs,
  binary detection via a NUL-byte probe, a max-file-size cap, a max-match cap with a `truncated`
  flag, and a traversal-depth limit) and uses **real regex via `regex-tdfa`** (see next decision);
  the tool **prefers an `rg`/`fd` fast path** — detected at call time with `command -v rg` through
  `envExec`, and routed through the *same* seam so a sandbox still controls it — and **falls back to
  the in-process baseline** when the binary is absent. nix provides `rg`/`fd` in the dev shell and in
  sandbox images (see the nix decision below), so the fast path is normally taken in dev and in
  sandboxes, while the in-process baseline guarantees correctness everywhere else. `bash` remains the
  escape hatch for ad-hoc or large searches the structured tools do not cover.
  Date: 2026-06-27 (authoring); substantially revised 2026-06-28

- Decision: use `regex-tdfa` for in-process `grep` matching from the first cut (not literal
  substring).
  Rationale: a tool named `grep` that cannot do regular expressions surprises both the model and the
  user; agents expect regex semantics. `regex-tdfa` is a mature, pure-Haskell, dependency-light POSIX
  ERE engine (no C bindings, no backtracking pathologies), so it adds one well-behaved dependency and
  removes the "literal-substring-only" limitation entirely. Case-insensitivity is handled via the
  engine's compile options driven by the `ignoreCase` flag. The `rg` fast path uses `rg`'s own regex
  engine; the in-process path uses `regex-tdfa` — both are regex, so switching paths does not change
  the contract the model sees (modulo dialect edge cases, which are documented).
  Date: 2026-06-28

- Decision: add `ripgrep` and `fd` to the nix dev shell (`nix/haskell.nix`'s native build inputs),
  and require sandbox images to provide them too.
  Rationale: the user's intent is that nix supplies these binaries in both development and sandboxes,
  so the `rg`/`fd` fast path is the normal case rather than an occasional optimization. Putting them
  in the dev shell makes the fast path exercised by the test suite (the `FsSpec` grep/glob tests run
  against `localToolEnv`, which will find `rg`/`fd` on `PATH`), and documenting them as a sandbox
  requirement keeps behavior consistent between dev and deployed sandboxes. The in-process baseline
  remains the contract for any environment that lacks them. Note this couples *test* behavior to the
  presence of `rg`/`fd`; to keep the in-process path covered too, the grep/glob tests run **twice** —
  once with the fast path available and once forced down the in-process baseline (via a stub
  `ToolEnv` whose `envExec` reports `rg` as absent).
  Date: 2026-06-28

- Decision: use `process`, `directory`, `filepath` (all GHC boot libraries) for shell and
  filesystem operations.
  Rationale: boot libraries are guaranteed present in the pinned toolchain (confirmed via
  `ghc-pkg list`: `process-1.6.x`, `directory-1.3.x`, `filepath-1.5.x`), so they add zero
  dependency-resolution risk. `typed-process` was considered for richer streaming but rejected for
  the first cut to avoid a non-boot dependency; revisit if streaming output becomes necessary.
  Date: 2026-06-27 (authoring)

- Decision: map `ToolEnv` I/O faults to `ShikumiError`'s existing `ProviderFailure` constructor
  (with a clear "tool env: " message prefix) rather than adding a new constructor.
  Rationale: a tool-body `ShikumiError` is *caught* inside `Shikumi.Tool.runErased` and converted
  to a `ToolRunFailed` value fed back to the model; it never reaches `Shikumi.Error.isTransient`
  or any retry path, so the choice of constructor has no behavioral effect — it only affects the
  message text. Reusing `ProviderFailure` keeps this plan additive and avoids touching the shared
  `ShikumiError` sum type (which every exhaustive match across the framework would have to
  update). A dedicated `ToolEnvFailure :: Text` constructor is recorded as a clean future
  refinement.
  Date: 2026-06-27 (authoring)

- Decision: tests exercise tools against *stub* `ToolEnv`/`WebClient` values where determinism or
  network isolation matters, and against `localToolEnv`/a temp directory where real I/O is the
  point. The web tools' network path is validated by a separate, manual, network-gated step.
  Rationale: the record-of-functions seam makes both `ToolEnv` and `WebClient` swappable in tests
  exactly as `CodeInterpreter` and the mock `LLM` already are, so the full agent loop can be
  exercised hermetically.
  Date: 2026-06-27 (authoring)

- Decision: all **plain data records** in the new modules follow
  `haskell-jitsurei/core/record-patterns.md` — **no field prefixes** (lean on
  `DuplicateRecordFields`), strict `!` fields, explicit `deriving stock`/`deriving anyclass`
  strategies, and field access via generic-lens `#label` (`req ^. #path`), never record-selector
  syntax (`path req`) and never record-update syntax. Each new module that reads fields imports
  `Data.Generics.Labels ()` to bring the `#label` instance into scope locally (not via the prelude,
  per the guide). The new modules set `default-language: GHC2024` with `DuplicateRecordFields`,
  `OverloadedLabels`, `DeriveAnyClass`, and `OverloadedStrings` (matching the guide's cabal stanza),
  plus the `RankNTypes`/`ConstraintKinds` the seam needs.
  Rationale: the user flagged prefixed fields in an earlier draft. The guide is explicit and
  project-wide; the draft violated it (`execCwd`, `entryName`, `entryIsDir`, `searchBaseUrl`,
  `searchApiKey`). Those are now `cwd`, `name`, `isDir`, `baseUrl`, `apiKey` — collisions across
  records (`ExecRequest.cwd`/`BashReq.cwd`, `FileStat.isDir`/`DirEntry.isDir`, the several `path`
  fields) are exactly what `DuplicateRecordFields` exists to permit, so no prefix is needed to
  disambiguate.
  Date: 2026-06-28

- Decision: the rank-2 **operation records** — `ToolEnv` (`envExec`, `envReadFile`, …), `WebClient`
  (`webFetch`, `webSearch`) — keep their method-style field names and are an explicit, documented
  carve-out from the no-prefix rule.
  Rationale: record-patterns.md's no-prefix rule exists to make generic-lens `#label` *access*
  uniform across data records. These fields are **higher-rank functions** (`forall es. EnvRow es =>
  …`), which cannot form a `#label` lens at all — generic-lens needs a monomorphic field — so they
  are never accessed via `#label`; they are *applied* (`envExec env req`). The no-prefix rule
  therefore does not functionally apply to them. Two concrete reasons to keep the names: (1) the
  exact in-repo precedent is `Shikumi.CodeExec.Interpreter.CodeInterpreter { runCode :: forall es.
  … }`, a rank-2 operation record in the same tool-body row that uses a descriptive, non-bare field
  name; mirroring it keeps the seam consistent with the one that already exists. (2) Stripping the
  prefixes would name selectors `exec`, `readFile`, `writeFile`, `stat`, `exists`, `rm`, `cwd`,
  which collide with `Prelude`/`bytestring`/`directory` imports at the use site; the `env`/`web`
  namespacing avoids that. These records still use strict semantics where applicable and explicit
  deriving; they simply are not `#label` data records. If the user prefers bare names regardless,
  this is the one decision to revisit.
  Date: 2026-06-28

- Decision: `localToolEnv` applies a 60-second default timeout when `ExecRequest.timeoutMs` is
  `Nothing`, and an elapsed timeout is thrown as the existing `Timeout` `ShikumiError` with a
  `tool env: exec timed out` message.
  Rationale: `ExecRequest` already carries an optional timeout, and an unbounded `bash -c` would be
  too easy for a tool call or test to hang indefinitely. The existing `Timeout` constructor is the
  right framework-level vocabulary for this failure. Explicit non-zero exit codes remain normal
  `ExecResult` values, so only launch faults and elapsed wall-clock limits become typed errors.
  Date: 2026-06-28 (implementation)


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

- 2026-06-28: Milestone 1 is complete. `Shikumi.Tool.Env` now provides the `ToolEnv` seam and
  `localToolEnv`, and `EnvSpec` proves the local implementation can write, read, stat, list, create,
  remove, report cwd, and execute a shell command through the mock-LLM effect stack. Milestones 2–5
  remain to implement the web tools, filesystem tools, shell tool, and builtin registry/catalog.


## Context and Orientation

This work lives entirely in the `shikumi-tools` package of the shikumi repository
(`/Users/shinzui/Keikaku/bokuno/shikumi`). You build and test inside the dev shell
(`nix develop`); the system `ghc` on `PATH` is the wrong compiler (9.10.x), and the project pins
GHC 9.12.4 via `flake.nix`. The build descriptor is `cabal.project` at the repo root; `shikumi-tools`
is one of its listed packages. Common developer commands are in `Justfile` (`just build`,
`just test`, `just test-one shikumi-tools`).

Several terms recur; here is what each means in this repository.

A **typed tool** is a value of type `Shikumi.Tool.Tool i o` (file
`shikumi-tools/src/Shikumi/Tool.hs`): a record with a `name`, a `description`, and a `run` field.
The `run` field is a *rank-2* function — `run :: forall es. (LLM :> es, Error ShikumiError :> es)
=> i -> Eff es o`. "Rank-2" means the function works in *any* effect stack `es` that provides the
two capabilities named: `LLM` (the model effect, so a tool may itself call a sub-model) and `Error
ShikumiError` (the typed error channel, so a tool may signal failure as a value). This exact pair
is "the tool body row" throughout this plan. `effectful` is the effect-system library shikumi
uses; `Eff es a` is "a computation producing `a` using the effects listed in the row `es`", and
`Eff :> es` reads "this effect is available in this row".

A **`SomeTool`** (same file) is a `Tool i o` with its `i`/`o` hidden behind an existential, while
retaining the dictionaries needed to derive the input JSON Schema, decode arguments from JSON, and
encode the result to text. A **`ToolRegistry`** is a name-keyed map of `SomeTool`s. The function
`Shikumi.Tool.runToolCall` looks a tool up by the name the model emitted, decodes the arguments,
runs the body, and returns `Either ToolError Text` — never throwing: a missing tool is
`ToolNotFound`, bad arguments are `ToolArgsInvalid`, and a body that throws a `ShikumiError`
becomes `ToolRunFailed`. **This error-as-value contract is load-bearing for this plan**: every
work tool relies on it so that a missing file, a non-zero shell exit, or a 404 becomes an
observation the model can read and recover from, not a crash.

The **ReAct loop** (`shikumi-tools/src/Shikumi/Agent/ReAct.hs`) is the driver: at each step the
model proposes a tool call or declares it is finished; the loop dispatches via `runToolCall`,
records the observation, and asks again until the model finishes or `maxIters` is hit, then
extracts the typed answer. `react`/`reactWithTrajectory` build this as a `Program i o`. The work
tools in this plan are exactly the catalog this loop is meant to dispatch.

The **only executor that exists today** is in `shikumi-tools/src/Shikumi/CodeExec/Interpreter.hs`:
`restrictedInterpreter`, a hermetic evaluator for a tiny arithmetic/string DSL, wrapped in the
`CodeInterpreter` record (`newtype CodeInterpreter = CodeInterpreter { runCode :: forall es. (LLM
:> es, Error ShikumiError :> es) => Text -> Eff es (Either Text Text) }`). Note its shape: a record
of rank-2 functions in the tool body row, captured by closure — **this is the precedent for
`ToolEnv`**. Its module header documents the security posture and explicitly states that a real
subprocess executor "needs `IOE`, which the `Embed` row lacks", so it "could only be offered
through a separate `IOE`-bearing entry point." This plan resolves that tension the same way
`Shikumi.Effect.Time` does (below), not by widening the row.

The **`ToolEnv` seam** is the new abstraction this plan introduces, and the reason it matters:
without it, every filesystem and shell tool would hard-code calls to the local OS, and adding a
sandbox later would mean rewriting every tool. With it, a tool body says `envReadFile env path`,
and *which* environment that is — the local process, a container, a remote executor — is a value
chosen at agent-construction time. The seam is "where a sandbox plugs in later without changing
tool definitions." That is the single most important architectural property of this plan; the
gap analysis (`shinzui/kikan`, `docs/architecture/evolution/agent-infrastructure-gaps.md`, gap #1)
calls it out explicitly.

The bridge from the tool body row (no `IOE`) to real `IO` already has a sanctioned pattern in this
repo: `shikumi/src/Shikumi/Effect/Time.hs`. Its operations call `unsafeEff_ :: IO a -> Eff es a`
(from `Effectful.Dispatch.Static`) so callers need only the narrow effect, with the real `IO`
permission demanded only at the discharge site. `localToolEnv` uses the same `unsafeEff_` bridge.
This is safe here for the same reason it is safe in `Time`: the operations are ordinary effectful
work, and any genuine fault is surfaced as a `ShikumiError`.

Two adjacent shikumi plans are **separate from this one** but build on the same surface and are
mentioned so the reader can place them: an MCP-client plan (surfacing an external MCP server's
tools as `Tool`s registered into a `ToolRegistry` — gap #6) and an in-run context-compaction plan
(summarizing the live message list mid-loop before it overflows — gap #5). Neither is in scope
here. One **downstream** consumer is worth noting and is also out of scope: `shinzui/shikigami`'s
skill behavior currently runs its *own* tool loop separate from shikumi's ReAct loop; this catalog
is the shared surface both should eventually use, unifying them on one tool loop. Do not attempt
that unification in this plan; just build the catalog it will consume.


## Plan of Work

The work proceeds in five milestones, each independently verifiable. The dependency order is: the
`ToolEnv` seam first (everything filesystem/shell depends on it), then the web tools (which need
nothing from `ToolEnv` and can ship in isolation), then the filesystem tools, then the shell tool,
then the registry/catalog assembly with the end-to-end acceptance test.

All new modules live under `shikumi-tools/src/Shikumi/Tool/`. Be aware of a small naming subtlety:
the existing module `Shikumi.Tool` is a *file* (`src/Shikumi/Tool.hs`). Adding child modules
`Shikumi.Tool.Env`, `Shikumi.Tool.Web`, and `Shikumi.Tool.Builtin.*` alongside it is valid Haskell
(a module and a directory of the same name coexist); create the directory `src/Shikumi/Tool/` and
place the new files there.


### Milestone 1 — the `ToolEnv` interface and a local implementation

Scope: introduce the execution-environment seam and one real implementation, with no tools yet.
At the end, `Shikumi.Tool.Env` exports the `ToolEnv` record and `localToolEnv`, and a unit test
proves that `localToolEnv` can create, write, read, stat, list, and delete files in a temporary
directory and run a shell command — all driven through the tool body effect row.

Create `shikumi-tools/src/Shikumi/Tool/Env.hs`. Define the value types first: a `Path` synonym
(`type Path = Text`), an `ExecRequest` record (`command :: Text`, `cwd :: Maybe Path`, `stdin
:: Maybe Text`, `timeoutMs :: Maybe Int`), an `ExecResult` record (`exitCode :: Int`, `stdout ::
Text`, `stderr :: Text`), a `FileStat` record (`isFile :: Bool`, `isDir :: Bool`, `size ::
Integer`), and a `DirEntry` record (`name :: Text`, `isDir :: Bool`). These are plain data records
and follow `haskell-jitsurei/core/record-patterns.md`: **no field prefixes** (rely on
`DuplicateRecordFields`, so `ExecRequest.cwd`/`BashReq.cwd`, `FileStat.isDir`/`DirEntry.isDir`, and
the several `path` fields can share names freely), strict `!` fields, explicit deriving strategies,
and field access via generic-lens `#label` (never record-selector syntax). Define the
constraint synonym `type EnvRow es = (LLM :> es, Error ShikumiError :> es)` (needs
`{-# LANGUAGE ConstraintKinds #-}`) so the `ToolEnv` field signatures read cleanly and stay
identical to the tool body row.

Then define the record of operations:

```haskell
data ToolEnv = ToolEnv
  { envExec      :: forall es. (EnvRow es) => ExecRequest -> Eff es ExecResult
  , envReadFile  :: forall es. (EnvRow es) => Path -> Eff es ByteString
  , envWriteFile :: forall es. (EnvRow es) => Path -> ByteString -> Eff es ()
  , envStat      :: forall es. (EnvRow es) => Path -> Eff es (Maybe FileStat)
  , envReaddir   :: forall es. (EnvRow es) => Path -> Eff es [DirEntry]
  , envExists    :: forall es. (EnvRow es) => Path -> Eff es Bool
  , envMkdir     :: forall es. (EnvRow es) => Path -> Eff es ()  -- create, parents included
  , envRm        :: forall es. (EnvRow es) => Path -> Eff es ()  -- remove file or empty dir
  , envCwd       :: forall es. (EnvRow es) => Eff es Path
  }
```

This needs `{-# LANGUAGE RankNTypes #-}` (a per-field universally quantified function) — note the
record fields are higher-rank, so the data declaration uses the same pattern as `CodeInterpreter`
in `Shikumi.CodeExec.Interpreter` (consult it for the exact pragma set; it uses `RankNTypes`).

Implement `localToolEnv :: ToolEnv`. Each operation does the real thing via `unsafeEff_`:
`envReadFile` is `unsafeEff_ . BS.readFile . T.unpack` wrapped to catch `IOException` and re-throw
as `throwError (ProviderFailure ("tool env: " <> ...))`; `envWriteFile` uses `BS.writeFile`;
`envStat` uses `System.Directory.doesFileExist`/`doesDirectoryExist`/`getFileSize`, returning
`Nothing` when neither exists; `envReaddir` uses `listDirectory` plus a `doesDirectoryExist` check
per entry; `envExists` is `doesPathExist`; `envMkdir` is `createDirectoryIfMissing True`; `envRm`
removes a file (`removeFile`) or an empty directory (`removeDirectory`); `envCwd` is
`getCurrentDirectory`. `envExec` builds a `System.Process` `CreateProcess` for `bash -c command`,
sets the process `cwd` from the request's `cwd`, feeds `stdin`, and returns `ExecResult` from
`readCreateProcessWithExitCode` (mapping `ExitSuccess` to `0` and `ExitFailure n` to `n`). The
key discipline: catch `IOException` from each call and convert it to `throwError (ProviderFailure
...)`; do *not* let an exception escape `unsafeEff_`. For `envStat`/`envExists` a non-existent
path is a normal result (`Nothing`/`False`), not an error.

Add `directory`, `filepath`, and `process` to `shikumi-tools.cabal`'s `library` `build-depends`,
and add `Shikumi.Tool.Env` to `exposed-modules`.

Acceptance: a new test module (e.g. `EnvSpec`) creates a temp directory with
`System.IO.Temp.withSystemTempDirectory` (this needs the `temp` capability — use `unix`/`directory`
primitives or add `temporary` if not present; prefer `getTemporaryDirectory` + a unique subdir to
avoid a new dep), then under `runEffMock []` exercises write → read (asserting round-trip bytes) →
stat (asserting `isFile`/`size`) → readdir (asserting the entry appears) → exists → mkdir → rm →
exec (`echo hello`, asserting `exitCode == 0` and `stdout` contains `hello`). Run with
`cabal test shikumi-tools`.


### Milestone 2 — web tools (no sandbox, ship now)

Scope: deliver `web_fetch` and `web_search` over HTTP, against a swappable `WebClient` value, with
no dependency on `ToolEnv`. At the end, both tools exist as typed `Tool`s, a stub-`WebClient` test
proves the loop hermetically, and a manual network check proves `web_fetch` against a live URL.

Create `shikumi-tools/src/Shikumi/Tool/Web.hs`. Define value types: `FetchResult` (`status ::
Int`, `contentType :: Text`, `body :: Text`, `truncated :: Bool`), `SearchHit` (`title :: Text`,
`url :: Text`, `snippet :: Text`), and `SearchResult` (`hits :: [SearchHit]`). Define the record:

```haskell
data WebClient = WebClient
  { webFetch  :: forall es. (EnvRow es) => Text -> Maybe Int -> Eff es FetchResult     -- url, maxBytes
  , webSearch :: forall es. (EnvRow es) => Text -> Maybe Int -> Eff es SearchResult    -- query, maxResults
  }
```

Reuse `EnvRow` from `Shikumi.Tool.Env` (import it) so web operations sit in the same row.
Implement `localWebClient :: Manager -> Maybe SearchConfig -> WebClient` where `Manager` is
`Network.HTTP.Client.Manager`. `webFetch` parses the URL with `parseRequest`, performs `httpLbs`
with the shared manager (via `unsafeEff_`), reads the status code and `Content-Type` header, decodes
the body as UTF-8, truncates to `maxBytes` (default a sane cap, e.g. 100_000 bytes) and sets
`truncated` accordingly. A transport exception (bad host, timeout) is caught and re-thrown as
`throwError (ProviderFailure ("web_fetch: " <> ...))`; an HTTP error *status* (e.g. 404) is **not**
an error — it is returned in `status` so the model can react. `webSearch` is implemented against a
configurable search endpoint (`SearchConfig` carries a base URL and an API key/header); since a
search provider requires credentials, ship `localWebClient` with `webSearch` either calling the
configured endpoint or, when `SearchConfig` is `Nothing`, throwing a clear `ProviderFailure
"web_search: no search provider configured"`. Document this clearly: `web_fetch` is fully
functional out of the box; `web_search` requires a configured provider.

Add `http-client` and `http-client-tls` to `build-depends`; export a helper that builds a TLS
manager (`newTlsManager` re-exported from `Network.HTTP.Client.TLS`) so callers have a one-liner.

Create `shikumi-tools/src/Shikumi/Tool/Builtin/Web.hs`. Define the input/output records and the
tools. For `web_fetch`: `data FetchReq = FetchReq { url :: Text, maxBytes :: Maybe Int }` deriving
`(Generic, ToSchema, FromModel, ToPrompt)`, and reuse `FetchResult` as the output (it must derive
`ToJSON`; add the instance in `Shikumi.Tool.Web`). Then `webFetchTool :: WebClient -> Tool FetchReq
FetchResult`, built with `mkTool "web_fetch" "Fetch the contents of a URL over HTTP." $ \req ->
webFetch wc (req ^. #url) (req ^. #maxBytes)` (field access via generic-lens `#label`, per
record-patterns.md — note `webFetch` is applied to the `WebClient`, not accessed as a lens; see the
operation-record note below). For `web_search`: `data SearchReq = SearchReq { query ::
Text, maxResults :: Maybe Int }`, output `SearchResult`, `webSearchTool :: WebClient -> Tool
SearchReq SearchResult`.

Acceptance: a `WebSpec` test builds a *stub* `WebClient` whose `webFetch` ignores its arguments and
returns a fixed `FetchResult { status = 200, contentType = "text/plain", body = "stub body",
truncated = False }`, runs `runToolCall` (or the tool's body directly) under `runEffMock []`, and
asserts the encoded observation contains `"stub body"` and `200`. A second case stubs a 404 and
asserts the status is surfaced (not thrown). Add a manual, *network-gated* test (guarded by an env
var such as `SHIKUMI_NET_TESTS=1`, skipped otherwise) that builds `localWebClient` over a real TLS
manager and fetches `https://example.com`, asserting `status == 200` and a non-empty body. State in
the test comment exactly how to run it.


### Milestone 3 — filesystem tools against `ToolEnv`

Scope: deliver `read`, `write`, `edit`, `grep`, and `glob` as typed `Tool`s that run entirely
against a `ToolEnv`. At the end, each tool exists and a test exercises all five against
`localToolEnv` in a temp directory.

Create `shikumi-tools/src/Shikumi/Tool/Builtin/Fs.hs`. Define input records (each deriving
`Generic, ToSchema, FromModel, ToPrompt`) and output records (each deriving `Generic, ToJSON`;
optionally `ToSchema, FromModel` for symmetry):

- `read`: `ReadReq { path :: Text, offset :: Maybe Int, limit :: Maybe Int }` → `ReadResp {
  content :: Text, lineCount :: Int, truncated :: Bool }`. The body reads via `envReadFile`,
  decodes UTF-8, applies optional `offset`/`limit` in lines, and reports truncation.
- `write`: `WriteReq { path :: Text, content :: Text }` → `WriteResp { path :: Text, bytesWritten
  :: Int }`. The body encodes UTF-8 and calls `envWriteFile`.
- `edit`: `EditReq { path :: Text, oldString :: Text, newString :: Text, replaceAll :: Maybe Bool
  }` → `EditResp { path :: Text, replacements :: Int }`. The body reads the file, replaces the
  first occurrence of `oldString` with `newString` (or all occurrences when `replaceAll` is
  `True`), writes it back, and reports the count. If `oldString` is not found, throw
  `ValidationFailure "edit: oldString not found"` so it returns as a `ToolRunFailed` observation
  the model can recover from.
- `grep`: `GrepReq { pattern :: Text, path :: Maybe Text, glob :: Maybe Text, ignoreCase :: Maybe
  Bool }` → `GrepResp { matches :: [GrepMatch], truncated :: Bool }` with `GrepMatch { file ::
  Text, line :: Int, text :: Text }`. `pattern` is a **regular expression** (POSIX ERE via
  `regex-tdfa`), not a literal substring. The body chooses a strategy at call time (see "grep/glob
  strategy" below): when an `rg` binary is available it runs `rg` through `envExec` and parses the
  results; otherwise it walks the directory rooted at `path` (default `envCwd`) via `envReaddir`
  recursively under the **hardening bounds** below, filters files by the optional `glob`, reads
  each via `envReadFile`, and collects lines matching the compiled regex (honoring `ignoreCase`).
  `truncated` is `True` when the match cap was hit.
- `glob`: `GlobReq { pattern :: Text, path :: Maybe Text }` → `GlobResp { paths :: [Text],
  truncated :: Bool }`. When an `fd` binary is available it runs `fd --glob` through `envExec`;
  otherwise the body walks from `path` (default `envCwd`) via `envReaddir` under the same hardening
  bounds and returns paths matching the glob.

**grep/glob strategy (the hybrid).** Per the Decision Log, these tools have three layers. (1) The
**hardened in-process baseline** is the guaranteed contract and always exists: it must skip a
default set of noise directories (`.git`, `node_modules`, and other common VCS/build dirs), detect
and skip binary files (probe the first ~8 KB for a NUL byte), skip files over a max-size cap (e.g.
5 MB), stop after a max-match / max-path cap and set `truncated`, and honor a traversal-depth limit
— without these bounds, an in-process grep over a real repository reads pack files and binaries,
matches inside them, and is pathologically slow. (2) The **`rg`/`fd` fast path** is preferred when
the binary is present: detect it once per call with `command -v rg` (resp. `fd`) through
`envExec` — routing through the **same `ToolEnv.exec` seam** so a sandbox still governs it — and on
exit code 0 run `rg --json` (parse the `match` records into `GrepMatch`) / `fd --glob`, otherwise
fall back to the baseline. nix supplies `rg`/`fd` in the dev shell and in sandbox images (a
`nix/haskell.nix` change is part of this plan — see Concrete Steps), so the fast path is normally
taken there. (3) **`bash`** (Milestone 4) remains the escape hatch for ad-hoc or large searches the
structured tools do not cover. Document this layering in the module header and in each tool's
`description` so the model knows `grep`/`glob` give structured, deterministic results and that
`bash`+`rg` is available for anything beyond them.

Implement a small, pure glob matcher in this module (translate `*` → "any run of non-separator
chars", `?` → "one char", `**` → "any run including separators"); keep it minimal and unit-test it
— it is used by the in-process baseline of both `glob` and `grep`'s `glob` filter. Use `regex-tdfa`
to compile `grep`'s `pattern` once per call (case-insensitive when `ignoreCase` is `True`); a
malformed pattern surfaces as a `ValidationFailure` (returned as a `ToolRunFailed` observation).
Each tool is a function `:: ToolEnv -> Tool i o`, e.g. `readTool env = mkTool "read" "Read a file's
contents." $ \req -> do { bs <- envReadFile env (req ^. #path); ... }` (field access via generic-lens
`#label`, per record-patterns.md).

Note on optional fields (verified, not a risk): the schema generator (`Shikumi.Schema`) and decoder
(`FromModel`) **do** support `Maybe` fields as *optional* JSON properties —
`shikumi/src/Shikumi/Schema.hs:133` returns `required = False` for a `Maybe` field, and the
`FromField (Maybe a)` instance decodes a missing key or JSON `null` to `Nothing`. So
`offset`/`limit`/`glob`/`ignoreCase`/`replaceAll` can be modeled as `Maybe` directly; no
required-field fallback is needed.

Acceptance: an `FsSpec` test, in a temp directory, writes a file via `writeTool`, reads it back via
`readTool` (asserting content), edits it via `editTool` (asserting `replacements == 1` and that a
re-read shows the new text), greps for the new text via `grepTool` (asserting one match with the
right line), and globs for the file via `globTool` (asserting the path appears) — all under
`runEffMock []` against `localToolEnv`. Run the grep/glob assertions **twice** to cover both
strategy layers: once against `localToolEnv` (which finds `rg`/`fd` on `PATH` via nix, exercising
the fast path) and once against a stub `ToolEnv` whose `envExec` reports `command -v rg` as exit
code 1 (forcing the in-process baseline), asserting identical results from both. Add a focused unit
test for the hardening bounds: seed a `.git`/`node_modules` subtree and a binary file, and assert
the in-process grep skips them.


### Milestone 4 — the shell tool against `ToolEnv`

Scope: deliver `bash` as a typed `Tool` over `ToolEnv`'s `exec`. At the end, `bashTool` exists and
a test proves it captures stdout, stderr, and exit code, with a non-zero exit returned as a value.

Create `shikumi-tools/src/Shikumi/Tool/Builtin/Shell.hs`. Define `BashReq { command :: Text, cwd
:: Maybe Text, timeoutMs :: Maybe Int, stdin :: Maybe Text }` → `BashResp { exitCode :: Int,
stdout :: Text, stderr :: Text }`. `bashTool :: ToolEnv -> Tool BashReq BashResp`, built with
`mkTool "bash" "Run a shell command and capture stdout, stderr, and the exit code." $ \req ->
envExec env (ExecRequest { command = req ^. #command, cwd = req ^. #cwd, stdin = req ^. #stdin,
timeoutMs = req ^. #timeoutMs })` then repackage the `ExecResult` into a `BashResp` (record
*construction* is permitted by record-patterns.md; only record *update* syntax is banned — and the
right-hand sides read fields via generic-lens `#label`). A non-zero exit is a normal
result returned in `exitCode` (the model decides what to do), not a thrown error; only a failure to
*launch* the process is a thrown `ProviderFailure`.

Acceptance: a `ShellSpec` test runs `echo hi` (asserting `exitCode == 0`, `stdout` contains `hi`),
runs a command that writes to stderr and exits non-zero (e.g. `sh -c 'echo oops 1>&2; exit 3'` via
`command`, asserting `exitCode == 3` and `stderr` contains `oops`), all against `localToolEnv`
under `runEffMock []`.


### Milestone 5 — registry/catalog assembly and the end-to-end agent

Scope: bundle the tools into a registry an agent installs, and prove an actual ReAct agent uses the
catalog to read, edit, verify, search, and fetch. At the end, `Shikumi.Tool.Builtin` exports the
catalog assemblers, and the acceptance test drives a scripted agent through the full work cycle.

Create `shikumi-tools/src/Shikumi/Tool/Builtin.hs` re-exporting the tools and assembling catalogs:

```haskell
builtinFsTools  :: ToolEnv -> [SomeTool]
builtinWebTools :: WebClient -> [SomeTool]
builtinTools    :: ToolEnv -> WebClient -> [SomeTool]
builtinRegistry :: ToolEnv -> WebClient -> ToolRegistry
```

`builtinFsTools env = [SomeTool (readTool env), SomeTool (writeTool env), SomeTool (editTool env),
SomeTool (grepTool env), SomeTool (bashTool env), SomeTool (globTool env)]` (note: `bash` belongs
in the fs/shell group since it also runs against `ToolEnv`; place it here or in a dedicated
`builtinShellTools` — pick one and document it). `builtinWebTools wc = [SomeTool (webFetchTool wc),
SomeTool (webSearchTool wc)]`. `builtinTools env wc = builtinFsTools env <> builtinWebTools wc`.
`builtinRegistry env wc = mkRegistry (builtinTools env wc)`.

Acceptance (the headline demonstration): an `AcceptanceSpec`-style test (extend the existing
`shikumi-tools/test/AcceptanceSpec.hs` or add a new `BuiltinAcceptanceSpec`) constructs
`builtinRegistry localToolEnv stubWebClient` (a stub `WebClient` so the test needs no network),
seeds a temp directory with a file, and runs a *scripted* ReAct agent (using the mock LLM, as the
existing `ReActSpec`/`AcceptanceSpec` do) whose script proposes, in order: `read` the file, `edit`
it, `bash` to print the edited file, `grep` for the edited line, `web_fetch` a URL, then finish.
The test asserts on the recorded `Trajectory` observations: the read returns the original content,
the edit reports one replacement, the bash stdout contains the edited text, the grep returns a
match, and the web_fetch observation contains the stub body. This shows the catalog works through
the real loop, end to end, beyond compilation.

Finally, wire every new test module into `shikumi-tools.cabal`'s `test-suite` `other-modules` and
confirm the whole suite is green.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/shikumi`, inside the dev
shell. Enter it once:

```bash
cd /Users/shinzui/Keikaku/bokuno/shikumi
nix develop
```

Confirm the toolchain and that the package builds before any change (baseline):

```bash
ghc --version          # expect 9.12.4 (NOT 9.10.x)
cabal build shikumi-tools
cabal test shikumi-tools
```

Expected: the existing suite passes. A short transcript ends with something like:

```text
All N tests passed (…s)
```

After Milestone 1 (the `ToolEnv` module and its test exist), build and test just this package:

```bash
cabal build shikumi-tools
cabal test shikumi-tools 2>&1 | tail -n 20
```

Expected: the `Env` group passes (write/read round-trip, stat, readdir, exists, mkdir, rm, exec).
A failing read round-trip prints the asserted vs. actual bytes; a missing dependency prints a
cabal "unknown package" error — fix the `build-depends` list and rebuild.

Actual 2026-06-28T16:33:11Z:

```text
$ nix develop --command cabal test shikumi-tools
Tool.Env
  localToolEnv can perform filesystem operations and exec: OK (0.01s)

All 30 tests passed (0.01s)
Test suite shikumi-tools-test: PASS
1 of 1 test suites (1 of 1 test cases) passed.
```

Repeat the same `cabal build shikumi-tools && cabal test shikumi-tools` cycle at the end of each
milestone.

For Milestone 3, the grep/glob fast path expects `rg` and `fd` on `PATH`. Add them to the nix dev
shell (`nix/haskell.nix`, alongside the existing native build inputs such as `just`/`postgresql`),
then re-enter the shell and confirm:

```bash
rg --version          # expect ripgrep present
fd --version          # expect fd present
```

Expected: both print a version. The `FsSpec` grep/glob tests run the fast path against
`localToolEnv` (which now finds `rg`/`fd`) and the in-process baseline against a stub `ToolEnv`,
asserting identical results; a missing `rg`/`fd` would make the fast-path case silently fall back to
the baseline, so this version check is how you confirm the fast path is actually exercised.

For the network-gated web check in Milestone 2:

```bash
SHIKUMI_NET_TESTS=1 cabal test shikumi-tools 2>&1 | tail -n 20
```

Expected when the env var is set and the network is up: the live `web_fetch` case runs and passes
(`status == 200`, non-empty body). Without the env var, that case is skipped and printed as such.

Run the full repository test matrix once at the end:

```bash
just test
```

Expected: every package's suite passes.

Update this section with the actual transcripts as work proceeds.


## Validation and Acceptance

The change is effective when an agent can do real work through the catalog. Validate at three
levels.

First, **per-operation validation** (Milestones 1–4): the `Env`, `Web`, `Fs`, and `Shell` test
groups demonstrate each operation against `localToolEnv`/a stub `WebClient`. Concretely: writing
bytes then reading them returns the same bytes; `stat` on a written file reports `isFile = True`
and the correct size; `exec "echo hello"` returns `exitCode == 0` with `hello` in stdout; `edit`
on a present `oldString` reports `replacements == 1` and a re-read shows the substitution; `grep`
(as a regex) finds the edited line via **both** strategy layers — the `rg` fast path against
`localToolEnv` and the in-process baseline against a stub `ToolEnv` that reports `rg` absent —
returning identical matches, and the in-process baseline skips a seeded `.git`/`node_modules`/binary
file; `web_fetch` against a stub returns the stub body and surfaces a 404 status without throwing.

Second, **end-to-end agent validation** (Milestone 5): the acceptance test runs a scripted ReAct
agent over `builtinRegistry localToolEnv stubWebClient` that reads a seeded file, edits it, runs
`bash` to print the edited contents, greps for the edited line, and fetches a URL — and the test
asserts each step's observation in the recorded `Trajectory`. This is observable behavior: the
agent loop dispatches each tool by the name the model emits, the tool acts, and the observation
flows back. Phrased as a check a human can read: "given a file containing `# Old Title`, the agent
edits it to `# New Title`, the bash step's stdout contains `New Title`, and the grep step returns a
match for `New Title`."

Third, **live network validation** (manual): with `SHIKUMI_NET_TESTS=1`, `localWebClient` fetching
`https://example.com` returns HTTP 200 with a non-empty body, proving `web_fetch` works over a real
HTTP client and not only against a stub.

Acceptance is met when `cabal test shikumi-tools` is green (all of the above except the gated live
check), `just test` is green for the whole repo, and the gated live check passes when run with the
network available.


## Idempotence and Recovery

Every step is additive: new modules, new dependencies, new tests. Re-running `cabal build`/`cabal
test` is always safe and converges to the same result. If a milestone half-lands (e.g. the module
compiles but a test fails), the build remains runnable for the prior milestone's tests; fix
forward and re-run.

The tools themselves are designed for safe repetition where their semantics allow. `write` and
`edit` are deterministic given the same inputs (re-running `edit` with the same `oldString` after a
successful edit yields `replacements == 0` or a not-found error, returned as a value — not a
crash). `read`, `grep`, `glob`, `stat`, `exists`, and `web_fetch` are read-only and freely
repeatable. `bash`/`exec` and `rm` can have side effects; tests confine them to a temporary
directory created per test run (via `getTemporaryDirectory` + a unique subdir, removed at the end),
so repeated runs neither collide nor pollute the working tree. No migration or destructive
repository operation is involved.

If a `localToolEnv` operation hits a genuine I/O fault, it surfaces as a `ProviderFailure`
`ShikumiError`, which `runErased` catches and converts to a `ToolRunFailed` observation — so an
agent run degrades to a recoverable message rather than aborting. To roll back the whole change,
revert the new modules and the `shikumi-tools.cabal` edits; nothing outside the package is touched.


## Interfaces and Dependencies

New library dependencies added to `shikumi-tools/shikumi-tools.cabal` (`library` stanza): `directory`,
`filepath`, `process` (GHC boot libraries, present in the pinned toolchain), `http-client` +
`http-client-tls` (the web tools' HTTP/TLS stack — **new third-party deps**: contrary to an earlier
draft, these are *not* in the baikai *library*'s dependency closure — only baikai's executable/test
stanzas use them — so adding them here is a real, if small, surface addition), and `regex-tdfa`
(in-process `grep`'s regex engine — also a new dep). `bytestring`, `text`, `aeson`, `vector`,
`containers`, `effectful`, `lens`, `generic-lens`, `baikai`, and `shikumi` are already present.

New **runtime** (non-cabal) dependencies, supplied by nix in the dev shell and in sandbox images via
`nix/haskell.nix`: `ripgrep` (`rg`) and `fd`. These are optional at the contract level — `grep`/`glob`
have a hardened in-process baseline that runs without them — but are the preferred fast path and are
expected to be present in dev and sandboxes.

New modules, with the interfaces that must exist at the end of each milestone (all under
`shikumi-tools/src/Shikumi/Tool/`):

`Shikumi.Tool.Env` (Milestone 1):

```haskell
type Path = Text
type EnvRow es = (LLM :> es, Error ShikumiError :> es)

data ExecRequest = ExecRequest
  { command :: !Text, cwd :: !(Maybe Path), stdin :: !(Maybe Text), timeoutMs :: !(Maybe Int) }
data ExecResult  = ExecResult { exitCode :: !Int, stdout :: !Text, stderr :: !Text }
data FileStat    = FileStat { isFile :: !Bool, isDir :: !Bool, size :: !Integer }
data DirEntry    = DirEntry { name :: !Text, isDir :: !Bool }

data ToolEnv = ToolEnv
  { envExec      :: forall es. (EnvRow es) => ExecRequest -> Eff es ExecResult
  , envReadFile  :: forall es. (EnvRow es) => Path -> Eff es ByteString
  , envWriteFile :: forall es. (EnvRow es) => Path -> ByteString -> Eff es ()
  , envStat      :: forall es. (EnvRow es) => Path -> Eff es (Maybe FileStat)
  , envReaddir   :: forall es. (EnvRow es) => Path -> Eff es [DirEntry]
  , envExists    :: forall es. (EnvRow es) => Path -> Eff es Bool
  , envMkdir     :: forall es. (EnvRow es) => Path -> Eff es ()
  , envRm        :: forall es. (EnvRow es) => Path -> Eff es ()
  , envCwd       :: forall es. (EnvRow es) => Eff es Path
  }

localToolEnv :: ToolEnv
```

`Shikumi.Tool.Web` (Milestone 2):

```haskell
data FetchResult = FetchResult { status :: !Int, contentType :: !Text, body :: !Text, truncated :: !Bool }
data SearchHit   = SearchHit { title :: !Text, url :: !Text, snippet :: !Text }
data SearchResult = SearchResult { hits :: ![SearchHit] }

data WebClient = WebClient
  { webFetch  :: forall es. (EnvRow es) => Text -> Maybe Int -> Eff es FetchResult
  , webSearch :: forall es. (EnvRow es) => Text -> Maybe Int -> Eff es SearchResult
  }

data SearchConfig = SearchConfig { baseUrl :: !Text, apiKey :: !Text }  -- shape TBD per provider
localWebClient :: Manager -> Maybe SearchConfig -> WebClient
newTlsManager :: IO Manager            -- re-exported from Network.HTTP.Client.TLS
```

`Shikumi.Tool.Builtin.Web` (Milestone 2):

```haskell
data FetchReq  = FetchReq  { url :: !Text, maxBytes :: !(Maybe Int) }
data SearchReq = SearchReq { query :: !Text, maxResults :: !(Maybe Int) }

webFetchTool  :: WebClient -> Tool FetchReq  FetchResult
webSearchTool :: WebClient -> Tool SearchReq SearchResult
```

`Shikumi.Tool.Builtin.Fs` (Milestone 3):

```haskell
data ReadReq  = ReadReq  { path :: !Text, offset :: !(Maybe Int), limit :: !(Maybe Int) }
data ReadResp = ReadResp { content :: !Text, lineCount :: !Int, truncated :: !Bool }
data WriteReq = WriteReq { path :: !Text, content :: !Text }
data WriteResp = WriteResp { path :: !Text, bytesWritten :: !Int }
data EditReq  = EditReq  { path :: !Text, oldString :: !Text, newString :: !Text, replaceAll :: !(Maybe Bool) }
data EditResp = EditResp { path :: !Text, replacements :: !Int }
data GrepReq  = GrepReq  { pattern :: !Text, path :: !(Maybe Text), glob :: !(Maybe Text), ignoreCase :: !(Maybe Bool) }  -- pattern is a POSIX ERE (regex-tdfa)
data GrepMatch = GrepMatch { file :: !Text, line :: !Int, text :: !Text }
data GrepResp = GrepResp { matches :: ![GrepMatch], truncated :: !Bool }
data GlobReq  = GlobReq  { pattern :: !Text, path :: !(Maybe Text) }
data GlobResp = GlobResp { paths :: ![Text], truncated :: !Bool }

readTool  :: ToolEnv -> Tool ReadReq  ReadResp
writeTool :: ToolEnv -> Tool WriteReq WriteResp
editTool  :: ToolEnv -> Tool EditReq  EditResp
grepTool  :: ToolEnv -> Tool GrepReq  GrepResp
globTool  :: ToolEnv -> Tool GlobReq  GlobResp
```

`Shikumi.Tool.Builtin.Shell` (Milestone 4):

```haskell
data BashReq  = BashReq  { command :: !Text, cwd :: !(Maybe Text), timeoutMs :: !(Maybe Int), stdin :: !(Maybe Text) }
data BashResp = BashResp { exitCode :: !Int, stdout :: !Text, stderr :: !Text }

bashTool :: ToolEnv -> Tool BashReq BashResp
```

`Shikumi.Tool.Builtin` (Milestone 5):

```haskell
builtinFsTools  :: ToolEnv -> [SomeTool]
builtinWebTools :: WebClient -> [SomeTool]
builtinTools    :: ToolEnv -> WebClient -> [SomeTool]
builtinRegistry :: ToolEnv -> WebClient -> ToolRegistry
```

Input records derive `(Generic, ToSchema, FromModel, ToPrompt)`; output records derive `(Generic,
ToJSON)` (add `ToSchema, FromModel` if a tool's output is also fed to schema-aware consumers). Per
`haskell-jitsurei/core/record-patterns.md`, write these with **explicit deriving strategies** —
`deriving stock (Generic, Show, Eq)` for the standard classes and `deriving anyclass (...)` for the
`Generic`-driven ones — never a bare `deriving (...)` list, and never mixing implicit and explicit.
All record fields are strict (`!`), carry no prefixes, and are read via generic-lens `#label`.
These derivations otherwise follow the `WeatherReq`/`WeatherResp` precedent in
`shikumi-tools/test/Fixtures.hs`. Tools are wrapped for the registry with the existing `SomeTool`
constructor and dispatched by the existing `runToolCall`/ReAct machinery — this plan adds *no* new
machinery to `Shikumi.Tool` or `Shikumi.Agent.ReAct`; it only adds tool *values* and the `ToolEnv`/
`WebClient` seams they close over.

The relationship to the broader effort: this plan closes gap #1 from the kikan gap analysis
(`shinzui/kikan`, `docs/architecture/evolution/agent-infrastructure-gaps.md`). It is upstream of
shikigami's plans (which consume this catalog) and adjacent to — but independent of — the sibling
shikumi MCP-client plan (gap #6, surfacing external tools as `Tool`s) and the in-run
context-compaction plan (gap #5). None of those are in scope here.


## Revision Notes

### 2026-06-28 — validation pass and grep/glob redesign

The plan was validated against the codebase (two parallel read-only audits) and revised on two
points.

**Validation outcome.** Every structural claim the plan relies on was confirmed against real code:
`Tool`/`mkTool`/`SomeTool`/`ToolRegistry`/`mkRegistry`/`runToolCall`/`ToolError` in
`shikumi-tools/src/Shikumi/Tool.hs`; the `runErased` `ShikumiError → ToolRunFailed` catch; the
`CodeInterpreter` rank-2-record precedent (`Shikumi.CodeExec.Interpreter`, `RankNTypes` only); the
`unsafeEff_` bridge in `Shikumi.Effect.Time`; the `ShikumiError` constructors and `isTransient`
(`shikumi/src/Shikumi/Error.hs`); the `Embed` row pin (`Shikumi.Program`); the `react`/
`reactWithTrajectory`/`Trajectory`/`Step` shapes (`Shikumi.Agent.ReAct`); the `runEffMock`/
`mkToolCallResponse` test harness (`shikumi-tools/test/MockLLM.hs`); and the cabal stanza contents.
**One disproven caveat:** `Maybe` fields *are* supported as optional JSON properties
(`Shikumi/Schema.hs:133` → `required = False`; `FromField (Maybe a)` decodes missing/null →
`Nothing`), so M3's "fall back to required fields" hedge was removed.

**Correction 1 — http-client dependency claim.** The Decision Log and Interfaces section claimed
`http-client`/`http-client-tls` were "already in the dependency closure via baikai." Verified false:
baikai's *library* stanza (what `shikumi-tools` depends on) does not list them; only baikai's
executable/test stanzas do. They are genuinely new library dependencies. The rationale was corrected
(the choice stands; the risk note was wrong).

**Change 2 — grep/glob strategy (driven by the user's skepticism about not shelling to `rg`).** The
original "in-process, literal-substring" decision was replaced with a three-layer hybrid: a
**hardened in-process baseline** (noise-dir skip-list, binary detection, size/match/depth caps) as
the guaranteed contract, a **preferred `rg`/`fd` fast path** routed through `ToolEnv.exec` (same
seam, so sandbox-governed) when the binary is present, and **`bash`** as the escape hatch. Matching
upgraded from literal substring to **real regex via `regex-tdfa`** from the first cut. nix supplies
`rg`/`fd` in the dev shell and sandbox images (`nix/haskell.nix` change added to scope). `GrepResp`/
`GlobResp` gained a `truncated` flag. M3 now tests both strategy layers and the hardening bounds.
Affected sections: Progress, Decision Log, Milestone 3, Concrete Steps, Validation and Acceptance,
Interfaces and Dependencies.

### 2026-06-28 — conform records to record-patterns.md

The user flagged prefixed record fields. Aligned the plan with
`haskell-jitsurei/core/record-patterns.md`.

- **De-prefixed the data records** (the rule applies to them): `ExecRequest.execCwd → cwd`,
  `DirEntry.entryName → name`, `DirEntry.entryIsDir → isDir`, `SearchConfig.searchBaseUrl → baseUrl`,
  `SearchConfig.searchApiKey → apiKey`. Collisions these names now share with other records
  (`BashReq.cwd`, `FileStat.isDir`, the various `path` fields) are handled by `DuplicateRecordFields`,
  which is the point of the rule.
- **Switched field access in the code sketches** from record-selector syntax (`url req`, `path req`,
  `command req`) to generic-lens `#label` (`req ^. #url`, …), and noted that record *construction*
  (e.g. building `ExecRequest`) stays as-is — only record *update* syntax is banned.
- **Required explicit deriving strategies and the guide's extensions/imports** (`GHC2024`,
  `DuplicateRecordFields`, `OverloadedLabels`, `DeriveAnyClass`, `OverloadedStrings`, per-module
  `import Data.Generics.Labels ()`) for the new modules.
- **Recorded an explicit carve-out** for the rank-2 *operation* records `ToolEnv` (`envExec`, …) and
  `WebClient` (`webFetch`, …): they keep method-style names because higher-rank fields cannot form a
  `#label` lens (so the no-prefix rule, which is about `#label` access, does not apply), the in-repo
  precedent `CodeInterpreter { runCode }` is exactly this shape, and bare names would collide with
  `Prelude`/`bytestring`/`directory` selectors. Flagged as the one decision to revisit if bare names
  are preferred regardless.

Affected sections: Decision Log, Milestone 1, Milestone 2, Milestone 4, Interfaces and Dependencies.
