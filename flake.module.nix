# Project-specific flake-parts customizations. This file is intentionally
# unmanaged by Seihou so these additions survive nix-haskell-flake upgrades.
{ ... }:
{
  perSystem = { pkgs, lib, config, ... }:
    let
      # PostgreSQL 18's libpq.pc adds `Requires.private: libcurl`, and Cabal
      # resolves every pkgconfig-depends with `pkg-config --libs --static`, which
      # walks Requires.private. So libcurl.pc — and the .pc files it requires in
      # turn — must be on PKG_CONFIG_PATH, or postgresql-libpq-pkgconfig fails
      # to configure. Take them from the curl postgresql was actually built with.
      pgCurl = lib.findFirst (p: (p.pname or "") == "curl")
        (throw "postgresql no longer builds against curl; drop pgCurlPkgConfig")
        pkgs.postgresql.buildInputs;
      pgCurlPkgConfig = map lib.getDev
        ([ pgCurl ] ++ pgCurl.buildInputs ++ pgCurl.propagatedBuildInputs);
    in
    {
      haskellProject.extraDevPackages = [
        pkgs.ripgrep
        pkgs.fd
      ] ++ pgCurlPkgConfig;

      # Haddock markup that renders wrongly without a Haddock warning (unescaped
      # `/`, `<word>`). Runs on commit and in CI's pre-commit check; identifier
      # warnings need a build and are checked by scripts/check-haddock.sh.
      pre-commit.settings.hooks.haddock-markup = {
        enable = true;
        name = "haddock markup";
        entry = "${pkgs.gawk}/bin/awk -f ${./scripts/lint-haddock-markup.awk}";
        files = "\\.hs$";
      };

      # Preserve the CI shell name used by .github/workflows/ci.yml. The managed
      # module provides the underlying GHC 9.12.4 shell.
      devShells.ghc9124-ci = config.devShells.ghc9124;
    };
}
