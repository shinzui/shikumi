---
id: 49
slug: shared-test-harness-and-fixture-diversification
title: "Shared Test Harness and Fixture Diversification"
kind: exec-plan
created_at: 2026-07-02T03:30:16Z
intention: "intention_01kwjfeb1pe8qbvb8vx7v1xdx0"
master_plan: "docs/masterplans/9-ci-and-shared-test-infrastructure.md"
---

# Shared Test Harness and Fixture Diversification

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

The repository maintains three near-identical, hand-copied implementations of the same
idea — a deterministic, network-free stand-in for a language model ("stub LM") that
answers the `LLM` effect from a pure function or a fixed script — in
`shikumi-cli/src/Shikumi/Cli/Runtime.hs`, `shikumi-jitsurei/src/Shikumi/Jitsurei/Stub.hs`,
and `shikumi-tools/test/MockLLM.hs`. Each copy drifts independently, and a
production-readiness review found that the *fixtures* every suite tests against sit
squarely in bug blind spots: every optimizer fixture is a signature with an empty
instruction, program fixtures use only `Validatable` instances that can never fail,
`majorityVote` is exercised only with the temperature schedule `TempFixed [0.0]`, and the
glob tool sees only `**/`-prefixed patterns.

After this plan, a new internal package `shikumi-testing` is the single home for the stub
LM (one responder-driven interpreter, one script-replay interpreter, counting and
error-injecting wrappers, and the marker-format response builders), and all three call
sites consume it — so a fix or extension to the harness lands once. The same package
exports deliberately non-trivial shared fixtures: a signature whose instruction is not
empty, an output type whose `Validatable` rule really rejects bad values, a two-stage
composed program with a responder that answers each stage differently, a multi-value
temperature schedule, and a diversified glob-pattern list. You can see it working by
running `cabal build all && cabal test all` in the dev shell (everything still green,
plus a new `shikumi-testing-test` suite proving the fixtures' properties) and by running
any `shikumi-jitsurei` example, which now executes through the shared harness.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M1: create `shikumi-testing/` (cabal file, `src/Shikumi/Testing/Response.hs`, `src/Shikumi/Testing/StubLLM.hs`, `src/Shikumi/Testing/Fixtures.hs`, `src/Shikumi/Testing.hs`).
- [ ] M1: add `shikumi-testing` to `cabal.project`; `cabal build shikumi-testing` succeeds.
- [ ] M1: write `shikumi-testing/test/Main.hs`; `cabal test shikumi-testing` passes.
- [ ] M1: add `shikumi-testing` to the internal-packages table in `agents/skills/release/SKILL.md`.
- [ ] M1: commit with the required trailers.
- [ ] M2: turn `shikumi-jitsurei/src/Shikumi/Jitsurei/Stub.hs` into a re-export shim; run all 12 examples.
- [ ] M2: commit.
- [ ] M3: migrate `shikumi-cli/src/Shikumi/Cli/Runtime.hs`; `cabal test shikumi-cli` passes.
- [ ] M3: commit.
- [ ] M4: delete `shikumi-tools/test/MockLLM.hs`; update the 13 importing spec files; `cabal test shikumi-tools` passes.
- [ ] M4: full `cabal test all` green; commit.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

- Decision: `shikumi-testing` is a proper cabal package listed in `cabal.project`, not a
  vendored test module, and it is internal (never published to Hackage).
  Rationale: three separate packages must depend on it (a `shikumi-cli` library module, a
  `shikumi-jitsurei` library module, and `shikumi-tools`' test suite), and cabal offers no
  cross-package module sharing short of a package. It joins `shikumi-cli` and
  `shikumi-jitsurei` in the "NOT released" table of `agents/skills/release/SKILL.md`.
  Date: 2026-07-01

- Decision: canonical names in the shared harness are `runStubLLM` (responder-driven),
  `runScriptLLM` (script replay), `runCountingLLM`, `runScriptLLMThrowingOn` /
  `runScriptLLMThrowingOnce`, and `runEffScript`; the `shikumi-tools` names `runMockLLM`,
  `runMockLLMThrowingOn(ce)`, and `runEffMock` are renamed at their call sites rather than
  aliased.
  Rationale: "mock" and "script" named the same thing in different packages; one name per
  concept keeps the shared package's export surface unambiguous, and the call-site rename
  is mechanical because the import line must change anyway.
  Date: 2026-07-01

- Decision: `Shikumi.Jitsurei.Stub` survives as a thin re-export module with an unchanged
  export list instead of being deleted.
  Rationale: eleven `shikumi-jitsurei/app/*.hs` example mains import it, and the examples
  double as documentation whose imports (`Shikumi.Jitsurei.Stub`) are described in the
  package's own haddocks and README-mirroring prose; a shim keeps every example diff-free
  and guarantees the extraction cannot break them.
  Date: 2026-07-01

- Decision: this plan does NOT touch `shikumi-cache-redis/test/Main.hs` or
  `shikumi-cache-postgres/test/Main.hs`, even though their duplicated `runCountingLLM` is
  exactly what `Shikumi.Testing.StubLLM.runCountingLLM` extracts.
  Rationale: plan 48 (docs/plans/48-github-actions-ci-pipeline.md) edits those two files
  for the CI skip-fail contract; disjoint file sets keep the two plans conflict-free.
  Adopting the shared counting stub there is cheap follow-up work after both plans land.
  Date: 2026-07-01

- Decision: accept that `shikumi-tools` (a Hackage-published package) gains a test-suite
  dependency on the unpublished `shikumi-testing`.
  Rationale: Hackage uploads are not blocked by test-suite dependencies, and this repo's
  release flow builds from the repo where the package is present; the cost is that a
  downstream user running `cabal build --enable-tests shikumi-tools` from a Hackage
  tarball cannot resolve the test suite. Recorded as a caveat next to the internal-packages
  table in `agents/skills/release/SKILL.md`. The alternative — leaving `MockLLM.hs`
  duplicated — recreates the drift this plan exists to end.
  Date: 2026-07-01

- Decision: the shared fixtures' *properties* are tested inside `shikumi-testing`'s own
  suite (e.g. `validate` really rejects an out-of-range confidence; the two-stage program
  decodes end-to-end under its responder), but the bug-exposing regression tests for known
  runtime/optimizer bugs are explicitly out of scope.
  Rationale: those tests assert post-fix behavior owned by
  docs/plans/32-fix-validatable-dispatch-in-program-runners.md (master plan 5) and
  docs/plans/36-fix-optimizer-instruction-seeding.md (master plan 6). This plan provides
  the shapes they consume; see Interfaces and Dependencies.
  Date: 2026-07-01


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

shikumi is a thirteen-package cabal project (packages listed in `cabal.project` at the
repo root). Everything builds inside the Nix dev shell — enter it with
`nix develop .#ghc9124` at the repo root; the system `ghc` is the wrong compiler.
Formatting is fourmolu (config in `fourmolu.yaml`: 2-space indent, trailing arrows/commas,
single-line haddock) enforced by a treefmt pre-commit hook; run `nix fmt` before
committing.

The `LLM` effect (defined in `shikumi/src/Shikumi/LLM.hs`, an `effectful` dynamic effect
with operations `Complete` and `Stream`) is the framework's only seam to a real model
provider. A "stub LM" is an interpreter of that effect that answers `Complete` from pure
data instead of the network. Two response shapes cover every consumer: a *marker
response* — the `[[ ## fieldName ## ]]` sectioned text body the prompt-fallback adapter
decodes into typed outputs, terminated by `[[ ## completed ## ]]` — and *agent turns*
(a plain assistant text block, or a native tool-call block).

The three duplicated implementations this plan unifies:

`shikumi-jitsurei/src/Shikumi/Jitsurei/Stub.hs` (the most complete copy, 162 lines) —
exports `markerResponse`, `mkTextResponse`, `mkToolCallResponse`, `runStub`,
`runStubEval`, `runStubLLM`, `runAgent`, `runScriptLLM`, `systemContains`. Eleven example
mains under `shikumi-jitsurei/app/` import it (`Predict.hs`, `Compose.hs`,
`Combinators.hs`, `Evaluate.hs`, `Optimize.hs`, `ReActAgent.hs`, `TraceReplay.hs`,
`Multimodal.hs`, `Adapters.hs`, `CodeExec.hs`, plus `Main.hs` which only prints an
index).

`shikumi-cli/src/Shikumi/Cli/Runtime.hs` — a private `runStubLLM` (lines 47–50) and an
exported `markerResponse` (lines 102–111) identical in behavior to the jitsurei ones,
plus `runStubEval`/`runStubProgram` (duplicates of jitsurei's `runStub`/`runStubEval`
under other names) and two genuinely CLI-specific functions that stay put:
`runReplayProgram` and `recordTrace` (they depend on `shikumi-trace`).
`Shikumi.Cli.Example` imports `markerResponse`; `Shikumi.Cli.Run` and
`shikumi-cli/test/Main.hs` import the four runners.

`shikumi-tools/test/MockLLM.hs` — exports `runMockLLM`, `runMockLLMThrowingOnce`,
`runMockLLMThrowingOn`, `runEffMock`, `runAgent`, `mkTextResponse`, `mkUsageResponse`,
`mkToolCallResponse`. `runMockLLM` is jitsurei's `runScriptLLM` under another name; the
throwing variants (throw a `ShikumiError` on selected 1-based completion calls) and
`mkUsageResponse` (a text response carrying a model and token usage) exist only here and
move into the shared package. Thirteen spec files import it: `AcceptanceSpec.hs`,
`BuiltinAcceptanceSpec.hs`, `CodeActSpec.hs`, `CompactionSpec.hs`, `EnvSpec.hs`,
`Fixtures.hs`, `FsSpec.hs`, `ProgramOfThoughtSpec.hs`, `ProtocolSpec.hs`, `ReActSpec.hs`,
`ShellSpec.hs`, `ToolSpec.hs`, `WebSpec.hs` (all under `shikumi-tools/test/`). It is
listed under `other-modules` in `shikumi-tools/shikumi-tools.cabal` (line 93).

The fixture blind spots this plan's shared fixtures address (evidence paths from the
review, verified 2026-07-01): `shikumi-optimize/test/StubLM.hs:129` defines
`sentimentSig = mkSignature ""` — an empty instruction, so instruction-seeding bugs are
invisible; the repo-wide default `instance {-# OVERLAPPABLE #-} Validatable a` in
`shikumi/src/Shikumi/Schema.hs` (the class is `validate :: a -> Either Text a`,
defaulting to `Right`) means existing program fixtures can never fail validation;
`shikumi/test/CombinatorSpec.hs:135` tests `majorityVote` only with
`sched1 = TempFixed [0.0]` (and `shikumi-trace/test/Main.hs:464` with `TempFixed []`);
`shikumi-tools/test/FsSpec.hs:68-74` exercises the glob tool only with `**/*.txt`.

`shikumi-cache/shikumi-cache.cabal` is the style template for the new package: cabal
3.4, a `common common-options` stanza with the standard warning set
(`-Wall -Wcompat -Widentities -Wincomplete-uni-patterns -Wincomplete-record-updates
-Wredundant-constraints -fhide-source-paths -Wmissing-export-lists -Wpartial-fields
-Wmissing-deriving-strategies`), `default-language: GHC2024`, and a small
`default-extensions` list.


## Plan of Work

Four milestones: create the package, then migrate the three call sites one per milestone
(jitsurei, cli, tools), keeping `cabal test all` green after each. Additive first, then
subtraction — at no point is a consumer broken while its provider is missing.

Every commit must use a Conventional Commits subject line and carry these trailers:

```text
MasterPlan: docs/masterplans/9-ci-and-shared-test-infrastructure.md
ExecPlan: docs/plans/49-shared-test-harness-and-fixture-diversification.md
Intention: intention_01kwjfeb1pe8qbvb8vx7v1xdx0
```

### Milestone 1 — the `shikumi-testing` package

Scope: a new top-level directory `shikumi-testing/` containing the cabal file, four
library modules, and a test suite; plus one line in `cabal.project` and a row in the
release skill's internal table. At the end, `cabal build shikumi-testing` and
`cabal test shikumi-testing` succeed and nothing else has changed.

Create `shikumi-testing/shikumi-testing.cabal`:

```cabal
cabal-version:   3.4
name:            shikumi-testing
version:         0.1.0.0
synopsis:        Shared offline test harness and fixtures for shikumi (internal)
category:        AI
description:
  The single home for shikumi's deterministic, network-free stub LM — a
  responder-driven interpreter, a script-replay interpreter, counting and
  error-injecting wrappers, and the marker-format response builders — plus
  deliberately non-trivial shared fixtures (a non-empty-instruction signature,
  an output type whose @Validatable@ rule can fail, a two-stage program) that
  every package's tests can regression-test against.
  .
  Internal to the repository: not published to Hackage.

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

  default-language:   GHC2024
  default-extensions:
    DeriveAnyClass
    DuplicateRecordFields
    OverloadedLabels
    OverloadedStrings

library
  import:          common-options
  hs-source-dirs:  src
  exposed-modules:
    Shikumi.Testing
    Shikumi.Testing.Fixtures
    Shikumi.Testing.Response
    Shikumi.Testing.StubLLM

  build-depends:
    , aeson
    , baikai        >=0.2  && <0.3
    , base          >=4.20 && <5
    , effectful
    , generic-lens
    , lens          ^>=5.3
    , shikumi       ^>=0.2.0.0
    , text          ^>=2.1
    , vector

test-suite shikumi-testing-test
  import:         common-options
  type:           exitcode-stdio-1.0
  hs-source-dirs: test
  main-is:        Main.hs
  ghc-options:    -threaded -with-rtsopts=-N
  build-depends:
    , base
    , shikumi          ^>=0.2.0.0
    , shikumi-testing  ^>=0.1.0.0
    , tasty
    , tasty-hunit
    , text
```

`shikumi-testing/src/Shikumi/Testing/Response.hs` is the response-builder module. Its
content is a merge of existing code, moved verbatim: `markerResponse` from
`shikumi-jitsurei/src/Shikumi/Jitsurei/Stub.hs` lines 72–81 (identical to the copy at
`shikumi-cli/src/Shikumi/Cli/Runtime.hs` lines 102–111 — including the fixed usage
numbers 18/5 and `latencyMs` 4, which several trace assertions rely on), and
`mkTextResponse`, `mkUsageResponse`, `mkToolCallResponse` from
`shikumi-tools/test/MockLLM.hs` lines 110–129 (jitsurei's `mkTextResponse` /
`mkToolCallResponse` are the same code). Module header and export list:

```haskell
-- | Builders for the stub 'Response' shapes shikumi tests script:
-- prompt-fallback marker bodies and agent turns (text / native tool-call).
module Shikumi.Testing.Response
  ( markerResponse,
    mkTextResponse,
    mkUsageResponse,
    mkToolCallResponse,
  )
where
```

Its imports are the union of the source files' relevant imports (`Baikai` value/lens
constructors, `Control.Lens ((&), (.~))`, `Data.Generics.Labels ()`, `Data.Aeson
(Value)`, `Data.Text`, `Data.Vector qualified`, `Numeric.Natural`).

`shikumi-testing/src/Shikumi/Testing/StubLLM.hs` is the interpreter module:

```haskell
-- | Deterministic, network-free interpreters of shikumi's @LLM@ effect: a
-- responder function, a scripted replay, and counting / error-injecting
-- wrappers, plus ready-made effect stacks for programs, agents, and eval runs.
module Shikumi.Testing.StubLLM
  ( -- * Interpreters
    runStubLLM,
    runScriptLLM,
    runCountingLLM,
    runScriptLLMThrowingOn,
    runScriptLLMThrowingOnce,

    -- * Ready-made stacks
    runStub,
    runStubEval,
    runEffScript,
    runAgent,

    -- * Inspecting requests inside a responder
    systemContains,
  )
where
```

The bodies move verbatim with only renames: `runStubLLM`, `runScriptLLM`, `runStub`,
`runStubEval`, `runAgent`, `systemContains` from
`shikumi-jitsurei/src/Shikumi/Jitsurei/Stub.hs` (lines 104–161);
`runScriptLLMThrowingOn` / `runScriptLLMThrowingOnce` are `runMockLLMThrowingOn` /
`runMockLLMThrowingOnce` from `shikumi-tools/test/MockLLM.hs` lines 55–84 renamed;
`runEffScript` is `runEffMock` from lines 89–93 renamed (keep its haddock, adjusting the
name). `runCountingLLM` is new to the shared package but copied from the identical
private helpers in `shikumi-cache-redis/test/Main.hs` lines 48–51 /
`shikumi-cache-postgres/test/Main.hs` lines 44–47:

```haskell
-- | Answer every completion with a fixed 'Response', bumping a counter — the
-- shape cache MISS/HIT tests assert against. (The cache backend suites carry a
-- private copy; see docs/plans/49-… Decision Log for why they are not migrated here.)
runCountingLLM :: (IOE :> es) => IORef Int -> Response -> Eff (LLM : es) a -> Eff es a
runCountingLLM ref resp = interpret $ \_ -> \case
  Complete {} -> liftIO (modifyIORef' ref (+ 1)) >> pure resp
  Stream {} -> pure []
```

`shikumi-testing/src/Shikumi/Testing/Fixtures.hs` is the new, deliberately non-trivial
fixture module — this file is new code, so it is given in full:

```haskell
-- | Deliberately NON-trivial shared fixtures. The production-readiness review
-- found every suite's fixtures sit in bug blind spots: optimizer signatures
-- with empty instructions, output types whose 'Validatable' never fails,
-- single-node-only programs, @TempFixed [0.0]@ schedules, and @**/@-only glob
-- patterns. These fixtures occupy exactly those spots so any package can
-- regression-test against them. The bug-exposing tests that consume them are
-- owned by docs/plans/32-fix-validatable-dispatch-in-program-runners.md and
-- docs/plans/36-fix-optimizer-instruction-seeding.md; the fixture SHAPES are
-- owned here — extend, don't fork.
module Shikumi.Testing.Fixtures
  ( -- * Task records
    Question (..),
    Draft (..),
    Answer (..),

    -- * Signatures and programs (instructions are non-empty)
    instructedSig,
    draftSig,
    reviseSig,
    instructedProg,
    twoStageProg,

    -- * Responders and responses
    twoStageResponder,
    validAnswerResponse,
    invalidAnswerResponse,

    -- * Diversified parameter fixtures
    diverseTemps,
    diverseGlobPatterns,
  )
where

import Baikai (Context, Response)
import Data.Aeson (ToJSON)
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Generics (Generic)
import Shikumi.Adapter (ToPrompt)
import Shikumi.Combinator (TempSchedule (..), (>>>))
import Shikumi.Module (predict)
import Shikumi.Program (Program)
import Shikumi.Schema (FromModel, ToSchema, Validatable (..))
import Shikumi.Signature (Signature, mkSignature)
import Shikumi.Testing.Response (markerResponse)
import Shikumi.Testing.StubLLM (systemContains)

-- | The fixture input: a question to answer.
newtype Question = Question {question :: Text}
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToJSON)

instance ToSchema Question

instance FromModel Question

instance ToPrompt Question

instance Validatable Question

-- | The two-stage pipeline's intermediate value: a draft answer.
newtype Draft = Draft {draft :: Text}
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToJSON)

instance ToSchema Draft

instance FromModel Draft

instance ToPrompt Draft

instance Validatable Draft

-- | The fixture output. Unlike every pre-existing fixture, its 'Validatable'
-- rule can FAIL: decodes with an empty answer or a confidence outside [0,1]
-- are rejected, so tests can prove validation is (or is not) being dispatched.
data Answer = Answer
  { answer :: Text,
    confidence :: Double
  }
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToJSON)

instance ToSchema Answer

instance FromModel Answer

instance ToPrompt Answer

instance Validatable Answer where
  validate a@Answer {answer = ans, confidence = conf}
    | T.null (T.strip ans) = Left "answer must be non-empty"
    | conf < 0 || conf > 1 = Left "confidence must be within [0,1]"
    | otherwise = Right a

-- | A single-node signature whose instruction is NOT empty — the shape
-- instruction-seeding tests need (contrast @sentimentSig = mkSignature \"\"@ in
-- shikumi-optimize/test/StubLM.hs).
instructedSig :: Signature Question Answer
instructedSig =
  mkSignature "Answer the question in one short sentence and report a confidence between 0 and 1."

-- | Stage one of the two-stage program.
draftSig :: Signature Question Draft
draftSig = mkSignature "Draft a short answer to the question."

-- | Stage two of the two-stage program.
reviseSig :: Signature Draft Answer
reviseSig = mkSignature "Revise the draft into a final answer with a confidence between 0 and 1."

-- | The single-node program over 'instructedSig'.
instructedProg :: Program Question Answer
instructedProg = predict instructedSig

-- | A multi-node, two-stage program: draft, then revise. Composed with EP-5's
-- @(>>>)@, so node-indexed behavior (tracing, optimization, validation) has
-- more than one node to get wrong.
twoStageProg :: Program Question Answer
twoStageProg = predict draftSig >>> predict reviseSig

-- | Answers each stage of 'twoStageProg' differently, keyed on the stage
-- instruction rendered into the system prompt.
twoStageResponder :: Context -> Response
twoStageResponder ctx
  | systemContains "Draft a short answer" ctx = markerResponse [("draft", "It is forty-two.")]
  | otherwise = validAnswerResponse

-- | Decodes to an 'Answer' that passes 'validate'.
validAnswerResponse :: Response
validAnswerResponse = markerResponse [("answer", "It is forty-two."), ("confidence", "0.9")]

-- | Decodes structurally to an 'Answer' whose confidence 1.5 must be REJECTED
-- by 'validate' — the probe for validation dispatch.
invalidAnswerResponse :: Response
invalidAnswerResponse = markerResponse [("answer", "It is forty-two."), ("confidence", "1.5")]

-- | A temperature schedule with distinct, non-zero temperatures (contrast the
-- @TempFixed [0.0]@ / @TempFixed []@ the existing vote tests use).
diverseTemps :: TempSchedule
diverseTemps = TempFixed [0.0, 0.3, 0.9]

-- | Glob patterns beyond the @**/@-prefixed shape the existing glob tests use.
diverseGlobPatterns :: [Text]
diverseGlobPatterns = ["*.txt", "src/**/*.hs", "docs/*.md", "README.*", "**/*.yaml"]
```

(The `validate` instance destructures the record rather than using field selectors or
record-dot syntax, so it compiles under `DuplicateRecordFields` with no extra
extension.)

`shikumi-testing/src/Shikumi/Testing.hs` is the umbrella consumers import:

```haskell
-- | One-stop import for shikumi's shared offline test harness.
module Shikumi.Testing
  ( module Shikumi.Testing.Response,
    module Shikumi.Testing.StubLLM,
    module Shikumi.Testing.Fixtures,
  )
where

import Shikumi.Testing.Fixtures
import Shikumi.Testing.Response
import Shikumi.Testing.StubLLM
```

`shikumi-testing/test/Main.hs` proves the fixtures' properties directly (deliberately
NOT via `runProgram`'s validation path, which plan 32 owns and will change): a tasty
suite asserting (1) `getInstruction instructedSig` is non-empty (import
`Shikumi.Signature (getInstruction)`); (2) `validate (Answer "x" 1.5)` and
`validate (Answer "" 0.5)` are `Left` while `validate (Answer "x" 0.9)` is `Right`;
(3) `runStub twoStageResponder twoStageProg (Question "What is six times seven?")`
returns `Right` an `Answer` whose `answer` is `"It is forty-two."` — proving the
two-stage program really round-trips through both stages of the shared stub; and
(4) `diverseTemps` and `diverseGlobPatterns` are non-degenerate (length ≥ 3, at least
one pattern not starting with `**/`). Use `defaultMain`, `testGroup`, `testCase`,
`(@?=)` mirroring `shikumi-cache/test/Main.hs`'s style.

Then add the package to the build set: in `cabal.project`, insert `  shikumi-testing`
into the `packages:` list between `shikumi-optimize` and `shikumi-tools`. Finally add a
row to the "NOT released (internal)" table in `agents/skills/release/SKILL.md`:
`shikumi-testing` / `shikumi-testing/` / "Internal: shared offline test harness and
fixtures; test-suite-only consumer in published packages", and a one-sentence caveat
beneath the table that published packages' *test suites* may depend on it (test-suite
deps do not block Hackage uploads, but `--enable-tests` builds from Hackage tarballs
will not resolve).

Acceptance: `cabal build shikumi-testing` compiles warning-free; `cabal test
shikumi-testing` passes; `nix fmt` makes no changes (format as you go); `cabal build
all` still succeeds (no other package is affected yet).

### Milestone 2 — migrate `shikumi-jitsurei`

Scope: `shikumi-jitsurei/src/Shikumi/Jitsurei/Stub.hs` becomes a re-export shim with an
byte-identical export list, so none of the eleven example mains changes. In
`shikumi-jitsurei/shikumi-jitsurei.cabal`, add `shikumi-testing` to the library's
`build-depends` and remove the now-unused direct deps of the old implementation from the
*library* stanza only (`aeson`, `baikai`, `effectful`, `generic-lens`, `lens`, `vector`
— keep `base`, `shikumi`, `text` if still referenced; let the compiler's warnings and
`cabal build` errors be the guide, and do not touch the executables' stanzas). Replace
the module body so it reads, in full:

```haskell
-- | The shared offline harness for the @shikumi-jitsurei@ examples — now a
-- thin re-export of the repo-wide harness in @shikumi-testing@
-- ("Shikumi.Testing"), kept so every example's import line still works.
module Shikumi.Jitsurei.Stub
  ( -- * Building stub responses
    markerResponse,
    mkTextResponse,
    mkToolCallResponse,

    -- * Running a program offline
    runStub,
    runStubEval,
    runStubLLM,

    -- * Running an agent against a scripted LM
    runAgent,
    runScriptLLM,

    -- * Inspecting the request inside a responder
    systemContains,
  )
where

import Shikumi.Testing
  ( markerResponse,
    mkTextResponse,
    mkToolCallResponse,
    runAgent,
    runScriptLLM,
    runStub,
    runStubEval,
    runStubLLM,
    systemContains,
  )
```

Acceptance: `cabal build shikumi-jitsurei` succeeds and all twelve executables run and
exit 0 (loop below in Concrete Steps) with output identical to before the migration —
the examples are deterministic, so you can capture `cabal run -v0 jitsurei-predict`
before and after and `diff` the transcripts.

### Milestone 3 — migrate `shikumi-cli`

Scope: `shikumi-cli/src/Shikumi/Cli/Runtime.hs` keeps its export list
(`runStubEval`, `runStubProgram`, `runReplayProgram`, `recordTrace`, `markerResponse`)
but drops its private copies. Delete the local `runStubLLM`, `markerResponse`,
`runStubEval`, and `runStubProgram` definitions; import
`Shikumi.Testing (markerResponse, runStub, runStubEval, runStubLLM)` and re-export
`markerResponse` and `runStubEval` directly; define
`runStubProgram = runStub` (keep the existing haddock — the name
`runStubProgram` stays because `Shikumi.Cli.Run` and `shikumi-cli/test/Main.hs` import
it). `runReplayProgram` and `recordTrace` stay as-is; `recordTrace` still uses the
imported `runStubLLM`. Prune imports that the deletions orphan (`Control.Lens`,
`Data.Vector`, the `Baikai` response constructors, `Data.Generics.Labels`,
`Data.Text qualified as T` …) until the module is warning-free, and drop any
library `build-depends` in `shikumi-cli/shikumi-cli.cabal` that `cabal build` proves
unused, adding `shikumi-testing`.

Acceptance: `cabal build shikumi-cli` warning-free; `cabal test shikumi-cli` passes;
`cabal run shikumi -- --help` (the bundled example executable) still prints its usage.

### Milestone 4 — migrate `shikumi-tools`

Scope: delete `shikumi-tools/test/MockLLM.hs`; remove `MockLLM` from `other-modules` in
`shikumi-tools/shikumi-tools.cabal` (line 93) and add `shikumi-testing` to the
test-suite's `build-depends`. In each of the thirteen spec files that import it
(`AcceptanceSpec.hs`, `BuiltinAcceptanceSpec.hs`, `CodeActSpec.hs`, `CompactionSpec.hs`,
`EnvSpec.hs`, `Fixtures.hs`, `FsSpec.hs`, `ProgramOfThoughtSpec.hs`, `ProtocolSpec.hs`,
`ReActSpec.hs`, `ShellSpec.hs`, `ToolSpec.hs`, `WebSpec.hs`), change
`import MockLLM (…)` to `import Shikumi.Testing (…)` and apply the rename table at every
import and use site — the only renames are `runMockLLM → runScriptLLM`,
`runMockLLMThrowingOnce → runScriptLLMThrowingOnce`,
`runMockLLMThrowingOn → runScriptLLMThrowingOn`, `runEffMock → runEffScript`;
`runAgent`, `mkTextResponse`, `mkUsageResponse`, and `mkToolCallResponse` keep their
names. `CompactionSpec.hs` is the only file using the throwing variants (uses at lines
115, 139, 161).

Acceptance: `cabal test shikumi-tools` passes with the same test count as before the
change, and `git grep -l "MockLLM"` returns nothing under `shikumi-tools/`.


## Concrete Steps

All commands run at the repository root inside the dev shell (`nix develop .#ghc9124`).
Steps are ordered; each milestone ends green.

Milestone 1:

```bash
mkdir -p shikumi-testing/src/Shikumi/Testing shikumi-testing/test
# create the five files per Plan of Work, then:
# edit cabal.project: add "  shikumi-testing" to the packages list
nix fmt
cabal build shikumi-testing
cabal test shikumi-testing
```

Expected tail of the test run:

```text
Test suite shikumi-testing-test: RUNNING...
shikumi-testing
  fixtures
    instructedSig has a non-empty instruction:            OK
    validate rejects out-of-range confidence:             OK
    validate rejects an empty answer:                     OK
    validate accepts a well-formed Answer:                OK
    twoStageProg round-trips under twoStageResponder:     OK
    diversified temps and globs are non-degenerate:       OK

All 6 tests passed (0.01s)
Test suite shikumi-testing-test: PASS
```

Commit:

```bash
git add shikumi-testing cabal.project agents/skills/release/SKILL.md
git commit -m "feat(testing): add shikumi-testing shared stub-LM harness and non-trivial fixtures" \
  -m "MasterPlan: docs/masterplans/9-ci-and-shared-test-infrastructure.md" \
  -m "ExecPlan: docs/plans/49-shared-test-harness-and-fixture-diversification.md" \
  -m "Intention: intention_01kwjfeb1pe8qbvb8vx7v1xdx0"
```

Milestone 2 (capture a before-transcript first):

```bash
cabal run -v0 jitsurei-predict > /tmp/predict.before 2>&1 || true
# edit shikumi-jitsurei/src/Shikumi/Jitsurei/Stub.hs and shikumi-jitsurei.cabal per Plan of Work
nix fmt && cabal build shikumi-jitsurei
for exe in shikumi-jitsurei jitsurei-predict jitsurei-compose jitsurei-combinators \
           jitsurei-evaluate jitsurei-optimize jitsurei-react jitsurei-trace-replay \
           jitsurei-multimodal jitsurei-streaming jitsurei-adapters jitsurei-codeexec; do
  echo "=== $exe"; cabal run -v0 "$exe" || exit 1
done
cabal run -v0 jitsurei-predict > /tmp/predict.after 2>&1
diff /tmp/predict.before /tmp/predict.after && echo "identical"
```

Expected: twelve `=== …` sections each followed by the example's deterministic output,
and `identical`. Commit as `refactor(jitsurei): re-export the stub harness from
shikumi-testing` with the three trailers.

Milestone 3:

```bash
# edit shikumi-cli/src/Shikumi/Cli/Runtime.hs and shikumi-cli.cabal per Plan of Work
nix fmt && cabal build shikumi-cli && cabal test shikumi-cli
```

Expected: `Test suite shikumi-cli-test: PASS`. Commit as `refactor(cli): consume the
shared stub harness from shikumi-testing` with the trailers.

Milestone 4:

```bash
git rm shikumi-tools/test/MockLLM.hs
# edit shikumi-tools.cabal and the 13 spec files per Plan of Work; the renames are mechanical:
grep -rn "runMockLLM\|runEffMock\|MockLLM" shikumi-tools/test/   # must end up empty
nix fmt && cabal test shikumi-tools
cabal test all
```

Expected: every suite reports `PASS` (the Redis suite may print
`[SKIP] shikumi-cache-redis: …` if no local Redis is running — that skip is governed by
plan 48's `SHIKUMI_REQUIRE_BACKENDS` contract and is fine locally). Commit as
`refactor(tools): replace test MockLLM with shikumi-testing harness` with the trailers.


## Validation and Acceptance

The change is internal plumbing plus new fixtures, so its effect is demonstrated three
ways. First, deduplication is observable: after Milestone 4,
`grep -rn "interpret" shikumi-jitsurei/src shikumi-cli/src shikumi-tools/test` finds no
stub-LM interpreter definitions outside `shikumi-testing/src` (the jitsurei shim
contains only re-exports; `Shikumi.Cli.Runtime` keeps no `interpret` call of its own),
and `shikumi-tools/test/MockLLM.hs` no longer exists. Second, behavior is preserved: `cabal test all` inside the dev shell passes with
the same suites and test counts as before the plan; every one of the twelve
`shikumi-jitsurei` executables exits 0 with byte-identical output (the `diff` check in
Concrete Steps). Third, the new fixtures demonstrably occupy the blind spots:
`cabal test shikumi-testing` shows `validate` really rejecting `confidence = 1.5` and an
empty answer (a `Left`, where every pre-existing fixture type could only produce
`Right`), and shows a two-node program decoding end-to-end under the shared responder.
If plan 48's CI is already live, the same evidence appears in the workflow run for this
plan's commits — including `shikumi-testing-test` in the `cabal test all` job.

Failure signatures to recognize: a `Could not resolve dependency shikumi-testing` error
means the `cabal.project` edit was missed; an "ambiguous occurrence" error in a tools
spec means a rename was applied to the import but not a use site (or vice versa); an
example whose output changed means the shim's re-exports silently picked up a
behavioral difference — stop and compare the moved code against the git history of the
deleted original before proceeding.


## Idempotence and Recovery

Every milestone is an ordinary git-tracked source change; re-running any build, test,
`nix fmt`, or example command is side-effect free (examples write only under
system temp dirs via the `temporary` package). Milestones land as separate commits, so a
bad migration is recovered by `git revert` of that one commit — the shim/rename design
means no other package's source refers to moved internals directly. If Milestone 4's
mechanical renames go wrong midway, `git checkout -- shikumi-tools/test` restores the
suite wholesale and the milestone can restart; nothing in Milestones 1–3 depends on it.


## Interfaces and Dependencies

The package dependency picture at the end: `shikumi-testing` (library) depends on
`shikumi` (for `Shikumi.LLM`, `Shikumi.Program`, `Shikumi.Module`, `Shikumi.Combinator`,
`Shikumi.Signature`, `Shikumi.Schema`, `Shikumi.Adapter`, `Shikumi.Effect.Time`,
`Shikumi.Error`), `baikai` (the `Context`/`Response` wire types and their lens
constructors), `effectful`, `lens`, `generic-lens`, `aeson`, `text`, `vector`, `base`.
It must never depend on `shikumi-trace`, `shikumi-tools`, or any other downstream
package — those packages' tests depend on it, and a cycle would be unbuildable. Consumers
gained: `shikumi-jitsurei` (library), `shikumi-cli` (library), `shikumi-tools`
(test-suite only).

Signatures that must exist in `Shikumi.Testing` at the end of Milestone 1 (all
re-exported by the umbrella module):

```haskell
markerResponse :: [(Text, Text)] -> Response
mkTextResponse :: Text -> Response
mkUsageResponse :: Model -> Natural -> Text -> Response
mkToolCallResponse :: Text -> Text -> Value -> Response

runStubLLM :: (Context -> Response) -> Eff (LLM : es) a -> Eff es a
runScriptLLM :: (IOE :> es) => [Response] -> Eff (LLM : es) a -> Eff es a
runCountingLLM :: (IOE :> es) => IORef Int -> Response -> Eff (LLM : es) a -> Eff es a
runScriptLLMThrowingOn :: (IOE :> es, Error ShikumiError :> es) => [Int] -> ShikumiError -> [Response] -> Eff (LLM : es) a -> Eff es a
runScriptLLMThrowingOnce :: (IOE :> es, Error ShikumiError :> es) => ShikumiError -> [Response] -> Eff (LLM : es) a -> Eff es a
runStub :: (Context -> Response) -> Program i o -> i -> IO (Either ShikumiError o)
runStubEval :: (Context -> Response) -> Eff '[LLM, Concurrent, Error ShikumiError, Time, Prim, IOE] a -> IO (Either ShikumiError a)
runEffScript :: [Response] -> Eff '[LLM, Error ShikumiError, IOE] a -> IO (Either ShikumiError a)
runAgent :: [Response] -> Program i o -> i -> IO (Either ShikumiError o)
systemContains :: Text -> Context -> Bool

instructedSig :: Signature Question Answer
draftSig :: Signature Question Draft
reviseSig :: Signature Draft Answer
instructedProg :: Program Question Answer
twoStageProg :: Program Question Answer
twoStageResponder :: Context -> Response
validAnswerResponse, invalidAnswerResponse :: Response
diverseTemps :: TempSchedule
diverseGlobPatterns :: [Text]
```

Cross-initiative integration (soft dependency, both directions — the fixture shapes are
the shared artifact and this plan owns them): the exposing regression tests for the
known bugs are owned elsewhere and must consume these fixtures rather than fork them.
`docs/plans/32-fix-validatable-dispatch-in-program-runners.md` (master plan
`docs/masterplans/5-core-runtime-correctness-and-wire-fidelity.md`) is expected to drive
`instructedProg` / `twoStageProg` with `invalidAnswerResponse` and assert the run
returns a validation failure — which is exactly why this plan's own suite tests
`validate` purely and never asserts `runProgram`'s validation behavior. Similarly,
`docs/plans/36-fix-optimizer-instruction-seeding.md` (master plan
`docs/masterplans/6-optimizer-and-evaluation-correctness.md`) is expected to seed an
optimizer with `instructedSig`'s non-empty instruction where
`shikumi-optimize/test/StubLM.hs`'s `mkSignature ""` currently hides the bug. If those
plans need a differently-shaped fixture, they should extend
`shikumi-testing/src/Shikumi/Testing/Fixtures.hs` (and this plan's Decision Log) rather
than duplicating shapes locally; neither plan blocks on this one, and this one does not
block on them.
