---
title: "Structure search over finite recipe registries"
type: Capability
description: "Select among a declared set of alternative typed program implementations by validation score, using the same operation admission, objectives, and shared budget as parameter optimization."
generated:
  by: claude/opus-5
  at: "2026-09-08T19:15:51Z"
capabilityId: CAP-34
provider: mori://shinzui/shikumi
status: shipped
stability: experimental
since: "0.3.0.0"
packages:
  - shikumi-optimize
interface:
  - Shikumi.Optimize.Structure
requires:
  - CAP-31
  - CAP-33
evidence:
  - kind: test
    resource: shikumi-optimize/test/StructureSpec.hs
    proves: structureSearchWith evaluates every registry recipe on validation data under one shared budget, selects by the named objective, and reports the winning recipe's identity and revision.
  - kind: example
    resource: shikumi-jitsurei/app/StructureSearch.hs
    proves: A runnable search picks between alternative program structures and persists the winner as a restorable artifact.
  - kind: guide
    resource: docs/user/evaluation-and-optimization.md
    proves: Documents structure search, its validation-only scoring, and how the selection is serialized.
---

# Structure search over finite recipe registries

Parameter optimization improves a program of fixed shape. `structureSearchWith`
answers the prior question: given several *different* implementations of the
same typed contract — a direct prediction, a chain-of-thought rewrite, a
retrieval-augmented variant — which one should this task use?

It takes a `StructureRegistry` from
[CAP-31 typed program structure registries](typed-structure-registries.md),
evaluates each recipe on validation data, and selects by a named objective. The
search deliberately reuses the admission, objective, and budget machinery of
[CAP-33 validated optimizer execution and lifecycle reports](validated-gepa-execution.md)
rather than introducing a second accounting scheme, so a structure search and a
parameter search consume a budget the same way and their reports read alike.

Scoring is validation-only: recipes are compared on held-out data, and the
winner is reported with the identity and revision needed to serialize it as a
restorable artifact.

## Limits

- Experimental, and finite by construction — it selects among recipes an author
  declared, and does not synthesize new program structures.
- Validation-only scoring. It selects a structure; it does not also tune that
  structure's parameters in the same pass.
- Selection is only as trustworthy as recipe revisions. An unchanged revision on
  changed code makes a persisted winner restore to something the search never
  evaluated.
- The comparison inherits the objective's blind spots; a structure that wins on
  the named metric may lose on one that was not measured.
