#!/usr/bin/env bash
# Idempotency check for the `upgrade-baikai-cohort` mori reaction.
#
# The reaction is scheduled with skipOnExit = NonZero, so:
#
#   exit 0  -> a bump is warranted; run the action
#   exit 1  -> skip (ReactionSkipped), for any reason at all
#
# This runs at wake-up time, hours after the release that triggered it, and it
# deliberately re-derives everything from Hackage rather than trusting the
# signal payload. The signal says which baikai version was released; whether
# Shikumi has anything to do about it is a question only Hackage and this
# checkout can answer, and both may have changed since. Every refusal is silent
# by design -- a skipped reaction is the common case, not an incident.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
# shellcheck source=scripts/baikai-cohort.sh
source scripts/baikai-cohort.sh

branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
if [[ $branch != master ]]; then
  echo "skip: on branch '${branch}', not master" >&2
  exit 1
fi

# An unattended bump wants a clean slate: it rewrites twelve cabal files,
# builds, tests, formats, and commits, and none of those mean what they should
# on top of someone else's work in progress.
if [[ -n $(git status --porcelain) ]]; then
  echo "skip: working tree is not clean" >&2
  exit 1
fi

if ! advances=$(cohort_advances); then
  echo "skip: could not establish the cohort's current state" >&2
  exit 1
fi

if [[ -z $advances ]]; then
  echo "skip: every cohort bound already names the newest release" >&2
  exit 1
fi

echo "proceed: ${advances//$'\n'/; }"
exit 0
