# Changelog

## Unreleased

### Changed

- Widened the `http-client-tls` upper bound to admit 0.4. The web tool uses
  the unchanged `tlsManagerSettings` API, and 0.4 is the compatible line for
  the TLS 2.x / Crypton 1.1 cohort selected by baikai 0.6.

## 0.3.0.3 — 2026-08-29

### Changed

- Every library dependency now carries a PVP upper bound: `aeson`, `bytestring`,
  `containers`, `directory`, `effectful`, `filepath`, `generic-lens`,
  `http-client`, `http-client-tls`, `http-types`, `process`, `regex-tdfa`,
  `vector`. `cabal check` reported these under `missing-upper-bounds`. Without
  one, a future breaking release of a dependency enters a consumer's build plan
  unchecked — which is the failure the bound exists to prevent.

  Each bound admits the version this package is built and tested against and
  stops below the next major.

  `aeson` stops at `<2.3` rather than `<2.4`: baikai-openai 0.5 constrains it to
  `^>=2.2`, so aeson 2.3 is not reachable for this cohort and a wider bound
  would assert compatibility that cannot be exercised here.

  `http-client-tls` stops at `<0.4` for the same reason — baikai-openai 0.5
  constrains it to `^>=0.3`.

## 0.3.0.2 — 2026-08-07

### Changed

- Upgraded the `baikai` dependency to the `0.5` series (`>=0.5 && <0.6`).
  Dependency bounds only — no changes to the exported API.

## 0.3.0.1 - 2026-07-20

### Changed

- Upgraded the `baikai` dependency to the `0.4` series (`>=0.4 && <0.5`).
  Dependency bounds only — no changes to the exported API.

## 0.3.0.0 - 2026-07-05

### Added

- ReAct exposes `Proposal`, `renderStepLine`, and `summaryStep`; native ReAct
  turns can dispatch multiple tool calls in order before the next model turn.
- `CodeActConfig` now includes trajectory compaction settings, matching the ReAct
  context-window recovery path.
- Tooling exposes infrastructure-error classification, fetch-policy controls,
  capped HTTP response reading, and symlink information in directory listings.

### Changed

- **BREAKING** `ProtocolImpl.parsePropose` now returns `Proposal` instead of
  `Action`, and trajectories can contain the new `Summarized` action injected by
  compaction.
- **BREAKING** `CodeActConfig` record construction requires the new `compaction`
  field.
- Tool bodies now rethrow budget and context-window exhaustion instead of feeding
  them back to the model as recoverable observations.
- Built-in filesystem, shell, and web tools are hardened: execution timeouts are
  clamped, default fetch policy rejects common local/private targets, and fetches
  cap bytes while streaming.
- Refreshed the internal `shikumi` bound for the `0.3` series.

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
