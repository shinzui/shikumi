---
id: 50
slug: adopt-okf-core-0-3-0-0-profile-features-in-shikumi-okf
title: "Adopt okf-core 0.3.0.0 profile features in shikumi-okf"
kind: exec-plan
created_at: 2026-07-30T04:20:12Z
intention: "intention_01kyrkxzwee3kvre2w45vctsrb"
---

# Adopt okf-core 0.3.0.0 profile features in shikumi-okf

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

The `shikumi-okf` package turns a list of shikumi programs into a folder of Markdown
documents (an "OKF bundle"). Alongside the generator it ships a small declarative file,
`shikumi-okf/profile/shikumi.dhall`, that states the house conventions those documents
must follow — which document kinds are allowed, which YAML keys must appear at the top of
each file, and what the `resource:` URI must look like. That file is called a "profile".

Two things are wrong with the current arrangement, and this plan fixes both.

First, **nothing automatically checks that the profile file is even valid.** The package's
test suite re-states the profile's conventions a second time in Haskell and checks the
generated documents against *that copy*, never against the real `.dhall` file. As a result
the profile silently rotted: across two `okf-core` major releases it stopped being a
well-typed profile at all, and no test noticed. It was found and repaired by hand in commit
`835148f`. After this plan, `cabal test shikumi-okf` loads the actual
`profile/shikumi.dhall`, compiles it, and validates the generated bundle against it — so
the same rot fails a test instead of going unnoticed for months.

Second, **the profile only checks that keys are present, never what they contain.** Today
`title: [a, b]` would pass even though a title must be a single value, and
`resource: not-a-uri` would pass even though every resource must be a `shikumi://` URI. The
`timestamp` key is entirely unvalidated free text supplied by whoever calls the generator.
`okf-core` 0.3.0.0 added the vocabulary to express all of this — value shapes
("cardinality"), named value formats, closed key sets, and per-document-kind rules — and
this plan puts it to work.

After this plan a reader can run two commands and watch both improvements. This one proves
the profile is now checked in-process:

```bash
cd /Users/shinzui/Keikaku/bokuno/shikumi
cabal test shikumi-okf
```

and its output includes a new passing test named
`generated bundle conforms to profile/shikumi.dhall`. This one proves the profile now
rejects malformed values that it previously accepted — deliberately breaking a document and
watching the checker complain:

```bash
cd /Users/shinzui/Keikaku/bokuno/shikumi
printf 'resource: nonsense\n' >> shikumi-okf/example/out/programs/heartbeat.md
okf validate shikumi-okf/example/out \
  --profile shikumi-okf/profile/shikumi.dhall --profile-enforce
# exits non-zero, reporting a resource format violation
git checkout shikumi-okf/example/out/programs/heartbeat.md
```


## Progress

- [x] Milestone 1: in-process profile conformance test. (2026-07-30T04:30Z)
  - [x] Add `data-files: profile/shikumi.dhall` to `shikumi-okf/shikumi-okf.cabal`.
  - [x] Add `Paths_shikumi_okf` to the test suite's `other-modules` and `autogen-modules`.
  - [x] Add the `Profile` test group to `shikumi-okf/test/Main.hs` that loads, compiles, and
        validates against the real descriptor.
  - [x] Confirm the new test fails when the descriptor is deliberately corrupted, then passes
        when restored (this is the proof it is actually reading the file). Both `Profile`
        tests failed with `could not load
        /Users/shinzui/Keikaku/bokuno/shikumi/shikumi-okf/./profile/shikumi.dhall` naming the
        real source path; restoring returned all 9 tests to green.
  - [x] Replace the duplicated hermetic `Conformance` group with a comment pointing at the
        new real check, keeping only assertions the profile cannot express. (Nothing was
        left to keep: all three of its assertions are profile-expressible — see the new
        Decision Log entry.)
  - [x] Commit.
- [ ] Milestone 2: value shapes and formats (`Cardinality`, `FieldFormat`).
  - [ ] Add the `scalarOf` helper and set `Scalar` on `type`, `title`, `description`.
  - [ ] Add `timestamp` as a recommended `Scalar` + `Rfc3339Utc` field.
  - [ ] Verify a malformed `title` list and a malformed `timestamp` are both reported.
  - [ ] Commit.
- [ ] Milestone 3: close the top-level key set (`allowUnknownFields = False`).
  - [ ] Set `allowUnknownFields = False` in the descriptor.
  - [ ] Verify a stray hand-added key is reported and that the untouched bundle still passes.
  - [ ] Commit.
- [ ] Milestone 4: per-document-kind rules (`TypeRule.frontmatter`).
  - [ ] Move `resource` from profile-wide `recommended` into each type's `required`, with the
        `UriWithScheme "shikumi"` format.
  - [ ] Add `tags` as a `List` recommendation on `Shikumi Program` only.
  - [ ] Verify a malformed `resource` is reported and the untouched bundle still passes.
  - [ ] Commit.
- [ ] Final: update `shikumi-okf/CHANGELOG.md`, re-run the full validation sequence, and fill
      in Outcomes & Retrospective.


## Surprises & Discoveries

- **`--profile-enforce` does not mean "strict".** Reading
  `/Users/shinzui/Keikaku/bokuno/okf/okf-cli/src/Okf/Cli.hs` line 788 shows the validation
  mode is chosen by a *separate* `--strict` flag, and `--profile-enforce` only decides
  whether violations are fatal:

  ```haskell
  let coreProfile = if strictMode then StrictAuthoring else PermissiveConformance
  ```

  This matters for this plan: a key placed in a profile's `recommended` list is only
  reported as missing under `StrictAuthoring`. So declaring the optional `timestamp` key as
  "recommended" buys format checking when it is present without failing the ordinary
  (non-`--strict`) validation when it is absent. See the Decision Log.

- **The working directory of a test run is the directory you invoke `cabal` from, not the
  package directory.** Evidence: `shikumi-okf/example/README.md` instructs the reader to run
  `cabal run shikumi-okf-example -- shikumi-okf/example/out` from the repository root, and
  that path resolves relative to the repository root. The `Justfile` runs `cabal test all`
  from the repository root too. A test that opened `"profile/shikumi.dhall"` as a plain
  relative path would therefore work when run from `shikumi-okf/` and break when run from
  the repository root. This is why Milestone 1 uses Cabal's `data-files` mechanism.

- **`data-files` resolves to the source tree for an in-place build, so the corruption proof
  works without reinstalling.** `getDataFileName "profile/shikumi.dhall"` returned
  `/Users/shinzui/Keikaku/bokuno/shikumi/shikumi-okf/./profile/shikumi.dhall` — the working
  copy itself, not a staged copy under `dist-newstyle`. Editing the descriptor therefore
  changes what the next `cabal test` reads, with no rebuild needed (the descriptor is not a
  build input, so nothing recompiles). Evidence, after appending `, bogusField = True`:

  ```text
    Profile
      profile/shikumi.dhall loads and compiles:                     FAIL
      generated bundle conforms to profile/shikumi.dhall:           FAIL
        Exception: user error (could not load
        /Users/shinzui/Keikaku/bokuno/shikumi/shikumi-okf/./profile/shikumi.dhall:
        Error: Invalid input
        75 | , bogusField = True
           | ^
        unexpected ','
  ```

  The fallback candidate-search described in Idempotence and Recovery was not needed.


## Decision Log

- Decision: Delete the `Conformance` group outright rather than keeping a reduced version of
  it, and remove the now-unused `conceptType`/`conceptResource` imports.
  Rationale: The plan permitted keeping it as a smoke check "if in doubt". There was no
  doubt: each of its three assertions is expressed by the descriptor and now checked against
  the real file. The app/program `type` strings are covered by `allowUnknownTypes = False`
  plus the two `TypeRule`s, and the app-vs-program *placement* is covered by each rule's
  `pathPattern` (`apps/*`, `programs/*`), so a program document carrying `type: Shikumi App`
  violates the app rule's path pattern. The `shikumi://` resource prefix is covered by
  `resourceScheme = Some "shikumi"` on both rules, and Milestone 4 adds a parsed
  `UriWithScheme "shikumi"` format on top. Concept count and ordering, which the profile
  genuinely cannot express, were already asserted by the untouched `Generate` group.
  Keeping a second copy would have reintroduced exactly the drift this milestone exists to
  prevent. The deletion is recorded as a comment on the new `Profile` group.
  Date: 2026-07-30

- Decision: Do the test (Milestone 1) before any profile tightening.
  Rationale: The tightenings in Milestones 2–4 change what the profile accepts. Without an
  in-process test, each one could only be verified by manually running the `okf` CLI, which
  is exactly the gap that let the descriptor rot in the first place. With the test landed
  first, every later milestone is self-verifying under `cabal test`.
  Date: 2026-07-30

- Decision: Locate the profile in the test through Cabal's `data-files` mechanism and
  `Paths_shikumi_okf.getDataFileName`, not a relative path.
  Rationale: The test's working directory is the directory `cabal` was invoked from (see
  Surprises & Discoveries), so a relative path is not reliable. `data-files` also means the
  published package ships the profile, which is a genuine benefit: a consumer who installs
  `shikumi-okf` gets the descriptor their bundles are supposed to satisfy. There is
  precedent for the `Paths_` module in this fleet — `okf-cli/okf-cli.cabal` lines 53–54
  declare `other-modules: Paths_okf_cli` and `autogen-modules: Paths_okf_cli`.
  Date: 2026-07-30

- Decision: Declare `timestamp` under `recommended` rather than `required`, and do not add a
  timestamp to the committed `example/out` bundle.
  Rationale: `timestamp` is genuinely optional — `Shikumi.Okf.Generate.generateBundle` takes
  it as a `Maybe Text` argument and the caller decides. Declaring it at all is what enables
  the `Rfc3339Utc` format check when it *is* present, and `recommended` avoids demanding it
  when it is not. Adding a timestamp to `example/out` was rejected because
  `shikumi-okf/example/README.md` documents that passing no timestamp is what makes
  regeneration byte-identical, which a "regenerate and diff" CI check depends on. The
  accepted consequence is that `okf validate --strict` will report a missing-recommended
  advisory for timestamp-free bundles; that is correct behavior for a strict authoring run
  and is documented in the profile file.
  Date: 2026-07-30

- Decision: Move `resource` out of the profile-wide `recommended` list and into each type's
  `required` list, rather than declaring it in both places.
  Rationale: `okf-core` merges profile-wide and per-type rules, keeping presence
  declarations as ordered clauses. Declaring the same key in both scopes yields two
  overlapping clauses for one key, which is harder to read and reason about for no gain. The
  generator always emits `resource` for both document kinds
  (`Shikumi.Okf.Generate.appConcept` and `programConcept` both call `setResource`), so
  per-type `required` states the truth precisely.
  Date: 2026-07-30

- Decision: The new test validates under `PermissiveConformance`, not `StrictAuthoring`.
  Rationale: It matches what `okf validate --profile --profile-enforce` does by default,
  which is the command the README tells users to run, so the test and the documented
  command agree. Under `StrictAuthoring` the test would also fail on absent recommended keys
  (`timestamp` on every document; `tags` on the two test programs that declare none), which
  is advisory authoring guidance rather than a conformance defect.
  Date: 2026-07-30

- Decision: Set `allowUnknownFields = False` without declaring `timestamp` and `tags`
  profile-wide purely to satisfy it.
  Rationale: A closed key set still always permits the six core OKF keys. Reading
  `/Users/shinzui/Keikaku/bokuno/okf/okf-core/src/Okf/Document.hs` line 190 gives that list
  as `["type", "title", "description", "timestamp", "resource", "tags"]`, and those six are
  exactly what the generator emits, so closing the set cannot reject a generated document.
  Its value is rejecting *hand-added* stray keys in a bundle that is supposed to be
  generated.
  Date: 2026-07-30


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Everything in this plan happens inside one directory, `shikumi-okf/`, of the repository at
`/Users/shinzui/Keikaku/bokuno/shikumi`. All commands below assume that repository root as
the working directory unless stated otherwise. The Haskell toolchain must be the one from
the project's Nix development shell (GHC 9.12.4); enter it with `nix develop` if the prompt
is not already inside it. The system `ghc` on `PATH` outside that shell is version 9.10.3
and is the wrong compiler.

**What OKF is.** "OKF" stands for Open Knowledge Format. An OKF *bundle* is just a
directory of Markdown files. Each file is a *concept document*: a block of YAML metadata
between `---` fences (called *frontmatter*), followed by a Markdown body. The frontmatter
carries keys like `type`, `title`, and `resource`. The library that reads and writes this
format is the Hackage package `okf-core`, and a standalone command-line tool `okf` (package
`okf-cli`) validates bundles from a terminal.

**What this package does.** `shikumi-okf` generates such a bundle from a list of shikumi
programs. `shikumi-okf/src/Shikumi/Okf/Generate.hs` builds one `Shikumi App` concept
document that links to one `Shikumi Program` concept document per program. Its frontmatter
is assembled from exactly three helper calls — `okfCommon` (which emits `type`, and
whichever of `title`, `description`, `timestamp` are supplied), `setResource` (which emits
`resource`), and `setTags` (which emits `tags`, and is skipped entirely when a program
declares no tags). There is no mechanism for an author to inject other frontmatter keys.
Generation is deterministic: the timestamp is an explicit argument and is never read from
the clock, so regenerating an unchanged input produces byte-identical files.

**What a profile is.** A *profile* is a Dhall file describing house conventions layered on
top of OKF — which `type` strings are allowed, which frontmatter keys are expected, what
the `resource` URI scheme must be, and where files must live. Dhall is a small typed
configuration language; a Dhall file is checked against a *schema* (a declared record type)
before it is used. Profiles are explicitly **not** part of the OKF standard: a bundle that
deviates from a profile is still a perfectly valid OKF bundle, which is why deviations are
advisory by default. This package's profile is
`shikumi-okf/profile/shikumi.dhall`. It imports its schema from okf's published entry point,
by relative path into a sibling checkout of the okf repository at
`/Users/shinzui/Keikaku/bokuno/okf`:

```dhall
let okf = ../../../okf/okf-core/dhall/package.dhall
```

That `package.dhall` exposes the schema types (`okf.Profile`, `okf.TypeRule`,
`okf.FieldRule`, `okf.Cardinality`, `okf.FieldFormat`, …), a set of record-completion
*defaults* under `okf.defaults`, and constructor helpers under `okf.mk`. Record completion
is the Dhall syntax `SomeType::{ field = value }`: it starts from a default record and
overrides only the named fields. Writing the profile that way is what protects it from
future *additive* schema changes.

**Where things stand right now.** Commit `835148f` moved the package's `okf-core` dependency
bound from `^>=0.1.0.0` to `^>=0.3.0.0` and rewrote `profile/shikumi.dhall` against the
0.3.0.0 schema, because the old descriptor no longer type-checked at all. That rewrite was
deliberately *semantics-preserving*: it kept the same two required keys (`type`, `title`),
the same two recommended keys (`description`, `resource`), closed document kinds
(`allowUnknownTypes = False`), an open key set (`allowUnknownFields = True`), no document-ID
checking (`idField` unset), and the permissive default value shape (`Cardinality.Any`) with
no format constraints anywhere. No Haskell source changed, because this package only uses
okf-core's bundle-producing API, which was untouched across both major releases. This plan
is the follow-up that actually uses the new checking vocabulary.

**The vocabulary 0.3.0.0 added**, in the terms this plan uses:

*Cardinality* is the expected shape of a value: `Any` (the permissive default — a single
value or a list both pass), `Scalar` (must be a single value), or `List` (must be a list).

*FieldFormat* is a named constraint on a value's text, checked with a real parser. The
available formats are `Rfc3339Utc` (a UTC timestamp such as `2026-07-30T04:20:12Z`), `Date`,
`Uri` (a well-formed absolute URI), `UriWithScheme "s"` (a well-formed absolute URI whose
scheme is `s`), and `DocumentHandle "PREFIX"`.

*`allowUnknownFields`* closes the set of permitted top-level frontmatter keys. When `False`,
a document may only carry the six core OKF keys, the profile's configured ID field, and keys
the profile explicitly declares.

*Per-type frontmatter rules* means each entry in the profile's `types` list carries its own
`frontmatter` record, merged with the profile-wide one, so a rule can apply to one document
kind only.

**The three functions Milestone 1 needs**, all from module `Okf.Profile` in `okf-core`:

```haskell
loadProfileFile  :: FilePath -> IO (Either Text ProfileSpec)
compileProfile   :: ProfileSpec -> Either (NonEmpty ProfileDefinitionError) CompiledProfile
validateProfile  :: ValidationProfile -> CompiledProfile -> [Concept] -> [ProfileViolation]
```

`loadProfileFile` reads and decodes the Dhall file. `compileProfile` turns the decoded
description into a checked, ready-to-use form, rejecting contradictory declarations up
front. `validateProfile` then compares a list of concept documents against it and returns
the deviations it found — an empty list means full conformance. `ValidationProfile` comes
from module `Okf.Validation` and has two values: `PermissiveConformance` and
`StrictAuthoring`, the latter additionally reporting absent *recommended* keys. All of
`ProfileViolation`, `ProfileDefinitionError`, and `ProfileSpec` derive `Show`, so a test can
print them directly in a failure message.

**The current test suite.** `shikumi-okf/test/Main.hs` uses `tasty` with `tasty-hunit` and
currently has four groups: `Render` (golden-text checks on rendered document bodies),
`Generate` (bundle-level validity and concept ids), `Conformance`, and `RoundTrip` (writes a
bundle to a temporary directory and re-reads it). The `Conformance` group is the one this
plan replaces: its own comment concedes that it "asserts the same conventions in-process
without dhall or a file path", deferring the real check to a manual CLI invocation. Its
fixtures are a three-program manifest named `demoManifest` over an app named `demoApp`; note
that two of those three programs declare no tags, which matters when reasoning about
`tags`-related rules.


## Plan of Work

The work splits into four milestones plus a wrap-up. Milestone 1 is the load-bearing one and
must come first: it converts "I checked by hand" into "the test suite checks", which is what
makes Milestones 2 through 4 verifiable at all. Milestones 2, 3, and 4 are independent
tightenings of the descriptor, each observable on its own.


### Milestone 1: make the test suite read the real profile

Scope: teach `shikumi-okf`'s test suite to find, load, compile, and validate against
`shikumi-okf/profile/shikumi.dhall`. Nothing about the profile's content changes in this
milestone. At the end, a corrupted or non-type-checking descriptor is a red test rather than
a silent problem, and the duplicated hermetic assertions are gone.

The obstacle is locating the file. As recorded in Surprises & Discoveries, a test's working
directory is wherever `cabal` was invoked, so `"profile/shikumi.dhall"` is not a dependable
path. Cabal's `data-files` mechanism solves this: declaring a file as a data file causes
Cabal to generate a module named `Paths_shikumi_okf` exposing
`getDataFileName :: FilePath -> IO FilePath`, which resolves a package-relative path to an
absolute one regardless of the working directory.

Three edits. First, in `shikumi-okf/shikumi-okf.cabal`, add a package-level `data-files`
field near the existing `extra-doc-files: CHANGELOG.md` line:

```cabal
data-files:      profile/shikumi.dhall
```

Second, in the same file, give the `test-suite shikumi-okf-test` stanza the generated
module, immediately after its `main-is: Main.hs` line:

```cabal
  other-modules:   Paths_shikumi_okf
  autogen-modules: Paths_shikumi_okf
```

Declaring the module in both fields is required: `other-modules` makes it part of the
component, and `autogen-modules` tells Cabal it is generated rather than a file on disk.

Third, in `shikumi-okf/test/Main.hs`, add the imports and a new test group. The new imports
are `Data.Foldable (toList)` (to render the non-empty list of definition errors),
`Okf.Profile (compileProfile, loadProfileFile, validateProfile)`, and
`Paths_shikumi_okf (getDataFileName)`. The existing import of
`Okf.Validation (ValidationProfile (PermissiveConformance), validateBundle)` already
supplies the validation mode. Then add this group to the `tests` list, between the existing
`Generate` and `Conformance` groups:

```haskell
      testGroup
        "Profile"
        -- The real descriptor, not a Haskell restatement of it. This fails if
        -- profile/shikumi.dhall stops type-checking against the okf-core schema,
        -- stops compiling as a coherent profile, or stops describing what the
        -- generator actually emits.
        [ testCase "profile/shikumi.dhall loads and compiles" $ do
            _ <- loadAndCompileProfile
            pure (),
          testCase "generated bundle conforms to profile/shikumi.dhall" $ do
            compiled <- loadAndCompileProfile
            case generateBundle demoApp Nothing demoManifest of
              Left err -> fail ("generateBundle failed: " <> show err)
              Right concepts ->
                validateProfile PermissiveConformance compiled concepts @?= []
        ],
```

and this helper alongside `freshTempDir` in the Helpers section at the bottom of the file:

```haskell
-- | Load and compile the shipped profile descriptor, failing the test with a
-- readable message at whichever stage breaks. The path is resolved through
-- Cabal's data-files mechanism, so it does not depend on the working directory
-- the test was launched from.
loadAndCompileProfile :: IO CompiledProfile
loadAndCompileProfile = do
  path <- getDataFileName "profile/shikumi.dhall"
  loaded <- loadProfileFile path
  case loaded of
    Left err -> fail ("could not load " <> path <> ": " <> T.unpack err)
    Right spec ->
      case compileProfile spec of
        Left errs ->
          fail ("profile did not compile: " <> show (toList errs))
        Right compiled -> pure compiled
```

This needs `CompiledProfile` added to the `Okf.Profile` import list for the type signature.

Finally, retire the now-duplicated `Conformance` group. Its two assertions — that the app
concept's type is `Shikumi App`, that every program concept's type is `Shikumi Program`, and
that every resource starts with `shikumi://` — are all now genuinely enforced by the profile
itself once Milestone 4 lands, and the type assertions are already covered by
`allowUnknownTypes = False`. Delete the group and leave the `Generate` group untouched. If
in doubt, keep the group but rewrite its comment to say it is a fast smoke check and that
the authoritative check is the `Profile` group.

Acceptance: `cabal test shikumi-okf` reports two new passing tests. Crucially, the milestone
is not complete until the test has been *proven* to read the file, by temporarily corrupting
the descriptor and watching the test fail. The Concrete Steps section gives the exact
sequence.


### Milestone 2: check value shapes and formats

Scope: state that the single-valued keys really are single-valued, and that a `timestamp`,
when present, really is a UTC timestamp. At the end, a document carrying `title: [a, b]` or
`timestamp: yesterday` is reported as a violation where previously both passed.

All edits are in `shikumi-okf/profile/shikumi.dhall`. Several fields now need two
constraints at once (a shape *and* a format), which the single-purpose `okf.mk.FieldRule`
constructors cannot express on their own, so introduce a small local helper just below the
existing `let field = okf.mk.FieldRule` line:

```dhall
let scalarOf =
      \(name : Text) ->
      \(prose : Text) ->
      \(fmt : Optional okf.FieldFormat) ->
        okf.defaults.FieldRule::{
        , field = name
        , description = Some prose
        , cardinality = okf.Cardinality.Scalar
        , format = fmt
        }
```

Then rewrite the profile-wide `frontmatter` record so `type` and `title` are required
scalars, and `description` plus a newly declared `timestamp` are recommended — the latter
carrying the `Rfc3339Utc` format:

```dhall
    , frontmatter = okf.defaults.FrontmatterRules::{
      , required =
        [ scalarOf
            "type"
            "The OKF concept type: `Shikumi App` or `Shikumi Program`."
            (None okf.FieldFormat)
        , scalarOf
            "title"
            "Human-readable name of the app or program."
            (None okf.FieldFormat)
        ]
      , recommended =
        [ scalarOf
            "description"
            "What the app or program is for, in one or two sentences."
            (None okf.FieldFormat)
        , scalarOf
            "timestamp"
            "Generation time, when the generator was given one. Optional by design: shikumi-okf takes the timestamp as an explicit argument so that regenerating an unchanged manifest is byte-identical, and omits the key when no timestamp is supplied. Declared here so its format is checked when it IS present; because it sits under `recommended`, an ordinary validation run does not demand it, while `okf validate --strict` will advise on its absence."
            (Some okf.FieldFormat.Rfc3339Utc)
        ]
      }
```

Note `resource` has deliberately left the profile-wide list — it moves to the per-type rules
in Milestone 4. Between Milestone 2 and Milestone 4 the profile therefore does not mention
`resource` at all, which is a temporary loosening, not a regression to worry about; the two
milestones can also be squashed into one commit if that gap is undesirable.

Acceptance: `cabal test shikumi-okf` still passes (the generated bundle satisfies all of
this), and the Concrete Steps section shows a deliberate corruption whose violation the
`okf` CLI reports.


### Milestone 3: close the top-level key set

Scope: a one-line change, `allowUnknownFields = False`, that stops a bundle from carrying
frontmatter keys nobody declared. At the end, a stray hand-added key in a generated bundle
is reported instead of silently accepted.

In `shikumi-okf/profile/shikumi.dhall`, add the field to the final record next to the
existing `allowUnknownTypes = False`:

```dhall
    , allowUnknownTypes = False
    , allowUnknownFields = False
```

As recorded in the Decision Log this cannot reject anything the generator produces, because
a closed key set still always admits the six core OKF keys and those six are exactly what
the generator emits. Its value is catching hand-edits and drift.

Acceptance: the test suite still passes, and appending a key such as `owner: someone` to a
generated document makes `okf validate … --profile-enforce` exit non-zero.


### Milestone 4: per-document-kind rules

Scope: use the per-type frontmatter rules to say what is true of each document kind
specifically — both kinds must carry a well-formed `shikumi://` resource URI, and program
documents are additionally expected to carry a list of tags. At the end, `resource` is
required rather than merely recommended, and its value is format-checked.

In `shikumi-okf/profile/shikumi.dhall`, give each of the two `let` bindings its own
`frontmatter` record. For the app:

```dhall
let appType =
      okf.defaults.TypeRule::{
      , type = "Shikumi App"
      , description = Some
          "One application that ships shikumi programs; links to every program it exposes."
      , frontmatter = okf.defaults.FrontmatterRules::{
        , required =
          [ scalarOf
              "resource"
              "The `shikumi://<namespace>/<app>` URI this concept documents."
              (Some (okf.FieldFormat.UriWithScheme "shikumi"))
          ]
        }
      , pathPattern = Some "apps/*"
      , resourceScheme = Some "shikumi"
      }
```

and for the program, the same required `resource` plus a recommended `tags` list:

```dhall
let programType =
      okf.defaults.TypeRule::{
      , type = "Shikumi Program"
      , description = Some
          "One shikumi program: its signature, adapter, and declared metadata."
      , frontmatter = okf.defaults.FrontmatterRules::{
        , required =
          [ scalarOf
              "resource"
              "The `shikumi://<namespace>/<app>/programs/<name>` URI this concept documents."
              (Some (okf.FieldFormat.UriWithScheme "shikumi"))
          ]
        , recommended =
          [ field.list "tags"
          ]
        }
      , pathPattern = Some "programs/*"
      , resourceScheme = Some "shikumi"
      }
```

`field.list` is the `okf.mk.FieldRule` constructor that sets `Cardinality.List` and nothing
else, which is all `tags` needs. Keep `resourceScheme = Some "shikumi"` on both: it is a
separate, still-useful check on the URI's scheme performed by the type rule, and it overlaps
harmlessly with the format constraint.

Note the interaction with the test fixtures: two of `demoManifest`'s three programs declare
no tags, so under `StrictAuthoring` they would draw a missing-recommended advisory. The test
validates under `PermissiveConformance` (see the Decision Log), so this is not a failure.

Acceptance: the test suite still passes, and replacing a `resource` value with a
non-URI string makes `okf validate … --profile-enforce` exit non-zero.


### Wrap-up

Add a `### Changed` entry under `## Unreleased` in `shikumi-okf/CHANGELOG.md` describing the
new in-process profile test and each tightening, and noting the one behavioral consequence
for consumers: `okf validate --strict` now reports a missing-recommended `timestamp` on
bundles generated without one. Leave the package `version:` field alone — this repository
bumps versions in a separate `chore(release):` commit, as commits `803615b` and `580b6c7`
show. Then re-run the full validation sequence and fill in Outcomes & Retrospective.


## Concrete Steps

Every command below runs from the repository root
`/Users/shinzui/Keikaku/bokuno/shikumi`, inside the Nix development shell. Verify the
toolchain first:

```bash
cd /Users/shinzui/Keikaku/bokuno/shikumi
ghc --version
```

Expect exactly:

```text
The Glorious Glasgow Haskell Compilation System, version 9.12.4
```

If it prints 9.10.3, run `nix develop` first and repeat.

A note on the `okf` command-line tool: the `okf` on `PATH` is version 0.1.2.1, which is too
old to read this profile's schema and will fail with a decode error. Use the 0.3.0.0 binary
from the sibling okf checkout instead. Define it once per shell:

```bash
OKF=/Users/shinzui/Keikaku/bokuno/okf/dist-newstyle/build/aarch64-osx/ghc-9.12.4/okf-cli-0.3.0.0/x/okf/build/okf/okf
$OKF --version
```

Expect:

```text
okf v0.3.0.0 (88ceed8)
```

If that path does not exist, build it: `cd /Users/shinzui/Keikaku/bokuno/okf && cabal build okf-cli`, then locate the binary with
`find dist-newstyle -name okf -type f -perm +111`.

**Milestone 1.** Make the three edits described in the Plan of Work, then build and test:

```bash
cabal build shikumi-okf
cabal test shikumi-okf
```

Expect the test list to gain a `Profile` group:

```text
  Profile
    profile/shikumi.dhall loads and compiles:                     OK
    generated bundle conforms to profile/shikumi.dhall:           OK
```

Now prove the test genuinely reads the file. Corrupt the descriptor, confirm a red test,
then restore it:

```bash
cp shikumi-okf/profile/shikumi.dhall /tmp/shikumi-profile-backup.dhall
printf ', bogusField = True\n' >> shikumi-okf/profile/shikumi.dhall
cabal test shikumi-okf 2>&1 | tail -20
```

Expect a failure naming the descriptor path, of the form
`could not load …/profile/shikumi.dhall: …`. Restore and re-confirm green:

```bash
cp /tmp/shikumi-profile-backup.dhall shikumi-okf/profile/shikumi.dhall
cabal test shikumi-okf
```

Commit:

```bash
git add shikumi-okf/shikumi-okf.cabal shikumi-okf/test/Main.hs
git commit
```

with a message body ending in the two required trailers:

```text
test(okf): validate generated bundle against the real profile

ExecPlan: docs/plans/50-adopt-okf-core-0-3-0-0-profile-features-in-shikumi-okf.md
Intention: intention_01kyrkxzwee3kvre2w45vctsrb
```

**Milestone 2.** Edit the descriptor, then keep it formatted and type-checked. Note that
`dhall format` silently discards comments that sit between top-level `let` bindings, so put
explanatory prose either in the file's header comment block or inside a field's
`description`:

```bash
cd shikumi-okf && dhall format profile/shikumi.dhall && dhall type --file profile/shikumi.dhall >/dev/null && echo "profile OK" && cd ..
cabal test shikumi-okf
```

Then demonstrate the new checking. Break a title's shape and watch it get caught:

```bash
$OKF validate shikumi-okf/example/out --profile shikumi-okf/profile/shikumi.dhall --profile-enforce; echo "clean exit=$?"
python3 - <<'PY'
import pathlib
p = pathlib.Path("shikumi-okf/example/out/programs/heartbeat.md")
p.write_text(p.read_text().replace("title: Heartbeat", "title:\n- Heartbeat\n- Extra"))
PY
$OKF validate shikumi-okf/example/out --profile shikumi-okf/profile/shikumi.dhall --profile-enforce; echo "broken exit=$?"
git checkout shikumi-okf/example/out/programs/heartbeat.md
```

Expect `clean exit=0`, then a `profile:` line on stderr mentioning a cardinality mismatch for
`title` and `broken exit=1`. Commit as in Milestone 1, with the same two trailers.

**Milestone 3.** Add the one line, then:

```bash
cd shikumi-okf && dhall format profile/shikumi.dhall && cd ..
cabal test shikumi-okf
$OKF validate shikumi-okf/example/out --profile shikumi-okf/profile/shikumi.dhall --profile-enforce; echo "clean exit=$?"
```

Then add a stray frontmatter key. Note that appending to the end of the file would add text
to the Markdown *body* and prove nothing; the key must go inside the metadata block, before
its closing `---`:

```bash
python3 - <<'PY'
import pathlib
p = pathlib.Path("shikumi-okf/example/out/programs/heartbeat.md")
lines = p.read_text().split("\n")
close = lines.index("---", 1)          # the second '---' closes the frontmatter
lines.insert(close, "owner: someone")
p.write_text("\n".join(lines))
PY
$OKF validate shikumi-okf/example/out --profile shikumi-okf/profile/shikumi.dhall --profile-enforce; echo "stray-key exit=$?"
git checkout shikumi-okf/example/out/programs/heartbeat.md
```

Expect `clean exit=0` and `stray-key exit=1`. Commit with the two trailers.

**Milestone 4.** Edit both type rules, then:

```bash
cd shikumi-okf && dhall format profile/shikumi.dhall && dhall type --file profile/shikumi.dhall >/dev/null && echo "profile OK" && cd ..
cabal test shikumi-okf
$OKF validate shikumi-okf/example/out --profile shikumi-okf/profile/shikumi.dhall --profile-enforce; echo "clean exit=$?"
python3 - <<'PY'
import pathlib
p = pathlib.Path("shikumi-okf/example/out/programs/heartbeat.md")
p.write_text(p.read_text().replace(
    "resource: shikumi://shinzui/example-app/programs/heartbeat",
    "resource: not-a-uri"))
PY
$OKF validate shikumi-okf/example/out --profile shikumi-okf/profile/shikumi.dhall --profile-enforce; echo "bad-resource exit=$?"
git checkout shikumi-okf/example/out/programs/heartbeat.md
```

Expect `clean exit=0` then `bad-resource exit=1`. Commit with the two trailers.

**Wrap-up.** Edit `shikumi-okf/CHANGELOG.md`, then run the whole sequence once more from
clean, including the regeneration-determinism check and the formatters this repository
enforces (`nixpkgs-fmt`, `fourmolu`, and `cabal-fmt`, wired through `nix/treefmt.nix`):

```bash
cabal build shikumi-okf
cabal test shikumi-okf
cabal run -v0 shikumi-okf-example -- shikumi-okf/example/out
git status --porcelain shikumi-okf/example/out
$OKF validate shikumi-okf/example/out --profile shikumi-okf/profile/shikumi.dhall --profile-enforce
cabal-fmt --check shikumi-okf/shikumi-okf.cabal
cd shikumi-okf && dhall format --check profile/shikumi.dhall && cd ..
```

The `git status --porcelain` line must print nothing, proving regeneration stayed
byte-identical. Then commit the changelog with the two trailers and fill in Outcomes &
Retrospective.


## Validation and Acceptance

The plan is complete when all of the following hold.

Running `cabal test shikumi-okf` from the repository root passes and its output contains a
`Profile` group with `profile/shikumi.dhall loads and compiles: OK` and
`generated bundle conforms to profile/shikumi.dhall: OK`. This is the behavior that did not
exist before: the test suite now reads the shipped descriptor rather than a Haskell
paraphrase of it.

That test demonstrably depends on the file's contents. Appending a line such as
`, bogusField = True` to `shikumi-okf/profile/shikumi.dhall` turns the suite red with a
message naming that path; restoring the file turns it green again. A test that passes in both
states is not actually reading the descriptor and the milestone is not done.

Each of the four value checks rejects a hand-broken document and accepts the untouched one.
With `OKF` pointing at the 0.3.0.0 binary as shown in Concrete Steps,
`$OKF validate shikumi-okf/example/out --profile shikumi-okf/profile/shikumi.dhall --profile-enforce`
exits 0 on the committed bundle, and exits non-zero after each of these four single-document
edits, each reverted with `git checkout` afterwards: turning `title: Heartbeat` into a
two-element list (cardinality), setting `timestamp: yesterday` in the frontmatter (format),
inserting an undeclared `owner: someone` key into the frontmatter (closed key set), and
replacing the `resource:` value with `not-a-uri` (URI format).

The generator's determinism guarantee is intact: after
`cabal run -v0 shikumi-okf-example -- shikumi-okf/example/out`,
`git status --porcelain shikumi-okf/example/out` prints nothing.

The formatters this repository enforces are satisfied:
`cabal-fmt --check shikumi-okf/shikumi-okf.cabal` and, from inside `shikumi-okf/`,
`dhall format --check profile/shikumi.dhall` both succeed silently.

Finally, `shikumi-okf/CHANGELOG.md` has an `## Unreleased` entry covering the new test and
each tightening, including the one consequence a consumer can observe — that
`okf validate --strict` now reports a missing recommended `timestamp` for bundles generated
without one — and the package `version:` field is unchanged.


## Idempotence and Recovery

Every step here is safe to repeat. The Dhall and Cabal edits are ordinary file edits;
`dhall format` and `cabal-fmt` are idempotent; `cabal build` and `cabal test` can run any
number of times.

The only steps that deliberately damage a tracked file are the "break it and watch it fail"
demonstrations, and each is paired with its own restore. For the generated bundle the
restore is `git checkout shikumi-okf/example/out/programs/heartbeat.md`, which is reliable
because that tree is committed. For the descriptor, take the backup copy shown in Concrete
Steps before corrupting it, or restore with
`git checkout shikumi-okf/profile/shikumi.dhall`. If a demonstration is interrupted midway,
`git status` shows exactly which files are dirty and `git checkout --` on each returns the
tree to a known-good state; nothing in this plan touches anything outside `shikumi-okf/` and
`docs/plans/`.

If the `data-files` approach in Milestone 1 does not resolve the profile path in some
environment, the fallback is a small candidate search in the test — try
`"profile/shikumi.dhall"` and then `"shikumi-okf/profile/shikumi.dhall"`, taking the first
that exists via `System.Directory.doesFileExist`, and failing with a message listing both
candidates. Record the switch in the Decision Log if it becomes necessary.

Each milestone is a separate commit that leaves the tree building and testing green, so
recovery from a bad milestone is `git revert` of that one commit. The dependency upgrade this
plan builds on is already committed as `835148f` and is not touched here.


## Interfaces and Dependencies

No new package dependencies are added. `okf-core` is already a dependency of both the
library and the test suite at `^>=0.3.0.0` (set in commit `835148f`), and every function this
plan calls lives in it. The `Paths_shikumi_okf` module is generated by Cabal, not a
dependency.

At the end of Milestone 1, `shikumi-okf/test/Main.hs` must use these functions, all exported
from module `Okf.Profile` in `okf-core`:

```haskell
loadProfileFile :: FilePath -> IO (Either Data.Text.Text ProfileSpec)
compileProfile  :: ProfileSpec -> Either (NonEmpty ProfileDefinitionError) CompiledProfile
validateProfile :: ValidationProfile -> CompiledProfile -> [Concept] -> [ProfileViolation]
```

together with the opaque type `Okf.Profile.CompiledProfile`, the value
`Okf.Validation.PermissiveConformance` of type `Okf.Validation.ValidationProfile`, and
`Paths_shikumi_okf.getDataFileName :: FilePath -> IO FilePath`. `Concept` comes from
`Okf.Bundle` and is already produced by `Shikumi.Okf.Generate.generateBundle`, whose
signature is unchanged:

```haskell
generateBundle :: AppInfo -> Maybe Data.Text.Text -> ProgramManifest -> Either GenerateError [Concept]
```

The test suite must also gain one new top-level helper:

```haskell
loadAndCompileProfile :: IO CompiledProfile
```

At the end of Milestone 4, `shikumi-okf/profile/shikumi.dhall` must still satisfy okf's
published schema — that is, from inside `shikumi-okf/`,
`dhall type --file profile/shikumi.dhall` succeeds and the expression inhabits
`okf.Profile`, where `okf` is
`../../../okf/okf-core/dhall/package.dhall`. The schema members it relies on are
`okf.Profile`, `okf.TypeRule`, `okf.FieldRule`, `okf.FrontmatterRules`, `okf.Cardinality`
(constructor `Scalar`, and `List` via `okf.mk.FieldRule.list`), `okf.FieldFormat`
(constructors `Rfc3339Utc` and `UriWithScheme`), the record-completion defaults
`okf.defaults.Profile`, `okf.defaults.TypeRule`, `okf.defaults.FrontmatterRules`,
`okf.defaults.FieldRule`, and the constructor helpers `okf.mk.FieldRule.documented` and
`okf.mk.FieldRule.list`.

Two external tools are used for verification and are not build dependencies: the `dhall`
command-line formatter and type checker (present in the development shell), and the `okf`
0.3.0.0 binary from the sibling checkout at `/Users/shinzui/Keikaku/bokuno/okf`. The `okf`
on `PATH` is 0.1.2.1 and cannot read this schema; upgrading that installation is outside
this plan's scope.
