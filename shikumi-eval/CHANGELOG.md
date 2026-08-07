# Changelog

## Unreleased

### Changed

- Every library dependency now carries a PVP upper bound: `aeson`, `bytestring`,
  `containers`, `effectful`, `generic-lens`, `tasty`, `tasty-golden`, `vector`.
  `cabal check` reported these under `missing-upper-bounds`. Without one, a
  future breaking release of a dependency enters a consumer's build plan
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
