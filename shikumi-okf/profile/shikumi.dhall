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
-- The schema is imported through okf's published entry point (`package.dhall`) by
-- a relative path to the sibling `okf` checkout. Every record below is written
-- with okf's record-completion defaults (`::`) and `mk` constructors, so a future
-- additive, defaulted schema field leaves this descriptor working unchanged. For a
-- published, reproducible profile, replace this import with a pinned raw URL (e.g.
-- https://raw.githubusercontent.com/shinzui/okf/<tag>/okf-core/dhall/package.dhall).
--
-- Types are closed (`allowUnknownTypes = False`): a shikumi bundle contains only
-- the two concept types `shikumi-okf` generates. Top-level frontmatter stays open
-- (`allowUnknownFields` keeps its default of True) because generated documents also
-- carry `tags` and an optional generation timestamp, and authors may add keys of
-- their own. No `idField` is declared, so document-handle checks stay off: shikumi
-- concepts are addressed by concept id and `shikumi://` resource, not by stable
-- handles. Every field rule keeps the default `Any` cardinality and no `format`,
-- matching the presence-only checks this profile has always expressed.
let okf = ../../../okf/okf-core/dhall/package.dhall

let field = okf.mk.FieldRule

let appType =
      okf.defaults.TypeRule::{
      , type = "Shikumi App"
      , description = Some
          "One application that ships shikumi programs; links to every program it exposes."
      , pathPattern = Some "apps/*"
      , resourceScheme = Some "shikumi"
      }

let programType =
      okf.defaults.TypeRule::{
      , type = "Shikumi Program"
      , description = Some
          "One shikumi program: its signature, adapter, and declared metadata."
      , pathPattern = Some "programs/*"
      , resourceScheme = Some "shikumi"
      }

in  okf.defaults.Profile::{
    , name = "shinzui-shikumi"
    , description = Some
        "House conventions for OKF bundles generated from shikumi programs by the shikumi-okf package."
    , okfVersion = "0.1"
    , frontmatter = okf.defaults.FrontmatterRules::{
      , required =
        [ field.documented
            "type"
            "The OKF concept type: `Shikumi App` or `Shikumi Program`."
        , field.documented "title" "Human-readable name of the app or program."
        ]
      , recommended =
        [ field.documented
            "description"
            "What the app or program is for, in one or two sentences."
        , field.documented
            "resource"
            "The `shikumi://<namespace>/<app>` URI this concept documents."
        ]
      }
    , allowUnknownTypes = False
    , types = [ appType, programType ]
    }
