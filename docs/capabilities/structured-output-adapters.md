---
title: "Provider-aware structured-output adapters"
type: Capability
description: "Render one typed signature through native JSON-schema, marker-based prompt fallback, or opt-in XML wire formats and decode every path through the same typed contract."
generated:
  by: codex/gpt-5
  at: "2026-08-30T20:48:38Z"
capabilityId: CAP-3
provider: mori://shinzui/shikumi
status: shipped
stability: experimental
since: "0.1.0.0"
packages:
  - shikumi
interface:
  - Shikumi.Adapter
  - Shikumi.Routing
requires:
  - CAP-1
evidence:
  - kind: test
    resource: shikumi/test/AdapterSpec.hs
    proves: Model capability detection selects native or prompt fallback rendering and fallback responses decode into the typed output.
  - kind: test
    resource: shikumi/test/RoutingSpec.hs
    proves: Native-capable routes attach the derived response schema and JSON demos while fallback routes retain marker prompts and strip internal metadata.
  - kind: test
    resource: shikumi/test/XmlAdapterSpec.hs
    proves: The opt-in XML adapter renders and parses nested and scalar output fields with the same located failures as the fallback decoder.
---

# Provider-aware structured-output adapters

An `Adapter i o` is the explicit seam between a typed
[signature](typed-signatures-and-schemas.md) and a provider request. Shikumi
auto-selects provider-native structured output for capable models and a
DSPy-style field-marker protocol elsewhere. Consumers can also choose the XML
adapter explicitly for models that follow tag-shaped output more reliably.

All paths converge on the same `FromModel` and `Validatable` decoder, so changing
wire format does not change application types or error handling. Few-shot demos
are translated to the corresponding native JSON or fallback representation.

## Limits

- Capability detection is based on the model provider/API identity known to
  shikumi; unusual compatible endpoints may need explicit routing configuration.
- XML is opt-in and never auto-selected.
- Native structured output constrains the response shape, but provider-level
  failures and semantic validation can still fail the call.
