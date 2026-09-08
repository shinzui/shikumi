---
id: 60
slug: apply-shared-request-defaults-across-programs-and-agent-calls
title: "Apply shared request defaults across programs and agent calls"
kind: exec-plan
created_at: 2026-09-08T16:50:38Z
master_plan: "docs/masterplans/11-adopt-baikai-runtime-capabilities-safely.md"
intention: "intention_01m20zkyrpeewr6kxrzatngqt3"
---

# Apply shared request defaults across programs and agent calls


This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture


A caller should configure reasoning effort, inference speed, output-token limits, and evidence once for an entire typed program, including its agent, repair, summary and streaming calls. Per-call choices must remain authoritative and independent concurrent runs must not leak settings. An offline capturing interpreter will show the effective request for every path.


## Progress


- [x] (2026-09-08) Milestone 1: Define an explicit default merge.
- [x] (2026-09-08) Milestone 2: Apply defaults at the effective request boundary.
- [x] (2026-09-08) Milestone 3 regressions: routing, concurrency, evidence bypass and effective cache keys pass.
- [x] (2026-09-08) Milestone 3 completion: compiled example runs successfully; full release-source build and all 13 suites pass.


## Surprises & Discoveries


2026-09-08: The released Options and EvidenceRequest types support the finite merge directly. Routing replaces every model by design; defaults preserve distinct recursive sub-models when used without that ambient router. The reusable capture interposer lives in the internal harness; existing RLM scripts now assert defaults on every actual call.

2026-09-08: Focused release-source validation passed 237 core, 128 tools and 33 cache tests. The deliberately misplaced-cache regression demonstrates one base call despite changed defaults; the correct order distinguishes speeds and reasoning while reusing equivalent effective options.


## Decision Log


2026-09-08: Use a small fill-only request-default vocabulary at the LLM seam. This covers every existing runner without broadening Program serialization or allowing defaults to overwrite schema/tool policy. Model routing stays independent.


2026-09-08: Use the existing terminal `ValidationFailure` for invalid default configuration; no new error constructor is needed. Reject zero default ceilings when entering the scope, including when an explicit call could override them. Pure merging stays total and validation-free. ADR-12 records the durable precedence, model boundary, composition order and evidence policy.


## Outcomes & Retrospective


EP-60 is complete. Commit `661204c` implements the defaults layer, evidence cache bypass and focused regressions. The compiled `jitsurei-request-defaults` example demonstrates routing, defaults, trace and cache together: three typed runs make two base calls. The full GHC 9.12.4 build and all 13 test suites pass against Hackage repo-tar sources: Baikai core/Claude/OpenAI 0.7.0.0 and Effectful 0.4.0.1. Redis ran zero tests; live-provider and embedding checks were skipped. No live-provider claim follows from this validation.

ADR-12 distills precedence, invocation isolation, the router/sub-model distinction, finite vocabulary and evidence bypass. User guides and affected changelogs are updated. No dependency bounds or package versions changed. EP-61 can observe effective requests below cache; EP-62 can reuse the compiled stack. Requested preferences remain distinct from provider execution evidence.


## Context and Orientation


The baseline is commit `ac70154`. It requires `mori://shinzui/baikai/packages/baikai`, `mori://shinzui/baikai/packages/baikai-claude`, and `mori://shinzui/baikai/packages/baikai-openai` at `>=0.7.0.0 && <0.8`, and `mori://shinzui/baikai/packages/baikai-effectful` at `>=0.4.0.1 && <0.5`. That upgrade already preserves billing metadata in response/checkpoint JSON, preserves opaque replay JSON, recognizes OpenAI Responses for native schema routing, and distinguishes explicit speed in cache keys. Do not repeat that migration. GHC 9.12.4 and Cabal come from `nix develop .#ghc9124-ci`; the system compiler is not the project compiler. No dependency upgrade is required by this plan.

`shikumi/src/Shikumi/Adapter.hs` creates Options from emptyOptions, while `Shikumi.Program` stamps schemas and sample temperatures. `shikumi/src/Shikumi/Routing.hs` replaces placeholder models and realizes those stamps identically for Complete and Stream. `shikumi-tools/src/Shikumi/Agent/ReAct.hs`, `Shikumi/CodeExec/CodeAct.hs`, and `shikumi/src/Shikumi/Compaction.hs` construct further requests with local Options. `shikumi-tools/src/Shikumi/CodeExec/Session.hs` supplies distinct sub-model requests; defaults must not silently replace their models. `shikumi-cache/src/Shikumi/Cache/Key.hs` already includes explicit speed. The core model route and default application are separate transformations.

[ADR-7](../adr/0007-bound-recursive-sessions-at-the-llm-operation-boundary.md) requires all recursive calls to pass through LLM admission and prohibits hidden RLM calls. [ADR-9](../adr/0009-centralize-offline-harness-and-diverse-fixtures.md) requires shared capturing fixtures to live in the internal harness when reusable. [ADR-12](../adr/0012-apply-request-defaults-before-cache-and-observation.md) now defines fill-only precedence, routing/defaults/cache order and evidence bypass. Upstream `mori://shinzui/baikai`, project-relative `docs/adr/0002-requested-translated-observed-are-never-collapsed.md` (artifact-level URI pending), and the registered guide `mori://shinzui/baikai/docs/model-call-evidence` distinguish a requested setting from what a provider actually accepted. No other child is a hard dependency. Integrate middleware ordering with [59-guard-reasoning-state-across-session-compaction-and-model-changes.md](../plans/59-guard-reasoning-state-across-session-compaction-and-model-changes.md) and final usage observation with [61-expose-billing-quality-and-failed-call-usage-in-reports-and-traces.md](../plans/61-expose-billing-quality-and-failed-call-usage-in-reports-and-traces.md).

Locate dependency sources with `mori registry search baikai`, `mori registry show shinzui/baikai --full`, and `mori registry docs shinzui/baikai` before reading APIs. Verify behavior against the release tag, since a sibling checkout can contain newer code. If changing dependency bounds becomes necessary, check Hackage preferred versions and upstream tags first. Never traverse `/nix/store` or the filesystem root. Cross-repository source paths below are relative to `mori://shinzui/baikai`; artifact-level source/ADR handles are pending. Registry searches for the relevant upstream ADR titles returned no handles, so do not invent bundle-scoped ADR IDs.


## Plan of Work


### Milestone 1: Define an explicit default merge


Create `shikumi/src/Shikumi/LLM/Defaults.hs` exposing RequestDefaults, emptyRequestDefaults, applyRequestDefaults, and withRequestDefaults. RequestDefaults contains only optional ThinkingLevel, Speed, Natural maxTokens, and EvidenceRequest values. Do not accept arbitrary Options or include model selection, tools, responseFormat, authentication headers, or Shikumi private metadata. applyRequestDefaults fills an absent field and never changes a present per-request field. Empty defaults are the identity. Keep empty defaults as no evidence request and no inferred fast mode. Reject a configured zero token ceiling before provider dispatch with a typed invalid-configuration error. Request-scoped evidence settings override the entire default EvidenceRequest; never merge their internal fields into an undocumented policy. Prove pure merge behavior before adding the interposer.

### Milestone 2: Apply defaults at the effective request boundary


Implement withRequestDefaults as an LLM interposer handling Complete and Stream identically. Place it outside cache/trace wrappers in effect execution order, so routing finishes first, defaults are applied next, and caches/traces receive the actual options. In function-composition notation the application stack is base interpreter composed with trace/cache composed with withRequestDefaults composed with routeLLM; the rightmost wrapper sees the originating call first. Show a compiling stack in docs rather than relying on this sentence alone. Nested default scopes let the innermost scope win because it fills fields before outer scopes. An explicit per-call setting wins over every scope. Keep the interposer pure and invocation-scoped, with no global IORef. Add tests covering a typed prediction, a stream, an agent proposal, a summary, and a recursive subquery; all calls pass through the same seam and no new model requests are introduced.

### Milestone 3: Demonstrate cache, routing and concurrency behavior


Add capturing regressions in core RoutingSpec and a new RequestDefaultsSpec, agent/summary regressions in tools, and cache regressions in the cache suite. Requests carrying any EvidenceRequest must bypass memoizer reads and writes: a cached Response deliberately omits evidence and cannot establish a new provider crossing. Implement that policy in shikumi-cache/src/Shikumi/Cache.hs after defaults are applied, for both direct and default-supplied evidence. Ordinary calls without evidence retain existing caching. Equal effective cacheable options must produce equal cache keys regardless of whether a value came from defaults or a direct call; fast versus standard and reasoning-level changes must not reuse entries. Verify reserved schema/tool metadata and explicit temperatures are unchanged, providers still decide unsupported-option handling, and two concurrent runs with different defaults remain independent. Export the module in the cabal manifest, add docs to effects-and-runtime and caching-tracing-replay, record an ADR for precedence/order, and add a compiled example consumed by the Responses plan.


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
nix develop .#ghc9124-ci --command cabal test shikumi shikumi-tools shikumi-cache --test-show-details=direct --project-file="$SHIKUMI_PLAN_PROJECT" --builddir="$PWD/dist-newstyle-baikai-plans"
nix develop .#ghc9124-ci --command cabal test all --test-show-details=direct --project-file="$SHIKUMI_PLAN_PROJECT" --builddir="$PWD/dist-newstyle-baikai-plans"
nix fmt
git diff --check
```

Expect exit status zero, the focused named regressions passing, and all enabled suites reporting PASS. Redis and live-provider skips are not evidence that those integrations work. The existing CI job starts Redis and sets `SHIKUMI_REQUIRE_BACKENDS=1`; preserve that gate. Live provider calls remain explicitly opt-in. After implementation changes an ADR, allocate any new handle with `okf id next docs/adr --profile docs/adr/profile.dhall ADR`, maintain its timestamp and `docs/adr/log.md`, and run `just check-adr`. Review public record/sum changes for Haskell PVP release impact and update affected package changelogs; do not publish a release as part of implementation.


## Validation and Acceptance


An empty default layer leaves requests byte-equivalent in their cache serialization. A default fast speed reaches both Complete and Stream unless the request says standard. An explicit thinking level and token limit override defaults; nested scopes use the nearer default. Schema, automatic tool choice, sample temperature and selected sub-model remain unchanged. An injected agent summary request receives the same defaults without any additional calls. Strict evidence request objects reach the transport unchanged; even a prepopulated cache cannot satisfy an evidence request. Two evidence-requesting calls make two provider calls, while identical ordinary calls still memoize. No test claims requested settings prove actual model execution. Different run settings remain isolated under concurrency. A deliberately misplaced cache wrapper test illustrates the wrong order, while the documented composition passes the cache differentiation test.


## Idempotence and Recovery


The implementation and tests are repeatable and require no external writes. Add regressions before changing behavior; preserve unrelated working-tree edits. Retry failed builds after fixing the reported cause rather than weakening tests or dependency bounds. Keep existing serialized fixtures as immutable compatibility evidence and add new-version fixtures alongside them. Record implementation evidence in the living sections; do not mark the plan complete on compilation alone.


## Interfaces and Dependencies


Proposed public signatures in Shikumi.LLM.Defaults are `emptyRequestDefaults :: RequestDefaults`, `applyRequestDefaults :: RequestDefaults -> Options -> Options`, and `withRequestDefaults :: (LLM :> es, Error ShikumiError :> es) => RequestDefaults -> Eff es a -> Eff es a`. The pure merge takes validated data; the interposer performs configuration validation before any call. RequestDefaults has named optional defaultThinking, defaultSpeed, defaultMaxTokens, and defaultEvidence fields using released Baikai types. Keep this finite vocabulary, with no model field. The session plan owns history validation, not this module. Billing observes after defaults, but cost calculations remain provider-owned. Existing Program and Params serialization is unchanged; defaults belong to runtime configuration, not compiled artifacts.

Revision (2026-09-08): Linked this plan to the shared initiative intention created with `mina ci --json`, as requested. Scope and dependencies are unchanged.

Revision (2026-09-08): Implemented milestones 1 and 2 and focused milestone 3 regressions; documented the existing typed validation error and router/sub-model distinction. Full acceptance is pending.

Revision (2026-09-08): Completed full acceptance and ADR distillation. Validation used the temporary release-source project printed by the Concrete Steps script, with `--builddir=dist-newstyle-baikai-plans` resolved relative to that temporary project. The workstation override was untouched. Full build and `cabal test all` exited zero; `nix fmt`, `git diff --check`, and strict `just check-adr` passed. The compiled example exited zero with:

```text
Three typed runs, two base calls: ordinary repeat cached; evidence request dispatched.
Requested: high thinking, standard speed, 4096 output tokens. Offline stub supplies no provider evidence.
```
