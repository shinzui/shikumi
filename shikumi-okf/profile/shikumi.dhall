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
-- silent pass. `timestamp` carries the `Rfc3339Utc` format so a value like
-- `yesterday` is rejected; it sits under `recommended` rather than `required`
-- because `shikumi-okf` takes the timestamp as an explicit argument and omits the
-- key when the caller supplies none, which is what makes regenerating an unchanged
-- manifest byte-identical. The consequence is that `okf validate --strict` reports
-- a missing-recommended advisory for timestamp-free bundles; an ordinary
-- (non-strict) run does not, since presence of a recommended key is only demanded
-- under strict authoring.
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
let okf = ../../../okf/okf-core/dhall/package.dhall

let field = okf.mk.FieldRule

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
    , okfVersion = "0.1"
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
        , scalarOf
            "timestamp"
            "Generation time, when the generator was given one. Optional by design: shikumi-okf takes the timestamp as an explicit argument so that regenerating an unchanged manifest is byte-identical, and omits the key when no timestamp is supplied. Declared here so its format is checked when it IS present; because it sits under `recommended`, an ordinary validation run does not demand it, while `okf validate --strict` will advise on its absence."
            (Some okf.FieldFormat.Rfc3339Utc)
        ]
      }
    , allowUnknownTypes = False
    , allowUnknownFields = False
    , types = [ appType, programType ]
    }
