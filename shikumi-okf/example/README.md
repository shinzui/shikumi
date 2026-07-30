# shikumi-okf example

A worked example of generating an OKF documentation bundle from a shikumi
program manifest. The generator (`example/Main.hs`) defines a two-program
manifest — one typed `Predict` program (`classify-ticket`) and one opaque
`Embed` program (`heartbeat`, the shape a declared-agent runtime such as
shikigami produces) — and writes the bundle to the directory given as its first
argument.

## Generate the bundle

From the repository root, inside the dev shell (`nix develop`):

```bash
cabal run shikumi-okf-example -- shikumi-okf/example/out
```

This writes the committed `out/` tree:

```text
out/apps/example-app.md          # the Shikumi App concept (links to each program)
out/programs/classify-ticket.md  # a Shikumi Program concept (typed Predict)
out/programs/heartbeat.md        # a Shikumi Program concept (opaque Embed)
out/**/index.md                  # generated OKF indexes
```

Because no timestamp is passed, regenerating from an unchanged manifest produces
byte-identical output. A CI check can regenerate into `out/` and fail if
`git status --porcelain shikumi-okf/example/out` reports any change.

## Validate it with the standalone okf CLI

The `okf` binary lives in the sibling `okf` repository. `profile/shikumi.dhall`
uses the `0.3.0.0` profile schema, so `--profile` needs `okf` `>=0.3`. From there:

```bash
cabal run okf -- validate <repo>/shikumi-okf/example/out
# OK: 3 concepts

cabal run okf -- validate <repo>/shikumi-okf/example/out \
  --profile <repo>/shikumi-okf/profile/shikumi.dhall --profile-enforce
# OK: 3 concepts   (exit 0 — conforms to the shikumi profile)

cabal run okf -- graph <repo>/shikumi-okf/example/out --json
# edges: apps/example-app -> programs/classify-ticket
#        apps/example-app -> programs/heartbeat
```

## Index the bundle in mori

To have mori index and profile-validate the bundle across projects, declare it
in the consuming application's `mori.dhall` under `okfBundles` (the schema field
already exists in mori-schema):

```dhall
, okfBundles =
  [ Schema.OkfBundle::{
    , name = "programs"
    , path = "shikumi-okf/example/out"
    , okfVersion = "0.1"
    , profile = Some "<path-or-pinned-url>/shikumi.dhall"
    }
  ]
```

In a real application, `path` points at wherever that app commits its generated
bundle, and `profile` points at the shared `shikumi.dhall` (a pinned URL once it
is published to the okf-profiles location). At register/observe time mori walks
the bundle with okf-core and reports any profile deviation as an advisory line.
