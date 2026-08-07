# Changelog

## Unreleased

### Changed

- Every library dependency now carries a PVP upper bound: `aeson`, `effectful`,
  `hasql`. `cabal check` reported these under `missing-upper-bounds`. Without
  one, a future breaking release of a dependency enters a consumer's build plan
  unchecked — which is the failure the bound exists to prevent.

  Each bound admits the version this package is built and tested against and
  stops below the next major.

  `aeson` stops at `<2.3` rather than `<2.4`: baikai-openai 0.5 constrains it to
  `^>=2.2`, so aeson 2.3 is not reachable for this cohort and a wider bound
  would assert compatibility that cannot be exercised here.

## 0.1.2.2 — 2026-08-07

### Changed

- Upgraded the `baikai` dependency to the `0.5` series (`>=0.5 && <0.6`).
  Dependency bounds only — no changes to the exported API.

## 0.1.2.1 - 2026-07-20

### Changed

- Upgraded the test suite's `baikai` dependency to the `0.4` series
  (`>=0.4 && <0.5`). Dependency bounds only — no changes to the exported API.

## 0.1.2.0 - 2026-07-05

### Changed

- Postgres cache operations are now best-effort: lookup failures degrade to
  misses and store failures are ignored.
- Failed schema creation now releases the connection, and accidental use after
  `closePostgresCache` degrades safely.
- Refreshed internal `shikumi` and `shikumi-cache` bounds for the current package
  set.

## 0.1.1.0 - 2026-06-28

### Changed

- Refreshed internal `shikumi` and `shikumi-cache` bounds for the current package
  set.
- Updated Postgres backend internals to match the record-patterns conventions
  used across the package set.

## 0.1.0.1 - 2026-06-21

### Changed

- Constrained the test suite's baikai dependency to the 0.2 series and refreshed internal shikumi-cache bounds.

## 0.1.0.0 - 2026-06-13

### Added

- Initial Hackage release of the PostgreSQL backend for shikumi-cache.
- Postgres connection lifecycle helpers, table initialization, lookup, store, and cache interpreter support.
