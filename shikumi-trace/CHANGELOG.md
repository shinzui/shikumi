# Changelog

## Unreleased

## 0.2.0.3 — 2026-08-29

### Changed

- Every library dependency now carries a PVP upper bound: `aeson`, `bytestring`,
  `containers`, `directory`, `effectful`, `generic-lens`, `scientific`, `time`,
  `vector`. `cabal check` reported these under `missing-upper-bounds`. Without
  one, a future breaking release of a dependency enters a consumer's build plan
  unchecked — which is the failure the bound exists to prevent.

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

- Upgraded the `baikai` dependency to the `0.4` series (`>=0.4 && <0.5`).
  Dependency bounds only — no changes to the exported API.

## 0.2.0.0 - 2026-07-05

### Added

- `minSupportedFormatVersion` documents the oldest trace file format accepted by
  this build.

### Changed

- **BREAKING** `replayIndex` now returns `Either Text (Map CacheKey Value)` and
  fails closed when a trace records conflicting responses for the same cache key.
- Trace span mutation now fails loudly on unsupported concurrent stack use instead
  of silently corrupting the tree; `runTrace`/`tracedLLM` remain sequential.
- Retry spans now count traced retry attempts, trace rendering handles multiple
  roots, and child ordering is stable by numeric `span-N` ids.
- Refreshed internal `shikumi` and `shikumi-cache` bounds for the current package
  set.

## 0.1.1.0 - 2026-06-28

### Changed

- Refreshed internal `shikumi` and `shikumi-cache` bounds for the current package
  set.
- Updated tracing and replay internals to use label-based record access.

## 0.1.0.1 - 2026-06-21

### Changed

- Constrained the baikai dependency to the 0.2 series and refreshed internal shikumi and shikumi-cache bounds.

## 0.1.0.0 - 2026-06-13

### Added

- Initial Hackage release of hierarchical tracing and deterministic replay for shikumi.
- Trace spans, trace trees, program-node tracing, replay, trace storage, feedback logs, rendering, and a trace demo executable.
