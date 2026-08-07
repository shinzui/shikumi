# Changelog

## Unreleased

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
