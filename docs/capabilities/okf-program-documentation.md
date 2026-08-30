---
title: "OKF program and application documentation generation"
type: Capability
description: "Generate deterministic OKF v0.2 bundles that document typed shikumi programs, their fields, structure, parameters, model-call instructions, and containing applications."
generated:
  by: codex/gpt-5
  at: "2026-08-30T20:48:38Z"
capabilityId: CAP-22
provider: mori://shinzui/shikumi
status: shipped
stability: experimental
since: "0.1.0.0"
packages:
  - shikumi-okf
interface:
  - Shikumi.Okf.Generate
  - Shikumi.Okf.Render
  - Shikumi.Okf.Types
requires:
  - CAP-2
evidence:
  - kind: test
    resource: shikumi-okf/test/Main.hs
    proves: Program bodies match golden structure, generated bundles contain the expected concepts and links, regenerate byte-identically, and conform to the shipped profile.
  - kind: example
    resource: shikumi-okf/example/out/index.md
    proves: A committed generated OKF v0.2 bundle provides an openable example of the output layout.
  - kind: module
    resource: shikumi-okf/profile/shikumi.dhall
    proves: The package ships the exact OKF profile its generated Shikumi App and Shikumi Program concepts satisfy.
---

# OKF program and application documentation generation

`shikumi-okf` accepts existentially packaged typed programs plus application
metadata and writes an OKF bundle containing one application concept and one
concept per program. Program pages describe fields, constructor structure,
node parameters, and model-call instructions using the inspectable
[Program](composable-program-values.md) representation.

Generation targets OKF v0.2, can record caller-supplied provenance, ships the
matching profile as package data, and is deterministic when no timestamp is
supplied. That permits regenerate-and-diff checks in CI.

## Limits

- Opaque embedded nodes can only report that their internal structure is
  unavailable; the generator never introspects Haskell closures.
- Provenance timestamps are caller-supplied. Omitting them preserves byte-for-
  byte regeneration, while supplying them makes the caller responsible for
  their accuracy.
- This capability documents program structure; it does not execute or evaluate
  the program and does not claim behavioral correctness.
