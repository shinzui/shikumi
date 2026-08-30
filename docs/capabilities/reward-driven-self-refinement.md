---
title: "Reward-driven inference-time self-refinement"
type: Capability
description: "Wrap a typed Program with best-of-N sampling, critique-and-retry refinement, or multi-chain synthesis driven by an explicit reward function."
generated:
  by: codex/gpt-5
  at: "2026-08-30T20:48:38Z"
capabilityId: CAP-7
provider: mori://shinzui/shikumi
status: shipped
stability: experimental
since: "0.1.0.0"
packages:
  - shikumi
interface:
  - Shikumi.Refine
  - Shikumi.Reward
requires:
  - CAP-2
  - CAP-4
evidence:
  - kind: test
    resource: shikumi/test/RefineSpec.hs
    proves: Best-of-N, critique-guided refinement, threshold short-circuiting, temperature spreading, and best-so-far recovery follow their reward contracts.
  - kind: test
    resource: shikumi/test/ModuleSpec.hs
    proves: Chain-of-thought modules return typed output, expose parameters, and enforce output validation.
  - kind: guide
    resource: docs/user/programs-and-combinators.md
    proves: The reward vocabulary and three inference-time refinement modules are documented with their composition semantics.
---

# Reward-driven inference-time self-refinement

Consumers define a `Reward o` and wrap an existing program with one of three
ordinary program modules. `bestOfN` samples and keeps the highest-scoring output;
`refine` asks a model to critique a weak output before another attempt; and
`multiChainComparison` synthesizes several reasoning chains into one typed
answer. Each module composes because it is built as a normal embedded
[Program](composable-program-values.md), not as a separate runtime.

## Limits

- A reward is application-supplied and only as trustworthy as its scoring rule.
- Refinement makes additional LM calls and therefore remains subject to the
  retry, routing, and optimistic budget semantics in
  [CAP-4](resilient-runtime-routing.md).
- Embedded refinement nodes carry no independently tunable `Params`; optimize
  the wrapped prediction nodes or use the optimizer package for training-time
  search.
