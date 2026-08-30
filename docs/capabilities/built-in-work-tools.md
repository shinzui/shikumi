---
title: "Built-in filesystem, shell, and web tools"
type: Capability
description: "Assemble typed agent tool registries from shipped filesystem, shell, glob, grep, web-fetch, and web-search tools over swappable local and HTTP environments."
generated:
  by: codex/gpt-5
  at: "2026-08-30T20:48:38Z"
capabilityId: CAP-20
provider: mori://shinzui/shikumi
status: shipped
stability: experimental
since: "0.2.0.0"
packages:
  - shikumi-tools
interface:
  - Shikumi.Tool.Builtin
  - Shikumi.Tool.Builtin.Fs
  - Shikumi.Tool.Builtin.Shell
  - Shikumi.Tool.Builtin.Web
  - Shikumi.Tool.Env
  - Shikumi.Tool.Web
requires:
  - CAP-17
evidence:
  - kind: test
    resource: shikumi-tools/test/BuiltinAcceptanceSpec.hs
    proves: The assembled built-in registry performs representative filesystem, search, shell, and web operations through its public tool contracts.
  - kind: test
    resource: shikumi-tools/test/FsSpec.hs
    proves: Filesystem edits, reads, directory listing, symlink reporting, glob, and grep behavior are exercised in temporary roots.
  - kind: test
    resource: shikumi-tools/test/WebSpec.hs
    proves: Web tools handle statuses, configurable search, private-target refusal, and capped streaming response reads.
  - kind: test
    resource: shikumi-tools/test/ShellSpec.hs
    proves: Shell execution captures output and enforces clamped timeouts through the tool environment.
---

# Built-in filesystem, shell, and web tools

The `shikumi-tools` package includes ready-made typed tools for reading, writing,
editing, listing, globbing and grepping files; running shell commands; and
fetching or searching the web. `ToolEnv` and `WebClient` keep filesystem,
process, and HTTP behavior behind swappable values so an application can replace
the local implementations with restricted or recording versions.

These tools plug into the [CAP-17 typed tool registry](typed-tools.md) and can be
given to [CAP-18 ReAct agents](react-agents.md).

## Limits

- `localToolEnv` is not a sandbox. It uses the current process's filesystem and
  command privileges; a restrictive deployment must supply a safer environment.
- The default fetch policy blocks obvious literal local/private targets and caps
  responses, but it does not resolve DNS to detect a private address hidden
  behind a hostname.
- `web_search` needs an application-supplied search implementation; the package
  does not bundle a search-service credential or provider.
