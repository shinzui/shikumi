---
type: Friction Entry
title: "Package-directory dev shells bootstrap separate database clusters"
description: "Running the release skill cabal-check commands from package directories causes the dev-shell hook to create an ignored database cluster under each package."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-11-03T04:48:26Z"
frictionId: FRIC-2
status: "accepted"
impact: nuisance
kind: environment
origin: "mori://shinzui/shikumi"
affects: "mori://shinzui/shikumi"
plan: "docs/plans/68-support-streamed-judgment-programs-with-typed-result-parity.md"
workaround: "Enter nix develop at the repository root, then change directories inside its command; move newly generated unused clusters to a temporary recovery directory"
resolution: "Use the repository root for nix develop and change package directories inside the command; newly generated unused clusters were moved to a temporary recovery directory."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-11-03T04:50:06Z"
    change: "Retain the shell behavior and document the release-command workaround"
---
# Package-directory dev shells bootstrap separate database clusters

## Attempted

Run nix develop -c cabal check from each release package directory as prescribed

## Encountered

The shell hook initialized shikumi/db, shikumi-cache/db, shikumi-tools/db and shikumi-trace/db because it resolves database state relative to cwd

```text
creating directory /Users/shinzui/Keikaku/bokuno/shikumi/shikumi/db/db ... ok
```

## Workaround

Enter nix develop at the repository root, then change directories inside its command; move newly generated unused clusters to a temporary recovery directory
