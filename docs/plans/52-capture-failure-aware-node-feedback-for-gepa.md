---
id: 52
slug: capture-failure-aware-node-feedback-for-gepa
title: "Capture failure-aware node feedback for GEPA"
kind: exec-plan
created_at: 2026-09-07T01:50:18Z
master_plan: "docs/masterplans/10-dspy-informed-optimizer-and-agent-evolution.md"
---

# Capture failure-aware node feedback for GEPA


This ExecPlan is a living document. Maintain Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective during implementation. Record durable decisions in ADRs before completion.


## Purpose / Big Picture


GEPA should improve the predictor that actually needs correction and continue past an invalid candidate output without mixing up examples. After this change a two-node program can attach a critique only to its second node, while a batch containing success, model-output failure, and success retains all three result positions. Callers can still request abort-on-failure explicitly.


## Progress


Implementation has not started. Populate timestamped milestone checkboxes when implementation begins.


## Surprises & Discoveries


None yet.


## Decision Log


On 2026-09-06, separate evidence capture from feedback attribution. An overall program score does not prove which internal predictor caused a failure. Legacy whole-program critique remains explicitly identified as program-scoped; never duplicate it into every node's evidence.

On 2026-09-06, score configured candidate/output failures but propagate cancellation, exhausted execution budgets, and infrastructure failures. Preserve the original error and example position. Do not catch every host exception and call it a poor candidate.


## Outcomes & Retrospective


Not implemented. Record actual acceptance evidence and remaining limitations at completion.


## Context and Orientation


GEPA means a reflective evolutionary optimizer: run candidates, inspect feedback, rewrite an instruction, and retain promising alternatives. shikumi-optimize/src/Shikumi/Optimize/GEPA.hs exports FeedbackMetric, captureFeedback, mutateNode, and gepa. FeedbackMetric currently receives expected and predicted outer outputs and returns a Score and Text. captureFeedback directly calls runProgram in a sequential loop, attaches the same critique to every programNodePaths entry, and aborts on an unhandled ShikumiError. mutateNode only receives instruction, concatenated critique, and superficial summaries. shikumi-optimize/src/Shikumi/Optimize/Pareto.hs stores scores across dataset examples, not named objectives.

shikumi-eval/src/Shikumi/Eval/Evaluate.hs already catches typed errors per example, and shikumi-eval/src/Shikumi/Eval/Report.hs defines FailurePolicy and indexed ExampleResult. Ordinary evaluation must retain its documented behavior. This plan adds feedback-capable execution sharing those failure/accounting conventions instead of maintaining two inconsistent batch engines. shikumi-trace/src/Shikumi/Trace/Feedback.hs stores node-keyed critiques but lacks example-level attribution and provenance.

Hard prerequisite docs/plans/51-recover-node-local-bootstrap-demonstrations.md adds capture-capable leaves, NodeObservation, and runProgramObserved returning a root Either plus ordered observations, including failed attempts. NodeObservation identifies a structural NodePath and invocation ordinal and may contain structured input/output only when a codec exists. Plain leaves still expose rendered fields, and Embed interiors remain opaque. This plan must not assume every observation contains JSON. The later docs/plans/53-add-validated-multi-objective-gepa-execution-and-lifecycle-events.md adds split-aware search, bounded execution, and reports on this foundation.

[ADR-1](../adr/0001-use-profile-governed-architecture-decisions.md) now governs decision records: allocate stable ADR-N handles, preserve decision/provenance metadata, update the bundle index/log, and run `just check-adr`. No earlier feature-specific ADR was found during the initial review. docs/improvement-requests/production-evidence-optimization.md requires bounded critiques, provenance, and separation of training feedback from validation/holdout evidence; this plan provides feedback primitives only, not that complete production workflow. Effectful checked errors differ from host exceptions; inspect mori://effectful/effectful/docs/error-guide for the established API before adding handlers.

Upstream evidence is mori://stanfordnlp/dspy, commit 3f06959eb (2026-08-28), which repaired shortened result arrays when trace capture dropped failed examples. The project is not registered locally and an artifact-level commit URI is pending. Our implementation has a different failure mode, so the requirement is positional stability and explicit failure policy, not copying that Python patch.


## Plan of Work


### Milestone 1 — Evidence and feedback contracts


Create shikumi-optimize/src/Shikumi/Optimize/Feedback.hs with an example-indexed EvaluationEvidence o carrying Either ShikumiError o, observations, and per-example execution summaries. Add NodeFeedback with example index, NodePath, optional invocation ordinal, bounded critique, and provenance (Caller, Model, or LegacyProgram). Add a FeedbackResult containing overall Score, optional program critique, and a list of node critiques. The new callback receives expected output and EvaluationEvidence; an effectful callback can call a critic LM through the existing optimizer effect row. Numeric objectives remain owned by plan 53.

Validate every feedback target against the observations for that example and the actual program's node paths. Reject a nonexistent path or negative bound before mutation. A node-specific callback is optional; absence of critique is valid. Keep the exported legacy FeedbackMetric alias and provide a documented adapter whose critique is program-scoped. Register the module in shikumi-optimize/shikumi-optimize.cabal and add FeedbackSpec.hs. A pure test must reject a critique aimed at an unexecuted Map invocation while accepting a real one.

### Milestone 2 — One position per example under failure


Factor the reusable per-example execution/failure machinery in shikumi-eval/src/Shikumi/Eval/Evaluate.hs to accept an alternate program runner while keeping evaluate, evaluatePure, and evaluateWith unchanged. The observed runner supplies evidence even when decoding fails. If a dependency cycle would result, keep the generic execution callback in shikumi-eval and define the trace-specific adapter in shikumi-optimize; shikumi-eval must not import shikumi-optimize.

Define the GEPA candidate failure policy with a configurable score for malformed JSON, missing fields, schema mismatch, and validation failure. BudgetExceeded always escapes to the search boundary; ProviderFailure and infrastructure Timeout abort unless explicitly classified by the caller. Exceptions used for thread cancellation are never scored. Metric failures remain separately identified. Preallocate or construct an indexed result for every example and preserve dataset order through future concurrency. Partial failure evidence must not be paired with the next example. Adapt legacy captureFeedback to this executor while retaining its exported type where possible and documenting the corrected program-scoped attribution.

At this milestone tests in FeedbackSpec.hs and GepaSpec.hs run a three-example batch where the middle response fails decoding; expect three slots, indices 0/1/2, with the failure score only at index 1. FailAbort must return the original error. Cancellation and budget exhaustion must not produce a successful completed batch.

### Milestone 3 — Node-grounded reflection


Extend the reflection input in GEPA.hs with bounded examples of the selected node's input, output or error, and its attributed critiques. Do not send sibling-node critiques as though they applied locally. Include program-level critique in a separately labeled field only when no node-specific callback exists or the caller explicitly enables it. Select a node from eligible executed paths deterministically; a node without relevant evidence is left unchanged. Truncate by configured example count and character count, preserving the most useful error summary and reporting truncation rather than accidentally dropping everything for an odd or zero limit.

Allow caller-provided redaction before evidence reaches the reflection model, and retain provenance without inferring human approval. Preserve the legacy gepa entry point as a compatibility wrapper over the new capture path. A two-node fixture with a correct extractor and a faulty classifier must reflect on the classifier's input/output and change only its instruction. Existing reflectiveProposer remains usable through an adapter if the richer ReflectIn type requires an additive replacement.

### Milestone 4 — Integration, diagnostics, and documentation


Update GepaSpec.hs to check failure alignment, exact target attribution, retry lineage, missing codecs, and program-scoped legacy fallback. Add typed-runner tests in shikumi-eval/test and preserve existing evaluation reports and replay tests. Document node callbacks and failure defaults in docs/user/evaluation-and-optimization.md and the limits in docs/capabilities/budgeted-program-optimization.md. Update affected changelogs. Record the feedback/provenance and error-boundary decisions as ADRs using the repository convention discovered at implementation time.


## Concrete Steps


From the repository root, after confirming plan 51 is complete:

```bash
nix develop .#ghc9124 -c cabal build all
rg -n 'captureFeedback|FeedbackMetric|evaluateWith|FailurePolicy' shikumi-optimize/src shikumi-eval/src
nix develop .#ghc9124 -c cabal test shikumi-eval shikumi-trace shikumi-optimize --test-show-details=direct
nix fmt
git diff --check
```

Add focused regressions before implementing each milestone. The attribution regression must fail against the prior broadcast implementation; the positional failure regression must fail against the prior aborting capture loop. After the change all three suites report PASS. Store short actual test output in this plan as implementation proceeds; no tests have been run for this design document. Final integration uses nix develop .#ghc9124 -c cabal test all.


## Validation and Acceptance


The mixed success/failure batch has exactly one score and evidence envelope per input. A failed predictor retains its path and error. A critique for the second predictor changes only that predictor's parameters; the proposer receives its local intermediate input rather than the outer input. An empty critique does not fabricate negative feedback. Invalid target paths produce an actionable configuration error. A legacy metric continues to optimize a single predictor but is labeled program-scoped for multi-node programs.

A zero critique allowance emits no critique; an odd character allowance obeys its maximum and retains a valid string. Redaction replaces a fixture secret before any proposer request. BudgetExceeded, cancellation, and infrastructure failures terminate through their documented boundaries, while FailAbort returns the exact model-output error. All pre-existing evaluation failure/accounting tests pass.


## Idempotence and Recovery


Tests use scripted models and fresh observation state, so they can be repeated offline. The interface is additive and does not migrate stored program parameters or trace files. If richer feedback is unavailable, retain a labeled program critique or skip mutation; never invent node-level evidence. If a generic evaluator refactor changes default behavior, restore the compatibility wrapper and fix the adapter rather than weakening error tests. Preserve unrelated edits and record any API migration in the changelog.


## Interfaces and Dependencies


Feedback.hs owns EvaluationEvidence, NodeFeedback, FeedbackResult, bounded feedback configuration, and the adapter from existing FeedbackMetric. The observed batch executor returns an ordered vector/list of evidence and scored outcomes of equal length to the dataset. Program identity uses NodePath from shikumi-trace; a separate invocation ordinal distinguishes repeat calls. The target node's output type remains existential, represented through plan 51's optional codec or labeled rendered fields, while the root callback remains typed in o.

Reuse ShikumiError, Score, FailurePolicy, FailureReason, Time, and the existing Effectful row. New effectful metric callbacks must be charged by the execution boundary added in plan 53. No dependency bounds are chosen here; locate APIs through Mori before using them. Do not add deployment, store access, or protected-holdout interfaces to this package.

Revision (2026-09-06): linked the newly bootstrapped ADR bundle and its authoring/check contract; implementation status is unchanged.
