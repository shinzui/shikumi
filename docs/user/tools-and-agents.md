# Tools & ReAct agents — under the covers

`shikumi-tools` adds typed tools, a built-in work-tool catalog, and a ReAct agent loop. The
two ideas that make it fit the rest of the framework: **a tool's argument schema is derived
from its input record** (same `ToSchema` engine as everything else), and **a ReAct agent is
itself a `Program`**, so it composes, traces, caches, and optimizes like any other node.

---

## Typed tools

```haskell
data Tool i o = Tool
  { name        :: Text
  , description :: Text
  , run         :: forall es. (LLM :> es, Error ShikumiError :> es) => i -> Eff es o
  }

mkTool :: Text -> Text -> (forall es. (LLM :> es, Error ShikumiError :> es) => i -> Eff es o) -> Tool i o
```

A tool is an ordinary function from an input record `i` to an output `o`. Its body is rank-2
over the effect row, so the same value runs in any stack with `LLM` and `Error ShikumiError` —
which means a tool may itself call sub-models and signal failure through the typed error
channel. A pure tool is just `\i -> pure (f i)`.

```haskell
weatherTool :: Tool City Forecast
weatherTool = mkTool "get_weather" "Look up a city's forecast." (\c -> pure (lookupForecast c))
```

### From typed tool to wire tool

The argument schema is derived from `i` via `ToSchema`, then lowered to baikai's untyped wire
tool:

```haskell
toolSchemaOf :: ToSchema i => Tool i o -> Value      -- the input record's JSON Schema
lowerTool    :: ToSchema i => Tool i o -> B.Tool     -- the single sanctioned typed→wire lowering
```

---

## The registry

Tools of different types live together behind an existential, keyed by name:

```haskell
data SomeTool where
  SomeTool :: (ToSchema i, FromModel i, Validatable i, ToJSON o) => Tool i o -> SomeTool

newtype ToolRegistry = ToolRegistry (Map Text SomeTool)

mkRegistry      :: [SomeTool] -> ToolRegistry           -- last wins on name clash
registryLookup  :: Text -> ToolRegistry -> Maybe SomeTool
registryBaikai  :: ToolRegistry -> Vector B.Tool        -- lowered, for Context.tools
registryNames   :: ToolRegistry -> [Text]               -- the tool menu
```

`SomeTool` erases `i`/`o` while retaining the dictionaries needed to derive the schema, decode
arguments from JSON, and encode the result to text — captured at wrap time.

### Running a tool totally

```haskell
data ToolError = ToolNotFound Text | ToolArgsInvalid Text Text | ToolRunFailed Text Text
renderToolError :: ToolError -> Text

runErased   :: (LLM :> es, Error ShikumiError :> es) => SomeTool -> Value -> Eff es (Either ToolError Text)
runToolCall :: (LLM :> es, Error ShikumiError :> es) => ToolRegistry -> ToolCall -> Eff es (Either ToolError Text)
```

`runToolCall` finds the named tool, decodes the JSON arguments to the hidden `i`, runs the
body, and encodes `o` to text — **totally**. A decode failure becomes `ToolArgsInvalid`; a body
throwing `ShikumiError` becomes `ToolRunFailed`. It never throws for a tool-level fault. The
agent feeds the *rendered* `ToolError` back to the model as an observation, so the model can
recover; only genuine infrastructure faults bubble up as a `ShikumiError`.

---

## Built-in work tools

The typed tool layer is intentionally small, but `shikumi-tools` also ships a practical
catalog for file, shell, and web work:

```haskell
module Shikumi.Tool.Builtin
  ( builtinFsTools
  , builtinWebTools
  , builtinTools
  , builtinRegistry
  )

builtinFsTools  :: ToolEnv -> [SomeTool]
builtinWebTools :: WebClient -> [SomeTool]
builtinTools    :: ToolEnv -> WebClient -> [SomeTool]
builtinRegistry :: ToolEnv -> WebClient -> ToolRegistry
```

`builtinRegistry` is the one-call entry point for a ReAct agent or `codeAct` loop that should
be able to inspect and edit local files, run commands, and fetch web pages:

```haskell
import Shikumi.Tool.Builtin (builtinRegistry)
import Shikumi.Tool.Env     (localToolEnv)
import Shikumi.Tool.Web     (localWebClient, newTlsManager)

main :: IO ()
main = do
  manager <- newTlsManager
  let web      = localWebClient manager Nothing
      registry = builtinRegistry localToolEnv web
      agent    = react agentSig registry defaultReActConfig
  -- runProgram agent ...
```

With `localWebClient manager Nothing`, `web_fetch` works and `web_search` returns a recoverable
tool failure observation saying no search provider is configured. Supplying a `SearchConfig`
enables `web_search` against a provider endpoint that accepts `q`, `key`, and `limit` query
parameters and returns a JSON `SearchResult`.

### Tool catalog

| Tool | Arguments | Result |
|---|---|---|
| `read` | `path`, optional `offset`, optional `limit` | UTF-8 file text, selected line count, and `truncated`. |
| `write` | `path`, `content` | Written path and byte count. |
| `edit` | `path`, `oldString`, `newString`, optional `replaceAll` | Written path and replacement count. Empty or missing `oldString` is a tool failure observation. |
| `grep` | `pattern`, optional `path`, optional `glob`, optional `ignoreCase` | Up to 1000 `{file,line,text}` regex matches plus `truncated`. |
| `glob` | `pattern`, optional `path` | Up to 1000 matching paths plus `truncated`. |
| `bash` | `command`, optional `cwd`, optional `timeoutMs`, optional `stdin` | Exit code, stdout, and stderr. A non-zero exit is a normal result, not an exception. |
| `web_fetch` | `url`, optional `maxBytes` | HTTP status, content type, decoded body, and `truncated`. |
| `web_search` | `query`, optional `maxResults` | Provider search hits with title, URL, and snippet. |

The JSON field for both search tools is `pattern`; the Haskell record selector is
`patternText`, because `pattern` conflicts with the `PatternSynonyms` extension used in the
package.

`grep` and `glob` prefer host tools when they are available: `rg` for grep and `fd` for glob.
If either command is missing or returns an unusable result, the tool falls back to a bounded
in-process traversal through the same `ToolEnv`. The fallback skips noisy directories
(`.git`, `node_modules`, `dist-newstyle`, `.stack-work`, `.direnv`), skips binary files, caps
file size at 5 MiB, caps depth at 25, and caps results at 1000.

### Environment seams

The built-ins do not call the host directly; they call two swappable records:

```haskell
data ToolEnv = ToolEnv
  { envExec      :: forall es. EnvRow es => ExecRequest -> Eff es ExecResult
  , envReadFile  :: forall es. EnvRow es => Path -> Eff es ByteString
  , envWriteFile :: forall es. EnvRow es => Path -> ByteString -> Eff es ()
  , envStat      :: forall es. EnvRow es => Path -> Eff es (Maybe FileStat)
  , envReaddir   :: forall es. EnvRow es => Path -> Eff es [DirEntry]
  , envExists    :: forall es. EnvRow es => Path -> Eff es Bool
  , envMkdir     :: forall es. EnvRow es => Path -> Eff es ()
  , envRm        :: forall es. EnvRow es => Path -> Eff es ()
  , envCwd       :: forall es. EnvRow es => Eff es Path
  }

localToolEnv :: ToolEnv

data WebClient = WebClient
  { webFetch  :: forall es. EnvRow es => Text -> Maybe Int -> Eff es FetchResult
  , webSearch :: forall es. EnvRow es => Text -> Maybe Int -> Eff es SearchResult
  }

localWebClient :: Manager -> Maybe SearchConfig -> WebClient
```

`localToolEnv` is a real local filesystem and shell environment. It is useful for local agents
and tests that deliberately exercise real commands, but it is not a sandbox. To restrict an
agent, provide a different `ToolEnv`: for example, one rooted in a scratch directory, one that
denies `bash`, or one that records writes for review. The tool definitions stay unchanged.

---

## The ReAct agent

```haskell
react              :: (ToPrompt i, ToSchema o, FromModel o, Validatable o)
                   => Signature i o -> ToolRegistry -> ReActConfig -> Program i o
reactWithTrajectory :: (…same…) => Signature i o -> ToolRegistry -> ReActConfig -> Program i (o, Trajectory)
```

`react` builds an agent as a `Program i o` returning the typed answer; `reactWithTrajectory`
also returns the recorded steps, for evaluators/optimizers and tests asserting on the path.
Because the loop is wrapped in an [`embed`](./programs-and-combinators.md#embed-the-escape-hatch)
node, **the agent is a real, composable `Program`** — runnable under `runProgram`,
structurally inspectable (`ShapeEmbed`), and serializable.

### Configuration

```haskell
data ReActConfig   = ReActConfig
  { maxIters :: Int, protocol :: ToolProtocol, compaction :: CompactionConfig }
data ToolProtocol  = ProtocolNative | ProtocolPrompt | ProtocolAuto
defaultReActConfig = ReActConfig
  { maxIters = 6, protocol = ProtocolAuto, compaction = defaultCompactionConfig }
```

`ProtocolAuto` resolves per model via the same `capabilityFor` used by the adapters: a model
with native function-calling uses the native protocol; everything else falls back to a
prompt-based action grammar parsed from the model's text. The loop body is identical under
either — only the rendering/parsing differs (the `ProtocolImpl` seam).

### Working-context compaction

Long ReAct runs compact their in-flight history before it exceeds the model context window.
After each tool turn, the loop reads the provider-reported input-token usage and resolved
model window from the `Response`; when usage reaches `contextWindow - reserveTokens`, it
summarizes older steps into one visible summary step and keeps the most recent
`keepRecent` steps verbatim. The defaults are `reserveTokens = 16384`, `keepRecent = 4`,
and `enabled = True`.

Under the default `maxIters = 6`, normal short agents usually never reach the threshold. To
benefit from compaction, run a longer agent by raising `maxIters`. Disable the behavior with
`compaction = defaultCompactionConfig { enabled = False }`.

If a provider reports an overflow as baikai's `ContextOverflow`, the loop also performs a
one-shot compact-then-retry recovery. That path is best-effort: the proactive token
threshold is the dependable guard, because some providers surface oversized requests as a
generic invalid request instead of `ContextOverflow`.

For tuning guidance, recovery details, and trajectory inspection, see
[Agent working-context compaction](./agent-context-compaction.md).

### The trajectory

```haskell
data Action      = CallTool Text Value | Finish
data Step        = Step { thought :: Text, action :: Action, observation :: Maybe Text }
data Termination = TerminatedFinish | TerminatedMaxIters Int | TerminatedBudget
data Trajectory  = Trajectory { steps :: Vector Step, termination :: Termination }

renderTrajectory :: Trajectory -> Text
```

The loop alternates **thought → action → observation** until the model finishes or the
iteration cap is hit, then extracts the typed answer. An `observation` is `Nothing` for
`Finish`; for a tool call it is the tool result text or the rendered `ToolError`. (Budget
termination is enforced one layer down by the resilient LLM interpreter.)

```haskell
researcher :: Program Question Answer
researcher = react agentSig
  (mkRegistry [SomeTool weatherTool, SomeTool searchTool])
  defaultReActConfig
```

---

## Code execution: `programOfThought` & `codeAct`

Two further modules (`Shikumi.CodeExec.*`) let the model **write code, run it in a sandbox, and
feed the result back into a typed answer** — the same idea as DSPy's `ProgramOfThought` and
`CodeAct`. Like `react`, each is an [`embed`](./programs-and-combinators.md#embed-the-escape-hatch)
node, so it is a real, composable `Program` carrying no tunable parameters.

```haskell
programOfThought :: (ToPrompt i, ToSchema o, FromModel o, Validatable o)
                 => Signature i o -> Program i o

codeAct          :: (ToPrompt i, ToSchema o, FromModel o, Validatable o)
                 => Signature i o -> ToolRegistry -> Program i o
codeActWithTrajectory :: (…) => CodeActConfig -> Signature i o -> ToolRegistry -> Program i (o, Trajectory)
```

- **`programOfThought`** asks the model for a code snippet that *computes* the answer, runs it,
  and — if the snippet errors — feeds the error back so the model can fix it (up to `maxIters`
  attempts), then extracts the typed `o` from the successful run's output. Useful when a plain
  `predict` would *guess* a number that a tiny computation gets right.
- **`codeAct`** is a ReAct-style loop whose each *action* is a code snippet that may call
  provided tools, accumulating the same `Trajectory` as `react`, until the model declares it is
  finished and the typed answer is extracted.

### The sandbox is a swappable value

```haskell
newtype CodeInterpreter = CodeInterpreter
  { runCode :: forall es. (LLM :> es, Error ShikumiError :> es) => Text -> Eff es (Either Text Text) }

restrictedInterpreter :: CodeInterpreter   -- the hermetic default
echoInterpreter       :: CodeInterpreter

data PoTConfig      = PoTConfig      { maxIters :: Int, interpreter :: CodeInterpreter }
data CodeActConfig  = CodeActConfig  { maxIters :: Int, interpreter :: CodeInterpreter }
```

The interpreter is a **plain value captured in the `embed` closure** — never an effect-row
member — because the `embed` body is fixed to the `(LLM, Error ShikumiError)` row (it admits no
`IOE`). That single fact shapes the design: a *pure* interpreter fits inside any row, but a real
subprocess interpreter would need `IOE` and so could only be offered through a separate
`IOE`-bearing entry point, outside the composable program path.

The shipped default, **`restrictedInterpreter`, is safe by construction**: it parses and
evaluates a tiny DSL purely — integer/rational arithmetic (`+ - * /`) with parentheses, string
literals with `++` and `len`/`upper`/`lower`, and list literals with `sum`/`length`/`concat` —
with a step cap and *no* syscalls, filesystem, or network. It returns `Left "<message>"` for a
parse error, an unknown identifier, division by zero, or exceeding the cap; that `Left` is the
recoverable error fed back to the model. This is enough to *demonstrate the loop* offline; a real
`deno`/`python3` subprocess sandbox (with no network, an isolated scratch dir, and CPU/wall-clock
limits) is specified but **not** shipped — running arbitrary model-emitted code is a genuine
remote-code-execution risk, so that path is deliberately gated and out of scope for the default
build.

> In `codeAct`, the hermetic DSL does not itself call host functions, so tool use is a
> *protocol* convention: a snippet of the exact form `call("toolName", <argsJSON>)` is
> recognized by the loop and dispatched through the typed `runToolCall`; any other snippet is
> evaluated by the sandbox. A real subprocess interpreter would instead inject the tool
> functions and call them natively.

---

## See it run

```bash
cabal run jitsurei-react      # a typed Tool, a ToolRegistry, and a reactWithTrajectory agent
cabal run jitsurei-codeexec   # programOfThought + codeAct over the hermetic sandbox
```

`jitsurei-react` shows the thought/action/observation turns and the recorded trajectory;
`jitsurei-codeexec` shows the model write code that the sandbox runs (including an
error-then-fix recovery) and a `codeAct` snippet calling a provided tool — all driven by a
scripted offline stub, no network.

The built-in work-tool catalog is exercised by the `shikumi-tools` test suite, including
filesystem edits, `grep`/`glob` fallback behavior, shell command capture, `web_fetch`, and the
configured/unconfigured `web_search` paths.
