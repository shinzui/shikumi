# Changelog

## Unreleased

### Changed

- **BREAKING** `Validatable` is now opt-in and enforced by the decode path in
  every program runner. The catch-all `instance {-# OVERLAPPABLE #-} Validatable a`
  has been removed, so a type's `Validatable` rule is no longer silently skipped
  when a program runs through `runProgram`, `runProgramConc`, `streamProgram`, or
  `chainOfThought` — a violated rule now surfaces as `Left (ValidationFailure …)`.
  Migration: declare an instance for every `Predict` output type and every typed
  tool input. A type with no rules needs one line — `instance Validatable Foo`
  (the default `validate = Right` applies) or add `Validatable` to a
  `deriving anyclass (…)` list. `runPredict`, `streamPredict`, `chainOfThought`,
  and `chainOfThoughtRaw` gained a `Validatable o` constraint, and
  `WithReasoning o` now has a delegating `Validatable` instance that runs the
  wrapped value's rule.

- **BREAKING** Derived JSON Schemas now satisfy OpenAI strict mode. A `Maybe`
  field is emitted as required-but-nullable (listed in `required` with a nullable
  schema) instead of being omitted from `required`, and `enumSchema` carries an
  explicit `"type": "string"`. This changes the shape real OpenAI/Anthropic
  requests send; the decode path is unchanged and still tolerates a missing key or
  explicit `null` for `Maybe` fields.

- Native structured-output requests are now coherent. When a program routes to a
  native-capable model, the request carries a system prompt describing the JSON
  object to produce and demos rendered as JSON — not `[[ ## field ## ]]` marker
  sections — via a new native render channel (`attachNativeRender` /
  `nativeRenderPieces`, swapped in by `routeLLM`/`translateForWire`). Fallback
  models are unchanged. `parseResponse` now keeps the precise native decode error
  for JSON reply bodies instead of masking it behind a misleading `MissingField`
  from the marker parser. `Shikumi.Routing.translateForWire` widened to
  `Model -> Context -> Options -> (Context, Options)`.

## 0.2.0.0 - 2026-06-28

### Added

- `Shikumi.Compaction`, with helpers for compacting older working context when a
  model approaches its context window.
- `Shikumi.Program.nodeInstructionsIndexed :: Program i o -> [Text]`: the signature
  instruction of each `Predict` node, in `foldParams`/`nodeFieldsIndexed` order. Used
  by `shikumi-okf` to document model calls (EP-31, Milestone 5).

### Changed

- `ShikumiError` now distinguishes provider context-window failures with the new
  `ContextWindowExceeded` constructor.

## 0.1.0.1 - 2026-06-21

### Fixed

- Adapted `Shikumi.Error.fromBaikaiError` and streaming response reassembly to the baikai 0.2 API.

### Changed

- Constrained baikai package dependencies to the 0.2 series for Hackage builds.

## 0.1.0.0 - 2026-06-13

### Added

- Initial Hackage release of the shikumi core runtime.
- Typed program and signature APIs, structured schema decoding, model routing, retries, budget tracking, multimodal helpers, streaming, refinement, rewards, and program combinators.
