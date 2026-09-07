---
type: Architecture Decision Record
title: Restore typed structures through trusted recipe registries
description: Select finite typed implementations with shared validation and restore experimental artifacts through caller-owned registry identity and revisions.
docId: ADR-8
status: Accepted
date: 2026-09-07
timestamp: 2026-09-07T14:05:00Z
generated:
  by: process:codex
  at: 2026-09-07T14:05:00Z
---

# Restore typed structures through trusted recipe registries

## Context

Program shapes omit executable closures. Equal shapes and boundary schemas cannot
prove that two reducers, signatures or embedded computations behave alike.
Structure selection must also share the admission and objective semantics used by
parameter optimization, while remaining separate from production promotion.

## Decision

`Shikumi.Compile.Structure` owns a nonempty, insertion-ordered registry of programs
sharing one input/output type pair. Smart constructors require distinct nonempty
recipe IDs, a nonempty registry ID and positive recipe revisions. Boundary schemas
come from the actual `ToSchema` dictionaries. The direct/CoT convenience registry
rejects populated parameters before rewriting; independently optimized programs
can be explicitly registered instead. Capture codecs remain template-owned and
the existing CoT compiler adapts them to reasoning/value output.

`Shikumi.Optimize.Structure` evaluates the finite registry with the shared search
session from [ADR-5](0005-own-optimizer-admission-and-diagnostic-reports-in-search-sessions.md).
Training and validation must be nonempty; this enumeration uses only validation
for scoring and never runs an inner optimizer. Candidate metadata in the shared
report and events carries registry/recipe/revision identity. Existing version-1
reports without the optional metadata map still decode. Fully evaluated eligible
candidates enter the named-objective frontier; ties retain insertion order. With
no eligible candidate, return the first recipe and explicitly report it unscored.
Concurrent physical dispatch and final-slot allocation retain ADR-5's limitations.

The version-1 `shikumi.experimental.structure` envelope contains registry ID,
recipe ID/revision, both boundary schema values, shape and ordered parameters.
Pure restoration rejects incompatible metadata before applying parameters to the
exact registered template. Existing compiled-state serialization is unchanged.
Schema comparison uses JSON value equality, not encoded object ordering.

Registry owners must advance a revision whenever implementation, signature or
reducer behavior changes, even if schemas and shape do not. Checks detect declared
incompatibility, not malicious or undeclared code replacement. Artifacts contain
no closures or source code and require the application's matching registry.
They are experimental diagnostic state, carry no promotion authority, and do not
satisfy or weaken the same-structure gate in
[production evidence optimization](../improvement-requests/production-evidence-optimization.md).

## Consequences

Applications can compare direct, chained, retrying and opaque typed programs and
restore a selected implementation without runtime source compilation. Function
identity remains a responsibility of trusted application code. Model-generated
programs, unlimited mutation and automatic promotion remain outside this API.
Compiler and optimizer structure tests cover metadata rejection, held-out winners,
partial-budget exclusion, deterministic ties and restored request/output equality.
[Plan 57](../plans/57-search-and-persist-typed-program-structures.md) records execution evidence.
