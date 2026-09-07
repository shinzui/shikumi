-- | The shared offline harness for the @shikumi-jitsurei@ examples — now a
-- thin re-export of the repo-wide harness in @shikumi-testing@
-- ("Shikumi.Testing"), kept so every example's import line still works.
module Shikumi.Jitsurei.Stub
  ( -- * Building stub responses
    markerResponse,
    mkTextResponse,
    mkToolCallResponse,

    -- * Running a program offline
    runStub,
    runStubEval,
    runStubLLM,

    -- * Running an agent against a scripted LM
    runAgent,
    runScriptLLM,

    -- * Inspecting the request inside a responder
    systemContains,
  )
where

import Shikumi.Testing
  ( markerResponse,
    mkTextResponse,
    mkToolCallResponse,
    runAgent,
    runScriptLLM,
    runStub,
    runStubEval,
    runStubLLM,
    systemContains,
  )
