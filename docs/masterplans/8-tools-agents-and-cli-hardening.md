---
id: 8
slug: tools-agents-and-cli-hardening
title: "Tools, Agents, and CLI Hardening"
kind: master-plan
created_at: 2026-07-02T03:29:36Z
intention: "intention_01kwgdyxm7ehh8yys1pp4wf1zr"
---

# Tools, Agents, and CLI Hardening

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

A production-readiness code review of `shikumi-tools` (typed tools, built-in tools,
the ReAct and CodeAct agent loops, the restricted code interpreter) and `shikumi-cli`
(the `shikumi` command line) surfaced a cluster of correctness and safety gaps. After
this initiative, the agent runtime and the CLI keep the promises their documentation
already makes:

- A tool body that hits an infrastructure fault — most importantly the cost ceiling
  (`BudgetExceeded`) — aborts the agent loop instead of being silently converted into
  a model-visible observation that lets the loop keep spending. Recoverable tool
  failures still become observations the model can react to. This makes the budget
  ceiling documented in `shikumi-tools/src/Shikumi/Agent/ReAct.hs` actually
  enforceable through tools.
- The built-in filesystem, web, and shell tools behave defensively: glob matching is
  consistent between the fast (`rg`/`fd`) and fallback (in-process) paths; a fetched
  web body is capped *while downloading* and the fetcher has a documented,
  configurable SSRF posture; a model-supplied exec timeout cannot disable the timeout
  or overflow arithmetic; `truncated` flags in tool responses are truthful; the
  directory walker cannot be blown up by symlink cycles; and the deliberately
  non-hermetic posture of `bash`/local tool environments is documented where users
  will read it.
- The ReAct and CodeAct loops behave predictably at the edges: compaction honors its
  `enabled` flag everywhere, compaction summaries appear in returned trajectories as
  an explicit marker rather than a fake tool call, native multi-tool-call responses
  are executed in order rather than silently dropped after the first, CodeAct tags
  interpreter errors and gains the same compaction wiring ReAct has, the restricted
  DSL supports unary minus and string escapes that models routinely emit, and
  `programOfThought` reports code failure honestly instead of as `ProviderFailure`.
- The CLI is safe against path-escaping trace ids, reports replay failures
  distinguishably, and — for the first time — has tests of the CLI layer itself
  (argument parsing, dispatch, error messages, exit codes), not just its runtime
  capabilities.

In scope: `shikumi-tools`, `shikumi-cli`, and the two core `shikumi` modules those
fixes force us to touch (`shikumi/src/Shikumi/Error.hs` for one new error
constructor, `shikumi/src/Shikumi/Compaction.hs` for the `enabled` flag). Out of
scope: any new sandbox/subprocess interpreter, any network-dependent test
infrastructure beyond what exists (the `SHIKUMI_NET_TESTS` gate), provider/transport
changes in baikai, and performance work not required by a correctness fix.


## Decomposition Strategy

The review findings cluster into four functional concerns that are almost entirely
disjoint in the files they touch and in how each is verified, so the initiative
decomposes into four ExecPlans rather than one sprawling plan or many micro-plans.

The first concern is the *error posture of the tool boundary*: `runErased` in
`shikumi-tools/src/Shikumi/Tool.hs` converts every `ShikumiError` a tool body throws
into an observation, which silently breaks the budget-ceiling story. This is a small,
self-contained change to one function plus a documented partition of the whole
`ShikumiError` vocabulary, and it is the highest-severity finding — it ships first
and alone (EP-44).

The second concern is *hardening the built-in tools* (filesystem, web, shell,
timeouts). These fixes live in `shikumi-tools/src/Shikumi/Tool/Builtin/Fs.hs`,
`shikumi-tools/src/Shikumi/Tool/Web.hs`, and `shikumi-tools/src/Shikumi/Tool/Env.hs`,
are individually small but numerous, and share test fixtures (temp directories, the
fallback `ToolEnv`), so they form one plan (EP-45) rather than five slivers.

The third concern is *agent-loop behavior* (ReAct, CodeAct, the restricted
interpreter, programOfThought). These findings are all about what the loop does with
model output and long trajectories, they share the mock-LM test harness, and several
of them touch `shikumi-tools/src/Shikumi/Agent/ReAct.hs` together — so they form one
plan (EP-46). EP-46 is sequenced after EP-44 because both edit `ReAct.hs`-adjacent
behavior and EP-46 extends `shikumiErrorText` in `Tool.hs`, whose surrounding
docstrings EP-44 rewrites; landing EP-44 first avoids churn.

The fourth concern is the *CLI layer* (EP-47): trace-id path sanitization, replay
error messages, and a test suite for parsing/dispatch. It shares no code with the
other three and can proceed fully in parallel.

Alternatives considered: a single mega-plan was rejected because it would span more
than ten files across three packages with unrelated validation stories (the ExecPlan
spec's threshold for decomposition). Splitting EP-45 into separate fs/web/timeout
plans was rejected because the plans would share fixtures and each would be trivially
small; splitting EP-46's interpreter fixes out was rejected for the same reason. A
"core-errors" plan owning the new `ShikumiError` constructor alone was rejected: the
constructor is meaningless without its single consumer (`programOfThought` in EP-46),
so EP-46 owns it and the master plan documents the cross-package impact as an
integration point instead.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 44 | Tool Error Posture: Infra Errors Escape the Loop | docs/plans/44-tool-error-posture-infra-errors-escape-the-loop.md | None | None | Not Started |
| 45 | Builtin Tool Hardening: Fs, Web, and Timeouts | docs/plans/45-builtin-tool-hardening-fs-web-and-timeouts.md | None | None | Not Started |
| 46 | ReAct and CodeAct Behavior Fixes | docs/plans/46-react-and-codeact-behavior-fixes.md | None | EP-44 | Not Started |
| 47 | CLI Hardening and CLI-Layer Tests | docs/plans/47-cli-hardening-and-cli-layer-tests.md | None | None | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-44).


## Dependency Graph

EP-44, EP-45, and EP-47 are mutually independent and can be implemented in any order
or in parallel: EP-44 edits `shikumi-tools/src/Shikumi/Tool.hs` (plus tests), EP-45
edits the built-in tool modules under `shikumi-tools/src/Shikumi/Tool/` (plus a doc
correction in `shikumi-tools/src/Shikumi/CodeExec/Interpreter.hs`), and EP-47 edits
`shikumi-cli` only.

EP-46 soft-depends on EP-44. There is no compile-time artifact EP-46 needs from
EP-44, so it *can* proceed independently, but both plans change behavior around the
tool-dispatch call inside `shikumi-tools/src/Shikumi/Agent/ReAct.hs` and both add
ReAct-loop tests to the same spec files. Land EP-44 first so that EP-46's loop-level
tests (compaction, multi-tool-call, corrective step) are written against the final
error posture — under EP-44, an infra error thrown by a tool aborts the loop, and
EP-46's tests must not accidentally rely on the old swallow-everything behavior.
EP-46 also adds a case arm to the exhaustive `shikumiErrorText` function in
`shikumi-tools/src/Shikumi/Tool.hs` (for its new `ShikumiError` constructor); EP-44
rewrites the docstrings around that function, so ordering EP-44 first keeps the merge
trivial.

EP-45 and EP-46 both touch `shikumi-tools/src/Shikumi/CodeExec/Interpreter.hs`, but
in disjoint regions (EP-45 corrects the security-posture module documentation; EP-46
changes the tokenizer/parser and the grammar documentation). They may land in either
order; see Integration Points.


## Integration Points

**`shikumi-tools/src/Shikumi/Agent/ReAct.hs` (EP-44, EP-46).** EP-44 owns the *error
path*: what happens when `runToolCall` (called at ReAct.hs line 214) lets a
`ShikumiError` propagate — after EP-44 an infra error thrown by a tool body escapes
`runErased` and therefore aborts the loop. EP-46 owns *loop behavior*: reactive
compaction honoring the `enabled` flag, the summary-step representation in returned
trajectories, and native multi-tool-call handling. EP-46 must not weaken or re-catch
the errors EP-44 lets escape; its reactive-compaction `catchError` handlers wrap only
the loop's own `complete` calls (as today), never the tool dispatch.

**`shikumi-tools/src/Shikumi/Tool.hs` — `shikumiErrorText` (EP-44, EP-46).** This
private function pattern-matches every `ShikumiError` constructor exhaustively
(currently lines 218–228). EP-44 rewrites the module's error-posture docstrings and
adds the infra/recoverable partition next to it. EP-46 adds one case arm for the new
constructor it introduces. EP-44 defines the shape; EP-46 extends it.

**`ShikumiError` in `shikumi/src/Shikumi/Error.hs` (EP-46, consumed everywhere).**
EP-46(f) adds one constructor (`CodeExecFailed`) for programOfThought's honest
failure reporting. This is a breaking change to the core `shikumi` package's error
vocabulary. Known files with exhaustive or enumerating matches that must be updated
in the same change: `shikumi-tools/src/Shikumi/Tool.hs` (`shikumiErrorText`,
exhaustive case) and `shikumi/test/ErrorSpec.hs` (its `isTransient` test enumerates
every constructor). `isTransient` in `shikumi/src/Shikumi/Error.hs` uses a wildcard
default (`_ -> False`), which is already the correct classification for a
deterministic code failure, but EP-46 must state that explicitly in the
`isTransient` doc and test. EP-44's partition function in `Tool.hs` also uses a
wildcard default (infra constructors listed explicitly, everything else
recoverable), so EP-46's new constructor lands on the recoverable side without a
code change there — EP-46 must confirm that classification deliberately.

**`shikumi/src/Shikumi/Compaction.hs` (EP-46, consumed by ReAct and CodeAct).**
EP-46(a) makes `compactTail` honor `CompactionConfig.enabled` in the core `shikumi`
package. Both the ReAct loop (existing) and the CodeAct loop (newly wired by
EP-46(d)) consume it. No other plan touches this module.

**`shikumi-tools/src/Shikumi/CodeExec/Interpreter.hs` (EP-45, EP-46).** EP-45 owns
the module's *security posture paragraph* (the "SECURITY POSTURE" section, currently
lines 13–28, whose claim that the effect row prevents IO is contradicted by
`unsafeEff_` in `Env.hs`/`Web.hs`). EP-46 owns the *grammar*: the tokenizer/parser
code and the "The restricted DSL" documentation section (currently lines 30–37).
Whichever plan lands second rebases trivially; the regions do not overlap.


## Progress

Track milestone-level progress across all child plans. Each entry names the child plan
and the milestone.

- [ ] EP-44: M1 — partition `ShikumiError` in `runErased`; infra errors rethrow, docstrings corrected
- [ ] EP-44: M2 — loop-level tests: budget abort and recoverable-observation continue
- [ ] EP-45: M1 — glob semantics unified between fast and fallback paths, with parity tests
- [ ] EP-45: M2 — web fetch: streamed byte cap and configurable SSRF policy
- [ ] EP-45: M3 — exec timeout clamped; truthful truncation flags; symlink-safe walk
- [ ] EP-45: M4 — schema helper tidied; security-posture docs for Shell/Env/Interpreter
- [ ] EP-46: M1 — compaction honors `enabled` (core + ReAct reactive path)
- [ ] EP-46: M2 — explicit `Summarized` action; consumers updated
- [ ] EP-46: M3 — native multi-tool-call execution; corrective-step test
- [ ] EP-46: M4 — CodeAct error tagging and compaction wiring
- [ ] EP-46: M5 — DSL unary minus + string escapes; guides updated
- [ ] EP-46: M6 — `CodeExecFailed` constructor; programOfThought honest failure
- [ ] EP-47: M1 — trace-id sanitization and distinct replay failure messages
- [ ] EP-47: M2 — CLI-layer test suite through `parseCommand`/`dispatch`


## Surprises & Discoveries

Document cross-plan insights, dependency changes, scope adjustments, or unexpected
interactions between child plans. Provide concise evidence.

(None yet.)


## Decision Log

- Decision: Decompose the production-readiness review findings into four ExecPlans —
  EP-44 (tool error posture), EP-45 (built-in tool hardening), EP-46 (ReAct/CodeAct
  behavior), EP-47 (CLI hardening + tests) — with EP-44/45/47 independent and EP-46
  soft-dependent on EP-44.
  Rationale: The findings cluster into four functional concerns with nearly disjoint
  file sets and distinct verification stories (see Decomposition Strategy). EP-44 is
  the highest-severity finding (the budget ceiling is silently defeated by tool
  bodies) and is deliberately kept minimal so it can land first. EP-46 follows EP-44
  because both plans edit behavior around `ReAct.hs`'s tool dispatch and the
  exhaustive `shikumiErrorText` in `Tool.hs`. Source: production-readiness code
  review of shikumi-tools and shikumi-cli (verified pass).
  Date: 2026-07-01

- Decision: The new `ShikumiError` constructor needed by EP-46(f) lives inside EP-46
  rather than in a separate core-package plan.
  Rationale: The constructor has exactly one producer (programOfThought) and its
  cross-package impact is small and enumerable (two exhaustive/enumerating matches);
  a standalone plan would not be independently verifiable. The master plan records
  the affected files under Integration Points so any contributor sees the blast
  radius. Source: production-readiness code review.
  Date: 2026-07-01


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original vision.

(To be filled during and after implementation.)
