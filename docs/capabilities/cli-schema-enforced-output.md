---
title: "Schema-enforced structured output on subscription CLIs"
type: Capability
description: "Run a typed program on a claude or codex subscription CLI model and have the CLI enforce the output record's derived JSON schema, so nested records and lists of records decode reliably."
generated:
  by: claude/opus-5-5
  at: "2026-09-30T17:30:00Z"
capabilityId: CAP-37
provider: mori://shinzui/shikumi
status: shipped
stability: experimental
since: "0.4.1.0"
packages:
  - shikumi
interface:
  - Shikumi.Adapter.capabilityFor
  - Shikumi.Routing.routeLLM
requires:
  - CAP-3
evidence:
  - kind: test
    resource: shikumi/test/CliSchemaSpec.hs
    proves: Programs on AnthropicMessagesCli and OpenAICompletionsCli models are routed with the strict derived schema and decode a list of records with an enum field; the same provider under a Custom tag gets no schema and fails with "expected object, got string".
  - kind: test
    resource: shikumi/test/AdapterSpec.hs
    proves: capabilityFor is NativeSchema for both CLI transports and the first-party HTTP hosts, and PromptFallback for Custom hosts and third-party hosts over Chat Completions.
  - kind: guide
    resource: docs/user/signatures-and-schemas.md
    proves: Documents which transports take the native path and why third-party hosts stay on the fallback.
---

# Schema-enforced structured output on subscription CLIs

Models reached through Baikai's `claude-cli` (`AnthropicMessagesCli`) and
`codex-cli` (`OpenAICompletionsCli`) providers now take the same native path as
the first-party APIs in [CAP-3 provider-aware structured-output
adapters](structured-output-adapters.md). The router attaches the output
record's derived schema as a strict `JsonSchema "output"` response format and
swaps in the native JSON prompt. Baikai forwards the schema as `claude -p
--json-schema` or `codex exec --output-schema`, and the CLI enforces it. No
program or type changes are needed; selecting a CLI model is enough.

`capabilityFor` derives this from Baikai's `declaredStructuredOutput`, so it
follows Baikai's per-transport declaration rather than a hand-kept table.

## Limits

- Requires `baikai >=0.7.2.0` and `baikai-claude`/`baikai-openai >=0.7.1.0`, and an
  installed CLI new enough to accept the schema flag. An older CLI fails the call
  with a terminal `ProviderError` rather than replying unconstrained.
- Third-party hosts that speak a first-party wire format (for example `deepseek`
  or `openrouter` over Chat Completions) and `Custom` transports stay on the
  prompt fallback. Shikumi does not consult a provider registry's declared
  support.
- Schema enforcement is not tool calling. ReAct agents on CLI models still use the
  prompt tool protocol, because the CLI providers drop tools.
- The optional live check against a logged-in CLI is not part of the hermetic
  evidence; the tests use a scripted provider.
