# Changelog

## Unreleased

### Added

- Initial release of production-evidence optimization and promotion reports.
- Sealed dataset envelopes: adapter records with human, model or inferred labels and
  critiques, redaction before sealing, deterministic group-preserving splits into
  training, validation and a protected holdout, validation that reports every problem,
  and typed opening through `modelEvidenceCodec`. No exported function returns holdout
  examples.
- Program artifacts for baselines and candidates, pinned to a template by structural
  fingerprint and schema digests, with source revisions and the optimization record.
- Declared metric policies over built-in and custom measures, with constraints read in
  each metric's direction.
- `runEvidenceJob`: optimize on training and validation, gate structure, identity and
  exposure, then compare baseline and candidate once on the holdout through
  `evaluateCandidate`, under recorded or replayed provider outcomes.
- Ordered-outcome recordings that replay retries and typed provider errors, raise
  `ReplayDivergence` on a missing or surplus outcome, and refuse streamed or
  evidence-requesting calls with `UnrecordableCall`.
- Comparison reports concluded `Improved`, `Regressed`, `Inconclusive` or `Invalid` by a
  fixed order, and `verifyReportBinding` for lifecycle owners.
- Every envelope carries a BLAKE3 content digest verified on the raw JSON value.

### Changed

- Upgrade `mori://shinzui/baikai/packages/baikai` to `>=0.11.0.0 && <0.12`.
