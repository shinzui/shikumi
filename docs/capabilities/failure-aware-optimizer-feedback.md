---
title: "Failure-aware optimizer feedback"
type: Capability
description: "Attribute critiques to the specific program node and invocation that produced a failure, and reflect over bounded, redacted evidence from failed attempts rather than only from scores."
generated:
  by: claude/opus-5
  at: "2026-09-08T19:15:51Z"
capabilityId: CAP-35
provider: mori://shinzui/shikumi
status: shipped
stability: experimental
since: "0.3.0.0"
packages:
  - shikumi-optimize
interface:
  - Shikumi.Optimize.Feedback
requires:
  - CAP-16
  - CAP-32
evidence:
  - kind: test
    resource: shikumi-optimize/test/FeedbackSpec.hs
    proves: Failed examples retain their positions, node critiques target the invocation that executed, reflection uses redacted intermediate evidence, typed error classification separates scored output failures from escaping infrastructure errors, and cancellation escapes.
  - kind: guide
    resource: docs/user/evaluation-and-optimization.md
    proves: Documents indexed feedback, node attribution, the reflection bounds, and which failures are scored rather than raised.
---

# Failure-aware optimizer feedback

A score tells an optimizer that a candidate did badly. It does not say which node
failed, on which example, or how — and a reflective optimizer that only sees
scores has to guess. This capability gives GEPA-style reflection indexed,
attributed evidence instead.

Failed examples keep their positions, so feedback can be tied back to the exact
input that produced it. Critiques are attributed to the node *and invocation*
that actually executed, rather than broadcast to every node in the program;
legacy critiques are now explicitly labeled program-scoped so the two are never
confused. Reflection retains failed retry lineage, including for nodes without
JSON codecs.

Error handling is typed and deliberate: output failures are scored by default,
because a malformed answer is genuine evidence about a candidate, while budget
exhaustion and infrastructure errors escape rather than being scored as bad
candidates — unless a caller explicitly classifies them otherwise.

Evidence supplied to reflection is bounded and redacted locally, so enabling
failure-aware feedback does not turn an optimizer log into an unbounded copy of
the training data.

This is growth of
[CAP-16 budgeted program optimization](budgeted-program-optimization.md), and it
consumes the per-node rejection lineage from
[CAP-32 isolated node observation with rejection lineage](isolated-node-observation.md).

## Limits

- Attribution requires an executed invocation. A node that never ran produces no
  attributed critique.
- Redaction bounds what reflection sees; a failure whose cause lies in redacted
  detail may still be opaque to the optimizer.
- Legacy program-scoped critiques remain supported and remain program-scoped;
  they are not retroactively attributed to nodes.
- Feedback improves the search signal. It does not make an under-specified
  metric into a good objective.
