---
id: 11
slug: adopt-baikai-runtime-capabilities-safely
title: "Adopt Baikai runtime capabilities safely"
kind: master-plan
created_at: 2026-09-08T16:50:24Z
intention: "intention_01m20zkyrpeewr6kxrzatngqt3"
---

# Adopt Baikai runtime capabilities safely


This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Vision & Scope


Users can run reasoning-enabled programs with one explicit request configuration, receive terminal refusals without unnecessary retries, preserve valid reasoning across resumes, and inspect the quality and origin of billing amounts. A compiled Responses example and real-adapter offline tests demonstrate the complete path. This initiative extends the compatibility upgrade at `ac70154`; it does not repeat dependency bounds, cost/replay JSON preservation, native Responses schema recognition, or speed cache-key differentiation already implemented there.

The scope is five independently testable improvements across core runtime, sessions, evaluation, tracing and examples. It excludes changing default production models, publishing packages, deployments, provider pricing tables, strict monetary reservation, unbounded telemetry retention, silently repairing signed history, or running live provider calls as a normal test. Provider translation/pricing remain owned by `mori://shinzui/baikai`; Shikumi owns runtime policy, session integrity and presentation. The master plan and all five child plans share the intention recorded in their frontmatter.


## Decomposition Strategy


Split by user-visible behavior rather than packages. Refusal handling is the smallest correctness change and establishes the error contract. Reasoning sessions have a distinct persistence and history contract. Request defaults are a pure runtime composition feature. Billing needs its own collector and serialization decisions because logical operation usage differs from transport attempts. The final example validates the combined result rather than becoming a second implementation of any feature.

[ADR-6](../adr/0006-preserve-completed-react-exchanges-in-versioned-sessions.md) preserves completed exchanges and the full audit while permitting request-view compaction; the new plan tightens when compaction is safe. [ADR-7](../adr/0007-bound-recursive-sessions-at-the-llm-operation-boundary.md) preserves bounded recursive calls and optimistic budget admission. [ADR-4](../adr/0004-separate-feedback-attribution-from-execution-evidence.md) prohibits inventing node attribution or provider evidence. [ADR-9](../adr/0009-centralize-offline-harness-and-diverse-fixtures.md) centralizes reusable offline fixtures without introducing production dependency cycles. Relevant prior plans 34, 39, 43, 49, 54 and 56 are completed and are not reopened. [ADR-11](../adr/0011-preserve-provider-errors-and-centralize-retry-policy.md) now defines refusal policy after EP-58 implementation. [ADR-12](../adr/0012-apply-request-defaults-before-cache-and-observation.md) defines shared request defaults and evidence cache bypass after EP-60 implementation. No local ADR yet defines transport-attempt billing. Child implementation must record those durable decisions when adopted.

Upstream context was read through Mori at `mori://shinzui/baikai`: project-relative `docs/adr/0011-core-owns-transport-failure-classification.md`, `docs/adr/0019-reasoning-continuation-is-scoped-to-its-provider-and-model.md`, and `docs/adr/0020-pricing-policies-and-calculation-bases-are-explicit.md`. Artifact-level handles are pending; registry title searches returned none. Their operative rules are embedded in the children: refusals are terminal; opaque replay is origin-scoped; estimates and missing usage remain explicit. Combining everything into one plan would hide independently shippable fixes; splitting billing by package would leave interface ownership unclear.


## Exec-Plan Registry


| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 58 | Preserve provider refusal classification and retry semantics | [58-preserve-provider-refusal-classification-and-retry-semantics.md](../plans/58-preserve-provider-refusal-classification-and-retry-semantics.md) | None | None | Complete |
| 59 | Guard reasoning state across session compaction and model changes | [59-guard-reasoning-state-across-session-compaction-and-model-changes.md](../plans/59-guard-reasoning-state-across-session-compaction-and-model-changes.md) | None | EP-60 | Complete |
| 60 | Apply shared request defaults across programs and agent calls | [60-apply-shared-request-defaults-across-programs-and-agent-calls.md](../plans/60-apply-shared-request-defaults-across-programs-and-agent-calls.md) | None | None | Complete |
| 61 | Expose billing quality and failed-call usage in reports and traces | [61-expose-billing-quality-and-failed-call-usage-in-reports-and-traces.md](../plans/61-expose-billing-quality-and-failed-call-usage-in-reports-and-traces.md) | EP-58 | EP-60 | In Progress |
| 62 | Demonstrate and verify OpenAI Responses workflows | [62-demonstrate-and-verify-openai-responses-workflows.md](../plans/62-demonstrate-and-verify-openai-responses-workflows.md) | EP-58, EP-59, EP-60, EP-61 | None | Not Started |



## Dependency Graph


Implement [58-preserve-provider-refusal-classification-and-retry-semantics.md](../plans/58-preserve-provider-refusal-classification-and-retry-semantics.md) first, then [59-guard-reasoning-state-across-session-compaction-and-model-changes.md](../plans/59-guard-reasoning-state-across-session-compaction-and-model-changes.md) as the next correctness priority. [60-apply-shared-request-defaults-across-programs-and-agent-calls.md](../plans/60-apply-shared-request-defaults-across-programs-and-agent-calls.md) has no hard prerequisite and may proceed independently with ownership coordination. [61-expose-billing-quality-and-failed-call-usage-in-reports-and-traces.md](../plans/61-expose-billing-quality-and-failed-call-usage-in-reports-and-traces.md) has a hard dependency on the refusal plan because it records final structured errors; it benefits from but does not require the defaults layer. [62-demonstrate-and-verify-openai-responses-workflows.md](../plans/62-demonstrate-and-verify-openai-responses-workflows.md) begins implementation after all four interfaces are complete, since its accepted example must exercise their combined behavior.

Hard dependencies are completion prerequisites. Soft dependencies improve context without blocking implementation. Integration dependencies require shared interface reconciliation: reasoning and defaults share request ordering; refusal and billing touch runtime handlers; defaults and billing share effective request observation; reasoning and Responses share checkpoint fixtures. Recommended sequential order is 58, 59, 60, 61, 62. Earlier isolated tests should remain useful even before the final example is available.


## Integration Points


The error vocabulary belongs to plan 58: ProviderError retains the released BaikaiError and only typed rate-limit/transient categories retry. Billing reads that contract and never creates another classifier. Legacy ProviderFailure remains available. Plan 61 owns observations for each actual transport attempt and must not charge budgets again.

The request order shared by plans 59, 60 and 61 is route the model, validate continuation, fill missing defaults, consult cache/trace, validate again and strip private metadata at final dispatch, then transport. Plan 59 owns the validation helper/private expectation format and adds cache checks before lookup. Plan 60 owns the finite fill-only defaults vocabulary and the memoizer bypass for evidence-requesting calls, because a cache hit cannot provide evidence of a new provider crossing. Plan 61 observes attempts after all those layers, so cache hits produce no attempt. Tests must prove the documented wrapper composition, not rely on informal left/right ordering language.

Plan 59 defines the shared `RequestOrigin` and pure context projection in `Shikumi.LLM.Continuation`; History persists these values. The origin is request identity, not observed provider evidence. Routing and cache memoizers now require `Error ShikumiError`.

Plan 59 owns checkpoint version 2 and the rule for unknown-origin legacy histories. It preserves audit bytes, uses a structurally safe summary projection, and makes reset explicit. Plan 62 consumes separate transport-valid Claude/Responses fixtures and never turns mixed metadata persistence tests into claims of wire compatibility.

Plan 61 owns the distinction between logical usage and transport billing, the bounded collector, and the shared summary type below evaluation/tracing. Evaluation owns report presentation; trace owns optional persisted billing detail and its format version; trace-otel owns export. No child may invent per-node attribution or make failed attempts replayable. The final example attaches these views explicitly.

The shared harness remains internal per ADR-9. Each child owns its focused consumer regressions, while plan 62 owns the loopback provider fixture, executable and CI smoke addition. Durable decisions must be distilled into the profiled ADR bundle during implementation, including error policy, continuation/reset boundaries, defaults precedence and observation ownership. Do not mark proposed planning choices as accepted ADRs before their implementation evidence exists.


## Progress


- [x] EP-58, milestone 1: Preserve the structured transport failure.
- [x] EP-58, milestone 2: Use one classification for blocking and streaming retries.
- [x] EP-58, milestone 3: Document the error boundary and downstream behavior.
- [x] EP-59, milestone 1: Separate audit data, safe summaries and replayable history.
- [x] EP-59, milestone 2: Bind persisted continuation to its origin and validate after routing.
- [x] EP-59, milestone 3: Provide an explicit fresh conversation and migration documentation.
- [x] EP-60, milestone 1: Define an explicit default merge.
- [x] EP-60, milestone 2: Apply defaults at the effective request boundary.
- [x] EP-60, milestone 3: Demonstrate cache, routing and concurrency behavior.
- [x] EP-61, milestone 1: Prove a transport-attempt observation seam.
- [x] EP-61, milestone 2: Add explicit billing summaries alongside logical usage.
- [x] EP-61, milestone 3: Record and export failure billing without corrupting replay.
- [ ] EP-61, milestone 4: Demonstrate an evaluation with retry, failure and cache hit.
- [ ] EP-62, milestone 1: Exercise the released provider through a local server.
- [ ] EP-62, milestone 2: Publish a compiled runnable example.
- [ ] EP-62, milestone 3: Document the supported workflow and its limits.


## Surprises & Discoveries

2026-09-08: EP-60 exposes `Shikumi.LLM.Defaults` with four fill-only optional fields and validates zero default ceilings using terminal `ValidationFailure`. Evidence requests bypass cache reads and writes. `shikumi-jitsurei/app/RequestDefaults.hs` compiles the routing/defaults/trace/cache stack for EP-62. Defaults preserve explicit sub-models; the existing ambient router replaces models, so distinct-model recursive sessions use defaults without that router. EP-61 observes below cache to distinguish actual attempts from logical hits.

2026-09-08: EP-59 preserves the reserved `shikumi.continuation.v1` expectation through routing and cache, stripping it only at transport. EP-60 must retain it when filling defaults. Explicit startup persists a minimal public model identity; callers use routing for full model capabilities and credentials. Unknown opaque version-1 histories require explicit restart.

2026-09-08: EP-58 confirms that typed unknown/process failures must remain terminal and that legacy malformed stream fixtures remain retryable. ReAct also checks raw responses from custom interpreters; it now preserves structured failures before any tool dispatch. EP-61 should consume `ProviderError` directly and keep attempt billing separate.


## Decision Log


2026-09-08: Create five child plans with correctness work first and one integration example last. Keep error classification, continuation integrity, defaults and billing independently verifiable. Billing is one four-milestone plan because collector/presentation/persistence must agree. The other children each have three milestones.

2026-09-08: Use conservative history rejection and an explicit new-session path rather than silently editing signed exchanges. Keep provider-owned opaque data out of summaries while preserving it in the original audit.

2026-09-08: Preserve the distinction between requested settings and observed provider facts, and between logical cached usage and actual attempt billing. Use bounded run-local collectors and explicit attachment, without new price computation or claimed node attribution.

2026-09-08: Require real released-adapter offline tests for Responses, while keeping live usage explicitly opt-in. No provider calls or release publication are authorized by plan creation.


## Outcomes & Retrospective


EP-58 is complete (`360c6d4`): structured refusals are terminal in both APIs; original error records survive; legacy fallback, cancellation and failure-cost accounting are covered. The release-source build and all 13 test suites passed, with Redis running zero tests and live checks skipped. ADR-11 captures the durable boundary. EP-59 is complete (`c24aa15`): version-2 continuation identity and protected-prefix validation, safe summaries, conservative compaction, and explicit restart are implemented. The full build and all 13 suites passed with release-source dependencies; Redis ran zero tests and live checks were skipped. ADR-6 captures the durable continuation boundary. EP-60 is complete: shared defaults, effective-option cache differentiation and evidence bypass are implemented (`661204c`), with a compiled offline stack and ADR-12. The full release-source build and all 13 suites passed; Redis ran zero tests and live checks were skipped. Three of five child plans are complete; EP-61 is the next eligible child, followed by EP-62.

Revision (2026-09-08): Linked this plan to the shared initiative intention created with `mina ci --json`, as requested. Scope and dependencies are unchanged.

Revision (2026-09-08): Completed EP-58, recorded its release-source validation and cross-plan error contract, and distilled refusal/retry policy into ADR-11. Remaining child statuses and dependencies are unchanged.

Revision (2026-09-08): Completed EP-59, recorded its shared continuation metadata and Error constraints for downstream plans, and extended ADR-6. EP-60 remains the next eligible child.

Revision (2026-09-08): Completed EP-60, recorded its released-source validation and compiled example, and distilled defaults precedence and evidence cache bypass into ADR-12. EP-61 is next.
