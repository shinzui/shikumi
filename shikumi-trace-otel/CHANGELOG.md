# Changelog

## Unreleased

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
