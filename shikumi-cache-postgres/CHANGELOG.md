# Changelog

## Unreleased

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
