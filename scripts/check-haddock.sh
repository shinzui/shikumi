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
  # Keep only the package's own Haddock run: local dependencies (e.g. a sibling
  # baikai checkout in cabal.project.local) are haddocked first, in the same log.
  # Each warning is the `Warning:` line plus its indented explanation.
  warnings=$(awk -v pkg="$pkg" '
    $0 ~ ("^Running Haddock on .* for " pkg "-[0-9]") { own = 1 }
    !own { next }
    /^Warning: .*(is out of scope|is ambiguous)/ { on = 1; print; next }
    on && /^    / { print; next }
    { on = 0 }' "$log")
  if [ -n "$warnings" ]; then
    echo "$warnings"
    failed=1
  fi
done

if [ "$failed" -ne 0 ]; then
  echo >&2
  echo "Haddock identifier warnings found; qualify the name or use a t'/v' namespace prefix." >&2
  exit 1
fi
