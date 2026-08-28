-- Move Shikumi onto a new Baikai cohort when baikai releases.
--
-- Registered as its own named automation (`--name upgrade`) because it is the
-- only rule here that runs a build: the reaction can hold a worker for up to
-- three hours, and neither recording nor announcing a Shikumi release should be
-- able to queue behind it.
--
-- No `consent` is declared. Consent reads as per-automation but
-- checkTargetConsent requires EVERY registration on the repository to allow the
-- source, so a list here would silently govern deliveries meant for
-- automation/release.dhall and automation/announce.dhall too.
let Schema =
      https://raw.githubusercontent.com/shinzui/mori-schema/9899d4544790da7120e8150c73e56cb53fe35191/package.dhall
        sha256:4024df757a0178e37fb0b5f04d7deb284dc3ee9bfea89a6610b793338101e284

in  Schema.Automation::{
    , events =
      [ Schema.EventSelector.SignalSelector Schema.SignalSelector::{
        , name = "baikai-released"
        , signalTypes = [ "BaikaiReleased" ]
        , sourceProjects = [ "shinzui/baikai" ]
        }
      ]
    , reactions =
      [ Schema.Reaction::{
        , name = "upgrade-baikai-cohort"
        , on = [ "baikai-released" ]
        , actions =
          [ Schema.ReactionAction.RunCommand Schema.RunCommandAction::{
            , command = "./scripts/upgrade-baikai.sh"
            ,
              -- A cold cohort bump rebuilds baikai and its dependencies before
              -- Shikumi's own thirteen packages start.
              timeout = Some +10800
            ,
              -- No env, and deliberately no {{signal.*}} or {{meta.*}}
              -- templates. The script re-derives the whole cohort from Hackage,
              -- which is the only source that can answer correctly twelve hours
              -- after the release anyway.
              env = [] : List { mapKey : Text, mapValue : Text }
            }
          ]
        , schedule = Some Schema.Schedule::{
          ,
            -- Baikai's release fact is recorded from the umbrella tag, and the
            -- seven packages of that cut reach Hackage as seven separate
            -- uploads. Waiting the working day out beats waking into a cohort
            -- the solver cannot yet satisfy.
            --
            -- Twelve hours rather than four because a skip is TERMINAL: if the
            -- idempotency check refuses, nothing re-arms this reaction until the
            -- next baikai release. Waiting too long costs a day; waking too
            -- early costs the whole release.
            after = Some "PT12H"
          ,
            -- Harmless today -- one release fact means one signal -- but kept so
            -- that a re-recorded or retried delivery debounces into one run
            -- rather than starting a second three-hour build.
            coalesceKey = Some "baikai-cohort-bump"
          , idempotencyCheck = Some Schema.IdempotencyCheck::{
            , command = "./scripts/baikai-bump-needed.sh"
            ,
              -- Asked twelve hours after the release, not at trigger time: by
              -- then the cohort may be complete, already bumped by hand, or the
              -- tree may be mid-work. Non-zero means skip, and skipping is the
              -- ordinary outcome rather than a fault.
              skipOnExit = Schema.SkipOnExit.NonZero
            , timeout = Some +120
            }
          }
        }
      ]
    , execution = Schema.ExecutionPolicy::{ allowLocal = True }
    }
