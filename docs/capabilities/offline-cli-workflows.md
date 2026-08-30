---
title: "Offline-capable evaluation, trace, optimize, and replay CLI"
type: Capability
description: "Register typed tasks and expose deterministic eval, trace, optimization, trace recording, and replay workflows through one command-line interface."
generated:
  by: codex/gpt-5
  at: "2026-08-30T20:48:38Z"
capabilityId: CAP-21
provider: mori://shinzui/shikumi
status: shipped
stability: experimental
since: "unreleased"
packages:
  - shikumi-cli
interface:
  - Shikumi.Cli
  - Shikumi.Cli.Registry
  - Shikumi.Cli.Runtime
  - Shikumi.Cli.Run
requires:
  - CAP-12
  - CAP-14
  - CAP-15
  - CAP-16
evidence:
  - kind: test
    resource: shikumi-cli/test/Main.hs
    proves: Eval, trace, optimize, record, and replay commands execute deterministically; trace IDs reject path escape; recorded replay makes zero provider calls.
  - kind: guide
    resource: docs/user/cli.md
    proves: Task registration, subcommands, offline runtime wiring, and construction of a custom CLI are documented.
  - kind: example
    resource: shikumi-cli/example/fixture/sentiment.json
    proves: The repository includes a compiled-program fixture consumed by the offline CLI workflows.
---

# Offline-capable evaluation, trace, optimize, and replay CLI

`shikumi-cli` provides a registry that bundles a typed program, fixtures,
metrics, and runtime wiring behind a command name. The executable exposes
evaluation, trace rendering, optimization, trace recording, and deterministic
replay. The shipped example registry uses in-process stub responses, so its
default workflows require no API key or network.

The CLI composes [replay](deterministic-replay.md),
[evaluation](typed-evaluation.md),
[compilation](pure-program-compilation.md), and
[optimization](budgeted-program-optimization.md).

## Release history

The package is implemented at version `0.1.0.0` in the repository but has no
Hackage release as of this catalog revision. Its profile-level `since` value is
therefore `unreleased`, not a fabricated release number.

## Limits

- The built-in registry is an example, not dynamic discovery of arbitrary
  Haskell programs. Applications construct their own executable and registry.
- Live provider behavior depends on the runtime a custom registry installs; the
  default example is deliberately offline.
- Trace identifiers are file-backed and validated against path traversal, but
  callers still choose and protect the store directory.
