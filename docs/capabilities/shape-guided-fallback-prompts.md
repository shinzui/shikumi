---
title: "Shape-guided fallback prompts"
type: Capability
description: "Show models without schema enforcement the JSON shape of every structured output field, including nested keys and closed enum values, in the marker-based fallback prompt."
generated:
  by: claude/opus-5-5
  at: "2026-09-30T17:30:00Z"
capabilityId: CAP-38
provider: mori://shinzui/shikumi
status: shipped
stability: experimental
since: "0.4.1.0"
packages:
  - shikumi
interface:
  - Shikumi.Adapter.fallbackAdapter
requires:
  - CAP-3
evidence:
  - kind: test
    resource: shikumi/test/FallbackGuideSpec.hs
    proves: The fallback system prompt for a list-of-records output carries a pinned JSON shape line with nested keys and enum values, and a scalar-only prompt is byte-for-byte unchanged.
  - kind: guide
    resource: docs/user/signatures-and-schemas.md
    proves: Documents the JSON shape line and when it appears.
---

# Shape-guided fallback prompts

The marker-based fallback in [CAP-3 provider-aware structured-output
adapters](structured-output-adapters.md) used to name each output field and its
description only. A field typed as a list of records gave the model no hint that
it should write objects. Now every output field whose schema (ignoring
nullability) is an object or an array gets one extra line under its marker:

```text
[[ ## concerns ## ]]  -- Readiness concerns
JSON shape: [{"statement": string, "severity": "Blocker" | "Major" | "Minor"}, ...]
```

Keys follow the record's field order; enum values are listed in full; nullable
values render as `<shape> | null`. The reply format does not change, so the
marker parser and demos are unaffected.

## Limits

- A prompt hint, not enforcement: a model can still write the wrong shape, and
  the typed decoder then reports a located `SchemaMismatch`.
- Nested field descriptions are omitted to keep the line short.
- Scalar fields, including top-level enums, get no shape line.
