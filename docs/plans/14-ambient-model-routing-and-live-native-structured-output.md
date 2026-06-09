---
id: 14
slug: ambient-model-routing-and-live-native-structured-output
title: "Ambient model routing and live native structured output"
kind: exec-plan
created_at: 2026-06-09T22:35:41Z
intention: "intention_01ktq80610e6nbe3d7yrct59an"
master_plan: "docs/masterplans/2-shikumi-substrate-routing-completion.md"
---

# Ambient model routing and live native structured output

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Shikumi is a typed LM-programming framework. You write a `Program i o` — a tree of typed
"predict" nodes and combinators — and run it with `runProgram program input`, which issues
calls to a large-language-model (LM) provider and decodes the replies back into your typed
output. Today there is a hole right in the middle of that hot path: **`runProgram` ignores
which model you want and always dispatches against a blank, provider-neutral model.**

Concretely, in `shikumi/shikumi/src/Shikumi/Program.hs` the executor hardcodes

```haskell
defaultModel :: Model
defaultModel = _Model
```

where `_Model` is baikai's empty record (`modelId = ""`, `provider = ""`, `api = Custom ""`).
Three user-visible consequences follow, and all three are the point of this plan:

1. **You cannot choose a real provider.** Whatever real model you registered, every `Predict`
   node still calls `complete _Model ctx opts`. The bottom transport interpreter has to guess
   a provider from an empty model, so in practice only the hermetic stub path works and a real
   OpenAI/Anthropic call is impossible to express through `runProgram`.

2. **The JSON schema is never enforced on the wire.** Each typed output has a derived JSON
   Schema (via `ToSchema`). For models that support provider-native structured output
   (OpenAI's `response_format`, Anthropic's `output_config`), shikumi *should* transmit that
   schema so the provider guarantees a conforming reply. But `attachSchema` in
   `shikumi/shikumi/src/Shikumi/Adapter.hs` is a no-op (`attachSchema _schema opts = opts`),
   and because the model is always the blank `_Model`, `capabilityFor _Model` is always
   `PromptFallback` — so the native adapter is never even selected. Structured output is
   requested only by prose in the prompt, never enforced by the provider.

3. **Per-sample temperature is inert.** The `MajorityVote k schedule program` combinator
   carries a `TempSchedule` (an explicit or spread temperature per sample). The schedule is
   stored, serialized, and inspectable, but `runProgram`'s `MajorityVote` clause discards it
   (`runProgram (MajorityVote k _sched p) i = ...`). Every one of the `k` samples is sent with
   identical options, so "vary the temperature across samples" does nothing.

**After this change**, a shikumi user picks a real model *by name* — for example
`Baikai.Models.Generated.openai_gpt_4o_mini`, a value from baikai's generated catalog — and
installs it once at the bottom of the effect stack. From then on every `Predict` node in
`runProgram`/`runProgramConc` dispatches against that model; for native-capable models the
derived JSON Schema is actually set on `Options.responseFormat = Just (JsonSchema {name,
schema, strict})` and transmitted; and `MajorityVote`'s `TempSchedule` actually sets
`Options.temperature` per sample on the wire.

**How you see it working (the headline scenario).** With no network and no API key, a hermetic
test installs a *capturing stub LM* that records every outgoing request as JSON. You run a
two-node pipeline routed to a native-capable model, then assert that the captured request JSON
contains the derived schema under `responseFormat` and that, under a `MajorityVote` with a
spread schedule, the captured temperatures differ across samples. The same test, run against
the old code, fails (no `responseFormat`, identical temperatures); against the new code it
passes. An optional, API-key-gated live test does the same against a real provider.

**The design constraint that makes this non-trivial** is integration point #4 of the parent
master plan (`docs/masterplans/2-shikumi-substrate-routing-completion.md`): the pinned
signature

```haskell
runProgram :: (LLM :> es, Error ShikumiError :> es) => Program i o -> i -> Eff es o
```

**must not change.** Every downstream consumer (evaluation, optimizers, the CLI, tools)
inherits that exact row. So we may not add a `Model` argument and we may not add a new
constraint to `runProgram`. The ambient model has to arrive the same way `LLM` and `Error`
already do: through an interpreter installed lower in the effect stack. This plan resolves how
to do that while still letting adapter selection and schema attachment see the real model. The
mechanism is proven first in a prototype milestone (M0) before any production wiring.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] **M0 (prototype):** Subsumed. The `interpose`-on-`LLM` seam is already proven twice in the
  repo (`cachedLLM`, `tracedLLM`), so rather than ship a throwaway spike module we went straight
  to the production `Shikumi.Routing` and validated the identical four assertions in the
  production `RoutingSpec` (`shikumi/test/RoutingSpec.hs`). Recorded in the Decision Log.
- [x] **M1:** `Shikumi.Routing` effect + `runRouting :: Model -> Eff (Routing : es) a -> Eff es a`
  exist (`shikumi/src/Shikumi/Routing.hs`); `runProgram`/`runProgramConc` dispatch the ambient
  model via `routeLLM` (the placeholder `_Model` is overwritten); the pinned
  integration-point-#4 signature is unchanged (verified by build of the whole fleet). `RoutingSpec`
  test "routes the ambient model id onto the wire" passes (captured `modelId == "gpt-4o-mini"`).
- [x] **M2:** `attachSchema` is a real setter onto the `Options.metadata` channel; `routeLLM`
  turns it into `Options.responseFormat = Just (JsonSchema {...})` for native-capable models and
  strips it; fallback models leave `responseFormat = Nothing`. Tests "native model attaches
  responseFormat with the derived schema" and "fallback model leaves responseFormat unset" pass;
  both assert the private key is stripped.
- [x] **M3:** `MajorityVote`'s `TempSchedule` is threaded per sample via the metadata channel and
  realized by `routeLLM` as `Options.temperature`. Tests show distinct spread temperatures
  `{0.1,0.5,0.9}`, exact fixed `[0.1,0.9]`, the private temperature key stripped, and
  `runProgram`/`runProgramConc` agree on the multiset.
- [ ] **M4 (optional, gated):** A `SHIKUMI_LIVE`-gated live test routes a real provider and
  asserts a schema-conforming reply. Deferred — the hermetic stub path (M0–M3) is the exercised
  one; the existing `LiveSpec` already proves real OpenAI dispatch end to end.
- [x] Master-plan Progress checkboxes for EP-14 ticked; Decision Log / Surprises updated.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **baikai's `responseFormat`/`metadata` fields already exist.** The `Shikumi.Adapter` header
  comment claimed "EP-2 is not yet merged … `Options` has no `responseFormat` field," but the
  current baikai checkout (`baikai/src/Baikai/Options.hs`) already carries both `responseFormat ::
  Maybe ResponseFormat` and `metadata :: Map Text Value`, and `Baikai.ResponseFormat.JsonSchema`
  exists. So no upstream baikai change was needed for EP-14; the stale comment was corrected.
- **The render-time adapter cannot be the model-dependent one.** Because `runProgram` renders
  before the ambient model is known, it cannot pick native-vs-fallback rendering/parsing per the
  real model. Rather than switch the default render to native (which would have broken every
  existing marker-fed hermetic test), `runPredict` keeps the existing fallback render, *stamps*
  the derived schema onto the metadata channel, and parses *leniently* — trying the native JSON
  parse first and falling back to the marker parser, surfacing the fallback parser's error when
  both fail. This keeps all 80 prior tests green (markers still parse, error behaviour unchanged)
  while making the native routed path coherent: a native model whose `responseFormat` the router
  enforced replies with JSON, which the lenient parser decodes. Evidence: `cabal test shikumi`
  green at 86 tests; `RoutingSpec` proves the captured native request carries the schema and the
  decode still succeeds against a marker stub response.
- **Metadata keys live in `Shikumi.Adapter`, not `Shikumi.Routing`.** The plan suggested defining
  the reserved keys in `Shikumi.Routing`, but `Routing` imports `Adapter` (for `capabilityFor`),
  so the keys must sit in a module both `Adapter` (writer of the schema key), `Program` (writer of
  the temperature key, via `stampTemperature`), and `Routing` (reader of both) can import without a
  cycle. `Adapter` is that lowest common module, so `metaResponseSchemaKey`/`metaTemperatureKey`
  and `stampTemperature` are exported from it. The keys are still defined exactly once.


## Decision Log

Record every decision made while working on the plan.

- Decision: Resolve the routing mechanism in favour of **approach (a): an `interpose`-on-`LLM`
  router** installed below `runProgram`, rather than **approach (b): a `Reader Model` effect in
  `runProgram`'s row.**
  Rationale: approach (b) would force the ambient `Routing` (or `Reader Model`) constraint into
  `runProgram`'s signature, breaking integration point #4's pinned row and cascading a signature
  change to every consumer in MasterPlans 3 and 4. Approach (a) keeps the pinned row exactly as
  is: the router is discharged at the bottom of the stack like `LLM`/`Error`, and `runProgram`
  stays model-agnostic. The repository already proves this seam works twice over — `cachedLLM`
  in `shikumi-cache/src/Shikumi/Cache.hs` and `tracedLLM` in `shikumi-trace/src/Shikumi/Trace.hs`
  both `interpose` on the same `LLM` effect to rewrite/observe calls without touching
  `runProgram`. See "Context and Orientation" for how the model and the derived schema are made
  visible to the router. **This decision does not alter integration point #4; no cross-plan
  notification is required.**
  Date: 2026-06-09 (confirmed in implementation: the whole fleet builds and tests green with the
  pinned `runProgram` row unchanged).
- Decision: Carry the derived JSON Schema and the per-sample temperature **as request metadata
  on `Options.metadata`** so the model-agnostic `runProgram` can emit them and the model-aware
  router can read them and translate them into `responseFormat` / `temperature` against the real
  model.
  Rationale: `runProgram` renders before it knows the real model (the model is ambient, supplied
  below). It therefore cannot itself decide native-vs-fallback or build the final
  `responseFormat`. The cleanest channel that already exists on every request is
  `Options.metadata :: Map Text Value` (see `baikai/baikai/src/Baikai/Options.hs`). The render
  step stamps two private metadata keys — one holding the derived schema `Value`, one holding the
  requested temperature — and the router consumes and strips them, attaching the real
  `responseFormat`/`temperature` keyed on the real model's `capabilityFor`. This keeps the schema
  derivation where the types live (in the adapter, parameterised over `o`) while keeping the
  provider decision where the model lives (in the router). See "Interfaces and Dependencies" for
  the exact key names and shapes.
  Date: 2026-06-09 (confirmed in implementation: the whole fleet builds and tests green with the
  pinned `runProgram` row unchanged).


- Decision: **Skip the throwaway M0 spike module and validate the mechanism directly in the
  production `RoutingSpec`.**
  Rationale: the `interpose`-on-`LLM` seam is already proven in production by `cachedLLM` and
  `tracedLLM`; a separate spike would test machinery the repo already exercises. The four M0
  acceptance assertions (routed model id; native `responseFormat` carries the derived schema;
  distinct per-sample temperatures; private metadata keys stripped) are all asserted in
  `shikumi/test/RoutingSpec.hs` against the real `Shikumi.Routing`. No spike code was written or
  retired.
  Date: 2026-06-09.
- Decision: **`runPredict` renders with the existing (fallback) adapter and parses leniently
  (native JSON first, marker fallback), rather than switching the render to native.**
  Rationale: a model-agnostic `runPredict` cannot know at render time whether the real model is
  native-capable, and switching the default render to native JSON would break every existing
  marker-fed hermetic test. Keeping the fallback render (prompts unchanged) plus stamping the
  schema onto the metadata channel plus a lenient parser preserves all prior behaviour while
  making the native routed path coherent (the router enforces `responseFormat`, the model returns
  JSON, the lenient parser decodes it). The fallback parser's error is surfaced when both parses
  fail, so un-routed error behaviour is byte-identical to before.
  Date: 2026-06-09.
- Decision: **Define the reserved metadata keys (and `stampTemperature`) in `Shikumi.Adapter`.**
  Rationale: `Shikumi.Routing` imports `Shikumi.Adapter` for `capabilityFor`, so the keys cannot
  live in `Routing` without a cycle; `Adapter` is the lowest module shared by the schema writer
  (`Adapter`), the temperature writer (`Program`), and the reader (`Routing`).
  Date: 2026-06-09.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

EP-14 delivered. `Shikumi.Routing` provides the ambient `Routing` effect, `runRouting`, and the
`routeLLM` re-interpreter; `runProgram`/`runProgramConc` are now model-agnostic (the placeholder
`_Model` is overwritten by the router) while keeping integration point #4's pinned signature
exactly. `attachSchema` is a live setter onto the private metadata channel, and `routeLLM` turns
it into a native `Options.responseFormat` for native-capable models (stripped for fallback ones).
`MajorityVote`'s `TempSchedule` is now live: each sample's temperature is threaded down and set on
the wire, identically under both executors. Validated hermetically by `shikumi/test/RoutingSpec.hs`
(6 cases) and the whole fleet stays green (`cabal test all` exit 0). Gaps: M4 (gated live
provider check) deferred — the existing `LiveSpec` already proves real OpenAI dispatch, and the
hermetic path is the exercised one; the native prompt is still the fallback marker prompt (a
native model relies on `responseFormat` enforcement plus the lenient JSON parse), which a later
plan can refine to emit a JSON-oriented prompt when desired.


## Context and Orientation

This section assumes no prior knowledge of the repository. Read it before touching code.

### The shape of the repository

Shikumi is a multi-package Cabal project rooted at `/Users/shinzui/Keikaku/bokuno/shikumi`,
with a sibling library `baikai` at `/Users/shinzui/Keikaku/bokuno/baikai` (the transport layer
that actually talks to providers). The packages you will touch live in the `shikumi/` package
(the runtime substrate): `shikumi/src/Shikumi/Program.hs` (the executor) and
`shikumi/src/Shikumi/Adapter.hs` (the request-rendering seam). Tests for that package live in
`shikumi/test/`.

"Effect" / "effect stack" / "interpreter": shikumi is built on the `effectful` library. An
*effect* is a typed capability such as `LLM` (issue a model call) or `Error ShikumiError`
(throw a typed error). A computation's type lists the effects it may use as constraints, e.g.
`(LLM :> es, Error ShikumiError :> es) => Eff es a`. An *interpreter* is a function that
"discharges" one effect from the row by giving it a concrete meaning, e.g.
`runLLM :: (IOE :> es, Error ShikumiError :> es) => Eff (LLM : es) a -> Eff es a`. Interpreters
are stacked; the ones nearest the bottom run last. The key library trick this plan relies on is
`interpose`: it lets you *re-interpret an effect that is still in the row* — you intercept each
operation, optionally rewrite it, and forward it to the handler beneath. `cachedLLM` and
`tracedLLM` both use `interpose` on `LLM`.

"Model": baikai's `Model` is a record (file `baikai/baikai/src/Baikai/Model.hs`, lines 96–111)
carrying `modelId`, `provider`, `api`, pricing, etc. `_Model` (same file, lines 131–146) is the
blank record. Real models are *values in a generated catalog* — module
`Baikai.Models.Generated` (`baikai/baikai/src/Baikai/Models/Generated.hs`) exposes top-level
bindings such as

```haskell
openai_gpt_4o_mini :: Model   -- modelId = "gpt-4o-mini", provider = "openai", api = OpenAIChatCompletions
anthropic_claude_haiku_4_5 :: Model
deepseek_deepseek_chat :: Model
```

To "pick a model by name" means: `import Baikai.Models.Generated (openai_gpt_4o_mini)` and use
that value. That is exactly how the existing `shikumi/test/LiveSpec.hs` selects a real model.

"Options": baikai's `Options` record (file `baikai/baikai/src/Baikai/Options.hs`, lines 34–62)
holds per-call knobs. Two fields matter here:

```haskell
temperature    :: !(Maybe Double)
responseFormat :: !(Maybe ResponseFormat)
metadata       :: !(Map Text Value)
```

`responseFormat` (file `baikai/baikai/src/Baikai/ResponseFormat.hs`) is

```haskell
data ResponseFormat
  = JsonSchema { name :: !Text, schema :: !Value, strict :: !Bool }
  | JsonObject
```

`metadata` is a free-form `Map Text Value` already present on every `_Options`; we use it as a
private channel between the adapter (which knows the types) and the router (which knows the
model). baikai passes `metadata` through but a provider request does not echo arbitrary
metadata keys back as `responseFormat`; the router strips our private keys before the call
reaches the transport, so nothing leaks onto the wire except the `responseFormat`/`temperature`
the router itself sets.

### The current executor (what you are changing)

`shikumi/src/Shikumi/Program.hs` defines `runProgram` and `runProgramConc`. Both delegate every
`Predict` node to a shared helper (lines 278–290):

```haskell
runPredict sig ps i = do
  sig' <- effectiveSignature sig ps
  let adapter = adapterFor defaultModel       -- always _Model -> fallback adapter
      (ctx, opts) = render adapter sig' i
  resp <- complete defaultModel ctx opts      -- always dispatches _Model
  either throwError pure (parse adapter sig' resp)
```

Note three hardcodings: `adapterFor defaultModel`, `render` produces `opts` with no schema and
no temperature, and `complete defaultModel`. The `MajorityVote` clauses (lines 244 and 267–268)
discard the `TempSchedule`.

### The adapter seam (what attaches the schema)

`shikumi/src/Shikumi/Adapter.hs` exposes `render`/`parse` per `Adapter`, plus:

```haskell
capabilityFor :: Model -> ModelCapability        -- NativeSchema for (openai, OpenAIChatCompletions) and (anthropic, AnthropicMessages); else PromptFallback
adapterFor    :: Model -> Adapter i o            -- nativeAdapter or fallbackAdapter per capabilityFor
attachSchema  :: Value -> Options -> Options     -- TODAY: no-op (returns opts unchanged)
nativeAdapter :: Adapter i o                      -- render calls attachSchema (deriveSchema @o) _Options
fallbackAdapter :: Adapter i o                    -- render leaves _Options untouched
```

`deriveSchema @o :: Value` (from `Shikumi.Schema`) is the derived JSON Schema for the typed
output `o`. The native adapter already *computes* it and hands it to `attachSchema`; it is just
thrown away today.

### The interpose precedent (your template)

`shikumi-cache/src/Shikumi/Cache.hs` shows the exact rewrite shape you will copy:

```haskell
cachedLLM :: (Cache :> es, LLM :> es, Time :> es) => Eff es a -> Eff es a
cachedLLM = interpose $ \env -> \case
  Complete model ctx opts -> do
    ...
    resp <- complete model ctx opts     -- forward to handler beneath
    ...
  other -> passthrough env other         -- forward Stream unchanged
```

`interpose`, `passthrough`, and `send` come from `Effectful.Dispatch.Dynamic`. The router you
write has the same shape but rewrites `model`+`opts` instead of memoising.

### How hermetic tests capture the wire

Tests never hit the network. They install a stub interpreter of `LLM` that records the outgoing
request and returns a canned `Response`. The pattern is in `shikumi/test/ProgramFixtures.hs`
(`runScriptedLLM` pops canned responses; `runRecordingLLM` additionally records the system
prompt) and in `shikumi/test/StubProvider.hs`. For this plan we need to capture *the whole
`Options` (and `Model`)*, not just the system prompt, so we add a capturing interpreter that
records `(Model, Options)` per `Complete`. The canonical-request helper
`Shikumi.Cache.Key.requestToCanonicalValue :: Model -> Context -> Options -> Value` already
serialises a request (including `responseFormat`) to JSON and is a convenient assertion target,
mirroring how the trace tests inspect requests. You may assert directly on the captured
`Options` record fields instead; both are acceptable and the plan uses direct field assertions
for clarity.


## Plan of Work

The work is one keystone change split into a de-risking prototype (M0) and three additive
production milestones (M1–M3), plus an optional gated live check (M4). Each milestone is
independently verifiable with a hermetic test that fails before and passes after.

### M0 — Prototype: prove the routing mechanism end-to-end (de-risking)

**Scope.** Before touching `runProgram`, prove the chosen mechanism (approach (a): an
`interpose`-on-`LLM` router that reads request metadata and rewrites `model`+`opts`) actually
gets a derived schema onto `Options.responseFormat` and a per-sample temperature onto
`Options.temperature`, observed by a capturing stub LM, with the ambient model supplied purely
by an interpreter below a `runProgram`-shaped loop.

**What will exist at the end.** A throwaway test module (suggested path
`shikumi/test/RoutingSpikeSpec.hs`, registered in `shikumi/test/Main.hs` and
`shikumi/shikumi.cabal`'s `other-modules`) that:

1. Defines a tiny local `Routing` effect with one operation returning the ambient `Model`, and a
   local interpreter `runRoutingSpike :: Model -> Eff (Routing : es) a -> Eff es a` (a constant
   reader; in `effectful` this is `interpret (\_ CurrentModel -> pure m)`).
2. Defines a local router `routeLLMSpike :: (Routing :> es, LLM :> es) => Eff es a -> Eff es a`
   that `interpose`s on `LLM`: for each `Complete _ignoredModel ctx opts`, it reads the ambient
   model, reads two private metadata keys off `opts` (a schema `Value` and a temperature
   `Double`), removes them, and — if `capabilityFor model == NativeSchema` — sets
   `responseFormat = Just (JsonSchema {name, schema, strict = True})`; always sets the
   temperature when the metadata key is present; then forwards `complete model ctx opts'`.
3. Defines a hand-written `spikePredict` that mimics `runPredict`: it stamps the schema and a
   temperature into `Options.metadata` and calls `complete _Model ctx opts` (a *model-agnostic*
   call — the model arg is the placeholder `_Model`, which the router overwrites).
4. Installs, bottom to top: a capturing stub `LLM` (records `(Model, Options)` per call) →
   `routeLLMSpike` → `runRoutingSpike nativeModel`. Runs `spikePredict` twice (simulating two
   samples with different requested temperatures).

**Acceptance (observable).** The captured requests show: (i) the recorded `Model.modelId`
equals the routed model's id (proving the ambient model replaced `_Model`); (ii)
`Options.responseFormat` is `Just (JsonSchema {schema = s, ...})` where `s` equals
`deriveSchema @SomeOutput`; (iii) the two captured `Options.temperature` values differ and match
what `spikePredict` requested; (iv) the private metadata keys are *absent* from the captured
`Options.metadata` (the router stripped them). Re-running the same spike with a *fallback* model
(`runRoutingSpike someCustomModel`) shows `responseFormat == Nothing`. Run with:

```bash
cd /Users/shinzui/Keikaku/bokuno/shikumi
nix develop .#ghc9124 --command cabal test shikumi --test-options='-p RoutingSpike'
```

**Promotion / discard criterion.** If all four assertions hold, the mechanism is proven and M1
promotes this code into production modules (the local `Routing`/router/metadata keys become the
real `Shikumi.Routing` and the real `runPredict`). If any assertion cannot be made to hold (for
example, `interpose` cannot see the metadata, or `effectful` ordering prevents the router from
running below `runProgram`), record the failure in Surprises & Discoveries and fall back to
approach (b) — at which point you MUST follow the cross-plan protocol in
"Interfaces and Dependencies" because (b) changes integration point #4. The spike module is
deleted once M3 is green (its assertions are superseded by the production specs).

### M1 — The `Routing` effect, its interpreter, and model-agnostic `runProgram`

**Scope.** Introduce the production `Routing` effect and `runRouting` interpreter, add the
production router that rewrites outgoing `LLM` calls, and make `runProgram`/`runProgramConc`
dispatch the ambient model instead of `_Model`. The pinned integration-point-#4 signature does
not change.

**What will exist at the end.** A new module `shikumi/src/Shikumi/Routing.hs` exporting:

```haskell
data Routing :: Effect where
  CurrentModel :: Routing m Model

currentModel :: (Routing :> es) => Eff es Model

runRouting :: Model -> Eff (Routing : es) a -> Eff es a

routeLLM :: (Routing :> es, LLM :> es) => Eff es a -> Eff es a
```

`runRouting m` is a constant reader: `interpret (\_ CurrentModel -> pure m)`. `routeLLM` is the
production router (the promoted M0 spike): it `interpose`s on `LLM`, and for each `Complete
_placeholder ctx opts` it reads the ambient model via `currentModel`, translates the private
metadata into `responseFormat`/`temperature` against that model (native-capable only for the
schema), strips the private keys, and forwards `complete model ctx opts'`. `Stream` is forwarded
unchanged via `passthrough`.

`runPredict` in `shikumi/src/Shikumi/Program.hs` is rewritten to be *model-agnostic*: it no
longer references `defaultModel`/`adapterFor`/`capabilityFor`. Instead it renders with a
metadata-stamping adapter (M2 makes the stamping real; in M1 the stamp is the schema only, and
the metadata channel is established) and calls `complete _Model ctx opts` — `_Model` is now an
inert placeholder that the router *always* overwrites with the ambient model. The constant
`defaultModel = _Model` is removed from the module's logic (kept only, if at all, as the
placeholder passed to `complete`).

Because `runProgram`'s row stays `(LLM :> es, Error ShikumiError :> es)`, the new `Routing`
effect appears **only in the interpreter stack the caller assembles**, never in `runProgram`'s
constraints. A caller now writes (schematically):

```haskell
runEff
  . runErrorNoCallStack @ShikumiError
  . runLLMResilient cfg          -- or runLLMWith reg for tests
  . routeLLM                      -- rewrites outgoing LLM calls using the ambient model
  . runRouting openai_gpt_4o_mini -- supplies the ambient model
  $ runProgram program input
```

**Important ordering note.** `routeLLM` must be installed *above* the bottom `LLM` interpreter
(so the rewritten call still has an `LLM` handler beneath it to forward to) and `runRouting`
must be installed so that `Routing` is in scope where `routeLLM` runs. The plan's stack above
satisfies both: `runRouting` is innermost (closest to `runProgram`), then `routeLLM`, then the
real `LLM` interpreter. Confirm this exact order in the spike (M0) before promoting.

**Acceptance (observable).** A hermetic test (`shikumi/test/RoutingSpec.hs`) runs a single
`predict` node through a capturing stub LM with `routeLLM . runRouting nativeModel`, and asserts
the captured `Model.modelId` equals `nativeModel`'s id (today it would be `""`). Run:

```bash
cd /Users/shinzui/Keikaku/bokuno/shikumi
nix develop .#ghc9124 --command cabal test shikumi --test-options='-p Routing'
```

### M2 — Live `attachSchema`: native `responseFormat` on the wire

**Scope.** Make `attachSchema` real and route the schema all the way to `Options.responseFormat`
for native-capable models, with the fallback path unchanged.

**What will exist at the end.** Two coordinated edits:

1. In `shikumi/src/Shikumi/Adapter.hs`, the native adapter's `render` stamps the derived schema
   into the request's metadata channel instead of relying on a no-op. Concretely, `attachSchema`
   becomes a setter that writes the schema `Value` under the private metadata key
   `"shikumi.responseSchema"` on `Options.metadata` (it does **not** set `responseFormat`
   directly, because at render time we still don't know whether the *real* model is
   native-capable — the router decides). The fallback adapter does not stamp the key. (If the
   spike showed it is cleaner to set `responseFormat` directly in the native adapter and have the
   router only *clear* it for fallback models, record that and do that instead; either is
   acceptable so long as the observable outcome below holds.)

2. In `shikumi/src/Shikumi/Routing.hs`, `routeLLM` reads `"shikumi.responseSchema"`; if present
   **and** `capabilityFor model == NativeSchema`, it sets `responseFormat = Just (JsonSchema
   {name = schemaName, schema = s, strict = True})` (a stable `schemaName`, e.g. `"output"`);
   otherwise it leaves `responseFormat = Nothing`. It strips the private key either way.

**Acceptance (observable).** A hermetic test routes one `predict OutputType` node and captures
the request. For `runRouting openai_gpt_4o_mini` (native), the captured
`Options.responseFormat` is `Just (JsonSchema {schema = deriveSchema @OutputType, ...})`. For a
hand-built `Custom`-api model (fallback), the captured `Options.responseFormat` is `Nothing`.
The private metadata key never appears on the captured request in either case. The same test on
the pre-M2 code fails (no `responseFormat` ever appears). Run:

```bash
cd /Users/shinzui/Keikaku/bokuno/shikumi
nix develop .#ghc9124 --command cabal test shikumi --test-options='-p Routing'
```

### M3 — Per-sample temperature from `MajorityVote`'s `TempSchedule`

**Scope.** Make `MajorityVote`'s `TempSchedule` actually set `Options.temperature` per sample on
the wire, in both `runProgram` and `runProgramConc`.

**What will exist at the end.** `runProgram`/`runProgramConc`'s `MajorityVote k schedule p`
clauses no longer ignore `schedule`. They compute the `k` temperatures from the schedule
(`TempFixed xs` cycles `xs` to length `k`; `TempSpread base spread` fans `k` values centred on
`base` by `spread`), and run the *i*-th sample with the *i*-th temperature threaded down to its
`Predict` nodes. The threading uses the same metadata channel: the run-of-one-sample stamps the
requested temperature under the private metadata key `"shikumi.temperature"` on `Options`, and
`routeLLM` reads it and sets `Options.temperature` (then strips the key). A sample with no
schedule entry leaves `temperature` at its default (`Nothing`).

The cleanest way to thread "this sample's temperature" without widening any signature is a small
reader-like effect, or — simpler and consistent with the metadata approach — a helper that runs
the inner program with an `interpose` that stamps the temperature onto every outgoing `Complete`
for that sample only. Decide in implementation; the observable outcome is what matters. Both
`MajorityVote` clauses (sequential and concurrent) must produce the same set of temperatures
across the `k` samples (order need not match for the concurrent path, but the *multiset* must).

**Acceptance (observable).** A hermetic test runs `majorityVote 3 (TempSpread 0.5 0.4)
(predict ...)` through a capturing stub LM with `routeLLM . runRouting nativeModel`, captures all
three requests, and asserts the three `Options.temperature` values are the three schedule
temperatures (as a set), and that they are not all equal. The same test with `TempFixed [0.1,
0.9]` and `k = 2` shows exactly `[0.1, 0.9]`. On pre-M3 code every captured temperature is
`Nothing`, so the test fails. A second assertion runs the same through `runProgramConc` (adding
`runConcurrent` to the stack) and checks the same multiset. Run:

```bash
cd /Users/shinzui/Keikaku/bokuno/shikumi
nix develop .#ghc9124 --command cabal test shikumi --test-options='-p Routing'
```

### M4 — Optional, gated: live provider verification

**Scope.** Prove the wired path works against a real provider, gated on an API key so the default
test run stays hermetic.

**What will exist at the end.** A `SHIKUMI_LIVE`-gated test case (extend `shikumi/test/LiveSpec.hs`
or add `RoutingLiveSpec`) that, when `SHIKUMI_LIVE=1` and `OPENAI_API_KEY` are set, registers the
OpenAI provider, runs a `predict` node through `runProgram` with `routeLLM . runRouting
openai_gpt_4o_mini` over `runLLMResilient`, and asserts a schema-conforming typed output decodes.
Without the variable it prints a skip line and stays green, exactly like the existing `LiveSpec`.

**Acceptance.** With credentials, the live case returns a decoded typed value (proving the real
provider honoured the transmitted schema). Without credentials, the suite stays green and prints
a skip line. This milestone is explicitly optional; the hermetic stub path (M0–M3) is the
exercised one.


## Concrete Steps

All commands run from the repository root and inside the project's Nix dev shell, which provides
the correct toolchain (GHC 9.12.4; the system GHC is the wrong version and must not be used).

Build and test the touched package:

```bash
cd /Users/shinzui/Keikaku/bokuno/shikumi
nix develop .#ghc9124 --command cabal build shikumi
nix develop .#ghc9124 --command cabal test shikumi
```

Run the whole fleet before committing:

```bash
cd /Users/shinzui/Keikaku/bokuno/shikumi
nix develop .#ghc9124 --command cabal test all
```

Run only this plan's specs by tasty pattern:

```bash
cd /Users/shinzui/Keikaku/bokuno/shikumi
nix develop .#ghc9124 --command cabal test shikumi --test-options='-p Routing'
```

The optional live check:

```bash
cd /Users/shinzui/Keikaku/bokuno/shikumi
SHIKUMI_LIVE=1 OPENAI_API_KEY=sk-... \
  nix develop .#ghc9124 --command cabal test shikumi --test-options='-p Live'
```

Formatting: the repo uses `fourmolu` (2-space indentation) enforced via a pre-commit hook. After
editing, run it (or let pre-commit run on commit):

```bash
cd /Users/shinzui/Keikaku/bokuno/shikumi
nix develop .#ghc9124 --command fourmolu --mode inplace \
  shikumi/src/Shikumi/Routing.hs shikumi/src/Shikumi/Program.hs shikumi/src/Shikumi/Adapter.hs
```

Expected transcript shape for a passing run (abbreviated):

```text
shikumi> Test suite shikumi-test: RUNNING...
Routing
  routes the ambient model id onto the wire:                OK
  native model attaches responseFormat with derived schema: OK
  fallback model leaves responseFormat unset:               OK
  majorityVote spread sets distinct per-sample temperatures: OK
All N tests passed
```

Commits must carry the master-plan/exec-plan/intention trailers, for example:

```text
feat(shikumi): ambient Routing effect + live native responseFormat (EP-14 M1–M2)

MasterPlan: docs/masterplans/2-shikumi-substrate-routing-completion.md
ExecPlan: docs/plans/14-ambient-model-routing-and-live-native-structured-output.md
Intention: intention_01ktq80610e6nbe3d7yrct59an
```


## Validation and Acceptance

The plan is accepted when, with no network and no API key, `nix develop .#ghc9124 --command
cabal test shikumi --test-options='-p Routing'` passes and demonstrates all of:

1. **Model routing.** A `predict` node run with `routeLLM . runRouting M` produces a captured
   request whose `Model.modelId` equals `M`'s id (not `""`). This proves the ambient model
   replaced the hardcoded `_Model` without changing `runProgram`'s pinned signature — confirm by
   grepping that `runProgram`'s declared type in `shikumi/src/Shikumi/Program.hs` is still
   `(LLM :> es, Error ShikumiError :> es) => Program i o -> i -> Eff es o`.

2. **Native schema on the wire.** For a native model the captured `Options.responseFormat` is
   `Just (JsonSchema {schema = deriveSchema @o, ...})`; for a fallback model it is `Nothing`. The
   private metadata key is absent from the captured request in both cases.

3. **Per-sample temperature on the wire.** Under `majorityVote k schedule`, the captured
   temperatures across the `k` requests equal the schedule's temperatures (as a multiset) and are
   not all identical, in both `runProgram` and `runProgramConc`.

Each acceptance is phrased as captured-request behaviour and each corresponding test fails on the
current code (no `responseFormat`, `modelId == ""`, identical temperatures) and passes after the
milestone. The whole fleet (`cabal test all`) must remain green, proving no consumer's pinned row
broke.

The optional M4 live check, when credentials are supplied, additionally proves a real provider
honoured the transmitted schema by returning a value that decodes into the typed output.


## Idempotence and Recovery

All edits are additive and re-runnable. Creating `Shikumi.Routing` is additive; the
`runProgram`/`Adapter` edits replace a no-op (`attachSchema`) and a discarded argument
(`_sched`) with real behaviour and can be re-applied cleanly. If a build breaks mid-milestone,
revert the single touched file and rebuild; nothing here performs destructive or stateful
operations (no migrations, no file writes outside the test tree). The M0 spike is a throwaway
test module: if promotion fails, delete it without consequence. Re-running any `cabal test`
command is safe and side-effect-free (the default path is hermetic; only the explicitly gated
`SHIKUMI_LIVE` path touches the network).

If you must fall back to approach (b) (a `Routing`/`Reader Model` constraint inside
`runProgram`), the recovery path is: stop, follow the cross-plan protocol in the next section,
update the master plan, and only then change the signature.


## Interfaces and Dependencies

**Libraries/modules used and why.** `effectful` (`Effectful`, `Effectful.Dispatch.Dynamic`'s
`interpose`/`interpret`/`passthrough`/`send`) — to add the `Routing` effect and the
re-interpreting router on the existing `LLM` effect, the same machinery
`shikumi-cache`/`shikumi-trace` already use. `baikai` (`Baikai.Model`, `Baikai.Options`,
`Baikai.ResponseFormat`, `Baikai.Models.Generated`) — the `Model`/`Options`/`ResponseFormat`
records and the named-model catalog. `shikumi`'s own `Shikumi.LLM` (`LLM`, `complete`),
`Shikumi.Adapter` (`capabilityFor`, `adapterFor`, `attachSchema`, `nativeAdapter`,
`fallbackAdapter`), and `Shikumi.Schema` (`deriveSchema`).

**The private metadata channel (exact shapes).** Two reserved keys on `Options.metadata :: Map
Text Value`:

- `"shikumi.responseSchema" :: Value` — the derived JSON Schema, set by the native adapter's
  `render`/`attachSchema`, consumed and stripped by `routeLLM`. When present and the ambient
  model is `NativeSchema`, the router sets `responseFormat = Just (JsonSchema {name = "output",
  schema = <that value>, strict = True})`.
- `"shikumi.temperature" :: Value` (a JSON number) — the per-sample temperature requested by a
  `MajorityVote` sample, consumed and stripped by `routeLLM`, which sets
  `Options.temperature = Just <that double>`.

The router always removes both keys before forwarding, so nothing private reaches the transport.
These names are internal and must be defined once (suggest constants in `Shikumi.Routing`).

**Signatures that must exist at the end of each milestone.**

- End of **M1** (`shikumi/src/Shikumi/Routing.hs`):
  ```haskell
  data Routing :: Effect where
    CurrentModel :: Routing m Model
  currentModel :: (Routing :> es) => Eff es Model
  runRouting   :: Model -> Eff (Routing : es) a -> Eff es a
  routeLLM     :: (Routing :> es, LLM :> es) => Eff es a -> Eff es a
  ```
  and unchanged in `shikumi/src/Shikumi/Program.hs`:
  ```haskell
  runProgram     :: (LLM :> es, Error ShikumiError :> es) => Program i o -> i -> Eff es o
  runProgramConc :: (LLM :> es, Error ShikumiError :> es, Concurrent :> es) => Program i o -> i -> Eff es o
  ```
- End of **M2** (`shikumi/src/Shikumi/Adapter.hs`):
  ```haskell
  attachSchema :: Value -> Options -> Options   -- now a real setter onto Options.metadata (no longer a no-op)
  ```
  with `nativeAdapter` stamping `deriveSchema @o` and `fallbackAdapter` not stamping.
- End of **M3** (`shikumi/src/Shikumi/Program.hs`): the `MajorityVote` clauses consume the
  `TempSchedule` and thread per-sample temperatures via the metadata channel; helper signatures
  are implementation-private but the observable wire behaviour is fixed by Validation point 3.

**Cross-plan dependency note.** This plan depends on **no other ExecPlan** (it is the keystone,
EP-14, with no hard or soft deps per the master plan's registry). It *defines* two integration
points the master plan lists: integration point #1 (the ambient `Routing` effect + `runRouting`)
and integration point #2 (live `attachSchema` / native adapter). The chosen mechanism — approach
(a) — **preserves integration point #4's pinned `runProgram` signature exactly**, so no
cross-plan change is needed and MasterPlans 3 and 4 (which inherit #4) require no notification.

**If, and only if, approach (b) is forced** (the M0 spike fails to prove approach (a)): adding a
`Routing`/`Reader Model` constraint to `runProgram`'s row *changes integration point #4*. In that
event you must, before merging: (1) record the reason in this plan's Decision Log and Surprises &
Discoveries with the spike evidence; (2) update the master plan
`docs/masterplans/2-shikumi-substrate-routing-completion.md` — its Decision Log (the entry that
pins #4 via an interpreter) and its Surprises & Discoveries — to reflect the changed contract;
and (3) flag that MasterPlans 3 and 4 (referenced by path:
`docs/masterplans/3-shikumi-dspy-parity-optimizers-and-self-refinement.md` and
`docs/masterplans/4-shikumi-richer-io-and-multimodal.md`) inherit #4 and must update every
`runProgram`/`runCompiled`/tool-body call site to supply the new constraint. Approach (a) is
strongly recommended precisely to avoid this blast radius.
