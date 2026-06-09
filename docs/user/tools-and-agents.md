# Tools & ReAct agents — under the covers

`shikumi-tools` adds typed tools and a ReAct agent loop. The two ideas that make it fit the
rest of the framework: **a tool's argument schema is derived from its input record** (same
`ToSchema` engine as everything else), and **a ReAct agent is itself a `Program`**, so it
composes, traces, caches, and optimizes like any other node.

---

## Typed tools

```haskell
data Tool i o = Tool
  { toolName        :: Text
  , toolDescription :: Text
  , toolRun         :: forall es. (LLM :> es, Error ShikumiError :> es) => i -> Eff es o
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
data ReActConfig   = ReActConfig { maxIters :: Int, protocol :: ToolProtocol }
data ToolProtocol  = ProtocolNative | ProtocolPrompt | ProtocolAuto
defaultReActConfig = ReActConfig { maxIters = 6, protocol = ProtocolAuto }
```

`ProtocolAuto` resolves per model via the same `capabilityFor` used by the adapters: a model
with native function-calling uses the native protocol; everything else falls back to a
prompt-based action grammar parsed from the model's text. The loop body is identical under
either — only the rendering/parsing differs (the `ProtocolImpl` seam).

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

## See it run

```bash
cabal run jitsurei-react
```

A typed `Tool`, a `ToolRegistry`, and a `reactWithTrajectory` agent driven by a scripted
offline stub — showing the thought/action/observation turns and the recorded trajectory, no
network.
