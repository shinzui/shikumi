---
type: Friction Entry
title: "Cabal configure assertion after a package version bump"
description: "cabal configure of a bumped local package aborted with an mkPackageIndex assertion until stale in-place registrations of older versions were removed from dist-newstyle/packagedb."
generated:
  by: "claude-code/claude-opus-5-5"
  at: "2026-11-19T00:01:22Z"
frictionId: FRIC-3
status: logged
impact: detour
kind: tooling
origin: "mori://shinzui/shikumi"
affects: "mori://shinzui/shikumi"
plan: "docs/plans/70-add-production-evidence-optimization-and-promotion-reports.md"
workaround: "Moved every dist-newstyle/packagedb/ghc-9.12.4/*-inplace.conf whose version no longer matches the package's cabal file out of the package db and ran ghc-pkg recache"
---
# Cabal configure assertion after a package version bump

## Attempted

Build shikumi-optimize after bumping it from 0.3.1.0 to 0.4.0.0

## Encountered

Configuring library for shikumi-optimize-0.4.0.0 failed with 'Assertion failed ... mkPackageIndex, called at src/Distribution/Simple/PackageIndex.hs:229:17' (Cabal 3.16.1.0); deleting the package's build directory did not help

```text
Error: [Cabal-7125] Failed to build shikumi-optimize-0.4.0.0 ... The failure occurred during the configure step.
```

## Workaround

Moved every dist-newstyle/packagedb/ghc-9.12.4/*-inplace.conf whose version no longer matches the package's cabal file out of the package db and ran ghc-pkg recache
