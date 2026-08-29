# Changelog

## Unreleased

## 0.1.1.1 — 2026-08-29

### Changed

- Every library dependency now carries a PVP upper bound: `aeson`, `containers`,
  `generic-lens`, `scientific`, `time`, `unordered-containers`. `cabal check`
  reported these under `missing-upper-bounds`. Without one, a future breaking
  release of a dependency enters a consumer's build plan unchecked — which is
  the failure the bound exists to prevent.

  Each bound admits the version this package is built and tested against and
  stops below the next major.

  `aeson` stops at `<2.3` rather than `<2.4`: baikai-openai 0.5 constrains it to
  `^>=2.2`, so aeson 2.3 is not reachable for this cohort and a wider bound
  would assert compatibility that cannot be exercised here.

## 0.1.1.0 - 2026-07-05

### Changed

- OpenTelemetry export now marks incomplete spans, exports error status for
  recorded provider failures, reads the response model from recorded response
  JSON, and avoids revisiting cyclic span references.
- Live export now flushes and shuts down its tracer provider with bracketed
  cleanup even when export throws.
- Refreshed the internal `shikumi-trace` bound for the `0.2` series.

## 0.1.0.0 - 2026-06-13

### Added

- Initial Hackage release of OpenTelemetry export for shikumi trace trees.
- Batch and live export helpers that map shikumi spans to OpenTelemetry spans with GenAI-oriented attributes.
