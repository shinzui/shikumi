---
id: 1
slug: shikumi-typed-lm-programming-framework
title: "Shikumi: Typed LM Programming Framework"
kind: master-plan
created_at: 2026-06-08T02:33:47Z
intention: "intention_01ktjgkp10ef79vpwz1cmajek9"
---

# Shikumi: Typed LM Programming Framework

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

Shikumi (仕組み — "the mechanism, the system behind how something works") is a
Haskell-native framework for building language-model (LM) programs that behave like
ordinary, well-typed software rather than collections of prompt strings. After this
initiative is complete, a Haskell developer can declare an LM-powered function whose
input and output are ordinary Haskell record types, run it against any provider, cache
and trace every call, evaluate it against a dataset with typed metrics, and have an
optimizer search for better demonstrations and instructions — all without ever writing a
raw prompt string or hand-parsing model output.

The single sentence that captures the end state: a user writes

```haskell
summarize :: (LLM :> es, Trace :> es, Cache :> es) => Program Article Summary
summarize = predict @Summarize
```

where `Article` and `Summary` are their own record types, runs `runProgram summarize
article` inside an `Eff` stack, and gets back a fully decoded `Summary` value — with the
JSON schema sent to the provider derived from `Summary`'s structure, the response decoded
and validated against that schema, the call cached and traced, and the whole thing
evaluable and optimizable.

What "done" looks like, concretely (user-visible behaviors enabled by the end of the
initiative):

1. **Typed programs.** Declare `Program i o` where `i` and `o` are Haskell records;
   invalid pipelines fail to compile. Build programs from `predict`, `chainOfThought`,
   `react`, and combinators (`Retry`, `Validate`, `Pipeline`, `Map`, `Parallel`,
   `MajorityVote`, `Ensemble`).
2. **Structured I/O by default.** Output decoding is schema-driven and total: every call
   returns either a typed value or a precise, enumerated error (invalid JSON, missing
   field, schema mismatch, validation failure, provider failure, timeout, budget
   exceeded). Free-text parsing is an explicit escape hatch, not the default.
3. **Production runtime.** Retries, rate limiting, budget controls, caching (memory /
   SQLite / Postgres / Redis), and deterministic replay from stored traces all work.
4. **First-class evaluation.** Run any program over a `Dataset i o` with a typed
   `Metric o`, get a `Report` with score, latency, token usage, cost, and failure
   analysis. Golden tests integrate with the project's test runner.
5. **Compilation and optimization.** Compile a program zero-shot, few-shot, with
   chain-of-thought, or retrieval-augmented; then optimize it (demo selection, bootstrap
   few-shot, instruction search, ensemble search) against a dataset and metric.
6. **Agents.** Typed tools (`Tool i o`) and a ReAct loop for multi-step tool-using
   programs.
7. **DX.** A `shikumi` CLI exposing `eval`, `trace`, `optimize`, and `replay`, plus
   OpenTelemetry observability.

**Design stance — first principles over a literal port.** Shikumi is *inspired by* DSPy
(Stanford's framework for programming — not prompting — language models) but is designed
from first principles to leverage Haskell's type system. Where DSPy relies on Python
dynamism (runtime frame introspection to resolve field types, Pydantic runtime coercion,
a mutable global `settings` object, and in-place mutation of a module tree by optimizers),
shikumi uses static alternatives: GHC `Generics` to derive field schemas and prompt
rendering from record types at compile time; `effectful` effects to make each program's
capabilities (LLM access, tracing, caching, error) visible in its type; and a typed deep
embedding of `Program i o` (a GADT — a generalized algebraic data type, i.e. a data type
whose constructors carry their own type indices — that *is* the program as inspectable
data) so that optimizers can traverse and rewrite a program's parameters without runtime
reflection while composition remains type-checked.

**Relationship to baikai (no duplication).** Baikai
(`/Users/shinzui/Keikaku/bokuno/baikai`, the user's published "媒介 / mediation" library)
already provides the entire provider/transport layer: provider dispatch by `Model`, a
generated model catalog (Claude, OpenAI, DeepSeek, OpenRouter, any OpenAI-compatible host
including Ollama via the `Custom` API tag), typed `Content`/`Message`/`Tool`, the
streaming `AssistantMessageEvent` algebra, `Usage`/`Cost` accounting, the `BaikaiError`
model, and a `TraceSink` (a flat `Fold IO TraceEvent ()`, with an optional OpenTelemetry
adapter). **Shikumi does not reimplement any of this.** Shikumi sits on top of baikai and
adds exactly the layers baikai deliberately omits: structured/schema output, response
caching, retries/backoff/rate-limiting, hierarchical (nested) traces, effect-system
integration, and the entire program/evaluation/compilation/optimization stack. One work
stream (EP-2) contributes a single feature *back into baikai* — native structured-output
support (`response_format` / JSON schema) — because the user chose provider-enforced
schemas over prompt-coaxed ones, and that capability belongs in the transport layer.

Two contributions land in the baikai repository itself rather than in shikumi. EP-2 (above)
is one. The second, **`baikai-effectful`**, is **already delivered** — a thin, policy-free
`effectful` binding over baikai's transport, now a published sibling package in the baikai
repo (module `Baikai.Effectful`). It provides a dynamic `Baikai` effect with operations
`Complete` (blocking), `StreamCollect` (materialized event list), and the higher-order
`StreamEach` (per-event callback running in the caller's `Eff es`), plus interpreters
`runBaikai` (global registry) and `runBaikaiWith` (explicit registry), carrying no retries,
caching, budgets, or error remapping. EP-1's higher-level `LLM` effect is built *in terms of*
it, so shikumi's framework code dispatches through an effect and never touches `IO`/`IOE`
directly — only the bottom interpreter does. `baikai-effectful` is tracked as its own
ExecPlan in the baikai repo
(`/Users/shinzui/Keikaku/bokuno/baikai/docs/plans/23-baikai-effectful-effectful-transport-binding.md`,
all four milestones complete as of 2026-06-08), not as a child of this MasterPlan, but it is
a hard dependency of EP-1 — now satisfied. (Parameterizing baikai over `MonadIO m` was
considered and rejected — see the Decision Log.)

**In scope:** everything in the seven behaviors above, across the spec's V0.1–V0.5
roadmap, plus the one upstream baikai extension.

**Out of scope:** building a new provider abstraction (baikai owns this), a retrieval/
vector-store implementation (the RAG compiler defines the *interface* and ships a trivial
in-memory retriever; production retrievers are future work), a web UI (the trace/replay
surface is CLI + OTel), and fine-tuning / weight-level optimization (shikumi optimizes
prompts, demonstrations, and program structure, not model weights).


## Decomposition Strategy

The initiative is decomposed into **twelve child ExecPlans grouped into five phases**.
Twelve exceeds the "prefer two-to-seven" guideline, so phases group them into
implementation waves per the MasterPlan specification. The decomposition is by functional
concern (each plan delivers an independently demonstrable behavior), not by file or
module.

The guiding principles were: (1) **separate the substrate from the surface** — anything
that touches baikai or the effect stack directly is isolated low in the graph so the rest
of the framework depends on a stable internal interface; (2) **make the type-system
design its own work stream** — the `Program i o` representation (EP-4) is the riskiest and
most consequential design decision, so it is a dedicated plan with an explicit
prototyping milestone rather than being smeared across modules; (3) **keep each
production-runtime concern (caching, tracing) independently verifiable**; and (4) **order
evaluation before optimization** because optimizers are search procedures *driven by*
evaluation.

The five phases:

- **Phase 0 — Substrate.** EP-1 (runtime + `LLM` effect over baikai) and EP-2 (baikai
  native structured-output extension). Establishes the bottom of the stack: how shikumi
  talks to baikai through `effectful`, plus the upstream capability EP-3 needs.
- **Phase 1 — Typed program core.** EP-3 (signatures + structured I/O), EP-4 (program
  representation + `predict`/`chainOfThought`), EP-5 (combinators). The heart of the
  framework: the typed program model and how it renders to / parses from the wire.
- **Phase 2 — Production runtime.** EP-6 (caching) and EP-7 (tracing, observability,
  replay). The reliability and reproducibility layer.
- **Phase 3 — Evaluate, compile, optimize.** EP-8 (evaluation), EP-9 (compiler layer),
  EP-10 (optimizer framework). The DSPy-style "make it better automatically" stack.
- **Phase 4 — Agents & DX.** EP-11 (typed tools + ReAct) and EP-12 (CLI + developer
  experience). Multi-step agents and the user-facing tooling.

**Alternatives considered and rejected.** (a) *Foundation-only master plan (V0.1–V0.2),
deferring compile/optimize/agents to a second master plan* — rejected because the user
asked to design the full vision from first principles; a partial decomposition would risk
baking in a program representation (EP-4) that cannot support optimization (EP-10), which
is precisely the integration we most need to get right up front. (b) *Adapter-only,
prompt-coaxed structured output with no baikai change* — rejected by explicit user choice
in favor of provider-native schemas (hence EP-2). (c) *Folding caching and tracing into a
single "runtime" plan* — rejected because each is a substantial, independently testable
concern (four cache backends; OTel + a replay engine) and merging them would create one
oversized plan. (d) *Merging the compiler and optimizer plans* — rejected because the
compiler is a pure program→program transformation while the optimizer is a search
procedure layered on evaluation; they have different dependencies and different
acceptance criteria.


## Exec-Plan Registry

All twelve child ExecPlans have been authored into `docs/plans/`. Paths below are real and
their bodies are fleshed out per the ExecPlan specification. Statuses are Not Started; the
milestone counts (from each plan's Progress section) are noted for at-a-glance scope.

| #  | Title | Path | Hard Deps | Soft Deps | Milestones | Status |
|----|-------|------|-----------|-----------|------------|--------|
| 1  | Shikumi runtime substrate and LLM effect over baikai | docs/plans/1-shikumi-runtime-substrate-and-llm-effect-over-baikai.md | None | None | 5 | Complete |
| 2  | Baikai native structured output extension | docs/plans/2-baikai-native-structured-output-extension.md | None | None | 4 | Complete |
| 3  | Generic-derived signatures and structured IO | docs/plans/3-generic-derived-signatures-and-structured-io.md | EP-1 | EP-2 | 7 | Complete |
| 4  | Typed program representation and core modules | docs/plans/4-typed-program-representation-and-core-modules.md | EP-3 | None | 6 | Complete |
| 5  | Module combinators and control flow | docs/plans/5-module-combinators-and-control-flow.md | EP-4 | None | 10 | Complete |
| 6  | Caching subsystem | docs/plans/6-caching-subsystem.md | EP-1 | None | 9 | In Progress |
| 7  | Hierarchical tracing observability and replay | docs/plans/7-hierarchical-tracing-observability-and-replay.md | EP-1 | EP-6 | 6 | Complete |
| 8  | Evaluation framework | docs/plans/8-evaluation-framework.md | EP-4 | EP-5 | 7 | Complete |
| 9  | Compiler layer | docs/plans/9-compiler-layer.md | EP-4 | EP-5 | 8 | Not Started |
| 10 | Optimizer framework | docs/plans/10-optimizer-framework.md | EP-8, EP-9 | None | 6 | Not Started |
| 11 | Typed tools and ReAct agents | docs/plans/11-typed-tools-and-react-agents.md | EP-4, EP-5 | EP-2 | 5 | Not Started |
| 12 | CLI and developer experience | docs/plans/12-cli-and-developer-experience.md | EP-7, EP-8, EP-10 | EP-11 | 9 | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).


## Dependency Graph

The graph is rooted at the substrate and fans out by phase. In prose:

**EP-1 (runtime + LLM effect)** has one external, cross-repo hard dependency —
`baikai-effectful` (the thin `Baikai` transport effect in the baikai repo at
`docs/plans/23-baikai-effectful-effectful-transport-binding.md`), **now delivered and
satisfied** — and is otherwise the foundation: it defines the higher-level `effectful` effect
(`LLM`), implemented *in terms of* the `Baikai` effect rather than calling baikai's
`completeRequest`/`streamRequest` directly, adds the shikumi error type (mapping `BaikaiError`
plus shikumi-specific failures), and the retries/backoff/rate-limiting/budget machinery
baikai lacks. With `baikai-effectful` complete, EP-1 is unblocked. Almost everything else has
a hard or soft dependency on EP-1.

**EP-2 (baikai structured-output extension)** has no dependencies and lives in the baikai
repository. It is an *integration dependency* of EP-3: EP-3 must agree with EP-2 on how a
JSON schema is attached to a request and how the structured response comes back. EP-3
soft-depends on EP-2 because EP-3 can begin against a prompt-coaxed fallback path and
switch to the native path once EP-2 lands.

**EP-3 (signatures + structured I/O)** hard-depends on EP-1 (it issues LM calls through
the effect) and soft-/integration-depends on EP-2 (native schema path). It produces the
`Signature` machinery, Generic-derived JSON-schema generation and decoding, the field
metadata mechanism, and the `Adapter` seam (render request / parse response).

**EP-4 (program representation + core modules)** hard-depends on EP-3 (a `Program` is
built around a `Signature` and uses its render/parse). This is the keystone: the GADT deep
embedding of `Program i o`, `runProgram`, and `predict`/`chainOfThought`. Everything in
Phases 3–4 depends transitively on EP-4.

**EP-5 (combinators)** hard-depends on EP-4 (combinators are constructors/transformers of
`Program`).

**EP-6 (caching)** hard-depends on EP-1 (the cache wraps the `LLM` effect and keys on the
baikai request). It can be built in parallel with all of Phase 1.

**EP-7 (tracing + replay)** hard-depends on EP-1 (it layers on baikai's `TraceSink` and
the `LLM` effect) and soft-depends on EP-6 (deterministic replay reuses the cache's
content-addressing of requests/responses).

**EP-8 (evaluation)** hard-depends on EP-4 (it runs programs) and soft-depends on EP-5
(metrics over ensembles/majority-vote are more useful with combinators present).

**EP-9 (compiler layer)** hard-depends on EP-4 and EP-5 (compilers rewrite programs and
their parameters). EP-8 and EP-9 can proceed in parallel after Phase 1.

**EP-10 (optimizer framework)** hard-depends on EP-8 (optimization *is* search driven by
evaluation) and EP-9 (optimizers emit compiled programs).

**EP-11 (typed tools + ReAct)** hard-depends on EP-4 and EP-5 (ReAct is a multi-step
program) and soft-depends on EP-2 (native tool/function-calling schemas reuse the same
schema-attachment seam).

**EP-12 (CLI + DX)** hard-depends on EP-7 (replay/trace subcommands), EP-8 (eval
subcommand), and EP-10 (optimize subcommand), and soft-depends on EP-11 (agent demos in
the CLI).

**What can run in parallel.** After EP-1 lands: EP-6 (caching) and the EP-2/EP-3 pair can
proceed concurrently. After EP-4 lands: EP-8, EP-9, and EP-11 can proceed concurrently
(EP-5 is a quick hard dependency for EP-9 and EP-11). EP-7 can start as soon as EP-1 lands
and finalize once EP-6 is far enough along for replay.


## Integration Points

These are the shared artifacts where two or more plans must agree. Each names the owning
plan (responsible for defining the artifact) and how consumers use it.

1. **The `LLM` effect and shikumi error type.** *Owner: EP-1, layered on the `Baikai`
   transport effect owned by `baikai-effectful`.* The `effectful` effect that exposes a
   single provider-neutral call and the enumerated shikumi error type (invalid JSON, missing
   field, schema mismatch, validation failure, provider failure, timeout, budget exceeded —
   mapping `Baikai.Error.BaikaiError` into the shikumi space). The `LLM` interpreter is built
   *on top of* the policy-free `Baikai` effect from `baikai-effectful`
   (`/Users/shinzui/Keikaku/bokuno/baikai/docs/plans/23-baikai-effectful-effectful-transport-binding.md`,
   operations `Complete`/`StreamCollect`/`StreamEach`, interpreters `runBaikai`/
   `runBaikaiWith`) rather than calling baikai's `IO` functions directly, so retries, rate
   limiting, budget, and error mapping live in `LLM` while raw transport lives one layer
   down. Those `Baikai` operation and interpreter shapes are a cross-repo integration
   contract: EP-1 and the `baikai-effectful` plan must agree on them. **This contract is now
   fixed** — `baikai-effectful` shipped on 2026-06-08 with `Baikai`'s operations
   (`Complete`/`StreamCollect`/`StreamEach`) and interpreters (`runBaikai`/`runBaikaiWith ::
   ProviderRegistry -> ...`) as published in `Baikai.Effectful`; EP-1 builds against exactly
   these. *Consumers:* EP-3
   (issues calls), EP-6 (wraps the effect with caching), EP-7 (traces it), EP-11 (tool loop).
   Every plan must use this error type rather than inventing its own.

2. **Request schema attachment (native structured output).** *Owner: EP-2 (in baikai),
   mirrored by EP-3.* The shape of the new baikai `Options` field carrying a JSON schema /
   `response_format`, and how the structured response is surfaced. EP-3 must construct
   requests against exactly this shape; EP-11 reuses it for tool/function-calling schemas.
   Documented identically in EP-2, EP-3, and EP-11.

3. **The `Signature` type and field-metadata mechanism.** *Owner: EP-3.* How a signature
   carries instruction text and per-field descriptions, and how `ToSchema` / `FromModel`
   / `ToPrompt`-style derivations work from a Generic record. *Consumers:* EP-4 (programs
   wrap signatures), EP-9 (compilers rewrite a signature's instruction), EP-10 (optimizers
   search over instructions and demos), EP-11 (ReAct extends a signature with trajectory
   fields). The instruction and demos are the *optimizable parameters*; EP-3 must expose
   them as first-class, replaceable values.

4. **The `Program i o` representation (the GADT deep embedding).** *Owner: EP-4.* The
   single most important integration point. `Program` must be (a) runnable as a typed
   function via `runProgram`, (b) traversable/rewritable as data so optimizers can read
   and replace per-node parameters, and (c) serializable so compiled/optimized programs
   can be saved and replayed. *Consumers:* EP-5 (adds constructors), EP-8 (runs it),
   EP-9 (rewrites it), EP-10 (searches over it), EP-11 (ReAct is a program), EP-12
   (CLI loads/saves it). EP-4 must define and document the traversal/parameter-update
   interface that EP-9 and EP-10 depend on.

5. **`Example` / `Prediction` / `Dataset` / `Metric` / `Report`.** *Owner: EP-8.* The
   evaluation data model. *Consumers:* EP-10 (optimizers consume `Dataset` + `Metric`,
   produce programs scored by `Report`), EP-12 (CLI `eval` renders `Report`). DSPy's
   `Example`/`Prediction` are untyped bags; shikumi types them by `i`/`o`. EP-8 owns these
   types; EP-10 must not redefine them.

6. **`CompiledProgram i o`.** *Owner: EP-9.* The output of compilation and the thing
   optimizers emit. *Consumers:* EP-10 (returns it), EP-12 (CLI loads/runs it). EP-9 must
   define how a `CompiledProgram` relates to a `Program` (e.g., a `Program` plus a frozen
   set of node parameters) and how it serializes.

7. **The trace tree and cache key.** *Owner: EP-7 (trace), EP-6 (cache key).* The
   content-addressed key is a **BLAKE3 256-bit digest (64 lowercase hex chars), namespaced
   `shikumi-cache/v1`**, computed over a canonical sorted-key JSON object with exactly the
   fields `api, maxTokens, messages, model, provider, responseFormat, systemPrompt,
   temperature, thinking, toolChoice, tools, version` (excluding `apiKey`, `timeoutMs`,
   `headers`, `metadata`, `cacheRetention`, and all of `Response`). EP-6 owns the production
   implementation in `Shikumi.Cache.Key`; EP-7's replay engine ships a verbatim copy until
   EP-6 lands, then imports it. Both plans pin the same `blake3` library and a shared golden
   fixture so the key matches byte-for-byte. (Reconciled during cross-plan review — EP-7 had
   independently specified SHA-256; corrected to EP-6's BLAKE3.)

8. **`Tool i o` and its lowering to `Baikai.Tool`.** *Owner: EP-11.* The typed tool whose
   argument schema is Generic-derived (reusing EP-3's schema generation) and which lowers
   to baikai's untyped `Tool { parameters :: Value }`. *Consumers:* EP-4/EP-5 only
   indirectly; primarily EP-11 internally and EP-12 for CLI agent demos.


## Progress

Milestone-level progress across all child plans. Populated as each plan defines its
milestones; updated as they complete. (No child plans authored yet — see Decision Log.)

- [x] EP-1: LLM effect over baikai with a working end-to-end call through `Eff`
- [x] EP-1: Retries, backoff, rate limiting, and budget controls
- [x] EP-2: `response_format` / JSON schema field on baikai `Options`
- [x] EP-2: Anthropic and OpenAI provider mappings emit/parse native structured output
- [x] EP-3: Generic-derived JSON schema + decode from record types
- [x] EP-3: `Signature` + field metadata + the `Adapter` seam (native + fallback)
- [x] EP-4: `Program i o` GADT, `runProgram`, and the parameter-traversal interface
- [x] EP-4: `predict` and `chainOfThought`
- [x] EP-5: `Retry`, `Validate`, `Pipeline`, `Map`, `Parallel`, `MajorityVote`, `Ensemble`
- [ ] EP-6: Cache effect with memory + SQLite backends
- [ ] EP-6: Postgres + Redis backends
- [x] EP-7: Hierarchical trace tree (over the `LLM` effect via `interpose`, not baikai's
  `TraceSink`) + nested OTel spans (`shikumi-trace-otel`)
- [x] EP-7: Deterministic replay from stored traces
- [x] EP-8: `Dataset`/`Metric`/`evaluate`/`Report` + built-in metrics + golden tests
  (new `shikumi-eval` package; 36 hermetic tests)
- [ ] EP-9: Zero-shot, few-shot, chain-of-thought, and retrieval-augmented compilers
- [ ] EP-10: Demo selection, bootstrap few-shot, instruction search, ensemble search
- [ ] EP-11: `Tool i o` lowering + ReAct loop + multi-step programs
- [ ] EP-12: `shikumi` CLI: `eval`, `trace`, `optimize`, `replay`


## Surprises & Discoveries

Cross-plan insights, dependency changes, scope adjustments, or unexpected interactions.

- During research (2026-06-07): baikai has **no** structured-output, caching, retry, or
  nested-trace support, and is plain `IO` (no `effectful`). This confirmed the clean split
  — shikumi owns everything above the wire — and drove the EP-2 (upstream baikai change)
  decision. Evidence: baikai `Options` has fields `maxTokens, temperature, apiKey,
  timeoutMs, headers, metadata, toolChoice, cacheRetention, thinking` — no
  `responseFormat`; grep for "retry"/"backoff"/"cache memoization" in baikai core returns
  nothing.
- baikai's `Tool` already carries `parameters :: Aeson.Value` (a JSON schema passed
  through verbatim), so EP-11's typed `Tool i o` lowers cleanly to it; no baikai tool
  change is required, only EP-2's request-level `response_format`.
- During EP-2 authoring (2026-06-07): the assumption that Anthropic has *no* native
  structured output was **wrong**. The `MercuryTechnologies/claude` SDK baikai depends on
  already exposes `Claude.V1.Messages.OutputConfig` / `OutputFormat` and a helper
  `jsonSchemaConfig :: Value -> OutputConfig`, and `CreateMessage` already has an
  `output_config :: Maybe OutputConfig` field. So EP-2 maps shikumi's structured-output
  request to Anthropic's *native* `output_config` (not a forced-tool workaround), and to
  OpenAI's existing `response_format`. Both providers enforce the schema server-side and
  return the JSON through the existing `AssistantText` content — so **no baikai `Response`
  type change is needed**, only a new `Options.responseFormat` field. Evidence: `grep -n
  "output_config\|jsonSchemaConfig"` in the claude SDK on disk shows `jsonSchemaConfig ::
  Value -> OutputConfig` and `output_config :: Maybe OutputConfig`.
- Cross-plan review (2026-06-07): two seams were reconciled after parallel authoring — the
  cache-key hash (EP-7 had SHA-256; corrected to EP-6's BLAKE3 + exact field set), and the
  EP-2↔EP-3 schema-attachment contract (aligned on EP-2's `ResponseFormat` sum type and the
  `attachSchema` helper). No other inconsistencies found across the twelve plans.
- During effect-binding design (2026-06-08): confirmed baikai's transport is `IO`/streamly
  throughout — `completeRequest :: ... -> IO Response`, `streamRequest :: ... -> Stream IO
  AssistantMessageEvent`, an `IORef`-backed `ProviderRegistry`, and a `Fold IO` reassembly
  path. This made the choice clear: a thin `baikai-effectful` `Baikai` effect (handler =
  `liftIO`/`localSeqUnliftIO` over today's `IO` baikai) gives the clean layering shikumi
  wants, whereas parameterizing baikai over `MonadIO m` would have to thread `m` through the
  `IORef` registry and the `Stream IO`/`Fold IO` layer for no capability gain. The
  `baikai-effectful` plan lives in the baikai repo with its own intention; EP-1 gains it as a
  hard, cross-repo dependency. See Decision Log (2026-06-08).
- **EP-3 delivered (2026-06-08).** The record↔JSON bridge landed: `Shikumi.Schema(.Types)`
  (`ToSchema`/`deriveSchema`, total `FromModel`/`parseOutput`, the `Field "desc"` wrapper,
  `Validatable`), `Shikumi.Signature` (replaceable `instruction`/`demos` + derived field
  metadata), and `Shikumi.Adapter` (`ToPrompt`, the `[[ ## field ## ]]` fallback adapter, the
  native adapter, `capabilityFor`). `shikumi-test` is green (35 tests). Cross-plan facts:
  (a) **integration point #3 is fixed** with the documented signatures for EP-4 (programs wrap
  a `Signature`), EP-9/EP-10 (rewrite the `instruction`/`demos` parameters — exposed as
  first-class values + `#instruction`/`#demos` optics), and EP-11 (`deriveSchema` fills a
  tool's `parameters`). (b) **Integration point #1 reconciled**: EP-3 emits decode-side
  `ShikumiError` values using EP-1's *flat-`Text`* constructors, threading a `FieldPath`
  breadcrumb and rendering it into the message (EP-3's draft assumed a `FieldPath`-typed error;
  EP-1 is authoritative). (c) **Integration point #2 is still pending EP-2**: the native
  adapter's `attachSchema` is a no-op and native `parse` reads JSON from assistant text until
  baikai gains `Options.responseFormat`; the prompt fallback is the exercised path. EP-2 remains
  the next valuable unblock for EP-3's native path. See EP-3's Decision Log.
- **EP-1 delivered (2026-06-08).** The runtime substrate landed: `shikumi` is now a buildable
  multi-package cabal project whose library exposes the `LLM` effect, `ShikumiError`, and the
  resilient interpreter, all over baikai via `effectful`; hermetic `cabal test` is green (13
  tests). Cross-plan facts for downstream EPs: (a) **the cascade is applied** — `LLM` is built
  on `baikai-effectful`'s `Baikai` effect via `reinterpret_ (runBaikaiWith reg)`, so consumers
  (EP-3/6/7/11) interpret `LLM` *above* `runLLMResilient` and never see `IOE`/`Baikai`. (b)
  **The blocking `Response` already carries `Usage`** (`message.usage.cost.usd`), so EP-6's
  cache-key field set and EP-8's cost accounting can read cost off a `Response` without the
  streaming path. (c) **A Nix toolchain is now required** — every shikumi build/test runs
  inside `nix develop .#ghc9124` (ghc-9.12.4 from `shinzui/haskell-nix-dev`); the system ghc
  (9.10.3) is the wrong compiler. (d) **`cabal.project` uses local paths** to the baikai repo
  (HEAD unpushed, `baikai-effectful` unpublished), and there is a fleet `fourmolu.yaml`
  (2-space) the formatter enforces via pre-commit. See EP-1's Decision Log.
- `baikai-effectful` **shipped (2026-06-08)** — all four of its milestones are complete: the
  package builds, hermetic `CompleteSpec`/`StreamSpec` pass, a gated live call succeeded
  (`LIVE: Sure!` via `openai_gpt_4o_mini`), and `mori show --full` lists it. EP-1's only
  cross-repo hard dependency is therefore satisfied; EP-1 can be implemented directly against
  the published `Baikai` effect. A clarification confirmed during this work: putting `IOE` in
  a function's row erases the effect ledger (under `IOE` you can `liftIO` arbitrary `IO`), and
  a `MonadIO m` baikai at `m = Eff es` would force exactly that `IOE :> es` onto consumers —
  which is why the dynamic `Baikai` effect (with `IOE` confined to the bottom interpreter), not
  monad parameterization, is the design that keeps consumer signatures honest.
- **EP-2 delivered (2026-06-08).** The upstream baikai structured-output capability landed in
  the baikai repo (commits `4a12f08`, `0cdbb18`, `d8ebc84`, `0b974e1`). `Baikai.ResponseFormat`
  (`JsonSchema { name, schema, strict }` | `JsonObject`) + `Options.responseFormat :: Maybe
  ResponseFormat` (default `Nothing`, re-exported from `Baikai`); OpenAI `mapRequest` maps it to
  native `response_format`, Anthropic `mapRequest` to native `output_config` (via
  `Messages.jsonSchemaConfig`; `strict` dropped, `JsonObject` → permissive `{"type":"object"}`).
  Pure mapping tests pass for both providers; the live `gpt-4o-mini` smoke returned
  `{"age":36,"name":"Ada Lovelace"}` for a schema-bearing request that never mentions JSON,
  proving server-side enforcement. Cross-plan facts that **fix integration point #2** for EP-3
  and EP-11: (a) attach a schema by setting `Options.responseFormat` to `Just (JsonSchema {name,
  schema, strict})` (schema = raw JSON-Schema `Value`) or `Just JsonObject`; `Nothing` =
  today's unconstrained behaviour. (b) The structured JSON comes back as **ordinary assistant
  text** — no new content kind — so `Baikai.Response`/`Content`/`Message` are unchanged; read it
  with `flattenAssistantBlocks` and JSON-decode. (c) **EP-3's native adapter can now be wired
  for real**: EP-3 shipped with `attachSchema` as a no-op pending EP-2; it can now set
  `responseFormat` and stop relying solely on the prompt fallback (the Anthropic native path is
  untested live — no Anthropic key was present — but its pure mapping is verified). (d) baikai
  still ships **no JSON-Schema validator** (out of scope); EP-3's decoding layer owns turning a
  syntactically-valid-but-shape-wrong body into a typed `ShikumiError`. The mapping functions
  `mapRequest` are now exported from both provider `Api` modules for testing.
- **EP-6 partially delivered (2026-06-08) — hermetic core done, persistent backends deferred.**
  The new `shikumi-cache` package ships the content-addressed cache key (**integration point #7**),
  the `Cache` effect (`lookupCache`/`storeCache`), the in-memory STM backend, the `cachedLLM`
  memoizer (re-interprets EP-1's `LLM` via `interpose`), and versioning. `cabal test shikumi-cache`
  green (11 tests). Cross-plan facts:
  (a) **Integration point #7 is now concrete and pinned.** `Shikumi.Cache.Key.cacheKey :: Model ->
  Context -> Options -> CacheKey` produces a BLAKE3 256-bit hex digest over the canonical
  sorted-key JSON with exactly the agreed field set; the golden-pinned key for the fixed test
  request is `30b2015562ec8b5cd4fdb64c7cc671c84f56f80d24891deec6676c521f008113`. **EP-7 imports
  `Shikumi.Cache.Key` and reuses `cacheKey` verbatim** (no longer a copy) and must reproduce this
  digest. The `responseFormat` slot reads the real `Options.responseFormat` (EP-2), `null` until
  EP-3's `attachSchema` is wired.
  (b) **`blake3` needs a `cabal.project` fix on aarch64-darwin**: `package blake3 { flags: -avx512
  -avx2 -sse41 -sse2; ghc-options: -optc-DBLAKE3_USE_NEON=0 }` (its vendored SIMD C is broken on
  ARM). Any plan adding a SIMD-C-vendoring fleet package should expect similar wrangling.
  (c) **Deferred:** SQLite (M3/M4), Redis (M6), Postgres (M7) — all need a faithful baikai
  `Response` JSON round-trip (baikai ships no `FromJSON` for `Response`; `Cost` is lossily
  `Rational`→`Scientific`) plus heavy deps/live servers. None blocks EP-7. EP-6 remains **In
  Progress** until they land. The second EP-6 progress line ("Postgres + Redis backends") and the
  SQLite half of the first remain open.
- **EP-7 delivered (2026-06-08).** The hierarchical-tracing + replay layer landed across two
  new packages, `shikumi-trace` (hermetic, 11 tests) and `shikumi-trace-otel` (1 test), both
  green with no network. Cross-plan facts:
  (a) **Capture is by `interpose` on the `LLM` effect, not a baikai `TraceSink`.** EP-1's
  interpreters expose no sink seam, and `LLM.complete` returns the full `Response` (latency,
  usage, cost, tool blocks — a superset of baikai's flat `TraceEvent`). So `Shikumi.Trace`
  owns the parent/child hierarchy via a span-id stack and `tracedLLM` (the same seam EP-6's
  `cachedLLM` uses) fills each LM-call leaf from the `Response`. Consequence: the core trace
  package depends on **neither `streamly-core` nor `Baikai.Trace.*`**. Integration point #7 is
  honoured by **importing `Shikumi.Cache.Key` from `shikumi-cache`** (EP-6 landed), not the
  planned verbatim copy — the golden test reproduces EP-6's pinned digest `30b2…8113`, so the
  two plans cannot drift.
  (b) **EP-7 built the faithful `Response` JSON round-trip that EP-6 deferred.** Replay must
  serialize/deserialize a `Response`, but baikai ships no `FromJSON` for the
  `Response`/`AssistantPayload`/`Usage`/`Cost` graph (and `Cost` is lossy `Rational→Scientific`).
  `Shikumi.Trace.ResponseJSON` supplies orphan `FromJSON` for `Usage`/`Cost`/`CostBreakdown`/
  `AssistantPayload` + `ToJSON`/`FromJSON Response`, reusing baikai's existing
  `Model`/`Api`/`AssistantContent`/`StopReason` instances. **EP-6's deferred SQLite/Redis/Postgres
  backends can reuse these instances** — the `Response`-round-trip blocker that drove their
  deferral is now solved. The replay typed-output guarantee rests only on `AssistantContent`
  (which round-trips exactly), so `Cost`'s imprecision is harmless.
  (c) **`runLLMReplay` is fail-closed and registry-free**: an unrecorded request raises
  `ReplayDivergence` (it never falls through to a provider), so "zero provider calls" is
  structural, not policy. It needs no `IOE`. The OTel adapter (`exportTree`) produces *nested*
  spans (unlike baikai's flat one-span-per-call) via `Context.insertSpan`.
- **EP-5 delivered (2026-06-08).** The combinator/control-flow layer landed:
  `Shikumi.Program` gained seven GADT constructors (`Map Int`, `Parallel`, `Retry`,
  `RetryWhen`, `Validate`, `MajorityVote`, `Ensemble`) wired through `runProgram`,
  `paramsTraversal`, `mapParamsAt`, `programShape`/`ProgramShape`, and `setProgramParams`; a new
  additive concurrent executor `runProgramConc`; `TempSchedule`; and `Shikumi.Combinator` (the
  ergonomic surface: `>>>`, `chain`, `mapP`/`mapSeqP`, `parallel2`/`parallelN`,
  `retry`/`retryWhen`, `validate`/`validateRetry`, `majorityVote`/`majorityVoteBy`, `ensemble`).
  `cabal test shikumi` green (78 tests; 24 new). Cross-plan facts for EP-9 (compiler), EP-11
  (ReAct), and EP-8 (eval), which hard-depend on EP-5:
  (a) **`runProgram`'s signature is unchanged** — still `(LLM :> es, Error ShikumiError :> es)
  => Program i o -> i -> Eff es o`, so integration point #4 is intact and every consumer keeps
  the same constraint. Concurrency is opt-in via `runProgramConc :: (LLM, Error ShikumiError,
  Concurrent :> es) => …` (the plan's "add Concurrent to runProgram" primary was rejected
  precisely to preserve #4 — see EP-5 Decision Log).
  (b) **The parameter/serialization contract extends uniformly**: every new constructor recurses
  in `paramsTraversal`/`foldParams` (a program's parameter count still equals its `Predict`-leaf
  count, now reachable through arbitrary combinator nesting), and `programShape` grew matching
  `Shape*` constructors. EP-9/EP-10 rewrite/optimize combinator programs through exactly the same
  `foldParams`/`mapParamsAt`/`programParams`/`setProgramParams` surface — verified by M9 on a
  deep `chain [retry (majorityVote …), validate …]`.
  (c) **Combinators are GADT constructors, not opaque functions** — so optimizers reach
  `Predict` leaves buried inside a `MajorityVote` inside a `Retry`. New constructors are still a
  compile error until all five functions pattern-match them (the EP-4 rule); EP-11 should follow
  the same "derive from existing constructors where possible" pattern (`parallelN`/`majorityVoteBy`
  are derived from `Ensemble`; ReAct's loop will likely need its own constructor).
  (d) **`TempSchedule` is carried + serialized but inert on the wire** (Predict's options are
  adapter-fixed — the same unwired-routing limitation EP-4 noted); per-sample temperature awaits
  real routing. EP-8/EP-12 supplying real model selection would also unblock this.
- **EP-4 delivered (2026-06-08).** The keystone landed: `Shikumi.Program` (the `Program i o`
  GADT — `Predict`/`Compose`/`FMap` — `Params`/`Demo`, `pipeline`, `runProgram`, the
  `paramsTraversal`/`foldParams`/`mapParams`/`mapParamsAt` parameter interface, and
  `ProgramShape`/`programParams`/`setProgramParams` serialization) and `Shikumi.Module`
  (`predict`, `chainOfThought`/`chainOfThoughtRaw`, `WithReasoning`). The three-constructor
  GADT from the M0 spike promoted **without change**; `cabal test shikumi` is green (54 tests),
  including the ordering law as a 100-case QuickCheck property and the two headline behaviors
  (typed pipeline runs end-to-end; an instruction rewrite reaches the captured wire prompt).
  Cross-plan facts that fix **integration point #4** for EP-5/8/9/10/11/12:
  (a) `runProgram :: (LLM :> es, Error ShikumiError :> es) => Program i o -> i -> Eff es o` —
  one capability beyond the originally-pinned `(LLM :> es)`, because decode failures throw
  typed `ShikumiError`s and EP-1 already threads `Error ShikumiError` wherever `LLM` runs;
  every consumer that calls `runProgram` inherits it.
  (b) The parameter/serialization contract the optimizer (EP-10) and compiler (EP-9) depend on
  is exactly `foldParams` (enumerate, left-to-right depth-first) + `mapParamsAt`/`mapParams`
  (edit) + `programParams`/`setProgramParams` (save/load); a program's parameter count equals
  its `Predict`-node count; `Params` is the uniform JSON overlay (`instructionOverride` +
  `demos`), and demos reach the wire by being decoded into the signature's typed demo channel,
  so a saved demo must be JSON that decodes to the node's `i`/`o`.
  (c) `Program i o` has **no `Eq`/`Show`** (it carries the `FMap` closure) — compare programs
  via `foldParams`/`programShape`/run result.
  (d) New GADT constructors are a compile error until `paramsTraversal`, `programShape`, and
  `setProgramParams` all pattern-match them — EP-5 should prefer *derived functions* over new
  constructors (the `chainOfThought`-via-`FMap` pattern).
  (e) **Real provider/model routing is unwired**: `runProgram` dispatches every node against
  the neutral `_Model` (→ prompt-fallback adapter, the MasterPlan's "exercised path" until
  EP-2). EP-8 (eval) and EP-12 (CLI) — or a future `Reader Model` effect — must supply real
  model selection before running against a live provider. See EP-4's Decision Log / Outcomes.
- **EP-8 delivered (2026-06-08).** The evaluation framework landed in the new `shikumi-eval`
  package; `cabal test shikumi-eval` is green (36 hermetic tests). Cross-plan facts that
  **fix integration point #5** for EP-10 (optimizer) and EP-12 (CLI):
  (a) **`Shikumi.Eval` is the single owned surface.** It re-exports `Score`/`Example`/
  `Dataset`/`Prediction`/`Metric`/`MetricM`/`Report` (plus `EvalConfig`, `FailurePolicy`,
  `FailureReason`, `UsageTotals`, `ExampleResult`, `renderReportText`). EP-10 consumes
  `Dataset` + `Metric`/`MetricM` as search inputs and `Report.aggregateScore :: Double` as the
  objective; EP-12's `eval` subcommand renders a `Report` with `renderReportText` (a
  deterministic, fixed-format string — safe to snapshot). Neither plan redefines these types.
  (b) **`evaluate`'s constraint is `(LLM, Concurrent, Error ShikumiError, IOE) :> es`** — one
  more (`IOE`) than the plan's sketch, for monotonic per-example latency; `Concurrent` drives
  `pooledForConcurrentlyN` (order-preserving, bounded by `EvalConfig.concurrency`). EP-10's
  search loop and EP-12's `eval` command inherit exactly this row when they call `evaluate`.
  (c) **`MetricM es o` is the effectful metric** an optimizer can pass directly (e.g.
  `modelJudge`/`semanticSimilarity`); pure metrics lift via `liftMetric`. A failing example
  does not abort the run by default (`FailScore scoreZero`), so an optimizer scoring many
  candidate programs measures robustness rather than crashing on the first bad case.
  (d) **Usage/cost accounting reuses the `interpose`-on-`LLM` seam** (the EP-6/EP-7 pattern):
  `Shikumi.Eval.Usage.withUsageTotals` reads `Usage`/`Cost` off each `Response`, so a `Report`
  carries real token/cost totals when run against a real interpreter — no substrate hook
  required. (e) **Golden tests** (`goldenProgram`/`goldenReport`) take a caller-supplied
  rank-2 `forall a. Eff es a -> IO a` runner, so EP-12 can wire them to EP-7's replay
  interpreter for offline CI without `shikumi-eval` depending on the trace package. (f) The
  multi-sample path and `semanticSimilarity`'s embedding backend remain inert pending real
  per-call model routing (EP-4's unwired-`_Model` limitation) and a substrate embedding op —
  neither blocks EP-10/EP-12. See EP-8's Outcomes & Retrospective.


## Decision Log

- Decision: Build shikumi *on top of* baikai; do not reimplement provider dispatch,
  the model catalog, streaming events, content/message/tool types, or `Usage`/`Cost`.
  Rationale: baikai already owns the entire transport layer; the spec's "Runtime /
  Provider Abstraction" box is ~80% baikai today. Duplicating it would split maintenance
  and diverge cost accounting. Date: 2026-06-07.
- Decision: Scope this master plan to the **full V0.1–V0.5 vision**, designed from first
  principles around Haskell's type system, rather than a foundation-only subset.
  Rationale: explicit user direction; designing the program representation (EP-4) without
  the optimizer (EP-10) in view risks an embedding that cannot support optimization.
  Date: 2026-06-07.
- Decision: Obtain typed outputs via **provider-native structured output**, extending
  baikai (EP-2) with a `response_format` / JSON-schema field, rather than prompt-coaxed
  parsing only. Rationale: explicit user choice for reliability; the capability belongs in
  the transport layer. The `Adapter` seam (EP-3) still keeps a prompt-based fallback for
  providers/models without native support. Date: 2026-06-07.
- Decision: Use **`effectful`** as the runtime substrate (`LLM`, `Trace`, `Cache`,
  `Error` effects) rather than plain `IO`+`ReaderT` or mtl typeclasses. Rationale:
  explicit user choice; matches the spec example; makes each program's capabilities
  visible in its type; `effectful` is already a registered dependency in the user's
  environment. Date: 2026-06-07.
- Decision: Represent `Signature` via **Generic-derived field schemas from record types**
  rather than the spec's `class Signature s where type Input/Output`. Rationale: explicit
  user choice; gives rich per-field metadata (descriptions, optimizable prefixes) and
  first-class fields, which the optimizer (EP-10) needs. Date: 2026-06-07.
- Decision: Represent `Program i o` as a **typed GADT deep embedding** (program-as-data)
  with an explicit parameter-traversal/rewrite interface, rather than an opaque function
  or a final-tagless encoding. Rationale: optimizers must read and rewrite per-node
  parameters without runtime reflection (Haskell has no Python-style introspection), while
  composition must stay type-checked and execution must stay a typed function. EP-4 carries
  a prototyping milestone to validate this against `predict`/`chainOfThought`/`Pipeline`
  before the rest of the framework commits to it. Date: 2026-06-07.
- Decision: Decompose into **twelve child plans across five phases (0–4)**. Rationale:
  full-vision scope exceeds the seven-plan guideline, so phases group implementation
  waves; boundaries follow functional concerns with the substrate isolated low in the
  graph and evaluation ordered before optimization. Date: 2026-06-07.
- Decision: Associate the entire initiative with intention
  `intention_01ktjgkp10ef79vpwz1cmajek9`; every commit carries `MasterPlan:`,
  `ExecPlan:`, and `Intention:` trailers. Date: 2026-06-07.
- Decision: Checkpointed with the user after authoring the MasterPlan; the user confirmed
  "author all 12 now (parallel)". All twelve child ExecPlans were then drafted by parallel
  agents from a shared research dossier and reconciled for cross-plan consistency.
  Rationale: the user framed this as design exploration and asked to think about the full
  vision from first principles; the checkpoint confirmed the decomposition before the large
  generation step. Date: 2026-06-07.
- Decision: Map Anthropic structured output to its **native** `output_config` (not a
  forced-tool workaround) after discovering the claude SDK already supports it; surface the
  structured JSON through existing assistant text so baikai's `Response` type is unchanged.
  Rationale: more faithful and less invasive than the originally-assumed workaround. See
  Surprises & Discoveries. Date: 2026-06-07.
- Decision: Introduce a **`baikai-effectful` package** (a thin, policy-free `effectful`
  binding over baikai's transport — a dynamic `Baikai` effect with `Complete`/`StreamCollect`/
  `StreamEach` and `runBaikai`/`runBaikaiWith` interpreters) and implement EP-1's higher-level
  `LLM` effect *in terms of* it, so shikumi's framework code never carries `IOE` and only the
  bottom interpreter does. **Rejected** the alternative of parameterizing baikai itself over
  `MonadIO m`. The reason is not merely ergonomic: `MonadIO m` instantiated at `m = Eff es`
  still requires `MonadIO (Eff es)`, which is `IOE :> es` — so it forces `IOE` into the
  *consumer's* effect row, and `IOE` is the top capability whose presence lets a function
  `liftIO` arbitrary `IO`. Putting `IOE` in a signature therefore collapses the effect row
  from an honest capability ledger ("this does only baikai calls", `Baikai :> es`) into "this
  may do anything". A `MonadIO m` baikai cannot avoid that, and it cannot push effects *into*
  baikai's internals either; it would also be invasive on baikai's `IORef` registry and
  streamly `Stream IO`/`Fold IO` layer. The dynamic `Baikai` effect is the right tool: `IOE`
  appears only as a residual discharged at the bottom (on `runBaikaiWith`/`runEff`), never in
  consumer signatures, which keeps the ledger honest. The `baikai-effectful` plan lives **in
  the baikai repo** at
  `/Users/shinzui/Keikaku/bokuno/baikai/docs/plans/23-baikai-effectful-effectful-transport-binding.md`
  under its own intention `intention_01ktmqmrjre89r3c3qq6fj3j5h` (not a child of this
  MasterPlan, but a hard dependency of EP-1). **Delivered 2026-06-08**: all four milestones
  complete — package builds, hermetic `CompleteSpec`/`StreamSpec` pass, a gated `LiveSpec`
  ran a real call (`LIVE: Sure!`, `openai_gpt_4o_mini`), and `mori show --full` lists the
  package. Date: 2026-06-08.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original vision.

(To be filled during and after implementation.)


## Revision Notes

- 2026-06-08: Recorded the decision to introduce `baikai-effectful` — a thin, policy-free
  `effectful` binding over baikai's transport (a dynamic `Baikai` effect with
  `Complete`/`StreamCollect`/`StreamEach` and `runBaikai`/`runBaikaiWith`) — and to build
  EP-1's `LLM` effect in terms of it; rejected parameterizing baikai over `MonadIO m` as
  cosmetic and invasive. The `baikai-effectful` ExecPlan was authored in the baikai repo
  (`/Users/shinzui/Keikaku/bokuno/baikai/docs/plans/23-baikai-effectful-effectful-transport-binding.md`)
  under intention `intention_01ktmqmrjre89r3c3qq6fj3j5h`; it is a hard, cross-repo dependency
  of EP-1, not a child of this MasterPlan. Updated Vision & Scope ("Relationship to baikai"),
  Dependency Graph (EP-1), Integration Points (#1), Surprises & Discoveries, and the Decision
  Log accordingly. EP-1's own ExecPlan
  (`docs/plans/1-shikumi-runtime-substrate-and-llm-effect-over-baikai.md`) should be revised
  in a follow-up to interpret `LLM` over the `Baikai` effect rather than calling baikai's
  `IO` functions directly; the cross-repo operation/interpreter shapes are the integration
  contract to hold stable.
- 2026-06-08: Reflected that `baikai-effectful` is **delivered** (all four milestones complete
  in the baikai repo: package builds, hermetic `CompleteSpec`/`StreamSpec` pass, gated
  `LiveSpec` ran a real call, `mori` lists the package). Updated Vision & Scope, the EP-1
  Dependency-Graph paragraph, Integration Point #1, the Decision Log, and Surprises &
  Discoveries to mark EP-1's cross-repo hard dependency as satisfied and the `Baikai`
  operation/interpreter contract as fixed. Also tightened the `MonadIO m`-rejection rationale
  in the Decision Log: the decisive reason is that `IOE` in a consumer row erases the effect
  ledger (and `MonadIO m` at `m = Eff es` forces `IOE :> es`), not mere ergonomics; the
  dynamic `Baikai` effect keeps `IOE` confined to the bottom interpreter.
