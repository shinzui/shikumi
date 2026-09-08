---
id: 58
slug: preserve-provider-refusal-classification-and-retry-semantics
title: "Preserve provider refusal classification and retry semantics"
kind: exec-plan
created_at: 2026-09-08T16:50:38Z
master_plan: "docs/masterplans/11-adopt-baikai-runtime-capabilities-safely.md"
intention: "intention_01m20zkyrpeewr6kxrzatngqt3"
---

# Preserve provider refusal classification and retry semantics


This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture


A provider refusal should reach the caller once, with its structured category intact, rather than consume every retry attempt. Blocking and streaming calls should make the same retry decision. Demonstrate this with isolated providers that refuse once, transiently fail then succeed, or return malformed legacy stream terminals; no credentials are needed.


## Progress


- [x] (2026-09-08) Milestone 1: Preserve the structured transport failure.
- [x] (2026-09-08) Milestone 2: Use one classification for blocking and streaming retries.
- [ ] Milestone 3: Document the error boundary and downstream behavior.


## Surprises & Discoveries


2026-09-08: The released `providerError` constructor creates `OtherError`, not a transient error. Updated the transient blocking fixture to set `TransientError`; malformed stream fixtures deliberately retain missing errorInfo to pin legacy behavior. The core suite passes 225 tests, including the full category/attempt matrix and cancellation.

2026-09-08: ReAct has a defensive raw-response check for custom LLM interpreters. Preserve its structured error before considering partial tool calls, while retaining the existing missing-errorInfo fallback.


## Decision Log


2026-09-08: Keep a structured ProviderError alongside the legacy text constructor and make permanent failures non-retryable. This retains caller compatibility while letting released stream terminals use the same classification as completions. Separate billing observation from errors so failures do not become containers for unrelated run totals.


## Outcomes & Retrospective


Milestones 1 and 2 are implemented and the core suite passes. Final downstream regressions, release-source build and full-suite validation are in progress. ADR-11 records the durable error and retry contract.


## Context and Orientation


The baseline is commit `ac70154`. It requires `mori://shinzui/baikai/packages/baikai`, `mori://shinzui/baikai/packages/baikai-claude`, and `mori://shinzui/baikai/packages/baikai-openai` at `>=0.7.0.0 && <0.8`, and `mori://shinzui/baikai/packages/baikai-effectful` at `>=0.4.0.1 && <0.5`. That upgrade already preserves billing metadata in response/checkpoint JSON, preserves opaque replay JSON, recognizes OpenAI Responses for native schema routing, and distinguishes explicit speed in cache keys. Do not repeat that migration. GHC 9.12.4 and Cabal come from `nix develop .#ghc9124-ci`; the system compiler is not the project compiler. No dependency upgrade is required by this plan.

`shikumi/src/Shikumi/Error.hs` owns `ShikumiError`, `fromBaikaiError`, and `isTransient`. Its catch-all mapping currently turns content filtering, authentication failures, and unavailable providers into the same retryable `ProviderFailure Text`. `shikumi/src/Shikumi/LLM.hs` owns both bare interpreters and the resilient retry loop. `streamTerminalError` currently ignores structured information and its comment incorrectly says that terminal payloads lack it. In the published dependency, `baikai/src/Baikai/Stream/Event.hs` defines `TerminalPayload.errorInfo :: Maybe BaikaiError`; this is confirmed in the `baikai-0.7.0.0` tag. `BaikaiError.refusalCategory` is optional provider text, not a closed Shikumi enumeration.

`shikumi/test/ErrorSpec.hs`, `LLMSpec.hs`, `ResilienceSpec.hs`, and `StubProvider.hs` cover mappings and attempt counts. `shikumi/src/Shikumi/Stream.hs` reconstructs successful responses; do not turn failed partial text into successful typed output. Audit downstream pattern matches in evaluator failure policies, optimizer classification, tools, and CLI renderers. [ADR-4](../adr/0004-separate-feedback-attribution-from-execution-evidence.md) requires original failure evidence and forbids swallowing cancellation; [ADR-9](../adr/0009-centralize-offline-harness-and-diverse-fixtures.md) keeps reusable fixtures below consumer packages. No local ADR currently defines refusal classification. Upstream `docs/adr/0011-core-owns-transport-failure-classification.md` in `mori://shinzui/baikai` says refusal categories are preserved verbatim and `ContentFiltered` is terminal, never inferred from message prose. This plan has no hard dependency; [61-expose-billing-quality-and-failed-call-usage-in-reports-and-traces.md](../plans/61-expose-billing-quality-and-failed-call-usage-in-reports-and-traces.md) consumes its error contract.

Locate dependency sources with `mori registry search baikai`, `mori registry show shinzui/baikai --full`, and `mori registry docs shinzui/baikai` before reading APIs. Verify behavior against the release tag, since a sibling checkout can contain newer code. If changing dependency bounds becomes necessary, check Hackage preferred versions and upstream tags first. Never traverse `/nix/store` or the filesystem root. Cross-repository source paths below are relative to `mori://shinzui/baikai`; artifact-level source/ADR handles are pending. Registry searches for the relevant upstream ADR titles returned no handles, so do not invent bundle-scoped ADR IDs.


## Plan of Work


### Milestone 1: Preserve the structured transport failure


Add `ProviderError BaikaiError` to `ShikumiError`. Preserve the existing `ProviderFailure Text` constructor for caller-created legacy errors and scripted interpreters. Keep existing `DecodeFailure`, `InvalidRequest`, and `ContextOverflow` mappings to `InvalidJSON`, `SchemaMismatch`, and `ContextWindowExceeded`, respectively; map every other dependency category to `ProviderError` carrying the original record. Export one readable rendering helper and update affected user-facing callers to use it without dumping credentials or opaque payloads. Preserve the refusal category exactly, including unknown future strings and absence. Run the ErrorSpec cases with records containing both known and unknown category strings; assert equality of the retained record, not only a text substring.

### Milestone 2: Use one classification for blocking and streaming retries


For `ProviderError`, only `RateLimited` and `TransientError` are transient. Authentication, content filtering, unavailable providers, unclassified process exits, and `OtherError` are non-transient. Legacy `ProviderFailure` and `Timeout` keep their current retry behavior. A typed invalid request or context overflow keeps its existing non-transient behavior. Change `streamTerminalError` to use `errorInfo` through `fromBaikaiError` when present. For third-party malformed terminals with no errorInfo, retain the documented legacy ProviderFailure fallback; do not guess categories from prose. Keep charging partial terminal costs before raising on both paths. A refusal produces one actual provider attempt under a max-attempts-three policy; a transient error followed by success produces two. Run the core suite and ensure no extra extraction or tool dispatch occurs after a refusal.

### Milestone 3: Document the error boundary and downstream behavior


Update `docs/user/effects-and-runtime.md`, the core changelog, and affected exhaustive matches. Add a provider error/retry ADR following the profiled ADR workflow. Document the new public sum constructor, the deliberate process/unknown error posture, the legacy fallback, and unchanged host-exception/cancellation propagation. Run all suites and prove refusal attempts are bounded in both APIs without changing GEPA's default scoring of infrastructure failures. This is a change in framework retry policy, not a reimplementation of the provider's transport classifier.


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
nix develop .#ghc9124-ci --command cabal test shikumi shikumi-tools shikumi-eval shikumi-optimize --test-show-details=direct --project-file="$SHIKUMI_PLAN_PROJECT" --builddir="$PWD/dist-newstyle-baikai-plans"
nix develop .#ghc9124-ci --command cabal test all --test-show-details=direct --project-file="$SHIKUMI_PLAN_PROJECT" --builddir="$PWD/dist-newstyle-baikai-plans"
nix fmt
git diff --check
```

Expect exit status zero, the focused named regressions passing, and all enabled suites reporting PASS. Redis and live-provider skips are not evidence that those integrations work. The existing CI job starts Redis and sets `SHIKUMI_REQUIRE_BACKENDS=1`; preserve that gate. Live provider calls remain explicitly opt-in. After implementation changes an ADR, allocate any new handle with `okf id next docs/adr --profile docs/adr/profile.dhall ADR`, maintain its timestamp and `docs/adr/log.md`, and run `just check-adr`. Review public record/sum changes for Haskell PVP release impact and update affected package changelogs; do not publish a release as part of implementation.


## Validation and Acceptance


Acceptance requires a table-driven test of every currently released ErrorCategory, including ProcessFailure and OtherError. Blocking in-band response errors, defensively thrown BaikaiError values, and streamed EventError values must preserve the same classification. A content-filtered response carrying refusalCategory `policy_example` reaches the caller unchanged after one call. A missing category stays Nothing. A rate-limit/transient failure retries and can succeed; auth/unregistered-provider errors do not retry. Legacy ProviderFailure fixtures still retry. Malformed error terminals exercise the documented fallback. Failure cost is charged once per observed attempt before the error escapes, and cancellation is not converted to a provider error. Existing evaluator, optimizer and agent error propagation tests remain green.


## Idempotence and Recovery


The implementation and tests are repeatable and require no external writes. Add regressions before changing behavior; preserve unrelated working-tree edits. Retry failed builds after fixing the reported cause rather than weakening tests or dependency bounds. Keep existing serialized fixtures as immutable compatibility evidence and add new-version fixtures alongside them. Record implementation evidence in the living sections; do not mark the plan complete on compilation alone.


## Interfaces and Dependencies


`Shikumi.Error` owns the additive `ProviderError BaikaiError` constructor, the mapping function, retry predicate, and readable renderer. Baikai retains ownership of ErrorCategory and refusalCategory semantics. The later billing plan may inspect this structured error but must not create a second refusal classifier or infer missing categories. This plan does not add partial usage fields to errors; per-attempt billing belongs to the later observer. No LLM operation constructors, serialized checkpoint versions, provider registrations, or package bounds need to change.

Revision (2026-09-08): Linked this plan to the shared initiative intention created with `mina ci --json`, as requested. Scope and dependencies are unchanged.

Revision (2026-09-08): Implemented structured mappings and retry parity; recorded fixture findings, shared rendering, defensive ReAct handling and core validation. No dependency bounds changed.
