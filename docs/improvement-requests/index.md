---
okf_version: "0.2"
---

# Files

- [profile.dhall](profile.dhall)

# Improvement Request

- [Enforce typed output schemas on CLI providers](enforce-typed-output-schemas-on-cli-providers.md) - Route programs on CLI providers that can enforce a JSON schema through the native-schema adapter, and make the prompt fallback describe nested output shapes, so typed programs with lists of records decode reliably on subscription CLIs.
- [Expose acknowledged evidence for every resilient LLM attempt](expose-acknowledged-evidence-for-resilient-llm-attempts.md) - Add a released, call-scoped Shikumi seam that supplies fresh Baikai evidence provenance and acknowledges every provider attempt before retrying or returning.
- [Add production-evidence optimization and promotion reports to Shikumi](production-evidence-optimization.md) - Produce sealed evidence datasets and auditable candidate-versus-baseline promotion reports.
- [Ship the MCP-to-ToolRegistry adapter](ship-the-mcp-to-tool-registry-adapter.md) - Implement and release Shikumi's planned dynamic-tool adapter so Baikai MCP tools enter the same bounded ToolRegistry and ReAct dispatch path as native tools.
- [Support streamed judgment programs with typed result parity](support-streamed-judgment-programs-with-typed-result-parity.md) - Support decision outputs through the public streaming runner and router while preserving complete-call derivation settings, structured answers, and acknowledged attempt evidence.
