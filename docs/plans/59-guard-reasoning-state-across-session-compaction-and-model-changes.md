---
id: 59
slug: guard-reasoning-state-across-session-compaction-and-model-changes
title: "Guard reasoning state across session compaction and model changes"
kind: exec-plan
created_at: 2026-09-08T16:50:38Z
master_plan: "docs/masterplans/11-adopt-baikai-runtime-capabilities-safely.md"
intention: "intention_01m20zkyrpeewr6kxrzatngqt3"
---

# Guard reasoning state across session compaction and model changes


This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture


Resuming a reasoning-enabled agent must either send the original continuation in a compatible conversation or stop before sending an invalid request. Compaction must never expose encrypted reasoning to a summarizer. Users retain the full audit and can explicitly start a fresh conversation from a safe summary when the old prefix cannot be preserved.


## Progress


- [ ] Milestone 1: Separate audit data, safe summaries and replayable history.
- [ ] Milestone 2: Bind persisted continuation to its origin and validate after routing.
- [ ] Milestone 3: Provide an explicit fresh conversation and migration documentation.


## Surprises & Discoveries


(None yet.)


## Decision Log


2026-09-08: Conservatively refuse to replay opaque continuation across a changed prefix or unknown origin. Defer automatic compaction rather than mutate signed exchanges; require explicit fresh-session creation for a reset. Protect summary inputs structurally and preserve the independent audit.


## Outcomes & Retrospective


(To be filled during and after implementation.)


## Context and Orientation


The baseline is commit `ac70154`. It requires `mori://shinzui/baikai/packages/baikai`, `mori://shinzui/baikai/packages/baikai-claude`, and `mori://shinzui/baikai/packages/baikai-openai` at `>=0.7.0.0 && <0.8`, and `mori://shinzui/baikai/packages/baikai-effectful` at `>=0.4.0.1 && <0.5`. That upgrade already preserves billing metadata in response/checkpoint JSON, preserves opaque replay JSON, recognizes OpenAI Responses for native schema routing, and distinguishes explicit speed in cache keys. Do not repeat that migration. GHC 9.12.4 and Cabal come from `nix develop .#ghc9124-ci`; the system compiler is not the project compiler. No dependency upgrade is required by this plan.

`shikumi-tools/src/Shikumi/Agent/History.hs` owns completed exchanges and checkpoint format version 1. promptEntries replaces an old prefix with a synthetic summary user turn, and entryMessages preserves the later assistant payloads. `shikumi-tools/src/Shikumi/Agent/ReAct.hs` implements advanceSession, requestRecover, forceCompact and checkSession. forceCompact currently serializes complete entryMessages to JSON for the summarizer, including opaque thinking data. Its request uses emptyModel; `shikumi/src/Shikumi/Routing.hs` later selects the real target. Session fingerprints contain instruction/schema/protocol/tool definitions but not model provenance. `shikumi/src/Shikumi/Compaction.hs` also serves legacy textual trajectories; retain their behavior when they contain no opaque state.

Opaque continuation means any AssistantThinking block with a signature, redacted=True, or replayState present. An empty visible summary does not mean no continuation. Released dependency source `baikai/src/Baikai/Content.hs` in `mori://shinzui/baikai` defines ThinkingReplay as API, model ID, and ordered JSON items. Its `docs/adr/0019-reasoning-continuation-is-scoped-to-its-provider-and-model.md` requires origin checks and exact preservation. The registered guide `mori://shinzui/baikai/docs/tools` further records that Claude thinking can depend on the preceding prompt, tools and messages. Prefix safety is therefore a Shikumi responsibility.

[ADR-6](../adr/0006-preserve-completed-react-exchanges-in-versioned-sessions.md) requires complete exchanges, full audit preservation, exact compatibility checks, and at most one context-recovery request. Extend that contract rather than reopening completed plan 54. [ADR-7](../adr/0007-bound-recursive-sessions-at-the-llm-operation-boundary.md) concerns a separate bounded textual RLM with no hidden summaries; keep that API outside this migration. [ADR-9](../adr/0009-centralize-offline-harness-and-diverse-fixtures.md) governs reusable fixtures. No existing ADR specifies reasoning-safe compaction. There are no hard child dependencies; coordinate dispatch order with [60-apply-shared-request-defaults-across-programs-and-agent-calls.md](../plans/60-apply-shared-request-defaults-across-programs-and-agent-calls.md). The core guard belongs to this plan, even if request defaults have not been implemented.

Locate dependency sources with `mori registry search baikai`, `mori registry show shinzui/baikai --full`, and `mori registry docs shinzui/baikai` before reading APIs. Verify behavior against the release tag, since a sibling checkout can contain newer code. If changing dependency bounds becomes necessary, check Hackage preferred versions and upstream tags first. Never traverse `/nix/store` or the filesystem root. Cross-repository source paths below are relative to `mori://shinzui/baikai`; artifact-level source/ADR handles are pending. Registry searches for the relevant upstream ADR titles returned no handles, so do not invent bundle-scoped ADR IDs.


## Plan of Work


### Milestone 1: Separate audit data, safe summaries and replayable history


Add pure classification and summary-projection helpers to Shikumi.Agent.History. Summaries include readable non-redacted text, tool names/arguments/results and explicit omission markers where needed, but never signature strings, replayState JSON, or redacted thinking text. Build this projection structurally, not with string replacement. Keep auditHistory and encodeSession lossless. Add separate transport-valid Claude and Responses fixtures: the current persistence test deliberately combines their metadata and cannot prove either wire protocol. Detect whether a proposed compaction boundary would change the prefix preceding a retained opaque block. Automatic proactive compaction must defer in that case; forced context-overflow recovery must return an actionable typed history error without a summary request or another doomed provider request. No-reasoning histories retain existing compaction and bounded retry behavior. Run AgentHistorySpec with capturing summary requests and actual tool counters.

### Milestone 2: Bind persisted continuation to its origin and validate after routing


Add a version-2 checkpoint field describing known provider/API/model origin or explicitly unknown origin, plus the exact request-view compatibility information needed to guard continuation. Keep reading version 1; histories without opaque state may bind on their next resolved request and conforming response, while legacy opaque histories with unknown origin require an explicit fresh-session path. Never assign an origin from the current ambient model merely to make an old checkpoint pass. Add an explicit-model session constructor for callers that need a known requested target before the first call. Provenance means resolved request identity, not provider attestation: Response.model echoes the input Model. A conforming response can carry that request identity back to the session, but it must never be labeled as an observed provider model. Cross-check Responses ThinkingReplay.replayApi/replayModel against this request identity. Consult observed-model evidence only when present; keep it separate and do not require a request alias to equal a provider-reported model string. When resolved request origin cannot be established, retain unknown and reject subsequent opaque replay with a useful diagnostic.

Create `shikumi/src/Shikumi/LLM/Continuation.hs` to own the provider-independent validation helper and reserved metadata vocabulary. ReAct stamps the expected origin and exact protected prefix on its request; routeLLM validates against the resolved model before emitting the routed call, and built-in bare/resilient interpreters validate again before transport. Cache memoizers validate before lookup so an old cache entry cannot bypass the guard. Checks are pure and idempotent. Provider adapters must never receive private continuation metadata: strip it only at the final transport boundary, while effective context/options still reach cache key computation. Validate provider, API, model and endpoint identity conservatively; compare ordered messages/system/tools for the protected prefix, excluding only construction timestamps already excluded by cache canonicalization. Do not hash secrets into durable checkpoint fields or persist headers/API keys. No global mutable session state is introduced.

Update effect constraints where validation needs Error ShikumiError and test both routed calls and direct explicit-model calls. A custom interpreter that bypasses framework boundaries is outside enforcement; document its obligation instead of claiming universal validation. Reject incompatible origin before provider and tool dispatch. Keep exact reasoning bytes and call/result order when the prefix and target agree. Do not remove a signature or replay item while retaining the rest of the same native exchange and claim it became valid.

### Milestone 3: Provide an explicit fresh conversation and migration documentation


Expose a fresh-session operation accepting an existing session and a caller-approved plain-text summary. It returns a separate unbound conversation with no native old exchanges; the original audit remains unchanged and available to the caller. It must not call a model, execute old tools, or silently migrate the active session. Provide a safe summary input renderer for a caller that wants to obtain such a summary separately. Test a resumed version-2 session, a legacy version-1 plain session, an unknown-origin opaque checkpoint, model/API switches, deferred compaction, forced overflow, and explicit restart. Update docs/user/resumable-react-sessions.md, the compiled ReActSessionExample test, affected changelogs, and ADR-6 or a narrowly linked successor. Run core, cache, tools and full workspace suites.


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


Valid same-origin Claude signed empty thinking and valid Responses encrypted replay round-trip exactly and reach the next captured request unchanged. A different API, provider, model or endpoint fails before any provider/tool dispatch. An unchanged compatible target succeeds. Prefix replacement with retained opaque reasoning is deferred proactively and fails actionably during forced recovery without invoking the summarizer. Safe summary requests contain none of unique sentinel strings placed in signature, replay JSON and redacted text, even when nested among rich tool outputs. Audit serialization still contains the original bytes. Plain-text compaction still summarizes once and retries at most once. Version-1 unknown provenance is not silently blessed, and malformed future checkpoint versions fail clearly. Restart creates a separate plain conversation with zero old tool calls, preserving the old checkpoint. Existing context-overflow and no-duplicate-dispatch tests stay green.


## Idempotence and Recovery


Checkpoint changes are additive readers plus a new writer version. Keep immutable version-1 fixtures and write new checkpoints to separate files; never rewrite a user's archive in place. A rejected resume must leave the original checkpoint usable under its original compatible runtime. A fresh session is a separate value and never overwrites the old audit. Repeatable tests use scripted providers and temporary files. If a provenance approach cannot validate request/response aliases safely, retain unknown provenance and fail locally rather than infer identity. Record this limitation and its supported explicit-binding path. Do not weaken signature guards to make a live model accept a test.


## Interfaces and Dependencies


Shikumi.Agent.History owns the checkpoint version, opaque-state classifier, summary projection, origin record and pure compaction assessment; keep its constructor opaque. Proposed public operations are `renderSessionSummaryInput :: ReActSession -> Text` and `restartSessionFromSummary :: Text -> ReActSession -> Either HistoryError ReActSession`, plus the explicit-model start operation in Shikumi.Agent.ReAct. Shikumi.LLM.Continuation owns `validateRequestContinuation :: Model -> Context -> Options -> Either ShikumiError ()` and final private-metadata removal. Session-specific structures stay out of core; core consumes a minimal validated expectation encoded in private metadata. Model identity is checked after routing; defaults change only request controls and cannot erase expectations. The existing error mapping may use ValidationFailure for a local incompatible-history error. Cross-plan updates to Routing.hs must preserve the shared order: route, validate continuation, defaults, cache/trace, final validation and stripping, transport.

Revision (2026-09-08): Linked this plan to the shared initiative intention created with `mina ci --json`, as requested. Scope and dependencies are unchanged.
