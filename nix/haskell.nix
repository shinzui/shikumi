# Dev shell, built from the haskell-nix-dev base flake's mkDevShell (GHC 9.12.4 +
# cabal + HLS). Add project-specific dev tools via
# `haskellProject.extraDevPackages` from below, or directly in the
# extraNativeBuildInputs list.
#
# mkDevShell already provides: the GHC compiler, cabal, HLS (when withHls),
# pkg-config, and zlib, plus a LANG=en_US.UTF-8 export. Only list tools BEYOND
# those in extraNativeBuildInputs.
{ inputs, lib, flake-parts-lib, ... }:
{
  options.perSystem = flake-parts-lib.mkPerSystemOption ({ ... }: {
    options.haskellProject.extraDevPackages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      example = lib.literalExpression "[ pkgs.ghciwatch ]";
      description = "Extra packages to add to the dev shell.";
    };
  });

  config.perSystem = { system, pkgs, config, ... }:
    let
      hsdev = inputs.haskell-nix-dev.lib.${system};

      mkProjectShell = { ghc, withHls ? true }: hsdev.mkDevShell {
        inherit ghc;
        inherit withHls;
        extraNativeBuildInputs =
          [
            # project dev tools beyond the mkDevShell defaults:
            pkgs.just
            # EP-6 persistent cache backends. `postgresql` provides libpq +
            # pg_config (so `hasql` builds) and initdb/postgres/pg_ctl (so the
            # `ephemeral-pg`-backed Postgres test and the process-compose
            # postgres can run). `redis` provides redis-server/redis-cli for
            # the Redis backend's local server. `process-compose` starts both
            # over UNIX sockets (see process-compose.yaml) so neither binds a
            # TCP port and conflicts with another running server.
            pkgs.postgresql
            # libpq's pkg-config file (libpq.pc) requires libssl/libcrypto;
            # `postgresql-libpq-pkgconfig` resolves them via pkg-config, so
            # openssl's .pc files must be on PKG_CONFIG_PATH at build time.
            pkgs.openssl
            pkgs.redis
            pkgs.process-compose
            pkgs.ripgrep
            pkgs.fd
          ]
          ++ config.haskellProject.extraDevPackages;
        shellHook = ''
          ${config.pre-commit.installationScript}

          # ── EP-6 local services (UNIX sockets only; no TCP) ─────────────────
          # The dev-time Postgres/Redis started by `just services` (process-compose)
          # listen on UNIX sockets under ./.dev, so they never collide with another
          # Postgres/Redis already bound to a TCP port on this machine. The Postgres
          # *test suite* uses `ephemeral-pg`, which spins up its own throwaway
          # server; these dirs are only for the manual `just services` / Redis path.
          export SHIKUMI_DEV_DIR="$PWD/.dev"

          # Postgres: socket-only. PGHOST is a directory (the socket dir), which is
          # how libpq selects a UNIX socket instead of TCP.
          export PGHOST="$SHIKUMI_DEV_DIR/pg"
          export PGDATA="$PGHOST/data"
          export PGLOG="$PGHOST/postgres.log"
          export PGDATABASE=shikumi

          # Redis: socket-only (the test reads REDIS_SOCKET; absent server → skip).
          export REDIS_SOCKET="$SHIKUMI_DEV_DIR/redis/redis.sock"
          export REDIS_LOG="$SHIKUMI_DEV_DIR/redis/redis.log"

          mkdir -p "$PGHOST" "$SHIKUMI_DEV_DIR/redis"

          if [ ! -d "$PGDATA" ]; then
            echo "shikumi: initializing local PostgreSQL cluster (socket-only)…"
            initdb --auth=trust --no-locale --encoding=UTF8 -D "$PGDATA" >/dev/null
          fi
        '';
      };
    in
    {
      devShells.default = mkProjectShell { ghc = "ghc9124"; };
      devShells.ghc9124 = mkProjectShell { ghc = "ghc9124"; };
      # CI needs the compiler, cabal, and service binaries, but not editor tooling.
      devShells.ghc9124-ci = mkProjectShell { ghc = "ghc9124"; withHls = false; };
    };
}
