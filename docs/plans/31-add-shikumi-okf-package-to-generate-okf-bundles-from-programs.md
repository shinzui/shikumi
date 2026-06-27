---
id: 31
slug: add-shikumi-okf-package-to-generate-okf-bundles-from-programs
title: "Add shikumi-okf package to generate OKF bundles from programs"
kind: exec-plan
created_at: 2026-06-27T21:46:07Z
intention: "intention_01kw5gqw31evb942ky4pcgnrwv"
---

# Add shikumi-okf package to generate OKF bundles from programs

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Today there is no way to see, at a glance, which shikumi language-model programs an
application contains. A shikumi program is a typed Haskell value (a `Shikumi.Program.Program i o`),
so the only record of "what programs this app ships" is the source code itself. We want a
*generated, human-readable, machine-validatable* inventory: a directory of Markdown documents,
one per program, that a person can read and that tooling can index and cross-reference across
projects.

The chosen documentation format is **OKF (Open Knowledge Format)** — a directory tree of
Markdown files with YAML frontmatter, where each file is a "concept" and Markdown links
between concepts become graph edges. OKF already has a complete standalone Haskell
implementation in the sibling repository at `/Users/shinzui/Keikaku/bokuno/okf` (the
`okf-core` library), including a *producer* API for building and writing bundles, and the
project registry tool **mori** already indexes and profile-validates OKF bundles a project
declares.

After this change, an application author writes a small **manifest** listing their named
programs, runs a generator, and gets an OKF bundle on disk: one `Shikumi App` concept that
links to one `Shikumi Program` concept per program, each documenting the program's structure
(its constructor tree and the input/output fields of every model call). They can then run the
standalone `okf` CLI to validate it and render its link graph, and declare the bundle in their
`mori.dhall` so mori indexes it across projects.

The non-negotiable design constraint driving this plan: **the generator lives in a brand-new,
separate Cabal package named `shikumi-okf`** so that the large majority of shikumi users — who
do not care about OKF — never take a dependency on `okf-core`. This mirrors how the repository
already isolates the heavy OpenTelemetry dependency in its own `shikumi-trace-otel` package
rather than forcing it on every shikumi user.

You can see it working when, from a clean build, you run the new package's test suite and it
generates a bundle from a sample manifest, validates it in-process with zero errors, and
asserts the expected app→program graph edges; and when you point the standalone `okf` binary at
the generated directory and it prints `OK: N concepts` and a graph whose edges run from the app
concept to each program concept.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

Milestone 1 — Scaffold the `shikumi-okf` package (DONE 2026-06-27):

- [x] Create `shikumi-okf/shikumi-okf.cabal` mirroring the satellite-package conventions. (2026-06-27)
- [x] Add `shikumi-okf` to the `packages:` stanza in `cabal.project`; resolve `okf-core` via sibling path `../okf/okf-core`. (2026-06-27)
- [x] Create `shikumi-okf/src/Shikumi/Okf/Types.hs` with `SomeProgram`, `ProgramDoc`, `ProgramManifest`, `AppInfo`. (2026-06-27)
- [x] Confirm `cabal build shikumi-okf` succeeds inside the dev shell. (2026-06-27)
- [x] Confirm isolation: `cabal build --dry-run shikumi` does not mention `okf-core`. (2026-06-27)

Milestone 2 — Reflect a program into OKF concepts (pure) (DONE 2026-06-27):

- [x] Add `shikumi-okf/src/Shikumi/Okf/Render.hs` rendering a `SomeProgram` to a Markdown body from `programShape`/`nodeFieldsIndexed`. (2026-06-27)
- [x] Add `shikumi-okf/src/Shikumi/Okf/Generate.hs` with `programConcept`, `appConcept`, `generateBundle`. (2026-06-27)
- [x] Add a test asserting `validateBundle` returns `[]` for a generated bundle and inline-golden tests pinning the rendered Markdown for a typed `Predict`, an opaque `Embed`, and a `Compose` tree. (2026-06-27)

Milestone 3 — Write the bundle and prove the round-trip (DONE 2026-06-27 except CLI transcript):

- [x] Add `writeProgramBundle` to `Shikumi/Okf/Generate.hs`. (2026-06-27)
- [x] Add a test that writes to a temp dir, re-reads with `Okf.Bundle.walkBundle`, and asserts the app→program graph edges via `Okf.Graph.buildGraph`. (2026-06-27)
- [ ] Capture an `okf validate` / `okf graph --json` transcript against the generated fixture. (deferred to the Milestone 4 example, which writes a bundle to a stable path)

Milestone 4 — Ship the shared profile and wire mori (DONE 2026-06-27):

- [x] Add `shikumi-okf/profile/shikumi.dhall` (an OKF profile descriptor for `Shikumi App` / `Shikumi Program`). (2026-06-27)
- [x] Add a hermetic in-suite Conformance test asserting the profile invariants (types + `shikumi://` scheme); the `.dhall` profile itself is enforced end-to-end by `okf validate --profile-enforce`. (2026-06-27)
- [x] Add a worked example (`shikumi-okf-example` executable + committed `example/out` bundle) and `example/README.md` documenting the generation command. (2026-06-27)
- [x] Document the `okfBundles` declaration to add to a consuming app's `mori.dhall` (in `example/README.md`). (2026-06-27)
- [x] Capture `okf validate` / `--profile-enforce` / `graph --json` transcripts against the example bundle (deferred from Milestone 3). (2026-06-27)

Milestone 5 (optional) — Richer bodies and CLI bridge:

- [x] Add `nodeInstructionsIndexed :: Program i o -> [Text]` to `Shikumi.Program` (core) and include each model call's instruction in the rendered body. (2026-06-27)
- [x] Provide a task-registry → `ProgramManifest` bridge. Landed as a new `handan-okf` package in the **handan** repo (`shinzui/handan`, commit `a09ded2`), not in shikigami — handan owns the `Task` type the whole fleet shares, so every handan app (shikigami included) gets it. Required `ProgramDoc.program` to become `Maybe SomeProgram` for handan tasks with no eval handle. (2026-06-27)


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Discovery (2026-06-27): A shikumi `Program i o` has **no name** of its own. The only stable
  structural identity available without running it is `Shikumi.Program.programShape` (the
  constructor tree, with each `Predict` node labelled by its joined output-field names) and
  `Shikumi.Program.nodeFieldsIndexed` (per-`Predict` input/output field names). The instruction
  text of a node is *not* exposed by any public accessor today; only the field names are. This
  means program naming must come from the manifest the app supplies, and the richest no-run
  documentation body we can build from core's public surface is "structure tree + per-node
  input/output field names".

- Discovery (2026-06-27): The downstream application `shinzui/shikigami` (at
  `/Users/shinzui/Keikaku/bokuno/shikigami`) defines its programs as `Program Value Value` built
  with `Shikumi.Program.embed` — i.e. single `Embed` nodes (see
  `shikigami-core/src/Shikigami/Program/Registry.hs`, `noopSummaryProgram = embed (\_ -> pure noopBody)`).
  For an `Embed` node `programShape` is `ShapeEmbed` and `nodeFieldsIndexed` is `[]`, so
  structural reflection yields essentially nothing. Furthermore shikigami's catalog is
  `[Handan.Task]` and the `Program` value is captured *inside* the `taskRun` closure, not exposed
  as a record field — so it cannot be projected back out of a `Handan.Task`. This directly shapes
  two requirements below: the generator must not assume `Predict`/typed signatures, and
  human-supplied `ProgramDoc` metadata must be first-class so an opaque agent program still
  documents usefully.


## Decision Log

Record every decision made while working on the plan.

- Decision: Deliver the generator as a brand-new separate Cabal package `shikumi-okf`, not as a
  module inside the core `shikumi` package or inside `shikumi-cli`.
  Rationale: The user requirement is that shikumi users who do not care about OKF must not take a
  dependency on `okf-core`. The repository already establishes this isolation pattern with
  `shikumi-trace-otel` (which quarantines the heavy `hs-opentelemetry-*` tree). `okf-core` is only
  pulled in when a project explicitly depends on `shikumi-okf`.
  Date: 2026-06-27

- Decision: The unit of enumeration is a user-supplied `ProgramManifest` of named `ProgramDoc`
  entries, each wrapping the program in a constraint-free existential `SomeProgram`. The generator
  does not attempt to auto-discover programs.
  Rationale: A `Program i o` is a plain Haskell value with no name and no global registry; there
  is nothing to reflect over at the module level. `programShape`/`nodeFieldsIndexed` are fully
  polymorphic, so `SomeProgram` needs no class constraints — which is exactly what lets it accept
  both typed `Predict` programs and shikigami's untyped `Embed`-based `Program Value Value`.
  Date: 2026-06-27

- Decision: `ProgramDoc` carries first-class human/declared metadata (title, description, tags,
  and an optional declared input/output summary), and the rendered Markdown body uses structural
  reflection only as a *best-effort enrichment*.
  Rationale: shikigami's programs are opaque single-`Embed` agents over `Value`/`Value`; structural
  reflection produces almost nothing for them. Making the declared metadata the primary content —
  and reflection an additive section — keeps the generated docs useful for both typed `Predict`
  pipelines (rich structure) and declared agents (rich prose, thin structure).
  Date: 2026-06-27

- Decision: `shikumi-okf` depends on `shikumi` (core) and `okf-core` only; it does **not** depend
  on `shikumi-cli`, `shikigami`, or `handan`. Any adapter from an app-specific registry
  (`Shikumi.Cli.Registry.Registry`, or shikigami's `[Handan.Task]`) into a `ProgramManifest` is the
  *app's* responsibility, living in the app, importing `shikumi-okf` — not the other way round.
  Rationale: Keeps the generator's dependency footprint minimal and avoids a dependency cycle
  (apps depend on shikumi-okf; shikumi-okf must not depend on apps). shikigami can build a manifest
  from its named program bindings (`noopSummaryProgram`, the per-agent programs) in a few lines.
  Date: 2026-06-27

- Decision: The pure builders return `Either GenerateError`, not a bare value, and
  `writeProgramBundle` returns `IO (Either GenerateError ())` rather than the originally-sketched
  `[Concept]` / `IO ()`.
  Rationale: An OKF concept id can fail to parse (`Okf.ConceptId.parseConceptId` is partial on
  malformed segments), so a manifest with an invalid `name`/`appName` is a real, reportable author
  error. Surfacing it as a typed `GenerateError` (`InvalidConceptName Text ConceptIdError`) is
  honest and total, where a partial `error` call would not be. `writeProgramBundle` also folds the
  `okf-core` index-write failure into `IndexWriteError BundleError`. The Interfaces section records
  the final signatures.
  Date: 2026-06-27

- Decision: Use inline expected-`Text` equality as the "golden" for rendered bodies rather than
  `tasty-golden` files.
  Rationale: The expected Markdown is small and self-contained; an inline literal pins the exact
  format (including the structure tree and the "opaque embedded program" line for the `Embed` case)
  without introducing golden-file management, and the plan must stay runnable from the file alone.
  Date: 2026-06-27

- Decision: The round-trip test compares the app→program edge set with `sort`, not by position.
  Rationale: `Okf.Graph.buildGraph` orders edges by target concept id, which is not the manifest
  order. The documentary guarantee is that an edge exists from the app to every program, which is a
  set property; asserting positional order would test an `okf-core` implementation detail.
  Date: 2026-06-27

- Decision: `ProgramDoc.program` is `Maybe SomeProgram`, not `SomeProgram` (changed during
  Milestone 5 part 2, while wiring the handan bridge).
  Rationale: A documentation source can name a program it cannot hand over as a value — concretely a
  `handan` task whose `taskEval` is `Nothing` exposes no `Program`. `Nothing` documents such a
  program from metadata alone; the renderer's structure section then states the structure is
  unavailable rather than fabricating an opaque node. This is a generic, reusable capability (any
  source may have a prose-only program), so it lives in `shikumi-okf`, and the handan bridge reuses
  the renderer instead of special-casing.
  Date: 2026-06-27

- Decision: Generation is deterministic — the timestamp is an explicit caller-supplied argument
  (`Maybe Text`, omitted by default), never read from the wall clock inside the generator.
  Rationale: The intended workflow includes a "regenerate and diff" CI check; a wall-clock
  timestamp would make every regeneration dirty. Determinism keeps diffs meaningful.
  Date: 2026-06-27


## Outcomes & Retrospective

Milestones 1–4 (the required scope) are complete as of 2026-06-27. The `shikumi-okf`
package exists, builds in the dev shell, and isolates `okf-core` so core shikumi users do not
depend on it (verified: `cabal build --dry-run shikumi` does not mention okf-core). Given a
`ProgramManifest`, it generates an OKF bundle — one `Shikumi App` concept linking to one
`Shikumi Program` concept per program — that the standalone `okf` CLI validates (`OK: 3 concepts`),
profile-enforces against the shipped `profile/shikumi.dhall` (exit 0), and renders as an app→program
graph. The 7-case test suite passes and covers both program shapes that matter: typed `Predict`
pipelines (rich structure) and opaque `Embed` programs (the shikigami shape, documented from declared
metadata). This matches the original purpose: a generated, human-readable, machine-validatable
inventory of the programs an app ships.

What remains (optional / downstream):

- Milestone 5 is now also complete: `nodeInstructionsIndexed` (part 1) and the registry bridge
  (part 2) both landed. Part 2 became a real `handan-okf` package in the handan repo rather than a
  shikigami snippet, so the whole handan fleet is covered.
- Real adoption: a consuming app (e.g. shikigami) calls `Handan.Okf.writeTaskBundle` over its task
  registry, commits the bundle, and declares it in its `mori.dhall` (recipe in
  `shikumi-okf/example/README.md`). shikigami should give its hand-rolled tasks (e.g. the noop
  summary) eval handles so they document with structure rather than metadata only.
- Publishing `shikumi.dhall` to a pinned `okf-profiles` URL so the profile import is reproducible in
  CI rather than resolved from the sibling checkout.

Lesson: the constraint-free `SomeProgram` existential was the load-bearing design choice — it let the
same generator accept typed and opaque programs without special-casing, which is exactly what made
shikigami compatibility fall out for free. The only real friction was build plumbing (resolving the
sibling `okf-core` and the cross-repo dhall import), not the program model.


## Context and Orientation

This repository, `shikumi`, is a multi-package Haskell project built with Cabal inside a Nix
dev shell (`nix develop`, GHC 9.12.4 — the system GHC is the wrong version, so all build/test
commands must run inside the dev shell). The package set is listed in the `packages:` stanza of
`/Users/shinzui/Keikaku/bokuno/shikumi/cabal.project`: a core library `shikumi` plus satellites
such as `shikumi-eval`, `shikumi-tools`, `shikumi-trace`, `shikumi-trace-otel`, and `shikumi-cli`.
Each satellite is its own directory with its own `<name>.cabal`. We will add one more satellite,
`shikumi-okf`.

**What a shikumi program is.** The core type is `Program i o`, defined in
`/Users/shinzui/Keikaku/bokuno/shikumi/shikumi/src/Shikumi/Program.hs`. It is a GADT — a typed
tree of constructors (`Predict`, `Compose`, `FMap`, `Map`, `Parallel`, `Retry`, `RetryWhen`,
`Validate`, `MajorityVote`, `Ensemble`, `Embed`). `Predict` is a single model call backed by a
`Signature i o` (from `/Users/shinzui/Keikaku/bokuno/shikumi/shikumi/src/Shikumi/Signature.hs`,
which carries an `instruction` and the derived `inputFields`/`outputFields`); the other
constructors compose programs. `Embed` wraps an opaque effectful function `i -> Eff es o` and is
how multi-step agents are represented as a single node.

The two public, run-free ways to inspect a program — both exported from `Shikumi.Program` — are:

- `programShape :: Program i o -> ProgramShape` — a closure-free description of the constructor
  tree. Each `Predict` becomes `ShapePredict <output-field-names>`; an `Embed` becomes the
  nullary `ShapeEmbed`; composites recurse. It does not require any constraints on `i`/`o`.
- `nodeFieldsIndexed :: Program i o -> [NodeFields]` — for each `Predict` node in depth-first
  order, a `NodeFields { inputFieldNames :: [Text], outputFieldNames :: [Text] }`. An `Embed`
  contributes nothing (empty list).

There is intentionally **no** `programName` and **no** public accessor for a node's instruction
text. Naming therefore has to come from outside the program value.

**What OKF is, and where its code lives.** OKF (Open Knowledge Format) is a directory tree of
Markdown files with YAML frontmatter. Each non-reserved `.md` file is a "concept" whose ID is its
bundle-relative path without the `.md` suffix (e.g. `programs/sentiment.md` → concept id
`programs/sentiment`). A concept's frontmatter has a required `type` and recommended `title`,
`description`, `timestamp`, `resource`, `tags`. A Markdown link from one concept to another
(`[label](/programs/sentiment.md)`) becomes a directed graph edge. The reference implementation is
the separate repository at `/Users/shinzui/Keikaku/bokuno/okf`, whose `okf-core` library we will
depend on. The producer (authoring) API we will call is summarised in the Interfaces section
below; it lets us build frontmatter, construct `Concept` values, validate a list of concepts, and
write them to disk. A standalone `okf` executable (from the `okf-cli` package in that repo) can
validate a bundle and print its graph; we use it for human-visible acceptance, but the automated
tests call `okf-core` in-process so they need no external binary.

**Why "documentation per app" needs an App concept.** The goal is to answer "which programs does
this app use?" and, across projects, "which apps use this program?". We model the app itself as a
concept of type `Shikumi App` that links to one `Shikumi Program` concept per program it ships.
Within one bundle this gives an app→program edge for every program; when each app emits its own
bundle and a project registry (mori) indexes them, both directions become answerable. We do not
build the cross-project resolver here — that belongs to mori — we only emit a well-formed,
profile-conformant bundle.

**The mori connection (context only, not built here).** `mori` (at
`/Users/shinzui/Keikaku/bokuno/mori-project/mori`) is a project registry. Its schema already has
an `OkfBundle` record, so a project declares bundles in its `mori.dhall` via an `okfBundles` list
(`name`, `path`, optional `profile`, `okfVersion`). At register/observe time mori walks each
declared bundle with `okf-core` and emits advisory profile deviations. This plan produces the
bundle and the profile; wiring an app's `mori.dhall` is the final, documentation-only step.

**The downstream consumer that stresses the design: shikigami.** `shinzui/shikigami` (at
`/Users/shinzui/Keikaku/bokuno/shikigami`) is a declared-agent runtime application that depends on
`shikumi`. It defines its programs in
`/Users/shinzui/Keikaku/bokuno/shikigami/shikigami-core/src/Shikigami/Program/Registry.hs` as
`Program Value Value` values built with `Shikumi.Program.embed` (single `Embed` nodes), catalogued
as `[Handan.Task]` where the program is captured inside the `taskRun` closure rather than exposed
as a field. The consequences (recorded in Surprises & Discoveries and the Decision Log) are that
the generator must not assume typed `Predict` structure, structural reflection will be thin for
such programs, and the human-supplied metadata in `ProgramDoc` must carry the documentary weight.
This plan is designed so that a shikigami agent produces a valid, useful concept from declared
metadata alone, with structural reflection added when present.


## Plan of Work

The work proceeds in four required milestones and one optional one. Each milestone leaves the
tree building and testable.

### Milestone 1 — Scaffold the `shikumi-okf` package and its core types

Scope: create the new package so it compiles and exposes the data types the rest of the plan
builds on, with no behaviour yet. At the end of this milestone `cabal build shikumi-okf` succeeds
inside the dev shell and the package depends on `shikumi` and `okf-core` (and nothing app-specific).

Create the directory `/Users/shinzui/Keikaku/bokuno/shikumi/shikumi-okf/` with a cabal file
`shikumi-okf/shikumi-okf.cabal` modelled on `shikumi-eval/shikumi-eval.cabal` (same
`common-options`, `GHC2024`, default extensions). Its `library` stanza lists the modules added in
this and later milestones and a `build-depends` of: `base`, `text`, `containers`, `aeson`,
`filepath`, `directory`, `shikumi`, and `okf-core`. Because `okf-core` lives in a sibling repo and
is not on Hackage, add a `source-repository-package` or a `packages:`/`optional-packages:` path
entry to `cabal.project` pointing at `/Users/shinzui/Keikaku/bokuno/okf` (verify how the repo
already resolves sibling sources before choosing; if `okf-core` is not yet reachable, add the
local path so Cabal can find it). Add `shikumi-okf` to the `packages:` stanza of `cabal.project`.

Create `shikumi-okf/src/Shikumi/Okf/Types.hs` exporting:

- `data SomeProgram where SomeProgram :: Program i o -> SomeProgram` — a constraint-free
  existential. No `ToJSON`/`Typeable` bound is needed because every function we call on it
  (`programShape`, `nodeFieldsIndexed`) is fully polymorphic.
- `data ProgramDoc = ProgramDoc { name :: Text, title :: Maybe Text, description :: Maybe Text,
  tags :: [Text], declaredInputs :: Maybe Text, declaredOutputs :: Maybe Text, program :: SomeProgram }`.
  `name` is the concept-id leaf (e.g. `sentiment`); `declaredInputs`/`declaredOutputs` are
  free-text summaries an app supplies for opaque programs (this is what makes shikigami's `Embed`
  agents document well).
- `newtype ProgramManifest = ProgramManifest { entries :: [ProgramDoc] }`.
- `data AppInfo = AppInfo { appNamespace :: Text, appName :: Text, appTitle :: Maybe Text,
  appDescription :: Maybe Text }` — the owning application's identity (e.g. namespace `shinzui`,
  name `shikigami`), used for the App concept and the `resource:` URIs.

Acceptance: `cabal build shikumi-okf` succeeds; `ghci` can construct a `ProgramManifest` holding a
trivial `embed (\_ -> pure ())` program.

### Milestone 2 — Reflect a program into OKF concepts (pure, in-memory)

Scope: turn a manifest into a list of `okf-core` `Concept` values, entirely pure, and prove they
are valid OKF. At the end, a test builds a bundle for a mixed manifest (one typed `Predict`
pipeline and one `Embed`-only program, mirroring shikigami) and `Okf.Validation.validateBundle`
returns `[]`.

Add `shikumi-okf/src/Shikumi/Okf/Render.hs` with `renderProgramBody :: ProgramDoc -> Text`. The
body is assembled as Markdown: an `# <title-or-name>` heading; the `description` prose if present;
a "Declared inputs/outputs" subsection from `declaredInputs`/`declaredOutputs` when present; and a
"Structure" subsection rendered from the program. The structure subsection walks
`programShape (the SomeProgram)` into an indented bullet tree of constructor names, and lists, for
each `Predict` node from `nodeFieldsIndexed`, its `inputFieldNames -> outputFieldNames`. For a
program that is a single `ShapeEmbed`, the structure subsection renders one line —
"Opaque embedded program (no inspectable internal structure)" — so shikigami programs still
produce a coherent, honest document rather than an empty one.

Add `shikumi-okf/src/Shikumi/Okf/Generate.hs` with the pure builders:

- `programConceptId :: ProgramDoc -> ConceptId` — `parseConceptId ("programs/" <> name)` (fail
  loudly on an invalid name; document the allowed character set from `Okf.ConceptId`).
- `appConceptId :: AppInfo -> ConceptId` — `parseConceptId ("apps/" <> appName)`.
- `programConcept :: AppInfo -> Maybe Text -> ProgramDoc -> Concept` — builds frontmatter
  (`type = "Shikumi Program"`, `title`, `description`, optional `timestamp` from the `Maybe Text`
  argument, `resource = "shikumi://<ns>/<app>/programs/<name>"`, `tags`) with `Okf.Document.okfCommon`
  + setters, attaches `renderProgramBody`, and calls `conceptFromDocument`.
- `appConcept :: AppInfo -> Maybe Text -> ProgramManifest -> Concept` — a `type = "Shikumi App"`
  concept whose body links to each program with `Okf.ConceptId.renderConceptLink` (these links are
  the app→program graph edges) and whose `resource = "shikumi://<ns>/<app>"`.
- `generateBundle :: AppInfo -> Maybe Text -> ProgramManifest -> [Concept]` — the app concept
  followed by every program concept. The `Maybe Text` is the optional shared timestamp.

Acceptance: a test in `shikumi-okf/test/` builds `generateBundle` for a sample manifest and asserts
`Okf.Validation.validateBundle Okf.Validation.PermissiveConformance concepts == []`; a golden test
pins the serialized Markdown of one typed program and one `Embed` program so body rendering is
stable.

### Milestone 3 — Write the bundle to disk and prove the round-trip and graph

Scope: persist the bundle and demonstrate, end to end, that the standalone OKF reader sees the
expected concepts and app→program edges. At the end, a test writes to a temp directory, re-reads
it with `okf-core`, and asserts the graph.

Add `writeProgramBundle :: FilePath -> AppInfo -> Maybe Text -> ProgramManifest -> IO ()` to
`Shikumi.Okf.Generate`, calling `Okf.Bundle.writeBundle root (generateBundle ...)` and then
`Okf.Index.writeBundleIndexes root` so the bundle gets `index.md` files.

Acceptance: a test writes a bundle to a temp dir (use `directory`'s temp facilities or a path under
the system temp), reads it back with `Okf.Bundle.walkBundle`, builds the graph with
`Okf.Graph.buildGraph`, and asserts there is one node per program plus the app node, and an edge
from the app node to each program node. Capture, in the Concrete Steps section, a transcript of the
standalone `okf validate` and `okf graph --json` commands run against the generated directory (built
from the sibling `okf` repo) as human-visible proof.

### Milestone 4 — Ship the shared profile and document the mori wiring

Scope: deliver the cross-project consistency mechanism and the integration recipe. At the end there
is a reusable OKF profile that pins shikumi's conventions, a test proving the generated bundle
conforms to it, a worked example, and copy-paste `mori.dhall` instructions.

Add `shikumi-okf/profile/shikumi.dhall`, an OKF profile descriptor (schema shape per the worked
example at `/Users/shinzui/Keikaku/bokuno/okf/docs/profiles/postgresql.dhall`). It declares
`okfVersion = "0.1"`, required frontmatter `["type", "title"]`, recommended
`["description", "resource"]`, `allowUnknownTypes = False`, and two types: `Shikumi App`
(`pathPattern = Some "apps/*"`, `resourceScheme = Some "shikumi"`) and `Shikumi Program`
(`pathPattern = Some "programs/*"`, `resourceScheme = Some "shikumi"`). Import the published profile
schema by pinned URL in production; for the in-repo copy, reference
`/Users/shinzui/Keikaku/bokuno/okf/okf-core/dhall/Profile.dhall` and note the pin to apply when the
profile is published to the shared `okf-profiles` location.

Add a worked example under `shikumi-okf/example/` — a small `Main.hs` (or a test fixture) that
defines a two-entry manifest and calls `writeProgramBundle` to a directory, plus a short README
snippet showing the command and the resulting tree. Document, in this plan's Validation section and
the example README, the exact `okfBundles` entry to add to a consuming app's `mori.dhall`:

```dhall
, okfBundles =
  [ Schema.OkfBundle::{
    , name = "programs"
    , path = "docs/okf/programs"
    , okfVersion = "0.1"
    , profile = Some "<pinned-url-or-path>/shikumi.dhall"
    }
  ]
```

Acceptance: a test loads `shikumi-okf/profile/shikumi.dhall` with `Okf.Profile.loadProfileFile` and
runs `Okf.Profile.validateProfile` over the generated concepts, asserting zero violations; the
example program runs and writes a bundle that `okf validate --profile profile/shikumi.dhall
--profile-enforce` accepts with exit 0.

### Milestone 5 (optional) — Richer bodies and an app-side registry bridge

Scope: optional enrichments that are valuable but not required for the core outcome. Keep them
clearly separable so they can be dropped without affecting Milestones 1–4.

First option (DONE 2026-06-27): add a public `nodeInstructionsIndexed :: Program i o -> [Text]`
accessor to `Shikumi.Program` (core) that, structurally like `nodeFieldsIndexed`, returns each
`Predict` node's signature instruction via `getInstruction`. Then include the instruction text per
node in `renderProgramBody` (zipped with `nodeFieldsIndexed`, rendered as a nested
`- Instruction: ...` bullet under each model call). This is the only change that touches the core
`shikumi` package; it is additive (a new export) and was guarded behind this optional milestone so
the core stayed untouched until the richer body was wanted. The originally-sketched `[Maybe Text]`
return type was reduced to `[Text]`: every `Predict` node always has a signature instruction, so the
`Maybe` conveyed nothing, and `[Text]` matches `nodeFieldsIndexed`'s one-entry-per-`Predict` shape so
the two zip cleanly.

Second option (DONE 2026-06-27, landed in the handan repo): rather than a shikigami-only snippet,
the bridge was built one layer down as a new `handan-okf` package in `shinzui/handan` (at
`/Users/shinzui/Keikaku/bokuno/handan/handan-okf`, commit `a09ded2`). handan owns the `Handan.Task`
type that the whole mori fleet shares, and that type already exposes the inner shikumi program via
its eval handle (`taskEval :: Maybe (EvalHandle i o)`, `evalProgram :: Program i o`) plus `taskName`
and `taskSummary`. So `Handan.Okf.taskManifest`/`writeTaskBundle` document any `[Handan.Task]` — and
every handan app, shikigami included, gets program docs without bespoke code. `handan-okf` depends on
`handan-core` + `shikumi-okf` (and resolves `shikumi-okf`/`okf-core` from sibling checkouts), keeping
okf-core out of handan-core. Tasks with no eval handle are documented from metadata
(`ProgramDoc.program = Nothing`) and reported by `metadataOnlyTaskNames`, per the user's chosen
"metadata-only doc + warn" behaviour. This is strictly better than the shikigami-only snippet and
avoided editing shikigami while it was being changed. The `Shikumi.Cli.Registry` adapter mentioned in
the original sketch was not built — handan is the relevant registry for the fleet, not the
shikumi-cli example registry.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/shikumi` inside the Nix
dev shell. Enter it first:

```bash
nix develop
```

Milestone 1 — after creating `shikumi-okf/shikumi-okf.cabal`, the `cabal.project` entries, and
`shikumi-okf/src/Shikumi/Okf/Types.hs`:

```bash
cabal build shikumi-okf
```

Expected: the package configures and compiles. If Cabal cannot find `okf-core`, confirm the
sibling path entry for `/Users/shinzui/Keikaku/bokuno/okf` was added to `cabal.project` and that
`okf-core`'s own `cabal.project`/package builds independently.

Milestone 2 and 3 — run the new test suite:

```bash
cabal test shikumi-okf
```

Expected (illustrative): all cases pass, including the `validateBundle == []` case, the golden body
test, and the round-trip graph test.

```text
shikumi-okf-test
  Generate
    valid bundle has no validation errors:       OK
    golden: typed program body:                  OK
    golden: embed program body:                  OK
    round-trip: app links to every program:      OK
  Profile
    generated bundle conforms to shikumi.dhall:  OK

All N tests passed
```

Milestone 4 — generate the example bundle:

```bash
cabal run shikumi-okf-example -- shikumi-okf/example/out
```

Observed:

```text
Wrote OKF bundle to shikumi-okf/example/out
```

producing `apps/example-app.md`, `programs/classify-ticket.md`, `programs/heartbeat.md`, and
generated `index.md` files.

Milestone 4 — human-visible proof with the standalone `okf` binary (built once from the sibling
repo). These were run and their real output captured:

```bash
cd /Users/shinzui/Keikaku/bokuno/okf
nix develop --command cabal build okf
nix develop --command cabal run -v0 okf -- \
  validate /Users/shinzui/Keikaku/bokuno/shikumi/shikumi-okf/example/out
```

```text
OK: 3 concepts
```

Profile enforcement (the `.dhall` profile resolves its schema across the sibling repo and the
bundle conforms, exit 0):

```bash
nix develop --command cabal run -v0 okf -- \
  validate /Users/shinzui/Keikaku/bokuno/shikumi/shikumi-okf/example/out \
  --profile /Users/shinzui/Keikaku/bokuno/shikumi/shikumi-okf/profile/shikumi.dhall --profile-enforce
```

```text
OK: 3 concepts
```

Graph (the app→program edges are exactly what answers "which programs does this app use?"):

```bash
nix develop --command cabal run -v0 okf -- \
  graph /Users/shinzui/Keikaku/bokuno/shikumi/shikumi-okf/example/out --json
```

```json
{"edges":[{"source":"apps/example-app","target":"programs/classify-ticket"},
          {"source":"apps/example-app","target":"programs/heartbeat"}],
 "nodes":[{"id":"apps/example-app","label":"Example Application","type":"Shikumi App",
           "resource":"shikumi://shinzui/example-app","tags":[]},
          {"id":"programs/classify-ticket","label":"Classify Ticket","type":"Shikumi Program",
           "resource":"shikumi://shinzui/example-app/programs/classify-ticket"},
          {"id":"programs/heartbeat","label":"Heartbeat","type":"Shikumi Program",
           "resource":"shikumi://shinzui/example-app/programs/heartbeat"}]}
```


## Validation and Acceptance

The change is effective — beyond compiling — when these behaviours hold:

1. **Generation produces valid OKF.** `cabal test shikumi-okf` passes a case that builds concepts
   for a manifest containing both a typed `Predict` pipeline and an `Embed`-only `Program Value Value`
   (the shikigami shape) and asserts `Okf.Validation.validateBundle PermissiveConformance concepts`
   is the empty list. This proves the generator does not assume typed structure and accepts opaque
   agent programs.

2. **The app→program graph is correct.** A test writes the bundle to disk, re-reads it with
   `Okf.Bundle.walkBundle`, builds `Okf.Graph.buildGraph`, and asserts one program node per manifest
   entry plus an app node, with an edge from the app node to every program node. This is the
   property that makes "which programs does this app use?" answerable.

3. **Bodies are stable and honest.** Golden tests pin the rendered Markdown for one typed program
   (showing its structure tree and per-`Predict` `inputs -> outputs`) and one `Embed` program
   (showing the declared metadata plus the explicit "opaque embedded program" structure line). A
   shikigami-style program must yield a non-empty, useful document.

4. **Cross-project consistency is enforceable.** A test loads `shikumi-okf/profile/shikumi.dhall`
   and validates the generated concepts against it with zero violations; the standalone
   `okf validate ... --profile profile/shikumi.dhall --profile-enforce` exits 0.

5. **Human-visible end to end.** The standalone `okf` binary prints `OK: 3 concepts` for the example
   bundle and a graph whose edges run app→program (transcripts in Concrete Steps).

6. **Isolation holds.** `cabal build shikumi` (the core library) and `cabal build shikumi-eval`
   etc. continue to succeed without `okf-core` in their build plans; only `shikumi-okf` pulls it in.
   Confirm with `cabal build shikumi` followed by inspecting that `okf-core` is not among its
   dependencies (e.g. `cabal build --dry-run shikumi` does not mention `okf-core`).

## Idempotence and Recovery

Creating the package is additive: the new directory, the `cabal.project` entries, and the new
modules do not modify existing packages (Milestones 1–4 touch only `shikumi-okf` and `cabal.project`;
the only edit to an existing package is the optional Milestone 5 core accessor, which is purely
additive — a new exported function). Re-running any build or test command is safe.

Bundle generation is idempotent by construction: `Okf.Bundle.writeBundle` overwrites exactly the
concept files it is given and leaves other files untouched, and `writeBundleIndexes` rewrites
`index.md` files deterministically. Because the timestamp is an explicit argument (omitted by
default), regenerating a bundle from an unchanged manifest produces byte-identical output, so a
"regenerate and diff" CI check is meaningful: regenerate into the committed bundle path, and fail if
`git status --porcelain` reports changes. To recover from a corrupted or partial generation, delete
the target directory and regenerate; nothing else depends on intermediate state.

If `cabal.project` cannot resolve `okf-core` from the sibling path, the recovery is to build
`okf-core` independently in `/Users/shinzui/Keikaku/bokuno/okf` first to confirm it is healthy, then
re-point the path entry; no changes to `okf-core` itself are required by this plan.

## Interfaces and Dependencies

**New package `shikumi-okf`.** Depends only on `base`, `text`, `containers`, `aeson`, `filepath`,
`directory`, the in-repo `shikumi` library, and the sibling `okf-core` library. It must not depend on
`shikumi-cli`, `shikigami`, or `handan` (Decision Log: dependency direction).

**Consumed from `Shikumi.Program` (core `shikumi`, already present):**

```haskell
data Program i o            -- the GADT (constructors exported)
data ProgramShape = ShapePredict Text | ShapeCompose ProgramShape ProgramShape
                  | ShapeFMap ProgramShape | ShapeMap Int ProgramShape
                  | ShapeParallel ProgramShape ProgramShape | ShapeRetry Int ProgramShape
                  | ShapeRetryWhen Int ProgramShape | ShapeValidate ProgramShape
                  | ShapeMajorityVote Int TempSchedule ProgramShape
                  | ShapeEnsemble [ProgramShape] | ShapeEmbed
data NodeFields = NodeFields { inputFieldNames :: [Text], outputFieldNames :: [Text] }
programShape       :: Program i o -> ProgramShape
nodeFieldsIndexed  :: Program i o -> [NodeFields]
embed              :: (forall es. (LLM :> es, Error ShikumiError :> es) => i -> Eff es o) -> Program i o
```

Milestone 5 added `nodeInstructionsIndexed :: Program i o -> [Text]` to this module (one signature
instruction per `Predict` node, index-aligned with `nodeFieldsIndexed`).

**Consumed from `okf-core` (sibling repo, producer API — verified to exist):**

```haskell
-- Okf.ConceptId
newtype ConceptId = ConceptId { segments :: NonEmpty Text }
parseConceptId      :: Text -> Either ConceptIdError ConceptId
renderConceptId     :: ConceptId -> Text
conceptIdToFilePath :: ConceptId -> FilePath
renderConceptLink   :: ConceptId -> Text -> Text     -- "[label](/path.md)" — graph edge

-- Okf.Document
data OkfCommon = OkfCommon { commonType :: Text, commonTitle :: Maybe Text
                           , commonDescription :: Maybe Text, commonTimestamp :: Maybe Text }
data OKFDocument = OKFDocument { frontmatter :: Frontmatter, body :: Text }
okfCommon       :: OkfCommon -> Frontmatter
setResource     :: Text -> Frontmatter -> Frontmatter
setTags         :: [Text] -> Frontmatter -> Frontmatter
serializeDocument :: OKFDocument -> Text

-- Okf.Bundle
data Concept
conceptFromDocument :: ConceptId -> OKFDocument -> Concept
writeBundle         :: FilePath -> [Concept] -> IO ()
walkBundle          :: FilePath -> IO (Either BundleError [Concept])   -- exact result type to confirm on use

-- Okf.Validation
data ValidationProfile = PermissiveConformance | StrictAuthoring
validateBundle :: ValidationProfile -> [Concept] -> [BundleValidationError]

-- Okf.Index
writeBundleIndexes :: FilePath -> IO (Either BundleError ())

-- Okf.Graph
buildGraph :: [Concept] -> Graph        -- exact node/edge accessors to confirm on use

-- Okf.Profile
loadProfileFile :: FilePath -> IO (Either e Profile)   -- exact signatures to confirm on use
validateProfile :: Profile -> [Concept] -> [ProfileViolation]
```

The exact signatures of `walkBundle`, `buildGraph`, and the `Okf.Profile` functions should be
re-confirmed against `okf-core` source at implementation time (their shapes are summarised from the
producer-API survey and the integration doc, but the graph/profile return types were not pinned to
the byte). Everything in `Okf.Document`, `Okf.ConceptId`, `Okf.Bundle` (concept construction +
`writeBundle`) and `Okf.Validation` was verified directly.

**Types this plan introduces (in `Shikumi.Okf.Types`), required by end of Milestone 1:**

```haskell
data SomeProgram where SomeProgram :: Program i o -> SomeProgram
data ProgramDoc = ProgramDoc
  { name :: Text, title :: Maybe Text, description :: Maybe Text, tags :: [Text]
  , declaredInputs :: Maybe Text, declaredOutputs :: Maybe Text, program :: Maybe SomeProgram }
  -- program: Just = reflectable structure; Nothing = document from metadata only (e.g. a
  -- handan task with no eval handle). See the Decision Log.
newtype ProgramManifest = ProgramManifest { entries :: [ProgramDoc] }
data AppInfo = AppInfo
  { appNamespace :: Text, appName :: Text, appTitle :: Maybe Text, appDescription :: Maybe Text }
```

**Functions delivered by Milestones 2–3 (in `Shikumi.Okf.Render` / `Shikumi.Okf.Generate`).** Final
signatures (the builders are `Either`-returning because a concept id can fail to parse — see the
Decision Log):

```haskell
-- Shikumi.Okf.Render
renderProgramBody  :: ProgramDoc -> Text

-- Shikumi.Okf.Generate
data GenerateError = InvalidConceptName Text ConceptIdError | IndexWriteError BundleError
programConceptId   :: ProgramDoc -> Either GenerateError ConceptId
appConceptId       :: AppInfo -> Either GenerateError ConceptId
programConcept     :: AppInfo -> Maybe Text -> ProgramDoc -> Either GenerateError Concept
appConcept         :: AppInfo -> Maybe Text -> ProgramManifest -> Either GenerateError Concept
generateBundle     :: AppInfo -> Maybe Text -> ProgramManifest -> Either GenerateError [Concept]
writeProgramBundle :: FilePath -> AppInfo -> Maybe Text -> ProgramManifest -> IO (Either GenerateError ())
```

**Profile artifact required by end of Milestone 4:** `shikumi-okf/profile/shikumi.dhall` declaring
the `Shikumi App` and `Shikumi Program` types with the `shikumi` resource scheme and `apps/*` /
`programs/*` path patterns.
