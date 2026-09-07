---
id: 56
slug: add-bounded-recursive-language-model-sessions
title: "Add bounded recursive language-model sessions"
kind: exec-plan
created_at: 2026-09-07T01:50:18Z
master_plan: "docs/masterplans/10-dspy-informed-optimizer-and-agent-evolution.md"
---

# Add bounded recursive language-model sessions


This ExecPlan is a living document. Update implementation evidence and distill durable decisions into ADRs before completion.

## Purpose / Big Picture


A recursive language-model session lets an agent inspect a large document held outside its prompt, store intermediate results and ask bounded sub-model questions about selected excerpts. After this experimental feature, a scripted agent will locate facts in a multi-megabyte document using bounded search and slicing, query a sub-model about selected text, and submit a typed answer without ever copying the entire source into an LM request.

## Progress


Implementation has not started.

## Surprises & Discoveries


No implementation discoveries recorded.

## Decision Log


Decision (2026-09-06): implement a restricted, persistent data-operation session, not a Python interpreter. The initial operations include document search/slice, named intermediate values and budgeted subqueries, making the prototype useful for large contexts without arbitrary host execution.

Decision (2026-09-06): keep state explicit and private per invocation, and run subqueries sequentially initially. This prevents cross-session leakage and makes admission limits deterministic without introducing a subprocess dependency.

Decision (2026-09-06): this plan is independent of structured ReAct and MCP. It exposes its own typed action loop under the existing Program effect boundary; it does not claim unlimited recursion or Python compatibility.

## Outcomes & Retrospective


Implementation and experimental acceptance results are pending.

## Context and Orientation


`shikumi-tools/src/Shikumi/CodeExec/Interpreter.hs` defines `CodeInterpreter` as a stateless text-to-text computation under `LLM` and `Error ShikumiError`. Its `restrictedInterpreter` evaluates a small arithmetic/string/list language with a 10,000-step limit. It cannot persist variables or reference an external document. `shikumi-tools/src/Shikumi/CodeExec/CodeAct.hs` runs model/code turns then extracts a typed answer; it is a useful loop/testing pattern but is not already a recursive language model. `shikumi/src/Shikumi/Program.hs` allows embedded computations under these two effects. `shikumi/src/Shikumi/LLM/Budget.hs` tracks actual model cost and admits calls optimistically; its dollar ceiling can overshoot by an admitted call's cost and must not be described as a strict monetary reservation.

The reference behavior is from `mori://stanfordnlp/dspy`, project-relative `dspy/predict/rlm.py` (artifact-level URI pending; project currently unregistered in Mori). It keeps context in an interpreter, bounds model calls and output, and manages interpreter ownership. This plan transfers those semantics without adding DSPy as a runtime dependency. [ADR-1](../adr/0001-use-profile-governed-architecture-decisions.md) now governs decision records: allocate stable ADR-N handles, preserve decision/provenance metadata, update the bundle index/log, and run `just check-adr`. No earlier feature-specific ADR was found during the initial review.

## Plan of Work


### Milestone 1: persistent bounded context operations


Create `shikumi-tools/src/Shikumi/CodeExec/Session.hs` and `shikumi-tools/test/SessionSpec.hs`. Define immutable `ContextStore` mapping caller document names to `Text`, private `SessionState` holding variables and counters, and a typed `SessionAction` parsed from model JSON. Implement `Describe name`, `Slice name start count`, `Find name needle start limit`, `Store name Value`, `Load name`, and `Submit Value`. Offsets and limits count Unicode characters, use half-open slices, and reject negative/out-of-range positions. `Find` is literal substring search, bounded by scanned characters and returned matches, without regular-expression dependencies. Describe exposes only name/length metadata; it never renders document contents.

Validate positive limits at initialization. Bound accepted context characters, stored-value characters, action bytes, per-observation characters, total observed characters and operation count. Reject invalid operations with recoverable observations; consume the operation budget on failures too. Include explicit truncation metadata when displaying a prefix, with offsets enabling a follow-up slice. Keep the original store immutable and separate from model-writable variables; names are checked so variables cannot shadow documents or built-in operations. Pure tests prove values persist across actions and independent sessions cannot observe one another.

### Milestone 2: budgeted model subqueries


Add `Query prompt` and `QueryBatch [prompt]` operations interpreted in the existing effect row. A `SessionConfig` holds a sub-model selector, `maxSubqueries`, `maxSubqueryChars` and the other limits above. Reserve the entire batch's call slots before dispatch; reject an oversized batch without making any call. Execute accepted batches sequentially and return results in original order. Charge attempted calls, including failures; do not restore slots after errors. Calls go through the same `LLM` interpreter as the outer loop so cost, tracing and runtime resilience remain shared. Never recursively invoke the outer RLM loop from a subquery; the initial depth is one.

Use a scripted LM to prove a three-question batch at a two-call limit makes zero subcalls, while two accepted queries make exactly two. Preserve cancellation/infrastructure errors on `ShikumiError`; do not convert them into apparently successful text. The count limit is exact, whereas actual dollar spending retains the existing optimistic budget contract.

### Milestone 3: typed large-context agent loop


Create `shikumi-tools/src/Shikumi/CodeExec/RLM.hs` with `rlm` and `rlmWithReport` Program constructors. They receive a signature for the ordinary question, an explicit immutable context store and a config; the source documents do not become `ToPrompt` input fields. Build each initial request from instructions, ordinary question, available document names/lengths, action grammar and limits. Append only bounded observations and actions thereafter. Parse model responses into `SessionAction`, feed recoverable action errors back, and stop on typed `Submit` validated with `FromModel`/`Validatable`. Invalid submissions consume an iteration and can be corrected while budget remains. Exhaustion returns `RLMExhausted SessionLimit` with the accumulated report from the reporting API; the plain `rlm` convenience API maps it to a typed `ShikumiError`. It never makes an extra extraction, summarization or repair call outside the budget. Each corrective outer response consumes an outer iteration, and all sub-model requests reserve a subquery slot before dispatch.

Bound outer iterations and all prompt growth; when the retained observation budget is exceeded stop with a clear exhaustion result rather than silently rebuilding a giant prompt. Store full bounded audit records in `RLMReport`, including operation counts, subquery attempts, truncation events and termination. Begin with pure session state scoped by the loop, so resource cleanup needs no host process or mutable global interpreter. Test normal completion, recoverable parse errors, empty documents, Unicode slicing and exhausted limits.

### Milestone 4: experimental demonstration and packaging


Wire the modules and new test files into `shikumi-tools/shikumi-tools.cabal` and the existing test entry point. Add `shikumi-tools/test/RLMSpec.hs` with a generated two-megabyte document containing two known facts far apart. Script `Find`, bounded `Slice`, `Store`, subquery and `Submit` actions; assert the final typed answer combines the facts and no captured request contains the entire document or exceeds the configured request bound. A second concurrent or interleaved invocation uses different facts and proves state isolation.

Document the restricted action language, all limits and a complete usage example under `docs/user/`. Label the API experimental. Promotion requires all large-context, isolation and exact subquery-admission tests to pass; otherwise leave the prototype incomplete and record the missing behavior. Arbitrary Python, process sandboxes, remote interpreters and deeper recursion remain later work. Record the session ownership and budget distinction in an ADR during implementation.

## Concrete Steps


Run from the repository root:

```bash
cd /Users/shinzui/Keikaku/bokuno/shikumi
mori registry show shinzui/baikai --full
mori registry docs shinzui/baikai
nix develop .#ghc9124 -c cabal build shikumi-tools
nix develop .#ghc9124 -c cabal test shikumi-tools
nix develop .#ghc9124 -c cabal build all
```

These commands should report successful compilation and a passing shikumi-tools test suite, including SessionSpec and RLMSpec. Record actual test output during implementation. Locate every new dependency API through Mori first; if introducing a dependency or bound, verify the released version on its authoritative registry and upstream tags. This design requires no new interpreter dependency.

## Validation and Acceptance


The end-to-end fixture must produce the expected two-fact typed answer while every captured request remains below its configured character ceiling and no request includes the two-megabyte source. Assert exact operation/subquery counts and that stored results survive multiple actions. Use the real loop and scripted LLM interpreter, not only isolated action helpers.

Adversarial fixtures cover invalid offsets, Unicode boundaries, oversized sources/variables/prompts, unknown names, built-in shadowing, malformed actions, invalid final output, zero/negative config limits, batch over-admission, a failed subquery, and exhausted outer/subquery/output budgets. Rejected batches invoke no LM; rejected oversized operations do not mutate session state. Independent runs share neither variables nor counters. Existing CodeAct, ProgramOfThought and ReAct tests continue passing because the original interpreter API is unchanged.

## Idempotence and Recovery


The context store is immutable and session state is an explicit value per invocation. Tests/builds are repeatable. A failed action leaves stored values unchanged but consumes its admission count; infrastructure failures terminate the run. Restarting a run starts fresh counters and may repeat LM calls, so it is an explicit caller choice, not an automatic recovery promise. No filesystem, network or process access is granted by the restricted operation evaluator; only the injected LM capability performs external requests.

## Interfaces and Dependencies


`Shikumi.CodeExec.Session` owns opaque `ContextStore`, `SessionState`, `SessionConfig`, `SessionAction`, `SessionObservation`, `SessionError`, constructors that validate limits, and pure context-operation evaluation. `SessionObservation` carries a value, optional truncation metadata and a recoverable error; state transitions return a new state instead of mutating global state. `Query` interpretation lives in RLM because it needs `LLM`.

`Shikumi.CodeExec.RLM` owns `RLMConfig`, `RLMReport`, `rlm :: (ToPrompt i, ToSchema o, FromModel o, Validatable o) => RLMConfig -> ContextStore -> Signature i o -> Program i o`, and `rlmWithReport` with the same arguments returning `Program i (RLMOutcome o, RLMReport)`. Define `RLMOutcome o = RLMSubmitted o | RLMExhausted SessionLimit`, with `SessionLimit` identifying the exhausted outer-iteration, operation, subquery, request-character or observation-character allowance. Reports identify the same termination and contain the counters and audit records accumulated before it. The plain `rlm` returns the value from `RLMSubmitted` and maps `RLMExhausted` to a typed `ShikumiError`; introduce a specific exhaustion constructor in `shikumi/src/Shikumi/Error.hs` if existing constructors cannot express this accurately, updating exhaustive matches and tests. Infrastructure errors propagate as `ShikumiError` rather than becoming an exhaustion outcome. Neither API issues hidden extraction, repair or summary queries after a limit is reached. Name the config's explicit request bound `maxRequestChars` and validate it before each outer and sub-model call.

Use existing `text`, `aeson`, `containers`, `vector`, `effectful`, and the shikumi LLM/Program APIs. This plan has no hard dependency on other new plans. It owns only its new session/RLM modules and tests plus Cabal/docs integration; it does not replace `CodeInterpreter`, modify MCP transport or add arbitrary code execution.

Revision (2026-09-06): linked the newly bootstrapped ADR bundle and its authoring/check contract; implementation status is unchanged.
