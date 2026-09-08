---
title: "Bounded nested XML structured output"
type: Capability
description: "Decode nested XML records and arrays from a model reply into typed values under explicit depth, size, and well-formedness limits, for models that produce XML more reliably than JSON."
generated:
  by: claude/opus-5
  at: "2026-09-08T19:15:51Z"
capabilityId: CAP-26
provider: mori://shinzui/shikumi
status: shipped
stability: experimental
since: "0.4.0.0"
packages:
  - shikumi
interface:
  - Shikumi.Adapter.Xml
  - Shikumi.Adapter
requires:
  - CAP-3
evidence:
  - kind: test
    resource: shikumi/test/XmlAdapterSpec.hs
    proves: Nested records and arrays decode to typed values; depth, length, entity, CDATA, and malformed-tag limits produce located schema-mismatch errors rather than partial parses.
  - kind: example
    resource: shikumi-jitsurei/app/Adapters.hs
    proves: A runnable program selects an XML adapter and round-trips a nested typed output.
  - kind: guide
    resource: docs/user/signatures-and-schemas.md
    proves: Documents the XML schema guide shown to the model and how nested fields are rendered and parsed.
---

# Bounded nested XML structured output

`nestedXmlAdapter` extends shikumi's XML output path from flat tag extraction
to genuinely nested structure: records become nested elements, arrays become
repeated `<item>` elements, and both decode into the same typed outputs the
JSON adapters produce. `xmlSchemaGuide` renders the corresponding instructions
shown to the model.

The parser is deliberately strict and bounded. It enforces a nesting depth limit
of 64 and an input length limit of 1 MiB, validates XML character ranges, rejects
attributes, namespaces, processing instructions, and mixed text-with-children
content, and resolves only the five standard entities plus numeric character
references. Every failure is a located `SchemaMismatch` naming a code-point
offset, so a malformed reply is a typed error rather than a partial decode.

Nullable string fields keep the literal text `null` distinguishable from an
absent value through CDATA provenance — a distinction a naive tag scraper loses.

This is growth of
[CAP-3 provider-aware structured-output adapters](structured-output-adapters.md);
the legacy flat XML rendering and JSON-in-tag container decoding are unchanged
and still available.

## Limits

- Not a general XML parser. Attributes, namespaces, DTDs, and processing
  instructions are rejected by design.
- Depth is capped at 64 and input at 1 MiB; larger replies fail rather than
  stream.
- Schema forms outside generated record, array, scalar, and nullable shapes fall
  back to escaped JSON values inside the element.
- XML remains a fallback for models without reliable native structured output.
  Where a provider enforces a JSON schema natively, that path is still the
  reliable one.
