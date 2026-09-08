---
title: "Typed program structure registries"
type: Capability
description: "Declare a finite, validated registry of alternative typed program implementations sharing one input and output schema, and serialize a selection as a versioned artifact that restores to the same program."
generated:
  by: claude/opus-5
  at: "2026-09-08T19:15:51Z"
capabilityId: CAP-31
provider: mori://shinzui/shikumi
status: shipped
stability: experimental
since: "0.2.1.0"
packages:
  - shikumi-compile
interface:
  - Shikumi.Compile.Structure
  - Shikumi.Compile.Structure.Serialize
requires:
  - CAP-15
evidence:
  - kind: test
    resource: shikumi-compile/test/StructureSpec.hs
    proves: Registries reject duplicate recipe identities and schema mismatches, and a serialized version-1 artifact restores only against a matching registry id, revision, schema, and program shape.
  - kind: guide
    resource: docs/user/evaluation-and-optimization.md
    proves: Documents how a structure registry is declared and how a selected structure is persisted and restored.
---

# Typed program structure registries

A `StructureRegistry` names a *finite* set of alternative implementations —
`StructureRecipe` values — that all satisfy the same input and output schema.
Where [CAP-15 pure program compilation and shape-safe state](pure-program-compilation.md)
persists the parameters of one program shape, this persists *which shape was
chosen* among a declared set.

Registry construction is validated: recipe identities must be unique and every
recipe's schemas must agree with the registry's declared input and output
schemas. A selection serializes as a distinct version-1 artifact carrying the
registry id, the recipe id, its revision, and the schema and shape it was
validated against. Restoring checks all of these, so an artifact cannot be
loaded against a registry that has since changed meaning.

Identity is deliberately a caller-owned contract. The registry cannot inspect a
recipe's opaque code, so **advance a recipe's revision whenever its signatures,
reducers, or implementation change**. A stale revision is the one way to make a
restore wrong, and the type system cannot catch it for you.

## Limits

- Finite and trusted. Recipes are supplied by the program author; this is not a
  search over arbitrary generated programs.
- Revision correctness is the caller's responsibility, as above.
- Structure artifacts are separate from compiled parameter state; restoring a
  structure does not restore parameters, and existing compiled state is
  unchanged by this addition.
- Experimental artifact format at version 1.
