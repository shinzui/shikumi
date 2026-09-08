---
name: release
description: >
  Cut a release of the shikumi Haskell packages and publish them to Hackage following the
  Haskell PVP (A.B.C.D). Inspects changes since each package's last tag, computes the version
  bump, updates cabal versions, internal dependency bounds, and changelogs, audits the
  docs/capabilities OKF catalog for capabilities the release adds or changes, runs the
  project's format/build/test/check gates, commits, tags, pushes, publishes to Hackage in
  dependency order, and creates per-package GitHub releases. Use when preparing a Hackage
  release.
argument-hint: "[major|minor|patch]"
disable-model-invocation: true
allowed-tools: Read, Bash, Edit, Glob, Grep, Write, AskUserQuestion
---

# Release Skill — shikumi → Hackage

You are cutting a release of the **shikumi** package set and publishing to
[Hackage](https://hackage.haskell.org/), following the Haskell **Package Versioning
Policy (PVP)**.

This is a **multi-package repository with independent per-package versioning**: each package
carries its own version and is tagged and released on its own cadence. A "release" may touch
one package or several. Only the packages that actually changed (or whose dependencies forced
a bound bump) get a new version, a tag, and an upload.

## Versioning strategy (PVP)

Versions are `A.B.C.D`:

- **`A.B`** — the *major* version. Bump when you make a **breaking change** (remove/change an
  exported type or signature, tighten behavior callers relied on). `major` argument bumps this.
- **`C`** — the *minor* version. Bump when you **add** functionality (new exports) in a
  backwards-compatible way. `minor` argument bumps this.
- **`D`** — the *patch* version. Bump for **non-API** changes (bug fixes, docs, internal
  refactors with no interface change). `patch` argument bumps this.

If invoked with an argument (`major` | `minor` | `patch`), honor it as the **minimum** bump
for every package being released. If a package's actual changes imply a larger bump than the
argument, take the larger one and explain why. With no argument, infer the bump per package
from its diff since its last tag.

Each package versions **independently** — do not move unchanged packages.

## Packages

### Published to Hackage — in dependency order (publish dependencies first)

Publish in exactly this order. Each later package can depend on earlier ones, so an earlier
upload must succeed (and be visible on Hackage) before its dependents go up.

| # | Package | Directory | Internal deps (libraries) |
|---|---------|-----------|----------------------------|
| 1 | `shikumi` | `shikumi/` | — (root) |
| 2 | `shikumi-cache` | `shikumi-cache/` | shikumi |
| 3 | `shikumi-tools` | `shikumi-tools/` | shikumi |
| 4 | `shikumi-eval` | `shikumi-eval/` | shikumi |
| 5 | `shikumi-compile` | `shikumi-compile/` | shikumi |
| 6 | `shikumi-trace` | `shikumi-trace/` | shikumi, shikumi-cache |
| 7 | `shikumi-trace-otel` | `shikumi-trace-otel/` | shikumi, shikumi-trace |
| 8 | `shikumi-cache-redis` | `shikumi-cache-redis/` | shikumi, shikumi-cache |
| 9 | `shikumi-cache-postgres` | `shikumi-cache-postgres/` | shikumi, shikumi-cache |
| 10 | `shikumi-optimize` | `shikumi-optimize/` | shikumi, shikumi-compile, shikumi-eval, shikumi-trace |
| 11 | `shikumi-okf` | `shikumi-okf/` | shikumi, okf-core |

When only a subset changes, publish that subset **in this same relative order**, skipping the
untouched packages.

`shikumi-okf` depends on the published `okf-core` library. Like `shikumi-trace-otel`
quarantines OpenTelemetry, only `shikumi-okf` lists `okf-core` under `build-depends`, so no
other package's build plan pulls it in. Before publishing `shikumi-okf`, verify `okf-core` is
still available from Hackage and that no local-path or `source-repository-package` override for
`okf-core` is active in `cabal.project` / `cabal.project.local`.

### NOT released (internal)

| Package | Directory | Why excluded |
|---------|-----------|--------------|
| `shikumi-cli` | `shikumi-cli/` | Internal: the command-line application (EP-12), not distributed via Hackage. |
| `shikumi-jitsurei` | `shikumi-jitsurei/` | Internal: worked examples (実例) — runnable demos, not a library. |
| `shikumi-testing` | `shikumi-testing/` | Internal: shared offline test harness and fixtures. |

Published packages may depend on this internal package in test suites; Hackage tarball builds with `--enable-tests` require a local copy of `shikumi-testing`.

> If a future release should publish `shikumi-cli` too, that is a deliberate decision — confirm
> with the operator and append it after `shikumi-optimize` / `shikumi-trace-otel` in the order.

### Upstream dependencies

shikumi depends on the published **baikai** packages (`baikai`, `baikai-claude`,
`baikai-openai`, `baikai-effectful`), resolved from Hackage via `cabal.project`. They are
**not** part of this release — they are released from their own repository. Before publishing,
confirm shikumi builds against the *Hackage* versions of baikai (no `source-repository-package`
overrides in `cabal.project` / `cabal.project.local`); Hackage will reject a package that
depends on an unpublished one.

`shikumi-okf` additionally depends on the published **`okf-core`** package. Before publishing,
confirm `okf-core` resolves from Hackage (for example, `nix develop -c cabal info okf-core`) and
confirm there is no local-path or `source-repository-package` override for `okf-core` in
`cabal.project` / `cabal.project.local`. Hackage rejects packages whose dependencies are
unpublished or only locally available.

## Toolchain & environment

- **Build inside the Nix dev shell.** The correct compiler is **GHC 9.12.4** from
  `nix develop`. The system `ghc` (9.10.3) is the *wrong* compiler. Run every cabal command via
  `nix develop -c ...` (or from inside a `nix develop` shell).
- **Format:** `nix fmt` (treefmt — fourmolu + cabal-fmt + nixpkgs-fmt).
- **Check gate:** `nix flake check`.
- **Build:** `cabal build all`. **Test:** `cabal test all`.

## Release steps

Work through these in order. **Stop on any failure** — do not proceed past a failed step.

### 1. Pre-flight

```bash
git status                       # working tree must be clean
git fetch --tags origin
git tag --list                   # see existing per-package tags: <pkg>-<version>
```

Confirm you are on the intended branch (`master`) and up to date with `origin`. A clean tree is
required — abort if there are uncommitted changes.

Confirm Hackage credentials are configured (e.g. `~/.config/cabal/config` has a `username`/
`password` under `upload`, or `HACKAGE_USERNAME`/`HACKAGE_PASSWORD` are set). You need
**Hackage maintainer/uploader rights** for each package (first-time uploads require the
account to be in the package's maintainer group, or use of the uploaders' trustee process).

### 2. Determine what changed, per package

For each publishable package, find its last release tag and inspect changes since:

```bash
# Last tag for a package (per-package tag format: <pkg>-<version>)
git describe --tags --abbrev=0 --match '<pkg>-*' 2>/dev/null

# Changes in that package's directory since its last tag (or since repo start if untagged)
git log <lasttag>..HEAD --oneline -- <pkg>/
git diff <lasttag>..HEAD -- <pkg>/
```

> First release: no package has a tag yet (all are at `0.1.0.0`). Treat the whole history as
> the change set; the first published version of each package is its current cabal version
> unless you decide to bump it.

Build the set of packages to release: any package with changes since its last tag, **plus**
any package whose internal dependency is getting a new version that crosses its bound (see
step 4) — those must be re-released with updated bounds even if their own code is unchanged.

### 3. Compute the PVP bump per package

For each package in the release set, classify its diff (breaking / additive / non-API) per the
PVP rules above and compute the new version. Apply the `major|minor|patch` argument as the
floor. Record old → new for each package.

### 4. Update cabal versions and internal dependency bounds

For each package being released:

- Bump `version:` in its `*.cabal`.
- Update **internal dependency bounds**. The cabals currently list internal deps with **no
  version bounds** (e.g. `shikumi-trace` lists `shikumi` and `shikumi-cache` bare). Hackage
  releases must carry PVP bounds. For every internal dependency, add/update a bound that admits
  the version you are publishing, using `^>=` (PVP caret):

  ```
  build-depends:
    , shikumi        ^>=<shikumi new version>
    , shikumi-cache  ^>=<shikumi-cache new version>
  ```

  `^>=X.Y.Z.W` means `>=X.Y.Z.W && <X.(Y+1)` — i.e. allows additive/patch releases but not the
  next major. When a dependency gets a **major** (`A.B`) bump, its dependents' bounds no longer
  admit it: bump the dependent (at least `minor`) and widen its bound. Add the dependent to the
  release set if it was not already there.
- Keep external bounds as-is unless the diff requires changing them.

After editing cabals, run `nix fmt` so `cabal-fmt` normalizes them.

### 5. Update changelogs

There are no changelogs yet — establish a per-package `CHANGELOG.md` (Keep-a-Changelog style)
in each published package's directory. For each release:

- Move the package's `## Unreleased` notes into a new `## <new-version> — <YYYY-MM-DD>` section
  (use today's date), and leave a fresh empty `## Unreleased` heading above it.
- If a package has no `CHANGELOG.md`, create one with a header and the new version section.
- The notes should describe API-visible changes (what a Hackage consumer cares about), grouped
  as Added / Changed / Fixed / Removed.

### 6. Audit the capability catalog (`docs/capabilities/`)

`docs/capabilities/` is an OKF bundle (declared in `mori.dhall` as the `capabilities` bundle)
that states, for consumers, **what shikumi provides today** — one record per capability, each
backed by evidence a reader can open. A release that ships consumer-visible provision without
updating the catalog publishes a catalog that is already wrong. Audit it on **every** release,
reusing the per-package diffs from step 2.

#### 6.1 Read the current catalog

```bash
cat docs/capabilities/index.md   # the CAP-N table: handle, capability, since, package
ls docs/capabilities/            # one file per capability, plus index.md, log.md, profile.dhall
cat docs/capabilities/log.md     # what previous releases changed and why
```

The highest `CAP-N` in the table is the last allocated handle; new records continue from there.
**Handles are stable** — never renumber, reuse, or reorder them.

#### 6.2 Classify each release-set package's diff

For each package being released, walk its changes since the last tag and classify every
consumer-visible change:

- **New capability** — something a consumer can now adopt **and verify independently** that no
  existing record covers. Write a new record.
- **Material growth of an existing capability** — the profile is explicit here: record the
  growth as a **new** capability whose `requires` names the older one. Do **not** move an
  existing record's `since` forward; that misinforms a consumer pinned to an older version.
- **Refined limits, interface, or evidence** — the record's claim is unchanged but the body is
  now inaccurate or thin. Update `interface`, `evidence`, and the `## Limits` section in place;
  `since` stays where it is.
- **Removal or deprecation** — set `status: deprecated` (still usable, discouraged) or
  `withdrawn`, and add `replacedBy`, which the profile requires once `status` leaves `shipped`.
- **Nothing consumer-visible** (internal refactor, tests, build plumbing, docs) — no catalog
  change. Say so explicitly when reporting, rather than silently skipping the audit.

What is **not** a capability, per the profile:

- Anything that does not exist yet. There is deliberately no `planned` status — absent behavior
  belongs in `docs/improvement-requests/` or `docs/plans/`.
- Anything that only works when several repositories cooperate; that is a use-case feature owned
  by the consuming repository, not a shikumi provision claim.
- One record per exported module. A capability is one thing a consumer adopts and verifies as a
  unit; things that always ship together and are proven by the same evidence are one record.
- `shikumi-jitsurei` demos — they are *evidence* for a capability, never a capability.

Also check the transport boundary: behavior that belongs to `mori://shinzui/baikai` (provider
transport) is not a shikumi capability, even when a shikumi release exposes it. A baikai cohort
upgrade only earns a catalog change if it makes a *shikumi* provision claim newly true.

#### 6.3 Write or update the records

A new record is `docs/capabilities/<kebab-case-name>.md` with this frontmatter shape (all
`required` fields of the `coordination.capabilities` profile, plus the recommended
`interface`):

```yaml
---
title: "<human-readable capability name>"
type: Capability
description: "<one sentence a consumer can evaluate without reading the body>"
generated:
  by: <agent/model identity producing this record>
  at: "<UTC ISO-8601 timestamp>"
capabilityId: CAP-<next unused N>
provider: mori://shinzui/shikumi
status: shipped
stability: experimental
since: "<version being published for this package in this release>"
packages:
  - <package name>
interface:
  - <module, command, or endpoint a consumer actually touches>
requires:
  - CAP-<n>            # optional; omit the key when there is nothing to require
evidence:
  - kind: test         # test | conformance | example | benchmark | module | guide
    resource: <repo-relative path, package target, module name, or URL>
    proves: <what a reader learns by opening it>
---
```

Rules that matter:

- **`since` is the version this release publishes** for that package (from step 3) — not the
  package's previous version. Use `unreleased` only for a capability that lives in a package
  with no Hackage release (`shikumi-cli`); when such a package is ever published, that release
  updates those records' `since` to the published version.
- **Evidence is mandatory and must resolve.** A record with no evidence is an improvement
  request, not a capability. `mori` does *not* check evidence paths, so verify each one exists
  (`test -f <resource>`) before committing. Prefer hermetic tests and worked examples.
- **Mirror every `requires` entry as a Markdown body link** (e.g. `[CAP-17 typed tool
  registry](typed-tools.md)`). OKF derives graph edges from body links only; a `requires` entry
  that is not also a body link validates cleanly and is invisible to the graph.
- **Every record carries a `## Limits` section** stating honestly what it does not do — match
  the candor of the existing records.

#### 6.4 Update `index.md` and `log.md`

- Add a row to the `# Capabilities` table in `docs/capabilities/index.md`, in CAP-N order, with
  the handle link, title, `since`, and package.
- Re-read the index prose. If the release changes something it asserts — the uniform
  `experimental` stability promise, which packages are published versus `unreleased`, the
  "Deliberately excluded" list — update that prose too.
- Prepend a dated entry to `docs/capabilities/log.md` under `## <YYYY-MM-DD>` (today), with
  `* **Update**:` / `* **Adoption**:` lines saying what changed and why.

#### 6.5 Validate

```bash
mori capabilities validate --bundle capabilities
```

It must report `OK: <n> capability record(s)`. Fix every reported problem — **a release does not
go out with an invalid bundle.** Re-check evidence paths by hand, since the validator does not.

Report the catalog decisions (new records, updated records, and "no catalog change because …")
to the operator alongside the version bumps in step 8's sign-off.

### 7. Verify — run the full gate (inside the dev shell)

Do **not** skip any of these. Stop on the first failure.

```bash
nix develop -c bash -lc '
  cabal build all          # compiles under GHC 9.12.4
  cabal test all           # all test-suites pass
'
nix fmt                    # formatting is clean...
git diff --exit-code       # ...and produced no changes (else commit them)
nix flake check            # treefmt + any flake checks

mori capabilities validate --bundle capabilities   # capability catalog still valid
```

Additionally, dry-run the packaging for each package to catch sdist/Hackage issues early:

```bash
nix develop -c cabal sdist <pkg>          # builds the source tarball
nix develop -c cabal check                # run from inside <pkg>/ — Hackage lint
```

### 8. Commit, tag, push

Use **Conventional Commits**. One release commit captures the version, changelog, dependency
bound, and capability-catalog edits:

```bash
git add -A
git commit -m "chore(release): <pkg list and versions>"
# e.g. chore(release): shikumi-trace 0.1.1.0, shikumi-optimize 0.1.0.1
```

Create an **annotated, per-package tag** for each released package:

```bash
git tag -a <pkg>-<new-version> -m "<pkg> <new-version>"
# e.g. git tag -a shikumi-trace-0.1.1.0 -m "shikumi-trace 0.1.1.0"
```

Push the commit and the tags:

```bash
git push origin master
git push origin <tag> [<tag> ...]      # or: git push origin --tags
```

### 9. Publish to Hackage — in dependency order

For each released package, **in the dependency order from the Packages table**, publish the
package and then its documentation. Wait for each upload to be accepted before starting its
dependents.

```bash
# From inside the dev shell, for each <pkg> in dependency order:
nix develop -c cabal sdist <pkg>
nix develop -c cabal upload --publish dist-newstyle/sdist/<pkg>-<version>.tar.gz

# Then upload Haddock documentation:
nix develop -c cabal haddock <pkg> --haddock-for-hackage --enable-doc
nix develop -c cabal upload --publish --documentation \
  dist-newstyle/<pkg>-<version>-docs.tar.gz
```

> Tip: do a **candidate** upload first (`cabal upload` *without* `--publish`, and
> `cabal upload --documentation` without `--publish`) to preview the package page on Hackage,
> then re-run with `--publish` to make it permanent. `--publish` is **irreversible**.

If an upload fails, **stop**: fix the issue and do not upload any dependent packages until the
upstream one is live, or you will publish packages whose dependencies don't exist on Hackage.

### 10. Create GitHub releases

`gh` is available; the remote is `shinzui/shikumi`. For each released package, create a GitHub
release from its tag, with notes taken from that package's new changelog section:

```bash
gh release create <pkg>-<new-version> \
  --title "<pkg> <new-version>" \
  --notes-file <(sed -n '/## <new-version>/,/## /p' <pkg>/CHANGELOG.md)
```

Verify each release page renders, then report the Hackage URLs
(`https://hackage.haskell.org/package/<pkg>-<version>`) and GitHub release URLs to the operator.

## Important — guardrails

- **Confirm before committing.** Show the operator the computed per-package version bumps, the
  changelog entries, and the capability-catalog decisions, and get explicit sign-off **before**
  the commit/tag step (step 8).
- **Always publish in dependency order** (the Packages table). An upload must be live before its
  dependents go up.
- **Never skip the check gates** (step 7): `cabal build all`, `cabal test all`, `nix fmt`,
  `nix flake check`, `mori capabilities validate`. A release must pass all of them.
- **Audit `docs/capabilities/` on every release** (step 6), including releases you expect to be
  purely internal — the conclusion "no catalog change" is a result to report, not a step to skip.
- **Never move an existing capability's `since` forward, and never renumber or reuse a CAP-N
  handle.** Growth of a capability is a new record that `requires` the old one.
- **Never add a capability record for behavior that does not ship in this release.** The profile
  has no `planned` status; unshipped work belongs in `docs/improvement-requests/`.
- **Stop on any failure.** Do not continue to later steps or later packages after a failure.
- **Never continue publishing dependents after an upstream upload fails** — a half-published
  release leaves Hackage with packages whose dependencies are missing.
- **`--publish` is irreversible.** Prefer a candidate dry-run first; double-check the version and
  package before publishing.
- **Build only inside the dev shell** (GHC 9.12.4). The system `ghc` is the wrong compiler.
- **Never publish the internal packages** (`shikumi-cli`, `shikumi-jitsurei`, `shikumi-testing`) without an explicit
  decision to change the published set.
- **Before uploading `shikumi-okf`**, verify `okf-core` resolves from Hackage and no local-path or
  `source-repository-package` override for it is active. Hackage will reject dependencies that are
  unpublished or only locally available.
