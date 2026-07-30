# Changelog

## Unreleased

### Added

- `profile/shikumi.dhall` is now shipped as a Cabal `data-files` entry, so
  installing this package also installs the profile its bundles are meant to
  satisfy.

### Changed

- The test suite now checks the real `profile/shikumi.dhall` instead of a Haskell
  paraphrase of it. A new `Profile` group loads the descriptor (located through
  `Paths_shikumi_okf.getDataFileName`, so it does not depend on the directory
  `cabal` was invoked from), compiles it, and validates the generated bundle
  against it under `PermissiveConformance` — the same mode
  `okf validate --profile --profile-enforce` uses. A descriptor that stops
  type-checking, stops compiling, or stops describing what the generator emits is
  now a red test; previously it could rot unnoticed across releases, which is
  exactly what had happened. The hermetic `Conformance` group it replaces asserted
  the same conventions against an in-process copy and is gone.
- **Breaking for profile consumers.** The profile now checks what frontmatter
  values *contain*, not only that keys are present. `type`, `title`,
  `description`, and `resource` are declared `Cardinality.Scalar`, so a
  list-valued `title` is a violation. `timestamp` is declared as a recommended
  scalar with the `Rfc3339Utc` format, so a value like `yesterday` is a violation;
  cardinality and format are checked in every validation mode, so declaring it
  *recommended* buys the format check without demanding the key be present.
- **Breaking for profile consumers.** `allowUnknownFields = False` closes the
  top-level key set. This cannot reject a generated document — a closed set still
  always admits the six core OKF keys, which are exactly what the generator emits
  — but a hand-added stray key in a generated bundle is now reported.
- **Breaking for profile consumers.** `resource` moved from the profile-wide
  `recommended` list into each type's own `required` list and carries
  `UriWithScheme "shikumi"`, so it is now required on both document kinds and its
  value must parse as an absolute `shikumi://` URI. `tags` is recommended as a
  `List` on `Shikumi Program` only.
- **Consequence for consumers.** `okf validate --strict` now reports a
  missing-recommended `timestamp` on bundles generated without one. That is
  correct for a strict authoring run: `timestamp` is optional by design, because
  `generateBundle` takes it as an explicit argument and omitting it is what makes
  regeneration byte-identical. Ordinary (non-`--strict`) validation is unaffected,
  and the committed `example/out` bundle still validates and regenerates
  byte-identically.
- Moved the `okf-core` bound from `^>=0.1.0.0` to `^>=0.3.0.0`, the newest release
  on Hackage. No source changes: the producer API this package uses (`Okf.Bundle`,
  `Okf.ConceptId`, `Okf.Document`, `Okf.Index`) is unchanged across both major
  bumps, and the breaking changes in `0.2`/`0.3` are confined to the profile
  compilation and validation API this package does not call.
- **Breaking for profile consumers.** Migrated `profile/shikumi.dhall` to the
  `0.3.0.0` profile schema; reading it now requires `okf` `>=0.3`. The schema made
  `frontmatter.required`/`recommended` `List FieldRule` instead of `List Text`,
  added `description`, `allowUnknownFields`, and `idField` to `Profile`, and added
  `description`, `frontmatter`, and `idPrefix` to `TypeRule`. The descriptor now
  imports okf's published `dhall/package.dhall` entry point and uses
  record-completion defaults (`::`) with the `mk.FieldRule` constructors, so later
  additive, defaulted schema fields will not break it again.
- The migrated profile keeps its previous meaning exactly — closed types, the same
  two required and two recommended keys, open frontmatter, no `idField`, and
  default `Any` cardinality with no `format` — and now also documents each key and
  concept type in prose, which the old schema had no field for. Checked with `okf`
  `0.3.0.0` against the committed `example/out` bundle: `validate` and
  `--profile-enforce` both exit 0 and regeneration stays byte-identical.

## 0.1.0.1 - 2026-07-05

### Changed

- Refreshed the internal `shikumi` bound for local builds against the `0.3`
  series now that `okf-core` is available on Hackage.

## 0.1.0.0 - 2026-06-28

### Added

- Initial package scaffold (EP-31, Milestone 1): `Shikumi.Okf.Types` defining
  `SomeProgram`, `ProgramDoc`, `ProgramManifest`, and `AppInfo`.
- Program rendering and bundle generation (Milestones 2–3): `Shikumi.Okf.Render`
  (`renderProgramBody`) and `Shikumi.Okf.Generate` (`generateBundle`,
  `writeProgramBundle`, and the per-concept builders), producing one `Shikumi App`
  concept linking to one `Shikumi Program` concept per program.
- Shared OKF profile `profile/shikumi.dhall`, a worked `shikumi-okf-example`
  executable, and the committed `example/out` bundle (Milestone 4). Verified with
  the standalone `okf` CLI: `validate`, `--profile-enforce`, and `graph --json`.
- Model-call instructions in rendered bodies (Milestone 5): each `Predict` node's
  signature instruction now appears under its model call, via the new core accessor
  `Shikumi.Program.nodeInstructionsIndexed`.
