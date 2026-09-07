---
id: 10
slug: dspy-informed-optimizer-and-agent-evolution
title: "DSPy-informed optimizer and agent evolution"
kind: master-plan
created_at: 2026-09-07T01:50:10Z
---

# DSPy-informed optimizer and agent evolution


This MasterPlan is a living document. Maintain the registry and four living sections during implementation. It coordinates delivery; each linked ExecPlan contains its own implementation context and acceptance tests.


## Vision & Scope


Shikumi users will optimize heterogeneous pipelines with valid node-local demonstrations, reflect on actual node evidence, select candidates using separate validation data and declared quality/resource objectives, and inspect truthful execution reports. Agent users will preserve structured tool histories across continuation, recover typed final submissions without unnecessary extraction calls, and consume rich MCP results once the upstream transport exists. Nested XML output becomes a usable typed codec. Two explicitly experimental additions provide bounded exploration of large external contexts and finite search over caller-supplied typed program structures.

This initiative follows a 2026-09-06 review of shikumi at commit 1a9edcc and mori://stanfordnlp/dspy through commit f70d08a5b934400d236078143e3704934f2d5dd1 (2026-09-05). The DSPy checkout matched upstream HEAD; PyPI and upstream tags identified 3.3.1, released 2026-08-21, as the current published release. The project was not registered in Mori; canonical project identity is retained and artifact-level commit URIs are pending. Relevant changes include per-predictor demo sampling (1bc87de15), failure-aligned GEPA capture (3f06959eb), objective-aware GEPA (638e155cf), parallel candidate evaluation (822f39319), optimizer callbacks (80553206b), nested XML (33aaa19e0), and Flex structure optimization (e4e97aae2). Several local weaknesses predate those changes. ReActV2 and RLM are older capabilities with recent documentation/hardening, not newly introduced September features.

The scope is seven new ExecPlans in three phases plus refreshed existing plan 30, retained under its original external master. This is not blanket DSPy parity. Excluded are weight training, arbitrary model-written Haskell/Python execution, automatic deployment, protected-holdout promotion workflows, provider transport rewrites, and unsupported claims that code closures serialize. Existing CodeAct and ProgramOfThought remain supported; DSPy's deprecation alone does not justify removing working Haskell APIs. Existing streaming error handling does not require a speculative rewrite.


## Decomposition Strategy


Phase A strengthens optimization in three ordered steps: capture valid intermediate values and bootstrap demos; use that evidence for failure-aware node feedback; then add configurable execution, split-aware selection, named objectives, reports and bounded concurrency. Keeping the evidence foundation separate makes the heterogeneous pipeline regression independently deliverable. Combining all three would hide attribution and budget failures inside one large optimizer rewrite.

Phase B improves agent and wire behavior: structured ReAct history owns generic rich tool output; pending MCP adaptation consumes that seam when its external APIs ship; nested XML is independent. Generic tool output must not be owned by MCP, because doing so would block ordinary agent improvements on an unavailable dependency. Plan 30 is updated in place rather than duplicated or reparented.

Phase C contains two restricted experimental implementations: explicit per-run context operations and budgeted subqueries, and finite typed recipe selection/restoration. They produce working offline demonstrations, not research-only documents. RLM needs no new optimizer API; structure search consumes the tested execution/report machinery from Phase A. Neither promises the arbitrary source synthesis capabilities of Flex.

The initial review found no ADR corpus. The user subsequently requested explicit bootstrap; [ADR-1](../adr/0001-use-profile-governed-architecture-decisions.md) now governs the registered `adrs` bundle with stable handles, provenance, index/log maintenance, and `just check-adr`. Registry concept discovery found related local improvement requests, including docs/improvement-requests/production-evidence-optimization.md, docs/improvement-requests/expose-acknowledged-evidence-for-resilient-llm-attempts.md, and docs/improvement-requests/ship-the-mcp-to-tool-registry-adapter.md. They constrain scope but are not ADRs. In particular, a new structure artifact must never be mislabeled compatible with the first production-promotion workflow, which requires the original structure. No earlier feature-specific ADR was found. Follow ADR-1 when promoting proved cross-plan contracts during implementation; bootstrap does not mark those designs implemented or independently verified.


## Exec-Plan Registry


| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 51 | Recover node-local bootstrap demonstrations | [Plan 51](../plans/51-recover-node-local-bootstrap-demonstrations.md) | None | None | Complete |
| 52 | Capture failure-aware node feedback for GEPA | [Plan 52](../plans/52-capture-failure-aware-node-feedback-for-gepa.md) | EP-51 | None | Complete |
| 53 | Add validated multi-objective GEPA execution and lifecycle events | [Plan 53](../plans/53-add-validated-multi-objective-gepa-execution-and-lifecycle-events.md) | EP-52 | None | Complete |
| 54 | Add structured resumable ReAct history | [Plan 54](../plans/54-add-structured-resumable-react-history.md) | None | None | Not Started |
| 30 | MCP-to-Tool adapter (externally owned) | [Plan 30](../plans/30-mcp-to-tool-adapter-surfacing-mcp-tools-into-the-registry.md) | EP-54; external MCP C1/C2 release | None | Not Started |
| 55 | Decode nested XML output fields | [Plan 55](../plans/55-decode-nested-xml-output-fields.md) | None | None | Not Started |
| 56 | Add bounded recursive language-model sessions | [Plan 56](../plans/56-add-bounded-recursive-language-model-sessions.md) | None | EP-54 | Not Started |
| 57 | Search and persist typed program structures | [Plan 57](../plans/57-search-and-persist-typed-program-structures.md) | EP-53 | None | Not Started |

Status values are Not Started, In Progress, Complete, and Cancelled. Plan 30 retains its existing intention and parent mori://shinzui/baikai/masterplans/6-mcp-support-across-the-agent-stack. External C1/C2 are mori://shinzui/baikai/plans/30-mcp-transport-and-json-rpc-client-core and mori://shinzui/baikai/plans/31-mcp-tool-discovery-and-invocation. Confirm actual released symbols and bounds from source, Hackage, and upstream tags before starting that adapter. A missing upstream implementation is an explicit prerequisite, not a reason to fabricate a local shim. During planning, mori path returned artifact-not-found for the external MCP master, both C1/C2 plan handles, and the declaration-layer consumer cited in plan 30. These are intended canonical references retained from the existing plan; registry resolution is not verified and must be revisited during prerequisite discovery.


## Dependency Graph


The first implementation path is EP-51 → EP-52 → EP-53 → EP-57. Plan 51 owns capture codecs and ordered observations; plan 52 needs them to attribute feedback and preserve failed-example evidence. Plan 53 needs plan 52's observed runner/error policy to add split-aware objectives and shared execution. Plan 57 must consume the resulting generic candidate session and admission counter rather than invent another optimizer driver.

EP-54 → EP-30 is a separate path, also gated by the two external MCP plans and their published API. Plan 54 provides rich tool output, dynamic registration, and structured history without depending on MCP. Plans 55 and 56 are independently implementable from the current tree. The phase names express delivery priority rather than artificial hard blockers. Plan 56 can reuse lessons from plan 54 but uses private session state and its own restricted action grammar; there is no code dependency.

Contributors can implement 51, 54, 55, and 56 independently once file ownership is agreed. Plans 51/55 both touch core facade/Cabal/example wiring; plans 54/56 both touch shikumi-tools Cabal and tests. Integrate these edits carefully rather than serializing all work. Complete child suites before cross-plan integration and run the full workspace suite after integration.


## Integration Points


Plan 51 owns CaptureCodec and capture-capable prediction leaves in core, and NodeObservation/runProgramObserved in shikumi-trace. The core stays independent of shikumi-trace. Capture codecs carry schema evidence for mapping preflight; observed execution uses observation-only callbacks without requiring trace/node effects, so existing optimizer effect rows remain sufficient. Captured and ordinary leaves share prediction semantics and execution shape; codecs are caller-owned runtime functions excluded from artifacts. Plan 52 consumes observations with example, path, invocation and control-flow identity and must handle missing codecs. Any compile rewrite changing leaf types must adapt capture encoders or report an explicit unsupported transformation; plan 57's helper recipes must honor this rule.

Plan 52 owns EvaluationEvidence, NodeFeedback and program-versus-node attribution. Plan 53 extends evidence with isolated usage summaries and consumes its error classification; recoverable output errors may score, but infrastructure failures and cancellation do not quietly become low quality. Typed budget stops are intercepted at the session boundary. Plan 53 owns SearchSession, RunConfig, the explicit rank-2 ConfiguredOptimizer with fromLegacyOptimizer adapter, OptimizationReport, objective semantics and lifecycle events. Plan 57 calls that shared session through its additive structure-search API. Existing optimize/Optimizer and compiled parameter formats remain usable.

Plan 53's hard ceiling counts admitted LLM Complete/Stream operations, including calls from nested Program constructs visible at that boundary. It is distinct from predicted calls, provider transport attempts, subquery admission counts in plan 56, and dollars. All reports must use these names honestly. A candidate stopped during validation is incomplete and cannot displace a completed candidate. Deterministic candidate ordering, bounded job scheduling, and a separate dispatch semaphore limiting nested active LLM calls are shared requirements for GEPA and structure search.

Plan 54 owns ToolOutput, rich/text projections, dynamic tool construction and checkpoint message representation. Plan 30 consumes those types and owns only MCP discovery, result mapping, collisions, connection-bound invocation and registry ownership. StructuredContent and extension blocks survive adaptation even when providers cannot send them natively. Plan 54's sessions do not silently accept schema changes after refresh; plan 30 refreshes between turns and callers start a validated new session when tool schemas change. Neither promises exactly-once remote effects across interrupted calls.

Plan 55 owns the XML fragment codec and additive nested renderer. It shares Aeson checked decoding with existing adapters and does not change runtime adapter routing. Plan 56 owns ContextStore, private bounded session state, and restricted subqueries; it does not replace the existing stateless interpreter. Plan 57 owns the typed recipe registry and distinct versioned structure artifact. Schema/shape checks cannot attest opaque function identity, so caller-managed recipe revisions are required. These artifact/session/feedback boundaries are the primary ADR candidates.

Every child updates its affected Cabal/test registration, changelogs and maintained user/capability documentation when the feature actually ships. The capability catalog describes delivered behavior only; this planning change must not claim future features are available. No release, push, or deployment is part of this initiative's planning task.


## Progress


- [x] (2026-09-07) Plan 51 implementation and child validation: typed capture, observations, node bootstrap and consumers; 81 optimizer tests pass.
- [x] (2026-09-07) Plan 51 complete: build all and test all pass (16 suites); ADR-2/ADR-3 and maintained documentation delivered.
- [x] (2026-09-07) Plan 52 completed: failure-aware node feedback and ADR-4; its recorded full test validation passes.
- [x] (2026-09-07 04:06Z) Plan 53 complete: shared execution, validation objectives, lifecycle reports and ADR-5; 120 optimizer tests and all 16 suites pass (Redis integration skipped), and the documented example selects B using 5/20 operations.
- [ ] Remaining children 54–57 and the linked MCP adapter.


## Surprises & Discoveries


Plan 51 uses an observation-only callback on the shared sequential traced walker, requiring only LLM, Error ShikumiError and Prim. Observations retain typed failures and rejected-scope lineage; Embed boundaries are explicitly opaque. Plan 52 can consume this surface without requiring Trace, CurrentNode, Time or IOE. [ADR-2](../adr/0002-keep-capture-codecs-in-templates-and-isolate-observations.md) records these contracts and [ADR-3](../adr/0003-validate-bootstrap-demonstrations-at-student-nodes.md) records validated node matching.


## Decision Log


On 2026-09-06, create seven new plans and refresh plan 30 under its original parent. This preserves backlog identity while introducing three delivery phases for eight coordinated workstreams. New plans are not linked to a Rei intention because no ID was supplied for this initiative; plan 30's existing intention remains authoritative for its own work.

On 2026-09-06, prioritize valid intermediate demonstrations and attributed feedback ahead of richer optimization. Existing ToPrompt dictionaries cannot guarantee lossless JSON, and outer example encoders cannot encode hidden intermediate types. Capture is explicit, with single-leaf compatibility retained.

On 2026-09-06, constrain experimental features to implementable capabilities: bounded document operations/subqueries and selection among typed recipe programs. Arbitrary source compilation, unrestricted interpreters, and automatic artifact promotion are excluded. This makes each experimental plan demonstrable without assuming a nonexistent runtime or persistence mechanism.

On 2026-09-06, distinguish current behavior from DSPy marketing and historical parity language: shikumi evaluation already has bounded example concurrency; ReActV2 also executes requested calls sequentially today; LLM-operation limits are not provider-attempt or dollar guarantees. Acceptance tests enforce the actual gaps identified in source.


## Outcomes & Retrospective


Plan 51 is complete: heterogeneous demos run and round-trip, with node-local consumer pools and isolated observation evidence. The full workspace build and all 16 test suites pass. Plan 52 has consumed the observation types and delivered failure-aware node feedback. Plan 53 implements shared admission, validation objectives and lifecycle reporting under ADR-5, with 120 optimizer tests, a passing full suite (Redis integration skipped), and the documented offline example selecting B at 5/20 admitted operations. Phase A is complete; plan 57 can consume the shared session without importing GEPA. The remaining children and linked MCP adapter are unimplemented. Completion requires all seven new plans plus the linked MCP adapter to pass their behavior tests, or an explicit registry scope revision if external MCP work remains unavailable. Independent completed children may be delivered while MCP is pending; do not mark the whole initiative complete prematurely.

Final integration runs from the repository root:

```bash
nix develop .#ghc9124 -c cabal build all
nix develop .#ghc9124 -c cabal test all
nix develop .#ghc9124 -c cabal run shikumi-jitsurei:exe:jitsurei-gepa-objectives
nix develop .#ghc9124 -c cabal run shikumi-jitsurei:exe:jitsurei-structure-search
nix develop .#ghc9124 -c cabal run shikumi-jitsurei:exe:jitsurei-adapters
git diff --check
```

The tests must pass offline, the GEPA example must choose by validation and report bounded calls, the structure example must select/save/restore an exact registered recipe, and the adapter example must round-trip nested data. Agent/RLM/MCP suites supply the remaining end-to-end demonstrations. Record actual output and unresolved limits, then distill durable lessons into ADRs before final completion. These commands are planned validation, not checks already executed during planning.

Revision (2026-09-06): bootstrapped and linked the ADR OKF bundle at the user's request; the feature plans remain unimplemented.

Revision (2026-09-07): record plan 51 implementation and the observation interface delivered for plan 52; other children remain unstarted.

Revision (2026-09-07): mark plan 51 complete after full workspace validation; this satisfies plan 52's capture prerequisite without changing other child statuses.

Revision (2026-09-07): reconcile completed plan 52 and record plan 53 completion and validation evidence; the remaining initiative stays open.
