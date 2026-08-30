---
title: "Typed signatures, schemas, and total decoding"
type: Capability
description: "Derive a model task's prompt contract, strict JSON Schema, typed decoder, and domain validation from ordinary Haskell record types."
generated:
  by: codex/gpt-5
  at: "2026-08-30T20:48:38Z"
capabilityId: CAP-1
provider: mori://shinzui/shikumi
status: shipped
stability: experimental
since: "0.1.0.0"
packages:
  - shikumi
interface:
  - Shikumi.Signature
  - Shikumi.Schema
  - Shikumi.Schema.Types
  - Shikumi.Error
evidence:
  - kind: test
    resource: shikumi/test/SchemaSpec.hs
    proves: Generic records derive the expected JSON Schema and model JSON decodes to typed values or located ShikumiError constructors.
  - kind: test
    resource: shikumi/test/ConstraintSpec.hs
    proves: Declarative string and numeric constraints appear in schemas and are enforced after decoding without partial failures.
  - kind: guide
    resource: docs/user/signatures-and-schemas.md
    proves: The public Field, Signature, ToSchema, ToPrompt, FromModel, Validatable, and Constrained authoring workflow is documented end to end.
---

# Typed signatures, schemas, and total decoding

A consumer describes an LM task with normal Haskell input and output records.
`Field`, `Signature`, `ToPrompt`, `ToSchema`, and `FromModel` turn those types into
the prompt, provider schema, and inverse decoder. Failures remain data:
malformed JSON, missing fields, type mismatches, enum mismatches, and domain-rule
violations become located `ShikumiError` values.

`Validatable` adds whole-value rules, while `Constrained` fields carry length,
pattern, numeric, and enumeration restrictions into both JSON Schema and the
post-decode validation pass. Optional fields are emitted in the strict
required-but-nullable shape expected by native structured-output providers.

## Limits

- Derivation targets record-shaped structured input and output; free-form text
  is handled by higher-level modules rather than pretending it is a record.
- `Validatable` is opt-in. Every predicted output and typed tool input must have
  an instance, even when the default rule accepts every value.
- Invalid type-level numeric constraint literals are reported as
  `ValidationFailure` during decode and omitted from the schema keyword; they do
  not crash schema derivation.
