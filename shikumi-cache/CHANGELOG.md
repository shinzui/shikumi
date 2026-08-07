# Changelog

## Unreleased

## 0.1.2.2 — 2026-08-07

### Changed

- Upgraded the `baikai` dependency to the `0.5` series (`>=0.5 && <0.6`).

- `Shikumi.Cache.ResponseJSON`'s orphan `ToJSON`/`FromJSON` for
  `Baikai.Response.Response` are written out by hand instead of derived, and
  they neither write nor read baikai 0.5's new `evidence` field. A cache hit
  replays a stored response without any provider call, so carrying the
  original call's `ModelCallEvidence` would attribute a record of a real
  boundary crossing to a call that never made one. Decoding always yields
  `evidence = Nothing`.

  The encoded keys are otherwise unchanged, so entries written by a pre-0.5
  shikumi still read back and `currentKeyVersion` is untouched. (baikai
  deliberately ships no `FromJSON ModelCallEvidence`, so the derived instance
  could not have been kept regardless.)

## 0.1.2.1 - 2026-07-20

### Changed

- Upgraded the `baikai` dependency to the `0.4` series (`>=0.4 && <0.5`).
  Dependency bounds only — no changes to the exported API.

## 0.1.2.0 - 2026-07-05

### Added

- `CacheConfig`, `defaultCacheConfig`, and `cachedLLMWith` for a shared policy
  layer across cache backends, including optional TTL-based entry expiry.
- `Shikumi.Cache.Backend.Effort` for best-effort backend error handling and
  `stripMessageTimestamps` for canonical cache-key inspection.

### Changed

- Cache keys now include endpoint identity, default/per-call headers, provider
  compatibility settings, and omit message construction timestamps. This bumps
  `currentKeyVersion` to `shikumi-cache/v2`, invalidating old cache entries and
  old trace replay keys.
- `cachedLLM` no longer stores in-band provider error responses, and persistent
  backend lookup/store failures degrade to cache misses or no-ops.
- Refreshed the internal `shikumi` bound for the `0.3` series.

## 0.1.1.0 - 2026-06-28

### Changed

- Refreshed the internal `shikumi` bound for the `0.2` series.
- Updated SQLite backend internals to match the record-patterns conventions used
  across the package set.

## 0.1.0.1 - 2026-06-21

### Changed

- Constrained the baikai dependency to the 0.2 series and refreshed internal shikumi bounds.

## 0.1.0.0 - 2026-06-13

### Added

- Initial Hackage release of provider-neutral response caching for shikumi.
- Content-addressed cache keys, in-memory and SQLite cache backends, cached LLM interpretation, and response JSON support shared by backend packages.
