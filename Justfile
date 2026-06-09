# shikumi developer tasks. Run inside `nix develop` (the dev shell exports the
# Postgres/Redis socket env and initialises the local PG cluster).

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
