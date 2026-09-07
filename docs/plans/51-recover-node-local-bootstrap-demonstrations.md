---
id: 51
slug: recover-node-local-bootstrap-demonstrations
title: "Recover node-local bootstrap demonstrations"
kind: exec-plan
created_at: 2026-09-07T01:50:18Z
master_plan: "docs/masterplans/10-dspy-informed-optimizer-and-agent-evolution.md"
---

# Recover node-local bootstrap demonstrations


This ExecPlan is a living document. Maintain Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective during implementation. Distill durable decisions into the repository's ADR convention before completion.


## Purpose / Big Picture


A user can bootstrap a two-stage program whose intermediate records differ from its outer input and output, then run and serialize the optimized program without invalid demo fields. Each predictor receives demonstrations of its own work. A deterministic fixture will extract a city from a question, then resolve its country; the second predictor must receive a city, never the original question.


## Progress


- [x] (2026-09-07) Milestone 1: typed capture and traversal compatibility; core (142), compile (17), trace (27), and OKF suites pass.
- [x] (2026-09-07 02:26Z) Milestone 2: isolated execution observations, retry rejection lineage, and concurrent outer isolation; all 31 trace tests pass. ADR-2 recorded and strict ADR validation passes.
- [ ] Milestone 3: validated node-local recovery and matching.
- [ ] Milestone 4: consumers, persistence, documentation, ADR and integration checks.


## Surprises & Discoveries


The chain-of-thought compiler changes the internal output type. Its capture codec now encodes reasoning plus the original codec output under value, and adapts the schema accordingly; ordinary and captured leaves retain the same serialized execution shape.


## Decision Log


On 2026-09-06, choose explicit typed capture codecs rather than deriving JSON from rendered prompt text. Predict currently retains FromModel and ToPrompt dictionaries, which do not imply ToJSON. Keep ordinary predict programs runnable without new encoding constraints. Recovering demos requires an explicit capture-capable leaf or the legacy single-leaf outer codec.

On 2026-09-06, limit automatic teacher/student matching to equal structural paths and equal input/output schema evidence plus successful target decoding. Expose an explicit mapping for different teacher structures; never broadcast outer demos across internal nodes. Default selection is deterministic, with seeded independent sampling configurable per node.


On 2026-09-07, use a shared sequential walker with scope and leaf callbacks. Observation-only execution needs Prim but no Time, Trace, CurrentNode, or IOE. Record rejection scope labels and starting invocation ordinals; keep Embed boundaries explicitly opaque. See [ADR-2](../adr/0002-keep-capture-codecs-in-templates-and-isolate-observations.md).


## Outcomes & Retrospective


Not implemented. Record demonstrated results and remaining limits here at completion.


## Context and Orientation


The core package defines Program i o, a typed representation of an LM computation, in shikumi/src/Shikumi/Program.hs. Predict stores a Signature and Params; Params contains JSON Demo values decoded back to each predictor's types by applyParams. Compose hides the intermediate type, so outer ToJSON constraints cannot encode an internal value. shikumi/src/Shikumi/Signature.hs holds typed signature metadata and demos. shikumi-trace/src/Shikumi/Trace/Node.hs enumerates structural NodePath values in parameter traversal order. Repeated executions of the same node need an invocation number as well as this structural path.

shikumi-trace/src/Shikumi/Trace/Program.hs already supplies runProgramTraced and tags prediction spans with NodePath, but delegates each prediction to runProgram without recording its structured input/output. shikumi-optimize/src/Shikumi/Optimize/Bootstrap.hs currently recovers outer Demo pairs and calls withDemos from shikumi-optimize/src/Shikumi/Optimize/LabeledFewShot.hs, which attaches them everywhere. shikumi-optimize/src/Shikumi/Optimize/RandomSearch.hs also consumes bootstrapKeptDemos. shikumi-optimize/src/Shikumi/Optimize/MIPRO.hs must be audited for the same assumption. The existing BootstrapSpec.hs and RandomSearchSpec.hs under shikumi-optimize/test use the local StubLM.hs fixture.

[ADR-1](../adr/0001-use-profile-governed-architecture-decisions.md) now governs decision records: allocate stable ADR-N handles, preserve decision/provenance metadata, update the bundle index/log, and run `just check-adr`. No earlier feature-specific ADR was found during the initial review. Existing plans 16, 23, 37, 38, and 42 under docs/plans explain tracing, bootstrap consumers, budget limits, persistence, and trace isolation; the constraints needed here are restated in this document. The follow-on docs/plans/52-capture-failure-aware-node-feedback-for-gepa.md consumes the observation representation owned here. This plan has no hard prerequisite among the new plans.

Upstream motivation is mori://stanfordnlp/dspy, commit 1bc87de15 (2026-08-27), independently sampling labeled demonstrations per predictor. DSPy is not locally registered; an artifact-level commit URI is pending. This plan repairs a pre-existing local recovery gap in addition to adopting sampling independence.


## Plan of Work


### Milestone 1 — Typed capture without changing ordinary prediction


Add CaptureCodec i o in shikumi/src/Shikumi/Program.hs with input and output encoders to Aeson Value plus explicit input/output JSON Schema values. Introduce a capture-capable prediction constructor retaining the same dictionaries, signature, and parameters as Predict, plus this codec. Add predictCaptured in shikumi/src/Shikumi/Module.hs, with ToJSON i, ToJSON o, ToSchema i, and ToSchema o constraints, that supplies the encoders and derives schema evidence. Ordinary predict stays unchanged. A custom-codec constructor is allowed for types with deliberate wire encodings. Both constructors must share runPredict, routing, decoding, and validation behavior.

Update every Program traversal, including sequential/concurrent execution, tracing, streaming, parameter rewriting, field enumeration, compile rewrites, shape serialization, and OKF documentation, by searching all Predict pattern matches. Treat captured leaves as the same execution shape as ordinary prediction; codecs live in the caller's template, never the parameter artifact. Preserve codecs through parameter changes and explicitly adapt or reject them through rewrites that change leaf types. Test ordinary and captured prediction against identical stub responses and require identical requests and decoded results. Run the core, compile, trace, and OKF suites at this milestone.

### Milestone 2 — Isolated structured execution observations


Create shikumi-trace/src/Shikumi/Trace/Observation.hs. NodeObservation contains NodePath, a per-example invocation ordinal, encoded input when available, rendered input fields, rendered output fields on success, optional encoded output, and Either ShikumiError success status. Distinguish missing codecs from failed model execution. Record control-flow lineage sufficient to exclude attempts later discarded by a retry or failed enclosing validation. Do not treat every successful leaf in a subsequently failed attempt as a usable demonstration.

Extend the existing traced walker with a shared internal observation callback and expose runProgramObserved. It returns the root Either ShikumiError o and observations even on typed root failure. Observation storage is fresh per example; cancellation and unexpected host exceptions propagate. Map elements and repeated attempts preserve stable structural paths with distinct invocation ordinals. Embed remains opaque and reports this limit; do not invent internal predictor identities. A traced fixture with retry then success must retain both observations while marking only the accepted attempt eligible for demo recovery. Keep deterministic ordering independent of unrelated example concurrency. Add ObservationSpec.hs under shikumi-trace/test and register it in its Main.hs and Cabal file.

### Milestone 3 — Per-node bootstrap and explicit matching


In Bootstrap.hs add bootstrapNodeDemos returning a map from student NodePath to ordered Demo values and a diagnostic report. Accept only completed teacher examples that pass the caller's metric threshold and eligible successful node invocations. Compare captured input/output schemas during mapping preflight, then validate each recovered input and output with the target leaf's FromModel dictionaries before attaching it. Missing required schema evidence or incompatible paths/schemas fails before any LM call. A runtime value or custom-codec mismatch is rejected after capture with a diagnostic and never installed as a demo; schema equality alone does not prove that a custom encoder obeys its declared schema. A positional coincidence alone is insufficient for differently shaped programs. For heterogeneous teachers expose explicit teacher-to-student path mapping, validate all paths and compatibility before LM calls, and reject duplicate target mappings unless the caller explicitly asks to merge.

Retain bootstrapFewShot and bootstrapFewShotWith. For an ordinary single Predict teacher, outer ToJSON encoders provide the backward-compatible capture path. For composite programs with uncaptured leaves, require capture-capable leaves and return a descriptive ValidationFailure before spending calls; do not retain the old global broadcast fallback. Add a separate node-bootstrap configuration rather than silently changing BootstrapConfig record construction. Cap demonstrations independently per target node and offer a seed; derive independent deterministic streams from seed plus stable target path. Identical runs reproduce selection, while two compatible predictors need not receive the same subset.

### Milestone 4 — Consumers, persistence, and user example


Migrate RandomSearch.hs and MIPRO.hs away from an unkeyed global demo pool. Retain bootstrapKeptDemos only for documented outer/single-node compatibility, so existing callers cannot silently receive a differently interpreted list. Add a heterogeneous fixture to BootstrapSpec.hs and exercise it through random search and MIPRO where they bootstrap candidates. Persist with shikumi-compile/src/Shikumi/Compile/Serialize.hs and restore onto the capture-capable template; node demos must round-trip exactly. Update docs/user/evaluation-and-optimization.md and docs/capabilities/budgeted-program-optimization.md with the typed capture requirement, accepted teacher mappings, and opaque Embed limit. Update affected changelogs and document public constructor/source compatibility implications; do not publish packages in this plan.


## Concrete Steps


Run from the repository root:

```bash
nix develop .#ghc9124 -c cabal build all
rg -n 'Predict|bootstrapKeptDemos|withDemos' shikumi/src shikumi-trace/src shikumi-optimize/src shikumi-compile/src shikumi-okf/src
nix develop .#ghc9124 -c cabal test shikumi shikumi-trace shikumi-compile shikumi-optimize shikumi-okf --test-show-details=direct
```

Add the tests before implementing their behavior. At milestone 1 the captured constructor tests pass with identical model requests; at milestone 2 the observation tests preserve failed attempts; at milestone 3 the heterogeneous bootstrap regression passes; at milestone 4 all listed suites report PASS. These are expected results, not results already obtained. Run nix fmt and git diff --check after code changes. Final integration runs cabal test all inside the same dev shell. Preserve unrelated working-tree edits.


## Validation and Acceptance


Use Question {question}, City {city}, and Country {country} records. With a teacher producing Paris then France, inspect the compiled parameters: the first demo input has question and output city; the second input has city and output country. Running the compiled student and loading its saved parameters onto the same template both produce France. The old implementation either installs incompatible fields or fails decoding, so this regression distinguishes the change.

An incompatible explicit teacher mapping fails before any LM calls. A failed teacher example contributes no demos; a retried successful example contributes no rejected-attempt demo. Repeated Map invocations remain separate observations. Missing capture codecs yield an actionable error, while a legacy single-node bootstrap remains successful. Two seeded runs give identical per-node pools and respect per-node caps. Parallel outer evaluations never exchange observations. All existing replay, routing, validation, and budget regressions remain green.


## Idempotence and Recovery


All validation is offline and repeatable. Saved parameter formats remain unchanged; capture functions are restored from the code template. No data migration or dependency pin is required. If a traversal loses codecs, keep capture opt-in and repair that traversal before enabling composite bootstrap. Never recover by reinstalling global demos or guessing encodings from prompt text. Use a temporary output directory for serialization fixtures and let test cleanup remove its own artifacts.


## Interfaces and Dependencies


The implementation owns CaptureCodec, the capture-capable prediction constructor and predictCaptured in core, and NodeObservation/runProgramObserved in shikumi-trace. The observable runner returns (Either ShikumiError o, [NodeObservation]) under LLM, Error ShikumiError, Time, and Prim, with Concurrent only for an explicitly concurrent variant. Factor the walker so the public runner installs private CurrentNode and Trace handlers internally (or uses an observation-only callback without those effects). Existing Optimizer cannot supply Trace or CurrentNode in its public row; do not accidentally require them or add IOE to ordinary Program execution. The bootstrap map is Map NodePath [Demo], with typed validation performed at the student leaf before Params installation. NodePath remains defined in shikumi-trace to avoid a reverse dependency from core.

Use existing Aeson, Effectful Prim references, and tracing mechanisms. Discover dependency APIs via mori registry search/show/docs and inspect source before implementation; no new dependency bounds are selected by this plan. Changes to constructors must be reflected throughout the monorepo. Record codec lifetime and observation identity as durable ADR context once proven.

Revision (2026-09-06): linked the newly bootstrapped ADR bundle and its authoring/check contract; implementation status is unchanged.

Revision (2026-09-07): implemented and validated milestone 1; captured codecs remain template-owned and the chain-of-thought rewrite adapts their wire output.

Revision (2026-09-07): completed milestone 2 and recorded ADR-2; observation identity and failed-scope eligibility are covered by deterministic trace tests.
