# Changelog

## Unreleased

## 0.2.1.0 - 2026-07-05

### Added

- Shared optimizer budget metering helpers, effective-instruction inspection, and
  exact LLM-call counting for opaque optimizer runs.
- Budgeted ensemble search via `ensembleSearchWith` and exported
  `bootstrapKeptDemos` for metered bootstrap demo recovery.

### Changed

- Optimizers now reserve predicted LM-call cost before scoring/proposing and
  return the best candidate found so far when the next spend would exceed budget.
- Instruction search and seeding preserve effective instructions without
  serializing redundant overrides.
- Ensemble and KNN documentation now calls out structure-changing artifacts and
  how to load saved state against matching templates.
- Refreshed internal `shikumi`, `shikumi-compile`, `shikumi-eval`, and
  `shikumi-trace` bounds for the current package set.

## 0.2.0.0 - 2026-06-28

### Added

- `Generic` instances for `BootstrapConfig`, `CoproConfig`, and `Miprov2Config`.

### Changed

- Renamed exported `Candidate` record selectors to `params`, `perExample`, and
  `aggregate`.
- Renamed exported `PastInstruction` record selectors to `instruction` and
  `score`.
- Refreshed internal `shikumi`, `shikumi-compile`, `shikumi-eval`, and
  `shikumi-trace` bounds for the current package set.

## 0.1.0.1 - 2026-06-21

### Changed

- Constrained the test suite's baikai dependency to the 0.2 series and refreshed internal shikumi package bounds.

## 0.1.0.0 - 2026-06-13

### Added

- Initial Hackage release of optimizer APIs for shikumi programs.
- Labeled few-shot, bootstrap few-shot, instruction search, random search, GEPA, KNN, COPRO, MIPRO, ensemble, Pareto, and proposal helpers.
