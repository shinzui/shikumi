---
title: "Typed image input"
type: Capability
description: "Place an Image in a typed input record and lower its bytes and MIME type to the provider's native user-image content block without disturbing text-only prompts."
generated:
  by: codex/gpt-5
  at: "2026-08-30T20:48:38Z"
capabilityId: CAP-6
provider: mori://shinzui/shikumi
status: shipped
stability: experimental
since: "0.1.0.0"
packages:
  - shikumi
interface:
  - Shikumi.Multimodal
requires:
  - CAP-1
  - CAP-3
evidence:
  - kind: test
    resource: shikumi/test/MultimodalEndToEndSpec.hs
    proves: An image-bearing typed input reaches the model as a UserImage block and its answer decodes, while image-free input preserves the text-only context.
  - kind: test
    resource: shikumi/test/MultimodalSpec.hs
    proves: File and base64 constructors validate and retain the decoded bytes and inferred or supplied MIME type.
  - kind: example
    resource: shikumi-jitsurei/app/Multimodal.hs
    proves: A complete offline example renders a typed image input through the public adapter path.
---

# Typed image input

`Image` lets an ordinary input record carry decoded bytes plus a MIME type.
Generic `ToPrompt` discovery separates the first image field from the textual
fields and renders it as the `mori://shinzui/baikai` native `UserImage` content.
Constructors accept bytes directly, decode base64, or read a file and infer a
supported MIME type.

The same typed signature and adapter machinery from
[CAP-1](typed-signatures-and-schemas.md) and
[CAP-3](structured-output-adapters.md) handles the request.

## Limits

- Images are input-only and intentionally have no `ToSchema` output instance.
- The current public contract lowers the first image field; multi-image inputs
  are not promised.
- Audio and document blocks are not modeled by the underlying
  `mori://shinzui/baikai` content vocabulary used by this release.
