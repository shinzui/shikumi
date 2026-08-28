-- Tell downstream consumers that shinzui/shikumi has released -- once per
-- release, rather than once per tag.
--
-- This is the second hop of the baikai -> shikumi -> kioku cascade. It fires on
-- the release FACT rather than on a successful upgrade, which is the difference
-- that makes the chain correct: kioku does not need to know that Shikumi
-- committed a bounds bump, it needs a Shikumi on Hackage that admits the new
-- baikai, and only a release says that.
let Schema =
      https://raw.githubusercontent.com/shinzui/mori-schema/9899d4544790da7120e8150c73e56cb53fe35191/package.dhall
        sha256:4024df757a0178e37fb0b5f04d7deb284dc3ee9bfea89a6610b793338101e284

in  Schema.Automation::{
    , events =
      [ Schema.EventSelector.ProjectSelector Schema.ProjectSelector::{
        , name = "shikumi-release-fact"
        , aggregates = [ Schema.ProjectSignalAggregate.ProjectRoot ]
        , families = [ Schema.ProjectSignalFamily.Release ]
        , actions = [ Schema.ProjectSignalAction.Added ]
        ,
          -- Project facts are evaluated against every registered automation in
          -- the registry, not only against the project the fact is about.
          -- Without this the reaction would announce every other project's
          -- releases as shikumi's.
          references = [ "mori://shinzui/shikumi" ]
        }
      ]
    , reactions =
      [ Schema.Reaction::{
        , name = "announce-shikumi-release"
        , on = [ "shikumi-release-fact" ]
        , actions =
          [ Schema.ReactionAction.Signal Schema.SignalAction::{
            , signalType = "ShikumiReleased"
            ,
              -- Six projects depend on shikumi; only kioku has a reaction that
              -- consumes ShikumiReleased. `*dependents*` would resolve all six,
              -- and a target with no registered automation dead-letters its
              -- delivery. Name the consumer, and add the next one when it has a
              -- reaction ready to receive this.
              targets = [ "shinzui/kioku" ]
            ,
              -- Assembled from the three release scalars rather than the
              -- whole-value {{release.payloadJson}} that mori's own help
              -- documents: validateSignalAction JSON-decodes this field when
              -- the config loads, before any template is expanded, so a bare
              -- placeholder always fails as malformed JSON.
              payloadJson = Some
                ''
                { "version": "{{release.version}}"
                , "released_at": "{{release.releasedAt}}"
                , "source": "{{release.source}}"
                }
                ''
            }
          ]
        }
      ]
    , execution = Schema.ExecutionPolicy::{ allowLocal = True }
    }
