---
id: 9
slug: ci-and-shared-test-infrastructure
title: "CI and Shared Test Infrastructure"
kind: master-plan
created_at: 2026-07-02T03:29:36Z
intention: "intention_01kwjfeb1pe8qbvb8vx7v1xdx0"
---

# CI and Shared Test Infrastructure

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

Today the shikumi repository has no continuous integration at all — there is no `.github`
directory, so nothing builds or tests the thirteen-package cabal project when commits land.
Worse, the two persistent-cache backend test suites (`shikumi-cache-redis/test/Main.hs` and
`shikumi-cache-postgres/test/Main.hs`) exit 0 when their backing service or binary is
missing, so even a hypothetical CI run would silently skip exactly the suites most likely to
break. A production-readiness code review also found that the test *fixtures* across the
repo sit in bug blind spots: every optimizer fixture is built from `mkSignature ""` (an
empty instruction), program fixtures use only trivial `Validatable` instances that cannot
fail, `majorityVote` is exercised only with `TempFixed [0.0]`, and the glob tool is tested
only with `**/`-prefixed patterns. Finally, three near-identical stub-LM implementations are
maintained by hand in `shikumi-cli`, `shikumi-jitsurei`, and `shikumi-tools`.

After this initiative, every push and pull request to GitHub runs a workflow that builds all
packages with GHC 9.12.4 inside the Nix dev shell, runs every test suite with the Redis and
Postgres backend suites *actually executing* (and failing loudly if they would skip), checks
formatting with the repo's pre-commit hooks, and smoke-runs all twelve offline
`shikumi-jitsurei` example executables. Alongside that, a new internal package
`shikumi-testing` becomes the single home for the stub-LM harness (deterministic responder,
scripted replay, counting/throwing wrappers, marker-format response builders) and for
deliberately non-trivial shared fixtures (a signature with a non-empty instruction, an
output type whose `Validatable` rule can fail, a two-stage composed program, diversified
temperature schedules and glob patterns) that other initiatives' bug-exposing tests consume.

In scope: the GitHub Actions workflow and caching, the fail-loud skip contract in the two
backend test mains, the `shikumi-testing` package, migration of the three existing stub-LM
call sites onto it, and the shared non-trivial fixtures. Out of scope: the actual
bug-exposing regression tests for the known runtime and optimizer bugs (owned by
`docs/masterplans/5-core-runtime-correctness-and-wire-fidelity.md` and
`docs/masterplans/6-optimizer-and-evaluation-correctness.md`), any change to what the
optimizer or runtime *does*, publishing anything to Hackage, and CI for platforms beyond
`ubuntu-latest` with the single GHC 9.12.4 toolchain the dev shell pins.


## Decomposition Strategy

The initiative splits cleanly into two functional concerns that share almost no files: the
*pipeline* (workflow YAML, caching, service startup, and the small fail-loud change to two
test mains that the pipeline contractually depends on) and the *test substrate* (a new cabal
package plus mechanical migration of three call sites and new fixture definitions). Each is
independently deliverable and independently verifiable: the pipeline can be proven by a
green (and deliberately red) run against today's test suites without any shared harness
existing, and the shared harness can be proven locally by `cabal build all && cabal test
all` in the dev shell without any CI existing.

Two plans, not one, because the skill sets and failure modes differ (YAML/actions/caching
versus Haskell package plumbing), and not three or more because splitting the harness
extraction from the fixture diversification would create two plans editing the same new
package's modules in sequence — maximal coupling for no scheduling benefit. An alternative
considered was folding the fail-loud test-main change into the harness plan (EP-49) since it
touches test code; it was rejected because the env-var contract exists solely for the
workflow's benefit and must land with (and be validated by) the workflow, and because
keeping EP-49 away from `shikumi-cache-redis/test/Main.hs` and
`shikumi-cache-postgres/test/Main.hs` means the two plans touch disjoint files and cannot
conflict. Another alternative — having EP-48 exclude the backend suites from CI until
services were figured out — was rejected because silent skipping is precisely the systemic
blind spot this initiative exists to close.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 48 | GitHub Actions CI Pipeline | docs/plans/48-github-actions-ci-pipeline.md | None | None | In Progress |
| 49 | Shared Test Harness and Fixture Diversification | docs/plans/49-shared-test-harness-and-fixture-diversification.md | None | EP-48 | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-48).


## Dependency Graph

EP-48 and EP-49 are independent: neither compiles against artifacts of the other, and either
can be implemented first from a clean checkout. There is one soft dependency, from EP-49 on
EP-48: the new `shikumi-testing` package is added to `cabal.project`, so once EP-48's
workflow exists, `cabal test all` in CI automatically builds and tests it, and the
separate example smoke job exercises the example executables — meaning EP-49's work is
CI-verified only if EP-48 has landed. For that reason land
EP-48 first when scheduling permits; if EP-49 lands first, nothing breaks, but its
verification is local-only until the workflow arrives. There are no hard dependencies and
the two plans deliberately touch disjoint files (see Integration Points), so they can also
proceed in parallel in separate sessions without merge conflicts.


## Integration Points

First, the skip-fail environment contract between the backend test mains and the workflow.
The shared artifact is the environment variable `SHIKUMI_REQUIRE_BACKENDS`: when it is unset,
empty, or `"0"`, the Redis and Postgres backend suites may skip cleanly (print a `[SKIP]`
line and exit 0) when their backend is unavailable, preserving today's developer-friendly
local behavior; when it is set to any other value (CI sets `"1"`), the skip path must
instead print a `[FAIL]` line to stderr and exit 1. EP-48 owns both sides of this contract:
it edits `shikumi-cache-redis/test/Main.hs` and `shikumi-cache-postgres/test/Main.hs` to
implement the fail-loud path and sets the variable in `.github/workflows/ci.yml`. EP-49 must
not touch those two test mains (it exports a counting stub those suites could adopt later,
but adoption is deferred precisely to keep the file sets disjoint). Any future suite that
gains a service-dependent skip path must honor the same variable.

Second, the `shikumi-testing` package as a cross-initiative artifact. EP-49 defines the
package (modules `Shikumi.Testing`, `Shikumi.Testing.StubLLM`, `Shikumi.Testing.Response`,
`Shikumi.Testing.Fixtures`) and owns the fixture *shapes*: a non-empty-instruction signature
(`instructedSig`), an output type with a failing-able `Validatable` rule (`Answer`, whose
`validate` rejects a confidence outside `[0,1]`), a two-stage composed program
(`twoStageProg` with its `twoStageResponder`), plus `diverseTemps` and
`diverseGlobPatterns`. The bug-exposing tests that *consume* these fixtures are owned by
other initiatives — `docs/plans/32-fix-validatable-dispatch-in-program-runners.md` (under
master plan 5) needs the failing-able `Validatable` fixture and the two-stage program, and
`docs/plans/36-fix-optimizer-instruction-seeding.md` (under master plan 6) needs a non-empty
seed instruction where today's optimizer fixture (`shikumi-optimize/test/StubLM.hs`, whose
`sentimentSig = mkSignature ""`) hides the seeding bug. This is a soft dependency in both
directions: those plans can write their own local fixtures if `shikumi-testing` has not
landed, and EP-49 does not write the exposing tests itself (its own suite verifies the
fixtures' properties directly, e.g. that `validate` really rejects an out-of-range
confidence, without asserting runner behavior that plan 32 will change). When plans 32 and
36 are drafted or implemented, reconcile by pointing them at
`shikumi-testing/src/Shikumi/Testing/Fixtures.hs` rather than duplicating shapes; EP-49 (this
initiative) is the owner of the fixture module and its naming.

Third, `cabal.project` and the CI build set. EP-49 adds `shikumi-testing` to the `packages`
list in `cabal.project`; EP-48's workflow builds `all`, so no workflow change is needed when
the package lands. Note that `shikumi-okf`'s dependency `okf-core` is resolved from Hackage
(verified 2026-07-01 — see Decision Log), so CI builds all thirteen (then fourteen) packages
with no sibling-repo checkout.


## Progress

Track milestone-level progress across all child plans. Each entry names the child plan
and the milestone.

- [x] EP-48: Milestone 1 — fail-loud skip contract (`SHIKUMI_REQUIRE_BACKENDS`) in the two backend test mains, validated locally in both modes.
- [x] EP-48: Milestone 2 — `.github/workflows/ci.yml` with lint, test, and examples jobs; actionlint-clean; local mirror commands pass.
- [ ] EP-48: Milestone 3 — workflow pushed and observed green on GitHub; caching effective on the second run.
- [ ] EP-49: Milestone 1 — `shikumi-testing` package builds; its own test suite passes.
- [ ] EP-49: Milestone 2 — `shikumi-jitsurei` migrated to the shared harness; all 12 examples still run.
- [ ] EP-49: Milestone 3 — `shikumi-cli` migrated; its tests pass.
- [ ] EP-49: Milestone 4 — `shikumi-tools` tests migrated off `MockLLM.hs`; full `cabal test all` green.


## Surprises & Discoveries

Document cross-plan insights, dependency changes, scope adjustments, or unexpected
interactions between child plans. Provide concise evidence.

- 2026-07-04: EP-48's first GitHub run proved the lint job, but the test job spent 73
  minutes in the first `nix develop .#ghc9124 --command cabal update` step before being
  canceled. The interactive `ghc9124` shell includes HLS; CI needs only the compiler,
  cabal, service binaries, and shell hook. EP-48 now adds `devShells.<system>.ghc9124-ci`
  with `withHls = false` and uses `nix develop -L` so cache misses show Nix progress.
  Evidence: run `28714435132` had `lint` success, then test job step `Refresh the Hackage
  index` ran from `2026-07-04T17:43:31Z` until cancellation at `2026-07-04T18:56:41Z`.

- 2026-07-04: The lean-shell replacement run (`28716549088`) still spent 19 minutes in
  Nix realization because EP-48's workflow was using GitHub's `/nix/store` cache, not the
  existing `shinzui.cachix.org` binary cache used by other shinzui projects. EP-48 now
  configures `shinzui.cachix.org` in both `flake.nix` and the workflow via
  `cachix/install-nix-action@v31` plus `cachix/cachix-action@v17`.

- 2026-07-04: The first Cachix-backed run (`28717147420`) got through Nix/Cachix setup
  and `cabal update`, then was canceled after 18m32s in the standalone `cabal build all`
  step. EP-48 removed that redundant pre-test build: CI now runs `cabal test all` with
  backend coverage required, then the example smoke job builds/runs all twelve example
  executables.


## Decision Log

- Decision: Decompose the initiative into exactly two ExecPlans — EP-48 (GitHub Actions CI
  pipeline, including the fail-loud skip contract in the two backend test mains) and EP-49
  (shared `shikumi-testing` harness package plus non-trivial fixture diversification).
  Rationale: The two concerns share no files, have different failure modes (workflow/caching
  versus Haskell package plumbing), and are independently verifiable. The fail-loud
  test-main change goes with the pipeline because the env-var contract exists for the
  workflow and must be validated by it; keeping EP-49 out of those files makes the plans
  conflict-free and parallelizable. Source: production-readiness code review findings (no CI;
  silent backend-suite skips; fixtures in bug blind spots; three duplicated stub LMs).
  Date: 2026-07-01

- Decision: CI builds all packages including `shikumi-okf`, with no sibling `okf` checkout
  and no package exclusion.
  Rationale: Investigation on 2026-07-01 shows the premise that `okf-core` is a local-path
  dependency is stale: commit `0799d06` ("chore(release): shikumi-okf 0.1.0.0") removed the
  `../okf/okf-core` local-path stanza from `cabal.project`, and `okf-core` 0.1.0.0/0.1.1.0
  are live on Hackage (present in the local Hackage package cache; the Hackage package page
  returns HTTP 200). `cabal.project` now says only "depends on the published okf-core
  library". Tradeoff recorded for posterity: had the local path still existed, the options
  were (a) `actions/checkout` of `shinzui/okf` into a sibling directory — faithful to dev
  setup but couples CI to a second repo's default branch, or (b) excluding `shikumi-okf`
  from the CI build — simple but leaves a package permanently untested. If a local-path
  override ever returns (e.g. developing against unreleased okf-core), CI will fail at
  `cabal build all` and option (a) is the recommended remedy, pinned to a specific okf ref.
  Date: 2026-07-01

- Decision: EP-49 exports a counting stub (`runCountingLLM`) matching the one duplicated in
  the two backend test mains, but does not migrate those mains onto it.
  Rationale: EP-48 edits exactly those two files for the skip-fail contract; keeping EP-49
  away from them removes the only potential file-level conflict between the plans. Adoption
  by the cache suites is cheap follow-up work once both plans have landed.
  Date: 2026-07-01

- Decision: The fixture *shapes* (non-empty-instruction signature, failing-able
  `Validatable` output, two-stage program, diversified temperatures and glob patterns) live
  in `Shikumi.Testing.Fixtures` and are owned by EP-49; the bug-exposing tests that consume
  them are owned by plans 32 (master plan 5) and 36 (master plan 6).
  Rationale: The review's blind-spot findings implicate fixtures shared across packages, so
  the fixtures must live where every package can depend on them; but the exposing tests
  assert post-fix behavior that belongs with the fixing plans. EP-49's own test suite proves
  the fixtures' properties (e.g. `validate` really can fail) without asserting runner
  behavior that plan 32 will change.
  Date: 2026-07-01


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original vision.

(To be filled during and after implementation.)
