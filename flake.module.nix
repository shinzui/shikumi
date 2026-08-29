# Project-specific flake-parts customizations. This file is intentionally
# unmanaged by Seihou so these additions survive nix-haskell-flake upgrades.
{ ... }:
{
  perSystem = { pkgs, config, ... }: {
    haskellProject.extraDevPackages = [
      pkgs.ripgrep
      pkgs.fd
    ];

    # Preserve the CI shell name used by .github/workflows/ci.yml. The managed
    # module provides the underlying GHC 9.12.4 shell.
    devShells.ghc9124-ci = config.devShells.ghc9124;
  };
}
