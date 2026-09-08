---
id: 61
slug: expose-billing-quality-and-failed-call-usage-in-reports-and-traces
title: "Expose billing quality and failed-call usage in reports and traces"
kind: exec-plan
created_at: 2026-09-08T16:50:38Z
master_plan: "docs/masterplans/11-adopt-baikai-runtime-capabilities-safely.md"
intention: "intention_01m20zkyrpeewr6kxrzatngqt3"
---

# Expose billing quality and failed-call usage in reports and traces


This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture


Evaluation and tracing should show whether a cost is calculated, provider-reported, estimated, or unknown, and retain available billing from failed attempts. A run that fails once and then succeeds should expose both actual provider attempts; a cache hit should not be mislabeled as new provider spending. Numeric program-usage totals and transport billing must remain separate, clearly named views.


## Progress


- [ ] Milestone 1: Prove a transport-attempt observation seam.
- [ ] Milestone 2: Add explicit billing summaries alongside logical usage.
- [ ] Milestone 3: Record and export failure billing without corrupting replay.
- [ ] Milestone 4: Demonstrate an evaluation with retry, failure and cache hit.


## Surprises & Discoveries


(None yet.)


## Decision Log


2026-09-08: Keep logical operation usage separate from actual transport attempts, and add a collector at the runtime seam that already observes each attempt. Explicit report/trace attachment avoids silently changing existing totals or inventing per-node attribution. This larger plan has four independently verifiable milestones because the collector, presentation and persistence must agree.


## Outcomes & Retrospective


(To be filled during and after implementation.)


## Context and Orientation


The baseline is commit `ac70154`. It requires `mori://shinzui/baikai/packages/baikai`, `mori://shinzui/baikai/packages/baikai-claude`, and `mori://shinzui/baikai/packages/baikai-openai` at `>=0.7.0.0 && <0.8`, and `mori://shinzui/baikai/packages/baikai-effectful` at `>=0.4.0.1 && <0.5`. That upgrade already preserves billing metadata in response/checkpoint JSON, preserves opaque replay JSON, recognizes OpenAI Responses for native schema routing, and distinguishes explicit speed in cache keys. Do not repeat that migration. GHC 9.12.4 and Cabal come from `nix develop .#ghc9124-ci`; the system compiler is not the project compiler. No dependency upgrade is required by this plan.

`shikumi-eval/src/Shikumi/Eval/Usage.hs` intercepts LLM operations above the runtime and projects successful returned usage into UsageTotals in Report.hs. It cannot see intermediate retries or an error terminal that the runtime raises before returning. `shikumi/src/Shikumi/LLM.hs` already charges budgets inside each retry attempt, before raising response/stream failures. `shikumi-trace/src/Shikumi/Trace.hs` records a successful completion's response JSON but leaves stream attributes empty and cannot annotate a failure after complete throws. `shikumi-trace-otel/src/Shikumi/Trace/OpenTelemetry.hs` exports numeric input/output/cost only. `Shikumi.Trace.Store` persists traces; `Shikumi.Trace.Replay` must continue to replay only valid recorded responses.

The upgrade already added Cost.basis and Usage.availability decoding; no new orphan instance is needed. In `mori://shinzui/baikai`, source `baikai/src/Baikai/Usage.hs` owns missing counters and observed service/speed facts, while `baikai/src/Baikai/Cost.hs` owns cost sources and estimate reasons. The decision at project-relative `docs/adr/0020-pricing-policies-and-calculation-bases-are-explicit.md` requires unioning basis sets and preserving absent versus reported zero. A provider-reported amount is not an invoice. Do not calculate prices again or infer observed speed from requested speed.

[ADR-4](../adr/0004-separate-feedback-attribution-from-execution-evidence.md) separates execution evidence from invented node attribution; [ADR-7](../adr/0007-bound-recursive-sessions-at-the-llm-operation-boundary.md) preserves optimistic dollar admission and actual logical attempts; [ADR-9](../adr/0009-centralize-offline-harness-and-diverse-fixtures.md) owns reusable fixtures. Completed plans 39 and 43 already fixed stream usage and exporter cleanup; retain those fixes. No local ADR defines transport-attempt accounting. This plan depends on [58-preserve-provider-refusal-classification-and-retry-semantics.md](../plans/58-preserve-provider-refusal-classification-and-retry-semantics.md) for final error classification. It integrates with [60-apply-shared-request-defaults-across-programs-and-agent-calls.md](../plans/60-apply-shared-request-defaults-across-programs-and-agent-calls.md) to observe effective requests, and with the Responses integration plan for a concrete combined example.

Locate dependency sources with `mori registry search baikai`, `mori registry show shinzui/baikai --full`, and `mori registry docs shinzui/baikai` before reading APIs. Verify behavior against the release tag, since a sibling checkout can contain newer code. If changing dependency bounds becomes necessary, check Hackage preferred versions and upstream tags first. Never traverse `/nix/store` or the filesystem root. Cross-repository source paths below are relative to `mori://shinzui/baikai`; artifact-level source/ADR handles are pending. Registry searches for the relevant upstream ADR titles returned no handles, so do not invent bundle-scoped ADR IDs.


## Plan of Work


### Milestone 1: Prove a transport-attempt observation seam


Create Shikumi.LLM.Observation in the core package. Define LLMObservation with an invocation-local call identifier, attempt ordinal, completion/stream kind, requested model identity, optional provider-observed identity from evidence, terminal status/error, and optional full Usage. Define `LLMObserver = LLMObservation -> IO ()` and a no-op default. Add an observer-aware bare runner and optional observer to LLMConfig, preserving existing runner names as no-op wrappers. Emit exactly one terminal observation for each attempted transport call inside the retry loop, after billing data is available and before raising its error. Success and error streams use their single terminal AssistantPayload. A thrown typed transport error has no fabricated Usage; cancellation propagates and does not synthesize zero-cost success. Response.model is the input Model echoed back; never use it to populate provider-observed identity. An observation contains no prompt, output text, credentials or opaque reasoning. Callback errors are not retried as provider errors; document and test their propagation outside provider retry classification.

Prototype this first with one transient failed attempt carrying partial usage followed by success. A collector sees two events while the ordinary call returns only the final response. A fully cached call emits zero attempt events. Do not also charge the budget from the observer. This milestone is independently accepted by core scripted-provider tests and is the prerequisite for report work, not a production-ready telemetry claim by itself.

### Milestone 2: Add explicit billing summaries alongside logical usage


Create a thread-safe invocation-local collector with `newBillingCollector :: IO (LLMObserver, IO BillingSummary)` and a bounded optional attempt log. Aggregate full Usage using the released dependency's semantics, preserve CostBasis source/reason unions, and separately count missing-usage attempts so absent is never mistaken for observed zero. BillingSummary distinguishes completed, failed and unknown-usage attempts, and identifies whether retained attempt detail was truncated. Numeric totals contain only observed numeric values; the summary labels uncertainty without inventing charges. Counts and sums continue after the detail retention limit.

Extend existing UsageTotals/report rendering to expose available cost-basis and usage-quality information for its logical returned-call view. Add `attachBillingSummary :: BillingSummary -> Report -> Report` as an explicit way to attach the whole-run transport view collected around an evaluation action. Keep the views separate: do not add transport totals to logical totals, and do not claim that the whole-run observer has per-example or node attribution. Show how a caller creates one collector, supplies its observer to the runtime used by evaluate, then attaches its result to the returned report. If the action returns a typed failure, the collector is still readable and can be rendered independently. Preserve FailScore/FailAbort behavior, budget semantics, exact Rational arithmetic, and old zero/default constructors. Update all affected public record construction sites and GEPA evidence projections.

### Milestone 3: Record and export failure billing without corrupting replay


Add optional billing-quality attributes to ordinary completed spans and populate success-stream attributes from terminal usage. Persist the observer's bounded attempt records as a separate, optional run-level billing section with explicit correlation identifiers; do not manufacture structural node parents or treat failed attempts as replayable responses. Provide an attachment helper for a collected billing result analogous to the report helper. Export transport attempts as explicitly identified attempt spans and logical calls as their existing program spans, clearly distinguishing the two to avoid double-counting. Export canonical JSON basis/availability fields and counters for missing observations, leaving them absent when unavailable. Preserve current exporter shutdown, incomplete-span and cycle behavior. Audit gen_ai.response.model as part of this change: populate it only from actual observed-model evidence, never the request Model echoed in Response.model; omit it when unobserved. Existing tests that treat the echoed model as a provider observation must be corrected, with a fixture whose requested and observed models differ. Version any trace-store schema change deliberately, read existing traces with absent billing data, and ensure Replay only indexes the existing successful response records.

### Milestone 4: Demonstrate an evaluation with retry, failure and cache hit


Add an offline integration fixture that evaluates a small multi-call program through routing/defaults, caching, the observer-aware resilient runtime, and report/trace attachment. Script one failed billable attempt then success, a reported zero, an entirely missing usage block, and a later cache hit. Render logical usage and transport billing side by side and export to an in-memory OpenTelemetry processor. Prove costs are counted once in their respective views and estimated components remain visible after aggregation with fully reported components. Update docs/user/evaluation-and-optimization.md and caching-tracing-replay.md, affected changelogs, and a billing-observation ADR. Preserve existing concurrent evaluator behavior; no global collector or sequential trace builder may be shared across runs.


## Concrete Steps


Run commands from the repository root. First inspect `cabal.project.local`: this workstation currently adds sibling dependency packages. For reproducible release verification, use a temporary project descriptor that copies the tracked project settings and makes package paths absolute, without loading that override:

```bash
python3 - <<'PYCODE'
from pathlib import Path
import re, tempfile
root = Path.cwd()
p = Path(tempfile.mkdtemp(prefix="shikumi-baikai-plan-")) / "cabal.project"
s = (root / "cabal.project").read_text()
s = re.sub(r"^  (shikumi(?:-[a-z-]+)?)$", lambda m: "  " + str(root / m[1]), s, flags=re.M)
p.write_text(s)
print(p)
PYCODE
```

Assign the printed path to `SHIKUMI_PLAN_PROJECT` in the shell. The examples below deliberately use a separate build directory so ordinary developer build plans are not overwritten. `plan.json` must identify the four dependency packages as Hackage `repo-tar` sources, not `local` source packages. Do not change the developer's override file.

```bash
nix develop .#ghc9124-ci --command cabal update
nix develop .#ghc9124-ci --command cabal build all --enable-tests --project-file="$SHIKUMI_PLAN_PROJECT" --builddir="$PWD/dist-newstyle-baikai-plans"
nix develop .#ghc9124-ci --command cabal test shikumi shikumi-eval shikumi-optimize shikumi-trace shikumi-trace-otel --test-show-details=direct --project-file="$SHIKUMI_PLAN_PROJECT" --builddir="$PWD/dist-newstyle-baikai-plans"
nix develop .#ghc9124-ci --command cabal test all --test-show-details=direct --project-file="$SHIKUMI_PLAN_PROJECT" --builddir="$PWD/dist-newstyle-baikai-plans"
nix fmt
git diff --check
```

Expect exit status zero, the focused named regressions passing, and all enabled suites reporting PASS. Redis and live-provider skips are not evidence that those integrations work. The existing CI job starts Redis and sets `SHIKUMI_REQUIRE_BACKENDS=1`; preserve that gate. Live provider calls remain explicitly opt-in. After implementation changes an ADR, allocate any new handle with `okf id next docs/adr --profile docs/adr/profile.dhall ADR`, maintain its timestamp and `docs/adr/log.md`, and run `just check-adr`. Review public record/sum changes for Haskell PVP release impact and update affected package changelogs; do not publish a release as part of implementation.


## Validation and Acceptance


The first-failure-then-success fixture yields two attempts, exact observed sum, retained partial failure usage, and the same retry outcome as before. A cache hit yields no new transport attempt while logical response usage retains its established behavior. Missing metadata, reported zero, estimated prices and provider-reported totals render differently. Adding a fully observed cost cannot erase another component's estimate reasons. Stream and completion totals agree for equivalent terminal payloads. Unknown abort costs remain absent, not zero observations. An observer failure is never retried as a model request. Independent concurrent run collectors do not mix records. Existing stored traces decode; failed attempts do not enter replay indexes. The in-memory exporter exposes basis/availability with failure status and no opaque request data. The detail retention limit never changes aggregate counts/sums.


## Idempotence and Recovery


The implementation and tests are repeatable and require no external writes. Add regressions before changing behavior; preserve unrelated working-tree edits. Retry failed builds after fixing the reported cause rather than weakening tests or dependency bounds. Keep existing serialized fixtures as immutable compatibility evidence and add new-version fixtures alongside them. Record implementation evidence in the living sections; do not mark the plan complete on compilation alone.


## Interfaces and Dependencies


Core owns LLMObservation/LLMObserver and per-attempt emission. Shikumi.Eval.Report owns logical report presentation; a core billing summary type may live in Shikumi.LLM.Observation so neither tracing nor evaluation depends on the other. The collector API returns an observer and a snapshot action with an explicit bounded-detail configuration and empty default. Trace owns its persistence version and optional billing attachment, while trace-otel owns export. Existing `withUsageTotals` retains its logical-call meaning; a collector explicitly wired into the real runtime supplies the transport view. No new provider calls, retries, price table, global state or strict monetary reservation are introduced. Use released CostBasis/UsageAvailability types directly and look up OpenTelemetry APIs through Mori before editing the exporter.

Revision (2026-09-08): Linked this plan to the shared initiative intention created with `mina ci --json`, as requested. Scope and dependencies are unchanged.
