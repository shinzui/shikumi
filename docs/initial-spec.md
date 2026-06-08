# Haskell LM Programming Framework

## Name

### 仕組み (Shikumi)

**Shikumi (仕組み)** means:

* mechanism
* system
* structure
* arrangement
* how something works internally

It is commonly used in Japanese to describe the underlying system that makes a process work.

Examples:

* 会社の仕組み — how a company is structured
* 経済の仕組み — how an economy works
* 機械の仕組み — how a machine works

### Why This Name

Most LLM frameworks focus on prompts, agents, or workflows.

Shikumi focuses on the system behind them.

The core idea is that LLM applications should not be collections of prompts and ad-hoc glue code. They should be explicit, inspectable, and composable systems.

A Shikumi program is:

* typed
* structured
* evaluable
* reproducible
* optimizable

The name reflects the belief that the future of AI engineering is not prompt engineering—it is building reliable systems whose behavior can be understood, measured, and improved.

### Design Philosophy

> Don't build prompts.
>
> Build systems.

---

## One-Line Pitch

A Haskell-native framework for building typed, evaluable, reproducible, and optimizable language-model programs.


---

# Vision

Most LLM frameworks treat prompts as strings and evaluation as an afterthought.

This framework treats LLM applications as programs:

* Typed inputs
* Typed outputs
* Structured decoding
* Reproducible evaluation
* Automatic optimization
* Production-grade observability

The goal is not to build "DSPy for Haskell."

The goal is to build the framework that naturally emerges when DSPy-style ideas are designed around Haskell's strengths.

---

# Design Principles

## Typed by Default

The primary abstraction should resemble a normal Haskell function:

```haskell
summarize :: Article -> LM Summary
```

The framework should make invalid pipelines difficult to express.

### Structured Outputs First

JSON and schema-based decoding should be the default.

Parsing free-form text should be an escape hatch rather than the primary workflow.

### Evaluation is a First-Class Feature

Every program should be easy to evaluate against datasets.

Optimization should be built on top of evaluation.

### Reproducibility

Every execution should be reproducible through:

* traces
* cached responses
* model versions
* prompt versions
* configuration snapshots

### Production Ready

The runtime should support:

* retries
* streaming
* caching
* tracing
* concurrency
* rate limiting
* budget controls
* deterministic replay

---

# Architecture

```text
                 +------------------+
                 |     Program      |
                 +------------------+
                          |
                          v
                 +------------------+
                 |     Compiler     |
                 +------------------+
                          |
                          v
                 +------------------+
                 |      Runtime     |
                 +------------------+
                          |
         +----------------+----------------+
         |                |                |
         v                v                v
   OpenAI Provider  Anthropic Provider  Ollama Provider

                          |
                          v

                 +------------------+
                 |      Traces       |
                 +------------------+

                          |
                          v

                 +------------------+
                 |    Evaluation     |
                 +------------------+

                          |
                          v

                 +------------------+
                 |    Optimizers     |
                 +------------------+
```

---

# Core Abstractions

## Program

A typed LM-powered function.

```haskell
data Program i o
```

Conceptually:

```haskell
Program Input Output
```

Examples:

```haskell
Program Article Summary

Program Question Answer

Program SupportTicket Classification
```

### Signature

Defines the contract between inputs and outputs.

```haskell
class Signature s where
  type Input s
  type Output s

  instruction :: Proxy s -> Text
```

Example:

```haskell
data Summarize

instance Signature Summarize where
  type Input Summarize = Article
  type Output Summarize = Summary

  instruction _ =
    "Summarize the article clearly and concisely."
```

### Modules

The initial module set:

```haskell
predict
  :: Program i o
  -> i
  -> LM o

chainOfThought
  :: Program i o
  -> i
  -> LM o

react
  :: Tools LM
  -> Program i o
  -> i
  -> LM o
```

Additional modules:

* Retry
* Validate
* Pipeline
* Map
* Parallel
* MajorityVote
* Ensemble

---

# Structured Output System

## Input Rendering

```haskell
class ToPrompt a where
  toPrompt :: a -> Prompt
```

## Output Decoding

```haskell
class FromModel a where
  modelSchema :: Proxy a -> JSONSchema
  parseModel :: Value -> Either ModelError a
```

The preferred workflow is:

```haskell
Article
  -> LM Summary
```

rather than:

```haskell
Text
  -> IO Text
```

## Validation Failures

Failures should be explicit:

* Invalid JSON
* Missing fields
* Schema mismatch
* Validation failure
* Provider failure
* Timeout
* Budget exceeded

---

# Runtime

## Provider Abstraction

```haskell
class Monad m => MonadLLM m where
  complete
    :: CompletionRequest
    -> m CompletionResponse
```

Initial providers:

* OpenAI
* Anthropic
* Gemini
* Ollama

Features:

* structured outputs
* streaming
* tool calling
* retries
* rate limiting

---

# Effects

The framework should integrate naturally with Effectful.

Example:

```haskell
type AppEffects =
  [ LLM
  , Trace
  , Cache
  , Logger
  , Error LMError
  , IOE
  ]
```

---

# Tracing

Every LM execution should emit a trace.

Trace data:

* model
* prompt
* response
* latency
* token counts
* cost
* retries
* tool calls
* parent trace

Example:

```haskell
traceId :: TraceId
```

The goal is complete execution visibility.

---

# Caching

Caching is mandatory.

Cache keys should include:

* model
* prompt
* temperature
* system instructions
* tool configuration

Cache backends:

* memory
* sqlite
* postgres
* redis

---

# Evaluation Framework

## Dataset

```haskell
data Example i o =
  Example
    { input :: i
    , expected :: o
    }

newtype Dataset i o =
  Dataset [Example i o]
```

## Metrics

```haskell
type Metric o =
  Expected o
  -> Actual o
  -> Score
```

Built-in metrics:

* exact match
* semantic similarity
* model judge
* custom metric

## Evaluation Runner

```haskell
evaluate
  :: Dataset i o
  -> Metric o
  -> Program i o
  -> IO Report
```

Reports should include:

* score
* latency
* token usage
* cost
* failure analysis

---

# Compiler Layer

The compiler converts abstract programs into optimized executable programs.

## Initial Compilers

### Zero Shot

Instruction only.

### Few Shot

Static demonstrations.

### Retrieval Augmented

Inject retrieved context.

### Chain of Thought

Reasoning-enabled compilation.

Example:

```haskell
compile
  :: Compiler
  -> Program i o
  -> CompiledProgram i o
```

---

# Optimizer Framework

The optimizer searches for better program configurations.

## Inputs

```haskell
optimize
  :: Optimizer
  -> Dataset i o
  -> Metric o
  -> Program i o
  -> IO (CompiledProgram i o)
```

## Initial Optimizers

### Demo Selection

Find the best demonstrations.

### Bootstrap Few-Shot

Generate demonstrations from training examples.

### Instruction Search

Mutate instructions and evaluate results.

### Ensemble Search

Search for multiple complementary programs.

---

# Tool System

Tools should be typed.

```haskell
data Tool i o
```

Example:

```haskell
weatherTool
  :: Tool WeatherRequest WeatherResponse
```

Agents interact with tools through typed interfaces rather than unstructured JSON.

---

# Observability

## OpenTelemetry

Support:

* traces
* spans
* metrics

## Metrics

Track:

* requests
* latency
* retries
* failures
* token usage
* spend

---

# Developer Experience

## CLI

```bash
lm eval
lm trace
lm optimize
lm replay
```

## Golden Tests

```haskell
goldenProgram
  :: Program i o
  -> Dataset i o
  -> TestTree
```

## Replay

```bash
lm replay trace-123
```

The same execution should be reproducible from stored traces.

---

# Initial Roadmap

## V0.1

Core runtime.

Features:

* Program
* Signature
* OpenAI provider
* Structured outputs
* Tracing
* Caching

## V0.2

Evaluation.

Features:

* Dataset runner
* Metrics
* Reports
* Golden tests

## V0.3

Compilation.

Features:

* Zero-shot compiler
* Few-shot compiler
* Chain-of-thought compiler

## V0.4

Optimization.

Features:

* Demo selection
* Bootstrap few-shot
* Instruction search

## V0.5

Agent support.

Features:

* Tool calling
* ReAct
* Multi-step programs

---

# Long-Term Vision

A framework where every LLM call is:

* Typed
* Structured
* Evaluated
* Cached
* Traced
* Reproducible
* Optimizable

The end goal is to make LM systems feel like normal software engineering rather than prompt engineering.


