-- Turn an observed release tag into the one immutable Project release fact
-- mori keeps for shinzui/shikumi.
--
-- The same shape shinzui/baikai uses. It exists here so the cascade has a
-- second hop: kioku cannot see this repo's tags, and a release fact is the only
-- thing that can tell it Shikumi has published a version admitting the new
-- baikai.
--
-- Pinned to mori-schema 7904371, the commit that adds `RefSelector.refRegexes`.
-- This is the commit the current mori binary embeds, so the import resolves
-- without touching the network.
let Schema =
      https://raw.githubusercontent.com/shinzui/mori-schema/7904371c3ee1f592b427167e213cb1baa835de2c/package.dhall
        sha256:4b3730d985a19575278e3f155d98d5a60992e5f51b4f9223d390ef13e513e3c4

in  Schema.Automation::{
    , events =
      [ Schema.EventSelector.RefSelector Schema.RefSelector::{
        , name = "shikumi-release-tag"
        ,
          -- Only the umbrella `shikumi-<version>` tag, not the twelve sibling
          -- package tags. A whole-input POSIX extended regex, so
          -- `shikumi-0.3.0.3` matches and `shikumi-cache-0.1.2.2` does not.
          -- Ref globs understand `*` and `**` and nothing else, so before mori
          -- grew `refRegexes` this narrowing had to live in
          -- scripts/record-release.sh, which fired on all thirteen tags and
          -- exited quietly on twelve. `[.]` for the literal dot: a Dhall
          -- double-quoted string would otherwise need the backslash doubled.
          refRegexes = [ "shikumi-[0-9]+([.][0-9]+)*" ]
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
              -- Not the 600-second default, which would hold the FIFO group for
              -- ten minutes on a hung database -- but not 60 seconds either.
              -- Every RunCommand is executed as `nix develop --command`, and
              -- that entry, not the single `mori registry release record`
              -- against a local Postgres, dominates: a backlog of ref
              -- observations timed out reactions in shinzui/keiro and
              -- shinzui/baikai at 60s while the nix eval cache was cold and
              -- contended.
              timeout = Some +300
            }
          ]
        }
      ]
    ,
      -- A release cut now triggers this once, not thirteen times, so the
      -- original reason for queueing is gone. It is kept for the replay case:
      -- `mori automate reset-checkpoint --to-root` re-observes every umbrella
      -- tag in the repo's history at once, and serializing keeps those
      -- invocations from racing each other into the same Project stream.
      -- Re-recording a version is already safe -- the first committed release
      -- time and source win -- so this is about avoiding contention, not
      -- correctness.
      queued = True
    , execution = Schema.ExecutionPolicy::{ allowLocal = True }
    }
