# nix-direnv automatically watches flake.nix and flake.lock, but not local
# modules imported by the flake. Watch every managed module plus the optional
# unmanaged extension so changes refresh the dev shell and installed hooks.
watch_file nix/haskell.nix nix/treefmt.nix nix/pre-commit.nix flake.module.nix

use flake
eval "$shellHook"
