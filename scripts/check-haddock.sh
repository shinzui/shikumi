#!/usr/bin/env bash
# Build the Haddocks of each shikumi package and fail on identifier warnings.
#
# Haddock only warns — it never fails — when a 'reference' is out of scope (so
# no link is generated) or ambiguous between a type and a value (it guesses).
# Both are fixed in the source: qualify the name ('Shikumi.Program.runProgram')
# or pick a namespace (t'Program' for the type, v'Program' for the constructor).
# See https://haskell-haddock.readthedocs.io/latest/markup.html#hyperlinked-identifiers
#
# Markup that renders wrongly without any warning (unescaped `/`, `<word>`) is
# caught separately by scripts/lint-haddock-markup.awk.
#
# Usage: scripts/check-haddock.sh [PACKAGE...]   (default: every package in
# cabal.project). Run inside `nix develop`.
set -euo pipefail

cd "$(dirname "$0")/.."

if [ "$#" -gt 0 ]; then
  packages=("$@")
else
  mapfile -t packages < <(awk '/^packages:/ { on = 1; next } on && /^[ \t]+[^ \t]/ { print $1; next } { on = 0 }' cabal.project)
fi

logdir=$(mktemp -d)
trap 'rm -rf "$logdir"' EXIT
failed=0

for pkg in "${packages[@]}"; do
  log="$logdir/$pkg.log"
  echo "=== haddock $pkg"
  if ! cabal haddock "$pkg" >"$log" 2>&1; then
    cat "$log"
    echo "cabal haddock $pkg failed" >&2
    exit 1
  fi
  # Each warning is the `Warning:` line plus its indented explanation.
  if grep -qE "^Warning: .*(is out of scope|is ambiguous)" "$log"; then
    awk '/^Warning: .*(is out of scope|is ambiguous)/ { on = 1; print; next }
         on && /^    / { print; next } { on = 0 }' "$log"
    failed=1
  fi
done

if [ "$failed" -ne 0 ]; then
  echo >&2
  echo "Haddock identifier warnings found; qualify the name or use a t'/v' namespace prefix." >&2
  exit 1
fi
