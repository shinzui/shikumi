-- OKF profile for shikumi program documentation bundles.
--
-- A profile is a small Dhall descriptor that layers house conventions on top of
-- OKF: which `type` strings are allowed, which frontmatter keys are required, the
-- `resource:` URI scheme, and the file layout. `okf validate --profile` (and
-- mori, at register/observe time) check a generated bundle against it, so every
-- application's program documentation stays consistent. Profiles are NOT part of
-- the OKF standard; a bundle that deviates remains fully OKF-conformant.
--
-- This bundle layout is produced by the `shikumi-okf` package: one `Shikumi App`
-- concept at `apps/<app>` linking to one `Shikumi Program` concept per program at
-- `programs/<name>`, with `shikumi://` resource URIs.
--
-- The schema is imported here by a relative path to the sibling `okf` checkout,
-- matching how cabal.project resolves okf-core locally. For a published,
-- reproducible profile, replace this import with a pinned raw URL into the
-- shared okf-profiles location (e.g.
-- https://raw.githubusercontent.com/shinzui/okf/<sha>/okf-core/dhall/Profile.dhall).
let Profile = ../../../okf/okf-core/dhall/Profile.dhall

in  { name = "shinzui-shikumi"
    , okfVersion = "0.1"
    , frontmatter =
      { required = [ "type", "title" ]
      , recommended = [ "description", "resource" ]
      }
    , allowUnknownTypes = False
    , types =
      [ { type = "Shikumi App"
        , pathPattern = Some "apps/*"
        , resourceScheme = Some "shikumi"
        , requireSchemaSection = False
        , schemaColumns = [] : List Text
        }
      , { type = "Shikumi Program"
        , pathPattern = Some "programs/*"
        , resourceScheme = Some "shikumi"
        , requireSchemaSection = False
        , schemaColumns = [] : List Text
        }
      ]
    }
  : Profile
