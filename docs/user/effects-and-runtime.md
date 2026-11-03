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
  , observer    :: Maybe LLMObserver -- optional per-attempt billing observation
  }

defaultLLMConfig :: ProviderRegistry -> LLMConfig   -- default retries, no budget, no rate limit
```

Each operation is wrapped, outermost to innermost, by:

```
budget check  →  rate-limit acquire  →  retry loop  →  the Baikai transport call
```

- **Budget** (`Maybe Budget`). An optimistic pre-call gate: if the running US-dollar total has
  already reached the ceiling, the call is refused with `BudgetExceeded`. Each response or stream terminal charges its reported cost (baikai's
  `Usage.cost.usd`) before success or failure is raised, once per observed attempt.
  Admission is optimistic, once before retries; it does not reserve money.
- **Rate limiter** (`Maybe RateLimiter`). A counter of permits bounding *in-flight* calls;
  build it once with `newRateLimiter n` and store it in the config (not per call). Acquired and
  released on every exit path.
- **Retry** (`RetryPolicy`). Exponential backoff, but **only for transient errors**
  (`isTransient`: typed `RateLimited` and `TransientError`, legacy `ProviderFailure`,
  and `Timeout`). Other errors propagate immediately without consuming a retry.

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

Use `summarizeP` from the getting-started guide and an `article :: Article`:

```haskell
import Baikai qualified as B
import Baikai.Models.Generated qualified as Models
import Baikai.Provider.OpenAI.Api (openaiChatProvider)

main = do
  registry <- B.newProviderRegistry
  B.registerApiProviderWith registry openaiChatProvider
  let cfg = defaultLLMConfig registry
  result <-
    runEff . runErrorNoCallStack @ShikumiError . runConcurrent
      . runRouting Models.openai_gpt_4o_mini
      . runLLMResilient cfg
      . routeLLM
      $ runProgram summarizeP article
  case result of
    Right s -> print (unField (headline s))
    Left err -> print err
```

The explicit registry supplies transport handlers; `runRouting` supplies the
ambient model, and `routeLLM` realizes that choice before transport. Supply provider
credentials through its usual environment or transport options. This prints the
headline using the record selector and `unField` from the getting-started guide.

### With caching and tracing

Create the memory backend and put logical tracing before cache lookup in request
execution order. This fragment uses `cfg` and the model from the provider example:

```haskell
cache <- newMemoryCache
(result, tree) <-
  runEff
    . runPrim
    . runTime
    . runConcurrent
    . runTrace
    . runErrorNoCallStack @ShikumiError
    . runRouting Models.openai_gpt_4o_mini
    . runCacheMemory cache
    . runLLMResilient cfg
    . cachedLLM
    . tracedLLM
    . routeLLM
    $ runProgram summarizeP article
```

Import cache operations from `Shikumi.Cache` and
`Shikumi.Cache.Backend.Memory`, tracing from `Shikumi.Trace`, routing from
`Shikumi.Routing`, `runPrim` from `Effectful.Prim`, and `runTime` from
`Shikumi.Effect.Time`. The result is `(Either ShikumiError Summary, TraceTree)`;
putting the error handler inside tracing retains a tree when the program fails.

The discharge interpreters install their effects. The `tracedLLM`, `cachedLLM`,
and `routeLLM` wrappers interpose on `LLM` while its base interpreter is active.
Although composition reads right to left, the request travels through routing,
logical tracing, cache lookup, and then the resilient transport. A cache hit is
still a logical traced call and does not reach the provider. See
[caching, tracing, and replay](caching-tracing-replay.md).

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

`streamProgram` supports generative prediction, typed judgments and progress
reporting. Since `shikumi 0.5.1.0`, judgments share complete-call settings and
decoding; TypeSafe supplies an atomic structured answer.

At the transport level, `stream` / `Stream` exist for callers that need deltas;
`runLLMResilient` charges streaming cost from the terminal event's assembled message. The cache
layer passes `Stream` through unchanged. Structured trace recordings can replay
atomically through either operation since `shikumi-trace 0.3.2.0`; text streams
keep usage-only capture.

On top of that, `Shikumi.Stream` exposes streaming **at the program level** — a separate,
additive entry point that does not touch `runProgram`:

```haskell
streamProgram :: (LLM :> es, Error ShikumiError :> es)
              => Program i o -> i -> (StreamEvent -> Eff es ()) -> Eff es o

data StreamEvent = StreamFieldChunk FieldChunk | StreamStatus Status
data FieldChunk  = FieldChunk { fieldName :: Text, chunk :: Text, isLast :: Bool }
data StatusPhase = LmStart | LmEnd | ToolStart | ToolEnd | NodeStart | NodeEnd
```

You hand `streamProgram` a program, an input, and a callback; it invokes the callback once per
event, in order, as execution proceeds, and **still returns the fully-decoded typed `o`** —
identical to what `runProgram` would return for the same input. The effect row is exactly
`runProgram`'s plus the callback, so a streamed program runs under the same interpreters as a
blocking one (the callback runs in *your* `Eff`, so you can print, accumulate into an `IORef`,
or push to a channel).

Two kinds of event reach the callback:

- **Field chunks** — a piece of an output field's text as the model writes it. Honestly scoped
  to a single `Predict` node (and chains of them) on the prompt-fallback / raw-text path;
  native whole-JSON field chunking is *not* promised (a JSON blob is only parseable once whole).
- **Status messages** — "LM call started/finished", "tool started/finished", "node
  started/finished". Status brackets every node, including composites; aggregating combinators
  (`Map`/`Parallel`/`MajorityVote`/`Ensemble`) and opaque `Embed` bodies stream status only.

`runProgram`'s blocking contract is untouched — `streamProgram` is parallel surface over the
same decode. (The headline live demo, streaming a program against a real routed provider, rides
on ambient routing above; the machinery is fully demonstrable against a stub event source with
no network.)

```bash
cabal run jitsurei-streaming   # field chunks + status events, then the typed answer — offline
```

---

## Where to go next

- The interpose layers in depth: [Caching, tracing & replay](./caching-tracing-replay.md).
- How evaluation threads `Time`/`Concurrent` through a run: [Evaluation & optimization](./evaluation-and-optimization.md).

## Provider failures and refusals

`ProviderError BaikaiError` retains the transport record, including an optional,
verbatim `refusalCategory`. Match it to inspect structured failures, and use
`renderShikumiError` for readable diagnostics. The new public sum constructor
requires consumers with exhaustive `ShikumiError` matches to add a branch (a PVP
major-version change when released).

Blocking and streamed errors use `fromBaikaiError`: decode failures, invalid
requests and context overflow retain their existing `InvalidJSON`, `SchemaMismatch`
and `ContextWindowExceeded` mappings. Other categories preserve the original
record in `ProviderError`. Content refusals, authentication errors, unavailable
providers, unclassified process exits and unknown errors are terminal. Only typed
rate limits and transient transport errors retry; no classification is guessed
from message text or refusal-category strings.

Caller-created `ProviderFailure Text` remains retryable for compatibility. A
malformed third-party `EventError` without `errorInfo` uses this legacy fallback,
with its message or stop reason. Failed partial output is never returned as a
successful response. Host exceptions and cancellation continue to escape; only
transport `BaikaiError` values enter this mapping. GEPA's default failure scoring
continues to abort on provider infrastructure failures. See
[ADR-11](../adr/0011-preserve-provider-errors-and-centralize-retry-policy.md).

## Shared request defaults

Import `Shikumi.LLM.Defaults` and scope a run with `withRequestDefaults`.
`RequestDefaults` contains only `defaultThinking`, `defaultSpeed`,
`defaultMaxTokens` and `defaultEvidence`, each optional. `emptyRequestDefaults`
changes nothing. Explicit options win over defaults; an inner scope wins over an
outer scope. Evidence requests override as a complete object. A zero default
token ceiling raises `ValidationFailure` before the scoped action runs.

Defaults cover both blocking and streaming calls, including agent proposals,
repairs, summaries and recursive subqueries. They preserve temperatures, schemas,
tool choices, credentials and continuation metadata. They do not select a model
or change the router's policy: use defaults without ambient routing when requests
already carry distinct sub-models. Independent concurrent runs share no settings.
Defaults are runtime configuration and do not change Program or Params encoding.

The compiled offline example in
[`RequestDefaults.hs`](../../shikumi-jitsurei/app/RequestDefaults.hs) uses this stack:

```haskell
runEff . runPrim . runTime . runConcurrent . runTrace
  . runErrorNoCallStack @ShikumiError . runRouting emptyModel . runCacheMemory cache
  . runStubLLM (const validAnswerResponse) . captureLLMRequests calls . cachedLLM . tracedLLM
  . withRequestDefaults defaults . routeLLM
  $ runProgram instructedProg question
```

The rightmost wrapper handles a call first: routing validates continuation, then
defaults fill missing options, then trace/cache see the effective request. The
production base interpreter validates continuation again and strips private
metadata before transport. Run the complete example with:

```bash
nix develop .#ghc9124-ci --command cabal run jitsurei-request-defaults
```

It makes three typed runs and two base calls: the ordinary repeat is cached; the
evidence-requesting run bypasses cache. Requested high thinking or fast speed
never proves that the provider used it. Translation and evidence strength remain
owned by `mori://shinzui/baikai/docs/model-call-evidence`; unsupported preferences
are handled by the provider. The offline example supplies no provider evidence.

## A complete Responses workflow

Run the compiled example with a loopback server and a dummy credential:

```bash
nix develop .#ghc9124-ci --command cabal run exe:jitsurei-responses
```

The implementation in [Responses.hs](../../shikumi-jitsurei/app/Responses.hs)
registers the released Responses adapter separately from Chat Completions:

```haskell
import Baikai qualified as B
import Baikai.Provider.OpenAI.Responses (openaiResponsesProvider)

registry <- B.newProviderRegistry
B.registerApiProviderWith registry openaiResponsesProvider
```

Its default mode needs no provider credentials and contacts only an ephemeral
127.0.0.1 server. It executes a typed program, runs one lookup tool, serializes a
completed-turn checkpoint through JSON bytes, resumes, and validates the final
answer. It prints `tool executions: 1`, `logical usage:`, `transport billing:`,
and `opaque continuation sent on resume: True`.

An optional public-provider run requires all three explicit inputs:

```bash
SHIKUMI_RESPONSES_LIVE=1 nix develop .#ghc9124-ci --command cabal run exe:jitsurei-responses -- --live --model "$SHIKUMI_RESPONSES_MODEL"
```

Set `OPENAI_API_KEY` and `SHIKUMI_RESPONSES_MODEL` yourself before that command.
The executable looks up the exact OpenAI model ID in `Baikai.Models.Generated.allModels`
and selects `OpenAIResponses`; catalog membership alone does not guarantee current
account access or endpoint support. It makes no automatic retries, caps output at
256 tokens and the agent at three iterations, and uses 15-second request and
65-second run timeouts. Credentials and timeouts remain runtime configuration.
The live switch is separate from `SHIKUMI_LIVE` and never runs in normal CI.
A successful live run without opaque continuation establishes connectivity only.

The released adapter owns request translation and error classification. In
`mori://shinzui/baikai/packages/baikai-openai` version 0.7.0.0, a
`response.failed` frame with `content_filter` maps to `OtherError`, which remains
terminal. Ordinary refusal content is not guaranteed to become a typed
`ContentFiltered` error. Shikumi preserves the released classification; it does
not infer refusals from text. The loopback regression pins one HTTP attempt for
that failure even with retries enabled.

## Acknowledging actual attempt evidence

Since `shikumi 0.5.1.0`, `runLLMResilientWithEvidence` accepts an effectful
`EvidenceObserver es`; `runLLMWithEvidence` provides the same boundary for bare
calls with an explicit registry and billing observer. Keep its effects outside
the interpreter. Returning normally acknowledges each original Baikai record.

```haskell
runEff . runConcurrent . runErrorNoCallStack @ShikumiError
  . runRouting model
  . runLLMResilientWithEvidence (liftIO . persistReceipt) cfg
  . withEvidenceRuns (EvidenceRequired EvidenceModelObserved) (liftIO newCallId)
  . routeLLM
  $ runProgram program input
```

Here `persistReceipt :: AttemptReceipt -> IO ()` is application-owned storage.
`withEvidenceRuns` mints a run per LLM operation, above retries; explicit request
options win. Retry records increment the caller's base attempt and supersede the
latest provider-built call ID. `logicalCallId` and `attemptOrdinal` correlate with
billing observations; persist the enclosed Baikai call ID for durable identity.

Settlement is budget charge, billing observer, evidence observer, then failure,
retry or return. Typed observer errors become `EvidenceObserverFailed` exceptions;
other exceptions propagate unchanged. Neither a transport retry nor a program
`Retry` redispatches after acknowledgement fails. Observers must be thread-safe
for concurrent programs; worker-local State changes do not reach the parent.

An observer alone does not request evidence. Best-effort collection can omit a
record; required evidence is enforced by Baikai. Strict pre-dispatch refusal can
produce a receipt even though no HTTP occurred. Budget refusal, a rate-limit
waiter, cache and replay produce none. Cancellation currently produces no receipt
on the Baikai collection path; the upstream addition is tracked at
`mori://shinzui/baikai/okf/improvement-requests/concepts/IR-13`.

`AttemptReceipt` has no JSON instances. Full evidence error messages can include
provider response text; select and redact fields according to application policy.
The [Responses example](../../shikumi-jitsurei/app/Responses.hs) demonstrates the
public runner and per-operation run IDs without paid calls by default.
