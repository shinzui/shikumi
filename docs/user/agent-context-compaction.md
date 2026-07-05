# Agent working-context compaction

Long-running ReAct and CodeAct agents can build a large in-flight history: every tool call,
code execution, observation, parse correction, and finish step is rendered back into the next
model prompt. Without compaction, that working context can grow until the provider rejects the
next request for exceeding the model's context window.

Shikumi's ReAct and CodeAct loops have built-in working-context compaction. It is an in-run
safety mechanism: it shrinks the live history inside one agent run, without writing memory to
a database and without changing cross-session recall.

This feature is part of `shikumi-tools`, but the reusable primitive lives in core
`shikumi` as `Shikumi.Compaction`.

---

## What gets compacted

Only the agent loop's in-flight step history is compacted.

```haskell
data Action = CallTool Text Value | Finish | Summarized

data Step = Step
  { thought     :: Text
  , action      :: Action
  , observation :: Maybe Text
  }
```

When compaction runs, older steps are summarized into one synthetic step, and the most
recent steps are kept verbatim. The returned `Trajectory` remains auditable because the
summary is visible as an ordinary step:

```text
thought: (compacted summary of earlier steps)
action: summary of earlier steps
observation: <summary text>
```

Internally that action is `Summarized`. It is never produced by the model and never dispatched
as a tool. The empty tool-name sentinel remains reserved for prompt-protocol parse correction,
so a compaction summary cannot be confused with a failed tool call. The recent tail is
preserved so the model still sees the immediate tool results and decisions that matter most
for the next turn.

---

## When it triggers

After each successful action turn, the loop reads two values from the provider `Response`:

- `resp ^. #message . #usage . #inputTokens`
- `resp ^. #model . #contextWindow`

The trigger threshold is:

```text
contextWindow - reserveTokens
```

with saturating subtraction for tiny windows. The default reserve is large enough to leave
room for another prompt render and the next model output.

```haskell
data CompactionConfig = CompactionConfig
  { reserveTokens :: Natural
  , keepRecent    :: Int
  , enabled       :: Bool
  }

defaultCompactionConfig =
  CompactionConfig
    { reserveTokens = 16384
    , keepRecent = 4
    , enabled = True
    }
```

The default `ReActConfig` includes compaction:

```haskell
defaultReActConfig =
  ReActConfig
    { maxIters = 6
    , protocol = ProtocolAuto
    , compaction = defaultCompactionConfig
    }
```

Under `maxIters = 6`, most ordinary agents never reach the threshold. Compaction matters
when you intentionally run longer agents by raising `maxIters`.

`CodeActConfig` carries the same `compaction :: CompactionConfig` field. Its default is
`maxIters = 5`, the hermetic restricted interpreter, and `defaultCompactionConfig`.

---

## Configuring it

Use the defaults for long-running agents unless you have a specific reason to tune them:

```haskell
longRunConfig :: ReActConfig
longRunConfig =
  defaultReActConfig
    { maxIters = 40
    }
```

Keep more recent steps when the agent depends heavily on exact recent tool output:

```haskell
moreTail :: ReActConfig
moreTail =
  defaultReActConfig
    { maxIters = 40
    , compaction = defaultCompactionConfig { keepRecent = 8 }
    }
```

Increase the reserve when the next turn may add a large prompt or produce a large answer:

```haskell
moreHeadroom :: ReActConfig
moreHeadroom =
  defaultReActConfig
    { maxIters = 40
    , compaction = defaultCompactionConfig { reserveTokens = 32768 }
    }
```

Disable compaction when you need to reproduce pre-compaction behavior exactly:

```haskell
noCompaction :: ReActConfig
noCompaction =
  defaultReActConfig
    { compaction = defaultCompactionConfig { enabled = False }
    }
```

---

## Reactive overflow recovery

Proactive compaction is the dependable path. It uses provider-reported token usage after a
successful turn and compacts before the next request grows too large.

There is also a best-effort reactive path. If baikai classifies a provider failure as
`ContextOverflow`, shikumi maps it to:

```haskell
ContextWindowExceeded Text
```

The ReAct and CodeAct loops catch that error at both model completion sites:

- the next-action step, where the model decides whether to call a tool, run code, or finish
- the final extract step, where the trajectory is converted into the typed answer

On `ContextWindowExceeded`, the loop compacts the current trajectory and retries that
completion once. If the retry also fails, the error is rethrown. The retry is deliberately
bounded so an impossible oversized request does not loop forever.

Reactive recovery depends on provider classification. Some providers surface an oversized
request as a generic invalid request instead of `ContextOverflow`; those errors are not
caught by the compaction recovery path. Raise `maxIters` and rely on the proactive trigger
for long agents.

---

## What it is not

Working-context compaction is not persistent memory.

It does not write memories, scenes, or summaries for future sessions. It only keeps the
current agent run inside the model window. Cross-session memory belongs in the memory layer,
not in this loop.

It is also not exact token budgeting per step. `keepRecent` is a step count, not a token
count. The trigger uses real provider usage for the whole prompt, then preserves a fixed
number of recent steps and summarizes the older prefix.

---

## Testing and inspection

The deterministic `shikumi-tools` test suite exercises the behavior without network access:

```bash
nix develop -c cabal test shikumi-tools --test-options='--pattern Compaction'
```

The tests cover:

- threshold behavior around `contextWindow - reserveTokens`
- `compactTail` folding older items into one summary
- a tiny-window ReAct run that compacts and completes
- one-shot recovery after `ContextWindowExceeded`
- final extract recovery
- retry failure propagation
- CodeAct usage-triggered compaction and reactive overflow recovery

For manual inspection, run an agent with `reactWithTrajectory` instead of `react`; the
returned `Trajectory` will show any synthetic summary step alongside the real recent steps.
For CodeAct, use `codeActWithTrajectory`.
