---
type: Improvement Request
title: Enforce typed output schemas on CLI providers
description: >-
  Route programs on CLI providers that can enforce a JSON schema through the native-schema adapter,
  and make the prompt fallback describe nested output shapes, so typed programs with lists of
  records decode reliably on subscription CLIs.
timestamp: 2026-09-30T17:00:00Z
generated:
  by: agent:anthropic/claude-opus-5-5
  at: "2026-09-30T00:00:00Z"
requestId: IR-4
status: completed
completedAt: "2026-09-30T17:00:00Z"
resolution: >-
  Implemented by docs/plans/67-enforce-typed-output-schemas-on-cli-providers.md and released as
  shikumi 0.4.1.0 and shikumi-tools 0.4.1.0. capabilityFor derives native-schema routing from
  Baikai's declaredStructuredOutput, so the claude and codex CLI transports are native, while
  third-party and Custom hosts stay on the fallback. The fallback guide renders JSON shapes for
  object and array fields. ReAct's tool-protocol choice keeps its own table because Baikai's
  CLI providers drop tools (ADR-14).
origin: mori://shinzui/mina
targetPlan: mori://shinzui/mina/plans/240-evaluate-plan-judgment-quality-and-verify-the-complete-workflow
dependencies:
  - ref: mori://shinzui/baikai/okf/improvement-requests/concepts/IR-11
    kind: hard
    reason: "Baikai's CLI providers must pass the schema to the CLI and advertise the capability before Shikumi can route to the native adapter."
---

# Improvement Request: Enforce Typed Output Schemas on CLI Providers

## Status

Completed on 2026-09-30 by
[docs/plans/67-enforce-typed-output-schemas-on-cli-providers.md](../plans/67-enforce-typed-output-schemas-on-cli-providers.md)
and released as `shikumi 0.4.1.0` and `shikumi-tools 0.4.1.0`. Evidence per criterion:

1. `capabilityFor` derives capability from Baikai's `declaredStructuredOutput`.
   `AnthropicMessagesCli` and `OpenAICompletionsCli` are `NativeSchema`; `Custom` hosts and
   third-party hosts over Chat Completions (`deepseek`, `openrouter`) stay `PromptFallback`
   (`shikumi/test/AdapterSpec.hs`). `shikumi/test/CliSchemaSpec.hs` asserts that a routed CLI
   request carries `responseFormat = JsonSchema "output"` (strict) with the derived schema.
   Baikai's HTTP tags keep their first-party provider guard, because Baikai cannot know whether
   a third-party host enforces the schema it forwards.
2. `CliSchemaSpec` runs a typed program whose output is a list of `Concern` records with a
   `Severity` enum. It decodes through a scripted provider under both CLI tags that returns
   conforming JSON only when given a schema. Registered under a `Custom` tag, the same provider
   fails with `expected object, got string`.
3. `shikumi/test/FallbackGuideSpec.hs` pins the full fallback system prompt, including
   `JSON shape: [{"statement": string, "severity": "Blocker" | "Major" | "Minor"}, ...]`.
   The pin is an inline expected text rather than a golden file.
4. The existing `capabilityFor` HTTP cases and `ResponsesSpec` pass unedited. A scalar-only
   prompt pin written from the pre-change code passes unchanged. ReAct's `ProtocolAuto` keeps
   CLI models on the prompt tool protocol through its own check (`shikumi-tools/test/ProtocolSpec.hs`),
   because Baikai's CLI providers still drop tools.
5. `shikumi-0.4.1.0` on Hackage requires `baikai >=0.7.2.0`, `baikai-claude >=0.7.1.0` and
   `baikai-openai >=0.7.1.0`, which is the cohort that implements
   `mori://shinzui/baikai/okf/improvement-requests/concepts/IR-11`. The workspace built and
   tested against Hackage alone before upload. Tags: `shikumi-0.4.1.0`, `shikumi-tools-0.4.1.0`.

## Context

`Shikumi.Adapter.capabilityFor` (unchanged in substance from `shikumi-0.3.0.3` through
`shikumi-0.4.0.0` and master `99106ac`) returns `NativeSchema` only for the OpenAI Chat Completions
and Responses APIs and the Anthropic Messages API; every CLI model gets `PromptFallback`. The
fallback guide (`fallbackOutputGuide`) lists one `[[ ## field ## ]]` section per output field with
its description only, so a field typed as a list of records gives the model no object shape.

In Mina's bounded live evaluation of its plan-assessment judges through `codex-cli`
(gpt-5.6-luna), 43 of 62 judge runs failed to decode because the model wrote arrays of strings
where arrays of objects were required (`expected object, got string`, `MissingField
"behaviors.[0].statement"`). Mina is working around it by writing each object's keys into field
descriptions, which is prompting, not enforcement, and every typed consumer would have to repeat
it.

## Requested Change

Decide capability from Baikai's structured-output signal (IR-11) rather than a fixed
provider/API table, so a CLI model that can enforce a schema uses the native adapter and gets the
derived schema as its response format. Independently, make the fallback output guide render the
expected shape of any non-scalar field — the element object's keys and closed enum values, as a
compact JSON example or schema — so models on true fallback paths see what to write.

## Acceptance

1. With a Baikai model advertising native structured output, `adapterFor` selects the native
   adapter and the request carries the derived schema; without it, behavior is unchanged.
2. A program whose output has a list of records with enum fields decodes through a scripted CLI
   provider that enforces the schema.
3. The fallback guide for such a program shows each nested field's keys and enum values; a golden
   test pins the rendered guide.
4. Existing native API routing and scalar-only fallback prompts are unchanged.
5. Released in a tagged version bounded to the Baikai release that implements IR-11.

## Requested Deliverables

- Capability-driven adapter selection.
- Nested-shape rendering in the fallback output guide.
- Tests (routing, decode through a schema-enforcing stub, golden fallback guide) and a release.
