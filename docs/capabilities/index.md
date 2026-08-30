---
okf_version: "0.2"
---

# Files

- [profile.dhall](profile.dhall)

# What shikumi provides today

Shikumi is a Haskell framework for expressing language-model work as typed,
inspectable programs. A consumer can derive provider contracts from ordinary
record types, compose and run programs, then add caching, tracing, replay,
evaluation, compilation, optimization, tools, agents, and documentation without
changing the program's input and output types.

Every capability below is shipped today and backed by repository evidence a
reader can open. The catalog deliberately describes provision, not roadmap:
planned work remains in improvement requests and execution plans.

**Stability is uniformly experimental.** The packages are pre-1.0 and their
recent changelogs include breaking minor releases. The capabilities are usable
and released, but the project does not yet promise source compatibility across
minor versions. The CLI is implemented and tested in this repository but has
not been published to Hackage, so its `since` value is `unreleased`.

## Deliberately excluded

- `shikumi-jitsurei` is worked-example code used as evidence, not a capability a
  consumer adopts on its own.
- Provider transport implementations belong to `mori://shinzui/baikai`.
  Shikumi provides the
  typed language-programming and runtime layers above that transport.
- Plans and improvement requests are not capabilities. The profile has no
  `planned` status, so absent behavior is not presented as shipped.
- Cache backends that ship in separate packages have separate records; the
  in-memory and SQLite interpreters remain together because they ship with the
  same core cache package and implement the same adoption surface.

# Capabilities

| Handle | Capability | Since | Package |
|---|---|---|---|
| [CAP-1](typed-signatures-and-schemas.md) | Typed signatures, schemas, and total decoding | 0.1.0.0 | shikumi |
| [CAP-2](composable-program-values.md) | Composable and rewritable program values | 0.1.0.0 | shikumi |
| [CAP-3](structured-output-adapters.md) | Provider-aware structured-output adapters | 0.1.0.0 | shikumi |
| [CAP-4](resilient-runtime-routing.md) | Ambient routing and resilient runtime policies | 0.1.0.0 | shikumi |
| [CAP-5](typed-streaming.md) | Program-level typed streaming | 0.1.0.0 | shikumi |
| [CAP-6](multimodal-image-input.md) | Typed image input | 0.1.0.0 | shikumi |
| [CAP-7](reward-driven-self-refinement.md) | Reward-driven inference-time self-refinement | 0.1.0.0 | shikumi |
| [CAP-8](content-addressed-response-cache.md) | Content-addressed response caching | 0.1.0.0 | shikumi-cache |
| [CAP-9](redis-cache-backend.md) | Redis response-cache backend | 0.1.0.0 | shikumi-cache-redis |
| [CAP-10](postgres-cache-backend.md) | PostgreSQL response-cache backend | 0.1.0.0 | shikumi-cache-postgres |
| [CAP-11](hierarchical-tracing.md) | Hierarchical, node-correlated tracing | 0.1.0.0 | shikumi-trace |
| [CAP-12](deterministic-replay.md) | Fail-closed deterministic replay | 0.1.0.0 | shikumi-trace |
| [CAP-13](opentelemetry-export.md) | OpenTelemetry trace export | 0.1.0.0 | shikumi-trace-otel |
| [CAP-14](typed-evaluation.md) | Typed evaluation and reporting | 0.1.0.0 | shikumi-eval |
| [CAP-15](pure-program-compilation.md) | Pure program compilation and shape-safe state | 0.1.0.0 | shikumi-compile |
| [CAP-16](budgeted-program-optimization.md) | Budgeted program optimization | 0.1.0.0 | shikumi-optimize |
| [CAP-17](typed-tools.md) | Typed tool contracts and registry | 0.1.0.0 | shikumi-tools |
| [CAP-18](react-agents.md) | Native and prompt-protocol ReAct agents | 0.1.0.0 | shikumi-tools |
| [CAP-19](hermetic-code-execution.md) | Hermetic code-execution modules | 0.1.0.0 | shikumi-tools |
| [CAP-20](built-in-work-tools.md) | Built-in filesystem, shell, and web tools | 0.2.0.0 | shikumi-tools |
| [CAP-21](offline-cli-workflows.md) | Offline-capable evaluation, trace, optimize, and replay CLI | unreleased | shikumi-cli |
| [CAP-22](okf-program-documentation.md) | OKF program and application documentation generation | 0.1.0.0 | shikumi-okf |
