# Changelog

## Unreleased

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
