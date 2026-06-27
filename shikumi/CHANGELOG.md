# Changelog

## Unreleased

### Added

- `Shikumi.Program.nodeInstructionsIndexed :: Program i o -> [Text]`: the signature
  instruction of each `Predict` node, in `foldParams`/`nodeFieldsIndexed` order. Used
  by `shikumi-okf` to document model calls (EP-31, Milestone 5).

## 0.1.0.1 - 2026-06-21

### Fixed

- Adapted `Shikumi.Error.fromBaikaiError` and streaming response reassembly to the baikai 0.2 API.

### Changed

- Constrained baikai package dependencies to the 0.2 series for Hackage builds.

## 0.1.0.0 - 2026-06-13

### Added

- Initial Hackage release of the shikumi core runtime.
- Typed program and signature APIs, structured schema decoding, model routing, retries, budget tracking, multimodal helpers, streaming, refinement, rewards, and program combinators.
