---
okf_version: "0.2"
---

# Files

- [profile.dhall](profile.dhall)

# Improvement Request

- [Expose acknowledged evidence for every resilient LLM attempt](expose-acknowledged-evidence-for-resilient-llm-attempts.md) - Add a released, call-scoped Shikumi seam that supplies fresh Baikai evidence provenance and acknowledges every provider attempt before retrying or returning.
- [Enforce typed output schemas on CLI providers](enforce-typed-output-schemas-on-cli-providers.md) - Route programs on CLI providers that can enforce a JSON schema through the native-schema adapter, and make the prompt fallback describe nested output shapes.
- [Add production-evidence optimization and promotion reports to Shikumi](production-evidence-optimization.md) - Produce sealed evidence datasets and auditable candidate-versus-baseline promotion reports.
- [Ship the MCP-to-ToolRegistry adapter](ship-the-mcp-to-tool-registry-adapter.md) - Implement and release Shikumi's planned dynamic-tool adapter so Baikai MCP tools enter the same bounded ToolRegistry and ReAct dispatch path as native tools.
