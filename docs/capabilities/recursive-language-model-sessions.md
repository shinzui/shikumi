---
title: "Bounded recursive language-model sessions"
type: Capability
description: "Let a model work over documents that stay outside its prompt, inspecting them through bounded data operations and depth-one subqueries under explicit operation, character, and subquery budgets."
generated:
  by: claude/opus-5
  at: "2026-09-08T19:15:51Z"
capabilityId: CAP-30
provider: mori://shinzui/shikumi
status: shipped
stability: experimental
since: "0.4.0.0"
packages:
  - shikumi-tools
interface:
  - Shikumi.CodeExec.RLM
  - Shikumi.CodeExec.Session
requires:
  - CAP-19
evidence:
  - kind: test
    resource: shikumi-tools/test/RLMSpec.hs
    proves: Outer iterations, subquery attempts, observed characters, and operation counts are bounded, and exceeding a budget terminates with a reported session limit rather than an unbounded loop.
  - kind: test
    resource: shikumi-tools/test/SessionSpec.hs
    proves: Session actions parse under size limits, observations truncate with explicit offsets, and invalid configurations are rejected before any model call.
  - kind: example
    resource: shikumi-tools/test/RLMExample.hs
    proves: A runnable session answers a question over a stored document that never enters the top-level prompt.
  - kind: guide
    resource: docs/user/recursive-language-model-sessions.md
    proves: Documents the context store, the action grammar, every budget, and the reported outcome and audit trail.
---

# Bounded recursive language-model sessions

A recursive language-model session inverts the usual arrangement: documents are
placed in a `ContextStore` and stay *out* of the prompt until the model
explicitly inspects them. The model issues data operations — slicing, scanning,
searching, binding variables — and receives bounded observations back. It may
also issue subqueries, which recurse to depth one and no further.

Every dimension is budgeted and validated up front:
`validateSessionConfig` rejects an inconsistent configuration before any model
call, and the session tracks operation count, subquery attempts, and total
observed characters against explicit ceilings. Exhausting a budget produces a
reported `SessionLimit` and a terminated session, never an unbounded loop.
`rlmWithReport` returns the outcome together with an audit trail of what was
inspected and where truncation occurred.

This extends [CAP-19 hermetic code-execution modules](hermetic-code-execution.md)
and shares its posture: the operations are invocation-local data manipulation
with **no host execution capability** — no filesystem, no process, no network.

## Limits

- Experimental, and the narrowest of the code-execution surfaces. Actions are
  data operations over the supplied store, not code the host runs.
- Subquery recursion is depth one by construction. There is no arbitrary-depth
  recursion.
- Observations truncate. A model can be told a document is longer than what it
  was shown, but it cannot exceed the observed-character budget to see the rest.
- Budgets bound work, not quality. A session can exhaust its budget without
  reaching an answer; the outcome reports that rather than fabricating one.
