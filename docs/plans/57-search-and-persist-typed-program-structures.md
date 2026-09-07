---
id: 57
slug: search-and-persist-typed-program-structures
title: "Search and persist typed program structures"
kind: exec-plan
intention: intention_01m1y2eqrxejrvsm24hybv6tsp
created_at: 2026-09-07T01:50:19Z
master_plan: "docs/masterplans/10-dspy-informed-optimizer-and-agent-evolution.md"
---

# Search and persist typed program structures


This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current during implementation. Distill durable decisions into docs/adr/ before completion.

## Purpose / Big Picture


Users will compare a finite collection of typechecked language-model program structures, select one against held-out examples and explicit resource limits, save it, and restore it using the same registered implementations. An example will compare a direct predictor with a reasoning predictor, select the better validation result, and restore its behavior from an artifact. This delivers useful structure search inspired by whole-program optimization without compiling model-written Haskell.

## Progress


- [x] (2026-09-07) Read plan/specification and confirmed plan 53 shared execution is implemented. Created the requested Rei intention.
- [x] (2026-09-07) Milestone 1: typed registry and compiler tests pass (20 tests at this milestone).
- [x] (2026-09-07) Milestone 2: shared bounded structure selection, deterministic ties, exact-cap queued-work guard and nested stream/ensemble coverage; 131 optimizer tests pass.
- [x] (2026-09-07) Milestone 3: pure restore checks, compatible demo/request round-trip (22 compiler tests), and winning search output/request round-trip all pass.
- [x] (2026-09-07) Milestone 4: example selects cot at 4/8 operations and restores identical output/requests; workflow docs, changelogs and ADR-8 written; strict ADR check passes.
- [ ] Final formatted-tree validation and workspace build.

## Surprises & Discoveries


Plan 53 already provides the generic session, objective selection and observed runner required here. No GEPA extraction was needed. Its report lacked caller identity metadata; an optional candidate-metadata map and lifecycle event now carry registry/recipe/revision identity while older version-1 JSON without that map still decodes.

Final review found that queued work could begin after the previous candidate consumed the exact operation cap. The shared `canStartCandidate` guard leaves those reservations unexecuted and reports budget stop without invalidating a candidate that already completed. A regression checks a two-operation baseline followed by an untouched reservation; the nested stream/ensemble regression separately proves interruption within an executing recipe.

## Decision Log


2026-09-06: Use a finite caller-supplied registry of typed candidate programs with stable recipe IDs and revisions. Each entry has the same input/output types, enforced by Haskell. Candidate topology can differ, while opaque functions remain implementations in application code. Serialized recipes identify those implementations and never contain closures or executable source.

2026-09-06: Depend on `docs/plans/53-add-validated-multi-objective-gepa-execution-and-lifecycle-events.md` for evaluation, reports/events, validation splits, objective semantics and actual LLM-operation budgeting. Do not build a competing budget or event system. Candidate enumeration is deterministic; model-generated structure proposals and unbounded recursive mutation are excluded.

2026-09-06: Keep existing compiled-state serialization unchanged and add an explicitly versioned structure artifact. Shape equality does not prove two opaque functions implement the same behavior, so recipe revisions and caller-owned registry identity are part of the restore contract.

2026-09-07: Keep identity wrappers and registry constructors opaque, with ordinary accessor functions rather than exported record labels that allow updates. Use the shared `scoringCost` estimate for predicted work and actual session admission for the hard ceiling. Evaluate only validation; training is required and validated but this finite enumeration has no training phase.

2026-09-07: Use additive optional metadata on shared version-1 reports, plus a metadata lifecycle event, without changing candidate numeric IDs or GEPA evaluation. Candidate metadata contains declared identities only. Record the durable registry/artifact and execution contract in [ADR-8](../adr/0008-restore-typed-structures-through-trusted-recipe-registries.md).

## Outcomes & Retrospective


All four feature milestones are implemented. The example has printed the configured CoT winner at 4/8 admitted operations and `True` for restored output/request equality. The compiler suite passes 22 tests and the optimizer suite passes 131 tests. Final formatted-tree validation remains before completion; no release or production promotion is performed.

## Context and Orientation


`shikumi/src/Shikumi/Program.hs` defines the typed `Program i o` tree. `Predict` performs a model call; `Compose` connects matching intermediate types; `FMap` holds a Haskell function; other constructors represent retries, parallel work, maps, ensembles and opaque embedded computations. The GADT, a datatype whose constructors constrain type parameters, ensures a constructed program's input/output types line up. `programShape` records structure without functions and `programParams` records instructions/demonstrations. Neither is a complete executable serialization.

`shikumi-compile/src/Shikumi/Compile/Types.hs` defines pure `Compiler` rewrites and `CompiledProgram`. `shikumi-compile/src/Shikumi/Compile/Serialize.hs` saves shape and parameters and loads only onto an already matching code template. `shikumi-compile/src/Shikumi/Compile/ChainOfThought.hs` provides a typed rewrite that wraps every prediction with a reasoning output and projection. Its current preservation of demos means applying it to an already populated plain predictor may fail decoding; the helper introduced here must clear affected demonstrations explicitly.

`shikumi-optimize/src/Shikumi/Optimize/Search.hs` currently estimates ordinary candidate cost from prediction-node count. Retries, ensembles and `Embed` can exceed that prediction. Plan 53 is a hard prerequisite: its actual dispatch admission must govern this plan's search and its shared report must expose rejected/incomplete candidates. Do not claim a hard cap by post-hoc counting. `shikumi-optimize/src/Shikumi/Optimize/Types.hs` currently describes mainly parameter search, with documented ensemble and KNN exceptions; update this documentation for the new additive structure API. Tests live in the respective package test directories and are registered in their Cabal files. [ADR-1](../adr/0001-use-profile-governed-architecture-decisions.md) now governs decision records: allocate stable ADR-N handles, preserve decision/provenance metadata, update the bundle index/log, and run `just check-adr`. No earlier feature-specific ADR was found during the initial review. `docs/plans/9-compiler-layer.md` supplies historical compiler/serialization context, repeated here where needed.

Upstream provenance is `mori://stanfordnlp/dspy`, commit `f70d08a5b934400d236078143e3704934f2d5dd1`, which added a custom Flex code-proposer hook. The project is currently unregistered locally and the artifact-level commit URI is pending. This plan adopts finite structure selection, not source-code proposal execution.

`docs/improvement-requests/production-evidence-optimization.md` requires the first production promotion workflow to reject changed structure/types and never emit them as promotion-compatible. The new structure artifact is separate and experimental; its search report and artifact must never be labeled promotion-compatible, passed off as a sealed promotion report, or weaken that workflow’s same-structure gate. Completing this plan does not fulfill that improvement request.

## Plan of Work


### Milestone 1: A typed finite recipe registry


Create `shikumi-compile/src/Shikumi/Compile/Structure.hs`, expose it in `shikumi-compile/shikumi-compile.cabal`, and re-export its public API from `shikumi-compile/src/Shikumi/Compile.hs`. Define opaque `RecipeId`, `RecipeRevision`, `RegistryId`, a nonempty `StructureRegistry i o`, and `StructureRecipe i o` containing identity, revision, description and `Program i o`. Require nonempty IDs, unique recipe IDs, nonempty registry identity, and positive revisions in a smart constructor. Registry insertion order defines deterministic search/tie order. Require `ToSchema i` and `ToSchema o` when constructing the registry so boundary schemas are derived from the actual types rather than caller-entered strings. Store their Aeson values for equality; do not depend on JSON object key ordering or call the schema a cryptographic proof.

A caller registers ordinary direct, chained, voting or retrying programs that all have the same `i` and `o`. This supports structurally different typed pipelines without existential casts. Supply a convenience constructor for a direct recipe and a CoT recipe built from a base program with empty parameters. Reject a populated base in that helper with a useful diagnostic rather than silently deleting a user's instructions/demos; callers can explicitly clear parameters first. The helper then applies `chainOfThoughtCompiler`. Explain how independently optimized variants can instead be registered explicitly. Do not use `unsafeCoerce`, dynamic Haskell compilation, or serialized function bodies. Test duplicate IDs, empty registries, bad revisions, stable order, and a direct/CoT pair with distinct shapes. Run the compile test suite to verify this milestone.

### Milestone 2: Bounded selection over registered structures


Create `shikumi-optimize/src/Shikumi/Optimize/Structure.hs` and export it through the optimize facade and Cabal library stanza. Implement `structureSearchWith` as an additive entry point accepting plan 53's validated execution configuration, training/validation data, metric/objective configuration, and a typed registry. It returns the selected recipe identity, its `CompiledProgram`, and the shared optimization report. The initial release evaluates supplied recipes; it does not run an unbounded inner optimizer. Training data is available under the shared execution contract but candidate ranking uses validation only. Treat the first recipe as baseline, including when no candidate can be fully scored; report explicitly when the returned baseline is unscored.

Submit each recipe through the shared evaluation/report/event path with its recipe ID as candidate metadata. Enforce both candidate-count and actual LLM dispatch ceilings across the entire search. Count stream and completion operations according to plan 53, including calls inside retries, maps, ensembles and `Embed`. Candidate dispatch must not start after a budget is exhausted; interruption makes that candidate incomplete and ineligible for selection. Shared configured example-error handling applies; infrastructure failures retain plan 53's propagation semantics. Preserve the shared named-objective frontier and explicit final-choice policy; equivalent scores retain registry order. Bounded concurrent execution may finish out of order, but identities and tie choices must remain deterministic. If plan 53's driver is GEPA-specific, extract its candidate-execution seam without altering GEPA behavior and keep shared types owned there.

Add `shikumi-optimize/test/StructureSpec.hs` to the test tree. A scripted provider makes the direct candidate fail one validation example and the CoT candidate answer both, producing a selected CoT recipe independent of training score. A second fixture makes validation favor direct even when training favors CoT, proving held-out selection. Counters must show no operation beyond a cap inside a retrying or opaque candidate; a partially evaluated candidate must not replace a fully scored baseline. Run optimize tests and require report IDs and objective outcomes to agree with the selected program.

### Milestone 3: Versioned restoration through the registry


Create `shikumi-compile/src/Shikumi/Compile/Structure/Serialize.hs` with `encodeStructureArtifact` and `decodeStructureArtifact`. Define an envelope with format version 1, registry ID, recipe ID and revision, input/output schema values, selected `ProgramShape`, and ordered `Params`. Encoding takes a registry and selected recipe/state, and rejects shape or parameter-count mismatch before writing bytes. Decoding takes the typed registry and bytes. Validate format version, registry identity, exact recipe revision, both boundary schemas, selected shape and parameter count before applying parameters to the registered program. Return typed artifact errors with useful categories and offending IDs. Reject unknown recipes and old revisions rather than picking a nearby structure. Existing `encodeCompiled` and `decodeCompiledOnto` remain compatible and retain their meaning. Give the new envelope an explicit artifact kind distinct from any production candidate envelope; do not emit promotion-compatible metadata.

The registry supplies the executable closures during restoration. Its owner must advance a recipe revision whenever implementation, reducer or signature behavior changes, even if shape and schemas remain equal. Document that the checks detect declared incompatibility, not malicious or undeclared replacement of application code. The format cannot move an artifact to an application that lacks the recipe. Test altered versions, schemas, IDs, revisions, shapes and parameter lengths; assert all failures occur without LLM calls. Round-trip the winning candidate from Milestone 2 through its original registry and compare captured requests and typed output, including restored demos on an explicitly registered compatible template.

### Milestone 4: A runnable structure-selection example and durable contract


Add `shikumi-jitsurei/app/StructureSearch.hs` and an executable stanza named `jitsurei-structure-search` to its Cabal file, following existing hermetic example conventions. It constructs the direct/CoT registry, evaluates with a scripted provider, prints the selected recipe and measured calls, encodes/decodes the artifact, and prints equality of original/restored output and request shape. Document the finite-registry workflow, revision obligations, validation distinction, limits and additive API in package docs/changelogs. Create a local ADR for trusted typed recipes and restoration identity, after checking the current ADR convention. Verify the affected suites and example, then record actual evidence below.

## Concrete Steps


Run from the repository root. Implement only after plan 53 has delivered its tested execution contract.

```bash
nix develop .#ghc9124 -c cabal test shikumi-compile:shikumi-compile-test
nix develop .#ghc9124 -c cabal test shikumi-optimize:shikumi-optimize-test
nix develop .#ghc9124 -c cabal build shikumi-jitsurei:exe:jitsurei-structure-search
nix develop .#ghc9124 -c cabal run shikumi-jitsurei:exe:jitsurei-structure-search
nix fmt
```

Successful tests exit zero. The hermetic example must identify the configured CoT recipe as winner, report actual calls at or below its configured cap, and print successful restored output/request equality. Record actual output during implementation; no live-model quality claim is inferred from a scripted provider. Inspect the final diff for unrelated formatting.

## Validation and Acceptance


Registering programs with different boundary types must be impossible through the typed API; demonstrate valid direct and two-stage programs sharing one boundary and document an intentionally ill-typed example without making it part of the build. A recipe whose validation answers are better must win even when its training answers are worse. Ties must consistently retain the earliest recipe despite reversed completion order. Zero candidate/call budgets return the first baseline as explicitly unscored with no LLM operations. Mid-candidate exhaustion preserves the previous fully evaluated winner and reports the incomplete candidate. A nested retry/ensemble/embedded candidate cannot overspend the shared hard dispatch limit. Invalid registry metadata fails before execution. Non-finite objective scores and configured evaluation failures follow plan 53's tested rejection policy.

Saving and loading the selected structure with its original registry must reproduce its prompts and outputs. Loading against missing IDs, changed revisions, changed input/output schemas, wrong shape, wrong parameter count, malformed JSON or an unknown format version must return descriptive errors and perform zero LLM operations. Existing compiled-state round-trip tests must still pass. A structure artifact must remain distinguishable from production candidate envelopes and cannot be admitted through a same-structure promotion gate merely because it restores against its own recipe. The executable must perform the full select/save/load/run sequence without credentials or network access.

## Idempotence and Recovery


Tests and examples use in-memory artifacts or temporary files and can be repeated safely. Preserve the caller's registry and original programs; apply restored parameters to a rebuilt immutable value. Do not modify existing saved artifacts in place. A restore incompatibility is resolved by supplying the exact intended recipe revision or re-running optimization, never by disabling validation. If budgets stop search, the report explains the returned baseline/winner; a new invocation gets a fresh shared budget. No deployment or persistent-data migration is part of this plan.

## Interfaces and Dependencies


`Shikumi.Compile.Structure` owns `StructureRecipe i o`, `StructureRegistry i o`, smart construction/lookup and recipe identity. `Shikumi.Compile.Structure.Serialize` owns a versioned `StructureArtifact` and `StructureArtifactError`, with pure encoding/decoding against the registry. `Shikumi.Optimize.Structure` owns `StructureSearchResult i o` containing selected recipe ID/revision, `CompiledProgram i o` and plan 53's `OptimizationReport`, plus `structureSearchWith`. Its effect row follows plan 53's execution driver instead of introducing IO into framework logic. The new API may use the shared request record rather than duplicating its fields; preserve the requirements stated above when choosing the final concrete signature.

The input/output schema values, recipe revision and `ProgramShape` are separate compatibility checks; none replaces the others. Existing Aeson, text, containers, effectful and compile/eval/optimize package dependencies suffice. Locate dependency source/docs through Mori before relying on unfamiliar APIs; no new third-party package or version bound is selected by this plan. Other master-plan children may consume this API after completion, but this plan requires only plan 53 and existing compiler/program functionality.

Revision (2026-09-06): linked the newly bootstrapped ADR bundle and its authoring/check contract; implementation status is unchanged.

Revision (2026-09-07): implemented registry and versioned artifacts, recorded compiler test evidence, and linked the user-requested intention. Shared search integration is in progress.

Revision (2026-09-07): record shared finite search, restore integration, exact-cap guard, executable example and ADR-8. Final validation is pending.
