let Schema =
      https://raw.githubusercontent.com/shinzui/mori-schema/026ae74331e5c516542af1dd96f041c658ed4621/package.dhall
        sha256:18258ef583580a897f4af3e7c86db0342afb42fb40efc535b217ba1089230141

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
    }
