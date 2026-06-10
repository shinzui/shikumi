# Effects & the runtime — under the covers

This guide explains the engine room: the provider-neutral **`LLM` effect**, the **resilience
interpreter** (retries / rate-limit / budget), how you **assemble an effect stack**, and the
design principle that **shikumi's framework code never carries `IOE`** — only the bottom
interpreter touches `IO`.

Shikumi is built on [`effectful`](https://hackage.haskell.org/package/effectful), a Haskell
effect system. If you have not met it: an effect like `LLM` is a capability that appears in a
type as `LLM :> es` ("this code may issue LM calls"); an *interpreter* discharges the effect,
turning `Eff (LLM : es) a` into `Eff es a`. Stacking interpreters is how you compose behaviour.

---

## The `LLM` effect — integration point #1

Every model call in the whole framework goes through one effect with two operations:

```haskell
data LLM :: Effect where
  Complete :: Model -> Context -> Options -> LLM m Response
  Stream   :: Model -> Context -> Options -> LLM m [AssistantMessageEvent]

complete :: LLM :> es => Model -> Context -> Options -> Eff es Response
stream   :: LLM :> es => Model -> Context -> Options -> Eff es [AssistantMessageEvent]
```

`complete` is a blocking completion; `stream` returns the assembled list of typed events.
Every later layer — caching, tracing, replay — *re-interprets these same two operations*.
That is the whole reason this effect exists: it is the single seam everything else hooks.

### Bare interpreters

```haskell
runLLM     :: (IOE :> es, Error ShikumiError :> es) => Eff (LLM : es) a -> Eff es a
runLLMWith :: (IOE :> es, Error ShikumiError :> es) => ProviderRegistry -> Eff (LLM : es) a -> Eff es a
```

These map baikai's `BaikaiError` into `ShikumiError` (via `fromBaikaiError`) and add **no
policy**. `runLLM` uses baikai's process-global registry; `runLLMWith` takes an explicit one
(tests do this for isolation). Each is written *in terms of* baikai's `Baikai` transport
effect, not baikai's raw `IO` functions — which is why `IOE` appears here, at the discharge
edge, and not in the framework code above it.

---

## Resilience: retries, rate-limit, budget

The production interpreter `runLLMResilient` adds exactly the features baikai deliberately
omits:

```haskell
runLLMResilient :: (IOE :> es, Concurrent :> es, Error ShikumiError :> es) => LLMConfig -> Eff (LLM : es) a -> Eff es a

data LLMConfig = LLMConfig
  { retryPolicy :: RetryPolicy
  , budget      :: Maybe Budget        -- Nothing = unlimited cost
  , rateLimit   :: Maybe RateLimiter   -- Nothing = unbounded concurrency
  , registry    :: ProviderRegistry
  }

defaultLLMConfig :: ProviderRegistry -> LLMConfig   -- default retries, no budget, no rate limit
```

Each operation is wrapped, outermost to innermost, by:

```
budget check  →  rate-limit acquire  →  retry loop  →  the Baikai transport call
```

- **Budget** (`Maybe Budget`). An optimistic pre-call gate: if the running US-dollar total has
  already reached the ceiling, the call is refused with `BudgetExceeded`. After a successful
  call, its cost (read from baikai's `Usage.cost.usd`) is charged. Reserved once before
  attempts, charged once after success — retries don't double-charge.
- **Rate limiter** (`Maybe RateLimiter`). A counter of permits bounding *in-flight* calls;
  build it once with `newRateLimiter n` and store it in the config (not per call). Acquired and
  released on every exit path.
- **Retry** (`RetryPolicy`). Exponential backoff, but **only for transient errors**
  (`isTransient`: `ProviderFailure`, `Timeout`). Deterministic errors (decode, schema,
  validation, budget) propagate immediately without consuming a retry.

```haskell
data RetryPolicy = RetryPolicy { maxAttempts :: Int, baseDelayMs :: Int, maxDelayMs :: Int }
defaultRetryPolicy = RetryPolicy { maxAttempts = 3, baseDelayMs = 200, maxDelayMs = 5000 }
```

> **Two retries, two levels.** The `retry` *combinator* (program level) re-runs a whole
> sub-program on any/selected `ShikumiError`. The resilience *interpreter* (transport level)
> retries a single transport call on transient errors only. They compose: a program-level
> retry can wrap a transport that is itself retrying.

---

## Assembling a stack

A run is the program interpreted bottom-up through a stack of interpreters you choose. The
canonical shapes:

### Minimal (offline / tests)

```haskell
runEff . runErrorNoCallStack @ShikumiError . runStubLLM stub
  $ runProgram summarize article
```

### Real provider, resilient

```haskell
main = do
  OpenAIApi.register
  let cfg = defaultLLMConfig globalProviderRegistry
  result <-
    runEff . runErrorNoCallStack @ShikumiError . runConcurrent . runLLMResilient cfg
      $ runProgram summarize article
  case result of
    Right s  -> print s
    Left err -> print (err :: ShikumiError)
```

### With caching and tracing stacked on top

```haskell
(result, tree) <-
  runEff . runErrorNoCallStack @ShikumiError
    . runConcurrent     -- discharge: rate limiter + concurrent executor
    . runPrim           -- discharge: runTrace's span-tree mutable cells
    . runTime           -- discharge: cache timestamps + span times
    . runTrace          -- (Prim, Time) → returns (a, TraceTree)
    . cachedLLM         -- interpose: serve cache hits, store misses
    . tracedLLM         -- interpose: open a span per LM call
    . runLLMResilient cfg
    $ runProgram summarize article
```

**Two kinds of layer.** The *discharge* interpreters (`runConcurrent`, `runPrim`, `runTime`)
satisfy the narrow capabilities the layers below need — `runTrace` now requires `(Prim,
Time)` and `runLLMResilient` requires `Concurrent`, not `IOE`. The *interpose* layers
(`cachedLLM`, `tracedLLM`) re-handle the `LLM` effect's `Complete`/`Stream` and delegate
down, so they must sit **above** `runLLMResilient`: a cache hit short-circuits before
resilience/transport ever run; a miss falls through. The details are in
[Caching, tracing & replay](./caching-tracing-replay.md).

---

## Ambient model routing

`runProgram` is **model-agnostic**: notice its row is just `(LLM, Error ShikumiError)` — there is
no `Model` argument and no `Model` constraint. That pinned signature never changes (every
consumer — eval, optimize, tools, the CLI — inherits it). So *which* real model each `Predict`
node dispatches against is supplied the same way `LLM` and `Error` are: by an interpreter lower
in the stack. That interpreter is `Shikumi.Routing`:

```haskell
data Routing :: Effect where
  CurrentModel :: Routing m Model

runRouting :: Model -> Eff (Routing : es) a -> Eff es a              -- supply the ambient model
routeLLM   :: (Routing :> es, LLM :> es) => Eff es a -> Eff es a     -- rewrite outgoing LLM calls
```

Pick a model **by name** from baikai's generated catalog and install the pair below `runProgram`
(`runRouting` *outer* of the real `LLM` interpreter, which is outer of `routeLLM` — the same
shape as `runTrace . runLLM… . tracedLLM`):

```haskell
import Baikai.Models.Generated (openai_gpt_4o_mini)

runEff . runErrorNoCallStack @ShikumiError . runConcurrent
  . runRouting openai_gpt_4o_mini   -- the ambient model
  . runLLMResilient cfg             -- the real LLM interpreter (or a stub)
  . routeLLM                        -- rewrites each Complete onto the ambient model
  $ runProgram summarize article
```

How it works: `runProgram` renders each node against an inert placeholder model and stamps its
*intentions* — the derived JSON schema, and any `MajorityVote` per-sample temperature — onto a
private `Options.metadata` channel. `routeLLM` reads the ambient model, overwrites the
placeholder with it, and translates those metadata keys into real wire options: for
native-capable providers (OpenAI `response_format`, Anthropic `output_config`) it sets
`Options.responseFormat = Just (JsonSchema …)` so the provider *enforces* the schema; it sets
`Options.temperature` per sample; and it strips the private keys before transport. Fallback
models simply get no `responseFormat`. Without a router installed (the offline stub path), runs
use the neutral model and the prompt-based fallback adapter — which is why the hermetic tests
and the CLI still work with no routing at all.

This is what makes
[`MajorityVote`'s `TempSchedule`](./programs-and-combinators.md#majority-vote-self-consistency)
live and native structured output actually enforced on the wire.

---

## Effects as a capability ledger

Here is the design principle that the whole runtime turns on.

Shikumi's framework code dispatches through the `LLM` effect, which is built in terms of
baikai's policy-free `Baikai` transport effect. **It therefore never carries `IOE`.** Only the
bottom interpreter (`runLLM*`, and the DB cache backends) touches `IO`. The consequence: each
program's effect row is an *honest capability ledger* — its type tells you exactly what it can
do.

```haskell
summarize :: (LLM :> es, Trace :> es, Cache :> es) => Program Article Summary
--            └──────────────── this is the whole list of things it can do ───────────────┘
```

`runProgram`'s constraint is exactly `(LLM :> es, Error ShikumiError :> es)` and nothing more.
It does not require `IOE`, `Concurrent`, or `Time`. That is deliberate (it is "integration
point #4" of the framework's design): the common path stays minimal, and you *add* a
capability only by choosing an interpreter that needs it.

### Narrow effects instead of `IOE`

`IOE :> es` means "this code may perform *arbitrary* `IO` — files, network, threads,
anything." Most framework functions need far less, and shikumi says exactly what each one
does with narrow effects:

| Effect | Means | Used for |
|---|---|---|
| `Time` | read a clock | cache-entry timestamps, trace-span times, eval latency |
| `Concurrent` | synchronize between threads (STM/MVar/`threadDelay`) | the concurrent executor, rate limiter, in-memory cache |
| `Prim` | touch in-process mutable cells (`IORef`) | usage counters, the trace-tree builder |
| `IOE` | arbitrary `IO` | **only** the genuine edges (below) |

**`IOE` survives only at the genuine-IO sites:** the SQLite/Postgres/Redis cache backends, the
baikai LLM transport interpreters, and the top-level program entry points (your `main`).
Everything else lost it — `runTrace` is now `(Prim, Time)`, the in-memory cache is
`Concurrent`, and the whole `evaluate`/`optimize` family is `(LLM, Concurrent, Error, Time,
Prim)` with no `IOE` at all. So when you read a shikumi signature, `IOE :> es` *means
something* — it flags real open-ended `IO`, not "we couldn't be bothered to be precise."

### The `Time` effect

```haskell
data Time                                            -- a small clock effect (shikumi-owned)
getCurrentTime       :: Time :> es => Eff es UTCTime  -- wall clock
getMonotonicTimeNSec :: Time :> es => Eff es Word64   -- monotonic counter
runTime              :: IOE :> es => Eff (Time : es) a -> Eff es a
```

Modeled on `time-effectful`'s `Clock`, shikumi owns it (rather than depending on that package)
because it also needs the monotonic counter for evaluation latency. A function that only times
something says `Time :> es`, not `IOE :> es`. The real `IO` permission is required exactly once,
at the discharge site `runTime`. Because it is an effect, a test can later run code against a
*fake* clock for deterministic timestamps.

> **This migration is complete.** Counter- and lock-touching helpers that once carried `IOE`
> now name `Prim` / `Concurrent`, and clock reads name `Time`. The change was internal
> signature-tightening — it did not alter the user-facing API or any design in these docs — so
> what you see above is the settled state. The discharge sites (`runPrim`, `runConcurrent`,
> `runTime`) are the only new obligation: where you used to satisfy everything with a single
> `IOE` at the base, you now also discharge the narrow effects a given stack uses (the example
> stacks above show exactly which).

---

## Streaming

`stream` / `Stream` exist for callers that need deltas; `runLLMResilient` charges streaming
cost from the terminal event's assembled message. Note that the cache and replay layers
**pass `Stream` through unchanged** (only blocking `Complete` calls are cached/replayed), so
streaming is a baikai-shaped concern — if streaming to a UI is your main job, see
[When to use shikumi](./when-to-use-shikumi.md).

---

## Where to go next

- The interpose layers in depth: [Caching, tracing & replay](./caching-tracing-replay.md).
- How evaluation threads `Time`/`Concurrent` through a run: [Evaluation & optimization](./evaluation-and-optimization.md).
