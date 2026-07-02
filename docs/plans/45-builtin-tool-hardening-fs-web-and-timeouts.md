---
id: 45
slug: builtin-tool-hardening-fs-web-and-timeouts
title: "Builtin Tool Hardening Fs Web and Timeouts"
kind: exec-plan
created_at: 2026-07-02T03:30:16Z
intention: "intention_01kwgdyxm7ehh8yys1pp4wf1zr"
master_plan: "docs/masterplans/8-tools-agents-and-cli-hardening.md"
---

# Builtin Tool Hardening Fs Web and Timeouts

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

shikumi ships built-in tools that language models drive at run time: filesystem
tools (`read`, `write`, `edit`, `grep`, `glob`), a `bash` tool, and web tools
(`web_fetch`, `web_search`). A production-readiness review found defensive gaps in
all three groups. After this plan:

- A model asking `glob` or `grep` for `*.hs` gets the same answer whether the host
  has `fd`/`rg` installed (the "fast path") or not (the in-process "fallback path").
  Today the fallback returns *nothing* for `*.hs` under a directory tree, because
  its glob matcher anchors the pattern against the full path while `rg`/`fd` match
  basenames.
- `web_fetch` stops downloading once its byte cap is reached (today it downloads the
  entire body into memory and truncates afterwards), and it refuses obviously unsafe
  URLs (non-http(s) schemes, loopback/link-local/private-range hosts — the classic
  server-side request forgery targets) under a documented, swappable policy.
- A model-supplied `timeoutMs` can no longer disable the `bash` timeout (negative
  values currently do, because GHC's `System.Timeout.timeout` treats negative as
  "wait forever") or overflow the microsecond arithmetic (huge values currently do).
- The `truncated` flags in tool responses are truthful: a result list of exactly the
  cap size no longer claims truncation, and `read` with an offset no longer claims
  truncation when it read to end of file.
- The fallback directory walker cannot be blown up by symlink cycles.
- The deliberately non-hermetic security posture of `bash`/local tool environments
  is documented in the modules users read, and the code interpreter's incorrect
  claim that the effect row prevents IO is corrected.

You can see each fix working through new hermetic tests in the `shikumi-tools`
suite; each is observable as a concrete before/after behavior listed under
Validation and Acceptance.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented
here, even if it requires splitting a partially completed task into two ("done" vs.
"remaining"). This section must always reflect the actual current state of the work.

- [ ] M1: rewrite `globMatches`/`globToRegex` in Fs.hs to basename-or-path semantics;
      update the two fallback call sites.
- [ ] M1: FsSpec parity tests with a non-`**` pattern across fast and fallback paths.
- [ ] M2: add `FetchPolicy`, `defaultFetchPolicy`, `checkFetchUrl`, `readCapped`,
      `localWebClientWith` to Web.hs; stream the body with a cap.
- [ ] M2: WebSpec tests for the policy and the capped reader.
- [ ] M3: clamp exec timeout in Env.hs; EnvSpec test for a negative timeout.
- [ ] M3: truthful `truncated` flags in Fs.hs (`capResults` helper, readTool fix);
      FsSpec tests.
- [ ] M3: symlink guard — `isSymlink` on `DirEntry`, walkFiles skips symlinked dirs;
      FsSpec cycle test.
- [ ] M4: parametrize `toolInputSchema`'s required list; pin request schemas in a test.
- [ ] M4: security-posture module docs in Shell.hs and Env.hs; correct the
      Interpreter.hs IOE-row claim.
- [ ] Final: `just test-one shikumi-tools` green; commits with required trailers.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

- Decision: Unify glob semantics to "rg/fd style": a pattern containing `/` matches
  the path relative to the search root (with `**` spanning directories and `**/`
  also matching zero directories); a pattern without `/` matches the basename at any
  depth.
  Rationale: The fast paths already behave this way (`rg -g`, `fd --glob`), models
  overwhelmingly emit basename patterns like `*.hs`, and the alternative (forcing
  full-path anchoring onto rg/fd) would break the common case. Source:
  production-readiness code review.
  Date: 2026-07-01

- Decision: The default fetch policy denies non-http(s) schemes and IP-literal /
  well-known-name private destinations (loopback, link-local incl. 169.254.169.254,
  RFC-1918 ranges, `localhost`), but does not resolve hostnames to detect private
  IPs behind DNS (DNS-rebinding is documented as out of scope).
  Rationale: Resolution-time checking requires hooking the connection manager and
  is out of proportion for this plan; the documented policy hook (`FetchPolicy`)
  lets deployments substitute a stricter checker. Denying the metadata address and
  loopback literals removes the highest-value SSRF targets.
  Date: 2026-07-01

- Decision: Clamp exec timeouts to the closed range [1 ms, 600000 ms] rather than
  rejecting out-of-range values with an error.
  Rationale: A tool-argument error would burn an agent turn for a value the runtime
  can safely coerce; clamping preserves the model's intent ("short"/"long") while
  keeping the host safe. The cap (10 minutes) exceeds every timeout currently used
  in-tree (30 s for rg/fd, 60 s default).
  Date: 2026-07-01


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This is a Haskell cabal multi-package repository. All work here is in the
`shikumi-tools` package: library sources under `shikumi-tools/src`, tasty/HUnit
tests under `shikumi-tools/test`. Build inside the nix dev shell: from the repo
root run `nix develop .#ghc9124`, then `cabal build shikumi-tools` and
`just test-one shikumi-tools` (which runs `cabal test shikumi-tools`).

The files this plan edits, and what lives in them today:

- `shikumi-tools/src/Shikumi/Tool/Builtin/Fs.hs` — the five filesystem tools. The
  search tools try host `rg`/`fd` binaries first ("fast path", `grepFast` lines
  247–268, `globFast` lines 270–291) and fall back to an in-process walk
  (`grepFallback` lines 293–308, `globFallback` lines 310–314, `walkFiles` lines
  333–351). Glob matching for the fallback is `globMatches`/`globToRegex` (lines
  379–390): it anchors `^…$` against the **full path** and translates `*` to
  `[^/]*`, so `*.hs` can never match `dir/file.hs` — while `rg -g` and `fd --glob`
  match such patterns against the basename. `toolInputSchema` (lines 445–452)
  builds the JSON schema for `GrepReq`/`GlobReq` and hardcodes
  `required = ["pattern"]`. Result caps: `maxResults = 1000` (line 468),
  `maxDepth = 25` (line 474), `maxFileSize` 5 MiB (line 471).
- `shikumi-tools/src/Shikumi/Tool/Env.hs` — the `ToolEnv` record of host operations
  (exec, file IO, stat, readdir…) that all filesystem/shell tools go through, plus
  `localToolEnv`, the real-host implementation. `localExec` (lines 102–126) runs
  `bash -c <command>` under `System.Timeout.timeout (effectiveTimeoutMs * 1000)`,
  where `timeoutMsOrDefault` (lines 173–174) passes any model-supplied value
  through unclamped. `localReaddir` (lines 142–151) reports a symlinked directory
  as a directory (it calls `doesDirectoryExist`, which follows links). `toolIO`
  (lines 165–171) converts `IOException`s to `ProviderFailure` using
  `unsafeEff_` — i.e. it performs real IO *inside* the `(LLM, Error ShikumiError)`
  effect row.
- `shikumi-tools/src/Shikumi/Tool/Web.hs` — the swappable `WebClient`. `localFetch`
  (lines 93–109) calls `httpLbs`, which reads the **entire** response body into
  memory, and only then truncates to `maxBytes` (default 100000); there is no
  scheme or host restriction of any kind — a model-supplied URL of
  `http://169.254.169.254/latest/meta-data/` (the cloud metadata service) is
  fetched happily. `httpIO` (lines 129–135) also uses `unsafeEff_`.
- `shikumi-tools/src/Shikumi/Tool/Builtin/Shell.hs` — `bashTool` (lines 36–53)
  passes the model's `command`, `cwd`, `timeoutMs`, `stdin` straight to
  `envExec`. Its module doc says nothing about the security posture.
- `shikumi-tools/src/Shikumi/CodeExec/Interpreter.hs` — the restricted code
  interpreter. Its "SECURITY POSTURE" haddock (lines 13–28) ends with the claim
  that a subprocess interpreter "needs @IOE@, which the @Embed@ row lacks", so it
  "could only be offered through a separate @IOE@-bearing entry point". That
  argument is contradicted by `toolIO`/`httpIO` above: real IO already happens
  inside that row via `unsafeEff_`. The claim must be corrected (the *policy* is
  right; the *type-level justification* is wrong). This plan touches only that doc
  paragraph — the DSL code and grammar doc belong to EP-46 (see the master plan's
  Integration Points).

Truncation-flag details (all in Fs.hs): `globFast` computes
`found = take maxResults …` then reports `truncated = length found >= maxResults`
(lines 289–290) — at *exactly* the cap this claims truncation even when nothing was
dropped. `globFallback` (313–314) and `parseRgJson` (355–356) share the same
take-then-`>=` bug. `grepFallback` (307–308) is the one correct instance (it
compares the *un*-truncated list with `>`). `readTool` (lines 184–193) reports
`truncated = start > 0 || length selected < length afterOffset` — reading with an
offset to end-of-file falsely claims truncation.

Symlink hazard: `walkFiles` (Fs.hs 333–351) recurses into anything `envReaddir`
flags `isDir`, and `localReaddir` flags symlinked directories as directories.
`maxDepth 25` bounds depth, but with k sibling symlinks pointing back up, the walk
visits on the order of k^25 paths before the (post-walk) result cap applies. Also,
`DirEntry` (Env.hs lines 69–74) is constructed in exactly one place (Env.hs line
149) and consumed by `walkFiles` and two test files, so extending it is cheap.

Test infrastructure to reuse: `shikumi-tools/test/FsSpec.hs` has `withTempDir` (a
bracket that creates/removes a scratch dir) and `noFastToolEnv` (a `ToolEnv` that
pretends `rg`/`fd` are absent so the fallback path runs deterministically).
`shikumi-tools/test/EnvSpec.hs` exercises `localToolEnv` directly.
`shikumi-tools/test/WebSpec.hs` tests web tools against stub `WebClient`s, with
live-network cases gated behind the `SHIKUMI_NET_TESTS` env var. `MockLLM.runEffMock`
discharges the `(LLM, Error ShikumiError)` row hermetically. Today FsSpec's only
glob pattern is `**/*.txt` — which is exactly why the divergence went unnoticed:
`**` maps to `.*`, which happens to match full paths.


## Plan of Work

### Milestone 1 — unified glob semantics

Scope: `Fs.hs` matching functions and their two fallback call sites, plus FsSpec
parity tests. At the end, `*.txt` finds nested files on the fallback path exactly as
it does under `fd`/`rg`, and a `dir/*.txt` pattern matches root-relative paths.

Replace `globMatches` and `globToRegex` (Fs.hs lines 379–390) with root-aware,
basename-or-path semantics:

```haskell
-- | rg/fd-style glob matching. A pattern containing a path separator is matched
-- against the candidate's path relative to the search root; a pattern without
-- one is matched against the basename, at any depth. @**@ spans directories,
-- and @**/@ also matches zero directories (so @**/*.txt@ matches a top-level
-- @note.txt@).
globMatches :: Text -> Text -> Text -> Bool
globMatches root pat candidate
  | "/" `T.isInfixOf` pat = matchGlob pat (relativeTo root candidate)
  | otherwise = matchGlob pat (basenameOf candidate)

matchGlob :: Text -> Text -> Bool
matchGlob pat s = T.unpack s =~ ("^" <> T.unpack (globToRegex pat) <> "$" :: String)

globToRegex :: Text -> Text
globToRegex = go . T.unpack
  where
    go [] = ""
    go ('*' : '*' : '/' : rest) = "(.*/)?" <> go rest
    go ('*' : '*' : rest) = ".*" <> go rest
    go ('*' : rest) = "[^/]*" <> go rest
    go ('?' : rest) = "[^/]" <> go rest
    go (c : rest) = T.pack (escapeRegex c) <> go rest

-- | Strip the search root (and its trailing slash) off a walked path; paths
-- outside the root are returned unchanged.
relativeTo :: Text -> Text -> Text
relativeTo root path =
  let rootSlash = T.dropWhileEnd (== '/') root <> "/"
   in maybe path id (T.stripPrefix rootSlash path)

basenameOf :: Text -> Text
basenameOf = snd . T.breakOnEnd "/"
```

Update the two call sites to pass the root: in `grepFallback` (line 297) change
`globOk p = maybe True (`globMatches` p) (req ^. #glob)` to
`globOk p = maybe True (\g -> globMatches root g p) (req ^. #glob)`; in
`globFallback` (line 313) change `filter (globMatches pat) paths` to
`filter (globMatches root pat) paths`. (`root` is already in scope in both.)

Tests (FsSpec): a new case "fast and fallback agree on non-** glob patterns".
Inside `withTempDir`, create `root/top.txt` and `root/sub/nested.txt` (use
`envMkdir`/`envWriteFile localToolEnv`). Then, through `runEffMock []`:
glob with pattern `*.txt` via `globTool localToolEnv` (fast) and via
`globTool noFastToolEnv` (fallback) — both must contain **both** files; grep for a
marker string with `glob = Just "*.txt"` on both paths — both must match in
`nested.txt`; and glob with the path-relative pattern `sub/*.txt` on the fallback —
must return exactly the nested file. Before this milestone the fallback halves
return empty lists (the failing-before evidence). Keep the existing `**/*.txt` case
untouched — it must still pass (that is what the `('*':'*':'/':rest)` →
`"(.*/)?"` translation preserves for top-level files).

### Milestone 2 — web fetch: streamed cap and SSRF policy

Scope: `Web.hs` plus WebSpec. At the end, `web_fetch` never buffers more than the
cap, refuses unsafe URLs by policy, and both behaviors are unit-tested without
network.

Edits to `shikumi-tools/src/Shikumi/Tool/Web.hs`:

1. New types and exports (add `FetchPolicy (..)`, `defaultFetchPolicy`,
   `checkFetchUrl`, `readCapped`, `localWebClientWith` to the export list):

```haskell
-- | The web_fetch safety policy: a hard byte ceiling and a URL check that runs
-- before any connection is opened. Swap the whole record (via
-- 'localWebClientWith') to loosen or tighten the posture per deployment.
data FetchPolicy = FetchPolicy
  { maxResponseBytes :: !Int,
    checkUrl :: !(Text -> Either Text ())
  }

-- | Deny non-http(s) schemes and the classic SSRF targets: loopback,
-- link-local (including the 169.254.169.254 cloud metadata service), and
-- RFC-1918 private ranges, matched on the URL's host literal. Hostnames that
-- *resolve* to private addresses (DNS rebinding) are NOT detected — supply a
-- resolving 'checkUrl' via 'localWebClientWith' if you need that.
defaultFetchPolicy :: FetchPolicy
defaultFetchPolicy =
  FetchPolicy {maxResponseBytes = 5 * 1024 * 1024, checkUrl = defaultCheckUrl}
```

2. `checkFetchUrl :: FetchPolicy -> Text -> Either Text ()` simply applies the
   record's `checkUrl` (exists so tests and callers name the policy application).
   `defaultCheckUrl` is implemented by (a) case-insensitively requiring a
   `http://` or `https://` prefix, then (b) parsing with
   `parseRequest :: … -> Either SomeException Request` (http-client's
   `parseRequest` works in any `MonadThrow`; instantiate at
   `Either SomeException`) and inspecting the request's `host` accessor
   (a `ByteString`; import `host` from `Network.HTTP.Client`). Deny when the host
   (lowercased) is `localhost`, `0.0.0.0`, `::1`, `[::1]`, or has prefix `127.`,
   `169.254.`, `10.`, `192.168.`, or is in `172.16.` through `172.31.` (test the
   second dotted octet numerically). Every denial returns
   `Left "<reason>"` naming the offending host or scheme.

3. A capped chunk reader, exported for unit tests:

```haskell
-- | Drain a chunk producer (http-client's 'brRead', which yields "" at end of
-- stream) accumulating at most @cap@ bytes. Returns the capped bytes and
-- whether any data beyond the cap existed. Never reads more than one chunk
-- past the cap.
readCapped :: Int -> IO BS.ByteString -> IO (BS.ByteString, Bool)
readCapped cap next = go 0 []
  where
    go n acc = do
      chunk <- next
      if BS.null chunk
        then pure (BS.concat (reverse acc), False)
        else do
          let n' = n + BS.length chunk
          if n' >= cap
            then do
              let keep = BS.take (cap - n) chunk
              more <- if n' > cap then pure True else (not . BS.null) <$> next
              pure (BS.concat (reverse (keep : acc)), more)
            else go n' (chunk : acc)
```

   (Import `Data.ByteString qualified as BS`.)

4. Rewrite `localFetch` to take the policy, check the URL first (a refusal throws
   `ValidationFailure ("web_fetch: refused by fetch policy: " <> reason)` — a
   recoverable, model-visible error), and stream with `withResponse`/`brRead`
   (import both from `Network.HTTP.Client`) instead of `httpLbs`:

```haskell
localFetch :: (EnvRow es) => FetchPolicy -> Manager -> Text -> Maybe Int -> Eff es FetchResult
localFetch policy manager url maxBytes =
  case checkFetchUrl policy url of
    Left reason -> throwError (ValidationFailure ("web_fetch: refused by fetch policy: " <> reason))
    Right () -> do
      let cap = min (maxResponseBytes policy) (max 0 (maybe 100000 id maxBytes))
      (st, ct, bodyBytes, wasTruncated) <- httpIO "web_fetch" $ do
        request <- parseRequest (T.unpack url)
        withResponse request manager $ \response -> do
          (bytes, cut) <- readCapped cap (brRead (responseBody response))
          pure (statusCode (responseStatus response), contentTypeOf (responseHeaders response), bytes, cut)
      pure
        FetchResult
          { status = st,
            contentType = ct,
            body = TE.decodeUtf8With lenientDecode bodyBytes,
            truncated = wasTruncated
          }
```

5. `localWebClientWith :: FetchPolicy -> Manager -> Maybe SearchConfig -> WebClient`
   is the new general constructor; `localWebClient` keeps its exact signature and
   becomes `localWebClientWith defaultFetchPolicy`, so no caller changes.
   (`Shikumi.Tool.Builtin.Web`'s `webFetchTool` is unchanged — it goes through the
   `WebClient` record.) Update the module haddock with a short security-posture
   paragraph describing the default policy and its DNS-rebinding limitation.

Tests (WebSpec): pure cases for the policy —
`checkFetchUrl defaultFetchPolicy "https://example.com/x"` is `Right ()`;
`"ftp://example.com"`, `"http://localhost:8080/"`, `"http://127.0.0.1/"`,
`"http://169.254.169.254/latest/meta-data/"`, `"http://192.168.1.5/"`, and
`"http://172.20.0.1/"` are all `Left _`. IO cases for the reader — feed `readCapped`
from an `IORef`-backed producer of 1 KiB chunks that never ends; with `cap = 2048`
it must return exactly 2048 bytes, `True`, and have consumed at most 3 chunks
(count with another `IORef`); and with a producer that yields exactly `cap` bytes
then `""`, it must return `(bytes, False)`. One effectful case: a `localWebClient`
built over a real `newTlsManager` asked to fetch
`http://169.254.169.254/latest/meta-data/` must return
`Left (ValidationFailure msg)` with `"refused by fetch policy"` in `msg` — this
proves the refusal happens before any connection attempt (before this milestone the
same call attempts a live connection and fails slowly with `ProviderFailure`).

### Milestone 3 — timeout clamp, truthful truncation, symlink guard

Scope: `Env.hs`, `Fs.hs`, EnvSpec, FsSpec. Three independent fixes verified by
three independent tests.

(3a) Timeout clamp, `Env.hs`. Replace `timeoutMsOrDefault` (lines 173–174) with:

```haskell
-- | Clamp a model-supplied timeout into [1 ms, 'maxExecTimeoutMs']. Unclamped,
-- a non-positive value disables the timeout entirely (GHC's 'System.Timeout.timeout'
-- treats non-positive as "wait forever") and a huge value overflows the
-- microsecond multiplication in 'localExec'.
effectiveTimeout :: Maybe Int -> Int
effectiveTimeout = max 1 . min maxExecTimeoutMs . maybe defaultExecTimeoutMs id

defaultExecTimeoutMs :: Int
defaultExecTimeoutMs = 60000

maxExecTimeoutMs :: Int
maxExecTimeoutMs = 600000
```

and update `localExec` (line 104) to
`let effectiveTimeoutMs = effectiveTimeout (req ^. #timeoutMs)`. After clamping to
at most 600000, `effectiveTimeoutMs * 1000` is at most 6×10^8, far inside `Int`.

Test (EnvSpec): `envExec localToolEnv ExecRequest {command = "sleep 2", cwd =
Nothing, stdin = Nothing, timeoutMs = Just (-1)}` must return
`Left (Timeout msg)` (assert `"timed out"` infix) and must do so in well under two
seconds. Before the fix, the negative value disables the timeout and the call
succeeds after two full seconds — the test fails on the result shape.

(3b) Truthful truncation, `Fs.hs`. Add one helper and use it at every cap site:

```haskell
-- | Cap a list at @n@ items, reporting whether anything was actually dropped.
capResults :: Int -> [a] -> ([a], Bool)
capResults n xs = let (kept, rest) = splitAt n xs in (kept, not (null rest))
```

Apply in `globFast` (replace lines 289–290: cap the filtered lines, sort the kept
list, report the helper's flag), `globFallback` (lines 313–314: cap the filtered
walk, then sort), `parseRgJson` (lines 355–356: cap the `mapMaybe` output), and
`grepFallback` (lines 307–308: already semantically correct; switch it to the
helper for uniformity). Fix `readTool` (line 192): delete the `start > 0 ||`
disjunct so `truncated = length selected < length afterOffset` — the flag now means
"lines after the returned slice were omitted", which is what a model needs to know
to page onward. Because lists here are lazily produced by walks capped elsewhere,
note `splitAt` only forces `n+1` cells — no full-length forcing regression.

Tests (FsSpec): (i) `readTool` on a three-line file with `offset = Just 1, limit =
Nothing` returns `truncated = False` (fails before) and with `offset = Just 0,
limit = Just 1` returns `truncated = True` (passes before and after; pins the
meaning). (ii) exact-cap glob: create exactly 1000 files named `f0.txt` …
`f999.txt` (1000 is `maxResults`; generate with `traverse` over `[0..999]` writing
one byte each — this is fast) and run `globTool noFastToolEnv` with pattern
`*.txt`; assert 1000 paths and `truncated = False` (before the fix this reports
`True`).

(3c) Symlink guard. In `Env.hs`, extend `DirEntry` (lines 69–74) with a third
field `isSymlink :: !Bool`, and set it in `localReaddir` (lines 142–151) via
`System.Directory.pathIsSymbolicLink` on the joined child path *before* the
(link-following) `doesDirectoryExist` call. `DirEntry` is constructed nowhere else
(verified by grep); the two test files import the type abstractly. In `Fs.hs`
`walkFiles` (lines 333–351), treat a symlinked directory as a leaf: recurse only
when `entry ^. #isDir` and not `entry ^. #isSymlink` (keep the existing
`skipDirName` skip). Do not follow directory symlinks at all — that is `fd`'s
default too, keeping fast/fallback parity. Document the choice in `walkFiles`'
haddock.

Test (FsSpec): in a temp root create `real.txt` and a directory symlink
`loop -> .` (use `System.Directory.createDirectoryLink root (root </> "loop")`).
Run `globTool noFastToolEnv` with pattern `*.txt`. After the fix the result is
exactly one path (`root/real.txt`). Before the fix the walker follows `loop`
`maxDepth` times and returns ~26 duplicate paths (`loop/real.txt`,
`loop/loop/real.txt`, …) — the test fails on the count. (On platforms where
creating symlinks fails, e.g. exotic CI, catch the `IOException` from
`createDirectoryLink` and skip the case with `assertBool` on a note — macOS and
Linux both support it unprivileged.)

### Milestone 4 — schema tidy and security-posture documentation

Scope: `Fs.hs` schema helper; module haddocks in `Shell.hs`, `Env.hs`,
`Interpreter.hs`. No behavior change; one pinning test.

Change `toolInputSchema` (Fs.hs lines 445–452) to take the required-field list
instead of hardcoding it:

```haskell
toolInputSchema :: [Text] -> [(Text, Value)] -> Value
toolInputSchema requiredFields fields =
  object
    [ "type" .= ("object" :: Text),
      "properties" .= object (map (\(key, value) -> Key.fromText key .= value) fields),
      "required" .= requiredFields,
      "additionalProperties" .= False
    ]
```

and pass `["pattern"]` at both call sites (the `ToSchema GrepReq` instance, lines
121–128, and `ToSchema GlobReq`, lines 162–167). Add a test (in
`shikumi-tools/test/SchemaSpec.hs`, alongside the existing schema pins) asserting
the generated schemas for `GrepReq` and `GlobReq` still carry
`required == ["pattern"]` — a regression guard for the refactor.

Documentation edits (haddock only, no code):

- `Shell.hs` module doc: add a "Security posture" paragraph stating plainly that
  `bashTool` executes arbitrary model-chosen shell commands on the host via the
  supplied `ToolEnv` with the process's own privileges and environment; it is
  deliberately non-hermetic and intended for trusted, local, single-operator use;
  sandboxing is achieved by supplying a confining `ToolEnv`, not by this module.
- `Env.hs` module doc: add the mirror paragraph for `localToolEnv` (full host
  filesystem access, arbitrary process execution, inherited environment variables
  including any secrets, IO performed inside the `(LLM, Error ShikumiError)` row
  via `unsafeEff_`); state that `ToolEnv` is the sandboxing seam.
- `Interpreter.hs` (lines 26–28 of the SECURITY POSTURE section): replace the
  sentence claiming a subprocess interpreter is impossible inside the row because
  it "needs @IOE@, which the @Embed@ row lacks" with an accurate statement: the
  row does not type-enforce purity — the built-in tool environments already
  perform real IO inside it via `unsafeEff_` (name `Shikumi.Tool.Env.toolIO` and
  `Shikumi.Tool.Web.httpIO`); the hermeticity of the shipped interpreters is a
  property of their construction, and any future subprocess interpreter must
  therefore be gated by explicit configuration and documentation, not assumed
  impossible by the types. Touch nothing else in this file — the grammar section
  and DSL code belong to EP-46.


## Concrete Steps

All commands run from the repository root:

```bash
nix develop .#ghc9124
cabal build shikumi-tools
just test-one shikumi-tools
```

Work milestone by milestone; each is independently committable. Suggested commit
subjects (Conventional Commits), each carrying the mandatory trailers:

```text
fix(tools): unify fallback glob semantics with rg/fd (basename + ** aware)

MasterPlan: docs/masterplans/8-tools-agents-and-cli-hardening.md
ExecPlan: docs/plans/45-builtin-tool-hardening-fs-web-and-timeouts.md
Intention: intention_01kwgdyxm7ehh8yys1pp4wf1zr
```

```text
feat(tools): stream web_fetch with a byte cap and a default SSRF policy
```

```text
fix(tools): clamp exec timeouts, truthful truncated flags, symlink-safe walk
```

```text
docs(tools): security posture for bash/local env; correct interpreter row claim
```

(Every commit gets the same three trailers: `MasterPlan:
docs/masterplans/8-tools-agents-and-cli-hardening.md`, `ExecPlan:
docs/plans/45-builtin-tool-hardening-fs-web-and-timeouts.md`, `Intention:
intention_01kwgdyxm7ehh8yys1pp4wf1zr`.)

Expected suite tail when done (names indicative):

```text
  Tool.Fs
    read/write/edit/grep/glob work through fast and fallback paths: OK
    fast and fallback agree on non-** glob patterns:                OK
    read truncated flag reflects omitted trailing lines only:       OK
    glob at exactly maxResults is not marked truncated:             OK
    walk does not follow directory symlinks:                        OK
  Tool.Env
    a negative exec timeout is clamped, not disabled:               OK
  Tool.Web
    default fetch policy refuses metadata/loopback/private hosts:   OK
    readCapped stops at the cap without draining the stream:        OK
    fetch of a denied URL fails fast with ValidationFailure:        OK

All N tests passed
```


## Validation and Acceptance

Each fix has a failing-before/passing-after test; to demonstrate, stash the
relevant source file and re-run `just test-one shikumi-tools`:

1. Glob parity: with `Fs.hs` reverted, "fast and fallback agree on non-** glob
   patterns" fails (fallback returns `[]` for `*.txt`); with it applied, fast and
   fallback return the same nested paths. The pre-existing `**/*.txt` case still
   passes throughout.
2. Web: `checkFetchUrl defaultFetchPolicy "http://169.254.169.254/…"` is a `Left`;
   fetching that URL through `localWebClient` fails fast with
   `ValidationFailure …refused by fetch policy…` instead of attempting a
   connection; `readCapped` provably consumes at most one chunk past the cap
   (chunk-counter assertion).
3. Timeout: `timeoutMs = Just (-1)` on a `sleep 2` yields `Left (Timeout _)`
   promptly; before the fix the exec completes after 2 s with `Right _`.
4. Truncation: `read` with offset-to-EOF reports `truncated = False`; a glob over
   exactly 1000 matches reports `truncated = False` and 1000 paths.
5. Symlinks: a `loop -> .` directory symlink yields exactly one result for
   `*.txt`, not ~26.
6. Docs: `shikumi-tools/src/Shikumi/Tool/Builtin/Shell.hs` and
   `…/Tool/Env.hs` module haddocks contain a security-posture paragraph;
   `…/CodeExec/Interpreter.hs` no longer claims the row lacks IO capability.
   Verify with a haddock build or by reading:
   `grep -n "unsafeEff_" shikumi-tools/src/Shikumi/CodeExec/Interpreter.hs`
   should hit the corrected paragraph.

Finally `cabal build all` must succeed — `DirEntry` gained a field and
`toolInputSchema` changed arity, but grep confirms all construction/call sites are
inside the two edited modules.


## Idempotence and Recovery

All steps are source edits plus hermetic tests; every command can be re-run safely.
The temp-dir fixtures create and forcibly remove their own scratch directories
(`withTempDir` brackets), so a crashed test run leaves at worst a stale directory
under the system temp dir with a `shikumi-tools-fsspec-` prefix, safe to delete.
The 1000-file test writes only to its scratch dir. If the symlink test's
`createDirectoryLink` fails on an unsupported platform, skip semantics are
described in M3c. Each milestone is an independent commit; revert any one without
affecting the others (M1 and M3b touch different regions of `Fs.hs`).


## Interfaces and Dependencies

No new package dependencies: `http-client` (for `withResponse`, `brRead`, `host`)
and `regex-tdfa` are already in `shikumi-tools.cabal`'s library build-depends; the
tests need only what the test-suite stanza already lists.

End-state signatures that must exist:

- `Shikumi.Tool.Builtin.Fs` (internal): `globMatches :: Text -> Text -> Text ->
  Bool` (root, pattern, candidate), `capResults :: Int -> [a] -> ([a], Bool)`,
  `toolInputSchema :: [Text] -> [(Text, Value)] -> Value`.
- `Shikumi.Tool.Env` (exported, as today plus): `DirEntry` with fields
  `name :: Text`, `isDir :: Bool`, `isSymlink :: Bool`.
- `Shikumi.Tool.Web` (exported): `FetchPolicy (..)`, `defaultFetchPolicy ::
  FetchPolicy`, `checkFetchUrl :: FetchPolicy -> Text -> Either Text ()`,
  `readCapped :: Int -> IO ByteString -> IO (ByteString, Bool)`,
  `localWebClientWith :: FetchPolicy -> Manager -> Maybe SearchConfig ->
  WebClient`, with `localWebClient :: Manager -> Maybe SearchConfig -> WebClient`
  unchanged and delegating.

Cross-plan coordination (from the master plan): EP-46 owns the Interpreter.hs
grammar section and DSL code; this plan touches only its security-posture
paragraph. Neither EP-44 nor EP-47 touches any file this plan edits.
