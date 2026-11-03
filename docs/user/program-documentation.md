# Document programs with shikumi-okf

`shikumi-okf` generates an Open Knowledge Format (OKF) bundle describing an
application and the programs it exposes. It reads program structure and
human-authored metadata without calling a model or running the programs.
The dependency is opt-in: applications using only core Shikumi do not need it.

## Run the example

Inside the repository's Nix development shell:

```bash
cabal run shikumi-okf-example -- /tmp/shikumi-program-docs
okf validate /tmp/shikumi-program-docs --strict \
  --profile shikumi-okf/profile/shikumi.dhall --profile-enforce
```

The standalone validator belongs to `mori://shinzui/okf`; generation itself only
requires the `shikumi-okf-example` executable. The output contains one application
concept and two program concepts, with indexes and links between them. See the
[complete example](../../shikumi-okf/example/Main.hs) and
[committed output](../../shikumi-okf/example/out/index.md).

## Supply a manifest

A `Program i o` has no application-level name. Supply a `ProgramManifest` of
`ProgramDoc` entries, wrapping each available program in `SomeProgram`. The
existential wrapper lets one manifest contain programs with different types.
For an existing `classify :: Program Ticket Category`:

```haskell
import Shikumi.Okf.Generate (defaultGenerateOptions, writeProgramBundle)
import Shikumi.Okf.Types

manifest :: ProgramManifest
manifest = ProgramManifest
  [ ProgramDoc
      { name = "classify-ticket"
      , title = Just "Classify Ticket"
      , description = Just "Assign a support ticket to a category."
      , tags = ["support"]
      , declaredInputs = Just "The customer report."
      , declaredOutputs = Just "The owning support category."
      , program = Just (SomeProgram classify)
      }
  ]

app :: AppInfo
app = AppInfo
  { appNamespace = "example"
  , appName = "support"
  , appTitle = Just "Support workflows"
  , appDescription = Just "Typed programs used by the support application."
  }

-- In IO; inspect Left GenerateError before publishing the output.
result <- writeProgramBundle outputDirectory app defaultGenerateOptions manifest
```

Add `shikumi-okf` to the documentation generator's dependencies. Keep executable
program definitions in their usual modules and import them into the manifest;
the generator does not discover them by scanning source files.

## What generation preserves

Each program concept combines the declared metadata with the inspectable
constructor tree and prediction-node field information. Supply `declaredInputs`
and `declaredOutputs` for opaque `Embed` programs, whose internal contracts cannot
be inferred structurally. Use `program = Nothing` for metadata-only documentation
when the caller cannot supply a program value.

`defaultGenerateOptions` declares OKF v0.2 and the producer
`process:shikumi-okf`. It supplies no generation timestamp, so an unchanged
manifest yields byte-identical documents. Start with the defaults and override
fields rather than constructing options positionally. Regenerate into a temporary
directory and compare with committed output to detect documentation drift.

The generator produces documentation, not an executable program artifact or an
evaluation report. Runtime behavior of opaque closures and model quality still
need their own evidence. The [capability record](../capabilities/okf-program-documentation.md)
links the shipped interface, profile, and acceptance tests.
