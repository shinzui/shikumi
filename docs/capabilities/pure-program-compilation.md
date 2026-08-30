---
title: "Pure program compilation and shape-safe state"
type: Capability
description: "Transform typed Programs into zero-shot, few-shot, chain-of-thought, or retrieval-augmented variants and persist compiled parameters with a structural shape fingerprint."
generated:
  by: codex/gpt-5
  at: "2026-08-30T20:48:38Z"
capabilityId: CAP-15
provider: mori://shinzui/shikumi
status: shipped
stability: experimental
since: "0.1.0.0"
packages:
  - shikumi-compile
interface:
  - Shikumi.Compile
  - Shikumi.Compile.ZeroShot
  - Shikumi.Compile.FewShot
  - Shikumi.Compile.ChainOfThought
  - Shikumi.Compile.RAG
  - Shikumi.Compile.Retriever
  - Shikumi.Compile.Serialize
requires:
  - CAP-2
evidence:
  - kind: test
    resource: shikumi-compile/test/Main.hs
    proves: Every compiler transformation changes the intended prompts, RAG ranks and persists context, state round-trips, and mismatched or legacy shapes are rejected.
  - kind: guide
    resource: docs/user/evaluation-and-optimization.md
    proves: Compilation, retrieval, and compiled-state loading are documented as pure transformations over Program values.
---

# Pure program compilation and shape-safe state

`shikumi-compile` rewrites a [Program](composable-program-values.md) without
running it. Consumers can install explicit instructions, inject typed few-shot
demonstrations, wrap reasoning, or retrieve and persist context for RAG. The
result remains the same `Program i o` type and runs under the ordinary runtime.

`encodeCompiled` stores a structural fingerprint plus the parameter state;
`decodeCompiledOnto` applies it only to a matching typed template. This rejects
the wrong program shape and legacy bare parameter arrays instead of silently
misaddressing nodes.

## Limits

- Compiled JSON stores state, not executable Haskell closures. Loading always
  requires the corresponding program template in code.
- The built-in retriever is an in-process abstraction; production indexing and
  corpus lifecycle remain consumer concerns.
- Shape-changing compiler upgrades can require re-encoding artifacts, and those
  breaks are recorded in the package changelog.
