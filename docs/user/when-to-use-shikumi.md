# When to use shikumi

Use Shikumi when model calls are part of a program you want to compose, evaluate,
inspect, or improve. A direct provider call remains a good fit for a small script
or a free-form response with no additional runtime or evaluation requirements.

## The two layers

Baikai (`mori://shinzui/baikai`) owns provider transport: models, contexts, options,
responses, structured-output wire formats, streaming, and provider error and usage
information. Shikumi builds typed signatures, programs, decisions, agents,
resilience, caching, tracing, evaluation, and optimization above that transport.

Baikai's user documentation starts at
`mori://shinzui/baikai/docs/getting-started`.

## Choose by what you need

| Requirement | Starting point |
|---|---|
| Send a prompt and receive prose | Direct Baikai call |
| Consume raw provider stream events | Baikai's transport stream |
| Receive a record derived from a Haskell schema | Shikumi `predict` |
| Compose stages with checked intermediate types | Shikumi `Program` and combinators |
| Stream program progress and receive a final typed result | Shikumi `streamProgram` |
| Use schema-enforced output through subscription CLIs | Shikumi native adapter over Baikai's CLI providers |
| Add retries, budgets, caching, tracing, or replay | Shikumi runtime interpreters |
| Tune instructions, demonstrations, or decision settings against data | Shikumi evaluation and optimizers |
| Compare declared program structures | Shikumi structure registry and structure search |
| Save and continue a tool-using conversation | Shikumi ReAct session API |
| Inspect large documents through bounded operations and subqueries | Shikumi's experimental recursive sessions |
| Use a provider feature without a Shikumi abstraction | Baikai directly, or its options through the runtime where supported |

Shikumi supports both streaming and subscription CLI providers. Field chunks are
available on supported prediction paths; composite and opaque nodes emit status
events. Decision outputs currently require blocking prediction. Schema support
and native tool calling are separate capabilities: CLI schema enforcement does
not imply native tool support.

See [runtime streaming](effects-and-runtime.md#streaming),
[adapters](signatures-and-schemas.md#the-adapter-seam-native-schema-vs-prompt-fallback),
and [resumable sessions](resumable-react-sessions.md).

## Jev directly or Shikumi decisions?

Jev already supplies probability-backed typed judgments. Shikumi does not improve
the underlying model merely by wrapping a call. If you need a few decisions and
will manage thresholds and evaluation yourself, a direct API call can be enough.

Shikumi earns its place when those judgments participate in a larger application:

- Derive closed decision contracts from `Noul`, `Choice`, and `Score` fields and
  compose their typed results with other program stages.
- Keep probability evidence while applying thresholds, score cuts, and choice
  weights locally. Reuse matching cached or replayed responses when settings change.
- Fit decision settings with ReAnchor against a task metric, retaining strict
  improvements that pass held-out fold checks.
- Run the same decision contract on judgment-only or generative backends, with
  common evaluation, routing, traces, and budgets.

You could build these facilities around a direct API. Shikumi supplies their
shared execution and persistence model. Generative models' reported probabilities
need evaluation on your task; the common contract does not establish equal
calibration across models. See [decisions and calibration](decisions-and-calibration.md).

## Keep the program's boundaries in view

A `Program i o` describes the typed contract; the runner and interpreters describe
execution capabilities. An `Embed` node can run custom work using the `LLM` and
`Error ShikumiError` effects, but its body is opaque to parameter search and cannot
request arbitrary `IOE`. Put host I/O in the appropriate runtime or tool boundary.

ReAct loops and CodeAct loops compose as opaque embedded nodes. Their internal
steps are observable through agent trajectories and runtime tracing, but parameter
traversal cannot tune predictors hidden inside those closures. Resumable sessions
are an explicit API and can be wrapped in `embed` when a program is needed.

The layers can coexist: stream free-form chat through Baikai and invoke a Shikumi
program for extraction, decisions, or evaluation when the application needs them.
