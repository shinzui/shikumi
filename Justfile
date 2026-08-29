# shikumi developer tasks. Run inside `nix develop` (the dev shell exports the
# Postgres/Redis socket environment and initialises the local PG cluster).

# Show available recipes.
default:
    @just --list

# ── Build & test ───────────────────────────────────────────────────────────

# Build every package.
build:
    cabal build all

# Run every test suite. The Redis backend test skips cleanly when no Redis is
# reachable on $REDIS_SOCKET; the Postgres backend test uses ephemeral-pg and
# needs no running server.
test:
    cabal test all

# Run a single package's tests, e.g. `just test-one shikumi-cache`.
test-one pkg:
    cabal test {{pkg}}

# ── Local services (UNIX sockets; see process-compose.yaml) ──────────────────

# Create the configured development database after PostgreSQL becomes ready.
# Re-running this is harmless when the database already exists.
create-database:
    createdb -h "$PGHOST" "$PGDATABASE" 2>/dev/null || true

# Start Postgres + Redis (socket-only) under process-compose.
services:
    process-compose up

# Start the services detached (background).
services-up:
    process-compose up --detached

# Stop the detached services.
services-down:
    process-compose down

# Tail the process-compose log.
services-log:
    tail -f .dev/process-compose.log

# ── Dependency cohorts ──────────────────────────────────────────────────────

# Move the Baikai cohort bounds to the newest releases Hackage prefers, verify
# by a full build and every test suite, and commit. Also the action of the
# `upgrade-baikai-cohort` mori reaction (automation/upgrade.dhall). Backs
# everything out on any failure; a baikai major needs a source migration this
# cannot do, and will stop at the build.
upgrade-baikai:
    ./scripts/upgrade-baikai.sh
