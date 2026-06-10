---
id: 2
slug: shikumi-substrate-routing-completion
title: "Shikumi Substrate & Routing Completion"
kind: master-plan
created_at: 2026-06-09T22:35:20Z
intention: "intention_01ktq80610e6nbe3d7yrct59an"
---

# Shikumi Substrate & Routing Completion

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

Shikumi (the typed LM-programming framework at `/Users/shinzui/Keikaku/bokuno/shikumi`)
shipped its full V1 vision across twelve ExecPlans (see
`docs/masterplans/1-shikumi-typed-lm-programming-framework.md`). That initiative
deliberately left a small set of *substrate* capabilities stubbed because no V1 behavior
strictly required them, but every one of those stubs now blocks the next wave of work
(the DSPy-parity optimizers in `docs/masterplans/3-shikumi-dspy-parity-optimizers-and-self-refinement.md`
and the richer I/O surface in `docs/masterplans/4-shikumi-richer-io-and-multimodal.md`).
This MasterPlan closes those gaps. It is the foundation wave: small, high-leverage, and a
hard prerequisite for most of what follows.

V1's own "Known gaps / future work" retrospective names them precisely: real per-call
provider/model routing (`runProgram` today dispatches every node against a neutral empty
`_Model`, so the provider-native structured-output path, per-sample temperature, and
multi-sample evaluation are all inert); no embeddings backend (the `Embedding` effect
exists in `Shikumi.Eval.Metric` but ships no interpreter, so `semanticSimilarity` and any
retrieval-by-similarity cannot run); no node-correlated tracing (the trace tree records
LM-call spans but cannot say *which* `Program` node issued a call, blocking per-node demo
recovery and reflective optimization); and a deferred live OpenTelemetry export sink (the
CLI accepts `--otel` but has no collector-facing exporter).

After this initiative a Shikumi user can: (1) choose a real model — by name, from baikai's
generated catalog — and have `runProgram` dispatch every `Predict` node against that
provider, with the JSON schema actually transmitted to and enforced by the provider
(OpenAI `response_format` / Anthropic `output_config`) and per-sample temperature actually
applied; (2) supply an embeddings backend (a real OpenAI-compatible embeddings endpoint)
so `semanticSimilarity` and embedding-based retrieval work end to end; (3) run a program
and get back a trace in which every LM-call span is tagged with the structural path of the
`Program` node that produced it, plus a per-node textual feedback slot that downstream
reflective optimizers can read and write; and (4) point `shikumi trace --otel` at a real
OpenTelemetry collector and see the nested span tree exported.

**In scope:** an ambient model-routing effect and the wiring of the live native-schema and
per-sample-temperature paths; an embeddings interpreter for the existing `Embedding`
effect, backed by a new (small) upstream baikai embeddings client because baikai ships
none today; node-path identity on programs plus a `runProgramTraced` that correlates spans
to nodes and a per-node feedback channel; and the live OTel export sink.

**Out of scope:** the optimizers and refinement modules that *consume* these substrates
(they live in MasterPlan 3); multimodal content, streaming, and adapter expansion
(MasterPlan 4); any change to the `Program` GADT's run semantics beyond threading an
ambient model and node path (the V1 integration point #4 contract — `runProgram ::
(LLM :> es, Error ShikumiError :> es) => Program i o -> i -> Eff es o` — must remain
valid); and a vector-store implementation (the embeddings effect returns vectors; storage
and ANN indexing are the consumer's concern, as in V1's RAG stance).


## Decomposition Strategy

The initiative splits into **four child ExecPlans**, one per substrate concern, ordered so
that the keystone (routing) lands first and the rest can proceed largely in parallel. The
guiding principle is the same as V1: separate independently verifiable behaviors, and keep
each plan's acceptance phrasable as an observable end-to-end scenario rather than an
internal attribute.

EP-14 (ambient model routing) is the keystone and is deliberately first: it is the single
change V1's retrospective flagged as gating "the native schema path, per-sample
temperature, and multi-sample eval." Until a program can dispatch a *named* model with the
schema actually attached, none of the live behaviors above can be demonstrated. It is
isolated into its own plan because it touches the hot path (`runProgram`/`runProgramConc`
and the `Adapter` seam's `attachSchema`) and the rest of the framework depends on its
choice of mechanism (a `Reader`-style ambient `Model`/`Options` effect vs. a parameter on
`runProgram`).

EP-15 (embedding backend) is separate because it carries a *cross-repo* component: baikai
has no embeddings client at all (confirmed: no `embed`/`embedding` symbol anywhere in
`baikai/src`), so this plan adds a small upstream baikai embeddings transport and then a
Shikumi `Embedding`-effect interpreter on top of it — the same shape as V1's `baikai-effectful`
and EP-2 upstream contributions. It can proceed entirely in parallel with the other three;
nothing in EP-14/16/17 depends on it.

EP-16 (node-correlated tracing + feedback channel) is separate because it is the prerequisite
the optimizer wave (MasterPlan 3) most needs and V1 explicitly deferred: the trace has "no
backward mapping from a span to the Program node that issued it," so bootstrap recovers only
program-level I/O and GEPA-style reflection is impossible. It introduces a `NodePath`
identity, threads it through a `runProgramTraced`, and adds a per-node feedback slot. It
soft-depends on EP-14 only because the most convincing demonstration routes a real model;
the correlation machinery itself is independent.

EP-17 (live OTel sink) is the smallest, last, and most independent: it wires the deferred
exporter behind `shikumi trace --otel`. It soft-depends on EP-16 only so the exported spans
can carry node-path attributes; functionally it can ship against the existing trace tree.

**Alternatives considered.** (a) *Folding routing and embeddings into one "substrate" plan*
— rejected: embeddings carries an upstream baikai change and an entirely separate effect, so
merging would create one oversized, two-headed plan. (b) *Doing node-correlation inside
MasterPlan 3's GEPA plan* — rejected: per-node correlation is also needed by per-node
bootstrap and the grounded proposer, so it belongs in the shared substrate, defined once.
(c) *Skipping ambient routing and passing a `Model` argument to `runProgram` directly* —
considered; rejected as the default because it would break integration point #4's pinned
signature and force every V1 consumer (eval, optimize, CLI, tools) to thread a model
argument. EP-14 must evaluate both and is free to expose a model-arg helper *in addition to*
the ambient effect, but the ambient effect is the contract.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 14 | Ambient model routing and live native structured output | docs/plans/14-ambient-model-routing-and-live-native-structured-output.md | None | None | Complete |
| 15 | Embedding backend over baikai | docs/plans/15-embedding-backend-over-baikai.md | None | None | Complete |
| 16 | Node-correlated tracing and feedback channel | docs/plans/16-node-correlated-tracing-and-feedback-channel.md | None | EP-14 | Complete |
| 17 | Live OpenTelemetry export sink | docs/plans/17-live-opentelemetry-export-sink.md | None | EP-16 | Complete |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-14).


## Dependency Graph

There are no hard dependencies inside this MasterPlan — by design, so all four plans can be
picked up immediately. The soft edges only sharpen demonstrations.

EP-14 (ambient routing) is the root. It changes how `runProgram`/`runProgramConc` choose a
`Model` and `Options` per node, and it activates `attachSchema` (today a no-op in
`Shikumi.Adapter`) so the derived JSON schema is set on `Options.responseFormat` for
native-capable models. Nothing here blocks on anything else.

EP-15 (embeddings) is fully independent. Its upstream baikai client and its `Embedding`
interpreter touch no file EP-14/16/17 touch.

EP-16 (node-correlated tracing) soft-depends on EP-14: the correlation logic (assigning a
`NodePath` to each node and opening a span per node in `runProgramTraced`) is independent of
routing, but the headline acceptance — "run a real program against a real model and see each
LM span tagged with its node path" — reads best once EP-14 can route a real model. EP-16 can
be implemented first against the neutral `_Model`; the demonstration simply uses a stub LM.

EP-17 (live OTel sink) soft-depends on EP-16: the exporter works against today's `TraceTree`,
but exporting the new per-node `NodePath` attribute requires EP-16's span fields. Implement
EP-17 last to export the richest spans; it does not block on EP-16 to compile.

**Parallelism.** All four can run concurrently. The natural ordering for a single
implementer is EP-14 → EP-16 → EP-17 (the trace chain) with EP-15 (embeddings) slotted in at
any point.


## Integration Points

These are the shared artifacts this MasterPlan defines and that MasterPlans 3 and 4 consume.
Each names the owning plan and how consumers use it. The exact current signatures these
extend are recorded in the integration dossier the plans were authored from; every child
plan embeds the relevant excerpt.

1. **The ambient model-routing effect.** *Owner: EP-14.* A new `effectful` effect (working
   name `Routing`, exposing the current `Model` and a per-call `Options` overlay) plus its
   interpreter `runRouting :: Model -> Eff (Routing : es) a -> Eff es a`, and the revised
   `runProgram`/`runProgramConc` that read the ambient model instead of the hardcoded
   `_Model` at `Shikumi.Program` (today: `defaultModel = _Model`). **Integration point #4's
   pinned signature `runProgram :: (LLM :> es, Error ShikumiError :> es) => Program i o ->
   i -> Eff es o` must not change**; the ambient model is supplied by an interpreter lower in
   the stack, exactly as `LLM`/`Error` already are. *Consumers:* every program execution in
   MasterPlans 3 and 4; in particular the self-refinement modules (MasterPlan 3 EP-18) and
   the multi-sample paths rely on EP-14 making per-sample temperature live. The
   `TempSchedule` carried by `MajorityVote` (today "carried + serialized but inert on the
   wire") becomes live here.

2. **Live `attachSchema` and the native adapter.** *Owner: EP-14.* `attachSchema :: Value ->
   Options -> Options` in `Shikumi.Adapter` becomes a real setter of
   `Options.responseFormat = Just (JsonSchema {name, schema, strict})` (baikai's
   `Baikai.ResponseFormat` already exists; `Options.responseFormat` already exists). `capabilityFor`
   / `adapterFor` already select native vs. fallback by `Model`. *Consumers:* MasterPlan 4's
   adapter-completeness plan (EP-26) extends the same seam; MasterPlan 3's optimizers benefit
   from enforced structured output but do not depend on it.

3. **Node-path identity and `runProgramTraced`.** *Owner: EP-16.* A `NodePath` type
   identifying a node's structural position in a `Program` (derived from the same
   left-to-right depth-first order as `foldParams`/`programShape`), a new optional
   `nodePath :: Maybe NodePath` (or equivalent) field on `Shikumi.Trace.SpanAttrs`, and a
   `runProgramTraced :: (LLM :> es, Trace :> es, Error ShikumiError :> es) => Program i o ->
   i -> Eff es o` that opens a span per node carrying its `NodePath`. *Consumers:* MasterPlan
   3's MIPROv2/bootstrap (per-node demo recovery), the grounded proposer (per-node field
   summaries), and especially GEPA (reflective per-predictor feedback). The node ordering
   **must agree** with `foldParams`/`mapParamsAt` integer indexing so that a `NodePath`
   maps to the same node a parameter edit would touch.

4. **The per-node feedback channel.** *Owner: EP-16.* A typed slot (working name
   `Feedback`, carried alongside or inside the trace) that lets a metric or judge attach a
   short textual critique to a specific `NodePath`, and a way for an optimizer to read all
   feedback for a node. *Consumers:* GEPA (MasterPlan 3 EP-22) reads node feedback to mutate
   that node's instruction; the grounded proposer (EP-19) may read it as an additional
   proposal signal.

5. **The embeddings interpreter.** *Owner: EP-15.* A concrete interpreter for the existing
   `Embedding` effect (`Shikumi.Eval.Metric.Embedding`, op `EmbedText :: Text -> Embedding m
   (Vector Double)`), backed by a new upstream baikai embeddings client, supplied as
   `runEmbeddingLLM`/`runEmbeddingWith` (name TBD by EP-15) so `semanticSimilarity` runs.
   *Consumers:* MasterPlan 3's KNN few-shot (EP-23) and any similarity-based demo selection;
   MasterPlan 4 does not consume it. EP-15 owns both the upstream baikai client and the
   Shikumi interpreter and must document the model-naming convention for embedding models.


## Progress

- [x] EP-14: Ambient `Routing` effect + interpreter; `runProgram`/`runProgramConc` dispatch a named model
- [x] EP-14: Live `attachSchema` (native `responseFormat`) + per-sample temperature applied on the wire
- [x] EP-15: Upstream baikai embeddings client (new transport)
- [x] EP-15: Shikumi `Embedding`-effect interpreter; `semanticSimilarity` runs end-to-end
- [x] EP-16: `NodePath` identity + `runProgramTraced` correlating spans to nodes
- [x] EP-16: Per-node feedback channel readable/writable by metrics and optimizers
- [x] EP-17: Live OpenTelemetry exporter wired behind `shikumi trace --otel`


## Surprises & Discoveries

These were surfaced while authoring the child plans (2026-06-09), before implementation;
they refine the integration contracts above.

- **EP-14 can preserve integration point #4 exactly** by routing through an `interpose` on the
  `LLM` effect rather than adding the ambient model to `runProgram`'s row. The plan adopts
  approach (a) from the Decomposition Strategy: a `runRouting :: Model -> Eff (Routing : es) a
  -> Eff es a` interpreter installs a model-aware router *below* `runProgram` (the same seam
  `cachedLLM` and `tracedLLM` already use). Because `runProgram` must render before the real
  model is known, the derived JSON schema and per-sample temperature are carried as private
  `Options.metadata` keys (`"shikumi.responseSchema"`, `"shikumi.temperature"`) that the router
  translates into `responseFormat`/`temperature` against the real model and strips before
  transport. Consequence: `runProgram :: (LLM :> es, Error ShikumiError :> es) => …` is
  **unchanged**, so MasterPlans 3 and 4 inherit the pinned row with no edit. (If the M0 spike
  disproves (a), the fallback is approach (b) — a `Reader Model` effect in the row — which
  *would* change #4 and require notifying MasterPlans 3/4; EP-14 documents that protocol.)
- **EP-16 exposes per-node field metadata as type-erased field *names* (`[Text]`), not a
  `Signature` accessor.** Because `Predict` hides its `i`/`o` existentially, a typed
  `nodeSignature` cannot escape the GADT; EP-16 provides `nodeFields`/`nodeFieldsIndexed ::
  Program i o -> [[Text]]` (input/output field names per node, indexed to match `foldParams`).
  MasterPlan 3's grounded proposer (EP-19) consumes exactly this. The per-node **feedback**
  channel is a *sibling* `FeedbackLog (Map NodePath [Text])` with its own `Feedback` effect,
  deliberately kept **out** of `TraceTree` to avoid churning the serialized trace format;
  EP-16 still bumps the trace `currentFormatVersion` 1→2 for the new optional `nodePath` span
  attribute.
- **EP-15's upstream embeddings client can reuse the vendored `openai` SDK** rather than
  hand-rolling HTTP: `OpenAI.V1.Embeddings.createEmbeddings` already exists on disk, so the new
  `Baikai.Embedding` client wraps baikai-openai's existing client/auth path. Caveat the plan
  records: that SDK's `CreateEmbeddings.input` is a single `Text`, so batch embedding loops
  per-input.


## Decision Log

- Decision: Split V1's deferred substrate work into a dedicated foundation MasterPlan of four
  plans rather than folding it into the optimizer initiative.
  Rationale: routing, embeddings, and node-correlated tracing are each consumed by *multiple*
  downstream plans across MasterPlans 3 and 4; defining them once in a shared substrate plan
  prevents three optimizer plans from each re-deriving the same prerequisite. The user
  directed dividing the follow-up into multiple master plans.
  Date: 2026-06-09.
- Decision: Make ambient model routing the keystone (EP-14) and require it to preserve
  integration point #4's `runProgram` signature by supplying the model through an interpreter,
  not a function argument.
  Rationale: V1 pinned `runProgram :: (LLM :> es, Error ShikumiError :> es) => Program i o ->
  i -> Eff es o` and every consumer (eval, optimize, tools, CLI) inherits it; threading a
  `Model` argument would break all of them, whereas an ambient `Reader Model`-style effect is
  discharged at the bottom of the stack like `LLM` and `Error` already are.
  Date: 2026-06-09.
- Decision: Give embeddings its own plan (EP-15) with an explicit upstream baikai component.
  Rationale: baikai ships no embeddings client (verified by absence of any `embed` symbol in
  `baikai/src`); the work mirrors V1's `baikai-effectful`/EP-2 upstream contributions and is
  independent of the routing/trace chain.
  Date: 2026-06-09.
- Decision: Associate this MasterPlan with intention `intention_01ktq80610e6nbe3d7yrct59an`;
  every commit carries `MasterPlan:`, `ExecPlan:`, and `Intention:` trailers.
  Date: 2026-06-09.


## Outcomes & Retrospective

**Status: Complete (2026-06-09).** All four child ExecPlans landed; the whole shikumi fleet
(`cabal test all`) and baikai's suite are green, with no consumer's pinned row broken.

What shipped, against the four integration points:

1. **Ambient model routing (EP-14).** `Shikumi.Routing` provides the `Routing` effect,
   `runRouting`, and the `routeLLM` re-interpreter. `runProgram`/`runProgramConc` are now
   model-agnostic — they render against an inert placeholder and stamp intentions onto a private
   `Options.metadata` channel; `routeLLM` overwrites the placeholder with the ambient model.
   Integration point #4's pinned signature is **unchanged** (approach (a) held; no cross-plan
   notification needed). `MajorityVote`'s `TempSchedule` is now live on the wire.
2. **Live `attachSchema` / native adapter (EP-14).** `attachSchema` is a real metadata setter and
   `routeLLM` turns it into `Options.responseFormat = Just (JsonSchema …)` for native-capable
   models (stripped for fallback). A lenient parser (native JSON, then markers) keeps every prior
   test green while making the native path coherent.
3. **Node-path identity + `runProgramTraced` (EP-16).** `Shikumi.Trace.Node` gives each `Predict`
   node a `NodePath` that agrees with `foldParams`/`mapParamsAt` by construction;
   `Shikumi.Trace.Program.runProgramTraced` tags each model-call span with it. `nodeFields`/
   `nodeFieldsIndexed` expose per-node field names. Trace `formatVersion` bumped 1→2.
4. **Per-node feedback channel (EP-16).** `Shikumi.Trace.Feedback` is a trace-format-independent
   sibling (`FeedbackLog` + `Feedback` effect) for per-node critiques.
5. **Embeddings interpreter (EP-15).** baikai gained its first embeddings client
   (`Baikai.Embedding`); shikumi gained `Shikumi.Eval.Embedding` (`runEmbeddingWith`/
   `runEmbeddingLLM`/`runEmbeddingBy`), so `semanticSimilarity` runs end to end.

Plus EP-17: `shikumi trace --otel` now exports the recorded tree (with `shikumi.node_path`) to a
real OTLP collector via `Shikumi.Trace.LiveExport`.

Notable course corrections (all recorded in the child plans' Decision Logs / Surprises): EP-14
went straight to production rather than shipping a throwaway spike, and uses lenient parsing
instead of switching the default render to native; EP-16 used a combined `tracedNodeLLM` capture
(not the layered interpose the plan sketched, which would have tagged the wrong span); EP-17 factors
its shared orchestration on a `SpanProcessor` (the type both the in-memory recorder and the OTLP
exporter can produce), not the `SpanExporter` the plan assumed. None changed the integration
contracts MasterPlans 3 and 4 depend on.
