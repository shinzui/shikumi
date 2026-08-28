-- Turn an observed release tag into the one immutable Project release fact
-- mori keeps for shinzui/shikumi.
--
-- The same shape shinzui/baikai uses. It exists here so the cascade has a
-- second hop: kioku cannot see this repo's tags, and a release fact is the only
-- thing that can tell it Shikumi has published a version admitting the new
-- baikai.
let Schema =
      https://raw.githubusercontent.com/shinzui/mori-schema/9899d4544790da7120e8150c73e56cb53fe35191/package.dhall
        sha256:4024df757a0178e37fb0b5f04d7deb284dc3ee9bfea89a6610b793338101e284

in  Schema.Automation::{
    , events =
      [ Schema.EventSelector.RefSelector Schema.RefSelector::{
        , name = "shikumi-release-tag"
        ,
          -- Every release tag in the repo, not only the umbrella one. Mori's
          -- ref globs understand `*` and `**` and nothing else, so no pattern
          -- can say "shikumi- followed by a version and no further package
          -- segment". scripts/record-release.sh makes that distinction and
          -- exits quietly on the twelve sibling package tags.
          refPatterns = [ "shikumi-*" ]
        , kinds = [ "tag" ]
        }
      ]
    , reactions =
      [ Schema.Reaction::{
        , name = "record-shikumi-release"
        , on = [ "shikumi-release-tag" ]
        , actions =
          [ Schema.ReactionAction.RunCommand Schema.RunCommandAction::{
            , command = "./scripts/record-release.sh"
            , args = [ "{{ref.name}}" ]
            ,
              -- One `mori registry release record` against a local Postgres.
              -- Without an explicit value this would inherit the 600-second
              -- default and hold the FIFO group for ten minutes on a hung
              -- database.
              timeout = Some +60
            }
          ]
        }
      ]
    ,
      -- A release cut pushes thirteen tags in the same second, so this
      -- automation is triggered thirteen times at once. Recording a version
      -- twice is already safe, but serializing keeps the thirteen `mori`
      -- invocations from racing each other into the same Project stream.
      queued = True
    , execution = Schema.ExecutionPolicy::{ allowLocal = True }
    }
