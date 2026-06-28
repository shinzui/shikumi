# Changelog

## Unreleased

## 0.2.0.0 - 2026-06-28

### Added

- Built-in filesystem, shell, and web tool modules, plus helpers for assembling
  built-in tool registries.
- `Shikumi.Tool.Env`, an execution-environment record for filesystem and process
  backed tools.
- `Shikumi.Tool.Web`, a swappable HTTP/search client layer for web tools.

### Changed

- `ReActConfig` now includes a `compaction` field, and ReAct agents compact older
  trajectory steps when usage approaches the model context window.
- Refreshed the internal `shikumi` bound for the `0.2` series.

## 0.1.0.1 - 2026-06-21

### Changed

- Constrained the baikai dependency to the 0.2 series and refreshed internal shikumi bounds.

## 0.1.0.0 - 2026-06-13

### Added

- Initial Hackage release of typed tool registries and ReAct-style agents for shikumi programs.
- CodeAct, program-of-thought helpers, prompt utilities, and a restricted deterministic code interpreter for offline tests.
