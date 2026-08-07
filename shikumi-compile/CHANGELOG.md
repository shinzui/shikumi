# Changelog

## Unreleased

### Changed

- Every library dependency now carries a PVP upper bound: `aeson`, `bytestring`,
  `effectful`. `cabal check` reported these under `missing-upper-bounds`.
  Without one, a future breaking release of a dependency enters a consumer's
  build plan unchecked — which is the failure the bound exists to prevent.

  Each bound admits the version this package is built and tested against and
  stops below the next major.

  `aeson` stops at `<2.3` rather than `<2.4`: baikai-openai 0.5 constrains it to
  `^>=2.2`, so aeson 2.3 is not reachable for this cohort and a wider bound
  would assert compatibility that cannot be exercised here.

## 0.2.0.2 — 2026-08-07

### Changed

- Upgraded the `baikai` dependency to the `0.5` series (`>=0.5 && <0.6`).
  Dependency bounds only — no changes to the exported API.

## 0.2.0.1 - 2026-07-20

### Changed

- Widened the `generic-lens` bound to `>=2.2 && <2.4` (admits 2.3) and upgraded
  the test suite's `baikai` dependency to the `0.4` series (`>=0.4 && <0.5`).
  Dependency bounds only — no changes to the exported API.

## 0.2.0.0 - 2026-07-05

### Changed

- **BREAKING** Compiled state JSON now stores a structural shape fingerprint plus
  parameters. Legacy bare parameter arrays are rejected and must be re-encoded.
- `decodeCompiledOnto` now fails with a shape-mismatch error when saved state is
  loaded onto the wrong compiled program template.
- RAG now stores retrieved context in serializable node parameters, so RAG state
  survives compiled-state encode/decode.
- Refreshed the internal `shikumi` bound for the `0.3` series.

## 0.1.1.0 - 2026-06-28

### Changed

- Refreshed the internal `shikumi` bound for the `0.2` series.
- Updated compiler internals to use label-based record updates.

## 0.1.0.1 - 2026-06-21

### Changed

- Constrained the test suite's baikai dependency to the 0.2 series and refreshed internal shikumi bounds.

## 0.1.0.0 - 2026-06-13

### Added

- Initial Hackage release of pure compiler transformations for shikumi programs.
- Zero-shot, few-shot, chain-of-thought, retrieval-augmented generation, retriever, compiled-program, and serialization APIs.
