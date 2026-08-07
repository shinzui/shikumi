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
-- The schema is imported through okf's published entry point (`package.dhall`) at
-- a pinned tag, protected by a Dhall integrity hash. It is deliberately NOT a
-- relative path into a sibling `okf` checkout: that spelling resolves against
-- whatever is in someone's working tree, so this descriptor silently stopped
-- type-checking when okf's schema moved ahead of the pinned `okf-core` release,
-- and it cannot work at all for anyone who installs this package from Hackage.
--
-- The hash covers the fully resolved, normalized expression, so it pins every
-- transitive `./Profile.dhall`, `./defaults/*`, and `./mk/*` the entry point
-- pulls in — not just the one file. Moving the tag therefore fails the load
-- loudly instead of changing the schema underneath this profile.
--
-- Dhall serves a hashed import from `~/.cache/dhall` when it is present, so only
-- the first resolution on a machine needs the network. To move to a new okf
-- release, bump the tag and refresh the hash with:
--
--     echo 'https://raw.githubusercontent.com/shinzui/okf/<tag>/okf-core/dhall/package.dhall' | dhall hash
--
-- Every record below is written with okf's record-completion defaults (`::`) and
-- `mk` constructors, so a future additive, defaulted schema field leaves this
-- descriptor working unchanged.
--
-- Types are closed (`allowUnknownTypes = False`): a shikumi bundle contains only
-- the two concept types `shikumi-okf` generates. Top-level frontmatter is closed
-- too (`allowUnknownFields = False`). That is safe because a closed key set still
-- always admits the six core OKF keys — `type`, `title`, `description`,
-- `timestamp`, `resource`, `tags` — and those six are exactly what the generator
-- emits: its frontmatter comes from three helpers (`okfCommon`, `setResource`,
-- `setTags`) and there is no mechanism for an author to inject other keys. So
-- closing the set cannot reject a generated document; what it catches is a
-- hand-added stray key in a bundle that is supposed to be generated. No `idField`
-- is declared, so document-handle checks stay off: shikumi concepts are addressed
-- by concept id and `shikumi://` resource, not by stable handles.
--
-- Value shapes are checked, not just key presence: every single-valued key is
-- declared `Cardinality.Scalar`, so `title: [a, b]` is a violation rather than a
-- silent pass.
--
-- This profile targets OKF v0.2 and requires its bundles to say so
-- (`requireBundleVersion = Some "0.2"`). The specification makes the root
-- `okf_version` declaration a MAY, so okf itself never asks for it — and an
-- undeclared bundle quietly opts out of every v0.2-only check, including the
-- report of concepts still carrying the superseded `timestamp`. `shikumi-okf`
-- writes the declaration on every bundle it generates, so requiring it here
-- costs a conformant producer nothing and catches a bundle that drifted back.
--
-- Provenance is the v0.2 `generated` family rather than the v0.1 `timestamp`
-- key, which this profile no longer declares at all: `allowUnknownFields` is
-- `False`, so a stray `timestamp` is now reported as an undeclared key on top of
-- whatever the core v0.2 checks say about it. `generated` sits under
-- `recommended` rather than `required` because a caller may pass
-- `generated = Nothing` to disclaim provenance rather than have the generator
-- invent it; the consequence is that `okf validate --strict` advises on such a
-- bundle while an ordinary run does not.
--
-- Rules that are true of one document kind only live in that kind's own
-- `frontmatter` record, which okf merges with the profile-wide one. `resource` is
-- declared there rather than profile-wide: the generator always emits it for both
-- kinds, so per-type `required` states the truth precisely, and declaring the same
-- key in both scopes would yield two overlapping presence clauses for no gain. Its
-- `UriWithScheme "shikumi"` format parses the value, so `resource: not-a-uri` is a
-- violation; that overlaps harmlessly with the `resourceScheme` check each type
-- rule already performs. `tags` is recommended on `Shikumi Program` only, as a
-- `List`, because only program documents carry it and only when the author
-- declared any.
let okf =
      https://raw.githubusercontent.com/shinzui/okf/v0.5.0.0/okf-core/dhall/package.dhall
        sha256:02a821061043976b0ec0d60745a792f5f536e5f5d0db43bc990890ab0f5af0e3

let field = okf.mk.FieldRule

let nested = okf.mk.NestedFieldRule

let scalarOf =
      \(name : Text) ->
      \(prose : Text) ->
      \(fmt : Optional okf.FieldFormat) ->
        okf.defaults.FieldRule::{
        , field = name
        , description = Some prose
        , cardinality = okf.Cardinality.Scalar
        , format = fmt
        }

-- OKF v0.2 §5.2: `by` is REQUIRED within the `generated` mapping, `at` is
-- optional. `at` is declared `optional` rather than `recommended` because
-- shikumi-okf omits it unless the caller supplies a time — that omission is what
-- keeps regenerating an unchanged manifest byte-identical — so demanding it
-- under `--strict` would advise against the generator's own determinism.
let generatedMembers =
      okf.defaults.NestedRules::{
      , required =
        [     nested.actor "by"
          //  { description = Some
                  "§7. The actor that produced this document: `<producer>/<version>`, `human:<id>`, or `process:<id>`."
              }
        ]
      , optional =
        [     nested.rfc3339Utc "at"
          //  { description = Some
                  "When the document was generated, if the caller supplied a time."
              }
        ]
      }

let appType =
      okf.defaults.TypeRule::{
      , type = "Shikumi App"
      , description = Some
          "One application that ships shikumi programs; links to every program it exposes."
      , frontmatter = okf.defaults.FrontmatterRules::{
        , required =
          [ scalarOf
              "resource"
              "The `shikumi://<namespace>/<app>` URI this concept documents."
              (Some (okf.FieldFormat.UriWithScheme "shikumi"))
          ]
        }
      , pathPattern = Some "apps/*"
      , resourceScheme = Some "shikumi"
      }

let programType =
      okf.defaults.TypeRule::{
      , type = "Shikumi Program"
      , description = Some
          "One shikumi program: its signature, adapter, and declared metadata."
      , frontmatter = okf.defaults.FrontmatterRules::{
        , required =
          [ scalarOf
              "resource"
              "The `shikumi://<namespace>/<app>/programs/<name>` URI this concept documents."
              (Some (okf.FieldFormat.UriWithScheme "shikumi"))
          ]
        , recommended = [ field.list "tags" ]
        }
      , pathPattern = Some "programs/*"
      , resourceScheme = Some "shikumi"
      }

in  okf.defaults.Profile::{
    , name = "shinzui-shikumi"
    , description = Some
        "House conventions for OKF bundles generated from shikumi programs by the shikumi-okf package."
    , okfVersion = "0.2"
    , requireBundleVersion = Some "0.2"
    , frontmatter = okf.defaults.FrontmatterRules::{
      , required =
        [ scalarOf
            "type"
            "The OKF concept type: `Shikumi App` or `Shikumi Program`."
            (None okf.FieldFormat)
        , scalarOf
            "title"
            "Human-readable name of the app or program."
            (None okf.FieldFormat)
        ]
      , recommended =
        [ scalarOf
            "description"
            "What the app or program is for, in one or two sentences."
            (None okf.FieldFormat)
        ,     field.record "generated" generatedMembers
          //  { description = Some
                  "OKF v0.2 §5.2. How this document was produced. `shikumi-okf` writes `by: process:shikumi-okf` on every concept it generates. Supersedes the v0.1 `timestamp` key, which this profile no longer declares: a bundle declaring `okf_version: \"0.2\"` that still carried `timestamp` would be reported as retaining a superseded key."
              }
        ]
      }
    , allowUnknownTypes = False
    , allowUnknownFields = False
    , types = [ appType, programType ]
    }
