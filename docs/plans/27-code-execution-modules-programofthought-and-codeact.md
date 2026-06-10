---
id: 27
slug: code-execution-modules-programofthought-and-codeact
title: "Code-execution modules ProgramOfThought and CodeAct"
kind: exec-plan
created_at: 2026-06-09T22:35:42Z
intention: "intention_01ktq812wfebgvf1dtbvg3v826"
master_plan: "docs/masterplans/4-shikumi-richer-io-and-multimodal.md"
---

# Code-execution modules ProgramOfThought and CodeAct

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

This is the **optional stretch plan** of the "Shikumi Richer IO and Multimodal" MasterPlan
(`docs/masterplans/4-shikumi-richer-io-and-multimodal.md`). It is ordered last, has **no
hard dependencies**, and **nothing depends on it**. The three parity plans of that MasterPlan
— multimodal field types (`docs/plans/24-multimodal-field-types.md`), program-level streaming
(`docs/plans/25-program-level-streaming-and-status-messages.md`), and adapter completeness plus
field constraints (`docs/plans/26-adapter-completeness-and-declarative-field-constraints.md`)
— stand entirely on their own and ship regardless of whether this plan is ever picked up. If
you are deciding what to work on and you are not specifically here for code execution, work on
those first.

After this change a Shikumi user can build two new kinds of program where **the model writes
code, the code runs in a sandbox, and the result flows back into the answer**:

- `programOfThought sig` — a `Program i o` that asks the model to emit a snippet of code that
  *computes* the answer (instead of asking the model to guess the answer directly), runs that
  snippet in a sandboxed interpreter, and — if the snippet errors — feeds the error message
  back to the model so it can fix the code, up to a bounded number of attempts, before
  extracting the typed answer `o` from the successful run's output.
- `codeAct sig reg` — a `Program i o` that combines code generation with tool calling: the
  model emits code snippets that may call a set of caller-provided functions (the tools), the
  snippets run in the sandbox turn-by-turn (a ReAct-style loop where each *action* is a code
  snippet rather than a single tool call), accumulating a trajectory of code and outputs, until
  the model declares it is finished and the typed answer is extracted.

You can see it working without any network and without any external interpreter binary: a test
asks `programOfThought` to compute an arithmetic/string result that a plain `predict` gets
wrong, and asserts (a) that the emitted code actually ran in the sandbox and (b) that the typed
answer is correct; a second test scripts a first code snippet that *errors* and a second that
*succeeds*, proving the error-then-fix feedback loop. Both run under a **hermetic** (no external
process, no network, fully in-process) restricted interpreter so the acceptance is reproducible
on CI.

**Why this is the riskiest, least-aligned item.** Shikumi's value proposition is *typed* LM
programming: every input and output is a typed record with a derived schema. "Run arbitrary
model-emitted code" is the opposite — it is dynamically typed, and the hard part is not the
algorithm (the algorithm is a small loop, almost identical to the existing ReAct loop in
`shikumi-tools/src/Shikumi/Agent/ReAct.hs`) but the **sandbox**: safely executing code a
language model wrote is a Haskell-and-environment problem with a real security surface. This
plan treats the sandbox as the central risk, surveys the realistic options honestly, recommends
a primary and a hermetic fallback, and scopes the dangerous part (a real subprocess interpreter)
as a clearly-gated, non-CI milestone (M4) that the parity items never wait on.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1: `CodeInterpreter` value type + hermetic restricted interpreter (`restrictedInterpreter`) + `echoInterpreter`; security write-up in module Haddock and this plan. (`scriptedInterpreter` deliberately dropped — see Decision Log: a stateful interpreter in the pure `Embed` row would need `unsafePerformIO`; the hermetic `restrictedInterpreter` already produces real error-then-success behavior, so it is unnecessary.)
- [x] M1: `shikumi-tools` cabal updated; module `Shikumi.CodeExec.Interpreter` compiles; `RestrictedSpec` (10 cases) for the restricted evaluator passes under `cabal test shikumi-tools`.
- [x] M2: `programOfThought` / `programOfThoughtWith` as an `Embed` node (predict code → run via the captured interpreter → on error feed back up to `maxIters` → extract typed answer). Module `Shikumi.CodeExec.ProgramOfThought`.
- [x] M2: Acceptance test (`ProgramOfThoughtSpec`) — `programOfThought` solves a fixture task end-to-end; the sandbox is proven load-bearing (an always-fail interpreter makes it give up, and an error-then-fix run only succeeds because the interpreter really rejected `1 / 0`); plus a plain-`predict` wrong-guess baseline.
- [x] M3: `codeAct` / `codeActWithTrajectory` as an `Embed` node combining code + tool calls, reusing the ReAct trajectory data model. Module `Shikumi.CodeExec.CodeAct`.
- [x] M3: Acceptance test (`CodeActSpec`) — a scripted `codeAct` run calls a provided tool (`addOne`) from within a `call("addOne", …)` snippet, accumulates a two-step `Trajectory`, finishes, and extracts the typed answer.
- [ ] M4 (gated, non-CI): real subprocess interpreter (`subprocessInterpreter`) behind an `IOE`-bearing entry point. **Not implemented** — explicitly optional even within this optional plan; the parity behavior in the Purpose ships on M1–M3 under the hermetic interpreter. (Deferred; not part of the accept gate.)
- [x] Confirm parameter-count invariant: each new node is an `Embed` (`codeAct` is `FMap fst (Embed …)`), carries no `Params`; `ProgramOfThoughtSpec` asserts `null (foldParams (programOfThought sig))`. No optimizer/compiler/serialization code changed.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **A stateful `scriptedInterpreter`/recording interpreter cannot be written without
  `unsafePerformIO`, so it was dropped.** `CodeInterpreter.runCode` is rank-2 over
  the exact `Embed` row `(LLM, Error ShikumiError)` — no `IOE`. Reading/popping an
  `IORef` inside `runCode` is therefore impossible by the type, and the only escape
  (`unsafePerformIO` on a non-input-dependent pop) is unsafe under GHC's float/CSE.
  The hermetic `restrictedInterpreter` is /pure/ and already produces real
  error-then-success behavior (`1 / 0` → `Left "division by zero"`, then `6` →
  `Right "6"`), so loop-shape tests use it directly. To prove the interpreter is
  *load-bearing* without recording, the spec uses a pure always-fail interpreter
  (`CodeInterpreter (\_ -> pure (Left …))`): with it the program gives up
  (`ProviderFailure`), with the restricted one the same code succeeds — bracketing
  the interpreter's verdict as the deciding factor. This is a cleaner proof than
  input-recording and needs no unsafe code.
- **The plan's worked example was internally inconsistent (`37 * 19 + 6 = 703`).**
  `37 * 19` is already `703`, so `37 * 19 + 6 = 709`. The restricted evaluator
  correctly returns `709`; the fixtures were corrected from the plan's stated `703`
  to the true `709`. (Evidence: `RestrictedSpec` `37 * 19 + 6 evaluates to 709: OK`.)
- **`responseText` is reused from `Shikumi.Adapter`, not re-copied from ReAct.** EP-26
  exported `Shikumi.Adapter.responseText`; the code-execution modules import it
  rather than duplicating ReAct's private copy. Only `stripFences` and the one-turn
  context/encode helpers were factored into the new `Shikumi.CodeExec.Prompt`.
- **`codeAct`'s tool dispatch uses a `call("name", args)` protocol convention, parsed
  by wrapping the inner text in `[...]` and JSON-decoding to `[String name, args]`.**
  This keeps the hermetic pure DSL free of any foreign-function interface while still
  routing tool use through the typed `runToolCall`; a snippet that is not a `call(…)`
  is handed to the sandbox. (Evidence: `CodeActSpec` step 1 observation is the
  `addOne` result `"42"`, step 2 runs `result = 42` in the sandbox.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Build `programOfThought` and `codeAct` as `Embed` nodes (not new `Program`
  constructors), exactly as `react` is built today.
  Rationale: MasterPlan integration point #5 ("the `Program` GADT extension rule") says a new
  constructor is a compile error until `paramsTraversal`, `programShape`, and
  `setProgramParams` pattern-match it, and *prefers* an `Embed` node so the parameter-count
  invariant (count == number of `Predict` nodes) holds and the V1 compilers/serialization pass
  it through unchanged. An `Embed` carries no `Params` (like `FMap`), so no optimizer/compiler
  code changes.
  Date: 2026-06-09.

- Decision: Model the sandbox as a **plain value** (`CodeInterpreter`) captured in the Embed
  closure, **not** as an effectful row member (`CodeInterpreter :> es`).
  Rationale: the `Embed` constructor fixes its body's row to *exactly* `(LLM :> es, Error
  ShikumiError :> es)` (see `shikumi/src/Shikumi/Program.hs` line 199). Adding a new effect to
  that row is impossible without changing the GADT — which we explicitly will not do. Capturing
  the interpreter as a value is precisely how `react` captures its `ToolRegistry`. The hermetic
  interpreter is *pure*, so its run function needs no effects and fits inside any row; the
  subprocess interpreter needs `IOE`, which the Embed row lacks, so it is offered only through a
  separate `IOE`-bearing entry point (M4), kept out of the composable GADT path.
  Date: 2026-06-09.

- Decision: Ship a hermetic restricted in-process interpreter as the default for tests/CI, and
  specify a real `python3`/`deno` subprocess interpreter as a gated, non-CI M4.
  Rationale: running model-emitted code is dangerous and a subprocess interpreter is
  non-hermetic (needs a binary) and a security surface; the MasterPlan and this plan's
  acceptance must run offline. A swappable `CodeInterpreter` value gives us both with one type.
  Date: 2026-06-09.

- Decision: Drop `scriptedInterpreter`/recording interpreters from the shipped surface; keep
  only the /pure/ `restrictedInterpreter` and `echoInterpreter`, and prove the interpreter is
  load-bearing with a pure always-fail interpreter contrast plus the real error-then-fix path.
  Rationale: `CodeInterpreter.runCode` is rank-2 over `(LLM, Error ShikumiError)` (no `IOE`),
  so any state (popping a script, recording inputs) inside `runCode` would require
  `unsafePerformIO`, which is unsafe under GHC float/CSE for a non-input-dependent effect. The
  hermetic `restrictedInterpreter` already exhibits real error-then-success behavior, so the
  loop-shape and load-bearing tests need no scripted/recording interpreter. This deviates from
  the plan's listed `scriptedInterpreter` API but removes an unsafe construct; the acceptance
  facts are all still demonstrated.
  Date: 2026-06-09.

- Decision: Do not implement M4 (the real subprocess interpreter) in this pass.
  Rationale: M4 is explicitly optional even within this optional plan, is non-hermetic and
  excluded from CI, and carries the real RCE security surface. All user-visible parity behavior
  in the Purpose ships under the hermetic interpreter (M1–M3). M4 remains specified (Plan of
  Work + SECURITY POSTURE) for a future, deliberately-gated pass.
  Date: 2026-06-09.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

**Delivered (2026-06-09).** M1–M3 complete; M4 deferred by design. `cabal test
shikumi-tools` green (29 tests, +13: 10 `RestrictedSpec`, 5 `ProgramOfThoughtSpec`,
1 `CodeActSpec` — note the spec counts differ slightly from the illustrative
transcript) and `cabal test all` green. Against the Purpose:

- **`programOfThought sig`** is an ordinary `Program i o` (a single `Embed` node)
  that asks the model for code, runs it in a sandbox, feeds errors back up to
  `maxIters`, and extracts the typed answer. `codeAct sig reg` is a `Program i o`
  (`FMap fst (Embed …)`) whose each action is a code snippet that may call provided
  tools via a `call("name", args)` convention, accumulating a reused
  `Shikumi.Agent.ReAct.Trajectory`.
- **The sandbox is a swappable value, hermetic by default.** `CodeInterpreter` is a
  rank-2 value captured in the `Embed` closure (never an effect-row member, since the
  `Embed` body is fixed to `(LLM, Error ShikumiError)`), exactly as `react` captures
  its `ToolRegistry`. `restrictedInterpreter` evaluates a tiny arithmetic/string/list
  DSL purely — no syscalls, no network, no filesystem, a step cap — so the whole
  acceptance runs offline with no external interpreter.
- **The code path is proven load-bearing, not incidental.** Beyond the end-to-end
  solve, an always-fail interpreter makes `programOfThought` give up (the loop
  consults the interpreter's verdict), and an error-then-fix run reaches the answer
  only because the interpreter really rejected `1 / 0` and accepted the correction.
- **The parameter-count invariant holds with zero compiler/optimizer changes.**
  `foldParams (programOfThought sig) == []` is asserted; `Embed`/`FMap` carry no
  `Params`, so `programShape`/`setProgramParams`/`encodeCompiled` pass these nodes
  through unchanged, exactly as for `react`.

**Gaps / deferred:**

- **M4 (real subprocess interpreter) is not implemented** — optional and off-CI by
  design; the SECURITY POSTURE and milestone spec remain for a future gated pass.
- The hermetic DSL is deliberately tiny (arithmetic, strings, small list ops); it is
  enough to *demonstrate the loop* (the plan's stated goal), not to run arbitrary
  computation. A real subprocess interpreter (M4) would lift that ceiling.
- `scriptedInterpreter` was dropped (would need `unsafePerformIO` in the pure `Embed`
  row); see Decision Log.

**Lessons.** The rank-2 `(LLM, Error)` row that makes `Embed` composable is exactly
what forbids stateful/IO interpreters inside it — the pure-value sandbox design
follows directly, and proving "the code ran" is cleanest via control-flow contrast
(always-fail vs. real) rather than recording. The plan's worked arithmetic example
was internally inconsistent (`37*19+6` is `709`, not `703`); the fixtures use the
true value.


## Context and Orientation

This section assumes you know nothing about this repository. Read it fully before editing.

### What Shikumi is, in one paragraph

Shikumi is a Haskell framework for *typed* language-model programming. A program is a value of
the GADT `Program i o` defined in `shikumi/src/Shikumi/Program.hs`: a tree of constructors that
can be *run* (interpreted as an `Eff` computation that issues LLM calls and returns a typed
output `o`), *rewritten as data* (an optimizer reads and replaces each node's tunable
parameters), and *serialized* (the parameter vector is saved as JSON). The whole project is a
Cabal multi-package build; this plan lives in the `shikumi-tools` package
(`shikumi-tools/shikumi-tools.cabal`), the same package that already hosts the ReAct agent,
because the code-execution loop is structurally the ReAct loop with "run code" where ReAct has
"call a tool".

### The exact pieces you will build on (copied from current source)

These signatures are current as of this plan's authoring. Re-read the named files before
editing; if a signature has drifted, update this plan.

**The `Program` GADT and the `Embed` constructor** (`shikumi/src/Shikumi/Program.hs`). The
constructor you will use is:

```haskell
-- shikumi/src/Shikumi/Program.hs, line 199
Embed :: (forall es. (LLM :> es, Error ShikumiError :> es) => i -> Eff es o) -> Program i o
```

and its smart constructor:

```haskell
-- shikumi/src/Shikumi/Program.hs, lines 211-212
embed :: (forall es. (LLM :> es, Error ShikumiError :> es) => i -> Eff es o) -> Program i o
embed = Embed
```

The Embed body is **rank-2** and constrained to *exactly* the row `(LLM :> es, Error
ShikumiError :> es)`. You cannot add any other effect (no `IOE`, no new `CodeInterpreter`
effect) to that body without changing the GADT. This single fact shapes the whole design: the
sandbox is passed as a **value** captured in the closure, never as a row member. (See the
Decision Log.)

`Embed` carries no `Params`. The module Haddock at the top of `Shikumi.Program` and the
constructor comment (lines 191-199) state this explicitly: an `Embed` node "carries no
`Params`, like `FMap`", is structurally inspectable as `ShapeEmbed`, and is opaque to the
parameter traversal. The serialization/compiler contract is therefore: `foldParams`,
`programParams`, `programShape`, `setProgramParams`, and `encodeCompiled`/`decodeCompiledOnto`
already handle `Embed` and need **no changes**. The parameter count of a program equals the
number of `Predict` nodes only; an all-`Embed` program folds to the empty parameter list. A
test in this plan asserts exactly that.

**How a node issues an LLM call.** Inside the Embed body you make model calls with `complete`
from `Shikumi.LLM`:

```haskell
-- shikumi/src/Shikumi/LLM.hs
complete :: (LLM :> es) => Model -> Context -> Options -> Eff es Response
```

and you can build a typed sub-call by reusing the `predict` machinery, or — exactly as ReAct
does — by rendering a `Context`/`Options` yourself and parsing the `Response` text. ReAct uses
the lower-level path; for `programOfThought`/`codeAct` you will do the same so the code-emitting
prompt is fully under your control.

**The neutral model.** Shikumi dispatches every node against a single provider-neutral model
`_Model` (from `Baikai`, re-exported); the *baikai registry*, not the program, selects a real
provider. `react` uses `_Model` directly (`shikumi-tools/src/Shikumi/Agent/ReAct.hs`, e.g. line
192/201). Do the same.

**The error type** (`shikumi/src/Shikumi/Error.hs`). The typed error channel:

```haskell
data ShikumiError
  = InvalidJSON !Text
  | MissingField !Text
  | SchemaMismatch !Text
  | ValidationFailure !Text
  | ProviderFailure !Text
  | Timeout !Text
  | BudgetExceeded !Text
```

You will throw `ProviderFailure` for "the sandbox could not run the code at all after all
retries" and `InvalidJSON`/`SchemaMismatch` (via the existing `parseOutput`) when the final
extracted answer does not decode. Use `throwError` from `Effectful.Error.Static`.

**The schema/parse helpers** (`shikumi/src/Shikumi/Schema.hs`, `Shikumi/Adapter.hs`). For
turning the final code output into a typed `o` you reuse:

```haskell
parseOutput :: forall a. (FromModel a, Validatable a) => Text -> Either ShikumiError a
toSchema    :: ToSchema a => Proxy a -> Value
class ToPrompt a where toPrompt :: a -> Text   -- renders the input record into prompt text
```

These are exactly the helpers ReAct uses (`shikumi-tools/src/Shikumi/Agent/ReAct.hs` imports
`parseOutput`, `toSchema`, `toPrompt`).

**The ReAct agent — your closest template** (`shikumi-tools/src/Shikumi/Agent/ReAct.hs`). Read
this file in full; `codeAct` reuses its data model and `programOfThought` mirrors its loop
shape. The relevant current signatures (verify against the file — note the dossier in
`/tmp/shikumi-followup/dossier.md` lists a slightly older shape; the *file* is authoritative):

```haskell
-- shikumi-tools/src/Shikumi/Agent/ReAct.hs
data Action = CallTool !Text !Value | Finish
data Step = Step { thought :: !Text, action :: !Action, observation :: !(Maybe Text) }
data Termination = TerminatedFinish | TerminatedMaxIters !Int | TerminatedBudget
data Trajectory = Trajectory { steps :: !(Vector Step), termination :: !Termination }

data ReActConfig = ReActConfig { maxIters :: !Int, protocol :: !ToolProtocol }
defaultReActConfig :: ReActConfig

react ::
  (ToPrompt i, ToSchema o, FromModel o, Validatable o) =>
  Signature i o -> ToolRegistry -> ReActConfig -> Program i o
react sig reg cfg = FMap fst (reactWithTrajectory sig reg cfg)

reactWithTrajectory ::
  (ToPrompt i, ToSchema o, FromModel o, Validatable o) =>
  Signature i o -> ToolRegistry -> ReActConfig -> Program i (o, Trajectory)
reactWithTrajectory sig reg cfg = embed (reactLoop sig reg cfg)

renderTrajectory :: Trajectory -> Text
```

Notice the loop body `reactLoop :: (..., LLM :> es, Error ShikumiError :> es, ...) => Signature
i o -> ToolRegistry -> ReActConfig -> i -> Eff es (o, Trajectory)` is an ordinary function in
the Embed row, wrapped by `embed`. That is the entire pattern you replicate.

**Typed tools** (`shikumi-tools/src/Shikumi/Tool.hs`). For `codeAct` the provided functions are
the existing `ToolRegistry`/`SomeTool`. The dispatch entry point is:

```haskell
runToolCall :: (LLM :> es, Error ShikumiError :> es) => ToolRegistry -> ToolCall -> Eff es (Either ToolError Text)
registryTools :: ToolRegistry -> [SomeTool]
someToolName :: SomeTool -> Text
someToolDescription :: SomeTool -> Text
someToolSchema :: SomeTool -> Value
renderToolError :: ToolError -> Text
```

`codeAct` does not call a tool by emitting a `ToolCall` JSON object the way ReAct does; instead
the model's *code* names a tool, and the loop intercepts those names (see M3). But the registry,
the per-tool name/description/schema accessors, and `runToolCall` are reused so the wire-level
plumbing is shared.

**The test harness** (`shikumi-tools/test/MockLLM.hs`). All `shikumi-tools` tests run against a
deterministic, network-free `LLM` interpreter that pops scripted `Response`s in order. The
helpers you will reuse:

```haskell
runMockLLM    :: (IOE :> es) => [Response] -> Eff (LLM : es) a -> Eff es a
runEffMock    :: [Response] -> Eff '[LLM, Error ShikumiError, IOE] a -> IO (Either ShikumiError a)
runAgent      :: [Response] -> Program i o -> i -> IO (Either ShikumiError o)
mkTextResponse     :: Text -> Response
mkToolCallResponse :: Text -> Text -> Value -> Response
```

`runAgent script prog i = runEffMock script (runProgram prog i)`. Because `programOfThought` is
a `Program` whose interpreter is *pure* (the hermetic restricted interpreter does no IO), you
script the model's code-emitting replies as `mkTextResponse` values and run with `runAgent`,
asserting on the typed result. This is exactly how `ReActSpec`/`AcceptanceSpec` work today.

### Terms defined

- **Sandbox / interpreter.** A component that takes a string of code and returns either its
  textual output or an error string, with the security property that the code cannot reach the
  network, the host filesystem, or unbounded CPU/memory/time. In this plan it is the value type
  `CodeInterpreter`.
- **Hermetic.** Requires no external program and no network; runs entirely in-process so a test
  produces the same result on any machine with no setup. The restricted interpreter is hermetic;
  a `python3`/`deno` subprocess interpreter is *not*.
- **Embed node.** A `Program` constructor wrapping an opaque effectful step whose body runs in
  exactly the `(LLM, Error ShikumiError)` row and which carries no tunable parameters. Both
  modules in this plan are Embed nodes.
- **Trajectory.** The recorded sequence of (thought, action, observation) steps a multi-step
  loop produces, reused from `Shikumi.Agent.ReAct`.

### What DSPy does (in our own words), for fidelity

This plan mirrors two DSPy modules. We restate them precisely so the reader needs no external
reference.

**DSPy `ProgramOfThought`** (`/tmp/dspy/dspy/predict/program_of_thought.py`). It builds three
chain-of-thought sub-predictors: *generate* (given the task inputs, emit Python code that
computes the answer), *regenerate* (given the previous code and its error, emit corrected code),
and *answer* (given the final code and its captured output, emit the typed output fields). The
`forward` method: call *generate*; parse the code out of the reply (strip Markdown fences, take
the first block); execute it in a `PythonInterpreter`; if execution errored, loop calling
*regenerate* with the previous code and the error message, up to `max_iters`, re-executing each
time; once execution succeeds (or it gives up and raises), call *answer* with the final code and
its output to produce the typed result. The code is asked to call a preloaded `SUBMIT()` and to
shape its result as a dict mapping the output field names. The interpreter is a Deno/Pyodide
WASM sandbox (`/tmp/dspy/dspy/primitives/python_interpreter.py`): code runs in an isolated
Pyodide environment with **no host filesystem, network, or environment access by default**, the
sandbox is a `deno run` subprocess driven over JSON-RPC on stdin/stdout, read/write/env/net
permissions are *opt-in* via explicit `--allow-*` flags, and host-side "tools" are exposed to
the sandbox by name and called back over the same JSON-RPC channel.

**DSPy `CodeAct`** (`/tmp/dspy/dspy/predict/code_act.py`). It subclasses both `ReAct` and
`ProgramOfThought`: a ReAct-style loop in which each *action* is a Python code snippet. It is
given a list of plain functions (tools); their source is injected into the interpreter so the
snippets can call them by name. Each iteration: the model emits a code snippet plus a `finished`
boolean; the snippet is parsed and executed in the interpreter, its printed output (or its parse
/execution error) is appended to a growing `trajectory`; when `finished` is true (or `max_iters`
is hit) an *extract* step turns the trajectory into the typed output fields. The same Deno/WASM
sandbox is used, with the tool functions registered into it.

We do **not** port the Deno/Pyodide sandbox as the default. We port the *shape* of both loops
faithfully, behind a swappable `CodeInterpreter` value whose default implementation is a
hermetic restricted evaluator (so tests run offline), with a real subprocess interpreter offered
as the gated M4.

### The sandbox survey (the hard, honest part)

Executing code a language model emitted is dangerous: the code can try to read secrets, open
sockets, spawn processes, delete files, or spin forever. The realistic Haskell options, and our
verdict on each:

1. **Subprocess to an external interpreter** (`python3`, `deno`, or `node`) with OS-level
   resource limits — this is what DSPy does (a `deno run` subprocess). *Pros:* most faithful to
   DSPy; the model is *good* at writing Python/JS; mature sandboxes (Deno's permission flags,
   Pyodide's WASM isolation) exist. *Cons:* **non-hermetic** (requires the binary to be
   installed — confirmed absent from this repo's hermetic build) and a **real security surface**
   (you are running model code on the host). Verdict: this is the *recommended primary for real
   use*, specified as M4, **gated and never run on CI**, with an explicit security boundary (no
   network, isolated scratch temp dir, CPU/memory/wall-clock limits, no host FS access beyond a
   scratch dir).

2. **`hint` / the GHC API to evaluate Haskell** — let the model emit *Haskell* and interpret it
   in-process. *Pros:* in-process, no external binary, lets the answer be a real typed Haskell
   value. *Cons:* `hint` is **not available** in this repo (checked: `mori registry search hint`
   returns nothing on disk, and it is not a declared dependency); models are markedly *worse* at
   Haskell than at Python; and `hint`/GHC-API evaluation is **not sandboxed** — interpreted
   Haskell has full `IO`, so it is unsafe for untrusted code. Verdict: **rejected** as a default;
   noted as a future possibility only if a sandboxing story for interpreted Haskell appears.

3. **A tiny safe expression evaluator for a restricted DSL** — a from-scratch, in-process
   evaluator for a small arithmetic/string/list language with no I/O of any kind. *Pros:* fully
   sandboxed *by construction* (it has no syscalls to make), hermetic, deterministic, trivial to
   test, needs no external runtime. *Cons:* limited — it can only do what the DSL supports
   (integer/rational arithmetic, string concatenation/length/case, simple list operations, a
   handful of named functions), not arbitrary computation. Verdict: this is the **recommended
   hermetic fallback and the default**, used for the plan's acceptance and for CI. It is enough
   to *demonstrate the loop* — that the model emitted code, the code ran in a sandbox, an error
   fed back and was fixed, and the typed answer came out — which is exactly what the acceptance
   requires.

**Recommendation.** Make the interpreter a swappable value `CodeInterpreter` with at least two
implementations: a hermetic restricted evaluator (`restrictedInterpreter`, the default, used by
M1–M3 and all tests) and a real subprocess one (`subprocessInterpreter`, M4, gated/non-CI). The
hermetic one is pure and therefore usable *inside* an Embed node; the subprocess one needs
`IOE` and is offered only through a separate `IOE`-bearing entry point (it cannot live inside
the `(LLM, Error ShikumiError)` Embed body). Stub interpreters (`echoInterpreter`,
`scriptedInterpreter`) make the loops testable without even the restricted evaluator when a test
just wants to script outputs.

`mori` evidence gathered while writing this plan: `mori registry search hint` → *no projects*;
`mori registry search process` → `typed-process-effectful-extra` exists under the
`effectful/effectful` project (relevant only to the M4 subprocess path, and even then a plain
`System.Process`/`typed-process` call under `IOE` suffices). We did **not** search `/nix/store`
or `/`.

### SECURITY POSTURE — read this before implementing M4

Running model-emitted code is a genuine remote-code-execution risk. The hermetic default
(`restrictedInterpreter`) is safe by construction: it parses a tiny DSL and evaluates it purely;
there is no syscall it can make, no filesystem, no network, no unbounded loop primitive (the
evaluator imposes a step/expression-size cap and returns a typed error past it). The subprocess
interpreter of M4 is the dangerous one and **must** enforce, at minimum:

- **No network.** For `deno`, omit `--allow-net` entirely (default-deny). For `python3`, run
  with no network namespace where the OS allows it, or document that `python3` cannot be made
  network-tight without a container and prefer `deno` for that reason.
- **No host filesystem access beyond a single scratch dir.** Create a fresh temp directory per
  invocation, pass only that as the allowed read/write path (`--allow-read=<scratch>
  --allow-write=<scratch>` for deno), and delete it after. Never expose `$HOME`, the repo, or
  `/`.
- **No environment access.** Omit `--allow-env`; do not inherit secrets into the child.
- **CPU / memory / wall-clock limits.** Impose a wall-clock timeout (kill the subprocess on
  expiry, surfacing a `Timeout` `ShikumiError`); set memory/CPU rlimits where the platform
  supports them.
- **Loud failure.** Any limit breach or permission denial becomes a `ShikumiError`
  (`Timeout`/`ProviderFailure`), never a silent empty result.

M4 is **never** run on CI and is not required by any acceptance in this plan. Implement it only
behind an explicit flag/entry point and document that enabling it executes untrusted code.


## Plan of Work

The work is four milestones. M1–M3 are hermetic and CI-safe and deliver the full user-visible
behavior in the Purpose. M4 is the gated real sandbox and is optional even within this optional
plan. New code lives in the `shikumi-tools` package under `shikumi-tools/src/Shikumi/CodeExec/`,
next to `Shikumi/Agent/ReAct.hs`.

### Milestone M1 — the `CodeInterpreter` value and the hermetic interpreter

**Scope.** Define the swappable sandbox as a value, ship a hermetic restricted evaluator and
trivial stubs, and write the security posture into the module Haddock. No model loop yet. At the
end of M1 a new module `Shikumi.CodeExec.Interpreter` compiles and its restricted evaluator is
unit-tested.

**What will exist.** A new file `shikumi-tools/src/Shikumi/CodeExec/Interpreter.hs` exporting:

```haskell
-- | A sandbox as a plain value: run a code string, get back either an error
-- message (fed to the model) or the program's textual output. Captured in an
-- Embed closure (like a ToolRegistry), never added to the effect row.
newtype CodeInterpreter = CodeInterpreter
  { runCode :: forall es. (LLM :> es, Error ShikumiError :> es) => Text -> Eff es (Either Text Text)
  }
```

The `runCode` field is rank-2 over the **same** row the Embed body has, so an interpreter may
(if it wants) make `LLM` calls or signal infrastructure failure — but a *pure* interpreter
simply ignores the effects and `pure`s its result, which is what the hermetic ones do. The
`Either Text Text` is "Left errorMessage / Right output": a `Left` is a *recoverable* code error
fed back to the model (it is **not** a `ShikumiError`); a genuine infrastructure failure (e.g.
M4's subprocess died) is thrown as a `ShikumiError` from inside `runCode`.

Implementations to ship in M1:

```haskell
-- | The hermetic default. Parses and evaluates a tiny arithmetic/string/list DSL
-- purely; no IO, no network, no filesystem; a step/size cap bounds runtime.
restrictedInterpreter :: CodeInterpreter

-- | Echoes the code back as output (trivial stub for wiring tests).
echoInterpreter :: CodeInterpreter

-- | Returns scripted results in order, ignoring the code (for loop-shape tests
-- that want to force a specific error-then-success sequence).
scriptedInterpreter :: [Either Text Text] -> IO CodeInterpreter
```

The restricted DSL (kept deliberately small, documented in the Haddock): integer and rational
literals and `+ - * /`, parentheses, string literals with `++` concatenation and the functions
`len`, `upper`, `lower`, list literals with `sum`, `length`, `concat`, and a single trailing
`result = <expr>` / bare `<expr>` whose value is rendered to text as the output. The evaluator
returns `Left "<message>"` for a parse error, an unknown identifier, division by zero, or
exceeding the step cap; `Right "<rendered value>"` on success. This is enough to (a) compute an
arithmetic/string answer the model would otherwise get wrong, and (b) produce a deliberate error
(e.g. division by zero or an unknown function) that the next attempt fixes.

**Security write-up.** Put the SECURITY POSTURE section above into the module Haddock of
`Interpreter.hs` verbatim-in-spirit, and keep this plan's copy authoritative.

**Cabal.** Add `Shikumi.CodeExec.Interpreter` to `exposed-modules` in
`shikumi-tools/shikumi-tools.cabal` (and the later modules as they land). No new dependencies
for M1–M3 (the restricted evaluator uses only `text`, `containers`, and what is already there).
M4 will add a process dependency, guarded.

**Acceptance for M1.** A unit test module `RestrictedSpec` (wired into `test/Main.hs`) feeds the
restricted interpreter several code strings and asserts the `Either Text Text` results: e.g.
`runRestricted "2 + 3 * 4"` gives `Right "14"`; `runRestricted "1 / 0"` gives a `Left` whose
message mentions division; `runRestricted "upper(\"ab\") ++ \"C\")"` (malformed) gives a `Left`
parse error; `runRestricted "len(\"hello\")"` gives `Right "5"`. Run with
`cabal test shikumi-tools` inside `nix develop .#ghc9124`.

### Milestone M2 — `programOfThought` as an Embed node

**Scope.** Build the single-snippet "emit code → run → on error feed back → extract" program.
At the end of M2 `programOfThought sig` is an ordinary `Program i o` that, against a scripted
mock model and the hermetic interpreter, solves a task a plain `predict` fails and exercises the
error-then-fix loop.

**What will exist.** A new file
`shikumi-tools/src/Shikumi/CodeExec/ProgramOfThought.hs` exporting:

```haskell
data PoTConfig = PoTConfig
  { maxIters    :: !Int            -- max code (re)generation attempts; default 3
  , interpreter :: !CodeInterpreter
  }

defaultPoTConfig :: PoTConfig          -- maxIters = 3, interpreter = restrictedInterpreter

-- | The ergonomic default: emit code, run it, fix on error up to maxIters, extract o.
programOfThought ::
  (ToPrompt i, ToSchema o, FromModel o, Validatable o) =>
  Signature i o -> Program i o
programOfThought sig = programOfThoughtWith defaultPoTConfig sig

programOfThoughtWith ::
  (ToPrompt i, ToSchema o, FromModel o, Validatable o) =>
  PoTConfig -> Signature i o -> Program i o
programOfThoughtWith cfg sig = embed (potLoop cfg sig)

-- | The loop body, in exactly the Embed row.
potLoop ::
  (LLM :> es, Error ShikumiError :> es, ToPrompt i, ToSchema o, FromModel o, Validatable o) =>
  PoTConfig -> Signature i o -> i -> Eff es o
```

`potLoop` mirrors DSPy's `forward` and the ReAct loop structure:

1. **Generate.** Render a code-generation prompt from `getInstruction sig`, the task rendered
   via `toPrompt i`, and an instruction to "write a snippet in the restricted language that
   computes the answer; the value of the final expression is the result." Issue `complete _Model
   ctx opts`; extract the code from the reply text, stripping Markdown fences (reuse a helper
   like ReAct's `stripFences`).
2. **Execute.** `runCode (interpreter cfg) code`. On `Right out`, go to extract. On `Left err`,
   record `(code, err)` and loop to **regenerate**.
3. **Regenerate.** If attempts remain, render a correction prompt that includes the previous
   code and the error message ("your code errored with: <err>; fix it"), issue `complete`,
   re-extract, re-execute. After `maxIters` failed attempts, throw `ProviderFailure
   "programOfThought: code failed after N attempts: <last error>"`.
4. **Extract.** Render an extraction prompt that gives the model the final code and its captured
   output and asks for the typed answer as JSON matching `toSchema (Proxy @o)`; issue `complete`;
   `parseOutput (stripFences (responseText resp))`; `either throwError pure`.

This is four `complete` calls at most-times-`maxIters` shape, identical in spirit to ReAct's
propose/extract split. Reuse `responseText`, `stripFences`, and the prompt-building helpers from
ReAct (either import them — they may need exporting from `Shikumi.Agent.ReAct` — or copy the few
small helpers into a shared `Shikumi.CodeExec.Prompt` module; prefer extracting shared helpers
to avoid duplication, and note the choice in the Decision Log).

**Acceptance for M2.** Two tests in a new module `ProgramOfThoughtSpec`:

- *Solves what predict fails.* Pick a task whose answer a single guess gets wrong but a tiny
  computation gets right — e.g. input "multiply 37 by 19 and add 6", expected `703`. Script the
  mock model to (a) emit the code `37 * 19 + 6` and (b) on the extract call emit the JSON for
  the typed output carrying `703`. Run `programOfThought sig` via `runAgent` with the hermetic
  `restrictedInterpreter`. Assert the typed result equals `703`. To *prove the code ran* (not
  that the model just returned 703), use a `scriptedInterpreter`/instrumented interpreter in a
  variant of the test that records the code it was asked to run and assert the recorded string is
  `"37 * 19 + 6"` and the run produced `"703"`; and assert that a *plain* `predict` baseline,
  scripted with the same wrong direct guess, returns the wrong number — demonstrating the
  difference. Keep both assertions so the test shows the code path is load-bearing.
- *Error-then-fix.* Script the model to first emit erroring code (e.g. `1 / 0`) and then, after
  the error is fed back, emit correct code (e.g. `6`); script the extract reply to carry the
  typed answer. With `restrictedInterpreter` (which really returns the division error on the
  first snippet and `6` on the second), assert the loop produced the right typed answer and that
  it took the second attempt. Optionally assert via an instrumented interpreter that exactly two
  code strings were executed, the first being the erroring one.

Run with `cabal test shikumi-tools` inside `nix develop .#ghc9124`.

### Milestone M3 — `codeAct` as an Embed node combining code + tool calls

**Scope.** Build the multi-turn loop where each action is a code snippet that may call provided
tools, accumulating a `Trajectory`, then extract the typed answer. Reuse `Shikumi.Agent.ReAct`'s
`Trajectory`/`Step`/`Termination` data model.

**What will exist.** A new file `shikumi-tools/src/Shikumi/CodeExec/CodeAct.hs` exporting:

```haskell
data CodeActConfig = CodeActConfig
  { maxIters    :: !Int            -- default 5
  , interpreter :: !CodeInterpreter
  }

defaultCodeActConfig :: CodeActConfig   -- maxIters = 5, interpreter = restrictedInterpreter

codeAct ::
  (ToPrompt i, ToSchema o, FromModel o, Validatable o) =>
  Signature i o -> ToolRegistry -> Program i o
codeAct sig reg = FMap fst (codeActWithTrajectory defaultCodeActConfig sig reg)

codeActWithTrajectory ::
  (ToPrompt i, ToSchema o, FromModel o, Validatable o) =>
  CodeActConfig -> Signature i o -> ToolRegistry -> Program i (o, Trajectory)
codeActWithTrajectory cfg sig reg = embed (codeActLoop cfg sig reg)

codeActLoop ::
  (LLM :> es, Error ShikumiError :> es, ToPrompt i, ToSchema o, FromModel o, Validatable o) =>
  CodeActConfig -> Signature i o -> ToolRegistry -> i -> Eff es (o, Trajectory)
```

`codeActLoop` mirrors DSPy's `CodeAct.forward` and the ReAct loop:

1. **Instructions.** Build a system prompt from `getInstruction sig` plus a description of the
   available tools (each tool's `someToolName`/`someToolDescription`/`someToolSchema` from the
   registry, rendered like ReAct's `toolMenu`), telling the model it may call those tools *by
   name from within its code snippet* and must print the value it wants extracted; and that it
   sets a `finished` flag when done.
2. **Iterate** up to `maxIters`: issue `complete`; parse a `(code, finished)` reply from the
   model text (a small JSON object `{"code": "...", "finished": true|false}`, parsed with the
   same fence-stripping helpers); run the snippet through the interpreter. Because the hermetic
   restricted DSL does not itself call host functions, the loop intercepts tool usage at the
   *protocol* level: the convention is that a snippet requesting a tool is the single form
   `call("<toolName>", <argsJSON>)`, which the loop recognizes before/without handing it to the
   pure evaluator, dispatching via `runToolCall reg (mkToolCall name args)` and feeding the
   tool's result text back as the observation; a snippet with no `call(...)` is evaluated by the
   interpreter and its output (or error) is the observation. Record each turn as a `Step`
   (thought = the model's preamble text, action encodes the code/tool, observation = the
   output/error) into the growing `Trajectory`. Stop when `finished` or `maxIters`
   (`TerminatedMaxIters`).
3. **Extract.** Render an extraction prompt giving the model the rendered trajectory
   (`renderTrajectory`) and asking for the typed `o` as JSON; `parseOutput`; return `(o, traj)`.

The `call("name", args)` convention keeps the hermetic path honest: tool dispatch goes through
the existing typed `runToolCall`, and the *code execution* path goes through the sandbox, so the
single loop genuinely combines both — matching DSPy's "code snippet that calls provided
functions" without requiring the hermetic DSL to embed a foreign-function interface. Document
this convention in the module Haddock; note that under the M4 subprocess interpreter the tools
would instead be injected into the real interpreter (as DSPy does) and called natively, and that
M4 may relax this convention.

**Acceptance for M3.** A test module `CodeActSpec`:

- Register one simple tool (e.g. `addOne :: {n:Int} -> Int`). Script the model to (turn 1) emit
  `{"code": "call(\"addOne\", {\"n\": 41})", "finished": false}`, and (turn 2) emit `{"code":
  "result = 42", "finished": true}`; script the extract reply to carry the typed answer `42`.
  Run `codeActWithTrajectory` via `runAgent` with the hermetic interpreter and assert: the typed
  answer is `42`; the trajectory has two steps; the first step's observation is the tool result
  (`42` from `addOne`); termination is `TerminatedFinish`. This proves code generation and tool
  calling are combined in one loop and the trajectory is recorded.

Run with `cabal test shikumi-tools` inside `nix develop .#ghc9124`.

### Milestone M4 (gated, non-CI) — the real subprocess interpreter

**Scope.** Provide `subprocessInterpreter` backed by a real `python3` or `deno` process with the
security boundary in the SECURITY POSTURE section. Because the subprocess needs `IOE` and the
Embed body cannot carry it, this interpreter is **not** usable inside the composable
`programOfThought`/`codeAct` GADT path; expose it only through an `IOE`-bearing convenience entry
point that runs the loop logic directly (e.g. `runProgramOfThoughtIO :: (IOE :> es, LLM :> es,
Error ShikumiError :> es) => PoTConfig -> Signature i o -> i -> Eff es o`, sharing `potLoop`'s
algorithm but allowed to call into IO for the subprocess). State clearly in the Haddock and here
that this path executes untrusted code and is excluded from CI.

**What will exist.** `subprocessInterpreter :: SubprocessConfig -> IO CodeInterpreter` (or an
`IOE`-scoped equivalent), where `SubprocessConfig` carries the interpreter choice (`deno`
preferred for its permission flags), the per-call wall-clock timeout, and the scratch dir
policy. Implementation uses `typed-process`/`System.Process` under `IOE`; for `deno`, build the
argument list with `--allow-read=<scratch> --allow-write=<scratch>` and **no** `--allow-net`/
`--allow-env`; create and delete a fresh temp dir per call; kill the child and raise `Timeout`
on expiry. Driving Python over a JSON-RPC stdin/stdout protocol like DSPy's runner is optional;
a simpler "write code to scratch file, run, capture stdout/stderr, parse" approach is acceptable
and easier to reason about for the security review.

**Acceptance for M4.** Manual, off-CI: with `deno` (or `python3`) installed, run a small
executable or an `ifdef`-guarded test that asks `programOfThought` (via the IO entry point) to
compute an arithmetic answer through the real interpreter and observe the correct typed result;
attempt a network call from the emitted code and observe it is denied (permission error surfaced
as a `ShikumiError`). Never wired into `cabal test`'s default run.

### The parameter-count invariant (state explicitly, verify by test)

Every program this plan produces is built solely from `embed` (and `FMap`, for `codeAct`'s
`fst`). `Embed` and `FMap` carry **no** `Params`. Therefore:

- `foldParams (programOfThought sig)` is `[]`, and `foldParams (codeAct sig reg)` is `[]`.
- `programShape` renders these as `ShapeEmbed` (or `ShapeFMap ShapeEmbed`) — the existing
  constructors; no new shape is added.
- `setProgramParams [] p` succeeds for these programs (zero expected, zero supplied);
  `encodeCompiled (freezeProgram (programOfThought sig))` is the empty JSON array `[]`, and
  `decodeCompiledOnto (programOfThought sig) "[]"` round-trips.
- No change is required to `paramsTraversal`, `programShape`, `setProgramParams`,
  `encodeCompiled`, `decodeCompiledOnto`, or any optimizer/compiler code. The V1 compilers and
  serialization pass these nodes through unchanged, exactly as they already do for `react`.

A test (`InvariantSpec`, or folded into `ProgramOfThoughtSpec`) asserts `null (foldParams
(programOfThought sig))` and the analogous fact for `codeAct`.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/shikumi` inside the dev
shell. Enter it once:

```bash
nix develop .#ghc9124
```

This provides GHC 9.12.4, `cabal`, HLS, and `fourmolu`. The hermetic path (M1–M3) needs no
other tools; do **not** add a `python3`/`deno` dependency to the default build.

Create the new module directory and files:

```bash
mkdir -p shikumi-tools/src/Shikumi/CodeExec
# then author, in order:
#   shikumi-tools/src/Shikumi/CodeExec/Interpreter.hs        (M1)
#   shikumi-tools/src/Shikumi/CodeExec/Prompt.hs             (shared helpers, optional)
#   shikumi-tools/src/Shikumi/CodeExec/ProgramOfThought.hs   (M2)
#   shikumi-tools/src/Shikumi/CodeExec/CodeAct.hs            (M3)
```

Register each module under `exposed-modules` in `shikumi-tools/shikumi-tools.cabal` as it is
written, and add the new test modules (`RestrictedSpec`, `ProgramOfThoughtSpec`, `CodeActSpec`,
optionally `InvariantSpec`) under the test-suite's `other-modules` and into `test/Main.hs`.

Build and test after each milestone:

```bash
cabal build shikumi-tools
cabal test shikumi-tools
```

Format before committing:

```bash
fourmolu -i $(git ls-files '*.hs')   # 2-space indentation, project default
```

Expected test transcript shape (illustrative — your test names will match the modules above):

```text
shikumi-tools-test
  RestrictedSpec
    2 + 3 * 4 evaluates to 14:            OK
    1 / 0 reports a division error:       OK
    len("hello") evaluates to 5:          OK
  ProgramOfThoughtSpec
    solves 37*19+6 that predict misses:   OK
    proves the emitted code actually ran: OK
    error-then-fix reaches the answer:    OK
    programOfThought carries no params:   OK
  CodeActSpec
    code snippet calls a provided tool:   OK
    records a two-step trajectory:        OK

All N tests passed
```


## Validation and Acceptance

The plan is accepted when, inside `nix develop .#ghc9124`, `cabal test shikumi-tools` (and
`cabal test all`) pass with the following **behavioral** facts demonstrated, all under the
hermetic `restrictedInterpreter` with the network-free `MockLLM` (no external interpreter, no
network):

1. `programOfThought sig` returns the **correct typed answer** to a fixture arithmetic/string
   task (e.g. `703` for "multiply 37 by 19 and add 6"), and a `predict` baseline scripted with a
   plausible wrong direct guess returns the **wrong** answer — so the code path is shown to be
   load-bearing, not incidental.
2. The **emitted code actually ran**: an instrumented interpreter records the exact code string
   it executed (`"37 * 19 + 6"`) and the output it produced (`"703"`), asserted in the test.
3. The **error-then-fix loop** is exercised: the first scripted snippet errors in the sandbox
   (e.g. `1 / 0` → division error), the error is fed back, the second snippet succeeds, and the
   final typed answer is correct; the test asserts the second attempt was the one that worked.
4. `codeAct sig reg` runs a two-turn loop in which a code snippet **calls a provided tool**
   (`addOne`), records a two-step `Trajectory`, finishes, and extracts the correct typed answer.
5. The **parameter-count invariant** holds: `foldParams (programOfThought sig) == []` and
   `foldParams (codeAct sig reg) == []`; serialization round-trips through the empty parameter
   vector; no optimizer/compiler code changed.

M4's real-sandbox behavior is validated **manually and off-CI** only (see its milestone); it is
not part of the accept gate.


## Idempotence and Recovery

All steps are additive: new files under `shikumi-tools/src/Shikumi/CodeExec/`, new test modules,
and `exposed-modules`/`other-modules` cabal additions. Re-running `mkdir -p`, `cabal build`,
`cabal test`, and `fourmolu -i` is safe and repeatable. If a milestone's build fails, fix the
named module in isolation and re-run `cabal build shikumi-tools`; nothing here mutates shared
state outside the new files and the two cabal stanzas. M4 adds a process dependency to the cabal
file — keep it confined so M1–M3 still build without any external interpreter; if M4 is not
pursued, simply do not add that dependency. No destructive or migration steps exist.


## Interfaces and Dependencies

**Libraries/modules used and why.** `Shikumi.Program` (the `Embed`/`embed` node — the whole
design hinges on it carrying no params and fixing the body row to `(LLM, Error ShikumiError)`);
`Shikumi.LLM` (`complete`, the model call); `Shikumi.Error` (`ShikumiError`, thrown via
`Effectful.Error.Static.throwError`); `Shikumi.Schema`/`Shikumi.Adapter`
(`parseOutput`/`toSchema`/`ToPrompt` for turning code output into a typed `o`);
`Shikumi.Signature` (`getInstruction`); `Shikumi.Tool` (`ToolRegistry`, `runToolCall`,
`registryTools`, the per-tool accessors — for `codeAct`); `Shikumi.Agent.ReAct` (the
`Trajectory`/`Step`/`Termination` data model and the small `stripFences`/`responseText` helpers
— export them from ReAct or factor into `Shikumi.CodeExec.Prompt`). For M4 only: `typed-process`
or `System.Process` under `IOE`, plus `directory`/`temporary` for the scratch dir — guarded, not
in the M1–M3 build. No new dependency for M1–M3; the restricted evaluator uses only `text` and
`containers`.

**Types/functions that must exist at the end of each milestone.**

End of **M1** (`shikumi-tools/src/Shikumi/CodeExec/Interpreter.hs`):

```haskell
newtype CodeInterpreter = CodeInterpreter
  { runCode :: forall es. (LLM :> es, Error ShikumiError :> es) => Text -> Eff es (Either Text Text) }
restrictedInterpreter :: CodeInterpreter
echoInterpreter       :: CodeInterpreter
scriptedInterpreter   :: [Either Text Text] -> IO CodeInterpreter
```

End of **M2** (`shikumi-tools/src/Shikumi/CodeExec/ProgramOfThought.hs`):

```haskell
data PoTConfig = PoTConfig { maxIters :: !Int, interpreter :: !CodeInterpreter }
defaultPoTConfig :: PoTConfig
programOfThought     :: (ToPrompt i, ToSchema o, FromModel o, Validatable o) => Signature i o -> Program i o
programOfThoughtWith :: (ToPrompt i, ToSchema o, FromModel o, Validatable o) => PoTConfig -> Signature i o -> Program i o
```

End of **M3** (`shikumi-tools/src/Shikumi/CodeExec/CodeAct.hs`):

```haskell
data CodeActConfig = CodeActConfig { maxIters :: !Int, interpreter :: !CodeInterpreter }
defaultCodeActConfig :: CodeActConfig
codeAct               :: (ToPrompt i, ToSchema o, FromModel o, Validatable o) => Signature i o -> ToolRegistry -> Program i o
codeActWithTrajectory :: (ToPrompt i, ToSchema o, FromModel o, Validatable o) => CodeActConfig -> Signature i o -> ToolRegistry -> Program i (o, Trajectory)
```

End of **M4** (gated; `Interpreter.hs` + an IO entry point):

```haskell
data SubprocessConfig = SubprocessConfig { {- interpreter choice, timeout, scratch policy -} }
subprocessInterpreter :: SubprocessConfig -> IO CodeInterpreter   -- non-hermetic, non-CI
runProgramOfThoughtIO ::
  (IOE :> es, LLM :> es, Error ShikumiError :> es, ToPrompt i, ToSchema o, FromModel o, Validatable o) =>
  PoTConfig -> Signature i o -> i -> Eff es o
```

**Build/test facts (authoritative).** Everything builds and tests inside `nix develop
.#ghc9124` (GHC 9.12.4). The home for this work is `shikumi-tools` (next to ReAct); run `cabal
test shikumi-tools` for the focused suite and `cabal test all` for the whole workspace. Format
with `fourmolu` at 2-space indentation. The CI/hermetic path (M1–M3) must **not** require any
external interpreter binary or network. Commits carry the `MasterPlan:`, `ExecPlan:`, and
`Intention:` trailers (this plan's `intention` is `intention_01ktq812wfebgvf1dtbvg3v826`; the
MasterPlan is `docs/masterplans/4-shikumi-richer-io-and-multimodal.md`; the ExecPlan is this
file). Sibling plans are referenced by path only:
`docs/plans/24-multimodal-field-types.md`,
`docs/plans/25-program-level-streaming-and-status-messages.md`,
`docs/plans/26-adapter-completeness-and-declarative-field-constraints.md`.
