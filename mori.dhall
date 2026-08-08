let Schema =
      https://raw.githubusercontent.com/shinzui/mori-schema/06da43590476f4ddc64386e91be9ca88a1f3c9d6/package.dhall
        sha256:dd0c3e0094714498fe7b2562aa85998624b13198758d9160b5ea74b253491836

let testDep =
      \(depName : Text) ->
        Schema.Dependency.WithAugmentation
          { name = depName
          , extraDocs = [] : List Schema.DocRef.Type
          , localPathOverride = None Text
          , kind = Some Schema.DependencyKind.ThirdParty
          , source = Some Schema.DependencySource.Hackage
          , scope = Some Schema.DependencyScope.Test
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
    , okfBundles =
      [ Schema.OkfBundle::{
        , name = "improvement-requests"
        , path = "docs/improvement-requests"
        , profile = Some "docs/improvement-requests/profile.dhall"
        , okfVersion = "0.2"
        , description = Some "Shikumi-owned improvement requests"
        }
      ]
    }
