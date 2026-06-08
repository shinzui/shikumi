---
id: 1
slug: shikumi-runtime-substrate-and-llm-effect-over-baikai
title: "Shikumi runtime substrate and LLM effect over baikai"
kind: exec-plan
created_at: 2026-06-08T02:44:16Z
intention: "intention_01ktjgkp10ef79vpwz1cmajek9"
master_plan: "docs/masterplans/1-shikumi-typed-lm-programming-framework.md"
---

# Shikumi runtime substrate and LLM effect over baikai

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Shikumi (仕組み — "the mechanism behind how something works") is a Haskell framework for
writing language-model (LM) programs as ordinary, well-typed software. This ExecPlan,
**EP-1**, lays the foundation that every later part of shikumi stands on. It does three
things, in plain terms.

First, it **creates the shikumi project** itself. Today the repository
`/Users/shinzui/Keikaku/bokuno/shikumi` contains only documentation (`docs/`), agent
configuration (`.claude/`, `.agents/`, `agents/`), and a dependency-registry descriptor
(`mori.dhall`). There is no Haskell code, no `cabal.project`, and no buildable package.
EP-1 scaffolds the multi-package cabal project and the core `shikumi` library so that
`cabal build all` succeeds for the first time.

Second, it **wraps baikai in an `effectful` effect.** baikai
(`/Users/shinzui/Keikaku/bokuno/baikai`) is a separate, already-working Haskell library
that talks to AI providers (Claude, OpenAI, DeepSeek, OpenRouter, Ollama, and the
`claude -p` / `codex exec` command-line tools) through one uniform interface. baikai's
calls live in plain `IO`. shikumi instead builds everything inside `effectful` — an effect
system where a function's type lists the capabilities it may use (for example,
`(LLM :> es) => ...` means "this code may make LM calls"). EP-1 defines the `LLM` effect:
a provider-neutral way to ask a model to complete a prompt, or to stream its tokens,
implemented on top of baikai. After EP-1, a program written as
`complete model context options :: (LLM :> es) => Eff es Response` runs through the
`effectful` machinery, calls baikai underneath, and returns the model's reply.

Third, it **adds the production-runtime features baikai deliberately leaves out**: an
enumerated shikumi error type (so callers get precise, typed failures instead of raw
exceptions), automatic **retries with exponential backoff** for transient provider
errors, **rate limiting** (a cap on how many requests may be in flight or started per
unit time), and **budget control** (a running ceiling on accumulated US-dollar cost that,
once exceeded, refuses further calls).

What you can do after EP-1, concretely:

- Run `cabal build all` from the repo root and watch the `shikumi` package compile against
  `baikai`, `baikai-claude`, `baikai-openai`, and `effectful`.
- Run a test that drives a **stub provider** (a fake baikai provider that returns a fixed
  reply without any network) end-to-end through the `Eff` stack and asserts the returned
  text — proving the effect, the interpreter, and the baikai bridge all work together.
- Run a test that makes the stub fail twice and succeed on the third try, and observe that
  the retry interpreter recovers transparently; and a test that sets a tiny budget,
  observes the first call succeed, and the second fail with a typed
  `BudgetExceeded` error.
- Optionally (gated behind an environment variable so the default test run needs no
  network or API key) run a **real** provider call through the same effect and see actual
  model text come back.

This plan **owns integration point #1** of the MasterPlan: the `LLM` effect and the
shikumi error type. Later plans consume them — the signatures/structured-IO plan
(`docs/plans/3-generic-derived-signatures-and-structured-io.md`) issues LM calls through
`LLM`; the caching plan (`docs/plans/6-caching-subsystem.md`) wraps `LLM` with a cache;
the tracing plan (`docs/plans/7-hierarchical-tracing-observability-and-replay.md`)
observes it; and the tools/agents plan
(`docs/plans/11-typed-tools-and-react-agents.md`) drives a tool loop over it. Because so
much depends on it, the shapes EP-1 chooses (the effect's operations, the error
constructors, the interpreter's configuration) are deliberately small, explicit, and
documented here in full.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M1: Scaffold the cabal project — root `cabal.project` with a `source-repository-package`
      stanza for baikai/baikai-claude/baikai-openai, the `shikumi` package with
      `shikumi.cabal`, an empty-but-compiling `Shikumi.Prelude`, and `mori.dhall` confirmed
      to mirror baikai. `cabal build all` succeeds.
- [ ] M2: `Shikumi.Error` — the `ShikumiError` enumerated type and `fromBaikaiError`
      mapping. Unit test asserts each `BaikaiError` constructor maps to the intended
      `ShikumiError`.
- [ ] M3: `Shikumi.LLM` core — the `LLM` effect, the `complete`/`stream` smart
      constructors, and a bare interpreter `runLLM` over `IOE` that calls baikai. A test
      drives a **stub provider** end-to-end through `Eff` and asserts returned text.
- [ ] M4: Resilience layer — `LLMConfig` (retry policy, rate limit, budget), the
      `runLLMResilient` interpreter, and `Shikumi.LLM.Budget`. Tests: retry recovers after
      N transient failures; budget refuses the call that would cross the ceiling
      (`BudgetExceeded`); timeout surfaces as `Timeout`.
- [ ] M5: Live end-to-end demo gated by `SHIKUMI_LIVE=1` — an executable/test that, when
      the env var and an API key are present, runs a real provider call through `LLM` and
      prints model text; otherwise skips cleanly. Document the transcript.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Use `effectful` as the runtime substrate and model the LM call as a single
  dynamically-dispatched effect `LLM` with two operations (`Complete`, `Stream`).
  Rationale: a dynamic effect (one whose operations are a data type interpreted at the
  edge) lets later plans *re-interpret* the same operations to add caching
  (`docs/plans/6-caching-subsystem.md`) and tracing
  (`docs/plans/7-hierarchical-tracing-observability-and-replay.md`) without changing
  call sites; the MasterPlan already commits to `effectful`. A static effect would make
  wrapping harder. Date: 2026-06-08.

- Decision: shikumi defines its own enumerated `ShikumiError` and a total
  `fromBaikaiError :: BaikaiError -> ShikumiError` mapping, rather than re-exporting
  baikai's `BaikaiError`. Rationale: shikumi adds failure modes baikai has no concept of
  (schema mismatch, validation failure, timeout, budget exceeded), and every later plan
  must converge on one error vocabulary (integration point #1). Date: 2026-06-08.

- Decision: Implement retries/backoff, rate limiting, and budget as a *layered
  interpreter* `runLLMResilient` built around the bare `runLLM`, configured by an
  `LLMConfig` value, rather than baking them into the effect's operations. Rationale: the
  effect should stay a thin provider-neutral surface; resilience is a policy chosen at
  interpretation time and is exactly the kind of behavior `effectful` interpreters are
  for. Keeping `runLLM` minimal also gives tests a deterministic baseline. Date: 2026-06-08.

- Decision: Budget is tracked as accumulated US dollars read from baikai's per-response
  `Usage.cost.usd` (a `Rational`), enforced *before* a call by an optimistic check and
  updated *after* each successful call. A call is refused with `BudgetExceeded` only when
  the running total already meets/exceeds the ceiling. Rationale: baikai always computes
  `Usage`/`Cost` (never `Nothing`), so no estimation layer is needed; pre-call refusal of
  the *next* call after the ceiling is reached is simple, predictable, and testable.
  Date: 2026-06-08.

- Decision: Classify which `ShikumiError`s are retryable in one place
  (`isTransient :: ShikumiError -> Bool`): provider failures and timeouts are transient;
  invalid-request, decode, schema, validation, and budget errors are not. Rationale:
  retrying a malformed request or a budget breach is pointless and could burn budget; a
  single predicate keeps the policy auditable. Date: 2026-06-08.

- Decision: Test the whole stack with a **stub baikai provider** registered into an
  isolated `ProviderRegistry` (via baikai's `newProviderRegistry` + `completeRequestWith`),
  so the default `cabal test all` needs no network and no API key. A separate
  `SHIKUMI_LIVE=1`-gated path exercises a real provider. Rationale: deterministic,
  hermetic tests are required for CI; the live path proves the real integration without
  making it mandatory. Date: 2026-06-08.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This section assumes you know nothing about this repository or its dependencies. Read it
in full before editing anything.

### The two repositories

- **shikumi** — `/Users/shinzui/Keikaku/bokuno/shikumi`. The repository you are building
  in. Today it has no Haskell code. Relevant existing files: `docs/` (plans, including
  this one), `mori.dhall` (a dependency-registry descriptor, explained below), and
  `.gitignore`. There is no `cabal.project` and no package directory yet; EP-1 creates
  them.
- **baikai** — `/Users/shinzui/Keikaku/bokuno/baikai`. A separate, already-working
  multi-package Haskell library that shikumi builds upon. You will not edit baikai in this
  plan. You depend on three of its packages: `baikai` (core), `baikai-claude` (Anthropic
  providers), and `baikai-openai` (OpenAI providers). baikai is **not published on
  Hackage**, so cabal must fetch it from its git source (see Milestone 1).

### What "effectful" means here

`effectful` is a Haskell effect-system library. An *effect* is a named capability (like
"make LM calls" or "read the clock"). Code that uses an effect carries it in its type via
a constraint `(LLM :> es)` — read "the effect list `es` contains `LLM`". The monad is
`Eff es a`: a computation that may use the effects in `es` and returns `a`. You *run* an
`Eff` computation by *interpreting* each effect — supplying the real behavior — until only
the built-in `IOE` (the ability to do `IO`) remains, then calling `runEff` to get an `IO`
action.

There are two flavors of effect. A **dynamic** effect declares its operations as a GADT
(a data type whose constructors carry type indices) of kind `Effect`
(`(Type -> Type) -> Type -> Type`), and an *interpreter* turns each constructor into real
work. We use a dynamic effect for `LLM` precisely so later plans can supply *different*
interpreters (one that caches, one that traces) for the same operations. The relevant
functions from `effectful`, with the signatures you will use:

```haskell
-- From Effectful (the entry points):
runEff :: IOE :> es => Eff '[IOE] a -> IO a            -- conceptually; runs the final IO layer
-- (you typically write: runEff $ runLLMResilient cfg reg $ program)

-- From Effectful.Dispatch.Dynamic (declaring/using/interpreting dynamic effects):
send      :: (e :> es, DispatchOf e ~ 'Dynamic) => e (Eff es) a -> Eff es a
interpret :: DispatchOf e ~ 'Dynamic
          => (forall r localEs. (HasCallStack, e :> localEs)
                => LocalEnv localEs es -> e (Eff localEs) r -> Eff es r)
          -> Eff (e : es) a -> Eff es a
-- `interpret` peels effect `e` off the front of the stack by giving each operation
-- a handler. The handler runs in `Eff es` (the remaining effects). `LocalEnv` lets you
-- run higher-order arguments; we won't need it for first-order ops but it is part of the
-- signature.

-- To call baikai's IO functions from inside a handler whose remaining stack has IOE:
liftIO :: IOE :> es => IO a -> Eff es a                 -- from Effectful (MonadIO)
-- and MonadUnliftIO is available for callbacks that need to run Eff back inside IO.
```

The built-in **`Error`** effect (module `Effectful.Error.Static`) gives typed, recoverable
errors inside `Eff`:

```haskell
-- From Effectful.Error.Static:
data Error (e :: Type) :: Effect
throwError          :: (HasCallStack, Error e :> es) => e -> Eff es a
catchError          :: Error e :> es => Eff es a -> (CallStack -> e -> Eff es a) -> Eff es a
runError            :: Eff (Error e : es) a -> Eff es (Either (CallStack, e) a)
runErrorNoCallStack :: Eff (Error e : es) a -> Eff es (Either e a)
```

We surface shikumi failures through `Error ShikumiError`, so a program's type can read
`(LLM :> es, Error ShikumiError :> es) => ...` and the caller chooses where to handle
them with `runError`/`runErrorNoCallStack`.

For sleeping between retries and for time, use `effectful`'s `Effectful.Concurrent` (which
re-exports `threadDelay`) or simply `liftIO . threadDelay`; either is acceptable. For
rate limiting we use a semaphore from `Effectful.Concurrent.QSem` / `QSemN` or plain
`stm`; the plan specifies a simple approach below.

### What baikai gives us (the transport layer)

baikai's top module `Baikai` re-exports the public surface. The functions and types EP-1
touches:

```haskell
-- Dispatch (all in IO). Without "With" they use a process-global registry; the
-- "With" variants take an explicit registry (used by tests for isolation).
completeRequest     :: Model -> Context -> Options -> IO Response
completeRequestWith :: ProviderRegistry -> Model -> Context -> Options -> IO Response
streamRequest       :: Model -> Context -> Options -> Stream IO AssistantMessageEvent
streamRequestWith   :: ProviderRegistry -> Model -> Context -> Options -> Stream IO AssistantMessageEvent

-- Core records (fields abbreviated; construct with generic-lens from empty bases
-- `_Context` / `_Options`, e.g. `_Options & #maxTokens .~ Just 32`):
data Context  = Context  { systemPrompt :: Maybe Text, messages :: Vector Message, tools :: Vector Tool }
data Options  = Options  { maxTokens :: Maybe Natural, temperature :: Maybe Double
                         , apiKey :: Maybe ApiKeySource, timeoutMs :: Maybe Int, ... }
data Response = Response { message :: AssistantPayload, model :: Model, api :: Api
                         , provider :: Text, responseId :: Maybe Text, latencyMs :: Integer }
data Model    = Model    { modelId :: Text, name :: Text, api :: Api, provider :: Text, ... }

-- Usage and cost are ALWAYS computed by baikai (never Nothing). Cost.usd is a Rational.
data Usage = Usage { inputTokens, outputTokens, ... :: Natural, totalTokens :: Natural, cost :: Cost }
data Cost  = Cost  { usd :: Rational, breakdown :: CostBreakdown }

-- IMPORTANT: baikai's `Response` record does NOT itself carry `Usage`. Usage arrives on
-- the streaming terminal event (EventDone/EventError carry the final Usage). The
-- implementer MUST confirm, when starting M4, exactly where Usage is exposed for the
-- blocking path (see "Interfaces and Dependencies" — Usage-access note). If the blocking
-- `Response` exposes usage via a helper, use it; otherwise run the streaming path to
-- recover the terminal Usage. Either way, budget reads `usage.cost.usd`.

-- Errors (an Exception; thrown by completeRequest on failure):
data BaikaiError = ProviderError !Text | RequestInvalid !Text | DecodeError !Text
                 | ProcessError !Int !Text
-- module: Baikai.Error. Streaming failures do NOT throw — they arrive as an EventError.

-- Provider registry (handlers keyed by an `Api` tag; no typeclass):
data Api = OpenAIChatCompletions | AnthropicMessages | OpenAICompletionsCli
         | AnthropicMessagesCli | Custom !Text
data ApiProvider = ApiProvider
  { apiTag   :: Api
  , stream   :: Model -> Context -> Options -> Stream IO AssistantMessageEvent
  , complete :: Model -> Context -> Options -> IO Response }
newProviderRegistry   :: IO ProviderRegistry
globalProviderRegistry :: ProviderRegistry
registerApiProvider   :: ApiProvider -> IO ()                 -- registers into the global registry
-- Vendor packages expose `register :: IO ()` (and a registry-scoped variant):
--   Baikai.Provider.Claude.Api.register, Baikai.Provider.OpenAI.Api.register
-- Registration is idempotent per Api tag; an unregistered tag throws ProviderError.

-- Streaming events (used only if you recover Usage from the stream):
data AssistantMessageEvent
  = EventStart StartPayload | TextStart .. | TextDelta .. | TextEnd ..
  | ThinkingStart .. | ThinkingDelta .. | ThinkingEnd ..
  | ToolCallStart .. | ToolCallDelta .. | ToolCallEnd ..
  | EventDone TerminalPayload | EventError TerminalPayload
-- Exactly one EventStart first; exactly one EventDone (success) or EventError (failure)
-- last; the terminal payload carries the assembled message + final Usage + StopReason.

-- Text extraction helpers:
flattenAssistantBlocks :: Response -> Vector AssistantContent
flattenAssistantText   :: Vector AssistantContent -> Text
```

baikai's style: `default-language: GHC2024`; default extensions `DeriveAnyClass`,
`DuplicateRecordFields`, `OverloadedLabels`, `OverloadedStrings`. Build values from the
empty bases `_Context`/`_Options` using `generic-lens` labels, e.g.
`_Context & #systemPrompt .~ Just "You are terse." & #messages .~ V.singleton msg`. The
exact baikai docs are at
`/Users/shinzui/Keikaku/bokuno/baikai/docs/user/{getting-started,streaming,tools,models-and-providers,cli-providers}.md`;
you may consult them but this plan embeds what EP-1 needs.

### What `mori.dhall` is

`mori.dhall` is a small descriptor consumed by the user's `mori` dependency-lookup tool.
It records the project's identity (name `shikumi`, namespace `shinzui`, language Haskell),
its packages, and its dependence on `shinzui/baikai`. It does **not** affect the cabal
build — it is metadata. A correct `mori.dhall` already exists at
`/Users/shinzui/Keikaku/bokuno/shikumi/mori.dhall` (it declares the `shikumi` package and
a dependency on `shinzui/baikai:baikai`). EP-1 verifies it and, as the package set grows
in later plans, this is where new packages get registered; for EP-1 the existing content
is sufficient and Milestone 1 only confirms it.


## Plan of Work

The work is five milestones. Each ends in a `cabal build` or `cabal test` you can run,
with the output you should see. Edits name full paths and module locations.

### Milestone 1 — Scaffold the buildable project

Scope: turn the empty repo into a multi-package cabal project that compiles. At the end,
`cabal build all` succeeds and produces an (almost empty) `shikumi` library that already
depends on baikai and effectful, proving the `source-repository-package` wiring resolves.

Create the root build descriptor `/Users/shinzui/Keikaku/bokuno/shikumi/cabal.project`.
It lists the local `shikumi` package and pulls baikai's three packages from git. baikai is
not on Hackage, so this stanza is mandatory; pin a real commit (read the latest commit of
`/Users/shinzui/Keikaku/bokuno/baikai` with `git -C /Users/shinzui/Keikaku/bokuno/baikai rev-parse HEAD`
and paste it as the `tag`):

```cabal
packages:
  shikumi

source-repository-package
    type: git
    location: https://github.com/shinzui/baikai
    tag: <PASTE-CURRENT-BAIKAI-COMMIT-SHA-HERE>
    subdir: baikai baikai-claude baikai-openai

test-show-details: direct
tests: True
jobs: $ncpus
```

Notes for the implementer: the `subdir:` line lists the three package subdirectories
inside the baikai repo. If you are developing against a local, possibly-uncommitted baikai
checkout, you may temporarily replace the `source-repository-package` stanza with a local
path during development:

```cabal
packages:
  shikumi
  /Users/shinzui/Keikaku/bokuno/baikai/baikai
  /Users/shinzui/Keikaku/bokuno/baikai/baikai-claude
  /Users/shinzui/Keikaku/bokuno/baikai/baikai-openai
```

but the committed `cabal.project` MUST use the `source-repository-package` form with a
pinned commit so the build is reproducible for anyone cloning shikumi alone. Record in the
Decision Log which form you committed and why.

Create the package directory `/Users/shinzui/Keikaku/bokuno/shikumi/shikumi/` and within
it `shikumi.cabal`. Mirror baikai's `common-options` (same warnings, `GHC2024`, same four
default extensions) so shikumi code and baikai code share a style. The dependency set
matches the dossier's canonical layout (`baikai`, `baikai-claude`, `baikai-openai`,
`effectful`, `aeson`, `lens`, `generic-lens`, `vector`, `text`, `containers`) plus what
the resilience layer needs (`stm` for the budget/rate-limit state, and `unliftio-core` or
`exceptions` for catching baikai's `IO` exceptions — `effectful` re-exports
`MonadUnliftIO`, and `Control.Exception.try` from `base` is enough to catch
`BaikaiError`):

```cabal
cabal-version:   3.4
name:            shikumi
version:         0.1.0.0
synopsis:        Typed, structured, evaluable LM programs over baikai
description:
  Shikumi is a Haskell-native framework for building typed language-model programs.
  This package provides the runtime substrate: the LLM effect over baikai, the
  shikumi error type, and resilience (retries, rate limiting, budget control).
license:         BSD-3-Clause
author:          Nadeem Bitar
maintainer:      nadeem@gmail.com
build-type:      Simple

common common-options
  ghc-options:
    -Wall -Wcompat -Widentities -Wincomplete-uni-patterns
    -Wincomplete-record-updates -Wredundant-constraints
    -fhide-source-paths -Wmissing-export-lists -Wpartial-fields
    -Wmissing-deriving-strategies
  default-language: GHC2024
  default-extensions:
    DeriveAnyClass
    DuplicateRecordFields
    OverloadedLabels
    OverloadedStrings

library
  import:          common-options
  hs-source-dirs:  src
  exposed-modules:
    Shikumi.Prelude
    Shikumi.Error
    Shikumi.LLM
    Shikumi.LLM.Budget
  build-depends:
    , base          >=4.20 && <5
    , aeson
    , baikai
    , baikai-claude
    , baikai-openai
    , containers
    , effectful
    , generic-lens
    , lens          ^>=5.3
    , stm
    , text          ^>=2.1
    , vector

test-suite shikumi-test
  import:             common-options
  type:               exitcode-stdio-1.0
  hs-source-dirs:     test
  main-is:            Main.hs
  other-modules:
    StubProvider
    ErrorSpec
    LLMSpec
    ResilienceSpec
  build-depends:
    , base
    , aeson
    , baikai
    , baikai-claude
    , baikai-openai
    , effectful
    , shikumi
    , stm
    , tasty
    , tasty-hunit
    , text
    , vector
```

Create the source directory `/Users/shinzui/Keikaku/bokuno/shikumi/shikumi/src/Shikumi/`
and a minimal `Shikumi/Prelude.hs` so the library has something to compile. For now
`Shikumi.Prelude` re-exports a few common names (this grows in later plans); keep it
trivial but real:

```haskell
module Shikumi.Prelude
  ( module Data.Text
  , module Data.Vector
  ) where

import Data.Text (Text)
import Data.Vector (Vector)
```

Create the test directory `/Users/shinzui/Keikaku/bokuno/shikumi/shikumi/test/` with a
placeholder `Main.hs` and empty stub modules so the package configures; later milestones
fill them. For M1 a single passing `tasty` test is enough to prove the test wiring:

```haskell
module Main (main) where

import Test.Tasty (defaultMain, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

main :: IO ()
main = defaultMain $ testGroup "shikumi"
  [ testCase "scaffold compiles" $ (1 + 1 :: Int) @?= 2 ]
```

(When you add `ErrorSpec`, `LLMSpec`, `ResilienceSpec`, `StubProvider` in later
milestones, list them in `other-modules` — they are already listed above — and import
their test trees into `Main`.)

Confirm `mori.dhall` already mirrors baikai's (identity namespace `shinzui`, language
Haskell, a `shikumi` package, dependency `shinzui/baikai:baikai`). It does. Make no change
unless it is missing; record in the Decision Log that it was present.

Acceptance: from `/Users/shinzui/Keikaku/bokuno/shikumi`, `cabal build all` exits 0 and
reports building `shikumi-0.1.0.0` and the three baikai libraries; `cabal test all` runs
the placeholder test and prints `1 passed`.

### Milestone 2 — The shikumi error type and the baikai mapping

Scope: define the one error vocabulary the whole framework shares, and a total mapping
from baikai's errors into it. At the end, `Shikumi.Error` exports `ShikumiError`,
`fromBaikaiError`, and `isTransient`, with a unit test pinning the mapping.

Create `/Users/shinzui/Keikaku/bokuno/shikumi/shikumi/src/Shikumi/Error.hs`. The type
enumerates exactly the failure modes the MasterPlan's integration point #1 names:

```haskell
module Shikumi.Error
  ( ShikumiError(..)
  , fromBaikaiError
  , isTransient
  ) where

import Baikai.Error (BaikaiError(..))
import Data.Text (Text)

-- | The single error vocabulary for the whole framework. Later plans (signatures,
-- caching, tracing, tools) MUST use this type rather than inventing their own.
data ShikumiError
  = InvalidJSON       !Text   -- ^ provider returned text that is not valid JSON
  | MissingField      !Text   -- ^ a required output field was absent (field name)
  | SchemaMismatch    !Text   -- ^ decoded JSON did not match the expected schema
  | ValidationFailure !Text   -- ^ a typed value failed a user/program validation rule
  | ProviderFailure   !Text   -- ^ the provider/transport failed (mapped from baikai)
  | Timeout           !Text   -- ^ the call exceeded its time budget
  | BudgetExceeded    !Text   -- ^ the running cost ceiling was reached; call refused
  deriving stock (Eq, Show)

-- | Total mapping from baikai's transport-level errors into shikumi's vocabulary.
-- baikai's constructors are: ProviderError, RequestInvalid, DecodeError, ProcessError.
fromBaikaiError :: BaikaiError -> ShikumiError
fromBaikaiError = \case
  ProviderError t   -> ProviderFailure t
  RequestInvalid t  -> SchemaMismatch ("invalid request: " <> t)
  DecodeError t     -> InvalidJSON t
  ProcessError n t  -> ProviderFailure ("process exited " <> tshow n <> ": " <> t)
  where
    tshow = Data.Text.pack . show
-- (import Data.Text qualified / use pack as appropriate; this is illustrative.)

-- | Which errors are worth retrying. Provider/transport failures and timeouts are
-- transient; everything else is a deterministic failure that retrying cannot fix.
isTransient :: ShikumiError -> Bool
isTransient = \case
  ProviderFailure{} -> True
  Timeout{}         -> True
  _                 -> False
```

Implementation note: `RequestInvalid` maps to `SchemaMismatch` because in baikai a
malformed request is usually a bad schema/parameters; choose `SchemaMismatch` and document
it, or, if M3/M4 experience shows otherwise, revisit and log the change. `DecodeError`
maps to `InvalidJSON` because baikai's decode failures are JSON parse failures of the
provider response. These two judgments are the only non-mechanical choices; record them in
the Decision Log if you revise them.

Create `/Users/shinzui/Keikaku/bokuno/shikumi/shikumi/test/ErrorSpec.hs` with a `tasty`
group asserting the four mappings and the `isTransient` classification, e.g.
`fromBaikaiError (ProviderError "x") @?= ProviderFailure "x"` and
`isTransient (BudgetExceeded "") @?= False`. Import its tree into `Main.hs`.

Acceptance: `cabal test all` runs `ErrorSpec` and all cases pass. Deliberately breaking
the mapping (e.g. mapping `DecodeError` to `ProviderFailure`) makes `ErrorSpec` fail —
demonstrate this once locally to confirm the test bites, then restore.

### Milestone 3 — The `LLM` effect and the bare interpreter, proven with a stub provider

Scope: define integration point #1's centerpiece — the `LLM` effect — and a baseline
interpreter `runLLM` that calls baikai. Prove it end-to-end through the `Eff` stack with a
**stub provider** (a fake baikai `ApiProvider` returning a fixed `Response`, registered
into an isolated registry), so no network is needed.

Create `/Users/shinzui/Keikaku/bokuno/shikumi/shikumi/src/Shikumi/LLM.hs`. Declare the
dynamic effect and its smart constructors:

```haskell
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE DataKinds #-}

module Shikumi.LLM
  ( -- * The effect
    LLM(..)
  , complete
  , stream
    -- * Interpreters
  , runLLM
  , runLLMWith
    -- * Re-exports of the baikai request/response vocabulary used at call sites
  , Model, Context, Options, Response
  ) where

import Baikai (Model, Context, Options, Response, AssistantMessageEvent)
import Baikai qualified
import Baikai.Provider.Registry (ProviderRegistry)
import Baikai.Error (BaikaiError)
import Control.Exception (try)
import Effectful
import Effectful.Dispatch.Dynamic (send, interpret)
import Effectful.Error.Static (Error, throwError)
import Shikumi.Error (ShikumiError, fromBaikaiError)

-- | The provider-neutral LM effect. Two operations: a blocking completion and a
-- streaming completion. `Stream` returns the assembled list of typed events so callers
-- that need deltas can fold them; higher layers (EP-7 tracing) re-interpret these.
data LLM :: Effect where
  Complete :: Model -> Context -> Options -> LLM m Response
  Stream   :: Model -> Context -> Options -> LLM m [AssistantMessageEvent]

type instance DispatchOf LLM = 'Dynamic

-- | Issue a blocking completion. This is integration point #1 — the call every later
-- plan makes. Signature deliberately mirrors baikai's `completeRequest` argument order.
complete :: (LLM :> es) => Model -> Context -> Options -> Eff es Response
complete m c o = send (Complete m c o)

-- | Issue a streaming completion, returning the assembled event list.
stream :: (LLM :> es) => Model -> Context -> Options -> Eff es [AssistantMessageEvent]
stream m c o = send (Stream m c o)
```

Now the bare interpreter. It needs `IOE` (to run baikai's `IO`) and `Error ShikumiError`
(to surface failures as typed errors rather than runtime exceptions). It catches baikai's
`BaikaiError` exception with `Control.Exception.try`, maps it with `fromBaikaiError`, and
re-raises it through the `Error` effect with `throwError`:

```haskell
-- | Bare interpreter over the process-global baikai registry. Use `runLLMWith` to
-- supply an isolated registry (tests do this).
runLLM
  :: (IOE :> es, Error ShikumiError :> es)
  => Eff (LLM : es) a -> Eff es a
runLLM = runLLMWith Baikai.globalProviderRegistry

-- | Bare interpreter over an explicit registry.
runLLMWith
  :: (IOE :> es, Error ShikumiError :> es)
  => ProviderRegistry -> Eff (LLM : es) a -> Eff es a
runLLMWith reg = interpret $ \_ -> \case
  Complete m c o -> do
    r <- liftIO (try (Baikai.completeRequestWith reg m c o)) :: Eff es (Either BaikaiError Response)
    either (throwError . fromBaikaiError) pure r
  Stream m c o -> do
    -- baikai streaming failures do NOT throw; they arrive as an EventError terminal.
    -- Collect the events; callers/higher layers interpret EventError. (If desired,
    -- detect a trailing EventError here and throwError ProviderFailure — decide in M3
    -- and document.)
    evs <- liftIO (collectStream reg m c o)
    pure evs
```

Provide a small helper `collectStream :: ProviderRegistry -> Model -> Context -> Options -> IO [AssistantMessageEvent]`
that runs baikai's `streamRequestWith reg m c o` and materializes the streamly stream to a
list (baikai's getting-started shows `Stream.toList $ streamRequest ...`). Keep it in
`Shikumi.LLM` (it is `IO`, called via `liftIO`).

Create the test stub `/Users/shinzui/Keikaku/bokuno/shikumi/shikumi/test/StubProvider.hs`.
It builds an isolated registry with `newProviderRegistry`, registers an `ApiProvider`
whose `apiTag` matches the `Api` of the `Model` you test with, whose `complete` returns a
fixed `Response` carrying known text, and whose `stream` yields a minimal valid event
sequence (`EventStart`, a `TextDelta`/`TextEnd`, `EventDone`). Expose:

```haskell
-- StubProvider.hs (test module)
stubRegistry  :: Text -> IO ProviderRegistry   -- registry whose complete returns the given text
failingStubRegistry :: IORef Int -> Int -> Text -> IO ProviderRegistry
  -- complete throws Baikai.Error.ProviderError the first `Int` times, then returns text;
  -- counts attempts in the IORef (used by Milestone 4's retry test)
stubModel     :: Model                          -- a hand-rolled Model whose `api` tag the stub serves
```

Construct `stubModel` by hand (a `Model` record with a `Custom`/known `Api` tag and dummy
`baseUrl`/cost) so it does not depend on any real catalog entry; document its `api` tag so
`stubRegistry` registers the matching `apiTag`.

Create `/Users/shinzui/Keikaku/bokuno/shikumi/shikumi/test/LLMSpec.hs`. The headline test
runs the whole stack:

```haskell
-- inside a tasty testCase:
reg  <- stubRegistry "hello from stub"
res  <- runEff . runErrorNoCallStack @ShikumiError . runLLMWith reg $ do
          r <- complete stubModel ctx opts
          pure (flattenAssistantText (flattenAssistantBlocks r))
res @?= Right "hello from stub"
```

where `ctx`/`opts` are built from baikai's `_Context`/`_Options` bases. This proves: the
effect dispatches, the interpreter calls baikai through the isolated registry, the
response flows back through `Eff`, and the error channel is wired (here `Right`).

Acceptance: `cabal test all` runs `LLMSpec` and the end-to-end stub case returns
`Right "hello from stub"`. A second case registers no provider for the model's tag and
asserts the result is `Left (ProviderFailure ...)` — proving the `BaikaiError ->
ShikumiError` mapping fires on a real baikai dispatch failure.

### Milestone 4 — Resilience: retries with backoff, rate limiting, and budget

Scope: add the production features baikai lacks, as a layered interpreter
`runLLMResilient` configured by `LLMConfig`, plus `Shikumi.LLM.Budget`. At the end, three
behaviors are observable in tests: transient failures are retried with exponential
backoff until success or exhaustion; concurrent requests are capped by a rate limit; and a
call that would push accumulated cost to/over the ceiling is refused with `BudgetExceeded`
*before* it runs.

Create `/Users/shinzui/Keikaku/bokuno/shikumi/shikumi/src/Shikumi/LLM/Budget.hs`:

```haskell
module Shikumi.LLM.Budget
  ( Budget(..)
  , newBudget
  , tryReserve
  , recordCost
  , spentUSD
  ) where

import Control.Concurrent.STM
import Data.Ratio ()  -- Rational

-- | A running cost ceiling in US dollars. `ceilingUSD == Nothing` means "unlimited".
data Budget = Budget
  { ceilingUSD :: !(Maybe Rational)
  , spentRef   :: !(TVar Rational)
  }

newBudget :: Maybe Rational -> IO Budget
newBudget c = Budget c <$> newTVarIO 0

-- | Optimistic pre-call check: returns True if a call is permitted (running total has
-- not yet reached the ceiling). When the ceiling is already met/exceeded, returns False.
tryReserve :: Budget -> IO Bool
tryReserve b = case ceilingUSD b of
  Nothing  -> pure True
  Just cap -> atomically $ do s <- readTVar (spentRef b); pure (s < cap)

-- | Add the actual cost of a completed call (read from baikai Usage.cost.usd).
recordCost :: Budget -> Rational -> IO ()
recordCost b c = atomically $ modifyTVar' (spentRef b) (+ c)

spentUSD :: Budget -> IO Rational
spentUSD b = readTVarIO (spentRef b)
```

The semantics (documented in the Decision Log): the budget refuses the *next* call once
the running total has reached the ceiling. A single very expensive call is therefore not
clipped mid-flight (baikai gives no streaming cost preview to enforce that), but once it
pushes the total to/over the cap, all subsequent calls fail fast with `BudgetExceeded`.
This is simple, deterministic, and testable.

Add the resilience configuration and interpreter to `Shikumi.LLM` (extend the module's
export list). The config:

```haskell
data RetryPolicy = RetryPolicy
  { maxAttempts :: !Int        -- ^ total tries including the first (>= 1)
  , baseDelayMs :: !Int        -- ^ first backoff delay
  , maxDelayMs  :: !Int        -- ^ cap on any single backoff delay
  }

defaultRetryPolicy :: RetryPolicy   -- e.g. maxAttempts 3, baseDelayMs 200, maxDelayMs 5000

data LLMConfig = LLMConfig
  { retryPolicy :: !RetryPolicy
  , budget      :: !(Maybe Budget)        -- ^ Nothing = unlimited
  , maxInFlight :: !(Maybe Int)           -- ^ rate limit: max concurrent calls; Nothing = unbounded
  , registry    :: !ProviderRegistry      -- ^ which baikai registry to dispatch against
  }
```

The interpreter wraps each `Complete`/`Stream` operation with three concentric policies,
in this order from outermost to innermost: **budget check** → **rate-limit acquire** →
**retry loop** → **the actual baikai call** (the same `try`/`fromBaikaiError` logic as
`runLLM`). Concretely:

```haskell
runLLMResilient
  :: (IOE :> es, Error ShikumiError :> es)
  => LLMConfig -> Eff (LLM : es) a -> Eff es a
runLLMResilient cfg = interpret $ \_ -> \case
  Complete m c o -> withBudget cfg $ withRateLimit cfg $ retrying cfg $ do
    r <- liftIO (try (Baikai.completeRequestWith (registry cfg) m c o))
    case r of
      Left be  -> throwError (fromBaikaiError be)
      Right rp -> do liftIO (chargeBudget cfg rp); pure rp
  Stream m c o -> withBudget cfg $ withRateLimit cfg $ retrying cfg $ do
    evs <- liftIO (collectStream (registry cfg) m c o)
    liftIO (chargeBudgetFromEvents cfg evs)   -- terminal event carries Usage
    pure evs
```

Define the helpers (all in `Shikumi.LLM`):

- `withBudget cfg act`: if `budget cfg` is `Just b`, call `liftIO (tryReserve b)`; on
  `False`, `throwError (BudgetExceeded "cost ceiling reached")`; on `True`, run `act`.
  If `Nothing`, just run `act`.
- `withRateLimit cfg act`: if `maxInFlight cfg` is `Just n`, guard `act` with a semaphore
  of `n` permits (acquire before, release after, even on exception). Use
  `Effectful.Concurrent.QSemN` (re-exported `waitQSemN`/`signalQSemN`) or an `stm` `TVar`
  counter created once and stored alongside the config; the simplest correct approach is a
  `TVar Int` initialized to `n`, decremented under `retry`-blocking STM when zero, and
  incremented on release using `Control.Exception.bracket_` / effectful's `bracket`. If
  `Nothing`, run `act` directly. (Initialize the semaphore once when building `LLMConfig`,
  not per call.)
- `retrying cfg act`: run `act`; if it throws (via the `Error` channel) a `ShikumiError`
  for which `isTransient` is `True` and attempts remain, sleep `min maxDelayMs (baseDelayMs
  * 2^(attempt-1))` milliseconds (`liftIO . threadDelay . (*1000)`), then retry; otherwise
  rethrow. Catch the `Error` channel with `catchError`. Non-transient errors propagate
  immediately without consuming retries.
- `chargeBudget cfg resp`: read the response's `Usage` (see the Usage-access note in
  Interfaces and Dependencies), and if `budget cfg` is `Just b`,
  `recordCost b (usage.cost.usd)`. `chargeBudgetFromEvents` does the same from the terminal
  streaming event's `Usage`.

Add a `Timeout` path: baikai's `Options` has `timeoutMs`. If a call must enforce a wall
clock beyond baikai's own timeout, wrap the `liftIO` call with `System.Timeout.timeout`
(microseconds) and, on `Nothing`, `throwError (Timeout "...")`. Prefer relying on baikai's
`timeoutMs` where it surfaces as a `ProviderError`/`ProcessError` (already mapped); add the
explicit `System.Timeout.timeout` wrapper only if M4 testing shows baikai does not enforce
it. Document which you chose.

Tests in `/Users/shinzui/Keikaku/bokuno/shikumi/shikumi/test/ResilienceSpec.hs`:

1. **Retry recovers.** Build `failingStubRegistry ref 2 "ok"` (fails twice, then
   succeeds). Run `complete` through `runLLMResilient` with `maxAttempts = 3`,
   `baseDelayMs` small (e.g. 1) so the test is fast. Assert the result is `Right "ok"` and
   that the attempt counter in `ref` reads 3.
2. **Retry exhausts.** Same stub but `maxAttempts = 2`. Assert the result is
   `Left (ProviderFailure ...)` and `ref` reads 2 (no extra attempt).
3. **Non-transient not retried.** A stub whose `complete` throws
   `Baikai.Error.RequestInvalid "bad"` (maps to `SchemaMismatch`, not transient). With
   `maxAttempts = 5`, assert `ref` reads 1 — it was tried exactly once.
4. **Budget refuses.** A stub returning a `Response` whose `Usage.cost.usd` is, say,
   `1 % 100` (one cent). Set `budget` ceiling to `1 % 100`. The first `complete` succeeds
   (`tryReserve` sees spent 0 < cap, then records 0.01). The second `complete` is refused:
   assert `Left (BudgetExceeded ...)`. (If your stub's Usage path is hard to populate, use
   `recordCost` directly to seed the spent total at/above the cap, then assert one call is
   refused — document the variant used.)
5. **Rate limit (smoke).** With `maxInFlight = Just 1`, launch two `complete`s
   concurrently (using `Effectful.Concurrent.Async` or `forkIO` at the `IO` boundary) and
   assert both eventually return `Right ...` and that, with an instrumented stub that
   records max concurrency in a `TVar`, the observed maximum never exceeds 1. A lighter
   acceptable version asserts both complete successfully under the cap.

Acceptance: `cabal test all` runs `ResilienceSpec` and cases 1–4 pass deterministically;
case 5 passes (either the strict concurrency assertion or the lighter "both succeed under
the cap" form — note which in Progress).

### Milestone 5 — Live end-to-end call (gated, optional)

Scope: prove the same `LLM` effect drives a *real* provider, without making the default
test run depend on network or credentials. At the end there is a test (or small
executable) that, when `SHIKUMI_LIVE=1` is set and a provider API key is present, registers
a real baikai provider, runs `complete` through `runLLMResilient`, and prints the model's
text; otherwise it skips with a clear message.

Add a `LiveSpec` test (list it in `other-modules` and import its tree) guarded at runtime:

```haskell
-- pseudo-Haskell sketch:
live <- lookupEnv "SHIKUMI_LIVE"
case live of
  Just "1" -> do
    Baikai.Provider.OpenAI.Api.register      -- or Claude; pick by available key
    reg  <- pure Baikai.globalProviderRegistry
    cfg  <- mkConfig reg                       -- defaultRetryPolicy, small budget, maxInFlight 1
    out  <- runEff . runErrorNoCallStack @ShikumiError . runLLMResilient cfg $ do
              r <- complete Models.openai_gpt_4o_mini termCtx terseOpts
              pure (flattenAssistantText (flattenAssistantBlocks r))
    case out of
      Right t -> putStrLn ("LIVE: " <> unpack t) >> assertBool "non-empty" (not (T.null t))
      Left e  -> assertFailure (show e)
  _ -> putStrLn "SHIKUMI_LIVE not set; skipping live test" -- counts as pass/skip
```

Use a real catalog model from `Baikai.Models.Generated` (e.g. `openai_gpt_4o_mini` or
`anthropic_claude_haiku_4_5`), a terse system prompt, `maxTokens` small, and rely on the
provider reading its key from the environment (`OPENAI_API_KEY` / `ANTHROPIC_API_KEY`), as
baikai's getting-started documents. Keep the budget ceiling generous enough for one tiny
call.

Acceptance: with no env var, `cabal test all` prints the skip line and stays green
(hermetic CI). With `SHIKUMI_LIVE=1` and a valid key,
`SHIKUMI_LIVE=1 cabal test shikumi-test` prints a `LIVE: <model text>` line and passes,
demonstrating an end-to-end real call through the entire `Eff` + resilience stack. Capture
the transcript in this plan's Concrete Steps / Outcomes when first run.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/shikumi` unless
noted.

Pin the baikai commit for the committed `cabal.project`:

```bash
git -C /Users/shinzui/Keikaku/bokuno/baikai rev-parse HEAD
```

Paste the printed SHA into `cabal.project`'s `tag:` line.

Build everything (Milestone 1):

```bash
cabal build all
```

Expected (abridged):

```text
Resolving dependencies...
Building library for baikai-0.1.0.0...
Building library for baikai-claude-0.1.0.0...
Building library for baikai-openai-0.1.0.0...
Building library for shikumi-0.1.0.0...
```

Run the full hermetic test suite (Milestones 2–4; no network):

```bash
cabal test all
```

Expected (abridged):

```text
shikumi
  ErrorSpec
    maps ProviderError -> ProviderFailure: OK
    maps DecodeError -> InvalidJSON:       OK
    isTransient classification:            OK
  LLMSpec
    stub end-to-end returns text:          OK
    unregistered tag -> ProviderFailure:   OK
  ResilienceSpec
    retry recovers after 2 failures:       OK
    retry exhausts after maxAttempts:      OK
    non-transient not retried:             OK
    budget refuses second call:            OK
    rate limit caps concurrency:           OK

All N tests passed
```

Run the live demo (Milestone 5; needs network + key):

```bash
SHIKUMI_LIVE=1 OPENAI_API_KEY=sk-... cabal test shikumi-test
```

Expected:

```text
LIVE: Hi.
  live provider call returns text: OK
```

Without the env var:

```bash
cabal test shikumi-test
```

```text
SHIKUMI_LIVE not set; skipping live test
  live provider call returns text: OK
```


## Validation and Acceptance

The plan is complete when all of the following are observably true from the repo root:

- `cabal build all` exits 0 and builds `shikumi` plus the three baikai libraries from the
  pinned `source-repository-package` stanza. This proves the project scaffolding and the
  baikai wiring (Milestone 1).
- `cabal test all` exits 0 with `ErrorSpec`, `LLMSpec`, and `ResilienceSpec` all green and
  no network access. The decisive cases are behavioral, not structural:
  - `LLMSpec` "stub end-to-end returns text" returns exactly `Right "hello from stub"`,
    proving a value flows `call site -> send -> interpret -> baikai (isolated registry) ->
    Response -> Eff -> caller`.
  - `LLMSpec` "unregistered tag" returns `Left (ProviderFailure ...)`, proving the
    `BaikaiError -> ShikumiError` mapping fires on a genuine baikai dispatch failure.
  - `ResilienceSpec` "retry recovers" returns `Right "ok"` only after exactly 3 recorded
    attempts; "non-transient not retried" records exactly 1 attempt; "budget refuses
    second call" returns `Left (BudgetExceeded ...)`.
- With `SHIKUMI_LIVE=1` and a valid key, `cabal test shikumi-test` prints a non-empty
  `LIVE:` line and passes (Milestone 5); without it, the suite skips that case and stays
  green.

To convince yourself a test genuinely bites (not vacuously passing): temporarily change
`fromBaikaiError`'s `DecodeError` case to `ProviderFailure` and re-run — `ErrorSpec` must
fail — then restore. Temporarily set `maxAttempts = 1` in the retry-recovers test and
re-run — it must fail (`Left`, 1 attempt) — then restore.


## Idempotence and Recovery

All steps are safe to repeat. `cabal build all` and `cabal test all` are idempotent.
Writing the scaffold files is idempotent — re-running the milestone overwrites the same
files with the same content. baikai registration is idempotent per `Api` tag (calling a
provider's `register` twice keeps one handler), and the tests use isolated registries via
`newProviderRegistry`, so repeated test runs never accumulate global state. The `Budget`'s
`TVar` is created fresh per `LLMConfig`, so each test starts from zero spent.

If `cabal build all` fails to resolve baikai, confirm the `tag:` commit exists in the
baikai repo (`git -C /Users/shinzui/Keikaku/bokuno/baikai cat-file -t <sha>`); during
local development you may switch `cabal.project` to the local-path form shown in Milestone
1, but restore the `source-repository-package` form before committing. If the GHC version
drifts (baikai targets `GHC2024`, currently built with ghc912 per baikai's `cabal.project`
comment), ensure the same compiler is on `PATH`; add a `with-compiler:` line to
`cabal.project` if you want cabal to fail loudly on a mismatch.


## Interfaces and Dependencies

Libraries used and why:

- **baikai / baikai-claude / baikai-openai** — the transport layer. shikumi calls
  `Baikai.completeRequestWith` / `Baikai.streamRequestWith`, maps `Baikai.Error.BaikaiError`,
  reads `Baikai.Usage`/`Baikai.Cost`, and (in tests) builds providers with
  `Baikai.Provider.Registry.{newProviderRegistry, ApiProvider}`. Pulled via
  `source-repository-package` because baikai is not on Hackage.
- **effectful** — the runtime substrate. Modules: `Effectful` (`Eff`, `IOE`, `runEff`,
  `liftIO`, `MonadUnliftIO`), `Effectful.Dispatch.Dynamic` (`send`, `interpret`,
  `LocalEnv`), `Effectful.Error.Static` (`Error`, `throwError`, `catchError`, `runError`,
  `runErrorNoCallStack`), and optionally `Effectful.Concurrent.*` for delays/semaphores.
- **stm** — the `TVar`-based budget and (optionally) rate-limit counter.
- **aeson, lens, generic-lens, vector, text, containers** — per the canonical layout;
  used to build `Context`/`Options` values via `generic-lens` labels and to manipulate
  text/vectors of events. (Several are transitive through baikai but are listed directly so
  later modules in this package can use them.)
- **tasty, tasty-hunit** — the test runner.

Types and signatures that must exist at the end of each milestone (full module paths):

- End of M1: package `shikumi` builds; `Shikumi.Prelude` exists and compiles.
- End of M2: in `Shikumi.Error` —
  `data ShikumiError = InvalidJSON Text | MissingField Text | SchemaMismatch Text |
  ValidationFailure Text | ProviderFailure Text | Timeout Text | BudgetExceeded Text`;
  `fromBaikaiError :: Baikai.Error.BaikaiError -> ShikumiError`;
  `isTransient :: ShikumiError -> Bool`.
- End of M3: in `Shikumi.LLM` —
  `data LLM :: Effect` with constructors `Complete :: Model -> Context -> Options -> LLM m
  Response` and `Stream :: Model -> Context -> Options -> LLM m [AssistantMessageEvent]`;
  `type instance DispatchOf LLM = 'Dynamic`;
  `complete :: (LLM :> es) => Model -> Context -> Options -> Eff es Response`;
  `stream   :: (LLM :> es) => Model -> Context -> Options -> Eff es [AssistantMessageEvent]`;
  `runLLM     :: (IOE :> es, Error ShikumiError :> es) => Eff (LLM : es) a -> Eff es a`;
  `runLLMWith :: (IOE :> es, Error ShikumiError :> es) => ProviderRegistry -> Eff (LLM : es) a -> Eff es a`.
  This is **integration point #1**: `complete`/`stream`/`LLM`/`ShikumiError` are the names
  consumed by `docs/plans/3-generic-derived-signatures-and-structured-io.md`,
  `docs/plans/6-caching-subsystem.md`,
  `docs/plans/7-hierarchical-tracing-observability-and-replay.md`, and
  `docs/plans/11-typed-tools-and-react-agents.md`. They must not change shape without
  updating this plan.
- End of M4: in `Shikumi.LLM.Budget` —
  `data Budget`; `newBudget :: Maybe Rational -> IO Budget`;
  `tryReserve :: Budget -> IO Bool`; `recordCost :: Budget -> Rational -> IO ()`;
  `spentUSD :: Budget -> IO Rational`.
  In `Shikumi.LLM` —
  `data RetryPolicy`; `defaultRetryPolicy :: RetryPolicy`; `data LLMConfig`;
  `runLLMResilient :: (IOE :> es, Error ShikumiError :> es) => LLMConfig -> Eff (LLM : es) a -> Eff es a`.
- End of M5: a `LiveSpec` test gated on `SHIKUMI_LIVE`.

**Usage-access note (must resolve in M4).** baikai's `Response` record, as documented,
exposes `message`, `model`, `api`, `provider`, `responseId`, `latencyMs` — it does not
obviously carry `Usage`; baikai's streaming terminal event (`EventDone`/`EventError`)
carries the final `Usage`. Before implementing `chargeBudget`, confirm where `Usage` is
reachable for the blocking path by inspecting baikai's source (`mori registry show
shinzui/baikai --full` then read `Baikai.Response` / `Baikai.Usage`, or grep the baikai
checkout). If the blocking `Response` exposes a usage accessor, use it; otherwise drive the
budget from the streaming path's terminal `Usage` (`collectStream` already materializes the
events, so `chargeBudgetFromEvents` can read the terminal payload). Either way, the budget
charge is `usage.cost.usd :: Rational`. Record the finding in Surprises & Discoveries.

**Effect-stack ordering.** Programs in later plans will have stacks like
`Eff '[LLM, Error ShikumiError, IOE]`. The canonical run is
`runEff . runErrorNoCallStack @ShikumiError . runLLMResilient cfg $ program` (or `runLLM`
/ `runLLMWith` for the bare interpreter in tests). Document this canonical assembly so
consumers (caching/tracing) interpret `LLM` *inside* their own wrappers consistently:
caching and tracing will `reinterpret`/`interpose` on `LLM`, so they must sit above
`runLLMResilient` in the stack.


## Revision Notes

(No revisions yet — initial authoring.)
