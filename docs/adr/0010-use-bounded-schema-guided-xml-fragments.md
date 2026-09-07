---
type: Architecture Decision Record
title: Use bounded schema-guided XML fragments
description: Decode a bounded XML vocabulary through the existing typed decoder and use JSON serialization for structured XML demonstrations.
docId: ADR-10
status: Accepted
date: 2026-09-07
timestamp: 2026-09-07T23:34:15Z
generated:
  by: process:codex
  at: 2026-09-07T23:34:15Z
---

# Use bounded schema-guided XML fragments

## Context

The previous XML adapter used the first closing tag and accepted structured data
only as JSON inside a field tag. Its `ToPrompt` output representation flattens
lists and shows records as presentation text, which cannot faithfully serialize
nested demonstrations. [Plan 55](../plans/55-decode-nested-xml-output-fields.md)
adds nested decoding without changing automatic adapter routing.

## Decision

Keep `xmlAdapter`'s public constraints and demonstration rendering compatible.
Both XML adapters use the internal `Shikumi.Adapter.Xml` codec to build an Aeson
value, then call `fromModelChecked` for located type errors and declared/domain
constraints. `nestedXmlAdapter` uses `ToJSON o` instead of `ToPrompt o`, allowing
structured demos without requiring a presentation-text instance. Top-level demo
fields follow signature order; nested object fields sort lexically.

The codec accepts sibling field elements, nested object properties and repeated
array `item` elements. It accepts self-closing elements, comments, CDATA, the five
predefined entities, and decimal/hexadecimal Unicode character references.
Element names start with a letter or underscore, followed by letters, digits,
underscores, hyphens or dots. Attributes, namespaces, declarations, processing
instructions and external entities are unsupported. Mixed non-whitespace text
and child elements are rejected. Unknown properties are ignored after parsing;
the first complete duplicate property wins at every object level. Only immediate
children satisfy a field. Explanatory text outside elements is ignored.

The entire fragment is checked before field selection. The maximum input is
1,048,576 Unicode code points and maximum element nesting is 64. Syntax and
resource-limit failures are `SchemaMismatch` messages beginning `XML: offset`,
with zero-based code-point offsets. No files or URLs are resolved. Shared typed
errors retain existing paths, including `people.[0].count`.

Schema guides support generated records, arrays, scalar types and nullable
`anyOf`. Empty containers follow their schema; missing properties stay absent.
Container text without child elements retains JSON-in-tag decoding. XML text
must escape ampersands and angle brackets, including within legacy JSON text.
Outer scalar whitespace is trimmed. Only nullable fields interpret plain `null`
as absence; CDATA distinguishes their literal string `null`. Required strings
always preserve `null` as text. This coercion rule belongs to XML and does not
change the marker adapter. Unsupported hand-written schema shapes use escaped
JSON fallback rendering and remain subject to the checked decoder.

## Consequences

The codec is intentionally a model-output fragment format, not a general XML
implementation. More XML features require an explicit format decision. Nested
rendering round-trips supported values subject to outer whitespace trimming,
valid XML characters and the input/depth limits. A manually defined `ToJSON`
instance must agree with its `ToSchema` and `FromModel` instances.

Hermetic adapter tests cover legacy and nested replies, typed demonstration
round-trips, scalar and constraint errors, malformed input and exact resource
boundaries. The offline adapters example demonstrates both formats.
