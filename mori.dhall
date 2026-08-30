let Schema =
      https://raw.githubusercontent.com/shinzui/mori-schema/9899d4544790da7120e8150c73e56cb53fe35191/package.dhall
        sha256:4024df757a0178e37fb0b5f04d7deb284dc3ee9bfea89a6610b793338101e284

let projectRef =
      \(namespace : Text) ->
      \(name : Text) ->
        Schema.MoriRef::{ namespace, name }

let testDep =
      \(depName : Text) ->
        Schema.Dependency.WithAugmentation
          { name = depName
          , extraDocs = [] : List Schema.DocRef.Type
          , localPathOverride = None Text
          , kind = Some Schema.DependencyKind.ThirdParty
          , source = Some Schema.DependencySource.Hackage
          , scope = Some Schema.DependencyScope.Test
          , versionConstraint = None Text
          }

in  Schema.Project::{
    , project = Schema.ProjectIdentity::{
      , name = "shikumi"
      , namespace = "shinzui"
      , type = Schema.PackageType.Library
      , language = Schema.Language.Haskell
      , lifecycle = Schema.Lifecycle.Active
      , description = Some
          "A Haskell-native framework for building typed, evaluable, reproducible, and optimizable language-model programs"
      , domains = [ "AI", "LLM", "Framework" ]
      , owners = [ "shinzui" ]
      }
    , repos = [ Schema.Repo::{ name = "shikumi" } ]
    , packages =
      [ Schema.Package::{
        , name = "shikumi"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , path = Some "shikumi"
        , description = Some
            "Typed, structured, evaluable LM programs: Program/Signature core, structured decoding, runtime, tracing, and evaluation"
        , dependencies =
          [ Schema.Dependency.ByName "haskell/aeson"
          , Schema.Dependency.ByName "shinzui/baikai"
          , Schema.Dependency.ByName "effectful/effectful"
          , Schema.Dependency.ByName "ekmett/lens"
          , testDep "composewell/streamly"
          , testDep "UnkindPartition/tasty"
          ]
        }
      , Schema.Package::{
        , name = "shikumi-cache"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , path = Some "shikumi-cache"
        , description = Some
            "Content-addressed response caching for shikumi (EP-6)"
        , dependencies =
          [ Schema.Dependency.ByName "haskell/aeson"
          , Schema.Dependency.ByName "shinzui/baikai"
          , Schema.Dependency.ByName "k0001/hs-blake3"
          , Schema.Dependency.ByName "effectful/effectful"
          , Schema.Dependency.ByName "ekmett/lens"
          , testDep "UnkindPartition/tasty"
          ]
        }
      , Schema.Package::{
        , name = "shikumi-cache-redis"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , path = Some "shikumi-cache-redis"
        , description = Some "Redis-backed shikumi cache (EP-6)"
        , dependencies =
          [ Schema.Dependency.ByName "haskell/aeson"
          , Schema.Dependency.ByName "effectful/effectful"
          , Schema.Dependency.ByName "informatikr/hedis"
          , testDep "shinzui/baikai"
          , testDep "ekmett/lens"
          , testDep "UnkindPartition/tasty"
          ]
        }
      , Schema.Package::{
        , name = "shikumi-cache-postgres"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , path = Some "shikumi-cache-postgres"
        , description = Some "Postgres-backed shikumi cache (EP-6)"
        , dependencies =
          [ Schema.Dependency.ByName "haskell/aeson"
          , Schema.Dependency.ByName "effectful/effectful"
          , Schema.Dependency.ByName "hasql/hasql"
          , testDep "shinzui/baikai"
          , testDep "shinzui/ephemeral-pg"
          , testDep "ekmett/lens"
          , testDep "UnkindPartition/tasty"
          ]
        }
      , Schema.Package::{
        , name = "shikumi-cli"
        , type = Schema.PackageType.Tool
        , language = Schema.Language.Haskell
        , path = Some "shikumi-cli"
        , description = Some "The shikumi command-line interface (EP-12)"
        , dependencies =
          [ Schema.Dependency.ByName "haskell/aeson"
          , Schema.Dependency.ByName "shinzui/baikai"
          , Schema.Dependency.ByName "effectful/effectful"
          , Schema.Dependency.ByName "ekmett/lens"
          , Schema.Dependency.ByName "pcapriotti/optparse-applicative"
          , testDep "UnkindPartition/tasty"
          ]
        }
      , Schema.Package::{
        , name = "shikumi-compile"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , path = Some "shikumi-compile"
        , description = Some "The compiler layer for shikumi LM programs (EP-9)"
        , dependencies =
          [ Schema.Dependency.ByName "haskell/aeson"
          , Schema.Dependency.ByName "effectful/effectful"
          , Schema.Dependency.ByName "ekmett/lens"
          , testDep "shinzui/baikai"
          , testDep "UnkindPartition/tasty"
          ]
        }
      , Schema.Package::{
        , name = "shikumi-eval"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , path = Some "shikumi-eval"
        , description = Some
            "Typed evaluation framework for shikumi LM programs (EP-8)"
        , dependencies =
          [ Schema.Dependency.ByName "haskell/aeson"
          , Schema.Dependency.ByName "shinzui/baikai"
          , Schema.Dependency.ByName "effectful/effectful"
          , Schema.Dependency.ByName "ekmett/lens"
          , Schema.Dependency.ByName "UnkindPartition/tasty"
          ]
        }
      , Schema.Package::{
        , name = "shikumi-jitsurei"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , path = Some "shikumi-jitsurei"
        , description = Some "Worked examples (実例) for the shikumi framework"
        , dependencies =
          [ Schema.Dependency.ByName "haskell/aeson"
          , Schema.Dependency.ByName "shinzui/baikai"
          , Schema.Dependency.ByName "effectful/effectful"
          , Schema.Dependency.ByName "ekmett/lens"
          ]
        }
      , Schema.Package::{
        , name = "shikumi-okf"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , path = Some "shikumi-okf"
        , description = Some
            "Generate OKF documentation bundles from shikumi programs (EP-31)"
        , dependencies =
          [ Schema.Dependency.ByName "shinzui/okf"
          , testDep "effectful/effectful"
          , testDep "UnkindPartition/tasty"
          ]
        }
      , Schema.Package::{
        , name = "shikumi-optimize"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , path = Some "shikumi-optimize"
        , description = Some
            "The optimizer framework for shikumi LM programs (EP-10)"
        , dependencies =
          [ Schema.Dependency.ByName "haskell/aeson"
          , Schema.Dependency.ByName "effectful/effectful"
          , Schema.Dependency.ByName "ekmett/lens"
          , testDep "shinzui/baikai"
          , testDep "UnkindPartition/tasty"
          ]
        }
      , Schema.Package::{
        , name = "shikumi-tools"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , path = Some "shikumi-tools"
        , description = Some
            "Typed tools and ReAct agents for shikumi LM programs (EP-11)"
        , dependencies =
          [ Schema.Dependency.ByName "haskell/aeson"
          , Schema.Dependency.ByName "shinzui/baikai"
          , Schema.Dependency.ByName "effectful/effectful"
          , Schema.Dependency.ByName "snoyberg/http-client"
          , Schema.Dependency.ByName "ekmett/lens"
          , testDep "UnkindPartition/tasty"
          ]
        }
      , Schema.Package::{
        , name = "shikumi-trace"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , path = Some "shikumi-trace"
        , description = Some
            "Hierarchical tracing, observability, and deterministic replay for shikumi (EP-7)"
        , dependencies =
          [ Schema.Dependency.ByName "haskell/aeson"
          , Schema.Dependency.ByName "shinzui/baikai"
          , Schema.Dependency.ByName "effectful/effectful"
          , Schema.Dependency.ByName "ekmett/lens"
          , testDep "UnkindPartition/tasty"
          ]
        }
      , Schema.Package::{
        , name = "shikumi-trace-otel"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , path = Some "shikumi-trace-otel"
        , description = Some
            "OpenTelemetry export of shikumi hierarchical trace trees (EP-7)"
        , dependencies =
          [ Schema.Dependency.ByName "haskell/aeson"
          , Schema.Dependency.ByName "iand675/hs-opentelemetry"
          , Schema.Dependency.ByName "ekmett/lens"
          , testDep "UnkindPartition/tasty"
          ]
        }
      ]
    , dependencies =
      [ "haskell/aeson"
      , "shinzui/baikai"
      , "k0001/hs-blake3"
      , "shinzui/cmark-gfm-hs"
      , "effectful/effectful"
      , "shinzui/ephemeral-pg"
      , "hasql/hasql"
      , "informatikr/hedis"
      , "snoyberg/http-client"
      , "iand675/hs-opentelemetry"
      , "ekmett/lens"
      , "shinzui/okf"
      , "pcapriotti/optparse-applicative"
      , "composewell/streamly"
      , "UnkindPartition/tasty"
      ]
    , dependencyRefs =
      [ projectRef "haskell" "aeson"
      , projectRef "shinzui" "baikai"
      , projectRef "k0001" "hs-blake3"
      , projectRef "shinzui" "cmark-gfm-hs"
      , projectRef "effectful" "effectful"
      , projectRef "shinzui" "ephemeral-pg"
      , projectRef "hasql" "hasql"
      , projectRef "informatikr" "hedis"
      , projectRef "snoyberg" "http-client"
      , projectRef "iand675" "hs-opentelemetry"
      , projectRef "ekmett" "lens"
      , projectRef "shinzui" "okf"
      , projectRef "pcapriotti" "optparse-applicative"
      , projectRef "composewell" "streamly"
      , projectRef "UnkindPartition" "tasty"
      ]
    , okfBundles =
      [ Schema.OkfBundle::{
        , name = "improvement-requests"
        , path = "docs/improvement-requests"
        , profileBinding = Some
            ( Schema.ProfileBinding.Published
                Schema.PinnedImport::{
                , publisher = "shinzui/okf-profiles"
                , publisherRef = Some (projectRef "shinzui" "okf-profiles")
                , export = Some "coordination.improvementRequests"
                , version = Some "v0.8.0"
                , pin = Some
                    "sha256:0d66bb25b99e74a10598be06eef30356f331ff9c1c557e8578daf48cbd50d8d3"
                }
            )
        , okfVersion = "0.2"
        , description = Some "Shikumi-owned improvement requests"
        }
      , Schema.OkfBundle::{
        , name = "capabilities"
        , path = "docs/capabilities"
        , profile = Some "docs/capabilities/profile.dhall"
        , okfVersion = "0.2"
        , description = Some
            "What shikumi provides today, one concept per capability, with evidence"
        }
      ]
    }
