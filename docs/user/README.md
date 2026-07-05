# Shikumi — User Guide

**Typed, structured, evaluable language-model programs in Haskell.**

This is the user documentation for [Shikumi](../../README.md) (仕組み — *the mechanism*).
It explains both **how to use** the framework and **how it works under the covers**, so
that nothing about it stays a black box.

If you have never seen shikumi before, read the guides in order. If you already know what
you want, jump straight to the relevant reference.

---

## Start here

| # | Guide | What it covers |
|---|---|---|
| 1 | [Getting started](./getting-started.md) | Install, write your first record-in/record-out program, run it offline. |
| 2 | [When to use shikumi (and when to use baikai directly)](./when-to-use-shikumi.md) | The decision that comes *before* any code: many good-model tasks don't need shikumi at all. |
| 3 | [Core concepts & mental model](./concepts.md) | `Field`, `Signature`, `Program`, `ShikumiError` — and the one idea that ties them together. |

## How it works under the covers

| # | Guide | What it covers |
|---|---|---|
| 4 | [Signatures & schemas](./signatures-and-schemas.md) | How a record becomes a JSON schema, how a reply becomes a typed value, the three adapters that bridge the wire (native / fallback / XML), declarative field constraints, and multimodal image input fields. |
| 5 | [Programs & combinators](./programs-and-combinators.md) | The `Program` GADT deep embedding: run it, rewrite it, serialize it. Every combinator explained — plus `twoStep` (free-form→extraction) and the reward-driven self-refinement modules (`bestOfN` / `refine` / `multiChainComparison`). |
| 6 | [Effects & the runtime](./effects-and-runtime.md) | The `LLM` effect over baikai, resilience (retries/rate-limit/budget), the effect stack, program-level streaming (`streamProgram`), and *why shikumi code never carries `IOE`*. |
| 7 | [Caching, tracing & replay](./caching-tracing-replay.md) | The `interpose` pattern, content-addressed cache keys, the span tree, and deterministic replay. |
| 8 | [Evaluation & optimization](./evaluation-and-optimization.md) | `Dataset`/`Metric`/`Report`, the compiler layer, and the nine optimizers (demo selection, instruction search, MIPROv2, COPRO, GEPA, KNN) — with serialization. |
| 9 | [Tools & ReAct agents](./tools-and-agents.md) | Typed tools, the registry, built-in work tools (`read`, `write`, `edit`, `grep`, `glob`, `bash`, `web_fetch`, `web_search`), and agent/code-execution loops that are themselves `Program`s. |
| 10 | [Agent working-context compaction](./agent-context-compaction.md) | How long ReAct and CodeAct runs compact older steps, preserve recent context, and recover from classified context-window overflow errors. |
| 11 | [The CLI](./cli.md) | `eval` / `record` / `trace` / `optimize` / `replay`, all runnable offline. |

---

## The one-paragraph mental model

You declare an LM-powered function whose **input and output are ordinary Haskell record
types**. From the *types*, shikumi derives the JSON schema sent to the provider, the
decoder that turns the reply back into a typed value, and the enumerated failure type you
get when something goes wrong. A program is a typed value — a `Program i o` — that can be
**run**, **rewritten as data** (so an optimizer can tune it), and **serialized**. Caching,
tracing, replay, retries, budgets and rate-limiting are all *interpreters you stack* over
one provider-neutral `LLM` effect, so the program code never changes when you add them.
You never write a prompt string; you write types.

```haskell
summarize :: (LLM :> es, Trace :> es, Cache :> es) => Program Article Summary
summarize = predict @Summarize
```

---

## Precise effect constraints

Shikumi uses *precise effect constraints*: instead of the broad `IOE` (arbitrary `IO`)
constraint, each function carries narrow effects that say exactly what it does — `Time` for
clock reads, `Concurrent` for thread synchronization, `Prim` for in-process mutable cells.
`IOE` now appears **only** at the genuine edges: the baikai transport interpreters, the
SQLite/Redis/Postgres cache backends, and your top-level `main`. Everything else — including
tracing, evaluation, and optimization — names its real capabilities and nothing more, so a
shikumi type signature reads as an honest capability ledger. See
[Effects & the runtime](./effects-and-runtime.md#effects-as-a-capability-ledger) for the
full story.
