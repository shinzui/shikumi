---
id: 62
slug: demonstrate-and-verify-openai-responses-workflows
title: "Demonstrate and verify OpenAI Responses workflows"
kind: exec-plan
created_at: 2026-09-08T16:50:38Z
master_plan: "docs/masterplans/11-adopt-baikai-runtime-capabilities-safely.md"
intention: "intention_01m20zkyrpeewr6kxrzatngqt3"
---

# Demonstrate and verify OpenAI Responses workflows


This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture


A user should have a compiled example showing how to register OpenAI Responses, select a catalog model, configure a typed program, and resume a reasoning/tool conversation. Offline tests must exercise the actual released provider adapter against a local scripted HTTP server; an opt-in live smoke confirms connectivity without being required for normal CI.


## Progress


- [x] Milestone 1: Exercise the released provider through a local server.
- [x] Milestone 2: Publish a compiled runnable example.
- [x] Milestone 3: Document the supported workflow and its limits.


## Surprises & Discoveries


2026-09-08: Real-adapter tests cannot live in the core suite through shikumi-testing because that introduces a Cabal package cycle. Core owns pure schema routing coverage; tools owns real HTTP schema and session tests. Warp listener bracketing alone allowed delayed request workers to outlive cancellation; explicit tracked-worker termination and joining now bounds cleanup.

2026-09-08: The released Responses failure-frame mapper classifies content_filter as OtherError, not ContentFiltered. It is terminal and makes one HTTP request. Tests and documentation preserve this limitation instead of adding a Shikumi classifier. Normal refusal content is not guaranteed a typed refusal error.


## Decision Log


2026-09-08: Make real adapter tests hermetic and live access a distinct explicit mode. The example integrates completed child interfaces rather than redefining them, and separates successful live connectivity from evidence that encrypted continuation was actually replayed.


2026-09-08: Extend ADR-9 with real released-adapter fixture ownership, cycle-free consumer placement, worker cleanup and independently gated live examples. Preserve provider-owned classification. Dependency lookup used Mori for the registered dependency and WAI sources; Hackage preferred versions verified wai 3.2.5, warp 3.4.15 and http-types 0.12.6 before adding internal-only fixture bounds. The Responses source matches the baikai-openai-0.7.0.0 tag.

## Outcomes & Retrospective


Completed in implementation commit `4846318` and the validation follow-up. The compiled default example prints a validated Paris answer, one tool execution, 75 logical tokens and three completed transport attempts with explicit billing uncertainty. Seven new real-adapter tests prove exact native schemas, streaming terminals, opaque checkpoint replay and original call IDs, one tool dispatch, pre-HTTP origin/option rejection, terminal failure classification, retry/cache accounting and timeout/cancellation cleanup. The core suite separately proves pure schema routing without a dependency cycle.

Validation used GHC 9.12.4 with a temporary project descriptor excluding the workstation sibling override. Hackage was refreshed; plan.json identifies Baikai core/Claude/OpenAI 0.7.0.0 and Effectful 0.4.0.1 as repo-tar sources. Full `cabal build all --enable-tests` passed. Full `cabal test all --test-show-details=direct` passed all 13 suites: 243 core, 135 tools, 131 optimizer, 47 evaluator, 32 trace, 9 trace-otel, 33 cache, 22 compile, 18 OKF, 10 CLI, 6 testing, 2 PostgreSQL and 3 Redis tests. The backend-required gate was enabled with an isolated temporary Redis socket; both backend suites actually ran, and Redis was shut down afterward. Provider and embedding live checks were skipped.

All 16 CI example executables exited zero, including Responses with its required output labels. Negative CLI checks reject absent live opt-in, absent credentials, an unknown catalog model and invalid arguments before transport. No live-provider calls were made. `nix fmt`, `git diff --check`, the commit treefmt hook and strict `just check-adr` passed. ADR-9 now records released-adapter fixture ownership and bounded lifecycle; the release-specific OtherError mapping remains documented implementation evidence, not a new classifier. New HTTP dependencies are confined to the internal harness, which published libraries do not depend on. No package versions were bumped or releases published.

The final master-plan ADR distillation reviewed all five child living sections against ADR-6 and ADR-9/11/12/13. Continuation boundaries, request defaults, provider classification and billing ownership are already durable there; EP-62 adds the independent transport proof and explicit live gates to ADR-9. No work remains in this child plan.


## Context and Orientation


The baseline is commit `ac70154`. It requires `mori://shinzui/baikai/packages/baikai`, `mori://shinzui/baikai/packages/baikai-claude`, and `mori://shinzui/baikai/packages/baikai-openai` at `>=0.7.0.0 && <0.8`, and `mori://shinzui/baikai/packages/baikai-effectful` at `>=0.4.0.1 && <0.5`. That upgrade already preserves billing metadata in response/checkpoint JSON, preserves opaque replay JSON, recognizes OpenAI Responses for native schema routing, and distinguishes explicit speed in cache keys. Do not repeat that migration. GHC 9.12.4 and Cabal come from `nix develop .#ghc9124-ci`; the system compiler is not the project compiler. No dependency upgrade is required by this plan.

`shikumi/src/Shikumi/Adapter.hs` already maps OpenAIResponses to NativeSchema. `Shikumi.Routing.translateForWire` attaches the derived strict schema to responseFormat. That change alone does not register a provider. The released module Baikai.Provider.OpenAI.Responses exports registration separately from Chat Completions; its generated model can therefore fail as unregistered even while local capability tests pass. `docs/user/effects-and-runtime.md` currently illustrates Chat registration. `shikumi-jitsurei/app` contains executable examples and `.github/workflows/ci.yml` runs a fixed offline smoke list. `shikumi/test/LiveSpec.hs` uses SHIKUMI_LIVE for a different opt-in provider test; do not repurpose that switch or enable network calls in the existing example list.

[ADR-9](../adr/0009-centralize-offline-harness-and-diverse-fixtures.md) requires reusable stubs in the internal harness and consumer-specific behavioral tests in the consumer package. [ADR-6](../adr/0006-preserve-completed-react-exchanges-in-versioned-sessions.md) requires complete tool exchanges and no redispatch on resume. The registered sources `mori://shinzui/baikai/docs/tools`, `mori://shinzui/baikai/docs/models-and-providers`, and `mori://shinzui/baikai/packages/baikai-openai` explain separate registration, exact Responses replay, distinct reasoning item IDs versus tool call_id, and provider limitations. In the dependency project, `docs/adr/0019-reasoning-continuation-is-scoped-to-its-provider-and-model.md` records that empty summaries still need opaque continuation. No local ADR yet covers a real Responses adapter fixture. This plan has hard dependencies on [58-preserve-provider-refusal-classification-and-retry-semantics.md](../plans/58-preserve-provider-refusal-classification-and-retry-semantics.md), [59-guard-reasoning-state-across-session-compaction-and-model-changes.md](../plans/59-guard-reasoning-state-across-session-compaction-and-model-changes.md), [60-apply-shared-request-defaults-across-programs-and-agent-calls.md](../plans/60-apply-shared-request-defaults-across-programs-and-agent-calls.md), and [61-expose-billing-quality-and-failed-call-usage-in-reports-and-traces.md](../plans/61-expose-billing-quality-and-failed-call-usage-in-reports-and-traces.md) because its final example exercises all four public behaviors. The test fixture design can be researched early, but implement against their completed interfaces.

Locate dependency sources with `mori registry search baikai`, `mori registry show shinzui/baikai --full`, and `mori registry docs shinzui/baikai` before reading APIs. Verify behavior against the release tag, since a sibling checkout can contain newer code. If changing dependency bounds becomes necessary, check Hackage preferred versions and upstream tags first. Never traverse `/nix/store` or the filesystem root. Cross-repository source paths below are relative to `mori://shinzui/baikai`; artifact-level source/ADR handles are pending. Registry searches for the relevant upstream ADR titles returned no handles, so do not invent bundle-scoped ADR IDs.


## Plan of Work


### Milestone 1: Exercise the released provider through a local server


Create `shikumi-tools/test/ResponsesIntegrationSpec.hs` and focused core schema coverage in `shikumi/test/ResponsesSpec.hs`. Use a loopback HTTP server on an ephemeral port with bounded shutdown, a dummy API key supplied per request/isolated registry, and a Model whose endpoint targets that server. Read the released Responses source via Mori to use its public provider constructor and correct SSE event shape rather than guessing or importing private SDK internals. Reuse existing HTTP test infrastructure if present; if a test dependency must be added, locate it through Mori and verify registry versions/tags before selecting bounds. Assert no request reaches a public provider, no real key is required, and every server exits on success, failure and cancellation.

Capture the actual outgoing request JSON. First prove a typed structured-output call uses the native Responses shape, correct schema, defaults and model; add streaming equivalence. Then script valid reasoning output with an empty summary and encrypted continuation, a function call with a distinct call_id, and a second final-submission response. Checkpoint through JSON bytes, resume, and assert exact opaque replay, unknown JSON fields, original tool-call/result order, correct call_id, one tool execution, and typed final validation. Add wrong-model/API and unsafe-compaction cases that fail before HTTP dispatch, plus a classified refusal that makes one request even with retries enabled. This is stronger evidence than the existing in-memory mixed-content persistence fixture.

### Milestone 2: Publish a compiled runnable example


Add `shikumi-jitsurei/app/Responses.hs` and the `jitsurei-responses` executable. Its default mode uses a shared offline fixture and prints a validated answer plus clearly separated logical usage and transport billing. Put the reusable loopback fixture in an internal example/test-support module with explicit test-only dependencies; do not make published library code depend on shikumi-testing or an HTTP test server. Add the example to the existing offline CI smoke list and update its stale count in the same edit.

Provide a distinct `--live` mode gated by `SHIKUMI_RESPONSES_LIVE=1` and an explicitly supplied model ID/API key. The example registers the Responses provider, uses the new request defaults, and attaches billing/trace observations from the new collector. Missing opt-in, missing credentials, invalid model or a request for live work in the default mode must fail or print a clear skip without silently making a public call. Use a small output limit, bounded agent iteration count and a request timeout. State when a live response does not include reasoning continuation; it is not proof of replay. Selecting models or pricing for the live documentation requires checking authoritative provider docs at implementation time, not copying current marketing or prices into this plan.

### Milestone 3: Document the supported workflow and its limits


Update docs/user/effects-and-runtime.md, signatures-and-schemas.md, resumable-react-sessions.md, and caching-tracing-replay.md with the actual compiled example's setup and expected output. Explain separate registration, provider-owned option translation, same-origin history requirements, refusal terminality, billing uncertainty and the explicit reset path. Document transport limitations from the released source: preserve opaque state rather than text summaries, and do not promise image tool results, stop sequences or sampling options that the mapper rejects. Pin these rejection paths in offline tests when the example can reach them. Record a narrow integration-testing ADR or extend ADR-9 if its contract changes, update changelogs, and run the complete offline CI path. Live smoke remains additional evidence and is never silently required to complete an offline plan.


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
nix develop .#ghc9124-ci --command cabal test shikumi shikumi-tools --test-show-details=direct --project-file="$SHIKUMI_PLAN_PROJECT" --builddir="$PWD/dist-newstyle-baikai-plans"
nix develop .#ghc9124-ci --command cabal test all --test-show-details=direct --project-file="$SHIKUMI_PLAN_PROJECT" --builddir="$PWD/dist-newstyle-baikai-plans"
nix fmt
git diff --check
```

After adding the executable, run its default offline mode from the same repository root:

```bash
nix develop .#ghc9124-ci --command cabal run exe:jitsurei-responses --project-file="$SHIKUMI_PLAN_PROJECT" --builddir="$PWD/dist-newstyle-baikai-plans"
```

Require a zero exit status and output containing a validated final answer plus `tool executions: 1`, `logical usage:`, and `transport billing:`. These labels are the example's acceptance contract, not output observed during planning. The separately opt-in live invocation is:

```bash
SHIKUMI_RESPONSES_LIVE=1 nix develop .#ghc9124-ci --command cabal run exe:jitsurei-responses --project-file="$SHIKUMI_PLAN_PROJECT" --builddir="$PWD/dist-newstyle-baikai-plans" -- --live --model "$SHIKUMI_RESPONSES_MODEL"
```

This optional command requires the caller to configure OPENAI_API_KEY and SHIKUMI_RESPONSES_MODEL explicitly. Never run it as part of the default gate, and never print the key. Implement the named CLI arguments as part of milestone 2.

Expect exit status zero, the focused named regressions passing, and all enabled suites reporting PASS. Redis and live-provider skips are not evidence that those integrations work. The existing CI job starts Redis and sets `SHIKUMI_REQUIRE_BACKENDS=1`; preserve that gate. Live provider calls remain explicitly opt-in. After implementation changes an ADR, allocate any new handle with `okf id next docs/adr --profile docs/adr/profile.dhall ADR`, maintain its timestamp and `docs/adr/log.md`, and run `just check-adr`. Review public record/sum changes for Haskell PVP release impact and update affected package changelogs; do not publish a release as part of implementation.


## Validation and Acceptance


From a clean checkout with no provider credentials, all focused tests and `cabal run exe:jitsurei-responses` succeed using loopback only. The example prints a typed final answer, exactly one execution of its scripted tool, and distinct logical/transport usage labels. Tests inspect real emitted Responses JSON, not an LLM-level mock. Empty-summary reasoning, unknown continuation fields, valid function call_id mapping and native schemas survive the checkpoint turn. Refusal makes one HTTP request; wrong origin or incompatible retained prefix makes zero. A transient fixture proves classified retries and two attempt observations. Cache hits add no transport attempts. Server timeout/cancellation tests leave no workers running. A live smoke, if explicitly run, records date, requested/observed model, status and whether replay was actually observed without retaining secrets or opaque reasoning in logs.


## Idempotence and Recovery


All default commands use isolated registries, temporary files and ephemeral loopback ports. A failed scripted test can be rerun without changing any external state. The fixture brackets server lifetime and has bounded timeouts. Checkpoints used by tests are disposable copies; original versioned fixtures stay immutable. Live calls cost money and are never a prerequisite to the offline acceptance gate. Do not retry an opted-in live smoke automatically after a refusal or unclassified failure. Save only redacted status/usage evidence; retain API keys and opaque continuation solely in their intended runtime/session data paths.


## Interfaces and Dependencies


This plan consumes ProviderError/isTransient from the refusal plan, session origin/restart APIs from the reasoning plan, RequestDefaults/withRequestDefaults from the configuration plan, and the observer collector/report attachment from the billing plan. It owns no replacement provider, error classifier or persistence codec. It owns the new executable, public documentation, loopback fixture and CI inclusion. Keep the published library dependency graph free of shikumi-testing and the loopback server. Any reused dependency documentation must be resolved with Mori; only a separately authorized implementation live invocation may contact the provider.

Revision (2026-09-08): Linked this plan to the shared initiative intention created with `mina ci --json`, as requested. Scope and dependencies are unchanged.
