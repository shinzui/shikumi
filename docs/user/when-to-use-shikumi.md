# When to use shikumi (and when to use baikai directly)

This is the decision that comes *before* any shikumi code. **A great many LM tasks do not
need shikumi at all** — especially when you are driving a strong model that already follows
instructions well and returns clean output. Reaching for shikumi by reflex adds types,
derivations, and an effect stack you may not need.

This guide gives you a straight answer: when the raw provider call through
[baikai](../../README.md) is the right tool, and when shikumi earns its keep.

---

## The two layers

Shikumi sits *on top of* baikai. They solve different problems.

```
┌─────────────────────────────────────────────┐
│  shikumi                                      │  ← typed I/O, schema, decode,
│   Program i o · Signature · Adapter           │     caching, tracing, eval,
│   LLM effect · ShikumiError · resilience      │     compile, optimize, agents
└───────────────────────┬───────────────────────┘
                        │  (LLM effect over the Baikai transport effect)
┌───────────────────────┴───────────────────────┐
│  baikai (媒介)                                 │  ← one call shape across
│   completeRequest / streamRequest              │     Claude, OpenAI, DeepSeek,
│   Model · Context · Options · Response         │     OpenRouter, Ollama, CLIs
│   provider dispatch · model catalog · Usage    │
└─────────────────────────────────────────────────┘
```

- **baikai** is the *transport*: one `completeRequest` / `streamRequest` call that dispatches
  to any provider, with a unified `Model` / `Context` / `Options` / `Response` vocabulary,
  streaming events, a model catalog, and token/cost accounting. It deliberately omits
  structured output, retries, caching, tracing, and evaluation.
- **shikumi** adds exactly those omitted layers, and binds them to your *Haskell types*.

If what you need is "send a prompt to a model and read the text back," that is a baikai
job. Shikumi's value begins where you want the model's output to be **typed data your
program manipulates**, or where you want **caching / tracing / evaluation / optimization**.

---

## Use baikai directly when…

Call `completeRequest` (or `streamRequest`) yourself, and skip shikumi entirely, when:

- **You want free-form text out.** Chat replies, drafting, rewriting, summarization-to-prose,
  translation, "explain this" — anything whose natural output *is* prose. Forcing it through
  a record schema buys you nothing.
- **You're streaming tokens to a UI.** baikai's event stream (`TextDelta`, `EventDone`, …)
  is the right surface. Shikumi's `Program` is request/response shaped.
- **The model is strong and the task is forgiving.** A capable model asked for "a JSON object
  with these keys" usually just returns it. If a rare malformed reply is cheap to retry or
  ignore, the typed-decode guarantee isn't worth the derivation overhead.
- **It's a one-shot script or a spike.** Exploratory prompting, prompt tuning by hand, a quick
  internal tool. Add structure once the shape stabilizes, not before.
- **You need provider features shikumi doesn't surface.** Raw multi-turn conversation state,
  custom message roles, vendor-specific options, the CLI providers (`claude -p`, `codex
  exec`) — drive them through baikai directly.

The baikai call is small:

```haskell
import Baikai
import Baikai.Models.Generated qualified as Models
import Control.Lens ((&), (.~))
import Data.Vector qualified as V

main :: IO ()
main = do
  OpenAIApi.register
  prompt <- userNow "Summarize this in two sentences: …"
  let ctx  = _Context & #systemPrompt .~ Just "You are terse."
                      & #messages .~ V.singleton prompt
      opts = _Options & #maxTokens .~ Just 256
  resp <- completeRequest Models.openai_gpt_4o_mini ctx opts
  print (flattenAssistantText (flattenAssistantBlocks resp))
```

That's the whole program. No types to derive, no effect stack to assemble. See baikai's
[getting-started](../../../baikai/docs/user/getting-started.md) for the full surface.

---

## Reach for shikumi when…

Shikumi earns its keep — and the raw baikai call starts to hurt — when one or more of these
is true:

- **The output is data, not prose.** You want a `Summary`, an `Invoice`, a `Category`, a
  `Decision` — a value your program then *branches on, stores, or passes downstream*. Shikumi
  derives the schema from the type and decodes the reply back into it, so you never hand-parse
  JSON or coerce strings. A malformed reply becomes a typed `MissingField "bullets"` /
  `SchemaMismatch "…"`, not an exception buried in a string.
- **You want failure to be enumerated, not ambient.** `ShikumiError` is a closed set; every
  call returns `Either ShikumiError o`. You handle the cases the compiler shows you, instead
  of discovering them in production.
- **You're composing multiple model calls.** `extract >>> enrich >>> approve` typechecks only
  when each stage's output type equals the next stage's input type. Reorder them and it does
  not compile. Hand-wiring this with baikai means re-parsing between every stage.
- **You want caching, tracing, or replay** without rewriting the call site. They are
  *interpreters you stack* over one `LLM` effect — opt in by layering, opt out by removing.
  Doing this by hand around baikai means threading a cache map and a span tree through every
  call yourself.
- **You want to evaluate or optimize.** `Dataset`/`Metric`/`Report` give you a typed score
  over labeled data; the optimizers search for better demos and instructions and *serialize*
  the tuned program. This is the whole point of the GADT deep embedding, and there is no
  baikai-level equivalent.
- **You're building an agent.** A typed tool's argument schema is derived from its input
  record; a ReAct loop is itself a `Program`, so it composes, traces, and optimizes like any
  other. Malformed tool arguments become a typed observation the model can recover from,
  never a crash.
- **You want honest effect signatures.** A shikumi program's type is a capability ledger:
  `(LLM :> es, Cache :> es, Trace :> es)` tells you exactly what it can do. See
  [Effects & the runtime](./effects-and-runtime.md).

---

## The decision in one table

| Your situation | Use |
|---|---|
| Free-form / prose output | **baikai** |
| Streaming tokens to a UI | **baikai** |
| One-shot script, spike, manual prompt tuning | **baikai** |
| Vendor-specific options, raw conversation state, CLI providers | **baikai** |
| Output is a record your code branches on | **shikumi** |
| You need decode failures as a typed, enumerated value | **shikumi** |
| You're chaining several model calls with type-checked hand-offs | **shikumi** |
| You want caching / tracing / replay as a stackable layer | **shikumi** |
| You want to evaluate against data or optimize the program | **shikumi** |
| You're building a tool-using agent | **shikumi** |

> **Rule of thumb.** If you would otherwise write code that *parses the model's text into a
> data structure* — or that you want to *cache, trace, evaluate, or improve* — shikumi
> replaces that code with derivations and stackable interpreters. If you just need the text,
> use baikai and move on.

---

## It is not all-or-nothing

Because shikumi's `LLM` effect is built *in terms of* baikai's transport, the two coexist
cleanly. Common hybrids:

- **Mostly baikai, shikumi for the structured bits.** Stream chat through baikai; when you
  need to extract structured fields from a turn, run a small `predict` program on that text.
- **Mostly shikumi, baikai for the escape hatch.** Build your typed pipeline in shikumi, but
  drop to a raw baikai call inside an [`embed`](./programs-and-combinators.md#embed) node when
  you need a provider feature shikumi doesn't expose — the `embed` node is still a first-class
  `Program`, so it composes and traces.

You are never locked into the wrong layer. Start at the lowest layer that meets the need and
move up only when a concrete requirement (typed data, composition, caching, eval, agents)
pulls you there.
