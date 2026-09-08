---
title: "Resumable ReAct sessions with versioned checkpoints"
type: Capability
description: "Drive a ReAct agent as an explicit session value that can be checkpointed to JSON, restored in a later process, compacted, and continued without losing completed tool exchanges or native call identity."
generated:
  by: claude/opus-5
  at: "2026-09-08T19:15:51Z"
capabilityId: CAP-29
provider: mori://shinzui/shikumi
status: shipped
stability: experimental
since: "0.4.0.0"
packages:
  - shikumi-tools
interface:
  - Shikumi.Agent.History
  - Shikumi.Agent.ReAct
requires:
  - CAP-18
  - CAP-25
evidence:
  - kind: test
    resource: shikumi-tools/test/AgentHistorySpec.hs
    proves: Sessions append completed exchanges, validate tool calls, encode and decode as version-2 checkpoints while still reading version 1, and reject malformed or inconsistent histories.
  - kind: test
    resource: shikumi-tools/test/SessionSpec.hs
    proves: startSession, advanceSession, continueSession and runSession preserve original native call IDs, validate the final submission, and reject a continuation whose origin does not match.
  - kind: example
    resource: shikumi-tools/test/ReActSessionExample.hs
    proves: A runnable end-to-end session starts, checkpoints, restores, and completes against a stub provider.
  - kind: guide
    resource: docs/user/resumable-react-sessions.md
    proves: Documents session construction, checkpoint versioning, compaction safety, and restart-from-summary for consumers.
---

# Resumable ReAct sessions with versioned checkpoints

Where [CAP-18 native and prompt-protocol ReAct agents](react-agents.md) runs an
agent loop to completion inside one call, this capability exposes the loop's
state as an explicit `ReActSession` value. A consumer starts a session, advances
it one exchange at a time, encodes it to JSON, stores it, and continues it in a
different process.

Checkpoints are versioned. This release writes version 2 — the reasoning-safe
format — while still reading version 1, so an existing stored checkpoint keeps
working. A session records *completed exchanges*: an assistant turn together
with the tool outputs answering it, never a half-dispatched turn. Original
native call IDs are preserved across the round trip, which is what lets a
provider match a restored tool result to the call it answered.

Continuation is guarded rather than assumed. Before dispatch, a session whose
origin or prompt prefix does not match is rejected via
[CAP-25 reasoning continuation guards](reasoning-continuation-guards.md), so a
checkpoint captured against one model or prompt cannot be silently resumed
against another. Compaction is likewise explicit: `compactionSafe` reports
whether a session may be compacted, and unsafe compaction is deferred rather
than performed. `restartSessionFromSummary` offers a pure restart when
continuation is not available.

## Limits

- Registries and handler closures stay caller-owned. A checkpoint stores history
  and identity, not the tools; restoring a session means supplying the same
  registry again.
- Compaction is refused, not forced, when reasoning state makes it unsafe. A
  session that cannot be compacted may need a summary restart instead.
- Version 2 is written and versions 1 and 2 are read; older readers cannot read
  a version-2 checkpoint.
- A checkpoint is not provider attestation. Restoring proves the history matches,
  not that the provider still holds any server-side state.
