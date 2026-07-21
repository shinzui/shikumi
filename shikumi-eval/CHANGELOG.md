# Changelog

## Unreleased

## 0.2.0.1 - 2026-07-20

### Changed

- Upgraded the `baikai` dependency to the `0.4` series (`>=0.4 && <0.5`).
  Dependency bounds only — no changes to the exported API.

## 0.2.0.0 - 2026-07-05

### Added

- Evaluation can enforce an optional per-example timeout via
  `EvalConfig.exampleTimeoutMs`.
- Usage accounting now includes streamed calls and exposes helpers for assistant
  messages and stream terminal events.

### Changed

- **BREAKING** `EvalConfig` record construction requires the new
  `exampleTimeoutMs` field.
- **BREAKING** `Score` no longer exports its constructor; use `mkScore`,
  `scoreZero`, `scoreOne`, and `unScore`.
- Reports render summed per-example latency as `latency-sum`, making concurrent
  evaluation accounting explicit.
- Refreshed the internal `shikumi` bound for the `0.3` series.

## 0.1.1.0 - 2026-06-28

### Added

- `EvalConfig` now derives `Generic`.

### Changed

- Refreshed the internal `shikumi` bound for the `0.2` series.

## 0.1.0.1 - 2026-06-21

### Changed

- Constrained the baikai dependency to the 0.2 series and refreshed internal shikumi bounds.

## 0.1.0.0 - 2026-06-13

### Added

- Initial Hackage release of typed evaluation for shikumi programs.
- Dataset, example, prediction, metric, score, report, embedding, golden-test, usage, and bounded evaluation APIs.
