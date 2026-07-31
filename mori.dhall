let Schema =
      https://raw.githubusercontent.com/shinzui/mori-schema/b85081a0e935a976202fd7a1227f8b93e2cbeb23/package.dhall
        sha256:1501e5c3e55e78d2a58774e2f8aefda20e32b948fa7caf639473fce90929464b

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
        , dependencies = [ Schema.Dependency.ByName "shinzui/baikai:baikai" ]
        }
      ]
    , dependencies = [ "shinzui/baikai" ]
    , okfBundles =
      [ Schema.OkfBundle::{
        , name = "improvement-requests"
        , path = "docs/improvement-requests"
        , profile = Some "docs/improvement-requests/profile.dhall"
        , okfVersion = "0.1"
        , description = Some "Shikumi-owned improvement requests"
        }
      ]
    }
