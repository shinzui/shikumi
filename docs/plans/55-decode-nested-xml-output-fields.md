---
id: 55
slug: decode-nested-xml-output-fields
title: "Decode nested XML output fields"
kind: exec-plan
created_at: 2026-09-07T01:50:18Z
master_plan: "docs/masterplans/10-dspy-informed-optimizer-and-agent-evolution.md"
---

# Decode nested XML output fields


This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current during implementation. Promote durable architectural decisions to docs/adr/ before completion.

## Purpose / Big Picture


Users will decode records and lists expressed as nested XML, such as `<author><name>Ada</name></author>` and `<bullets><item>one</item><item>two</item></bullets>`, into their existing typed outputs. They will also render demonstrations in that same format. Existing flat XML replies containing JSON remain accepted. A hermetic adapter test and the adapters example will demonstrate both formats without a model account.

## Progress


(No implementation steps completed.)

## Surprises & Discoveries


(None yet.)

## Decision Log


2026-09-06: Keep the public type of `xmlAdapter` unchanged and add `nestedXmlAdapter` with a `ToJSON o` constraint for faithful demonstration rendering. `ToPrompt` flattens lists and uses `Show` for nested records, so it cannot reconstruct arbitrary structured demonstrations. Both adapters share nested decoding; the additive adapter advertises and renders the richer format.

2026-09-06: Implement a small, explicitly defined XML fragment vocabulary using the existing text and containers packages. This is a model-output codec, not a general XML processor. No external entities, DTDs, namespace resolution, or additional package dependency are needed.

## Outcomes & Retrospective


(To be filled during implementation.)

## Context and Orientation


`shikumi/src/Shikumi/Adapter.hs` defines `Adapter i o`, whose `render` produces a request and whose `parse` decodes a response. `xmlAdapter` currently extracts each output field with `extractTag`, which takes the text between the first opening tag and the next closing tag. It cannot balance repeated nested tag names. `sectionsToObject` interprets non-string contents as JSON, so current nested records work only when supplied as JSON inside their outer XML tag. `renderOutputXml` uses `toPromptFields`; list and nested-record formatting is therefore presentation text rather than structured serialization.

`shikumi/src/Shikumi/Schema.hs` supplies `deriveSchema`, `fromModelChecked`, nullable `anyOf` schemas, and path-carrying errors. Convert XML into an Aeson `Value`, then retain this decoding and validation seam. `shikumi/test/XmlAdapterSpec.hs` currently tests rendering, flat JSON-in-tag decoding, and a missing required field. `shikumi-jitsurei/app/Adapters.hs` is the user-facing executable example. `shikumi/shikumi.cabal` registers production modules and test modules; `shikumi/test/Main.hs` includes the existing XML test group. [ADR-1](../adr/0001-use-profile-governed-architecture-decisions.md) now governs decision records: allocate stable ADR-N handles, preserve decision/provenance metadata, update the bundle index/log, and run `just check-adr`. No earlier feature-specific ADR was found during the initial review. Existing scope is documented in `docs/plans/26-adapter-completeness-and-declarative-field-constraints.md`.

Upstream provenance is `mori://stanfordnlp/dspy`, commit `33aaa19e0`, which added nested XML adapter data. The project is currently unregistered locally and the artifact-level commit URI is pending. This is behavioral inspiration, not a Python dependency or a promise of complete XML parity.

## Plan of Work


### Milestone 1: Balanced fragment decoding


Create `shikumi/src/Shikumi/Adapter/Xml.hs` as an internal module and register it in the library stanza. Parse a fragment containing sibling field elements into a small element/text tree, balancing names with a stack or recursive descent. Recognize self-closing tags, comments, CDATA, and the five predefined entities plus numeric character references. Reject malformed nesting, unsupported declarations and attributes, invalid Unicode references, and unterminated content with `SchemaMismatch` beginning `XML:` and a location. Never resolve files or URLs. Permit ordinary explanatory text outside field elements; unknown top-level elements are ignored as before. Duplicate known sibling fields retain the first complete element, preserving existing behavior; a nested occurrence must never satisfy a missing outer field. Enforce depth 64 and input length 1,048,576 Unicode code points before recursion to bound parser work. Error messages must identify the exceeded limit.

Convert each known element using its property schema. Object properties recurse into child elements; arrays contain repeated `<item>` children, including arrays of objects and nested arrays. Unwrap nullable `anyOf` to choose the non-null schema. For a nullable schema, an element containing only `null` uses the explicit-null convention; a nonnullable string element containing `null` is the literal string. This repairs the current shared coercion helper’s unconditional conversion of `null` to JSON null for required strings. Keep that XML-specific correction out of the marker adapter. Omitted nullable fields remain omitted and decode as `Nothing`. Empty containers decode as empty array/object according to schema; empty strings decode as empty text. For a nullable string, CDATA containing `null` distinguishes the literal string from absence. Reject non-whitespace text mixed with child elements for structured fields. Scalar strings retain inner whitespace except the existing outer trimming behavior, decode entities, and accept CDATA. Scalars of other types use existing JSON coercion and checked decoding. For object/array elements with no child elements, retain legacy JSON-in-tag parsing. Missing required fields still reach `fromModelChecked` as absent keys and produce located `MissingField`; wrong nested scalar types retain paths such as `author.name` or `bullets[1]`.

Replace only XML extraction in `xmlAdapter`; marker and native adapters retain their current paths. Run the XML test group and observe old flat examples plus new nested examples decode identically.

### Milestone 2: Schema-guided nested rendering


Export `nestedXmlAdapter` from `shikumi/src/Shikumi/Adapter.hs`. Its render function uses existing system/header/input rendering, but renders output demos from `toJSON` and guides from `deriveSchema @o`. Emit object property elements recursively and array item elements; escape text ampersands and angle brackets so a demo containing `</author>` remains a scalar. Render null as `null`, booleans as lowercase `true`/`false`, numbers as JSON numeric literals, and a nullable literal string equal to `null` as CDATA. Render a nonnullable string equal to `null` as ordinary text. Split embedded CDATA terminators safely if this representation is used. Preserve output-field order from the signature at the top level and use a deterministic property ordering below it. Guides show nested object fields, repeated array items, and nullable handling. Rejecting unsupported schema features is not a new runtime failure in `render`: document the generated-schema subset, and render an escaped JSON scalar fallback for unsupported manually supplied schema forms. Parsing follows the existing checked decoder, which determines whether those forms are valid.

Keep `xmlAdapter`'s render behavior and constraints compatible. Share the new parser between both adapters. Update comments that currently imply nested XML support from JSON coercion. Verify that a rendered nested assistant demonstration, extracted from the request by the test, parses back to the original typed output.

### Milestone 3: Demonstrate and document the codec


Extend `shikumi/test/XmlAdapterSpec.hs` with nested fixtures and all acceptance cases below, reusing `Fixtures` where suitable and adding a local record for arrays of records. Update `shikumi-jitsurei/app/Adapters.hs` to print successful flat and nested decoding and a nested demonstration round-trip. Update the relevant package changelogs and adapter documentation with the additive constraint and exact XML vocabulary. Record the format/compatibility decision in a local ADR following the repository convention discovered at implementation time. Finish by running both affected package tests and the example.

## Concrete Steps


Run from the repository root in its development shell:

```bash
nix develop .#ghc9124 -c cabal test shikumi:shikumi-test --test-options='-p XmlAdapterSpec'
nix develop .#ghc9124 -c cabal test shikumi:shikumi-test
nix develop .#ghc9124 -c cabal build shikumi-jitsurei:exe:jitsurei-adapters
nix develop .#ghc9124 -c cabal run shikumi-jitsurei:exe:jitsurei-adapters
nix fmt
```

The tests must exit zero with all cases passing. The example must display `Right` results for both legacy and nested replies and `True` for the nested demonstration round-trip; record its actual short output here during implementation. Formatting must leave no unrelated edits.

## Validation and Acceptance


The existing `xmlBody` must still decode to `expectedSummary`. Replacing its author JSON with `<name>Ada</name>` and bullets JSON with item elements must produce that same value. A list of two records, a list of lists, empty containers, nullable omission/null, escaped ampersands and tag-like string contents must round-trip through `nestedXmlAdapter` demos. A nullable literal `null` string must differ from `Nothing` under the documented CDATA convention; a nonnullable `null` string remains a string without CDATA. Boolean and numeric demonstrations round-trip as typed values. A nested same-name tag must balance correctly. A nested field with the name of a missing top-level field must not satisfy the outer requirement. Duplicate top-level fields retain the first complete value; unknown elements do not become output properties. Malformed nesting, unsupported declarations, invalid entities, and depth/size overflow produce bounded typed failures rather than crashes or partial success. Scalar type failures carry the full nested path, and declared field constraints still execute. The existing native and fallback adapter tests must continue passing.

## Idempotence and Recovery


All validation is hermetic and repeatable. No stored data migration is required. Keep legacy fixtures throughout development to catch accidental format changes. If the new renderer fails for a supported type, fix its schema/value traversal; do not silently fall back to flattened `ToPrompt` output. Re-run only failed/affected tests after edits before the final package checks.

## Interfaces and Dependencies


The internal `Shikumi.Adapter.Xml` module provides pure helpers conceptually named `decodeXmlFields :: Value -> Text -> Either ShikumiError Value`, `renderXmlFields :: Value -> Value -> Text`, and `xmlSchemaGuide :: Value -> Text`. The first `Value` is JSON Schema; the second renderer value is the demonstration object. Keep the tree representation internal. The public `nestedXmlAdapter` has the same constraints as `xmlAdapter` plus `ToJSON o` and returns `Adapter i o`. Its input rendering still uses `ToPrompt i`. Use existing Aeson, text, containers and vector dependencies; no bounds changes are planned. If a dependency API needs investigation, locate its source and docs with Mori before coding. No runtime adapter-router selection is added by this plan.

Revision (2026-09-06): linked the newly bootstrapped ADR bundle and its authoring/check contract; implementation status is unchanged.
