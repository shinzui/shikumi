# Bundle Update Log

## 2026-08-30

- **Adoption**: Authored the initial capability catalog against the shared
  `coordination.capabilities` profile from `mori://shinzui/okf-profiles` v0.9.0.
  The 22
  capabilities (CAP-1 … CAP-22) were derived from public modules, user guides,
  hermetic tests, worked examples, package changelogs, git release tags, and
  Hackage release history. Every evidence resource was checked to exist, and
  the bundle was registered in `mori.dhall`.
- **Release-history note**: All library `since` values name published Hackage
  releases. `shikumi-cli` is marked `unreleased` because its package exists and
  is tested in the repository but has no Hackage release.
