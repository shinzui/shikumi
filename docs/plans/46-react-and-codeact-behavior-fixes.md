---
id: 46
slug: react-and-codeact-behavior-fixes
title: "ReAct and CodeAct Behavior Fixes"
kind: exec-plan
created_at: 2026-07-02T03:30:16Z
intention: "intention_01kwgdyxm7ehh8yys1pp4wf1zr"
master_plan: "docs/masterplans/8-tools-agents-and-cli-hardening.md"
---

# ReAct and CodeAct Behavior Fixes

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

shikumi's two agent loops — ReAct (`shikumi-tools/src/Shikumi/Agent/ReAct.hs`,
alternating model "thought + action" turns with tool executions) and CodeAct
(`shikumi-tools/src/Shikumi/CodeExec/CodeAct.hs`, the same loop where each action is
a code snippet) — have a cluster of edge-case behaviors that surprise users and
corrupt the data downstream consumers rely on. After this plan:

- Turning compaction off (`CompactionConfig { enabled = False }`) actually turns it
  off everywhere. Today the loop's *reactive* path (recovering from a
  `ContextWindowExceeded` provider error) compacts unconditionally.
- A compaction summary appears in the returned `Trajectory` as an explicit
  `Summarized` action, not as a fake tool call `CallTool "" Null` that evaluators
  and optimizers must reverse-engineer.
- When a natively tool-calling model emits several tool calls in one turn, the loop
  executes **all of them in order** instead of silently dropping all but the first.
- CodeAct observations distinguish errors from output (`Error: code failed: …`
  prefix), and CodeAct gains the same context-window compaction wiring ReAct has —
  today a long CodeAct trajectory overflows terminally.
- The restricted code DSL accepts unary minus (`-3`, `2 * -3`) and string escapes
  (`\"`, `\\`, `\n`, `\t`) — things models routinely emit and today get parse
  errors for — and the prompt guides describe the language accurately.
- `programOfThought` reports exhausted code attempts as a new, honest
  `CodeExecFailed` error instead of mislabeling them `ProviderFailure`.

Each item is observable through hermetic tests in the `shikumi-tools` (and one in
the `shikumi`) test suites; no network is involved anywhere.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented
here, even if it requires splitting a partially completed task into two ("done" vs.
"remaining"). This section must always reflect the actual current state of the work.

- [ ] M1: `compactTail` honors `enabled`; ReAct reactive handlers honor `enabled`;
      tests.
- [ ] M2: `Summarized` action constructor; `summaryStep`, `renderAction`, jitsurei
      apps, CompactionSpec updated; trajectory doc updated.
- [ ] M3: `Proposal` type; native protocol executes all tool calls in order;
      `mkToolCallsResponse` mock builder; multi-call and corrective-step tests.
- [ ] M4: CodeAct error tagging; CodeAct compaction wiring (`compaction` in
      `CodeActConfig`, proactive + reactive paths); tests.
- [ ] M5: DSL unary minus and string escapes; module doc, `dslGuide`,
      `codeActGuide` updated; RestrictedSpec cases.
- [ ] M6: `CodeExecFailed` constructor in core `shikumi`; `shikumiErrorText` arm;
      `programOfThought` uses it; ErrorSpec + ProgramOfThoughtSpec updated.
- [ ] Final: `just test-one shikumi-tools` and `just test-one shikumi` green;
      `cabal build all` green; commits with required trailers.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

- Decision: Native multi-tool-call turns execute every call in order (one `Step`
  per call, the model's thought text attached to the first), rather than feeding
  back a "one call at a time" corrective observation.
  Rationale: Models that emit parallel calls expect a result per call; silently
  dropping the tail (current behavior) loses information the model believes it
  requested, and a corrective bounce wastes an iteration and trains the trajectory
  data on an artificial failure. Executing in order preserves sequential semantics
  (later calls may depend on earlier writes) and keeps the trajectory faithful.
  Date: 2026-07-01

- Decision: Represent compaction summaries with a new `Summarized` constructor on
  `Action` (summary text stays in the step's `observation`), while the
  corrective-step sentinel (`CallTool "" Null` for unparseable replies) is kept but
  documented.
  Rationale: Summaries are produced by the framework and consumed by
  evaluators/optimizers, so they need a first-class, pattern-matchable marker.
  Corrective steps are model-visible feedback within one run; converting them too
  would widen the change for little downstream value — documented instead, and easy
  to revisit.
  Date: 2026-07-01

- Decision: Add `CodeExecFailed !Text` to `ShikumiError` (core `shikumi` package)
  rather than reusing `ValidationFailure`.
  Rationale: The error module's charter is "the single error vocabulary…every
  package MUST surface failures through it"; sandbox failure after N attempts is a
  distinct, reportable failure mode that operators will want to alert on separately
  from schema/validation noise. PVP note: adding a constructor to an exported type
  is a breaking change for external consumers of `shikumi-0.2.0.0`; in-repo
  packages build together via `cabal.project`, and the version-bump decision is
  deferred to the next release (record there). Classification: deterministic, so
  `isTransient` stays `False` (the wildcard already yields that; ErrorSpec pins it
  explicitly) and EP-44's `isInfraToolError` wildcard classifies it recoverable —
  correct, since a tool body embedding a code loop should surface it as an
  observation.
  Date: 2026-07-01

- Decision: Implement unary minus by parsing `-x` at the factor level as
  `EBin Sub (ENum 0) x` instead of adding a new AST node.
  Rationale: No evaluator change, correct precedence (`-2 * 3` is `(-2) * 3`,
  `-(2+3)` works), zero new surface area. Source: production-readiness review's
  preference for implementing over documenting-away, since models routinely emit
  negative literals.
  Date: 2026-07-01


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

Haskell cabal multi-package repo; work happens in `shikumi-tools` (agent loops,
interpreter) and, for one milestone, the core `shikumi` package (error vocabulary,
compaction helper). Build/test inside the dev shell: from the repo root,
`nix develop .#ghc9124`, then `just test-one shikumi-tools`,
`just test-one shikumi`, and `cabal build all`.

Orientation over the touched modules:

- `shikumi/src/Shikumi/Compaction.hs` — the shared "shrink the working context"
  helper. `CompactionConfig` (lines 36–49) has `reserveTokens`, `keepRecent`,
  `enabled`. `usageExceedsWindow` (lines 60–62) *does* check `enabled` — this
  drives ReAct's proactive compaction. But `compactTail` (lines 66–84), the
  function that actually folds older items into a model-written summary, never
  checks `enabled`.
- `shikumi-tools/src/Shikumi/Agent/ReAct.hs` — the ReAct loop. The *reactive* paths
  catch `ContextWindowExceeded` from the loop's own `complete` calls and compact
  unconditionally: the extract handler at lines 227–234 calls
  `forceCompactTrajectory`, and `completeProposeRecover` at lines 238–249 calls
  `forceCompactAcc` — neither consults `enabled`. `summaryStep` (lines 282–288)
  fabricates `CallTool "" Null` as the summary marker; `correctiveStep` (lines
  272–281) uses the same sentinel for unparseable-reply feedback. Yet
  `reactWithTrajectory`'s haddock (lines 173–175) sells the trajectory to
  "evaluators/optimizers and tests that assert on the steps". The native
  protocol's `parsePropose` (lines 388–392) pattern-matches `(tc : _)` — every
  tool call after the first is silently discarded. `ProtocolImpl` (lines 305–310)
  is the seam both protocols implement; `Action`/`Step`/`Trajectory` (lines
  96–128) are the trajectory data model.
- `shikumi-tools/src/Shikumi/CodeExec/CodeAct.hs` — the CodeAct loop.
  `CodeActConfig` (lines 52–59) has only `maxIters` and `interpreter` — no
  compaction at all; the loop (lines 92–106) calls `complete` bare, so a
  `ContextWindowExceeded` kills the run and long trajectories overflow terminally,
  unlike ReAct. `runAction` (lines 110–117) builds the sandbox observation with
  `either id id r` — an interpreter *error* is indistinguishable from ordinary
  *output* in the observation text (ReAct, by contrast, prefixes tool failures
  with `Error: …` via `renderToolError`). `codeActGuide` (lines 192–198) documents
  the restricted language for the model.
- `shikumi-tools/src/Shikumi/CodeExec/Interpreter.hs` — the hermetic restricted
  DSL. The tokenizer's string case (lines 145–149) does `break (== '"')` — no
  escape sequences, so `"a\"b"` is a parse error. `parseFactor` (lines 220–231)
  has no unary-minus production, so `-3` is "expected an expression". The module
  doc's grammar section (lines 30–37) is the "advertised grammar" this plan makes
  truthful. (The SECURITY POSTURE paragraph earlier in the same haddock belongs to
  EP-45 per the master plan — do not edit it here.)
- `shikumi-tools/src/Shikumi/CodeExec/ProgramOfThought.hs` — the write-code-run-it
  program. `potLoop` (lines 75–89) throws
  `ProviderFailure ("programOfThought: code failed after N attempts: …")` (lines
  84–88) when attempts are exhausted — but no provider failed; the model's code
  did. `dslGuide` (lines 120–126) is its language description.
- `shikumi/src/Shikumi/Error.hs` — `ShikumiError` (lines 22–39), the framework's
  single error vocabulary (eight constructors today); `isTransient` (lines 62–66)
  classifies retryability with explicit `True` arms and a wildcard `False`.
- `shikumi-tools/src/Shikumi/Tool.hs` — `shikumiErrorText` (lines 218–228, moved
  slightly by EP-44) pattern-matches every `ShikumiError` constructor
  *exhaustively*; a new constructor will not compile without a new arm.
- Consumers of the trajectory data model that pattern-match `Action`:
  `renderTrajectory`/`renderAction` in ReAct.hs (lines 428–441),
  `shikumi-jitsurei/app/ReActAgent.hs` (`describe`, lines 89–90) and
  `shikumi-jitsurei/app/CodeExec.hs` (`describe`, lines 101–102) — both have
  exhaustive `CallTool`/`Finish` matches that need a `Summarized` arm.
- Tests: `shikumi-tools/test/CompactionSpec.hs` (loop-level compaction; its
  `isSummary` helper at line 178 currently sniffs the summary by its thought
  string), `ReActSpec.hs`, `ProtocolSpec.hs` (no multi-call or corrective-step
  coverage today), `CodeActSpec.hs`, `RestrictedSpec.hs` (pure DSL cases),
  `ProgramOfThoughtSpec.hs` (line 67 asserts the *wrong* `ProviderFailure` — it
  pins the bug), `shikumi/test/ErrorSpec.hs` (enumerates `isTransient` over every
  constructor), and `MockLLM.hs` (`mkToolCallResponse` builds a single-call
  response; you will add a multi-call builder).

Sequencing note from the master plan: this plan soft-depends on EP-44
(`docs/plans/44-tool-error-posture-infra-errors-escape-the-loop.md`). Land EP-44
first. Nothing here may add a `catchError` around `runToolCall` — the reactive
compaction handlers wrap only the loop's own `complete` calls, preserving EP-44's
guarantee that infra errors thrown by tool bodies abort the run.


## Plan of Work

### Milestone 1 — compaction honors `enabled`

Scope: `shikumi/src/Shikumi/Compaction.hs`, `shikumi-tools/src/Shikumi/Agent/ReAct.hs`,
CompactionSpec. At the end, `enabled = False` disables both proactive and reactive
compaction; a context overflow then propagates as an error instead of triggering a
summarization call.

In `Compaction.hs`, add a guard to `compactTail` (first line of the guards, before
`olderCount <= 0`): `| not (enabled cfg) = pure xs`, and say in its haddock that a
disabled config is the identity. In `ReAct.hs`, make both reactive handlers consult
the flag; in `completeProposeRecover` (lines 238–249) and the extract handler
(lines 227–234), change the `ContextWindowExceeded {}` match to a guarded one so a
disabled config rethrows instead of compacting:

```haskell
( \_cs -> \case
    e@(ContextWindowExceeded {})
      | not (compaction cfg ^. #enabled) -> throwError e
    ContextWindowExceeded {} -> do
      compacted <- forceCompactAcc acc
      let (ctx', opts') = renderPropose impl i (soFar compacted)
      (compacted,) <$> complete _Model ctx' opts'
    e -> throwError e
)
```

(the extract handler analogously with `forceCompactTrajectory`; `^. #enabled`
works through generic-lens labels already imported in the module — or import the
`enabled` selector from `Shikumi.Compaction`, either is fine).

Tests. In CompactionSpec add two cases: (i) "compactTail with enabled=False is the
identity and calls no model" — run `compactTail (defaultCompactionConfig { enabled
= False, keepRecent = 0 }) _Model render inject items` under `runEffMock []` with a
non-trivial `items` list and assert the output equals the input (before the fix,
the exhausted mock script returns an empty summary response and the output is a
single injected summary — observably different). (ii) "reactive compaction is
skipped when disabled" — copy the existing "overflow error is caught, compacted,
and retried once" case (line 97) but with `compaction = defaultCompactionConfig
{ enabled = False }` and assert the run returns
`Left (ContextWindowExceeded "context length exceeded")` after the *first* throw
(script it with `runMockLLMThrowingOn [1] …`; before the fix the loop would compact
and consume a second scripted response).

### Milestone 2 — an explicit `Summarized` action

Scope: `ReAct.hs`, the two jitsurei example apps, CompactionSpec. At the end, the
returned `Trajectory` marks compaction summaries structurally.

In `ReAct.hs`: add a third constructor to `Action` (lines 98–101):

```haskell
data Action
  = CallTool !Text !Value
  | Finish
  | -- | Injected by compaction: this step's observation carries a model-written
    -- summary of earlier steps that were folded away. Never produced by the
    -- model and never dispatched as a tool.
    Summarized
  deriving stock (Show, Eq, Generic)
```

Change `summaryStep` (lines 282–288) to `action = Summarized` (keep the human-
readable thought text — it renders into later prompts). Add a `renderAction`
arm in `renderTrajectory` (lines 428–441): `renderAction Summarized = "summary of
earlier steps"`. Update `reactWithTrajectory`'s haddock (lines 173–175) to say the
trajectory may contain `Summarized` steps when compaction ran, and update
`correctiveStep`'s haddock (lines 272–275) to state explicitly that the
`CallTool "" Null` sentinel is *only* used for corrective feedback and is
documented behavior. Fix the incomplete matches the new constructor exposes:
`describe` in `shikumi-jitsurei/app/ReActAgent.hs` (line 89) and
`shikumi-jitsurei/app/CodeExec.hs` (line 101) each gain
`describe Summarized = "summary"`. (`-Wall` makes these incomplete-pattern
warnings; treat any warning in touched modules as a must-fix.)

Tests: change CompactionSpec's `isSummary` (line 178) from sniffing the thought
string to `isSummary s = action s == Summarized` — the existing compaction cases
then *prove* the marker arrives in returned trajectories. Add an assertion in the
"agent on tiny window compacts and completes" case that no step has
`action == CallTool "" Null` (the old fake-call representation is gone from the
summary path).

### Milestone 3 — native multi-tool-call execution, plus corrective-step coverage

Scope: `ReAct.hs` protocol seam and loop, `MockLLM.hs`, ProtocolSpec/ReActSpec. At
the end, a native turn with N tool calls yields N executed steps in order.

Introduce a proposal type next to `ProtocolImpl` and change the seam's type
(`parsePropose :: Response -> Either Text (Text, Proposal)`):

```haskell
-- | What one model turn proposed: finish, or one-or-more tool calls to execute
-- in order before the next turn. The prompt protocol always proposes exactly
-- one call; the native protocol may propose several (parallel tool calls).
data Proposal = ProposeFinish | ProposeCalls !(NonEmpty (Text, Value))
```

(import `Data.List.NonEmpty (NonEmpty (..))` and `Data.List.NonEmpty qualified as
NE`; export `Proposal (..)` alongside `ProtocolImpl`). The prompt implementation
maps its parsed single action (`Finish -> ProposeFinish`; `CallTool nm args ->
ProposeCalls ((nm, args) :| [])`). The native implementation (lines 388–392)
becomes total over the call list:

```haskell
parsePropose = \resp ->
  case toolCallsOf resp of
    [] -> Right (responseText resp, ProposeFinish)
    (tc : tcs) ->
      Right
        ( responseText resp,
          ProposeCalls (fmap (\c -> (c ^. #name, c ^. #arguments)) (tc :| tcs))
        )
```

In the loop (lines 203–218), the `Right (th, CallTool nm args)` branch becomes a
`Right (th, ProposeCalls calls)` branch that folds over `NE.toList calls`
executing each with `runToolCall` and consing one `Step` per call (thought `th` on
the first, `""` on the rest), then runs the existing `compactAcc` once on the
combined accumulator and recurses; `Right (th, ProposeFinish)` behaves as the old
`Finish` branch. The iteration counter still advances by one per model *turn* (not
per call) — document that in the loop comment.

In `MockLLM.hs`, add and export a multi-call response builder:

```haskell
-- | An assistant 'Response' carrying several native tool-call blocks in order.
mkToolCallsResponse :: [(Text, Text, Value)] -> Response
mkToolCallsResponse calls =
  _Response
    & #message . #content
      .~ V.fromList
        [ AssistantToolCall (_ToolCall & #id_ .~ cid & #name .~ nm & #arguments .~ args)
        | (cid, nm, args) <- calls
        ]
```

Tests. ProtocolSpec: "native turn with two tool calls executes both in order" —
script `[mkToolCallsResponse [("c1","get_weather",argsParis),("c2","get_weather",argsLondon)], mkTextResponse "done", mkTextResponse extractReply]`
against `reactWithTrajectory weatherSignature weatherRegistry (defaultReActConfig
& #protocol .~ ProtocolNative)`; assert the trajectory has three steps — two
`CallTool "get_weather" _` steps whose recorded args are Paris then London, each
with an observation, then `Finish` — and the typed answer extracts. Before the
fix this yields only two steps (London dropped): the failing-before evidence.
ReActSpec: "an unparseable reply produces a corrective step and the loop recovers"
— script `[mkTextResponse "this is not json", …promptScript]` with default config;
assert `Right (o, traj)`, `o` is `expectedWeather`, and `traj` contains a step
whose observation contains `"not a valid action JSON object"` (this is new
coverage of an existing path; it must pass both before and after this milestone —
if the `Proposal` refactor breaks it, the refactor is wrong).

### Milestone 4 — CodeAct: tagged errors and compaction

Scope: `CodeAct.hs`, `ReAct.hs` exports, CodeActSpec. At the end, CodeAct
observations mark failures and CodeAct survives context overflow exactly like
ReAct.

Error tagging: in `runAction` (line 117) replace `either id id r` with
`either ("Error: code failed: " <>) id r`, mirroring ReAct's `Error: …`
observation convention from `renderToolError`.

Compaction wiring: add `compaction :: !CompactionConfig` to `CodeActConfig` (lines
52–59) with `defaultCodeActConfig` using `defaultCompactionConfig`. Export
`summaryStep` and `renderStepLine` from `ReAct.hs` (add to the "Rendering" export
group with haddocks — they are already top-level definitions) so CodeAct reuses the
identical summary-step representation (`Summarized` from M2) rather than inventing
one. In `codeActLoop`: (a) replace the bare `complete _Model ctx opts` (line 98)
with a `completeTurnRecover` clone of ReAct's `completeProposeRecover` — catch
`ContextWindowExceeded`, and if `compaction cfg ^. #enabled`, compact the
accumulator with `compactTail (compaction cfg) _Model renderStepLine summaryStep`
(remember the accumulator is newest-first: reverse before and after, exactly as
ReAct's `forceCompactAcc` at lines 256–258 does) and retry once, otherwise
rethrow; (b) after a successful non-finish step, run the proactive check — if
`usageExceedsWindow (compaction cfg) (resp ^. #model) (resp ^. #message . #usage)`
then force-compact the accumulator before recursing (import `usageExceedsWindow`,
`compactTail`, `CompactionConfig`, `defaultCompactionConfig` from
`Shikumi.Compaction`); (c) give `extract` the same reactive recovery over the
rendered trajectory (compact `steps traj` and retry once), mirroring ReAct's
extract handler. Note `CodeActConfig` has callers constructing it positionally?
No — only `defaultCodeActConfig` in-tree constructs it; CodeActSpec uses
`defaultCodeActConfig`, so the new field is source-compatible for the suite.

Tests (CodeActSpec): (i) "an interpreter error observation is tagged" — script a
turn whose code is `1 / 0` (not `finished`), then a finishing turn, then extract;
assert the first step's observation is `Just t` with `"Error: code failed:"` a
prefix of `t` and `"division"` an infix (before the fix the observation is exactly
`division by zero`, so the prefix assertion fails). (ii) "codeAct compacts on
context overflow and completes" — mirror CompactionSpec's "overflow error is
caught, compacted, and retried once" shape: tiny `contextWindow` model,
`runMockLLMThrowingOn [2] (ContextWindowExceeded …)` around a script of turn /
summary / turn(finished) / extract responses; assert success and that the
trajectory contains a `Summarized` step. Before the fix the run is
`Left (ContextWindowExceeded …)`. (iii) "codeAct with compaction disabled
propagates overflow" — same script, `compaction = defaultCompactionConfig
{ enabled = False }`, assert `Left (ContextWindowExceeded …)` — pins the M1 flag
in the new wiring.

### Milestone 5 — DSL: unary minus and string escapes

Scope: `Interpreter.hs` tokenizer/parser and module grammar doc, `dslGuide`
(ProgramOfThought.hs lines 120–126), `codeActGuide` (CodeAct.hs lines 192–198),
RestrictedSpec.

Parser: add a unary-minus production to `parseFactor` (insert before the catch-all
at line 231):

```haskell
parseFactor (TMinus : ts) = do
  (e, ts') <- parseFactor ts
  Right (EBin Sub (ENum 0) e, ts')
```

Desugaring to `0 - e` reuses the evaluator unchanged and gives factor-level
binding: `-2 * 3 == -6`, `2 * -3 == -6`, `-(2 + 3) == -5`, and `- -3 == 3`.

Tokenizer: replace the string case (lines 145–149) with an escape-aware scanner:

```haskell
| c == '"' = lexString cs []
```

with a local helper alongside `go`:

```haskell
lexString [] _ = Left "unterminated string literal"
lexString ('"' : rest) acc = (TStr (T.pack (reverse acc)) :) <$> go rest
lexString ('\\' : e : rest) acc = case e of
  '"' -> lexString rest ('"' : acc)
  '\\' -> lexString rest ('\\' : acc)
  'n' -> lexString rest ('\n' : acc)
  't' -> lexString rest ('\t' : acc)
  _ -> Left ("unsupported string escape: \\" <> T.singleton e)
lexString ('\\' : []) _ = Left "unterminated string literal"
lexString (ch : rest) acc = lexString rest (ch : acc)
```

Docs: extend the module haddock's "The restricted DSL" section (lines 30–37) with
unary minus and the four escapes (only this section — the security paragraph is
EP-45's). Update `dslGuide` and `codeActGuide` to advertise the same: e.g.
"…integer/rational arithmetic (+ - * /, unary minus) with parentheses, string
literals (escapes: \\\" \\\\ \\n \\t) with ++ …".

Tests (RestrictedSpec): `runRestricted "-3 + 5"` is `Right "2"`;
`runRestricted "2 * -3"` is `Right "-6"`; `runRestricted "-(2 + 3)"` is
`Right "-5"`; `runRestricted "len(\"a\\\"b\")"` is `Right "3"` (Haskell-source
escaping: the DSL sees `len("a\"b")`); `runRestricted "\"a\" ++ \"\\n\""` renders a
two-character string; an unsupported escape like `"\q"` is a `Left` mentioning
"escape". The first three fail before the change with "expected an expression";
the string ones fail with token errors.

### Milestone 6 — honest programOfThought failure: `CodeExecFailed`

Scope: `shikumi/src/Shikumi/Error.hs`, `shikumi/test/ErrorSpec.hs`,
`shikumi-tools/src/Shikumi/Tool.hs`, `ProgramOfThought.hs`,
ProgramOfThoughtSpec. This is the cross-package milestone; see the Decision Log
entry for the PVP note.

In `Error.hs` append a ninth constructor to `ShikumiError` (after
`BudgetExceeded`):

```haskell
  | -- | model-emitted code failed in the sandbox after all attempts
    CodeExecFailed !Text
```

and extend `isTransient`'s haddock to note code-execution failure is
deterministic (the wildcard already returns `False`; make the doc say so). In
`shikumi-tools/src/Shikumi/Tool.hs`, `shikumiErrorText` is an exhaustive case and
will fail to compile — add `CodeExecFailed t -> t`. Confirm (comment, not code)
that EP-44's `isInfraToolError` wildcard classifies `CodeExecFailed` recoverable —
intended, per the Decision Log. In `ProgramOfThought.hs` (lines 84–88) replace
`ProviderFailure` with `CodeExecFailed` (message text unchanged). Sweep for other
exhaustive matches: `grep -rn "ShikumiError" --include='*.hs' | grep -v
dist-newstyle` and check each `case`/`\case` over the type — as of this writing
the only exhaustive value-level match is `shikumiErrorText`; `isTransient` and
`Shikumi.Error.fromBaikaiError` use wildcards/construction only.

Tests: in `shikumi/test/ErrorSpec.hs` extend the "isTransient classification" case
with `isTransient (CodeExecFailed "") @?= False`. In
`shikumi-tools/test/ProgramOfThoughtSpec.hs` (lines 67–68) change the expected
error from `Left (ProviderFailure _)` to `Left (CodeExecFailed _)` — this test
currently pins the bug and will fail the moment the constructor lands, which is
the desired failing-before/passing-after evidence.


## Concrete Steps

All commands from the repo root, inside the dev shell:

```bash
nix develop .#ghc9124
cabal build shikumi-tools          # after M1–M5 edits
cabal build all                    # after M6 (core package changed)
just test-one shikumi-tools
just test-one shikumi              # ErrorSpec lives here (M6)
```

Because M6 changes the core package, expect `cabal build all` to recompile
dependents (`shikumi-cache*`, `shikumi-eval`, `shikumi-cli`, …); none of them
pattern-match `ShikumiError` exhaustively (verified by the grep in M6), so only
recompilation, not edits, is expected — if any package fails to compile on the new
constructor, add the missing arm and record it in Surprises & Discoveries.

Suggested commits (Conventional Commits; one per milestone or grouped M1+M2), each
with the mandatory trailers:

```text
fix(agent): honor compaction enabled flag on reactive paths

MasterPlan: docs/masterplans/8-tools-agents-and-cli-hardening.md
ExecPlan: docs/plans/46-react-and-codeact-behavior-fixes.md
Intention: intention_01kwgdyxm7ehh8yys1pp4wf1zr
```

```text
feat(agent): explicit Summarized trajectory action; execute all native tool calls
```

```text
feat(codeact): tag interpreter errors and wire context compaction
```

```text
feat(interpreter): unary minus and string escapes in the restricted DSL
```

```text
feat(error)!: add CodeExecFailed; programOfThought reports code failure honestly
```

(The `!` marks the PVP-breaking core change. Every commit carries `MasterPlan:
docs/masterplans/8-tools-agents-and-cli-hardening.md`, `ExecPlan:
docs/plans/46-react-and-codeact-behavior-fixes.md`, and `Intention:
intention_01kwgdyxm7ehh8yys1pp4wf1zr` trailers.)


## Validation and Acceptance

Run `just test-one shikumi-tools` and `just test-one shikumi`. Acceptance, per
milestone, phrased as observable behavior:

1. With `enabled = False`, a scripted `ContextWindowExceeded` on the first
   completion surfaces as `Left (ContextWindowExceeded …)` and the mock consumes
   exactly one response; with the fix stashed, the loop instead issues a summary
   completion (test fails on consumed-count/shape).
2. Compaction cases in CompactionSpec find their summary via
   `action == Summarized`; no summary step carries `CallTool "" Null`.
3. The two-call native script produces a trajectory of Paris-step, London-step,
   Finish — before the fix the London step is absent. The corrective-step case
   returns the typed answer with the corrective observation recorded.
4. CodeAct: `1 / 0` yields an observation prefixed `Error: code failed:`; the
   overflow script completes with a `Summarized` step where before it returned
   `Left (ContextWindowExceeded …)`; disabled compaction propagates the error.
5. `runRestricted "-3 + 5" == Right "2"` (and friends) — before: `Left "expected
   an expression"`; escaped-string cases parse.
6. `programOfThought` with an always-failing interpreter returns
   `Left (CodeExecFailed …)`; ErrorSpec pins `isTransient (CodeExecFailed "") ==
   False`. `cabal build all` is green.


## Idempotence and Recovery

All edits are additive or local; re-running builds/tests is always safe. The
riskiest step is M6 (core constructor): if an unexpected downstream package fails
to compile, either add the missing case arm (record it) or revert just the M6
commit — M1–M5 do not depend on it. M3 changes the exported `ProtocolImpl` seam
type; `resolveProtocol`'s two implementations are the only in-repo constructors
(verify with `grep -rn "ProtocolImpl" --include='*.hs' | grep -v dist-newstyle`),
so external breakage is limited to that named seam and is intentional. If a
milestone must be abandoned mid-way, `git stash`/commit granularity per milestone
keeps the tree releasable.


## Interfaces and Dependencies

No new package dependencies anywhere (NonEmpty is `base`). End-state interfaces:

- `Shikumi.Agent.ReAct` (shikumi-tools): `data Action = CallTool !Text !Value |
  Finish | Summarized`; `data Proposal = ProposeFinish | ProposeCalls !(NonEmpty
  (Text, Value))` (exported); `ProtocolImpl.parsePropose :: Response -> Either
  Text (Text, Proposal)`; newly exported `summaryStep :: Text -> Step` and
  `renderStepLine :: Step -> Text`.
- `Shikumi.CodeExec.CodeAct`: `CodeActConfig { maxIters :: !Int, interpreter ::
  !CodeInterpreter, compaction :: !CompactionConfig }`.
- `Shikumi.Compaction` (shikumi core): `compactTail` returns its input unchanged
  when `enabled` is `False` (signature unchanged).
- `Shikumi.Error` (shikumi core): `ShikumiError` gains `CodeExecFailed !Text`;
  `isTransient (CodeExecFailed _) == False`.
- `Shikumi.CodeExec.Interpreter`: `runRestricted` accepts unary minus and the four
  string escapes (signature unchanged).
- Test helpers: `MockLLM.mkToolCallsResponse :: [(Text, Text, Value)] -> Response`.

Cross-plan coordination (master plan Integration Points): EP-44 must land first
(shared `ReAct.hs`/`Tool.hs` surfaces; this plan adds the `shikumiErrorText` arm
EP-44's rewrite surrounds). EP-45 owns Interpreter.hs's security paragraph; this
plan edits only the grammar section and code of that file.
