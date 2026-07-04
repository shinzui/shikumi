{
  description = "shikumi is a Haskell-native framework for typed, structured, evaluable, reproducible, and optimizable language-model programs built over baikai.";

  inputs = {
    # The shared base flake. Provides the GHC 9.12.4 / cabal / HLS toolchain via
    # `mkDevShell`, and the single pinned nixpkgs the whole fleet follows.
    haskell-nix-dev.url = "github:shinzui/haskell-nix-dev";
    nixpkgs.follows = "haskell-nix-dev/nixpkgs";

    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs";

    treefmt-nix.follows = "haskell-nix-dev/treefmt-nix";

    pre-commit-hooks.url = "github:cachix/git-hooks.nix";
    pre-commit-hooks.inputs.nixpkgs.follows = "nixpkgs";
  };

  # The haskell-nix-dev base flake's binary cache, so the first `nix develop`
  # downloads prebuilt GHC/HLS/cabal instead of compiling the toolchain from source.
  # nixConfig is honored by CI via `accept-flake-config = true`; locally, run
  # `cachix use shinzui` once if your Nix config does not already trust this cache.
  nixConfig = {
    extra-substituters = [ "https://shinzui.cachix.org" ];
    extra-trusted-public-keys = [ "shinzui.cachix.org-1:QEmAoJrA9WwLP0uxfDgktLi2BRrcvQQWdz8NzcMg4/E=" ];
  };

  # Thin flake-parts shell. The dev toolchain comes from the haskell-nix-dev base
  # flake (GHC 9.12.4 / cabal / HLS via mkDevShell); project wiring lives in the
  # imported ./nix modules. shikumi builds via cabal in the dev shell and exposes
  # no Nix package output.
  outputs = inputs@{ flake-parts, nixpkgs, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = nixpkgs.lib.systems.flakeExposed;

      imports = [
        ./nix/haskell.nix
        ./nix/treefmt.nix
        ./nix/pre-commit.nix
      ];
    };
}
