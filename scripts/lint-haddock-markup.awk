# Flag Haddock markup that renders wrongly without producing a Haddock warning.
#
# `cabal haddock` (see scripts/check-haddock.sh) catches out-of-scope and
# ambiguous identifiers, but some mistakes render silently wrong:
#
#   * two unescaped `/` on one line pair up as /emphasis/, even inside @code@,
#     so `run/evaluate/optimize` renders as run<em>evaluate</em>optimize and
#     `mori://owner/project` as mori:/<em>owner</em>project;
#   * `<word>` that is not a URL, and operators like @</>@, render as hyperlinks.
#
# Escape them as `\/` and `\<word\>`. Emphasis never spans lines, so a single
# `read/write` on a line is fine; pairs that look intentional (`/word/`, opened
# after a space or punctuation and closed before one) are left alone.
#
# Only Haddock comments are checked: `-- |`, `-- ^`, `-- $`, `-- *` (and their
# continuation lines) and `{- | ... -}`. Bird-track (`> code`) and doctest
# (`>>> expr`) lines are literal and skipped.
#
# Usage: awk -f scripts/lint-haddock-markup.awk FILE.hs...

function check(text, clean, n, i, j, before, after) {
  if (text ~ /^[ \t]*>/) return                    # literal code lines
  clean = text
  gsub(/\\./, "__", clean)                        # escaped characters
  gsub(/<(https?|ftp|mailto):[^>]*>/, "", clean)    # explicit URL links
  gsub(/(https?|ftp):\/\/[^ \t)>]*/, "", clean)     # bare URLs (autolinked)
  gsub(/\]\([^)]*\)/, "]", clean)                   # [label](target) targets
  # Replay Haddock's emphasis parse: a `/` opens emphasis if another `/` follows
  # on the line with something in between; an empty `//` leaves the first literal.
  n = length(clean)
  for (i = 1; i <= n; i++) {
    if (substr(clean, i, 1) != "/") continue
    j = index(substr(clean, i + 1), "/")
    if (j == 0) break
    if (j == 1) continue
    before = substr(clean, i - 1, 1); after = substr(clean, i + j + 1, 1)
    if (before ~ /[A-Za-z0-9_:.\/]/ || after ~ /[A-Za-z0-9_]/ || substr(clean, i + 1, 1) == " ") {
      report("'" substr(clean, i, j + 1) "' renders as emphasis; escape the slashes as '\\/'")
      break
    }
    i += j
  }
  if (clean ~ /<[^ \t<>][^<>]*>/)
    report("'<...>' renders as a hyperlink; escape it as '\\<...\\>'")
}

function report(msg) {
  printf "%s:%d: %s\n    %s\n", FILENAME, FNR, msg, $0
  bad++
}

FNR == 1 { inLine = 0; inBlock = 0 }

inBlock {
  line = $0
  if (sub(/-}.*/, "", line)) inBlock = 0
  check(line)
  next
}

# A block Haddock comment: {- | ... -}, {- ^ ... -}, {- $name ... -}
/\{-[ \t]*[|^$]/ {
  line = $0
  sub(/.*\{-[ \t]*[|^$]/, "", line)
  if (!sub(/-}.*/, "", line)) inBlock = 1
  check(line)
  next
}

# A line Haddock comment, either leading or trailing code.
/--[ \t]*[|^$*]/ && !/--[ \t]*[|^$*][^ \t]*--/ {
  line = $0
  sub(/.*--[ \t]*[|^$*]/, "", line)
  inLine = 1
  check(line)
  next
}

# Continuation of a line Haddock comment.
inLine && /^[ \t]*--/ {
  line = $0
  sub(/^[ \t]*--/, "", line)
  check(line)
  next
}

{ inLine = 0 }

END {
  if (bad) {
    printf "\n%d Haddock markup problem(s). See https://haskell-haddock.readthedocs.io/latest/markup.html#special-characters\n", bad
    exit 1
  }
}
