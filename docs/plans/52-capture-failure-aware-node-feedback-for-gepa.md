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


- [x] (2026-09-07 02:48Z) Milestone 1: evidence contracts, bounded critiques, target validation, and legacy adapter.
- [x] (2026-09-07 02:48Z) Milestone 2: shared typed failure boundary and ordered observed capture.
- [x] (2026-09-07 02:48Z) Milestone 3: node-grounded reflection and compatibility wrapper.
- [x] (2026-09-07 02:53Z) Milestone 4: integration regressions, documentation, ADR, and full validation.


## Surprises & Discoveries


The ordinary predictor fixture uses rendered-field decoding: malformed text produces `MissingField "sentiment"`, rather than InvalidJSON. The positional regression checks this exact original failure; explicit InvalidJSON injection verifies abort identity.

The observed runner requires Prim but no Time or Concurrent effect. Capture retains its legacy effect signature by reporting per-example provider-acknowledged execution usage rather than introducing a mandatory clock. Ordinary evaluation retains its existing timing and concurrency.

A supplemental strict capability-profile check reports missing recommended `reviews` metadata across all 22 existing capability pages. This is a pre-existing corpus-wide condition; no review provenance was fabricated and no unrelated corpus migration was made. The required strict ADR bundle check passes.

Focused validation passed 47 evaluation, 31 trace, and 94 optimizer tests before the final error-priority and sibling-isolation additions. The prior legacy test failed until its expected critique included the truthful program-scope label.


## Decision Log


On 2026-09-06, separate evidence capture from feedback attribution. An overall program score does not prove which internal predictor caused a failure. Legacy whole-program critique remains explicitly identified as program-scoped; never duplicate it into every node's evidence.

On 2026-09-06, score configured candidate/output failures but propagate cancellation, exhausted execution budgets, and infrastructure failures. Preserve the original error and example position. Do not catch every host exception and call it a poor candidate.


On 2026-09-07, keep the public ReflectIn fields and put labeled intermediate evidence in its feedback field. Add FeedbackCallback/gepaWithFeedback for effectful attributed feedback; retain gepa as an explicit program-fallback wrapper. Failed/rejected invocations sort before successful evidence and the sample limit counts invocation samples. These contracts are distilled in [ADR-4](../adr/0004-separate-feedback-attribution-from-execution-evidence.md).

On 2026-09-07, share scoreExecution in shikumi-eval rather than add trace dependencies to evaluation. It accepts an evidence-preserving runner and root projection; ordinary evaluation keeps its prior classifier, while capture hard-aborts BudgetExceeded and exposes explicit infrastructure classification. Critic failures are MetricError. The legacy FeedbackLog projection stores program critique once at the root key with a label. No intention was supplied in the plan or master plan; the skill-required optional question was asked once and work proceeded without a trailer.

## Outcomes & Retrospective


Implemented the four milestones. Feedback capture preserves all dataset positions, original typed errors, observation/retry lineage, and provider-acknowledged execution usage. Explicit example/path/invocation attribution is validated before reflection. GEPA reflects on bounded, redacted local evidence and changes only the selected executed node. Legacy entry-point signatures remain supported, with program-scoped critiques labeled rather than broadcast.

The full-search classifier regression improves the second predictor while preserving the extractor and inspecting its intermediate input. Regressions cover missing codecs, invalid Map ordinals, zero/odd limits, sibling exclusion, error prioritization, redaction, retry lineage, exact FailAbort errors, custom failure scores, metric failures, budget escape, and cancellation. Ordinary evaluation and replay behavior remain green. ADR-4 distills the durable evidence, provenance, and error-boundary contracts.

The complete test rerun with `nix develop .#ghc9124 -c cabal test all -j1` passed all 16 suites. The initial parallel run had one dependency fake-tool version-probe timeout; the same probe and all 677 tests in mori://shinzui/baikai passed on the serial rerun. Core focused results were:

```text
All 47 tests passed (shikumi-eval)
All 96 tests passed (shikumi-optimize)
All 31 tests passed (shikumi-trace)
16 test suites: PASS
cabal build all -j1: exit 0
nix fmt / git diff --check: PASS
just check-adr: OK: 4 concepts (okf_version 0.2)
```

Remaining limits are deliberate: capture is sequential; callback execution and retry expansion are not strictly charged by predicted-call budgets; structured observations remain optional; and raw returned evidence is not redacted. Plan 53 owns actual bounded execution, split-aware search, and lifecycle reporting. Supplemental capability-profile validation reports the existing missing review metadata across the capability corpus; required ADR enforcement passes.


## Context and Orientation


GEPA means a reflective evolutionary optimizer: run candidates, inspect feedback, rewrite an instruction, and retain promising alternatives. Before this implementation, shikumi-optimize/src/Shikumi/Optimize/GEPA.hs exported FeedbackMetric, captureFeedback, mutateNode, and gepa. FeedbackMetric received expected and predicted outer outputs and returned a Score and Text. captureFeedback directly called runProgram in a sequential loop, attached the same critique to every programNodePaths entry, and aborted on an unhandled ShikumiError. mutateNode only received instruction, concatenated critique, and superficial summaries. shikumi-optimize/src/Shikumi/Optimize/Pareto.hs stores scores across dataset examples, not named objectives.

shikumi-eval/src/Shikumi/Eval/Evaluate.hs already catches typed errors per example, and shikumi-eval/src/Shikumi/Eval/Report.hs defines FailurePolicy and indexed ExampleResult. Ordinary evaluation must retain its documented behavior. This plan adds feedback-capable execution sharing those failure/accounting conventions instead of maintaining two inconsistent batch engines. shikumi-trace/src/Shikumi/Trace/Feedback.hs stores node-keyed critiques but lacks example-level attribution and provenance.

Hard prerequisite docs/plans/51-recover-node-local-bootstrap-demonstrations.md adds capture-capable leaves, NodeObservation, and runProgramObserved returning a root Either plus ordered observations, including failed attempts. NodeObservation identifies a structural NodePath and invocation ordinal and may contain structured input/output only when a codec exists. Plain leaves still expose rendered fields, and Embed interiors remain opaque. This plan must not assume every observation contains JSON. The later docs/plans/53-add-validated-multi-objective-gepa-execution-and-lifecycle-events.md adds split-aware search, bounded execution, and reports on this foundation.

[ADR-1](../adr/0001-use-profile-governed-architecture-decisions.md) now governs decision records: allocate stable ADR-N handles, preserve decision/provenance metadata, update the bundle index/log, and run `just check-adr`. ADR-2 now governs capture codecs and observation isolation; [ADR-4](../adr/0004-separate-feedback-attribution-from-execution-evidence.md) records the implemented feedback attribution and failure boundary. docs/improvement-requests/production-evidence-optimization.md requires bounded critiques, provenance, and separation of training feedback from validation/holdout evidence; this plan provides feedback primitives only, not that complete production workflow. Effectful checked errors differ from host exceptions; inspect mori://effectful/effectful/docs/error-guide for the established API before adding handlers.

Upstream evidence is mori://stanfordnlp/dspy, commit 3f06959eb (2026-08-28), which repaired shortened result arrays when trace capture dropped failed examples. The project is not registered locally and an artifact-level commit URI is pending. Our implementation has a different failure mode, so the requirement is positional stability and explicit failure policy, not copying that Python patch.


## Plan of Work


### Milestone 1 — Evidence and feedback contracts


Create shikumi-optimize/src/Shikumi/Optimize/Feedback.hs with an example-indexed EvaluationEvidence o carrying Either ShikumiError o, observations, and per-example provider-reported execution usage summaries (preserving the legacy effect row without a required clock). Add NodeFeedback with example index, NodePath, optional invocation ordinal, bounded critique, and provenance (Caller, Model, or LegacyProgram). Add a FeedbackResult containing overall Score, optional program critique, and a list of node critiques. The new callback receives expected output and EvaluationEvidence; an effectful callback can call a critic LM through the existing optimizer effect row. Numeric objectives remain owned by plan 53.

Validate every feedback target against the observations for that example and the actual program's node paths. Reject a nonexistent path or negative bound before mutation. A node-specific callback is optional; absence of critique is valid. Keep the exported legacy FeedbackMetric alias and provide a documented adapter whose critique is program-scoped. Register the module in shikumi-optimize/shikumi-optimize.cabal and add FeedbackSpec.hs. Pure validation assertions must reject a critique aimed at an unexecuted Map invocation while accepting a real one.

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

Add focused regressions before implementing each milestone. The attribution regression must fail against the prior broadcast implementation; the positional failure regression must fail against the prior aborting capture loop. After the change all three suites report PASS. Store short actual test output in this plan as implementation proceeds; focused tests have passed, with final integration results recorded below. Final integration uses nix develop .#ghc9124 -c cabal test all.


## Validation and Acceptance


The mixed success/failure batch has exactly one score and evidence envelope per input. A failed predictor retains its path and error. A critique for the second predictor changes only that predictor's parameters; the proposer receives its local intermediate input rather than the outer input. An empty critique does not fabricate negative feedback. Invalid target paths produce an actionable configuration error. A legacy metric continues to optimize a single predictor but is labeled program-scoped for multi-node programs.

A zero critique allowance emits no critique; an odd character allowance obeys its maximum and retains a valid string. Redaction replaces a fixture secret before any proposer request. BudgetExceeded, cancellation, and infrastructure failures terminate through their documented boundaries, while FailAbort returns the exact model-output error. All pre-existing evaluation failure/accounting tests pass.


## Idempotence and Recovery


Tests use scripted models and fresh observation state, so they can be repeated offline. The interface is additive and does not migrate stored program parameters or trace files. If richer feedback is unavailable, retain a labeled program critique or skip mutation; never invent node-level evidence. If a generic evaluator refactor changes default behavior, restore the compatibility wrapper and fix the adapter rather than weakening error tests. Preserve unrelated edits and record any API migration in the changelog.


## Interfaces and Dependencies


Feedback.hs owns EvaluationEvidence, NodeFeedback, FeedbackResult, bounded feedback configuration, and the adapter from existing FeedbackMetric. The observed batch executor returns an ordered vector/list of evidence and scored outcomes of equal length to the dataset. Program identity uses NodePath from shikumi-trace; a separate invocation ordinal distinguishes repeat calls. The target node's output type remains existential, represented through plan 51's optional codec or labeled rendered fields, while the root callback remains typed in o.

Reuse ShikumiError, Score, FailurePolicy, FailureReason, Time, and the existing Effectful row. New effectful metric callbacks must be charged by the execution boundary added in plan 53. No dependency bounds are chosen here; locate APIs through Mori before using them. Do not add deployment, store access, or protected-holdout interfaces to this package.

Revision (2026-09-06): linked the newly bootstrapped ADR bundle and its authoring/check contract; implementation status is unchanged.

Revision (2026-09-07): implemented the evidence contracts, shared checked-error execution boundary, node-grounded reflection, and compatibility adapters; recorded actual focused validation and ADR-4. Full integration validation is recorded in Outcomes & Retrospective.

Validation update (2026-09-07): `nix develop .#ghc9124 -c cabal test all` passed every Shikumi suite, including all 96 optimizer tests, but one of 677 tests in mori://shinzui/baikai failed: the fake tool version probe expected `Just "faketool 9.9.9"` and returned Nothing after 5.01 seconds. The failure occurred during concurrent package builds; full-suite `-j1` confirmation subsequently passed all 16 suites. No dependency source changes or compatibility workarounds were introduced.

Revision (2026-09-07): recorded all 16 passing integration suites, the resolved dependency probe timeout, delivered APIs and regression evidence, and the existing capability-profile metadata limitation.

Completion (2026-09-07): final `nix develop .#ghc9124 -c cabal build all -j1` also passed. All milestones are complete; implementation commit cf73195 and the documentation completion commit retain the ExecPlan trailer.
