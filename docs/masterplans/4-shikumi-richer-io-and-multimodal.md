---
id: 4
slug: shikumi-richer-io-and-multimodal
title: "Shikumi Richer IO and Multimodal"
kind: master-plan
created_at: 2026-06-09T22:35:20Z
intention: "intention_01ktq812wfebgvf1dtbvg3v826"
---

# Shikumi Richer IO and Multimodal

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

Shikumi's V1 (`docs/masterplans/1-shikumi-typed-lm-programming-framework.md`) treats every
signature as a record of text fields rendered to and parsed from a single text channel, runs
programs to completion with a blocking call, and ships two adapters (the native JSON adapter
and the `[[ ## field ## ]]` prompt fallback). DSPy 3.3 (surveyed from a fresh clone) is
broader on the I/O surface: it carries multimodal field types (`Image`, `Audio`, `Document`,
`Code`, `History`), streams partial results with status messages (`streamify`,
`StreamResponse`, `StatusMessage`), offers more adapters (`XMLAdapter`, `TwoStepAdapter`) and
declarative Pydantic-style field constraints, and includes code-execution modules
(`ProgramOfThought`, `CodeAct`) that write and run code in a sandbox. This MasterPlan brings
the I/O surface to parity, expressed through Shikumi's typed signatures.

This is the *orthogonal parity* wave: unlike the optimizer initiative
(`docs/masterplans/3-shikumi-dspy-parity-optimizers-and-self-refinement.md`), most of it does
not change how programs are optimized — it widens what flows in and out of them and how a
caller observes execution. After this initiative a Shikumi user can: (1) declare a signature
whose input includes an image (or audio/document) field and have it lowered to baikai's
multimodal `Content` so the model actually sees the image — baikai already models inline
images (`Baikai.Content.UserImage`/`ImageContent`); (2) stream a program's output
field-by-field with status messages ("calling tool X", "model thinking") surfaced to the
caller, built over baikai's `StreamEach` per-event callback that V1 never exposed at the
program level; (3) choose an XML or two-step adapter, and declare field constraints (minimum
length, numeric bounds, enum) that flow into both the JSON schema and the `Validatable`
check; and (4) use a `programOfThought`/`codeAct` module that has the model emit code, runs
it in a sandboxed interpreter, and feeds the result back — the one DSPy capability furthest
from a typed-Haskell framework's grain, included as a clearly-scoped stretch plan.

**In scope:** multimodal field types and their lowering to baikai `Content`; program-level
streaming and status messages; adapter completeness (XML, two-step) and declarative field
constraints; code-execution modules (`ProgramOfThought`/`CodeAct`) via a sandboxed interpreter
effect.

**Out of scope:** the optimizer/refinement stack (MasterPlan 3); the substrate (routing,
embeddings, node-correlated tracing) delivered by MasterPlan 2 — though one plan here
(streaming) soft-depends on MasterPlan 2's routing so a streamed program targets a real model;
and any provider work baikai cannot already do (e.g. audio/video input is bounded by baikai's
`Content` constructors — baikai today models `UserText`/`UserImage` only, so audio/document
fields beyond what baikai supports are noted as upstream-gated, not assumed).


## Decomposition Strategy

The initiative splits into **four child ExecPlans**, one per I/O concern, grouped so the
clearly-additive parity items come first and the exotic code-execution module is an explicit
final stretch.

EP-24 (multimodal field types) is first and self-contained: it extends the `ToSchema`/
`FromModel`/`ToPrompt`/`Adapter` seam so a signature field can be an image (or other media)
that lowers to baikai's existing `UserImage`/`ImageContent`. It touches the schema and adapter
layers but no run semantics.

EP-25 (program-level streaming + status messages) is separate because it is an execution-time
concern, not a typing concern: it surfaces baikai's `StreamEach` events through a new
program-level streaming entry point and a status-message provider. It soft-depends on
MasterPlan 2's routing so a streamed program targets a real model, but can be demonstrated
with a stub event source.

EP-26 (adapter completeness + declarative field constraints) groups two closely-related
adapter-layer concerns: new `Adapter` implementations (XML, two-step) and field-level
constraints that enrich both the generated JSON schema and the `Validatable` check. Both edit
the same `Shikumi.Schema`/`Shikumi.Adapter` files, so per the decomposition principle
("two plans that must modify the same function in the same way should likely be one plan")
they are one plan.

EP-27 (code-execution modules) is the explicit stretch: `ProgramOfThought`/`CodeAct` need a
sandboxed code interpreter (DSPy uses a Deno/WASM or Python sandbox). It is isolated last so
the rest of the MasterPlan delivers regardless of whether the sandbox work is pursued; it is
the least aligned with Shikumi's typed value proposition and carries the most external risk.

**Alternatives considered.** (a) *Merging streaming into the multimodal plan* — rejected:
typing vs. execution-time concerns, different files, independently verifiable. (b) *Splitting
field constraints out of the adapter plan* — rejected: constraints live in the same schema
generation code the adapters touch; splitting would create cross-plan coupling on the same
functions. (c) *Dropping code modules entirely* — considered; kept as a labeled stretch
because it is real DSPy surface, but ordered and scoped so it never blocks the parity items.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 24 | Multimodal field types | docs/plans/24-multimodal-field-types.md | None | None | Complete |
| 25 | Program-level streaming and status messages | docs/plans/25-program-level-streaming-and-status-messages.md | None | EP-14 (MP-2) | Complete |
| 26 | Adapter completeness and declarative field constraints | docs/plans/26-adapter-completeness-and-declarative-field-constraints.md | None | EP-24 | Complete |
| 27 | Code-execution modules ProgramOfThought and CodeAct | docs/plans/27-code-execution-modules-programofthought-and-codeact.md | None | None | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference rows by their # prefix. `EP-14` lives in MasterPlan 2
(`docs/masterplans/2-shikumi-substrate-routing-completion.md`).


## Dependency Graph

There are no hard dependencies — every plan can be picked up independently. The soft edges
only sharpen demonstrations.

EP-24 (multimodal) is independent. EP-26 (adapters + constraints) soft-depends on EP-24
because both edit the schema/adapter seam; if EP-24 lands first, EP-26 extends the same field
machinery rather than reconciling a parallel one. They can also be done in the other order or
together; the soft edge is a sequencing preference, not a compile requirement.

EP-25 (streaming) soft-depends on MasterPlan 2 EP-14 (ambient routing): streaming a program
against a *real* provider is the headline demo, and that needs routing; but the streaming
machinery (surfacing `StreamEach` events, status messages) can be built and tested against a
stub event source first.

EP-27 (code modules) is independent of the others and explicitly optional; it is ordered last.

**Parallelism.** All four can proceed concurrently. A single implementer's natural order is
EP-24 → EP-26 (the schema/adapter chain), with EP-25 and EP-27 slotted in independently.


## Integration Points

These are the shared artifacts this MasterPlan touches. Each child plan embeds the exact
current signatures it builds on (from the integration dossier) so it stands alone.

1. **The schema/adapter seam.** *Owner: V1 EP-3; extended by EP-24 and EP-26.* The
   `ToSchema`/`FromModel`/`ToPrompt` derivations and the `Adapter i o` record (`render ::
   Signature i o -> i -> (Context, Options)`, `parse :: Signature i o -> Response -> Either
   ShikumiError o`) in `Shikumi.Schema`/`Shikumi.Adapter`. EP-24 adds media field types that
   the derivations recognize and that `render` lowers to baikai `Content` (`UserImage`); EP-26
   adds XML/two-step `Adapter` values and constraint-aware schema generation. Both must keep
   the existing text-field path working unchanged (V1 integration point #3). They edit the
   same modules, so they coordinate here: EP-24 defines the media-field mechanism; EP-26
   defines the constraint mechanism; neither breaks the other's path.

2. **baikai multimodal `Content` (inherited from baikai).** *Owner: baikai; consumed by
   EP-24.* `Baikai.Content.UserContent = UserText !TextContent | UserImage !ImageContent`,
   with `ImageContent { imageData :: ByteString, mimeType :: Text }` (decoded bytes, not
   base64). EP-24 lowers an image field to `UserImage`. Audio/document/video are **not** in
   baikai's `Content` today; EP-24 documents which media types are deliverable now (image) vs.
   upstream-gated (audio/document) and may add the upstream baikai content constructor if the
   plan chooses to pursue a non-image medium.

3. **baikai streaming `StreamEach` (inherited from baikai-effectful).** *Owner:
   baikai-effectful; consumed by EP-25.* `StreamEach :: Model -> Context -> Options ->
   (AssistantMessageEvent -> m ()) -> Baikai m ()` and the `Shikumi.LLM` effect's `Stream`
   op (today defined but only used by the materializing `stream`, never by `runProgram`).
   EP-25 adds a program-level streaming entry point that drives `StreamEach` and emits
   `StreamResponse`/`StatusMessage`-equivalent events. It must not change `runProgram`'s
   blocking contract (V1 integration point #4); streaming is an additive, separate entry
   point.

4. **The ambient routing effect (inherited from MP-2 EP-14).** *Owner: MP-2 EP-14; consumed
   (soft) by EP-25.* A streamed program targets the ambient model from
   `docs/masterplans/2-shikumi-substrate-routing-completion.md` integration point #1.

5. **The `Program` GADT extension rule (inherited from V1 EP-4).** *Owner: V1 EP-4; respected
   by EP-27.* If EP-27's code modules add a new `Program` constructor, it is a compile error
   until `paramsTraversal`, `programShape`, and `setProgramParams` pattern-match it; prefer an
   `Embed` node (as V1's `react` did) so the parameter-count invariant (count == number of
   `Predict` nodes) holds and the compilers pass it through unchanged.


## Progress

- [x] EP-24: Image (and other feasible media) field types lower to baikai `Content`; model sees the image
- [x] EP-24: Round-trip through `ToSchema`/`FromModel`/`ToPrompt` for a media-bearing signature
- [x] EP-25: Program-level streaming entry point surfacing field chunks via `StreamEach`
- [x] EP-25: Status messages (LM start/end, tool start/end) surfaced to the caller
- [x] EP-26: `XMLAdapter` and `TwoStepAdapter` selectable alongside native/fallback
- [x] EP-26: Declarative field constraints flow into JSON schema and `Validatable`
- [ ] EP-27: `programOfThought`/`codeAct` run model-emitted code in a sandbox and feed results back


## Surprises & Discoveries

These were surfaced while authoring the child plans (2026-06-09), before implementation;
they refine the integration contracts above.

- **EP-24 is image-only at delivery; audio/document are upstream-gated.** Confirmed against
  source: baikai's `UserContent` is exactly `UserText | UserImage`. So EP-24 ships image
  (lowering to `UserImage`/`ImageContent`, decoded bytes + mimeType) and documents the precise
  upstream `Baikai.Content` constructor a future plan would add for audio/document — it does not
  claim a medium baikai cannot send. Image fields are **input-only** (no `ToSchema Image`, so
  "image in an output record" is a clean compile error), and the single render change is gated
  so the existing text-field path is provably untouched (the EP-26 coexistence requirement).
- **`twoStepAdapter` is a combinator (an `Embed` node), not an `Adapter` value.** EP-26 found
  that `Adapter.parse :: Signature i o -> Response -> Either ShikumiError o` is *pure* and so
  structurally cannot issue the second model call a two-step extraction needs. It is therefore
  delivered as `twoStep :: … -> Program i o` built on `Embed` (free-form call, then an
  extraction call reusing the fallback adapter) — the same Embed-node pattern the optimizer
  MasterPlan leans on. `xmlAdapter` *is* a normal third `Adapter` value alongside native/fallback.
- **The `Embed`-row constraint reaches here too.** EP-27's sandboxed code modules cannot add a
  `CodeInterpreter` effect to the `Embed` body row (fixed at `(LLM, Error ShikumiError)`), so the
  interpreter is modeled as a plain `newtype CodeInterpreter` value captured in the closure —
  exactly how `react` captures its `ToolRegistry`. The hermetic restricted interpreter fits
  inside `Embed`; the real subprocess interpreter needs `IOE` and is offered only through a
  separate gated, non-CI entry point. (Same pattern recorded in MasterPlan 3's Surprises.)
- **EP-24 implemented: image discovery lives on `ToPrompt`, not a separate class — affects EP-26.**
  (Discovered during EP-24 M2 implementation, 2026-06-09.) The authored EP-24 plan put image
  collection in a standalone `ImageFields` class with a blanket `OVERLAPPABLE` instance. That design
  is unbuildable: the overlappable blanket poisons given-resolution (GHC-39999 — a given
  `ImageFields i` is not used to discharge `adapterFor`'s wanted one), and polymorphic-field Predict
  inputs (`MultiChainInput`, `WithReasoning`) cannot be walked generically so they need a manual
  instance that *requires* the poisoning overlap. **Delivered mechanism:** `imageFields` and
  `imageFieldNames` are methods on the existing `Shikumi.Adapter.ToPrompt` class (generic defaults
  backed by `GImageFields`/`GImageFieldNames` in `Shikumi.Multimodal`); `render`'s `userTurn` lowers
  the first image field. This reused the `ToPrompt i` constraint already threaded through
  `predict`/`Predict`/`adapterFor`, so **no new constraint and zero fixture churn** workspace-wide.
  *Integration note for EP-26* (`docs/plans/26-adapter-completeness-and-declarative-field-constraints.md`):
  `ToPrompt` now carries two extra methods with generic defaults; an EP-26 hand-written `ToPrompt`
  instance on a type with polymorphic/non-`Generic` fields must add `imageFields _ = []` and
  `imageFieldNames _ = []` (the all-text path is unaffected — `userTurn` falls back to
  `user (toPrompt i)` whenever `imageFields i == []`). Integration point #1's text-field path is
  intact and the schema layer (`ToSchema`/`FromModel`) was not touched by EP-24, so EP-26's
  constraint mechanism is free of EP-24 collisions.
- **EP-26 delivered: the EP-24 `ToPrompt` coexistence held with zero friction.**
  (Discovered during EP-26 implementation, 2026-06-09.) EP-24's integration note warned
  that any EP-26 hand-written `ToPrompt` instance on a non-`Generic`/polymorphic-field
  type must add `imageFields _ = []` / `imageFieldNames _ = []`. EP-26's only new
  `ToPrompt` instance is the internal `ExtractIn` (a plain `Generic` newtype), which gets
  the generic defaults for free — no manual override needed. The schema layer
  (`ToSchema`/`FromModel`) that EP-26's `Constrained` mechanism extends was untouched by
  EP-24, so the two mechanisms compose on disjoint instance heads exactly as predicted:
  `Constrained`, `xmlAdapter`, and `twoStep` are all-new surface, the `Field`/bare-`Text`
  path is unaltered, and all EP-24 multimodal specs still pass. **One typeclass wrinkle
  for any future schema-layer plan:** `ReflectConstraints`' schema-emitting method does not
  mention its value-type parameter `a`, so recursive calls need explicit type applications
  (`constraintSchema @cs @a Proxy`); see EP-26's Surprises. **`twoStep` is an `Embed`
  node** (per the pre-authoring Surprise above), confirmed to carry no `Params` and pass
  through the serializers unchanged.
- **Field-level streaming is honestly scoped.** EP-25 delivers field chunks for a single
  `Predict` (and chains) on the `[[ ## field ## ]]` fallback/raw-text path — the exercised path
  since `defaultModel` maps to `PromptFallback` and `attachSchema` is a no-op; native whole-JSON
  field chunking is explicitly *not* promised. Aggregating combinators stream status, not field
  chunks. `runProgram`'s blocking contract is untouched; `streamProgram` is a separate additive
  entry point.


## Decision Log

- Decision: Treat richer I/O as its own MasterPlan, orthogonal to the optimizer initiative,
  with four plans (multimodal, streaming, adapters+constraints, code modules).
  Rationale: these widen what flows in/out of programs and how execution is observed, not how
  programs are optimized; they share the schema/adapter seam, not the optimizer surface.
  Date: 2026-06-09.
- Decision: Group adapter completeness and declarative field constraints into one plan (EP-26).
  Rationale: both edit the same `Shikumi.Schema`/`Shikumi.Adapter` code; splitting would
  couple two plans on the same functions, violating the decomposition principle.
  Date: 2026-06-09.
- Decision: Scope code-execution modules (EP-27) as an explicit, last, optional stretch.
  Rationale: a sandboxed code interpreter is the highest-risk, least typed-Haskell-aligned
  DSPy capability; isolating it last ensures the parity items ship regardless.
  Date: 2026-06-09.
- Decision: Bound multimodal scope by baikai's existing `Content` (image is deliverable now;
  audio/document are upstream-gated and called out as such in EP-24).
  Rationale: baikai models `UserText`/`UserImage` only; honesty about provider limits prevents
  a plan that compiles but cannot send the medium.
  Date: 2026-06-09.
- Decision: Associate this MasterPlan with intention `intention_01ktq812wfebgvf1dtbvg3v826`;
  every commit carries `MasterPlan:`, `ExecPlan:`, and `Intention:` trailers.
  Date: 2026-06-09.


## Outcomes & Retrospective

(To be filled during and after implementation.)
