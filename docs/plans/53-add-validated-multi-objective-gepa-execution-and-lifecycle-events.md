---
id: 53
slug: add-validated-multi-objective-gepa-execution-and-lifecycle-events
title: "Add validated multi-objective GEPA execution and lifecycle events"
kind: exec-plan
created_at: 2026-09-07T01:50:18Z
master_plan: "docs/masterplans/10-dspy-informed-optimizer-and-agent-evolution.md"
---

# Add validated multi-objective GEPA execution and lifecycle events


This ExecPlan is a living document. Maintain the four living sections during implementation and distill durable execution and reporting contracts into ADRs before completion.


## Purpose / Big Picture


A user can optimize using training feedback while selecting candidates on a separate validation set, inspect quality/cost tradeoffs, and stop at an enforced model-operation ceiling. The returned report explains which candidates completed, failed, or ran out of budget. A scripted example will deliberately reward a different candidate on validation than on training and demonstrate that validation determines the winner.


## Progress


- [x] (2026-09-07) Read the plan, skill specification, prerequisite implementation, and Effectful registry/source documentation. Plan 52 is complete.
- [x] (2026-09-07) Milestone 1: validated configuration and additive report driver.
- [x] (2026-09-07) Milestone 2: atomic admission and failure-safe generic candidate lifecycle.
- [x] (2026-09-07) Milestone 3: validation split and named objectives.
- [x] (2026-09-07) Milestone 4: bounded generations and concurrency regressions.
- [ ] Milestone 5: offline example, documentation, ADR, and full validation.


## Surprises & Discoveries


The prerequisite plan 52 is implemented and validated, despite the stale master-plan registry. The first integration pass passes all 109 optimizer tests, including objective frontiers, report JSON, caught admission errors, the concurrent final-slot ceiling, and opposite training/validation rankings with a sentinel request check.


## Decision Log


On 2026-09-06, add a configured execution/report API while retaining optimize and the existing Optimizer record. GEPA gains an explicit configuration closure; older optimizers remain callable through the same driver. Candidate lifecycle events require instrumented search strategies and must not be fabricated for opaque third-party optimizers.

On 2026-09-06, define the hard budget unit as an admitted Shikumi LLM Complete or Stream operation. This counts calls inside program retries, voting, and Embed bodies visible at that effect boundary. Provider-internal transport retries and dollars are different measurements and are not guaranteed by this cap. Keep estimates separate from actual operation counts.

On 2026-09-06, define a finite declared objective set with direction and missing-value policy. A Pareto frontier is the set of candidates not worse in all objectives and strictly worse in at least one than another. It does not choose a unique winner; an explicit primary-objective/tie policy does that. Training and validation examples are separate from any protected final holdout, which this optimizer never receives.


On 2026-09-07, use serial examples inside bounded candidate batches and an independent dispatch semaphore. Keep serializable RunLimits separate from the executable observer. The generic runSearchSession returns the original typed error alongside its diagnostic report; optimizeWith propagates non-session errors, while its lifecycle sink retains terminal metadata. Candidate status and event constructors use CandidateEnded carrying the explicit terminal status to avoid conflicting Haskell constructor names.

On 2026-09-07, training screening verifies execution without requiring training-score improvement: rejecting every training regression would contradict the opposite-ranking validation acceptance fixture. All required validation positions still gate selection. No intention was supplied in either frontmatter; the optional skill question was asked once and implementation proceeded without a trailer.

On 2026-09-07, refine the deterministic contract to candidate reservation IDs, generation snapshots, parent selection, and result folding. Physical operation order and final-slot allocation across arbitrary concurrent callbacks remain runtime-dependent. Enforcing total ordering across opaque nested operations can prevent barrier-dependent workers from making progress; claiming it from an atomic counter would be false. Width one provides reproducible scheduling for deterministic providers. The source API, user guide, acceptance section, and ADR-5 state this limitation explicitly.

## Outcomes & Retrospective


The shared driver, objective policy, split-aware GEPA path, and lifecycle implementation are in place. The offline optimizer suite passes 114 tests before the final baseline-retention and empty-validation additions. Full repository build, example execution, and final validation remain in progress.


## Context and Orientation


shikumi-optimize/src/Shikumi/Optimize/Types.hs defines Optimizer as a rank-2 function receiving one Dataset, Metric, and Program and returning CompiledProgram under LLM, Concurrent, Error ShikumiError, Time, and Prim. shikumi-optimize/src/Shikumi/Optimize.hs exposes optimize as a thin driver. GEPA.hs uses the same training set for capture and scoring, sequentially evolves one child at a time, and discards its internal frontier when returning. Pareto.hs compares per-example scores; these are distinct from named quality/cost objectives.

shikumi-optimize/src/Shikumi/Optimize/Search.hs reserves predicted costs and provides withLmCallCount, which counts Complete and Stream but cannot stop them before dispatch. shikumi-eval/src/Shikumi/Eval/Evaluate.hs already evaluates examples with bounded concurrency and preserves order. This plan must not claim ordinary evaluation is currently sequential. GEPA feedback capture is sequential, candidate evolution is serial, and concurrency limits are not caller-controlled through GEPA. shikumi-eval/src/Shikumi/Eval/Usage.hs collects model usage; measure summaries per example in isolated collectors before aggregating rather than attaching a shared batch total to every result.

Hard prerequisite docs/plans/52-capture-failure-aware-node-feedback-for-gepa.md supplies typed root evidence, node observations, explicit failure classification, and bounded node feedback. Its own prerequisite plan 51 supplies capture codecs. docs/plans/57-search-and-persist-typed-program-structures.md consumes this plan's generic execution session, candidate evaluation, hard admission, objective selection, events, and OptimizationReport; those mechanisms must not depend on GEPA's mutation algorithm.

[ADR-1](../adr/0001-use-profile-governed-architecture-decisions.md) now governs decision records: allocate stable ADR-N handles, preserve decision/provenance metadata, update the bundle index/log, and run `just check-adr`. No earlier feature-specific ADR was found during the initial review. docs/improvement-requests/production-evidence-optimization.md requires sealed datasets, protected holdouts, provenance, and promotion comparison reports. This plan supports separate validation and diagnostic reporting only; it must not mark that request complete or emit deployment/promotion authority. docs/improvement-requests/expose-acknowledged-evidence-for-resilient-llm-attempts.md covers provider-attempt evidence separately from our LLM-operation ceiling.

Upstream reference is mori://stanfordnlp/dspy, commits 822f39319 (2026-08-18, parallel candidate evaluation), 638e155cf (2026-08-21, named objective scores), and 80553206b (2026-08-10, optimizer lifecycle callbacks). The unregistered project's artifact-level commit URI is pending. PyPI and upstream tags were checked on 2026-09-06: release 3.3.1 contains the first two changes. No dependency on Python DSPy is introduced.


## Plan of Work


### Milestone 1 — Validated configuration and additive reporting driver


Create shikumi-optimize/src/Shikumi/Optimize/Execution.hs and Report.hs. Define RunConfig with operation and candidate ceilings, total evaluation concurrency, deterministic seed, and a metadata-only event sink. Define OptimizationReport with run status, actual admitted operations, predicted work, completed/failed/incomplete candidates, ordered candidate outcomes, per-objective aggregates and selection reason. Separate BudgetStopped and Failed from Completed; a returned baseline may explicitly be Unscored. Version the report's JSON independently from compiled parameter state.

Expose optimizeWith accepting RunConfig, a new ConfiguredOptimizer i o, dataset, metric, and student and returning the compiled result with OptimizationReport. Define ConfiguredOptimizer as a rank-2 driver: forall es. (LLM :> es, Concurrent :> es, Error ShikumiError :> es, Time :> es, Prim :> es) => SearchSession es -> Dataset i o -> Metric o -> Program i o -> Eff es (CompiledProgram i o). An explicit fromLegacyOptimizer :: Optimizer i o -> ConfiguredOptimizer i o lifts opaque legacy strategies. Existing optimize and Optimizer retain their types and semantics. The configured driver creates and explicitly passes an opaque SearchSession es; no undeclared ambient effect or monomorphic es closure is needed. Specify runSearchSession config action for algorithms such as structureSearchWith which return a richer result. The session owns candidate IDs, accounting, event order, and bounded execution. A legacy opaque optimizer receives run-level start/end/failure events and operation accounting only, with candidate detail marked unavailable.

Add gepaWith returning ConfiguredOptimizer i o and accepting a GEPA configuration closure containing optional explicit validation dataset, feedback callback, objective policy, minibatch size, and number of children per generation. Preserve gepa :: ... -> Optimizer i o as a wrapper that invokes the configured GEPA driver with compatibility defaults and discards its report; its old training-as-validation behavior is explicitly labeled in configured reports. New validated mode rejects empty training or validation datasets, invalid limits, duplicate objective IDs, and non-finite configuration values before any calls. Do not silently replace an explicit empty validation set with training. Test configuration and report JSON round-trips without a provider.

### Milestone 2 — Actual admission, failure-safe lifecycle, and generic candidate execution


Add an LLM interposer using atomic admission before forwarding each Complete/Stream. Starting an operation consumes one slot even if it fails; no refund can allow a retry to exceed the ceiling. All candidate, proposer, critic, and internal Program operations share that session. Admission exhaustion raises a distinguished internal stop condition at the search boundary. Even if a Retry or Embed catches the exposed ShikumiError, every subsequent dispatch remains denied, and the enclosing candidate is incomplete, never a fully scored success. Distinguish this stop from caller-originated BudgetExceeded using session state.

Provide evaluateCandidate/session batch primitives receiving candidate identity, dataset, runner, and metric/evidence callbacks. Results preserve example identity and apply plan 52's failure classification. Candidate completion requires all required validation examples; partial aggregate scores are never eligible to win. Keep the best completed candidate on budget stop, falling back to the unscored baseline if none completed. Reserve candidate-count slots before execution and record unused/incomplete work honestly. This is the generic seam consumed by plan 57, not a GEPA-specific function.

Emit RunStarted, CandidateStarted, CandidateCompleted, CandidateFailed, CandidateIncomplete, BudgetStopped, and one terminal RunFinished event on normal, scored-failure, budget-stop, and typed-error paths as applicable. Assign monotonically ordered event IDs at the sink boundary; candidate IDs reflect deterministic scheduling order, not finish order. Isolate observer exceptions under a declared best-effort policy and record observer failure without altering candidate scores; cancellation must still propagate. Keep raw prompts, datasets, and tool payloads out of events by default. Use structured resource cleanup so terminal bookkeeping occurs on cancellation where possible without swallowing it. Opaque candidate reservations belong to one session, execute once, and unused reservations remain listed separately in the report. A stub counter proves a retrying candidate cannot make cap+1 admitted operations, including simultaneous workers racing for the last slot.

### Milestone 3 — Separate validation and named objective selection


GEPA reflection receives only training evidence. Score candidate selection on explicit validation data and never pass validation inputs, labels, critiques, or traces into proposer requests. Reflection may see the selected parent's instructions but not validation evidence. Minibatch training screens proposals; full validation confirms candidates before frontier insertion. Explicitly state that arbitrary caller-written programs/metrics are trusted code: the framework enforces its own data flow, not a security sandbox around malicious callbacks.

Define ObjectiveSpec with stable ID, unit, Maximize/Minimize direction, deterministic aggregation, and required/missing policy. ObjectiveMetric receives expected output and plan 52's evidence, including isolated operation/usage/latency summaries. Support normalized quality and raw nonnegative cost/latency without forcing every objective through the existing bounded Score type. Reject NaN/infinity and required missing values as invalid candidate metrics. Keep per-example scores and aggregate objectives in separate fields. The caller supplies a primary objective and ordered tie-break objectives; after dominance filtering apply this policy and finally candidate creation order. Optional hard bounds exclude a candidate regardless of quality. Legacy scalar scoring stays valid through an adapter.

Use a fixture with candidate A quality 1.0/cost 3, B quality 0.9/cost 1, C quality 0.8/cost 4. A and B are non-dominated; C is dominated. A quality-first policy picks A, while a cost ceiling of 2 excludes A and picks B. Validate objective directions, missing values, and ties. A split fixture where training favors A and validation favors B must pick B, with sentinel validation text absent from reflection requests.

### Milestone 4 — Bounded generations and deterministic integration


Permit GEPA to propose a finite generation of children from the frontier snapshot, then evaluate them concurrently. Use a bounded job scheduler across candidates and a separate shared semaphore directly around Complete/Stream dispatch. The semaphore enforces total active LLM operations, including concurrency introduced inside a Program or Embed. Acquire a permit before admission/dispatch and release it with exception-safe cleanup on success, failure or cancellation. Never hold a dispatch permit for the lifetime of an example or recursive evaluator, which could deadlock its nested calls. Do not multiply candidate workers by example workers and accidentally exceed either stated bound. Allocate deterministic candidate IDs and reserve candidate slots in scheduling order, including when only part of a generation fits the candidate ceiling. Atomic operation admission bounds concurrent dispatch, but the worker receiving the final operation slot can depend on runtime scheduling. Width one is required when reproducible budget-stop outcomes matter. Work admitted to execute can complete out of order; fold completed results into the frontier in candidate order. Adaptive parent selection occurs between generations, so do not pretend parallel scheduling preserves the old single-child search trajectory. Default generation width one preserves that trajectory.

Test concurrency with barriers and counters rather than fragile wall-clock speed assertions. Active operations must never exceed configured width; a blocked job is released by another admitted job; report/selection order remains stable under reversed completion. The operation ceiling still holds when the final slot is contested. Propagate cancellation to workers and close each candidate's event lifecycle exactly once.

### Milestone 5 — User-facing example, compatibility, and documentation


Add shikumi-jitsurei/app/GepaObjectives.hs and jitsurei-gepa-objectives executable using a stub provider. It prints the validation-selected candidate, objective frontier, admitted calls versus cap, and run termination reason. Update shikumi-optimize/test/Main.hs and its Cabal file for ExecutionSpec.hs, ObjectiveSpec.hs, and lifecycle regressions. Preserve existing optimize/gepa tests and compiled serialization tests. Document configured execution in docs/user/evaluation-and-optimization.md, add evidence and limits to docs/capabilities/budgeted-program-optimization.md, and update changelogs. Do not advertise the report as a sealed promotion artifact or a provider-dollar hard cap. Capture the shared driver contract in ADRs after it is implemented and verified.


## Concrete Steps


From the repository root after plan 52 completes:

```bash
nix develop .#ghc9124 -c cabal build all
nix develop .#ghc9124 -c cabal test shikumi-eval shikumi-trace shikumi-optimize --test-show-details=direct
nix develop .#ghc9124 -c cabal run shikumi-jitsurei:exe:jitsurei-gepa-objectives
nix fmt
git diff --check
```

At milestones 1 and 2 the configuration, counter, and lifecycle tests pass; milestone 3 proves objective and split selection; milestone 4 proves bounded concurrency with synchronization barriers; milestone 5 runs the example end to end. Expected output identifies B for the documented split/cost-ceiling fixture, shows calls no greater than the configured cap, and reports Completed or BudgetStopped truthfully. Record actual output during implementation. Finish with nix develop .#ghc9124 -c cabal test all. Tests and examples require no API keys.


## Validation and Acceptance


Zero operation/candidate budget returns an explicitly unscored baseline without dispatch. Mid-candidate budget exhaustion preserves the previous completed winner. Retry, stream, and opaque embedded calls all share one hard admission counter. Concurrent jobs cannot exceed either width or operation ceiling. Provider-internal retries are not labeled separate counted operations unless a future provider-attempt seam supplies them.

Training-only reflection and validation-only selection are verified by captured requests and opposite rankings. Empty explicit validation fails before calls. Objective values preserve units/directions; missing required or non-finite values cannot win. Scalar compatibility produces the old winner for generation width one. Events have stable IDs, one terminal record per started candidate, and truthful run termination; observer failure does not mutate optimization results. Cancellation propagates without leaking workers. Saved reports round-trip and retain candidate IDs, objective policy and units, objective frontier, run controls, unused reservations, actual counts, and incomplete status. The deterministic seed controls candidate scheduling and parent selection; concurrent physical dispatch and the identity of a final-slot winner are explicitly outside that guarantee. Existing compiled-state formats remain unchanged.


## Idempotence and Recovery


Each run owns fresh counters and immutable candidate records. Reports are diagnostic artifacts and do not mutate program deployments or datasets. Offline fixtures can be repeated; live models are not promised deterministic merely because the scheduler has a seed. If concurrency complicates ordering, width one is the tested recovery configuration, not an excuse to omit the bounded-width contract. If a budget stops execution, start a new run with an explicitly changed budget rather than resuming with reset hidden counters. Do not reuse partial validation as a completed result.


## Interfaces and Dependencies


Execution.hs owns validated RunConfig, SearchSession es, runSearchSession, atomic LLM admission, and generic candidate evaluation/scheduling. Report.hs owns OptimizationReport, CandidateReport, ObjectiveSpec/objective values, and OptimizationEvent with versioned JSON. GEPA.hs owns gepaWith and its GEPA-specific proposal configuration. Types.hs owns ConfiguredOptimizer and fromLegacyOptimizer; the optimize facade owns optimizeWith while existing optimize continues accepting Optimizer. All session-aware callbacks quantify over the same es as the session they receive. Plan 57 consumes runSearchSession and evaluateCandidate without importing GEPA mutation logic.

Use existing Effectful Prim atomic references (as in Search.hs), Concurrent, Time, and typed errors. Inspect APIs through mori://effectful/effectful and its registered docs before coding. Reuse eval accounting and plan 52's evidence runner; no new package bounds are selected. Count LLM dispatch operations separately from predicted costs, provider usage, and dollar spending. The protected holdout and production-evidence envelope remain outside this API.

Revision (2026-09-06): linked the newly bootstrapped ADR bundle and its authoring/check contract; implementation status is unchanged.

Revision (2026-09-07): implemented shared execution and objective contracts; clarified concurrent dispatch determinism, introduced session-owned one-use candidate reservations, and recorded test evidence and ADR-5.
