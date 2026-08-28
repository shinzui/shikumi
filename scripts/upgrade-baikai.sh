#!/usr/bin/env bash
# Action for the `upgrade-baikai-cohort` mori reaction; also runnable by hand
# as `just upgrade-baikai`.
#
# Moves this repo's Baikai-cohort bounds to the newest releases Hackage prefers,
# proves the result builds and passes every suite, and commits. On any failure
# every cabal file is restored, so a red run leaves the tree exactly as it found
# it.
#
# What this can and cannot do. A baikai patch or minor release is a bounds move
# and this script can land it end to end. A baikai MAJOR release is a source
# migration -- 0.6.0.0 broke Model, Context, Options and Response, which Shikumi
# consumes across twelve packages -- and no bounds rewrite can complete it. That
# case is expected to fail the build, restore, and exit 1 asking for a human.
# Failing loudly there is the point: the alternative is a major sitting unnoticed
# behind a stale bound.
#
# Exit codes are chosen for an unattended caller:
#
#   0 -- either the bump landed and is committed, or there was legitimately
#        nothing to do (already current, tree dirty, cohort not yet consistent).
#        None of those are incidents and none should page anyone.
#   1 -- the bump was warranted and available but did not survive verification,
#        or the environment is not fit to attempt it. This wants a human.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
# shellcheck source=scripts/baikai-cohort.sh
source scripts/baikai-cohort.sh

log() { printf '[upgrade-baikai] %s\n' "$*"; }
# Put every cabal file back the way it found it, staged or not. All of them,
# not just the ones this run rewrote: `nix fmt` runs across the tree and may
# have touched a file the rewrite never named.
restore() {
  git reset -q 2>/dev/null || true
  git checkout -- "${CABAL_FILES[@]}" 2>/dev/null || true
}

branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
if [[ $branch != master ]]; then
  log "on branch '${branch}', not master -- nothing to do"
  exit 0
fi

if [[ -n $(git status --porcelain) ]]; then
  log "working tree is not clean -- refusing to build, test, or commit on top of it"
  exit 0
fi

if ! advances=$(cohort_advances); then
  log "could not establish the cohort's current state from Hackage -- not acting on partial data"
  exit 1
fi

if [[ -z $advances ]]; then
  log "every cohort bound already names the newest release -- nothing to do"
  exit 0
fi

log "cohort advances available:"
while read -r pkg current latest; do
  log "  ${pkg}: ${current} -> ${latest}"
done <<< "$advances"

# --- rewrite ---------------------------------------------------------------
# One bullet per package rather than a comma-joined run-on: this text goes into
# a commit body, which does not want a 200-column line.
moves=""
while read -r pkg current latest; do
  if ! set_cabal_bound "$pkg" "$latest"; then
    log "rewriting ${pkg} failed -- restoring"
    restore
    exit 1
  fi
  moves+="- \`${pkg} >=${latest} && <$(pvp_next_major "$latest")\` (was >=${current})
"
done <<< "$advances"
moves=${moves%$'\n'}

if git diff --quiet -- "${CABAL_FILES[@]}"; then
  log "bounds rewrite produced no change -- the cabal files do not look as expected"
  exit 1
fi

# cabal-fmt aligns the version column off the widest entry in each stanza, and
# `>=0.5` and `>=0.6.0.0` are different widths, so the rewrite above leaves the
# columns wrong on purpose and lets the formatter that owns them fix it. Doing
# this before the build, not before the commit: the pre-commit hook runs the
# same formatter and would otherwise reject a commit at the very end of a long
# verified run.
log "formatting"
if ! nix fmt >/dev/null 2>&1; then
  log "nix fmt failed -- restoring; the commit hook would have rejected this anyway"
  restore
  exit 1
fi

# --- can the cohort even be solved yet? ------------------------------------
# The baikai packages of one release cut are separate Hackage uploads, and the
# release fact that woke us is recorded from the first tag of the cut. Landing
# here before the whole cohort is published is expected, not a fault: back the
# change out and wait to be woken again.
log "refreshing the package index"
cabal update >/dev/null 2>&1 || { log "cabal update failed"; restore; exit 1; }

log "checking the solver can find a plan"
if ! plan=$(cabal build all --enable-tests --dry-run 2>&1); then
  log "no consistent install plan yet -- the cohort is not fully published"
  log "solver said:"
  printf '%s\n' "$plan" | tail -20
  restore
  exit 0
fi

# --- verify ----------------------------------------------------------------
# Full output goes to a file and only the tail is echoed. A reaction that fails
# at 4am is read from `mori reaction show` hours later, and "which test failed"
# has to survive that trip -- piping straight to `tail` throws the answer away.
run_log=$(mktemp) || { log "cannot create a log file"; restore; exit 1; }
[[ -n $run_log ]] || { log "mktemp returned an empty path"; restore; exit 1; }
log "verification output: ${run_log}"

log "building"
if ! cabal build all --enable-tests > "$run_log" 2>&1; then
  log "BUILD FAILED -- restoring every cabal file; full output in ${run_log}"
  log "this is the expected outcome for a baikai major: the bounds moved, the source did not"
  tail -40 "$run_log"
  restore
  exit 1
fi

# The Postgres backend test uses ephemeral-pg and the Redis backend test skips
# cleanly when no Redis is reachable, so no service needs starting here.
log "running the test suites"
if ! cabal test all --test-show-details=streaming > "$run_log" 2>&1; then
  log "TESTS FAILED -- restoring every cabal file; full output in ${run_log}"
  log "failing cases:"
  grep -E "FAIL|failed" "$run_log" | head -20
  restore
  exit 1
fi

# --- commit ----------------------------------------------------------------
# No changelog entry. Shikumi keeps a CHANGELOG.md per package and a cohort move
# touches a dozen of them; mutating all twelve unattended is more risk than the
# entry is worth, and this commit body carries the same information for whoever
# writes the release notes.
git add "${CABAL_FILES[@]}"
if ! git commit -q -F - <<COMMIT
chore(deps): move onto the newest Baikai cohort

${moves}

Bounds only; no Shikumi source changed. Raised automatically by the
upgrade-baikai-cohort mori reaction on a shinzui/baikai release fact, and
committed only after \`cabal build all --enable-tests\` and every test suite
passed against the new cohort.

Nothing read the upstream changelogs, and no per-package CHANGELOG.md was
touched. A breaking change that Shikumi's tests do not cover would land here
unremarked, so treat this commit as verified, not reviewed, and write the
changelog entries before releasing.

Ref: mori://shinzui/baikai
COMMIT
then
  log "COMMIT REFUSED -- the pre-commit hook rejected it; backing the bump out"
  restore
  exit 1
fi

log "committed $(git rev-parse --short HEAD)"
log "NOT pushed -- review, then push when you are satisfied"
