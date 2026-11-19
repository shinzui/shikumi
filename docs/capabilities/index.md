---
okf_version: "0.2"
---

# Files

- [profile.dhall](profile.dhall)

# Capability

- [Acknowledged provider attempt evidence](acknowledged-attempt-evidence.md) - Handle exact provider-built evidence before retries, classified failures or successful return through an effectful observer.
- [Atomic structured stream replay](atomic-structured-replay.md) - Capture structured stream responses and replay them offline through either complete or stream operations without fresh provider evidence.
- [Budgeted program optimization](budgeted-program-optimization.md) - Search a Program's instructions, demonstrations, neighbors, and ensembles with multiple optimizers that score typed datasets and stop with the best-so-far candidate at an LM-call budget.
- [Built-in filesystem, shell, and web tools](built-in-work-tools.md) - Assemble typed agent tool registries from shipped filesystem, shell, glob, grep, web-fetch, and web-search tools over swappable local and HTTP environments.
- [Schema-enforced structured output on subscription CLIs](cli-schema-enforced-output.md) - Run a typed program on a claude or codex subscription CLI model and have the CLI enforce the output record's derived JSON schema, so nested records and lists of records decode reliably.
- [Composable and rewritable program values](composable-program-values.md) - Represent LM workflows as typed Program values that compose, execute sequentially or concurrently, expose parameters, and serialize their closure-free shape.
- [Content-addressed response caching](content-addressed-response-cache.md) - Interpose a provider-neutral cache over blocking LM completion calls using versioned canonical request keys, TTL policy, and in-memory or SQLite storage.
- [Fail-closed deterministic replay](deterministic-replay.md) - Re-run blocking LM programs offline from captured trace responses, rejecting missing requests and conflicting recordings instead of falling through to a live provider.
- [Failure-aware optimizer feedback](failure-aware-optimizer-feedback.md) - Attribute critiques to the specific program node and invocation that produced a failure, and reflect over bounded, redacted evidence from failed attempts rather than only from scores.
- [Hermetic code-execution modules](hermetic-code-execution.md) - Let a model solve typed tasks through program-of-thought or CodeAct loops using a swappable interpreter whose shipped default is a pure, step-bounded DSL with no host access.
- [Hierarchical, node-correlated tracing](hierarchical-tracing.md) - Capture programs, modules, retries, and LM calls as a hierarchical trace tree with stable program-node paths, persisted JSON, rendering, and per-node feedback.
- [Isolated node observation with rejection lineage](isolated-node-observation.md) - Run a program once and recover structured per-node evidence, including failed attempts and why each rejected output was rejected, isolated from concurrent runs.
- [Typed image input](multimodal-image-input.md) - Place an Image in a typed input record and lower its bytes and MIME type to the provider's native user-image content block without disturbing text-only prompts.
- [Bounded nested XML structured output](nested-xml-decoding.md) - Decode nested XML records and arrays from a model reply into typed values under explicit depth, size, and well-formedness limits, for models that produce XML more reliably than JSON.
- [Node-local bootstrap demonstration pools](node-local-bootstrap-pools.md) - Recover and validate few-shot demonstrations per predictor node in a composite program, with explicit teacher-to-student mapping, per-node caps, and independent seeded selection.
- [Offline-capable evaluation, trace, optimize, and replay CLI](offline-cli-workflows.md) - Register typed tasks and expose deterministic eval, trace, optimization, trace recording, and replay workflows through one command-line interface.
- [OKF program and application documentation generation](okf-program-documentation.md) - Generate deterministic OKF v0.2 bundles that document typed shikumi programs, their fields, structure, parameters, model-call instructions, and containing applications.
- [OpenTelemetry trace export](opentelemetry-export.md) - Export completed or live shikumi trace trees as nested OpenTelemetry spans with GenAI-oriented attributes, error status, and bracketed provider cleanup.
- [Persistent decision calibration settings](persistent-decision-settings.md) - Persist per-field thresholds, score cuts and choice weights and rederive answers from cached or replayed evidence without changing request identity.
- [PostgreSQL response-cache backend](postgres-cache-backend.md) - Run shikumi's response-cache effect against PostgreSQL with table initialization, connection lifecycle, and best-effort lookup and storage.
- [Probability-backed typed decisions](probability-backed-decisions.md) - Declare closed Boolean, choice and ordered-score outputs, retrieve probability evidence and derive typed answers locally on judgment-only or generative models.
- [Production-evidence optimization and promotion reports](production-evidence-promotion-reports.md) - Optimize a typed program on a sealed dataset of production evidence and receive a digested candidate plus a baseline-versus-candidate report, decided on a protected holdout as Improved, Regressed, Inconclusive or Invalid and reproducible by replay.
- [Pure program compilation and shape-safe state](pure-program-compilation.md) - Transform typed Programs into zero-shot, few-shot, chain-of-thought, or retrieval-augmented variants and persist compiled parameters with a structural shape fingerprint.
- [Native and prompt-protocol ReAct agents](react-agents.md) - Compose a tool-using ReAct loop as a typed Program with native or prompt action protocols, recorded trajectories, iteration limits, and context compaction.
- [ReAnchor decision calibration](reanchor-decision-calibration.md) - Fit persistent decision thresholds, cuts and weights through budgeted response replay, retaining only strict improvements accepted by held-out folds.
- [Reasoning continuation guards](reasoning-continuation-guards.md) - Reject resumed language-model calls whose reasoning prefix or request origin does not match the session being continued, before the request reaches a cache or a provider.
- [Bounded recursive language-model sessions](recursive-language-model-sessions.md) - Let a model work over documents that stay outside its prompt, inspecting them through bounded data operations and depth-one subqueries under explicit operation, character, and subquery budgets.
- [Redis response-cache backend](redis-cache-backend.md) - Run shikumi's response-cache effect against Redis with connection lifecycle helpers, optional Redis-side TTL, and best-effort failure behavior.
- [Ambient routing and resilient runtime policies](resilient-runtime-routing.md) - Install an effectful LM runtime that supplies ambient models and applies retry, rate-limit, budget, and error-normalization policies beneath unchanged Program values.
- [Resumable ReAct sessions with versioned checkpoints](resumable-react-sessions.md) - Drive a ReAct agent as an explicit session value that can be checkpointed to JSON, restored in a later process, compacted, and continued without losing completed tool exchanges or native call identity.
- [Reward-driven inference-time self-refinement](reward-driven-self-refinement.md) - Wrap a typed Program with best-of-N sampling, critique-and-retry refinement, or multi-chain synthesis driven by an explicit reward function.
- [Rich tool outputs and runtime tool registration](rich-tool-outputs.md) - Return structured content and extension blocks from a tool alongside its text projection, and register tools whose argument schema is only known at runtime.
- [Invocation-scoped request defaults](scoped-request-defaults.md) - Apply fill-only thinking, speed, token, and evidence defaults across every language-model call in a scope, without overriding options a call already set.
- [Shape-guided fallback prompts](shape-guided-fallback-prompts.md) - Show models without schema enforcement the JSON shape of every structured output field, including nested keys and closed enum values, in the marker-based fallback prompt.
- [Streamed judgment result parity](streamed-judgment-parity.md) - Run typed judgments in complete and stream modes with identical immutable settings, raw answers and locally derived rich results.
- [Structure search over finite recipe registries](structure-search.md) - Select among a declared set of alternative typed program implementations by validation score, using the same operation admission, objectives, and shared budget as parameter optimization.
- [Provider-aware structured-output adapters](structured-output-adapters.md) - Render one typed signature through native JSON-schema, marker-based prompt fallback, or opt-in XML wire formats and decode every path through the same typed contract.
- [Per-attempt transport billing observation](transport-billing-observation.md) - Observe every provider attempt made by a program run and collect exact per-attempt cost and token accounting separately from logical usage, without exposing prompts, outputs, or credentials.
- [Typed evaluation and reporting](typed-evaluation.md) - Evaluate a typed Program over typed datasets with pure or model-backed metrics, bounded concurrency, per-example timeouts, usage accounting, reports, and golden-test helpers.
- [Opt-in typed prediction capture](typed-prediction-capture.md) - Mark individual prediction nodes to retain their typed input and output alongside derived schemas, so downstream tooling can recover per-node examples that ordinary prediction erases.
- [Typed signatures, schemas, and total decoding](typed-signatures-and-schemas.md) - Derive a model task's prompt contract, strict JSON Schema, typed decoder, and domain validation from ordinary Haskell record types.
- [Program-level typed streaming](typed-streaming.md) - Observe ordered field chunks and node, tool, and LM status events while a Program executes, then receive the same fully decoded typed result as the blocking path.
- [Typed program structure registries](typed-structure-registries.md) - Declare a finite, validated registry of alternative typed program implementations sharing one input and output schema, and serialize a selection as a versioned artifact that restores to the same program.
- [Typed tool contracts and registry](typed-tools.md) - Derive provider-visible JSON argument contracts for typed Haskell tools and dispatch calls totally through a heterogeneous registry with structured errors.
- [Validated optimizer execution and lifecycle reports](validated-gepa-execution.md) - Run optimizer candidates under a shared, validated execution budget that admits only real language-model operations, and read back versioned diagnostic reports of what each candidate cost and why it was accepted or rejected.
