#!/usr/bin/env bash
# Shared vocabulary for the Baikai cohort automation.
#
# Sourced by baikai-bump-needed.sh (the reaction's idempotency check) and by
# upgrade-baikai.sh (the reaction's action). Not executable on its own.
#
# Modelled on kioku's script of the same name, with two differences that matter.
# Kioku pins its cohort with caret bounds in one cabal file; Shikumi pins the
# same cohort with `>=lower && <upper` range bounds spread across a dozen
# package cabal files, in both library and test-suite stanzas. So a bound here
# is read as a set across every file -- a divergence between them is a finding,
# not something to paper over -- and written to all of them at once.

COHORT_PACKAGES=(
  baikai
  baikai-claude
  baikai-effectful
  baikai-openai
)

# Every package cabal file in the repo. Set once, at source time, from the
# checkout rather than from a hand-maintained list: shikumi gains packages, and
# a list that goes stale would silently leave a package pinned to the old
# cohort while everything else moved.
mapfile -t CABAL_FILES < <(find . -mindepth 2 -maxdepth 2 -name '*.cabal' -not -path './dist-newstyle/*' | sort)

# The version Hackage currently prefers, i.e. the newest non-deprecated release.
# Prints nothing and fails if Hackage cannot be reached or returns nothing
# usable -- callers must treat an empty answer as "do not act", never as
# "no releases exist".
hackage_latest() {
  local pkg=$1 body
  body=$(curl -fsS --max-time 30 -H 'Accept: application/json' \
    "https://hackage.haskell.org/package/${pkg}/preferred" 2>/dev/null) || return 1
  printf '%s' "$body" | jq -er '."normal-version"[0]' 2>/dev/null
}

# The PVP major of a version: its first two components. `0.6.0.0` -> `0.6`.
pvp_major() {
  awk -v v="$1" 'BEGIN { n = split(v, p, "."); printf "%s.%s", (n >= 1 ? p[1] : 0), (n >= 2 ? p[2] : 0) }'
}

# The exclusive upper bound that admits exactly one PVP major: for `0.6.0.0`
# that is `0.7`, and for `1.9.2` it is `1.10`. Written out rather than assumed,
# because the second component carries past 9 and a string bump would not.
pvp_next_major() {
  awk -v v="$1" 'BEGIN {
    n = split(v, p, ".")
    major = (n >= 1 ? p[1] + 0 : 0)
    minor = (n >= 2 ? p[2] + 0 : 0)
    printf "%s.%s", major, minor + 1
  }'
}

# The lower bound this repo currently pins for a package, as the set of
# distinct values found across every cabal file. One value is printed; two or
# more is a divergence and fails, because a single rewrite cannot be correct
# for both and choosing one silently would hide a deliberate exception.
cabal_bound() {
  local pkg=$1 found
  found=$(awk -v pkg="$pkg" '
    $1 == "," && $2 == pkg && $3 ~ /^>=/ { sub(/^>=/, "", $3); print $3 }
  ' "${CABAL_FILES[@]}" | sort -u)

  if [[ -z $found ]]; then
    return 1
  fi
  if [[ $(printf '%s\n' "$found" | wc -l) -gt 1 ]]; then
    echo "${pkg} is pinned at more than one lower bound: ${found//$'\n'/, }" >&2
    return 1
  fi
  printf '%s' "$found"
}

# Rewrite every `>=lower && <upper` pair for one package across every cabal
# file. The lower bound becomes the exact version verified against, and the
# upper bound the next PVP major, so the pin says what was actually tested.
# Column alignment is not preserved -- `>=0.5` and `>=0.6.0.0` are different
# widths -- so callers must run `nix fmt` before committing; cabal-fmt owns
# that alignment and the pre-commit hook enforces it.
set_cabal_bound() {
  local pkg=$1 version=$2 upper file tmp
  upper=$(pvp_next_major "$version")
  for file in "${CABAL_FILES[@]}"; do
    tmp=$(mktemp) || return 1
    awk -v pkg="$pkg" -v lower=">=$version" -v upper="<$upper" '
      $1 == "," && $2 == pkg && $3 ~ /^>=/ && $4 == "&&" && $5 ~ /^</ {
        match($0, /^[ \t]*/)
        printf "%s, %s %s && %s\n", substr($0, 1, RLENGTH), pkg, lower, upper
        next
      }
      { print }
    ' "$file" > "$tmp" || { rm -f "$tmp"; return 1; }
    mv "$tmp" "$file"
  done
}

# Compare two dotted version strings. Exits 0 when $1 is strictly newer than
# $2. Written in awk because macOS `sort` has no -V and coreutils is not in
# this devShell.
version_gt() {
  awk -v a="$1" -v b="$2" '
    BEGIN {
      n = split(a, x, "."); m = split(b, y, ".")
      len = (n > m ? n : m)
      for (i = 1; i <= len; i++) {
        p = (i <= n ? x[i] + 0 : 0)
        q = (i <= m ? y[i] + 0 : 0)
        if (p > q) exit 0
        if (p < q) exit 1
      }
      exit 1
    }
  '
}

# Emit "<pkg> <current> <latest>" for each cohort member that has a strictly
# newer release on Hackage than this repo pins. Returns non-zero if any Hackage
# lookup or bound read failed, so a network blip can never read as "nothing to
# do".
cohort_advances() {
  local pkg current latest failed=0
  for pkg in "${COHORT_PACKAGES[@]}"; do
    if ! current=$(cabal_bound "$pkg") || [[ -z $current ]]; then
      echo "cannot read a >= bound for ${pkg} from this repo's cabal files" >&2
      failed=1
      continue
    fi
    if ! latest=$(hackage_latest "$pkg") || [[ -z $latest ]]; then
      echo "cannot read the preferred version of ${pkg} from Hackage" >&2
      failed=1
      continue
    fi
    if version_gt "$latest" "$current"; then
      printf '%s %s %s\n' "$pkg" "$current" "$latest"
    fi
  done
  return $failed
}
