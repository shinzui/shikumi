---
id: 44
slug: tool-error-posture-infra-errors-escape-the-loop
title: "Tool Error Posture Infra Errors Escape the Loop"
kind: exec-plan
created_at: 2026-07-02T03:30:16Z
intention: "intention_01kwgdyxm7ehh8yys1pp4wf1zr"
master_plan: "docs/masterplans/8-tools-agents-and-cli-hardening.md"
---

# Tool Error Posture Infra Errors Escape the Loop

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

shikumi's ReAct agents run tools in a loop, and the framework promises that the
running cost ceiling (the "budget") is enforced underneath the loop: when the budget
is exhausted, the next model call is refused with a `BudgetExceeded` error and the
whole agent run aborts. Today that promise is broken whenever a *tool body* makes the
model call: `runErased` in `shikumi-tools/src/Shikumi/Tool.hs` catches **every**
`ShikumiError` a tool body throws — including `BudgetExceeded` — and converts it into
a `ToolRunFailed` observation that is fed back to the model as text. The loop then
happily keeps issuing its own model calls, spending money past the ceiling. The
module's own documentation ("only infrastructure faults bubble up as a
`ShikumiError`") describes behavior that does not exist: nothing bubbles up.

After this change, a tool body that throws an infrastructure error
(`BudgetExceeded` or `ContextWindowExceeded`) aborts the agent run — the caller of
`runProgram` receives `Left (BudgetExceeded …)` — while a tool body that throws a
recoverable error (a validation failure, a decode failure, a timeout, an IO fault)
still becomes an observation the model can react to, exactly as before. You can see
it working by running the new tests: a scripted agent whose tool throws
`BudgetExceeded` returns `Left (BudgetExceeded …)` and consumes no further scripted
model responses; a scripted agent whose tool throws `ValidationFailure` completes
normally with the failure text recorded as a step observation.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented
here, even if it requires splitting a partially completed task into two ("done" vs.
"remaining"). This section must always reflect the actual current state of the work.

- [ ] M1: add `isInfraToolError` partition to `shikumi-tools/src/Shikumi/Tool.hs` and
      make `runErased` rethrow infra errors.
- [ ] M1: correct the `runErased` and `ToolError` docstrings to describe the real
      posture.
- [ ] M2: add ToolSpec cases — tool body throwing `BudgetExceeded` escapes; tool body
      throwing `ValidationFailure` becomes `ToolRunFailed`.
- [ ] M2: add ReActSpec cases — budget abort mid-loop; recoverable error continues
      the loop.
- [ ] Final: `just test-one shikumi-tools` green; commit with the required trailers.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

- Decision: Partition the eight `ShikumiError` constructors as — rethrow (infra):
  `BudgetExceeded`, `ContextWindowExceeded`; convert to observation (recoverable):
  `InvalidJSON`, `MissingField`, `SchemaMismatch`, `ValidationFailure`,
  `ProviderFailure`, `Timeout`.
  Rationale: See "The partition, constructor by constructor" in Context and
  Orientation. In short: budget is global monotone state (continuing can only spend
  more); a context-window overflow inside a tool's own sub-call cannot be fixed by
  the outer loop's compaction; whereas the built-in tool environment deliberately
  encodes host IO faults as `ProviderFailure` and exec timeouts as `Timeout`, and
  those are exactly the failures a model routinely routes around. Source:
  production-readiness code review.
  Date: 2026-07-01

- Decision: Implement the partition with explicit arms for the infra constructors
  and a wildcard `_ -> False` for everything else.
  Rationale: A future `ShikumiError` constructor (EP-46 adds `CodeExecFailed`)
  defaults to "recoverable", which is the safe direction for the agent loop: a
  wrongly-recoverable error wastes a turn; a wrongly-fatal error kills a run that
  could have succeeded. The master plan's Integration Points section records that
  EP-46 must confirm this default for its new constructor.
  Date: 2026-07-01


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This repository is a Haskell cabal multi-package project. The package relevant here
is `shikumi-tools`; its library sources live under `shikumi-tools/src` and its test
suite (tasty + HUnit) under `shikumi-tools/test`. Everything builds inside the nix
dev shell: run `nix develop .#ghc9124` from the repository root
(`/…/shikumi`), then use `cabal` or the `just` recipes (`just test-one
shikumi-tools` runs `cabal test shikumi-tools`).

Key vocabulary, defined from scratch:

- A *tool* (`Tool i o` in `shikumi-tools/src/Shikumi/Tool.hs`) is a named effectful
  function from a typed input record `i` to a typed output `o`. Its body runs in the
  effect row `(LLM, Error ShikumiError)` — meaning it may itself call language
  models and may signal failure by throwing a `ShikumiError` through the typed error
  channel (the `effectful` library's `Effectful.Error.Static`).
- A *ReAct loop* (`shikumi-tools/src/Shikumi/Agent/ReAct.hs`) alternates model turns
  ("thought + action") with tool executions, feeding each tool result back to the
  model as an *observation* (plain text), until the model finishes or an iteration
  cap is hit.
- `ShikumiError` (`shikumi/src/Shikumi/Error.hs`, lines 22–39) is the single error
  vocabulary the whole framework shares. It has exactly eight constructors:
  `InvalidJSON`, `MissingField`, `SchemaMismatch`, `ValidationFailure`,
  `ProviderFailure`, `ContextWindowExceeded`, `Timeout`, `BudgetExceeded` — each
  carrying one `Text` payload.
- A `ToolError` (`Tool.hs`, lines 183–190) is a tool-call failure carried as a
  *value*: `ToolNotFound`, `ToolArgsInvalid`, or `ToolRunFailed`. The loop renders
  it to text (`renderToolError`) and feeds it back as an observation.

The bug. `runErased` (`Tool.hs`, currently lines 140–150) is the single place a tool
body executes behind the `SomeTool` existential. Its body is:

```haskell
runErased (SomeTool t) args =
  case fromModelChecked args of
    Left err -> pure (Left (ToolArgsInvalid (name t) (shikumiErrorText err)))
    Right i ->
      (Right . encodeText <$> run t i)
        `catchError` \_cs e -> pure (Left (ToolRunFailed (name t) (shikumiErrorText e)))
```

The `catchError` handler ignores the error's constructor entirely: every
`ShikumiError` from the body — including `BudgetExceeded` thrown by the resilient
LLM interpreter's pre-call budget gate (see `shikumi/src/Shikumi/LLM.hs`, whose
budget check refuses a call with `BudgetExceeded` once the cost ceiling is reached)
— becomes a `ToolRunFailed` value. The `ToolError` docstring (`Tool.hs`, lines
179–182) then claims "only infrastructure faults bubble up as a `ShikumiError`",
which is false, and the `runErased` docstring (lines 136–139) claims "it never
throws to the caller", which after this plan will also be deliberately false for
infra errors. Meanwhile the `Termination` docstring in `ReAct.hs` (lines 113–116)
promises "the budget ceiling is enforced one layer down by the resilient `LLM`
interpreter, surfacing as a `ShikumiError`" — a promise `runErased` currently
defeats for any model call made *inside a tool*.

The partition, constructor by constructor. Every one of the eight constructors must
be classified as either *infra* (rethrow; the agent run aborts) or *recoverable*
(convert to a `ToolRunFailed` observation; the loop continues):

- `BudgetExceeded` — **infra, rethrow.** The budget is a global, monotone cost
  ceiling. Turning it into an observation lets the loop keep issuing propose/extract
  completions, each spending more; no model reply can un-spend money. This is the
  motivating finding.
- `ContextWindowExceeded` — **infra, rethrow.** When a tool's own sub-model call
  overflows the window, the outer loop cannot fix it: the loop's reactive compaction
  (`ReAct.hs`, `completeProposeRecover` and the extract `catchError`) wraps only the
  loop's *own* `complete` calls, not tool dispatch, and compacting the loop's
  trajectory does nothing to the tool's internal prompt. Feeding it back as text
  invites the model to retry the identical failing call. Aborting surfaces a real
  configuration problem (model window too small for the tool's workload) to the
  operator.
- `Timeout` — **recoverable, observation.** The built-in shell/exec environment
  (`shikumi-tools/src/Shikumi/Tool/Env.hs`, `localExec`, lines 102–126) throws
  `Timeout` when a command exceeds its time budget. A timed-out command is the
  canonical failure a model recovers from (retry with a cheaper command, or give
  up on that avenue). `isTransient` in `shikumi/src/Shikumi/Error.hs` already
  classifies `Timeout` as transient.
- `ProviderFailure` — **recoverable, observation.** The built-in tool environment
  deliberately encodes host IO faults as `ProviderFailure` (`Env.hs`, `toolIO`,
  lines 165–171: any `IOException` — e.g. reading a nonexistent file — becomes
  `ProviderFailure "tool env: readFile: …"`), and the web client does the same for
  `HttpException` (`shikumi-tools/src/Shikumi/Tool/Web.hs`, `httpIO`, lines
  129–135). A missing file or a DNS failure is exactly what a ReAct model routinely
  routes around. Note the tension: a `ProviderFailure` from a *sub-model transport*
  also lands here and stays recoverable; the resilient LLM interpreter has already
  retried it before it surfaces, so treating the final failure as tool-level is
  acceptable. If this ever needs to change, the fix is a dedicated constructor for
  tool-env faults, not reclassifying `ProviderFailure` — record that in the Decision
  Log if pursued.
- `InvalidJSON`, `MissingField`, `SchemaMismatch`, `ValidationFailure` —
  **recoverable, observation.** These are deterministic, data-shaped failures
  (malformed sub-model output, failed validation rules — the built-in fs tools throw
  `ValidationFailure` on purpose for things like "edit: oldString not found",
  `Fs.hs`, `throwValidation`). The model can correct its arguments or approach on
  the next turn. Aborting on these would make ordinary tool misuse fatal.

Where the rethrown error goes. `runToolCall` (`Tool.hs`, lines 199–208) calls
`runErased`; the ReAct loop calls `runToolCall` at `ReAct.hs` line 214 with no
surrounding `catchError` (the loop's handlers wrap only `complete` calls). So a
rethrown error propagates out of `reactLoop`, out of `runProgram`, to whatever
discharges `Error ShikumiError` — in tests, `runErrorNoCallStack`, yielding
`Left (BudgetExceeded …)`. No ReAct code change is needed in this plan; the ReAct
tests added here pin that propagation. (EP-46, per the master plan, later changes
loop behavior and must not re-catch these errors.)

Existing test infrastructure you will reuse (all under `shikumi-tools/test/`):
`MockLLM.hs` provides `runEffMock :: [Response] -> Eff '[LLM, Error ShikumiError,
IOE] a -> IO (Either ShikumiError a)` (scripted responses, no network) and
`runAgent` (same, through `runProgram`); `Fixtures.hs` provides the `weatherTool`
registry, `weatherSignature`, `weatherQuestion`, and scripted reply builders like
`promptScript`. `ToolSpec.hs` tests `runToolCall` directly; `ReActSpec.hs` tests the
loop. There is currently **no** test anywhere for a tool body that throws — only
decode failures (`ToolArgsInvalid`) and unknown names are covered.


## Plan of Work

Milestone 1 — the partition and the docstrings. Scope: `shikumi-tools/src/Shikumi/Tool.hs`
only. At the end of this milestone, `runErased` rethrows infra errors and the module
documentation tells the truth; the package still compiles and all existing tests
still pass (no existing test exercises a throwing tool body). Acceptance: `cabal
build shikumi-tools` succeeds; `just test-one shikumi-tools` is green.

Edit 1: add a classification function near `shikumiErrorText` (bottom of `Tool.hs`),
and export it from the module's export list (add `isInfraToolError` to the
"The typed error and the wire round-trip" export group) so tests and downstream code
can consult the policy:

```haskell
-- | Which 'ShikumiError's must escape the agent loop rather than become
-- observations. Budget and context-window exhaustion are infrastructure faults:
-- the model cannot recover from them by reading an observation, and continuing
-- the loop would either overspend (budget) or deterministically re-fail
-- (context window). Everything else — validation, decode, timeout, and
-- provider/IO faults — is a tool-level failure the model may route around, so it
-- is fed back as a 'ToolRunFailed' observation. New constructors default to
-- recoverable: a wrongly-recoverable error wastes a turn, a wrongly-fatal error
-- kills a run that could have succeeded.
isInfraToolError :: ShikumiError -> Bool
isInfraToolError = \case
  BudgetExceeded {} -> True
  ContextWindowExceeded {} -> True
  _ -> False
```

Edit 2: change `runErased`'s handler (currently lines 145–150) to discriminate. The
`effectful` `catchError` handler receives a `CallStack` and the error; rethrow with
`throwError` (import it: change the import at line 64 to
`import Effectful.Error.Static (Error, catchError, throwError)`):

```haskell
runErased (SomeTool t) args =
  case fromModelChecked args of
    Left err -> pure (Left (ToolArgsInvalid (name t) (shikumiErrorText err)))
    Right i ->
      (Right . encodeText <$> run t i)
        `catchError` \_cs e ->
          if isInfraToolError e
            then throwError e
            else pure (Left (ToolRunFailed (name t) (shikumiErrorText e)))
```

Edit 3: correct the two lying docstrings. Replace the `runErased` haddock (lines
136–139) so it reads, in substance: decode failures become `ToolArgsInvalid`; a body
that throws a *recoverable* `ShikumiError` becomes `ToolRunFailed`; a body that
throws an *infrastructure* error (`isInfraToolError`) rethrows and aborts the
caller's loop. Replace the `ToolError` haddock (lines 179–182) sentence "only
infrastructure faults bubble up as a 'ShikumiError'" with a reference to the actual
partition: "infrastructure faults ('isInfraToolError': budget and context-window
exhaustion) bubble up as a 'ShikumiError' and abort the loop; every other failure is
carried here as a value". Keep the surrounding prose about observations intact.

Milestone 2 — tests that fail before and pass after. Scope:
`shikumi-tools/test/ToolSpec.hs` and `shikumi-tools/test/ReActSpec.hs` (plus a small
fixture addition to `shikumi-tools/test/Fixtures.hs` if you prefer to share the
throwing tools; inline definitions in the spec files are equally acceptable — the
existing `CodeActSpec.hs` defines its own `addOneTool` inline, so follow that
precedent and keep the new tools inline). At the end of this milestone four new test
cases exist. Acceptance: with Milestone 1 reverted (`git stash` the `Tool.hs`
change), the two "infra" cases fail; with it applied, all pass.

In `ToolSpec.hs` add two cases to the existing `testGroup "Tool"`. Define two local
tools (imports needed: `mkTool`, `SomeTool (..)`, `mkRegistry` from `Shikumi.Tool`;
`throwError` from `Effectful.Error.Static`; `ShikumiError (..)` from
`Shikumi.Error`). Note the input type: reuse the fixture pattern — a tool over a
simple record with `ToSchema`/`FromModel` instances. The simplest is to reuse
`WeatherReq` from `Fixtures`:

```haskell
budgetTool :: Tool WeatherReq WeatherResp
budgetTool = mkTool "burn_budget" "Always exceeds the budget." $ \_req ->
  throwError (BudgetExceeded "ceiling reached")

flakyTool :: Tool WeatherReq WeatherResp
flakyTool = mkTool "flaky" "Always fails validation." $ \_req ->
  throwError (ValidationFailure "nothing to see")
```

Case A (fails before M1): running `runToolCall` against a registry containing
`budgetTool` with valid `weatherArgs` yields `Left (BudgetExceeded "ceiling
reached")` from `runEffMock` — i.e. the error escaped the tool boundary. Before the
fix it yields `Right (Left (ToolRunFailed "burn_budget" _))`.

Case B (passes before and after; pins the recoverable side): the same call against
`flakyTool` yields `Right (Left (ToolRunFailed "flaky" msg))` with `"nothing to
see"` in `msg`.

In `ReActSpec.hs` add two cases:

Case C (fails before M1): build a registry `mkRegistry [SomeTool budgetTool]`, a
prompt-protocol script whose first reply proposes calling `burn_budget` (copy the
shape of `Fixtures.proposeCallReply`, changing the tool name and args to valid
`WeatherReq` JSON), followed by `finishReply` and `extractReply` entries that must
never be consumed. Run
`runAgent script (reactWithTrajectory weatherSignature budgetRegistry defaultReActConfig) weatherQuestion`
and assert the result is `Left (BudgetExceeded "ceiling reached")`. Before the fix
the loop continues, consumes the finish/extract replies, and returns `Right _`.

Case D (pins the recoverable loop path): same shape with `flakyTool`; assert the
run returns `Right (o, traj)`, that `traj` contains a step whose `action` is
`CallTool "flaky" _` and whose `observation` text contains both `"failed"` (from
`renderToolError`'s `ToolRunFailed` rendering: `Error: tool "flaky" failed: …`) and
`"nothing to see"`, and that the termination is `TerminatedFinish`.


## Concrete Steps

All commands run from the repository root. Enter the dev shell once:

```bash
cd /path/to/shikumi
nix develop .#ghc9124
```

Build and test loop while editing:

```bash
cabal build shikumi-tools
just test-one shikumi-tools
```

Expected test output tail once complete (counts will differ as suites grow; what
matters is the new case names appearing and the suite passing):

```text
  Tool
    decodes valid args and runs the body:                    OK
    returns ToolArgsInvalid for a missing required field:    OK
    returns ToolNotFound for an unknown name:                OK
    a tool body throwing BudgetExceeded escapes as ShikumiError: OK
    a tool body throwing ValidationFailure becomes ToolRunFailed: OK
  ReAct
    ...
    a tool throwing BudgetExceeded aborts the loop:          OK
    a tool throwing a recoverable error yields an observation and the loop continues: OK

All N tests passed
```

To demonstrate failing-before: stash the source change and re-run the suite; the two
infra cases must fail with the loop/tool returning a `Right`/`ToolRunFailed` shape
instead of the escaped error:

```bash
git stash push shikumi-tools/src/Shikumi/Tool.hs
just test-one shikumi-tools   # expect the two new infra cases to FAIL
git stash pop
just test-one shikumi-tools   # expect all green
```

Committing: this repository uses Conventional Commits, and every commit in this
initiative must carry three trailers naming the master plan, this plan, and the
intention. Example:

```text
fix(tools): rethrow infra errors from tool bodies instead of observing them

Tool bodies that throw BudgetExceeded/ContextWindowExceeded now abort the
agent loop; recoverable errors still become ToolRunFailed observations.

MasterPlan: docs/masterplans/8-tools-agents-and-cli-hardening.md
ExecPlan: docs/plans/44-tool-error-posture-infra-errors-escape-the-loop.md
Intention: intention_01kwgdyxm7ehh8yys1pp4wf1zr
```


## Validation and Acceptance

Acceptance is behavioral:

1. Running the shikumi-tools suite (`just test-one shikumi-tools` inside `nix
   develop .#ghc9124`) passes, including the four new cases named above.
2. The two infra-path cases (`ToolSpec` case A, `ReActSpec` case C) demonstrably
   fail when the `Tool.hs` change is reverted (see the stash transcript in Concrete
   Steps) — proving they pin the new behavior, not incidental structure.
3. Reading `shikumi-tools/src/Shikumi/Tool.hs` no longer shows the sentence "only
   infrastructure faults bubble up" without the partition being real, and
   `runErased`'s haddock no longer claims it never throws.
4. `cabal build all` still succeeds (no other package consumes `runErased`'s
   swallow-everything behavior; the ReAct loop is the only caller of `runToolCall`
   in `shikumi-tools`, plus `CodeAct.hs` — whose loop likewise has no `catchError`
   around tool dispatch, so CodeAct inherits the corrected posture automatically;
   no change there).


## Idempotence and Recovery

Every step is an ordinary source edit plus test run; re-running any command is safe.
If Milestone 2's tests are written first (recommended), they fail until Milestone 1
lands — that is the expected order, not an error. To back out entirely, revert the
commit; no data, schema, or generated artifacts are involved.


## Interfaces and Dependencies

No new library dependencies. Modules touched:

- `shikumi-tools/src/Shikumi/Tool.hs` — changed function `runErased :: (LLM :> es,
  Error ShikumiError :> es) => SomeTool -> Value -> Eff es (Either ToolError Text)`
  (signature unchanged; behavior now rethrows infra errors); new exported function
  `isInfraToolError :: ShikumiError -> Bool`; import list gains `throwError`.
- `shikumi-tools/test/ToolSpec.hs`, `shikumi-tools/test/ReActSpec.hs` — new cases
  as described; imports gain `Shikumi.Error (ShikumiError (..))`,
  `Effectful.Error.Static (throwError)`, and `Shikumi.Tool (SomeTool (..), Tool,
  mkRegistry, mkTool)` where not already present.
- Read-only context: `shikumi/src/Shikumi/Error.hs` (the eight-constructor
  vocabulary), `shikumi-tools/src/Shikumi/Agent/ReAct.hs` (verifying no handler
  wraps `runToolCall`), `shikumi-tools/src/Shikumi/CodeExec/CodeAct.hs` (same).

Coordination (from the master plan's Integration Points): EP-46 later adds a
`CodeExecFailed` constructor to `ShikumiError`; `isInfraToolError`'s wildcard arm
classifies it recoverable by default, and EP-46 is responsible for confirming that.
