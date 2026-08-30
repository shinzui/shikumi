---
title: "Hermetic code-execution modules"
type: Capability
description: "Let a model solve typed tasks through program-of-thought or CodeAct loops using a swappable interpreter whose shipped default is a pure, step-bounded DSL with no host access."
generated:
  by: codex/gpt-5
  at: "2026-08-30T20:48:38Z"
capabilityId: CAP-19
provider: mori://shinzui/shikumi
status: shipped
stability: experimental
since: "0.1.0.0"
packages:
  - shikumi-tools
interface:
  - Shikumi.CodeExec.ProgramOfThought
  - Shikumi.CodeExec.CodeAct
  - Shikumi.CodeExec.Interpreter
requires:
  - CAP-2
  - CAP-4
  - CAP-17
evidence:
  - kind: test
    resource: shikumi-tools/test/ProgramOfThoughtSpec.hs
    proves: Program-of-thought runs code to improve a typed answer, feeds interpreter errors back for correction, and respects interpreter failure.
  - kind: test
    resource: shikumi-tools/test/CodeActSpec.hs
    proves: CodeAct evaluates restricted snippets, dispatches explicit typed tool calls, records trajectories, and terminates safely.
  - kind: test
    resource: shikumi-tools/test/RestrictedSpec.hs
    proves: The default DSL evaluates its supported arithmetic, string, and list forms while rejecting invalid programs and enforcing its step cap.
  - kind: example
    resource: shikumi-jitsurei/app/CodeExec.hs
    proves: Both modules run offline, including error-then-fix recovery and a CodeAct tool call.
---

# Hermetic code-execution modules

`programOfThought` asks a model to produce a computation, evaluates it, feeds
recoverable errors back for correction, and decodes the successful result into a
typed answer. `codeAct` combines code actions, explicit typed tool calls, and a
trajectory. Both are [CAP-2 composable program
nodes](composable-program-values.md), run model calls under the [CAP-4
runtime](resilient-runtime-routing.md), and reuse the [CAP-17 typed tool
foundation](typed-tools.md).

The default `restrictedInterpreter` is a pure arithmetic/string/list DSL with a
step cap and no filesystem, process, or network access. `CodeInterpreter` is a
plain swappable value, so tests and constrained applications can replace it
without changing the loop.

## Limits

- No general Python, JavaScript, or subprocess sandbox ships on the composable
  program path. Arbitrary model-emitted host code is deliberately out of scope.
- The restricted DSL is demonstrative, not a general-purpose language.
- In CodeAct, tool invocation is a recognized `call("name", args)` protocol
  form; the DSL itself does not gain ambient host functions.
