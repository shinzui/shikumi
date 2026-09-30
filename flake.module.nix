# Project-specific flake-parts customizations. This file is intentionally
# unmanaged by Seihou so these additions survive nix-haskell-flake upgrades.
{ ... }:
{
  perSystem = { pkgs, config, ... }: {
    haskellProject.extraDevPackages = [
      pkgs.ripgrep
      pkgs.fd
    ];

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
