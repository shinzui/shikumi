---
title: "Composable and rewritable program values"
type: Capability
description: "Represent LM workflows as typed Program values that compose, execute sequentially or concurrently, expose parameters, and serialize their closure-free shape."
generated:
  by: codex/gpt-5
  at: "2026-08-30T20:48:38Z"
capabilityId: CAP-2
provider: mori://shinzui/shikumi
status: shipped
stability: experimental
since: "0.1.0.0"
packages:
  - shikumi
interface:
  - Shikumi.Program
  - Shikumi.Module
  - Shikumi.Combinator
requires:
  - CAP-1
evidence:
  - kind: test
    resource: shikumi/test/ProgramAcceptanceSpec.hs
    proves: A typed two-stage program executes and a parameter rewrite changes only the addressed node and its wire prompt.
  - kind: test
    resource: shikumi/test/CombinatorSpec.hs
    proves: Pipelines, maps, parallel branches, retries, validation, voting, ensembles, parameter traversal, and structural serialization obey their contracts.
  - kind: example
    resource: shikumi-jitsurei/app/Compose.hs
    proves: A complete typed pipeline composes stages whose intermediate types are checked by Haskell.
---

# Composable and rewritable program values

`Program i o` is a typed GADT that is both runnable code and inspectable data.
Consumers build predictors, chain-of-thought and two-step modules, then compose
them with pipelines, bounded maps, parallel branches, retries, validation,
majority voting, and ensembles. Incompatible stages do not type-check.

`runProgram` gives deterministic sequential semantics; `runProgramConc` opts
into concurrency for independent branches. A lawful parameter traversal exposes
each prediction node's instruction and demonstrations for compilers and
optimizers. `ProgramShape` and parameter vectors serialize the structural state
while leaving functions and effectful closures in the Haskell template.

This capability builds on the typed contract in
[CAP-1](typed-signatures-and-schemas.md).

## Limits

- Serialized state is not executable by itself. The consumer reconstructs the
  typed program template in code and applies the saved parameters.
- Functions captured by mapping, validation, reduction, and embedded nodes are
  intentionally represented only by opaque shape markers.
- Concurrency is an interpreter choice and can oversubscribe an optimistic LM
  budget; the runtime documents that trade-off explicitly.
