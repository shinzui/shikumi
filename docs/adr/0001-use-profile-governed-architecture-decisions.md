---
type: Architecture Decision Record
title: Use profile-governed architecture decisions
description: Keep durable Shikumi decisions in a flat OKF bundle with stable ADR handles and strict profile validation.
docId: ADR-1
status: Accepted
date: 2026-09-06
timestamp: 2026-09-07T02:10:23Z
generated:
  by: process:codex
  at: 2026-09-07T02:10:23Z
---

# Use profile-governed architecture decisions

## Context

The DSPy-informed implementation plans identify decisions about typed capture,
optimizer execution, tool histories, and artifact restoration that will need to
outlive their implementation sessions. Shikumi previously had no ADR corpus.
The user explicitly requested bootstrapping the ADR OKF profile on 2026-09-06.

Execution plans describe work to deliver; Architecture Decision Records (ADRs)
preserve a decision, its rationale, and consequences. Recording a planned feature
in an ADR does not mean that feature has shipped.

## Decision

Keep one decision per Markdown file directly under `docs/adr/`, governed by the
shared `documentation.architectureDecisions` profile from
`mori://shinzui/okf-profiles`. The local [profile descriptor](profile.dhall) selects
that export from the v0.14.0 package with a Dhall integrity hash. The release tag
and published release were verified before selecting the pin. Do not fork the
profile or weaken its constraints to accommodate a record.

Use stable, positive, unpadded `ADR-N` document handles allocated by OKF. Preserve
handles when renaming files and never recycle them. Register the bundle as `adrs`
in `mori.dhall`, targeting OKF 0.2. `index.md` and `log.md` are reserved navigation
and change-log files, not decision concepts. ADR-1 was allocated with `okf id next`.

Each ADR records its original decision date and repository-native status, such as
Proposed, Accepted, or Superseded. Its `generated` provenance identifies the actual
producer of the current content and revision time; `verified` is added only for
an independent verification that actually occurred. Preserve historical metadata
when migrating an existing decision. Do not mark an unimplemented design accepted
solely because it appears in a plan.

Use relative Markdown links within the repository and canonical Mori handle URIs
across repositories. Run `just check-adr` after every ADR change. Regenerate the
index and append a dated OKF log entry when adding or meaningfully revising a
record. Before allocating another handle, run:

```bash
okf id list docs/adr --profile docs/adr/profile.dhall
okf id next docs/adr --profile docs/adr/profile.dhall ADR
```

The implementation plans must distill proved durable decisions into this bundle
and cite them without replacing their own self-contained implementation context.

## Consequences

The repository has one discoverable, validated location for durable decisions.
Changing a filename does not change a cross-repository reference. Profile upgrades
must update the tag and computed integrity hash together and pass strict validation.

The initial bundle records its own adoption only. Optimizer, agent, and experimental
feature designs remain in their plans until their decision status and evidence
justify separate records. This avoids claiming implementation or independent
verification that has not occurred.

The check uses the installed `okf` CLI and Dhall profile resolution. The `justfile`
is the repository-native check surface; this bootstrap does not provision a new
CI toolchain. The adoption is explicit bootstrap work, not an automatic migration
of an existing corpus.
