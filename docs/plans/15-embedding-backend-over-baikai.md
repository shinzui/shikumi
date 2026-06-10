---
id: 15
slug: embedding-backend-over-baikai
title: "Embedding backend over baikai"
kind: exec-plan
created_at: 2026-06-09T22:35:41Z
intention: "intention_01ktq80610e6nbe3d7yrct59an"
master_plan: "docs/masterplans/2-shikumi-substrate-routing-completion.md"
---

# Embedding backend over baikai

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Shikumi is a typed framework for programming language models in Haskell. It lives at
`/Users/shinzui/Keikaku/bokuno/shikumi`. One of its evaluation building blocks is a
metric called **semantic similarity**: given an expected answer and a model's predicted
answer, it scores how *meaning-close* they are by turning each into a numeric vector (an
"embedding") and measuring the angle between the two vectors. That metric already exists
in source — `semanticSimilarity` in
`/Users/shinzui/Keikaku/bokuno/shikumi/shikumi-eval/src/Shikumi/Eval/Metric.hs` — but it
is **inert**: it is written against a small effect named `Embedding` whose only shipped
interpreter, `runEmbedding`, takes a *pure* `Text -> Vector Double` function. There is no
backend that calls a real embedding model, so today the only way to run the metric is to
hand it a hard-coded lookup table in a test. Embedding is the word for the dense numeric
vector a model produces for a piece of text; an "embedding model" is a model whose job is
to produce those vectors (for example OpenAI's `text-embedding-3-small`, which returns a
1536-number vector per input string).

After this change a Shikumi user can supply a **real embeddings backend** — an
OpenAI-compatible HTTP endpoint at the path `/v1/embeddings` — and have
`semanticSimilarity` produce genuine semantic scores end to end. Concretely: two
semantically-close strings ("a cat sat on the mat" vs. "the cat is on the rug") will
score *higher* than two distant strings ("a cat sat on the mat" vs. "quarterly revenue
rose"), because the backend returns vectors whose geometry reflects meaning. This unblocks
similarity-based demonstration selection (k-nearest-neighbour few-shot) and
retrieval-augmented generation in the downstream optimizer initiative
(`/Users/shinzui/Keikaku/bokuno/shikumi/docs/masterplans/3-shikumi-dspy-parity-optimizers-and-self-refinement.md`),
which is the consumer named in integration point #5 of this plan's parent master plan
(`/Users/shinzui/Keikaku/bokuno/shikumi/docs/masterplans/2-shikumi-substrate-routing-completion.md`).

The work has a **cross-repository** shape that mirrors how Shikumi V1 grew its
`baikai-effectful` binding: the transport library Shikumi sits on, **baikai** (a separate
Haskell repo at `/Users/shinzui/Keikaku/bokuno/baikai`), ships **no embeddings client at
all** today. We verified this directly: searching every baikai package source tree for any
`embed` / `embedding` symbol turns up only incidental prose in comments (the word
"embedded" describing how `Cost` is stored inside a message), never a function, type, or
module. So this plan first contributes a small **upstream** embeddings client to the
baikai repo, then builds a Shikumi interpreter on top of it.

You will see it working two ways. First, a **hermetic** (no-network) test: an isolated
deterministic stub backend returns fixed vectors for two close strings and two distant
strings, and the test asserts the close pair outscores the distant pair. This test
**fails before** this plan (there is no interpreter to wire a backend into the
`semanticSimilarity` path beyond the pure table, and no batching transport to exercise) and
**passes after**. Second, a **gated live** test, skipped by default and switched on only
when an API key and an opt-in environment variable are present, calls a real OpenAI
embeddings endpoint and asserts the returned vector has the model's expected
dimensionality (1536 for `text-embedding-3-small`).


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1: Upstream baikai embeddings client — new module `Baikai.Embedding` in package
      `baikai` exposing `embed`/`embedOne` + the pure `mkEmbeddingRequest`, plus the
      `EmbeddingModel` selection record and `openAIEmbeddingModel`; OpenAI `/v1/embeddings`
      mapping through the vendored `openai` SDK (`getClientEnv`/`makeMethods`/`createEmbeddings`),
      reusing `Baikai.Auth`. `openai` added to core baikai's library deps.
- [x] M1: Upstream baikai embeddings tests pass in the baikai repo (`cabal test baikai`, 43
      cases): the request-mapping unit test (`mkEmbeddingRequest` puts input/model/dimensions on
      the wire) is green and the gated `BAIKAI_EMBEDDING_LIVE` test skips cleanly. Committed in the
      baikai repo.
- [x] M2: Shikumi interpreter `Shikumi.Eval.Embedding` — `runEmbeddingWith` (explicit
      `EmbeddingModel`), `runEmbeddingLLM` (defaulted to `text-embedding-3-small`), and
      `runEmbeddingBy` (injected batching embedder) driving the baikai client; transport failures
      become typed `ProviderFailure`. `baikai` added to `shikumi-eval`'s library deps.
- [x] M3: Hermetic stub-backed test in `shikumi-eval` (`EmbeddingSpec`) proves close > distant
      under `semanticSimilarity` routed through the real `runEmbeddingBy` interpreter; gated
      `SHIKUMI_EMBEDDING_LIVE` test asserts a 1536-length vector. `cabal test shikumi-eval` green
      (38 cases).
- [x] Master-plan registry row for EP-15 flipped to Complete and the two EP-15 progress bullets
      checked off.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- The upstream `openai` Haskell package (Mercury's `MercuryTechnologies/openai`, vendored
  in the fleet at `/Users/shinzui/Keikaku/hub/haskell/openai-project`) already exposes an
  embeddings client. In `openai/src/OpenAI/V1/Embeddings.hs` it defines
  `CreateEmbeddings { input :: Text, model :: Model, encoding_format :: Maybe EncodingFormat, dimensions :: Maybe Natural, user :: Maybe Text }`
  and `EmbeddingObject { index :: Natural, embedding :: Vector Double, object :: Text }`,
  and `OpenAI.V1.Methods` carries
  `createEmbeddings :: CreateEmbeddings -> IO (Vector EmbeddingObject)` right alongside the
  `createChatCompletion` field baikai's OpenAI provider already uses. **Consequence:** the
  upstream baikai client does *not* need to hand-roll an HTTP request; it reuses the same
  `OpenAI.getClientEnv` + `OpenAI.makeMethods` path the existing
  `baikai-openai`/`Baikai.Provider.OpenAI.Api` module uses, so M1 is a thin mapping, not a
  from-scratch HTTP client.
- Note one wrinkle from that SDK: `CreateEmbeddings.input` is a single `Text`, not a list —
  the SDK models one input string per request even though the OpenAI wire API accepts an
  array. This shapes the M1 API: `embed` over a list of texts loops/sequences per-input
  calls rather than issuing one batched request. Documented in the Decision Log.

- The vendored `openai` SDK's `OpenAI.V1.Models.Model` is a `newtype Model { text :: Text }` that
  derives `FromJSON`/`IsString`/`Show`/`ToJSON` but **not `Eq`**. So the M1 request-mapping unit
  test cannot compare the request's `model` field with `==`; it asserts on the unwrapped
  `OpenAIModels.text (Emb.model req)` instead.
- Confirmed the core-baikai placement works: adding `openai` to core `baikai`'s library
  `build-depends` resolves cleanly (it is already a dep of `baikai-openai`), and `shikumi-eval`
  reaches `Baikai.Embedding` through its existing `baikai` dependency — no `cabal.project` change
  and no relocation to `baikai-openai` was needed.


## Decision Log

Record every decision made while working on the plan.

- Decision: Place the new embeddings client in the **core `baikai` package** as a new
  module `Baikai.Embedding`, not in `baikai-openai` and not in a new package.
  Rationale: it is a small, provider-neutral surface (a request/response record pair plus an
  `embed` function selecting an endpoint by config), and the master plan's integration point
  #5 explicitly calls for "a new (small) upstream baikai embeddings client." Keeping it in
  the core package means the Shikumi interpreter depends only on `baikai`, which `cabal.project`
  already wires by local path, with no new package to register. The actual HTTP call is made
  through the `openai` SDK's `Methods.createEmbeddings`, so `Baikai.Embedding` declares an
  `openai` build-dep — the same dependency `baikai-openai` already uses. (If a reviewer
  prefers strict layering — core baikai with zero provider SDK deps — the fallback is to put
  the module in `baikai-openai` instead; see "Plan of Work" for how to relocate. The core
  placement is chosen because it keeps the Shikumi dependency graph minimal and there is no
  policy in the module.)
  Date: 2026-06-09.
- Decision: Do **not** add an embeddings operation to baikai's existing `Baikai` effect in
  `baikai-effectful`, and do **not** add a separate effect there.
  Rationale: Shikumi already owns an `Embedding` effect (`Shikumi.Eval.Metric.Embedding`,
  the integration-point-#5 contract) and the only Shikumi consumer is the
  `semanticSimilarity` metric. Adding a parallel embeddings op to the baikai `Baikai` effect
  would create two competing embedding effects with no consumer for the baikai one. The
  upstream contribution is therefore a **plain IO client** (`Baikai.Embedding.embed :: ... ->
  IO (Vector (Vector Double))`), policy-free, with `IOE` introduced only at the very bottom
  inside Shikumi's interpreter — exactly the layering baikai-effectful uses (transport in
  baikai, effect binding in shikumi). Keeping the baikai side effect-free also means the
  client is usable from any baikai consumer, not just `effectful` ones.
  Date: 2026-06-09.
- Decision: Model embedding-model selection with a small `EmbeddingModel` record carrying
  the model id, base URL, optional dimensions, and api-key source, rather than reusing
  baikai's chat `Model` record.
  Rationale: baikai's `Model` (`Baikai.Model.Model`) is a chat-completion record keyed on an
  `Api` tag (`OpenAIChatCompletions`, `AnthropicMessages`, …) and a catalog of generated
  chat models; none of those tags name an embeddings endpoint, and most `Model` fields
  (`contextWindow`, `maxOutputTokens`, `reasoning`, `input` modalities, chat `cost` rates,
  `compat` shims) are meaningless for embeddings. Forcing embeddings through `Model` would
  either require a new `Api` tag and a catalog entry for every embedding model, or a `Custom`
  api with mostly-empty fields. A purpose-built `EmbeddingModel` record is smaller, honest
  about what an embeddings call needs, and avoids polluting the chat catalog. The
  model-naming convention is therefore: an embedding model is named by its bare provider
  model id string (e.g. `"text-embedding-3-small"`) plus a base URL, with no catalog/`Api`
  registration required. A convenience smart constructor `openAIEmbeddingModel ::
  Text -> EmbeddingModel` defaults the base URL to `https://api.openai.com` and the key to
  the `OPENAI_API_KEY` environment variable.
  Date: 2026-06-09.
- Decision: `embed` takes a list of texts and returns one vector per text (`[Text] -> IO
  (Vector (Vector Double))`), looping the SDK's single-input call per text.
  Rationale: the vendored `openai` SDK's `CreateEmbeddings.input` is a single `Text` (one
  input per request). Sequencing per-input calls keeps the client correct against the SDK we
  have; batching can be added later behind the same signature if the SDK gains array input.
  The Shikumi interpreter only ever embeds one string per `EmbedText`, so the per-call loop
  is not on a hot path.
  Date: 2026-06-09.
- Decision: Name the Shikumi interpreter `runEmbeddingWith` (explicit `EmbeddingModel`
  argument) with a convenience `runEmbeddingLLM` that defaults to OpenAI
  `text-embedding-3-small`.
  Rationale: matches the master plan's integration-point-#5 naming hint
  (`runEmbeddingLLM`/`runEmbeddingWith`) and mirrors baikai-effectful's `runBaikai` /
  `runBaikaiWith` pairing (a defaulted convenience plus an explicit-config variant).
  Date: 2026-06-09.

(Add further decisions as they are made.)


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

EP-15 delivered across both repos. baikai gained its first embeddings client (`Baikai.Embedding`,
core package), a thin policy-free wrapper over the vendored `openai` SDK's `createEmbeddings`,
selecting a model by a bare id string + base URL in `EmbeddingModel` (no `Api` tag, no chat
catalog). shikumi gained `Shikumi.Eval.Embedding` with `runEmbeddingWith`/`runEmbeddingLLM` and the
test-seam `runEmbeddingBy`, so the previously-inert `semanticSimilarity` now produces
meaning-sensitive scores from a real backend — demonstrated hermetically (close pair strictly
outscores a distant pair through the real interpreter over a deterministic stub) and behind a gated
live check (1536-d vector from `text-embedding-3-small`). The `Embedding` effect contract
(integration point #5) is unchanged; only interpreters were added. No gaps; the one deviation from
the plan was confirming up front that `OpenAI.V1.Models.Model` has no `Eq` instance, so the unit
test compares the unwrapped `text` field rather than the `Model` value. The whole shikumi fleet
stays green and baikai's suite is green.


## Context and Orientation

This section assumes no prior knowledge of either repository. Read it fully before editing.

**Two repositories, built together.** Shikumi (`/Users/shinzui/Keikaku/bokuno/shikumi`)
is the framework under change. It depends, by **local filesystem path**, on four sibling
Haskell packages that live in the baikai repository
(`/Users/shinzui/Keikaku/bokuno/baikai`): `baikai` (the core transport), `baikai-openai`
and `baikai-claude` (provider plug-ins), and `baikai-effectful` (a thin `effectful` binding
over baikai's transport). These local-path wirings are declared in
`/Users/shinzui/Keikaku/bokuno/shikumi/cabal.project`; the relevant lines read:

```text
  /Users/shinzui/Keikaku/bokuno/baikai/baikai
  /Users/shinzui/Keikaku/bokuno/baikai/baikai-claude
  /Users/shinzui/Keikaku/bokuno/baikai/baikai-openai
  /Users/shinzui/Keikaku/bokuno/baikai/baikai-effectful
```

Because of this, a change to the baikai source on disk is picked up by a Shikumi rebuild
with no publish step. That is what makes the cross-repo M1→M2 flow in this plan work: you
edit baikai, then build Shikumi against it.

**Build environment.** Both repos build with GHC 9.12.4, supplied by a Nix dev shell. In
Shikumi, enter it with `nix develop .#ghc9124` from the Shikumi repo root; that shell puts
the correct `cabal` and `ghc` on `PATH` (the system `ghc` is 9.10.3 and is the **wrong**
compiler — do not use it). In baikai, the dev shell is entered with `nix develop` from the
baikai repo root. Source formatting is enforced by `fourmolu` (2-space indentation) via a
pre-commit hook in each repo; run it before committing or the hook will reformat.

**The effect you are interpreting.** Shikumi is built on the `effectful` library, in which
a *capability* is declared as an "effect" (a small GADT of operations) and *interpreted* by
a function that says how each operation actually runs. The capability this plan targets is
`Embedding`, declared in
`/Users/shinzui/Keikaku/bokuno/shikumi/shikumi-eval/src/Shikumi/Eval/Metric.hs`. Its full
current definition (copied verbatim so you need not open the file to follow along):

```haskell
data Embedding :: Effect where
  EmbedText :: Text -> Embedding m (Vector Double)

type instance DispatchOf Embedding = 'Dynamic

embedText :: (Embedding :> es) => Text -> Eff es (Vector Double)
embedText t = send (EmbedText t)

runEmbedding :: (Text -> Vector Double) -> Eff (Embedding : es) a -> Eff es a
runEmbedding f = interpret $ \_ -> \case
  EmbedText t -> pure (f t)
```

In plain terms: `EmbedText` is the single operation — "turn this `Text` into a `Vector
Double`". `embedText` is the helper a metric calls. `runEmbedding` is the only shipped
interpreter, and it is **pure**: you give it a function from text to vector and it never
touches the network. This plan adds a *second* interpreter that calls a real backend.

`Vector Double` here is `Data.Vector.Vector Double` from the `vector` package — a flat,
boxed array of `Double`s. The embedding for one string is one such vector (length 1536 for
`text-embedding-3-small`).

**The metric that consumes it.** Same file, also verbatim:

```haskell
semanticSimilarity :: (Embedding :> es) => (o -> Text) -> MetricM es o
semanticSimilarity proj expd predd = do
  a <- embedText (proj expd)
  b <- embedText (proj (predictionPrimary predd))
  pure (cosineScore a b)
```

`semanticSimilarity proj` takes a projection `proj :: o -> Text` saying which text field of
the typed output to compare. It embeds the expected and predicted text, then scores their
**cosine similarity** — the cosine of the angle between the two vectors. `cosineScore`
(also in that file) maps cosine from its natural range `[-1, 1]` into `[0, 1]`, and returns
`scoreZero` if either vector has zero length (a degenerate "no signal" case). Identical
direction → score 1; orthogonal → 0.5; opposite → 0. **Nothing about this metric changes in
this plan.** We only give it a real interpreter to run under.

**Why it is inert today.** The only interpreter is the pure `runEmbedding`. To run
`semanticSimilarity` against a real model you must supply an interpreter whose `EmbedText`
calls an embeddings endpoint — and none exists, in Shikumi or in baikai. That is the gap.

**The baikai transport you will extend.** baikai's core package
(`/Users/shinzui/Keikaku/bokuno/baikai/baikai`) holds the request/response vocabulary and
the provider registry. Its auth helper, `Baikai.Auth`
(`/Users/shinzui/Keikaku/bokuno/baikai/baikai/src/Baikai/Auth.hs`), defines:

```haskell
data ApiKeySource
  = ApiKeyLiteral !Text
  | ApiKeyEnv !String

resolveApiKey :: (MonadIO m) => ApiKeySource -> m Text
```

`ApiKeyLiteral` carries a token directly (handy for tests); `ApiKeyEnv "OPENAI_API_KEY"`
defers to an environment variable, read lazily by `resolveApiKey` (which throws baikai's
`ProviderError` if the variable is unset). The new embeddings client reuses this exactly —
no new auth code.

The existing OpenAI **chat** provider,
`/Users/shinzui/Keikaku/bokuno/baikai/baikai-openai/src/Baikai/Provider/OpenAI/Api.hs`,
shows the pattern for calling the `openai` SDK. Its `prepareCall` builds an SDK client
environment and method table like this (excerpted):

```haskell
key <- resolveKey opts                    -- Auth.resolveApiKey
env <- OpenAI.getClientEnv url            -- url defaults to https://api.openai.com
let mtds = OpenAI.makeMethods env key Nothing Nothing
```

and then uses `mtds`'s `createChatCompletionStream` field. The embeddings client uses the
**same** two calls (`getClientEnv`, `makeMethods`) and the *sibling* method field
`createEmbeddings`.

**The upstream SDK's embeddings surface.** The `openai` Haskell package (vendored at
`/Users/shinzui/Keikaku/hub/haskell/openai-project`, the same package `baikai-openai`
already depends on) exposes, in `openai/src/OpenAI/V1/Embeddings.hs`:

```haskell
data CreateEmbeddings = CreateEmbeddings
  { input :: Text
  , model :: Model               -- OpenAI.V1.Models.Model, a newtype over Text
  , encoding_format :: Maybe EncodingFormat
  , dimensions :: Maybe Natural
  , user :: Maybe Text
  }

_CreateEmbeddings :: CreateEmbeddings   -- defaults the optional fields to Nothing

data EmbeddingObject = EmbbeddingObject
  { index :: Natural
  , embedding :: Vector Double
  , object :: Text
  }
```

and in `openai/src/OpenAI/V1.hs` the method-table field:

```haskell
createEmbeddings :: CreateEmbeddings -> IO (Vector EmbeddingObject)
```

So one `createEmbeddings` call sends one input string and returns a `Vector` of
`EmbeddingObject` (length 1 for a single input); the vector you want is the `embedding`
field of its single element. `OpenAI.V1.Models.Model` is a newtype wrapping `Text`, so an
embedding model id like `"text-embedding-3-small"` is wrapped as `OpenAIModels.Model
"text-embedding-3-small"` (this is the same `OpenAIModels` import the chat provider uses).

**Confirmation that baikai ships nothing for this.** A full-source search of the baikai
packages for `embed`/`embedding` finds only comment prose ("…embeds 'Cost' in-place…"),
never a definition. There is no embeddings module, function, or type anywhere in
`baikai*/src`. This plan introduces the first one.

**Where the model-naming convention lands.** baikai's chat models come from a generated
catalog (`Baikai.Models.Generated`, e.g. `openai_gpt_4o_mini` used in baikai-effectful's
`LiveSpec`) keyed by `Api` tag. Embedding models are deliberately kept **out** of that
catalog (see Decision Log): an embedding model is named by its plain provider id string and
a base URL inside the new `EmbeddingModel` record, with no `Api` tag or catalog entry. This
is the convention the master plan asks this plan to document.


## Plan of Work

The work is three milestones. M1 is entirely in the baikai repo (the upstream client and
its tests). M2 and M3 are in the Shikumi repo (the interpreter and the end-to-end tests).
M1 must land first because M2 builds against it; M2 before M3 because the tests exercise the
interpreter. Each milestone is independently verifiable with its own commands and acceptance.


### Milestone M1 — Upstream baikai embeddings client

**Scope.** Add a new module `Baikai.Embedding` to the core `baikai` package providing a
provider-neutral, policy-free embeddings client that calls an OpenAI-compatible
`/v1/embeddings` endpoint through the `openai` SDK, plus the `EmbeddingModel` selection
record and a tiny request-mapping unit test and a gated live test. At the end of M1 the
baikai repo builds and tests green, and a developer can call, from a `ghci` or a test,
`embed (openAIEmbeddingModel "text-embedding-3-small") ["hello"]` and (with a key) get back
a 1536-long vector.

**Files to create or edit (all under `/Users/shinzui/Keikaku/bokuno/baikai`):**

1. **New module** `baikai/src/Baikai/Embedding.hs`. Define the selection record and the
   client. The intended public surface (the contract M2 builds against):

   ```haskell
   module Baikai.Embedding
     ( EmbeddingModel (..)
     , _EmbeddingModel
     , openAIEmbeddingModel
     , embed
     , embedOne
     ) where

   data EmbeddingModel = EmbeddingModel
     { modelId    :: !Text                 -- e.g. "text-embedding-3-small"
     , baseUrl    :: !Text                 -- e.g. "https://api.openai.com"
     , dimensions :: !(Maybe Natural)      -- request a reduced dimensionality, or Nothing for the model default
     , apiKey     :: !ApiKeySource         -- from Baikai.Auth
     }

   -- | Blank base; record-update target for hand-built models.
   _EmbeddingModel :: EmbeddingModel

   -- | OpenAI default: api.openai.com, key from OPENAI_API_KEY, model-default dims.
   openAIEmbeddingModel :: Text -> EmbeddingModel

   -- | Embed a batch of texts: one vector per input text, in input order.
   embed :: EmbeddingModel -> [Text] -> IO (Vector (Vector Double))

   -- | Embed a single text (convenience).
   embedOne :: EmbeddingModel -> Text -> IO (Vector Double)
   ```

   Implementation notes, in prose so a novice can write it:

   - Import the SDK as the chat provider does:
     `import qualified OpenAI.V1 as OpenAI`,
     `import qualified OpenAI.V1.Embeddings as Emb`,
     `import qualified OpenAI.V1.Models as OpenAIModels`. Import
     `Baikai.Auth (ApiKeySource (..), resolveApiKey)`.
   - `openAIEmbeddingModel mid = _EmbeddingModel { modelId = mid, baseUrl =
     "https://api.openai.com", dimensions = Nothing, apiKey = ApiKeyEnv "OPENAI_API_KEY" }`.
     `_EmbeddingModel` itself can use an empty `modelId`/`baseUrl` and `ApiKeyEnv
     "OPENAI_API_KEY"` as a safe default.
   - `embedOne m t = V.head <$> embed m [t]` — but guard the empty case so an empty input
     list to `embed` returns an empty vector and `embedOne` is only ever called on a
     single-element batch (it always is).
   - `embed m texts`: resolve the key once with `key <- resolveApiKey (apiKey m)`; build the
     client env with `env <- OpenAI.getClientEnv (urlOf m)` where `urlOf` substitutes the
     OpenAI default for an empty `baseUrl` exactly as the chat provider's `prepareCall` does
     (`"" -> "https://api.openai.com"; u -> u`); build the method table
     `let OpenAI.Methods { OpenAI.createEmbeddings = create } = OpenAI.makeMethods env key
     Nothing Nothing`. Then, for each input text, issue one call:

     ```haskell
     objs <- create Emb._CreateEmbeddings
                       { Emb.input = t
                       , Emb.model = OpenAIModels.Model (modelId m)
                       , Emb.dimensions = dimensions m
                       }
     ```

     `objs :: Vector Emb.EmbeddingObject`; take `Emb.embedding (V.head objs)` as that text's
     vector (one input ⇒ one object). Collect the per-text vectors into a
     `Vector (Vector Double)` preserving input order (`V.fromList <$> traverse one texts`).
   - The call throws on transport failure (the SDK throws a Servant client exception, which
     baikai's chat path also lets propagate); M1 lets it propagate — error remapping is the
     Shikumi layer's job (M2). This keeps the client policy-free, matching baikai-effectful's
     stance.

2. **Edit** `baikai/baikai.cabal`. Add `Baikai.Embedding` to the library's `exposed-modules`
   and add `openai` and `vector` to the library `build-depends` if not already present. (The
   `openai` dep is new to the *core* `baikai` package — it is already a dep of
   `baikai-openai`, so the same package resolves; `vector` is already used across baikai.)
   Run `nix develop` then `cabal build baikai` to confirm the new dep resolves.

   *Layering fallback (only if a reviewer objects to `openai` in core baikai):* move
   `Baikai/Embedding.hs` into `baikai-openai/src/Baikai/Provider/OpenAI/Embedding.hs`, add it
   to `baikai-openai`'s `exposed-modules`, and have the Shikumi interpreter depend on
   `baikai-openai` (already wired in `cabal.project`) instead of `baikai`. The module body is
   identical; only the package and module name change. The default plan keeps it in core
   baikai for a minimal Shikumi dependency graph (see Decision Log).

3. **New test** `baikai/test/...` (place it in baikai's existing test suite; inspect
   `baikai/baikai.cabal` for the `test-suite` stanza and its `hs-source-dirs`/`other-modules`
   and add a module there). Two tests:

   - A **hermetic request-mapping unit test** that does not hit the network. Since the SDK's
     `createEmbeddings` is buried in a `Methods` record built from a live client env, the
     cleanest network-free assertion is on the *request value*: construct the
     `Emb.CreateEmbeddings` that `embed` would send for a given `EmbeddingModel` and input,
     and assert its fields (`input == "hello"`, `model == OpenAIModels.Model
     "text-embedding-3-small"`, `dimensions == Nothing`). To make this testable without
     duplicating logic, factor the request construction in `Baikai.Embedding` into a small
     **pure** exported helper, e.g. `mkEmbeddingRequest :: EmbeddingModel -> Text ->
     Emb.CreateEmbeddings`, and have `embed` call it. Then the unit test asserts on
     `mkEmbeddingRequest`. Add `mkEmbeddingRequest` to the module's export list.
   - A **gated `LiveSpec`-style test**, mirroring
     `baikai-effectful/test/LiveSpec.hs`: read an env var (call it
     `BAIKAI_EMBEDDING_LIVE`); when it is `"1"` (and `OPENAI_API_KEY` is set), call
     `embedOne (openAIEmbeddingModel "text-embedding-3-small") "hello"` and assert the
     returned vector has length `1536`; otherwise print a skip line and stay green. This keeps
     the default `cabal test` run hermetic.

**Commands (run from `/Users/shinzui/Keikaku/bokuno/baikai`):**

```bash
nix develop
cabal build baikai
cabal test baikai
```

**Acceptance for M1.** `cabal build baikai` compiles the new `Baikai.Embedding` module.
`cabal test baikai` is green with the live test skipped (you should see a line like
`BAIKAI_EMBEDDING_LIVE not set; skipping live test`). The request-mapping unit test passes,
proving `mkEmbeddingRequest` puts the input text, model id, and dimensions where the OpenAI
embeddings wire expects them. Optionally, with a real key:

```bash
OPENAI_API_KEY=sk-... BAIKAI_EMBEDDING_LIVE=1 cabal test baikai
```

should print a `LIVE` line and pass, demonstrating a real 1536-length vector came back.

**Commit (M1).** Commit in the baikai repo. The message follows Conventional Commits and
carries the cross-plan trailers this initiative uses:

```text
feat(baikai): add Baikai.Embedding OpenAI /v1/embeddings client

MasterPlan: docs/masterplans/2-shikumi-substrate-routing-completion.md
ExecPlan: docs/plans/15-embedding-backend-over-baikai.md
Intention: intention_01ktq80610e6nbe3d7yrct59an
```


### Milestone M2 — Shikumi `Embedding`-effect interpreter

**Scope.** Add a Shikumi interpreter for the existing `Shikumi.Eval.Metric.Embedding`
effect that drives the M1 baikai client. At the end of M2, a Shikumi program can run
`semanticSimilarity` against a real OpenAI-compatible embeddings endpoint by discharging the
`Embedding` effect with the new interpreter at the bottom of the stack (where `IOE` lives),
exactly as `runEmbedding` discharges it for the pure case.

**Files to create or edit (all under `/Users/shinzui/Keikaku/bokuno/shikumi`):**

1. **New module** `shikumi-eval/src/Shikumi/Eval/Embedding.hs`. It must not change the
   `Embedding` effect's definition (that stays in `Shikumi.Eval.Metric`, the integration
   point #5 contract); it only adds interpreters. Public surface:

   ```haskell
   module Shikumi.Eval.Embedding
     ( runEmbeddingWith   -- explicit EmbeddingModel
     , runEmbeddingLLM    -- defaulted to OpenAI text-embedding-3-small
     ) where

   runEmbeddingWith ::
     (IOE :> es, Error ShikumiError :> es) =>
     EmbeddingModel ->
     Eff (Embedding : es) a ->
     Eff es a

   runEmbeddingLLM ::
     (IOE :> es, Error ShikumiError :> es) =>
     Eff (Embedding : es) a ->
     Eff es a
   ```

   Implementation notes:

   - Import the effect and its operation from
     `Shikumi.Eval.Metric (Embedding (..))` (the `Embedding (..)` export already exists in
     that module's export list, exposing the `EmbedText` constructor). Import the baikai
     client: `import Baikai.Embedding (EmbeddingModel, embedOne, openAIEmbeddingModel)`.
   - `runEmbeddingWith m = interpret $ \_ -> \case EmbedText t -> ...`. Inside, run the IO
     call `embedOne m t` via `liftIO`, but **wrap it** so a transport failure becomes a typed
     Shikumi error rather than an unhandled IO exception: catch the call (e.g. with
     `Control.Exception.try` inside `liftIO`) and on failure `throwError (ProviderFailure
     <rendered message>)` using `Shikumi.Error (ShikumiError (..))` and
     `Effectful.Error.Static (throwError)`. This is why the interpreter carries the
     `Error ShikumiError :> es` constraint and `runEmbedding` (the pure one) does not — a real
     backend can fail, and the surrounding `evaluate` runner already threads
     `Error ShikumiError` (see the metric's siblings `modelJudge`/`semanticSimilarity` and the
     eval row `LLM, Concurrent, Error ShikumiError, Time, Prim`). `ProviderFailure` is the
     `ShikumiError` constructor baikai transport failures map to elsewhere
     (`Shikumi.Error.fromBaikaiError` maps `ProviderError -> ProviderFailure`), so reuse it
     for consistency.
   - `runEmbeddingLLM = runEmbeddingWith (openAIEmbeddingModel "text-embedding-3-small")`.
   - `IOE :> es` is the bottom-of-stack effect that permits `liftIO`; it is introduced here
     and nowhere higher, keeping every layer above policy-free — the same discipline
     baikai-effectful follows (`IOE` only inside `runBaikaiWith`).

2. **Edit** `shikumi-eval/shikumi-eval.cabal`. Add `Shikumi.Eval.Embedding` to the library
   `exposed-modules`, and add `baikai` and `vector` to the library `build-depends` (the test
   suite already depends on `baikai`; the library gains a direct `baikai` dep here). No
   `cabal.project` change is needed — `baikai` is already a local-path package there.

**Commands (run from `/Users/shinzui/Keikaku/bokuno/shikumi`):**

```bash
nix develop .#ghc9124
cabal build shikumi-eval
```

**Acceptance for M2.** `cabal build shikumi-eval` compiles the new
`Shikumi.Eval.Embedding` module, proving `runEmbeddingWith` / `runEmbeddingLLM` type-check
against both the Shikumi `Embedding` effect and the M1 baikai client. (Behavioural proof
comes in M3; M2's acceptance is that the interpreter exists and the cross-repo types line
up.)

**Commit (M2).** In the Shikumi repo:

```text
feat(shikumi-eval): add runEmbeddingWith/runEmbeddingLLM Embedding interpreter

MasterPlan: docs/masterplans/2-shikumi-substrate-routing-completion.md
ExecPlan: docs/plans/15-embedding-backend-over-baikai.md
Intention: intention_01ktq80610e6nbe3d7yrct59an
```


### Milestone M3 — Wire `semanticSimilarity` end-to-end with a hermetic stub and a gated live test

**Scope.** Prove the whole path works. Add a hermetic (no-network) test that drives
`semanticSimilarity` through the *real interpreter shape* using a deterministic stub
backend, asserting that a semantically-close pair scores strictly higher than a distant
pair; and a gated live test asserting a real vector's dimensionality. At the end of M3, a
reader can run one test command and watch the inert metric produce meaningful scores from a
backend.

**The hermetic-stub challenge and how to solve it.** The M2 interpreter `runEmbeddingWith`
makes a live HTTP call inside `EmbedText`, so it cannot itself be used hermetically. The
existing pure `runEmbedding :: (Text -> Vector Double) -> ...` *is* hermetic but bypasses the
new code path. To get a hermetic test that genuinely exercises the **batching client shape**
(the thing M1 added) without a network, introduce a tiny seam: factor the per-text core of
the interpreter so it can be driven by an injected `[Text] -> IO (Vector (Vector Double))`
function. Concretely, add to `Shikumi.Eval.Embedding` one more exported interpreter:

```haskell
-- | Interpret 'Embedding' with an explicit batching embedder (the same shape as
-- 'Baikai.Embedding.embed'). 'runEmbeddingWith' is this with the embedder fixed
-- to the baikai client; a deterministic stub embedder drives it in hermetic tests.
runEmbeddingBy ::
  (IOE :> es, Error ShikumiError :> es) =>
  ([Text] -> IO (Vector (Vector Double))) ->
  Eff (Embedding : es) a ->
  Eff es a
```

Define `runEmbeddingWith m = runEmbeddingBy (embed m)` so the production interpreter and the
test interpreter share the identical effect-handling, error-wrapping, and vector-extraction
logic; only the embedder function differs. Export `runEmbeddingBy` from the module. This is a
standard "inject the effectful boundary" refactor and keeps the hermetic test honest: it runs
the *same* interpreter the live path runs, with the network call replaced by a pure stub.

**Files to create or edit (all under `/Users/shinzui/Keikaku/bokuno/shikumi`):**

1. **Edit** `shikumi-eval/src/Shikumi/Eval/Embedding.hs` to add and export `runEmbeddingBy`
   as above, and redefine `runEmbeddingWith` in terms of it.

2. **New test module** `shikumi-eval/test/EmbeddingSpec.hs`, added to the
   `shikumi-eval-test` suite's `other-modules` in `shikumi-eval/shikumi-eval.cabal`. It
   contains:

   - A **deterministic stub embedder** `stubEmbed :: [Text] -> IO (Vector (Vector Double))`
     that maps known strings to fixed 2-D or 3-D vectors chosen so the close pair's cosine
     exceeds the distant pair's. For example, place "a cat sat on the mat" and "the cat is on
     the rug" near the same direction (e.g. `[1, 0.9]` and `[0.9, 1]`, cosine ≈ 0.995) and
     "quarterly revenue rose" on a near-orthogonal direction (e.g. `[0, 1]` would be too
     close to the second; use `[1, -1]` for the distant one so cosine against `[1, 0.9]` is
     small/negative). Pick exact numbers in code and verify the inequality holds; the point is
     a *strict* close > distant separation under `cosineScore`'s `[-1,1]→[0,1]` mapping.
   - A test `"semanticSimilarity scores close pair above distant pair (hermetic)"` that runs,
     for each pair, `semanticSimilarity id` through `runEmbeddingBy stubEmbed` under
     `runEff` + `runErrorNoCallStack @ShikumiError`, and asserts the close pair's `Score` is
     strictly greater than the distant pair's. The harness mirrors the existing
     `shikumi-eval/test/MetricLMSpec.hs` (which already runs `semanticSimilarity` through
     `runEmbedding` over a fixed table), but routes through `runEmbeddingBy` so it exercises
     the new code path. Because `runEmbeddingBy` carries `IOE`, run under `runEff` (not
     `runPureEff`).
   - A **gated live test** `"live embedding returns expected dimensionality"`, mirroring M1's
     and baikai-effectful's `LiveSpec`: read an env var (call it `SHIKUMI_EMBEDDING_LIVE`);
     when `"1"` (and `OPENAI_API_KEY` set), run `embedText "hello"` through `runEmbeddingLLM`
     under `runEff` + the error handler and assert the resulting `Vector Double` has length
     `1536`; otherwise print a skip line and stay green.

3. **Edit** `shikumi-eval/test/Main.hs` to include `EmbeddingSpec.tests` in the suite's test
   tree (follow the existing pattern by which `MetricLMSpec` etc. are aggregated).

**Why this acceptance is meaningful (fails before, passes after).** Before this plan, there
is no `runEmbeddingBy`/`runEmbeddingWith` interpreter and no batching client, so the test
module `EmbeddingSpec` cannot even be written against an existing API — there is nothing to
import; the close-vs-distant assertion through the real interpreter shape is unrunnable.
After M1–M3, the module compiles and the assertion passes: the stub-backed
`semanticSimilarity` returns a strictly higher score for the close pair. This is the
observable behaviour the Purpose section promised — meaning-closeness reflected in the score
— demonstrated without a network, and the gated live test demonstrates the same path against
a real provider returning a correctly-sized vector.

**Commands (run from `/Users/shinzui/Keikaku/bokuno/shikumi`):**

```bash
nix develop .#ghc9124
cabal test shikumi-eval
```

Expected (abridged) output:

```text
Embedding
  semanticSimilarity scores close pair above distant pair (hermetic): OK
  live embedding returns expected dimensionality: OK
    SHIKUMI_EMBEDDING_LIVE not set; skipping live test
...
All N tests passed
```

And the full suite:

```bash
cabal test all
```

should remain green (the new tests are additive and the live test is skipped by default).
With a real key:

```bash
OPENAI_API_KEY=sk-... SHIKUMI_EMBEDDING_LIVE=1 cabal test shikumi-eval
```

runs the live test for real and asserts a 1536-length vector.

**Commit (M3).** In the Shikumi repo:

```text
test(shikumi-eval): semanticSimilarity end-to-end over stub + gated live embedder

MasterPlan: docs/masterplans/2-shikumi-substrate-routing-completion.md
ExecPlan: docs/plans/15-embedding-backend-over-baikai.md
Intention: intention_01ktq80610e6nbe3d7yrct59an
```

After M3, update the parent master plan
(`docs/masterplans/2-shikumi-substrate-routing-completion.md`): flip EP-15's registry row
status and check the two EP-15 progress bullets ("Upstream baikai embeddings client" and
"Shikumi `Embedding`-effect interpreter; `semanticSimilarity` runs end-to-end").


## Concrete Steps

The exact command sequence, in order, with working directories. Update this section as work
proceeds (record actual output under the milestone where it was produced).

```bash
# --- M1: upstream baikai client (in the baikai repo) ---
cd /Users/shinzui/Keikaku/bokuno/baikai
nix develop                 # GHC 9.12.4 dev shell for baikai
# create baikai/src/Baikai/Embedding.hs; edit baikai/baikai.cabal; add the test module
cabal build baikai
cabal test baikai           # live test skipped; request-mapping unit test passes
fourmolu --mode inplace $(git ls-files '*.hs')   # or rely on pre-commit
git add -A
git commit                  # message with MasterPlan/ExecPlan/Intention trailers (see M1)

# --- M2: Shikumi interpreter (in the shikumi repo) ---
cd /Users/shinzui/Keikaku/bokuno/shikumi
nix develop .#ghc9124       # GHC 9.12.4 dev shell for shikumi
# create shikumi-eval/src/Shikumi/Eval/Embedding.hs; edit shikumi-eval/shikumi-eval.cabal
cabal build shikumi-eval
git add -A && git commit     # M2 message + trailers

# --- M3: end-to-end tests (in the shikumi repo) ---
# add runEmbeddingBy; create shikumi-eval/test/EmbeddingSpec.hs; edit test/Main.hs + cabal
cabal test shikumi-eval     # hermetic close>distant passes; live test skipped
cabal test all              # full suite stays green
git add -A && git commit     # M3 message + trailers
# update docs/masterplans/2-...md registry row + progress bullets; commit
```

A note on the cross-repo ordering: because Shikumi consumes `baikai` by local path
(`cabal.project`), the M2 Shikumi build automatically picks up the M1 baikai source on disk;
there is no publish or version-bump step between M1 and M2. If you build Shikumi before M1's
module exists, M2's import of `Baikai.Embedding` fails — do M1 first.


## Validation and Acceptance

The plan is accepted when all of the following hold:

1. In the baikai repo, `cabal test baikai` is green with the embeddings request-mapping unit
   test passing and the live test skipped. This proves the upstream client compiles and maps
   a request correctly with no network.

2. In the Shikumi repo, `cabal test shikumi-eval` is green, and within it the hermetic test
   `"semanticSimilarity scores close pair above distant pair (hermetic)"` passes — the close
   pair's `Score` is strictly greater than the distant pair's, computed by routing the
   real `runEmbeddingBy` interpreter over a deterministic stub embedder. This is the headline
   observable behaviour: the previously-inert `semanticSimilarity` now produces a
   meaning-sensitive score from a backend. It fails before this plan (no interpreter, nothing
   to import) and passes after.

3. `cabal test all` in the Shikumi repo remains green — the change is additive and the live
   tests are gated, so the default hermetic run is unaffected.

4. (Optional, when a real key is available) With `OPENAI_API_KEY` set and the live gate
   enabled (`BAIKAI_EMBEDDING_LIVE=1` for baikai, `SHIKUMI_EMBEDDING_LIVE=1` for shikumi),
   the live tests run and assert the returned vector has length `1536` for
   `text-embedding-3-small`. This proves the path works against a real provider and returns
   the expected dimensionality.

Phrase your verification by behaviour, not by code presence: the success signal is a passing
close-vs-distant inequality and a correctly-sized live vector, not merely "the module
exists".


## Idempotence and Recovery

All steps are additive and safe to repeat. Re-running `cabal build` / `cabal test` is
idempotent. Creating the new modules is a one-time additive change; if a build fails partway
(for example a missing `build-depends` entry), fix the cabal file and rebuild — nothing is
destructive and there is no migration or data change anywhere in this plan.

If the upstream-placement decision is revisited (moving `Baikai.Embedding` from core
`baikai` into `baikai-openai`), the recovery is mechanical: move the file, change the module
header and the two cabal `exposed-modules`/`build-depends` stanzas, and point the Shikumi
interpreter's import at the new package. The module body is unchanged. Re-run M1 and M2
builds to confirm.

If the live tests ever fail due to provider/key issues, that does not block acceptance —
they are gated and skipped by default; acceptance rests on the hermetic tests. To retry a
live run, re-export the env vars and re-run the single test command; no cleanup is needed
between runs (the calls are stateless reads).


## Interfaces and Dependencies

**Libraries and why.**

- `baikai` (core transport, `/Users/shinzui/Keikaku/bokuno/baikai/baikai`): gains the new
  `Baikai.Embedding` module. Reuses `Baikai.Auth` (`ApiKeySource`, `resolveApiKey`) for key
  resolution. Already wired into Shikumi by local path in `cabal.project`.
- `openai` (`MercuryTechnologies/openai`, vendored at
  `/Users/shinzui/Keikaku/hub/haskell/openai-project`): the `Baikai.Embedding` client calls
  its `OpenAI.V1` `getClientEnv` / `makeMethods` and the `Methods.createEmbeddings ::
  CreateEmbeddings -> IO (Vector EmbeddingObject)` field, with request/response types from
  `OpenAI.V1.Embeddings`. Already a dep of `baikai-openai`; newly added to core `baikai`'s
  library deps (or kept in `baikai-openai` under the layering fallback).
- `vector` (`Data.Vector`): the embedding representation (`Vector Double` per text,
  `Vector (Vector Double)` per batch). Already used throughout both repos.
- `effectful` / `effectful-core`: the `Embedding` effect and its `interpret`-based
  interpreters in Shikumi; `IOE` for the bottom-of-stack IO boundary and
  `Effectful.Error.Static (Error, throwError)` for typed error wrapping.

**Types and signatures that must exist at the end of each milestone.**

- End of M1 (in `baikai`):

  ```haskell
  data EmbeddingModel = EmbeddingModel
    { modelId    :: !Text
    , baseUrl    :: !Text
    , dimensions :: !(Maybe Natural)
    , apiKey     :: !ApiKeySource
    }
  _EmbeddingModel      :: EmbeddingModel
  openAIEmbeddingModel :: Text -> EmbeddingModel
  embed                :: EmbeddingModel -> [Text] -> IO (Vector (Vector Double))
  embedOne             :: EmbeddingModel -> Text -> IO (Vector Double)
  mkEmbeddingRequest   :: EmbeddingModel -> Text -> OpenAI.V1.Embeddings.CreateEmbeddings
  ```

- End of M2 (in `shikumi-eval`):

  ```haskell
  runEmbeddingWith :: (IOE :> es, Error ShikumiError :> es)
                   => EmbeddingModel -> Eff (Embedding : es) a -> Eff es a
  runEmbeddingLLM  :: (IOE :> es, Error ShikumiError :> es)
                   => Eff (Embedding : es) a -> Eff es a
  ```

- End of M3 (in `shikumi-eval`):

  ```haskell
  runEmbeddingBy :: (IOE :> es, Error ShikumiError :> es)
                 => ([Text] -> IO (Vector (Vector Double)))
                 -> Eff (Embedding : es) a -> Eff es a
  -- with runEmbeddingWith m = runEmbeddingBy (embed m)
  ```

**The unchanged contract (integration point #5).** The `Embedding` effect itself
(`Shikumi.Eval.Metric.Embedding`, op `EmbedText :: Text -> Embedding m (Vector Double)`,
helper `embedText`, pure interpreter `runEmbedding`, metric `semanticSimilarity`) is **not
modified** by this plan. Downstream consumers (MasterPlan 3's KNN few-shot and
similarity-based demo selection) interpret the same effect with the new `runEmbeddingWith` /
`runEmbeddingLLM` instead of the pure `runEmbedding`, exactly as the master plan's
integration point #5 prescribes. The embedding-model naming convention this plan establishes:
an embedding model is identified by a bare provider model-id string (e.g.
`"text-embedding-3-small"`) plus a base URL inside the new `EmbeddingModel` record, with no
baikai `Api`-tag registration and no chat-catalog entry required.
