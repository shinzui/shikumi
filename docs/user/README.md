# Shikumi — User Guide

**Typed language-model programs you can compose, evaluate, optimize, and replay.**

Shikumi connects structured predictions, probability-backed decisions, typed
pipelines, and agents through `Program i o`. This guide explains how to build
those programs, run them, measure their behavior, and persist improvements.

## Start here

| Guide | What it covers |
|---|---|
| [Getting started](getting-started.md) | Build the repository, run offline examples, and write a typed prediction. |
| [When to use shikumi](when-to-use-shikumi.md) | Choose between a direct provider call and a typed program, including Jev decisions. |
| [Core concepts](concepts.md) | `Field`, `Signature`, `Program`, errors, and probability evidence. |
| [Decisions and calibration](decisions-and-calibration.md) | A complete offline decision example, threshold tuning, ReAnchor, metrics, and persistence. |

## Programs and execution

| Guide | What it covers |
|---|---|
| [Signatures and schemas](signatures-and-schemas.md) | Schema derivation, validation, native/fallback/XML adapters, images, and decision evidence. |
| [Programs and combinators](programs-and-combinators.md) | Prediction and capture nodes, composition, concurrency, refinement, parameters, and serialization. |
| [Effects and runtime](effects-and-runtime.md) | Routing, scoped defaults, retries, rate limits, budgets, billing observers, streaming, and Responses workflows. |
| [Caching, tracing, and replay](caching-tracing-replay.md) | Cache identity and backends, node traces, replay, billing, and reusing decision evidence. |
| [Evaluation and optimization](evaluation-and-optimization.md) | Datasets, metrics, compilation, node-local demos, GEPA objectives, structure search, and ReAnchor. |
| [Program documentation](program-documentation.md) | Generate an Open Knowledge Format bundle from a program manifest. |
| [CLI](cli.md) | Repository workflows for evaluation, recording, tracing, optimization, and replay. |

## Tools and agents

| Guide | What it covers |
|---|---|
| [Tools and agents](tools-and-agents.md) | Typed tools, filesystem/shell/web tools, ReAct, Program of Thought, and CodeAct. |
| [Resumable ReAct sessions](resumable-react-sessions.md) | Completed-turn checkpoints, rich outputs, typed final submissions, and continuation guards. |
| [Working-context compaction](agent-context-compaction.md) | Compact older steps and recover from classified context-window overflow in long agent runs. |
| [Recursive language-model sessions](recursive-language-model-sessions.md) | Bounded searches, slices, stored values, and subqueries over documents outside the prompt. |

## The program model

Record types describe the input and output contract. A signature adds instructions
and demonstrations; `predict` turns it into a program:

```haskell
summarize :: Program Article Summary
summarize = predict (mkSignature "Summarize the article.")
```

`Program i o` carries no effect-row constraint. Its runners return an `Eff es o`
computation; interpreters choose the provider and install policies such as routing,
caching, tracing, and budgets. Additional runners support concurrency, node
observation, and streaming. Since `shikumi 0.5.1.0`, decision streaming shares
the complete runner's calibrated results and delivers atomic status events.

Prediction-node parameters include instructions, demonstrations, and per-field
decision settings. Optimizers search those parameters; structure search selects
among a finite registry of typed implementations. Saved artifacts contain state
and structural metadata, with executable closures retained in your code template.

Framework functions name narrow effects such as `LLM`, `Time`, `Prim`, and
`Concurrent`; I/O is discharged at runtime and storage boundaries. See
[effects as a capability ledger](effects-and-runtime.md#effects-as-a-capability-ledger).

The APIs are experimental. The [capability catalog](../capabilities/index.md)
records shipped behavior, package ownership, release provenance, evidence, and
limits; ongoing plans are separate from shipped capabilities.
