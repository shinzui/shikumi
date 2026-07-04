---
id: 48
slug: github-actions-ci-pipeline
title: "GitHub Actions CI Pipeline"
kind: exec-plan
created_at: 2026-07-02T03:30:16Z
intention: "intention_01kwjfeb1pe8qbvb8vx7v1xdx0"
master_plan: "docs/masterplans/9-ci-and-shared-test-infrastructure.md"
---

# GitHub Actions CI Pipeline

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

The shikumi repository currently has no continuous integration at all: there is no
`.github` directory, so a broken commit is only discovered when a developer happens to run
`cabal build all` locally. Worse, two test suites — the Redis and Postgres cache backends —
silently exit 0 when their backing service or binary is missing, so even if someone wired
up a naive CI, those suites would report green without running a single assertion.

After this plan, every push to `master` and every pull request runs a GitHub Actions
workflow with three jobs: a lint job that checks formatting exactly as the repo's
pre-commit hook does (treefmt running fourmolu, cabal-fmt, and nixpkgs-fmt), a test job
that builds all packages and runs all test suites inside the pinned GHC 9.12.4 Nix dev
shell with a real Redis available on a UNIX socket — and with a new environment-variable
contract (`SHIKUMI_REQUIRE_BACKENDS=1`) that turns the backend suites' silent skips into
loud failures — and a smoke job that runs all twelve deterministic offline example
executables from `shikumi-jitsurei` and asserts they exit 0. Anyone can see it working by
opening the repository's Actions tab on GitHub and watching a run go green, or by breaking
a test locally, pushing a branch, and watching the run go red.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] 2026-07-04T17:35:18Z — Milestone 1: edit `shikumi-cache-redis/test/Main.hs` — fail-loud skip helper.
- [x] 2026-07-04T17:35:18Z — Milestone 1: edit `shikumi-cache-postgres/test/Main.hs` — fail-loud skip helper.
- [x] 2026-07-04T17:35:18Z — Milestone 1: validate both suites in all three modes (backend present; absent+var unset → skip 0; absent+var set → fail 1).
- [x] 2026-07-04T17:35:18Z — Milestone 1: commit with the required trailers.
- [ ] Milestone 2: create `.github/workflows/ci.yml` with lint, test, and examples jobs.
- [ ] Milestone 2: run actionlint over the workflow; fix any findings.
- [ ] Milestone 2: run the local mirror of every CI step and record transcripts here.
- [ ] Milestone 2: commit with the required trailers.
- [ ] Milestone 3: push to GitHub, observe the first run, fix runner-only issues, observe a green run and an effective cache on a second run.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

- Decision: Install Nix with `DeterminateSystems/nix-installer-action` and cache the Nix
  store with `nix-community/cache-nix-action` (backed by the ordinary GitHub Actions
  cache), rather than the often-suggested `DeterminateSystems/magic-nix-cache-action`.
  Rationale: Building the GHC 9.12.4 toolchain from scratch on every run is unacceptable,
  so a store cache is mandatory. Magic Nix Cache was shut down in early 2025 when GitHub
  retired the internal cache API it depended on, and its hosted successor (FlakeHub Cache)
  requires an external account. `cache-nix-action` needs no account or secret. If the
  implementer finds these action versions have moved on, prefer the newest stable major
  version and verify input names against the action's README.
  Date: 2026-07-01

- Decision: The skip-fail contract is the environment variable `SHIKUMI_REQUIRE_BACKENDS`.
  Unset, empty, or `"0"` preserves today's clean-skip behavior; any other value makes the
  skip path print `[FAIL] ...` to stderr and exit 1. CI sets it to `"1"` on the test job.
  Rationale: local developers without Redis keep a frictionless `just test`; CI can never
  silently lose backend coverage. A single variable covers both suites and any future
  service-dependent suite.
  Date: 2026-07-01

- Decision: Start Redis directly with `redis-server --daemonize yes` in a workflow step
  instead of running `process-compose up --detached`.
  Rationale: the tests need only Redis (the Postgres suite is hermetic via `ephemeral-pg`),
  process-compose would also start a Postgres server nothing uses, and a detached
  process-compose adds lifecycle state (`down`, log files) to clean up. Tradeoff: CI
  service startup is no longer byte-identical to `just services`; the socket path and
  flags are copied from `process-compose.yaml` to compensate.
  Date: 2026-07-01

- Decision: Build all thirteen packages, including `shikumi-okf`, with no special handling.
  Rationale: `okf-core` (shikumi-okf's distinctive dependency) is published on Hackage
  (0.1.0.0 / 0.1.1.0) and `cabal.project` no longer carries the historical
  `../okf/okf-core` local-path stanza (removed in commit `0799d06`). See the master plan's
  Decision Log for the fallback if a local-path override ever returns.
  Date: 2026-07-01

- Decision: Keep the matrix minimal — `ubuntu-latest` only, one toolchain (the dev shell's
  GHC 9.12.4). Use `nix develop .#ghc9124 --command ...` for every build/test/run step so
  CI uses byte-for-byte the toolchain developers use.
  Rationale: the flake pins exactly one compiler; a matrix would multiply cost without
  adding signal. macOS runners are slow and expensive and the team develops on darwin
  locally anyway.
  Date: 2026-07-01

- Decision: Preserve the expanded local skip banners that already existed in the Redis and
  Postgres backend suites, and add the CI-required failure path only when
  `SHIKUMI_REQUIRE_BACKENDS` is set.
  Rationale: The checked-in tests had more explicit skip output than the original plan
  snippet: they state that zero tests ran and point developers at the command needed to run
  the suite for real. Keeping that output preserves local ergonomics, while the new
  required-backend branch still prints the concise `[FAIL] ...` stderr line and exits 1
  for CI.
  Date: 2026-07-04


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

- 2026-07-04: Milestone 1 completed. `SHIKUMI_REQUIRE_BACKENDS` now converts Redis and
  Postgres backend-suite skips into failures while preserving clean local skips when the
  variable is unset, empty, or `"0"`. Validation evidence:

```text
cabal test shikumi-cache-redis
== SKIPPED: shikumi-cache-redis test suite ran ZERO tests
Test suite shikumi-cache-redis-test: PASS

SHIKUMI_REQUIRE_BACKENDS=1 cabal test shikumi-cache-redis
[FAIL] shikumi-cache-redis: SHIKUMI_REQUIRE_BACKENDS is set but no Redis reachable at socket .../.dev/redis/redis.sock
Test suite shikumi-cache-redis-test: FAIL
exit: 1

just services-up
SHIKUMI_REQUIRE_BACKENDS=1 cabal test shikumi-cache-redis shikumi-cache-postgres
shikumi-cache-redis: All 3 tests passed
shikumi-cache-postgres: All 2 tests passed
just services-down
```


## Context and Orientation

shikumi is a multi-package Haskell project. `cabal.project` at the repository root lists
thirteen packages: `shikumi`, `shikumi-cache`, `shikumi-cache-redis`,
`shikumi-cache-postgres`, `shikumi-cli`, `shikumi-compile`, `shikumi-eval`,
`shikumi-jitsurei`, `shikumi-okf`, `shikumi-optimize`, `shikumi-tools`, `shikumi-trace`,
and `shikumi-trace-otel`. Twelve of them have a `test-suite`; `shikumi-jitsurei` (a package
of runnable worked examples) has none — its coverage is execution itself, which this plan's
smoke job provides. All dependencies, including `shikumi-okf`'s `okf-core`, resolve from
Hackage; nothing needs a sibling repository checkout.

The toolchain does not come from the runner's system packages. `flake.nix` (with modules
under `nix/`) defines a Nix development shell — a reproducible environment entered with
`nix develop .#ghc9124` — that provides GHC 9.12.4, cabal, and the service binaries
(`nix/haskell.nix` adds `postgresql`, `redis`, `process-compose`, `just`, and friends).
The system `ghc` is explicitly the wrong compiler (see the comment at the top of
`cabal.project`). Every CI step that builds, tests, or runs Haskell therefore wraps its
command as `nix develop .#ghc9124 --command <cmd>`.

The dev shell's `shellHook` (in `nix/haskell.nix`) exports service environment variables
whenever the shell is entered: `SHIKUMI_DEV_DIR=$PWD/.dev`, `PGHOST=$SHIKUMI_DEV_DIR/pg`
(a directory — libpq treats a directory `PGHOST` as a UNIX-socket dir), `PGDATA`, `PGLOG`,
`PGDATABASE=shikumi`, `REDIS_SOCKET=$SHIKUMI_DEV_DIR/redis/redis.sock`, and `REDIS_LOG`.
It also creates those directories and runs `initdb` once. Because CI enters the shell via
`nix develop`, these variables are set identically in every step with no workflow-level
duplication.

Two test suites interact with services, and both currently skip silently:

`shikumi-cache-redis/test/Main.hs` reads `REDIS_SOCKET` (line 55) and connects to that
UNIX socket. If the variable is unset (line 57) or no Redis answers (line 62), a local
`skip` helper (lines 68–70) prints `[SKIP] shikumi-cache-redis: ...` and calls
`exitSuccess`. The dev shell exports `REDIS_SOCKET` but does not start a server — locally
one runs `just services` (process-compose, see `process-compose.yaml`, which starts
`redis-server --port 0 --unixsocket "$REDIS_SOCKET"` — socket-only, no TCP). So in CI we
must start a Redis on `$REDIS_SOCKET` ourselves, and make the skip path fatal.

`shikumi-cache-postgres/test/Main.hs` does *not* use the process-compose Postgres. It
calls `EphemeralPg.start` (line 51), which spins up a private throwaway Postgres cluster
using the `initdb`/`postgres` binaries on `PATH` (provided by the dev shell). Only if that
startup fails does it print `[SKIP] shikumi-cache-postgres: ...` and `exitSuccess` (lines
53–55). Inside the dev shell this suite runs hermetically with no server; the fail-loud
change is still required so a future PATH regression cannot silently disable it.

Formatting is enforced by a pre-commit hook generated by git-hooks.nix: the only hook
(`.pre-commit-config.yaml`) runs `treefmt --fail-on-change --no-cache`, and treefmt
(`nix/treefmt.nix`) runs `fourmolu` (configured by `fourmolu.yaml`), `cabal-fmt`, and
`nixpkgs-fmt`. Both git-hooks.nix and treefmt-nix expose flake *checks* — buildable
derivations named `pre-commit` and `treefmt` under `.#checks.<system>` — so the CI lint
job builds those two checks rather than invoking the `pre-commit` Python tool.

`shikumi-jitsurei` ships twelve executables (enumerated in
`shikumi-jitsurei/shikumi-jitsurei.cabal`), all deterministic and offline — they run
against an in-process stub LM, no API key or network: `shikumi-jitsurei` (the index),
`jitsurei-predict`, `jitsurei-compose`, `jitsurei-combinators`, `jitsurei-evaluate`,
`jitsurei-optimize`, `jitsurei-react`, `jitsurei-trace-replay`, `jitsurei-multimodal`,
`jitsurei-streaming`, `jitsurei-adapters`, and `jitsurei-codeexec`.

One term of art: a "UNIX socket" is a filesystem path (here `.dev/redis/redis.sock`) that
processes on the same machine use to talk to each other instead of a TCP port; the repo
uses sockets so dev services never collide with anything already bound to a port.


## Plan of Work

The work is three milestones: make the backend suites fail loudly on demand, write the
workflow, and validate (locally first, then on GitHub — the only place a GitHub Actions
workflow can truly run).

Every commit made while implementing this plan must use a Conventional Commits subject
line (`feat:`, `fix:`, `ci:`, `test:`, etc.) and carry these three trailers, each on its
own line at the end of the commit message:

```text
MasterPlan: docs/masterplans/9-ci-and-shared-test-infrastructure.md
ExecPlan: docs/plans/48-github-actions-ci-pipeline.md
Intention: intention_01kwjfeb1pe8qbvb8vx7v1xdx0
```

### Milestone 1 — fail-loud skip contract in the backend test mains

Scope: two small, symmetric edits. At the end, both backend suites still skip cleanly for
a developer without services, but exit 1 with a `[FAIL]` message when
`SHIKUMI_REQUIRE_BACKENDS` is set to anything other than empty or `"0"`. This is the
contract the workflow's test job relies on; it is documented as an integration point in
the master plan.

In `shikumi-cache-redis/test/Main.hs`, the `main` function ends with a `where`-bound
`skip` helper (currently lines 67–70). Replace it with a helper that consults the
environment, and extend the imports: the module already imports
`System.Environment (lookupEnv)` and `System.Exit (exitSuccess)`; change the latter to
`System.Exit (exitFailure, exitSuccess)` and add `import System.IO (hPutStrLn, stderr)`.
The new helper:

```haskell
  where
    skip reason = do
      required <- lookupEnv "SHIKUMI_REQUIRE_BACKENDS"
      if maybe False (`notElem` ["", "0"]) required
        then do
          hPutStrLn stderr ("[FAIL] shikumi-cache-redis: SHIKUMI_REQUIRE_BACKENDS is set but " <> reason)
          exitFailure
        else do
          putStrLn ("[SKIP] shikumi-cache-redis: " <> reason)
          exitSuccess
```

In `shikumi-cache-postgres/test/Main.hs`, the skip is inline in `main`'s `Left err`
branch (lines 53–55). Give it the same shape: add
`import System.Environment (lookupEnv)`, change the `System.Exit` import to
`(exitFailure, exitSuccess)`, add `import System.IO (hPutStrLn, stderr)`, and rewrite the
branch:

```haskell
    Left err -> do
      let reason = T.unpack (Pg.renderStartError err)
      required <- lookupEnv "SHIKUMI_REQUIRE_BACKENDS"
      if maybe False (`notElem` ["", "0"]) required
        then do
          hPutStrLn stderr ("[FAIL] shikumi-cache-postgres: SHIKUMI_REQUIRE_BACKENDS is set but ephemeral-pg failed to start: " <> reason)
          exitFailure
        else do
          putStrLn ("[SKIP] shikumi-cache-postgres: " <> reason)
          exitSuccess
```

Keep the module haddocks honest: extend each file's header comment sentence about
skipping with "…unless `SHIKUMI_REQUIRE_BACKENDS` is set (CI sets it), in which case the
skip becomes a failure." Run the formatter (`nix fmt` or let the pre-commit hook do it)
before committing; fourmolu will normalize layout.

Acceptance for this milestone is behavioral, in three modes, all from inside the dev
shell (`nix develop .#ghc9124`) at the repo root: with no Redis running and the variable
unset, `cabal test shikumi-cache-redis` prints the `[SKIP]` line and the suite PASSES
(exit 0); with no Redis and `SHIKUMI_REQUIRE_BACKENDS=1`, the same command FAILS (exit 1)
and the log shows the `[FAIL]` line; with Redis running (`just services-up`), the suite
runs its real test and passes in both variable states. The Postgres suite passes in all
modes on a healthy machine (ephemeral-pg needs no server); to see its `[FAIL]` path you
would have to hide the `initdb` binary, which is not required for acceptance.

### Milestone 2 — the workflow file

Scope: create `.github/workflows/ci.yml` (new directory `.github/workflows/`) with three
jobs — `lint`, `test`, `examples` — exactly as below. At the end the file exists, passes
`actionlint`, and every command it runs has been executed successfully by hand locally.

The design, so the YAML below reads as intended: all jobs run on `ubuntu-latest`.
`DeterminateSystems/nix-installer-action` installs Nix with flakes enabled.
`nix-community/cache-nix-action` saves and restores `/nix/store` through the GitHub
Actions cache, keyed on `flake.lock` plus the `nix/` modules — this is what makes the GHC
9.12.4 toolchain arrive in minutes instead of being rebuilt (the very first run on a
fresh cache still pays full price; see Validation). A second, ordinary `actions/cache`
covers cabal state: `dist-newstyle` (build products) and the cabal package/store
directories. Cabal ≥ 3.10 uses XDG paths (`~/.cache/cabal` for the Hackage index and
downloaded tarballs, `~/.local/state/cabal` for the store) but falls back to legacy
`~/.cabal` if it exists, so the cache lists all three; the key hashes `flake.lock`,
`cabal.project`, and every `*.cabal` file, with a prefix restore key so an old cache
still warms a changed build. The test job exports `SHIKUMI_REQUIRE_BACKENDS=1` (the
Milestone 1 contract), starts Redis as a daemon on the dev shell's `$REDIS_SOCKET`
(flags copied from `process-compose.yaml`: `--port 0` disables TCP, `--save ""` disables
persistence), waits for `PING`/`PONG`, then runs `cabal test all`. The `examples` job
`needs: test` so it restores the cabal cache the test job saved, then runs all twelve
`shikumi-jitsurei` executables under `set -euo pipefail`, so any non-zero exit fails the
job. The lint job builds the two flake checks (`treefmt`, `pre-commit`) for
`x86_64-linux`, which is exactly what the local pre-commit hook enforces.

Create `.github/workflows/ci.yml` with this content:

```yaml
name: ci

on:
  push:
    branches: [master]
  pull_request:

concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: true

jobs:
  lint:
    name: lint (treefmt / pre-commit checks)
    runs-on: ubuntu-latest
    timeout-minutes: 90
    steps:
      - uses: actions/checkout@v4
      - uses: DeterminateSystems/nix-installer-action@v16
      - uses: nix-community/cache-nix-action@v6
        with:
          primary-key: nix-lint-${{ runner.os }}-${{ hashFiles('flake.lock', 'nix/**') }}
          restore-prefixes-first-match: nix-lint-${{ runner.os }}-
      - name: Check formatting (fourmolu, cabal-fmt, nixpkgs-fmt) and hooks
        run: |
          nix build -L \
            .#checks.x86_64-linux.treefmt \
            .#checks.x86_64-linux.pre-commit

  test:
    name: build and test (GHC 9.12.4, dev shell)
    runs-on: ubuntu-latest
    timeout-minutes: 240
    env:
      SHIKUMI_REQUIRE_BACKENDS: "1"
    steps:
      - uses: actions/checkout@v4
      - uses: DeterminateSystems/nix-installer-action@v16
      - uses: nix-community/cache-nix-action@v6
        with:
          primary-key: nix-shell-${{ runner.os }}-${{ hashFiles('flake.lock', 'nix/**') }}
          restore-prefixes-first-match: nix-shell-${{ runner.os }}-
      - name: Cache cabal state and dist-newstyle
        uses: actions/cache@v4
        with:
          path: |
            ~/.cabal
            ~/.cache/cabal
            ~/.local/state/cabal
            dist-newstyle
          key: cabal-${{ runner.os }}-${{ hashFiles('flake.lock', 'cabal.project', '**/*.cabal') }}
          restore-keys: |
            cabal-${{ runner.os }}-
      - name: Refresh the Hackage index
        run: nix develop .#ghc9124 --command cabal update
      - name: Build all packages
        run: nix develop .#ghc9124 --command cabal build all
      - name: Start Redis on the dev-shell UNIX socket
        run: |
          nix develop .#ghc9124 --command bash -c '
            set -euo pipefail
            redis-server --port 0 --unixsocket "$REDIS_SOCKET" \
              --unixsocketperm 700 --daemonize yes --save ""
            for _ in $(seq 1 20); do
              if redis-cli -s "$REDIS_SOCKET" ping >/dev/null 2>&1; then exit 0; fi
              sleep 0.5
            done
            echo "redis did not become ready on $REDIS_SOCKET" >&2
            exit 1'
      - name: Test all packages (backend suites must run, not skip)
        run: nix develop .#ghc9124 --command cabal test all

  examples:
    name: smoke (shikumi-jitsurei examples)
    runs-on: ubuntu-latest
    needs: test
    timeout-minutes: 60
    steps:
      - uses: actions/checkout@v4
      - uses: DeterminateSystems/nix-installer-action@v16
      - uses: nix-community/cache-nix-action@v6
        with:
          primary-key: nix-shell-${{ runner.os }}-${{ hashFiles('flake.lock', 'nix/**') }}
          restore-prefixes-first-match: nix-shell-${{ runner.os }}-
      - name: Restore cabal state and dist-newstyle
        uses: actions/cache@v4
        with:
          path: |
            ~/.cabal
            ~/.cache/cabal
            ~/.local/state/cabal
            dist-newstyle
          key: cabal-${{ runner.os }}-${{ hashFiles('flake.lock', 'cabal.project', '**/*.cabal') }}
          restore-keys: |
            cabal-${{ runner.os }}-
      - name: Run all 12 example executables
        run: |
          nix develop .#ghc9124 --command bash -c '
            set -euo pipefail
            for exe in shikumi-jitsurei jitsurei-predict jitsurei-compose \
                       jitsurei-combinators jitsurei-evaluate jitsurei-optimize \
                       jitsurei-react jitsurei-trace-replay jitsurei-multimodal \
                       jitsurei-streaming jitsurei-adapters jitsurei-codeexec; do
              echo "=== running $exe"
              cabal run -v0 "$exe"
            done'
```

Two notes the implementer should be ready for. First, verify the flake check names before
relying on them: run `nix flake show 2>/dev/null | grep -A4 checks` locally; expect
`treefmt` (from treefmt-nix) and `pre-commit` (from git-hooks.nix) under
`checks.x86_64-linux` (locally you will see the darwin equivalents). If git-hooks.nix
named its check differently (some versions use `pre-commit-check`), adjust the lint step
to the actual name. Second, verify the pinned action versions still exist
(`nix-installer-action@v16`, `cache-nix-action@v6`, `checkout@v4`, `cache@v4`); if a
major has moved, take the newest stable and re-check the `with:` input names —
`cache-nix-action` in particular renamed its inputs across majors (`primary-key` /
`restore-prefixes-first-match` are the v6 names).

### Milestone 3 — validation on GitHub

Scope: no new files; push and observe. A GitHub Actions workflow cannot be fully
validated locally — `act` runs a rough approximation in a container where the Nix
installer and cache actions frequently misbehave — so the final acceptance is a real run.
Push the branch (or master, per the repo's no-feature-branch default), open the Actions
tab, and watch the `ci` workflow. The first `test` job run is slow (it may build parts of
the toolchain and every Hackage dependency; expect one to a few hours worst case). Verify
in the logs of the `Test all packages` step that `shikumi-cache-redis-test` shows its real
tasty output (`memoize: first request MISS ... OK`) and not a `[SKIP]` line. Then re-run
or push a trivial commit and confirm the second run restores the nix and cabal caches and
completes in minutes. If the first run trips the repository's 10 GB Actions cache limit,
add `gc-max-store-size-linux: 8G` to the `cache-nix-action` steps (it garbage-collects
the store before saving) — and record whatever you did in Surprises & Discoveries.


## Concrete Steps

All commands run at the repository root, `/…/shikumi` (the directory containing
`cabal.project`). Enter the dev shell once per terminal with `nix develop .#ghc9124`, or
prefix individual commands with `nix develop .#ghc9124 --command`.

Milestone 1, edit then verify the three modes. Make sure no dev Redis is up first:

```bash
just services-down 2>/dev/null || true
cabal build shikumi-cache-redis shikumi-cache-postgres
cabal test shikumi-cache-redis
```

Expected (skip mode — suite passes without running assertions):

```text
Test suite shikumi-cache-redis-test: RUNNING...
[SKIP] shikumi-cache-redis: no Redis reachable at socket /…/shikumi/.dev/redis/redis.sock
Test suite shikumi-cache-redis-test: PASS
```

Now the fail-loud mode:

```bash
SHIKUMI_REQUIRE_BACKENDS=1 cabal test shikumi-cache-redis; echo "exit: $?"
```

Expected:

```text
Test suite shikumi-cache-redis-test: RUNNING...
[FAIL] shikumi-cache-redis: SHIKUMI_REQUIRE_BACKENDS is set but no Redis reachable at socket /…/shikumi/.dev/redis/redis.sock
Test suite shikumi-cache-redis-test: FAIL
...
exit: 1
```

And the real-backend mode, which must pass regardless of the variable:

```bash
just services-up
SHIKUMI_REQUIRE_BACKENDS=1 cabal test shikumi-cache-redis shikumi-cache-postgres
just services-down
```

Expected: both suites print tasty output ending in `All 1 tests passed` and
`Test suite …: PASS`. Commit:

```bash
git add shikumi-cache-redis/test/Main.hs shikumi-cache-postgres/test/Main.hs
git commit -m "test(cache): fail loudly on backend-suite skips when SHIKUMI_REQUIRE_BACKENDS is set" \
  -m "MasterPlan: docs/masterplans/9-ci-and-shared-test-infrastructure.md" \
  -m "ExecPlan: docs/plans/48-github-actions-ci-pipeline.md" \
  -m "Intention: intention_01kwjfeb1pe8qbvb8vx7v1xdx0"
```

Milestone 2, create the workflow and lint it:

```bash
mkdir -p .github/workflows
# create .github/workflows/ci.yml with the YAML from Plan of Work
nix run nixpkgs#actionlint -- .github/workflows/ci.yml
```

Expected: `actionlint` prints nothing and exits 0. Then mirror each CI step locally, in
order (this is the documented local validation of the workflow's substance):

```bash
nix build -L .#checks.aarch64-darwin.treefmt .#checks.aarch64-darwin.pre-commit  # use your local system attr
nix develop .#ghc9124 --command cabal update
nix develop .#ghc9124 --command cabal build all
just services-up      # local stand-in for the workflow's redis-server step
SHIKUMI_REQUIRE_BACKENDS=1 nix develop .#ghc9124 --command cabal test all
just services-down
nix develop .#ghc9124 --command bash -c '
  set -euo pipefail
  for exe in shikumi-jitsurei jitsurei-predict jitsurei-compose jitsurei-combinators \
             jitsurei-evaluate jitsurei-optimize jitsurei-react jitsurei-trace-replay \
             jitsurei-multimodal jitsurei-streaming jitsurei-adapters jitsurei-codeexec; do
    echo "=== running $exe"; cabal run -v0 "$exe"; done'
```

Expected: the checks build (first time may compile fourmolu for GHC 9.12.4 — slow once,
cached after), `cabal test all` reports every suite `PASS` with no `[SKIP]` lines from
the two backend suites, and the example loop prints twelve `=== running …` headers with
each program's deterministic output and exits 0. Commit the workflow:

```bash
git add .github/workflows/ci.yml
git commit -m "ci: add github actions pipeline (lint, build+test, examples smoke)" \
  -m "MasterPlan: docs/masterplans/9-ci-and-shared-test-infrastructure.md" \
  -m "ExecPlan: docs/plans/48-github-actions-ci-pipeline.md" \
  -m "Intention: intention_01kwjfeb1pe8qbvb8vx7v1xdx0"
```

Milestone 3, push and watch (requires the repo to exist on GitHub with Actions enabled):

```bash
git push
gh run watch          # or open the Actions tab in a browser
gh run view --log | grep -E "SKIP|FAIL|memoize" | head
```

Expected: three jobs, all green; the grep shows the redis suite's `memoize` test ran and
no `[SKIP]` appears in the backend suites' output.


## Validation and Acceptance

Acceptance is observable behavior, layered from local to remote.

Locally (all inside `nix develop .#ghc9124` at the repo root): with services down and
`SHIKUMI_REQUIRE_BACKENDS` unset, `cabal test shikumi-cache-redis` exits 0 printing
`[SKIP] shikumi-cache-redis: …`; with services down and `SHIKUMI_REQUIRE_BACKENDS=1` it
exits 1 printing `[FAIL] shikumi-cache-redis: …`; with `just services-up` and
`SHIKUMI_REQUIRE_BACKENDS=1`, `cabal test all` runs every suite with zero `[SKIP]` lines
and every suite reports `PASS`. `actionlint .github/workflows/ci.yml` reports nothing.
The twelve-executable loop exits 0. These local commands mirror the CI steps one-to-one
(the only substitution is `just services-up` for the workflow's `redis-server` step, and
your local `checks.<system>` attribute for `checks.x86_64-linux`), so a green local pass
is strong evidence the workflow's substance is correct. Optionally, `act` can rehearse
the YAML structure, but be honest about its limits: the Nix installer and cache actions
often fail in act's containers, so do not treat an act failure as a workflow bug.

On GitHub (final acceptance — this genuinely requires pushing; there is no way to fully
validate a GitHub Actions workflow without GitHub running it): the `ci` workflow appears
in the Actions tab and a run triggered by a push to `master` (or a PR) finishes with all
three jobs green; the test job's log shows real tasty output for
`shikumi-cache-redis-test` (the `memoize:` test) rather than a skip; the examples job's
log shows all twelve `=== running …` sections; and a second run with unchanged
`flake.lock`/`*.cabal` files restores both caches (visible as `Cache restored from key:`
lines) and completes dramatically faster than the first. As a negative control, push a
branch with a deliberately failing test (e.g. flip an expected value in
`shikumi-cache/test/Main.hs`) and confirm the test job goes red, then drop the commit.


## Idempotence and Recovery

Every step is safe to repeat. The test-main edits are plain source changes guarded by
`git`; re-running the formatter or tests mutates nothing. `just services-up` /
`services-down` are idempotent (process-compose refuses a second detached instance; down
on nothing is a no-op); if the local Redis socket is left stale, `just services-down`
then deleting `.dev/redis/redis.sock` recovers. The workflow itself is stateless per run;
caches are additive and keyed by content hashes, so a bad cache is recovered by bumping
the key (e.g. temporarily prefixing `v2-`) or deleting the cache entry in the repo's
Actions → Caches UI. If the first GitHub run times out building the toolchain, re-run the
job: the store cache saved by the partial run (cache-nix-action saves even on failure
only if configured — otherwise the run must complete; if this bites, split a warm-up
commit that only runs `nix develop .#ghc9124 --command true`). If GitHub Actions is
unavailable, nothing in the repo is degraded — the workflow file is inert locally.


## Interfaces and Dependencies

GitHub-side: `actions/checkout@v4`, `DeterminateSystems/nix-installer-action@v16`,
`nix-community/cache-nix-action@v6` (inputs `primary-key`,
`restore-prefixes-first-match`, optional `gc-max-store-size-linux`), `actions/cache@v4`
(inputs `path`, `key`, `restore-keys`). No secrets are required; nothing publishes.

Repo-side: the flake outputs consumed are `devShells.<system>.ghc9124` (from
`nix/haskell.nix`; `default` is an alias) and `checks.<system>.{treefmt,pre-commit}`
(from `nix/treefmt.nix` and `nix/pre-commit.nix`). The service contract consumed is the
dev-shell environment: `REDIS_SOCKET` (path the redis suite dials), `PGHOST`/`PGDATA`/
`PGDATABASE` (used by `ephemeral-pg`'s host tooling and the optional manual server), all
exported by the `shellHook` in `nix/haskell.nix`.

Contract defined by this plan (consumed by the workflow, implemented in the two test
mains): environment variable `SHIKUMI_REQUIRE_BACKENDS` — unset/empty/`"0"` permits a
clean skip (exit 0, `[SKIP]` on stdout); any other value converts the skip path to exit 1
with `[FAIL]` on stderr. After Milestone 1, `shikumi-cache-redis/test/Main.hs` and
`shikumi-cache-postgres/test/Main.hs` each contain a `skip`-shaped branch implementing
exactly this; no library API changes anywhere (`main :: IO ()` is the only affected
symbol in each file). Plan 49 (`docs/plans/49-shared-test-harness-and-fixture-diversification.md`)
must not modify these two files; if a future plan centralizes the helper into
`shikumi-testing`, it must preserve this contract byte-for-byte in behavior.
