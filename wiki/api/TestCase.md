# TestCase

`DeepEvalEx.TestCase` represents a test case for LLM evaluation.

## Overview

A test case contains the input prompt, the LLM's actual output, and optional context for evaluation. Different metrics require different fields to be populated.

## Fields

| Field | Type | Description |
|-------|------|-------------|
| `input` | `String.t()` | The input prompt sent to the LLM (required) |
| `actual_output` | `String.t()` | The LLM's response to evaluate |
| `expected_output` | `String.t()` | The expected/ground truth output |
| `retrieval_context` | `[String.t()]` | List of retrieved context chunks for RAG |
| `context` | `[String.t()]` | Alias for `retrieval_context` |
| `tools_called` | `[ToolCall.t()]` | List of tool calls made by the LLM |
| `expected_tools` | `[ToolCall.t()]` | Expected tool calls for tool use evaluation |
| `metadata` | `map()` | Additional metadata |
| `name` | `String.t()` | Optional name/identifier for the test case |
| `tags` | `[String.t()]` | Tags for filtering/grouping |

## Creating Test Cases

### Using `new!/1`

```elixir
alias DeepEvalEx.TestCase

# Basic test case
test_case = TestCase.new!(
  input: "What is the capital of France?",
  actual_output: "The capital of France is Paris."
)

# With expected output (for comparison metrics)
test_case = TestCase.new!(
  input: "What is 2 + 2?",
  actual_output: "4",
  expected_output: "4"
)

# RAG evaluation (with retrieval context)
test_case = TestCase.new!(
  input: "What are the benefits of exercise?",
  actual_output: "Exercise improves cardiovascular health and mood.",
  retrieval_context: [
    "Regular exercise strengthens the heart.",
    "Physical activity releases endorphins."
  ]
)
```

### Using `new/1` (with error handling)

```elixir
case TestCase.new(input: "Question", actual_output: "Answer") do
  {:ok, test_case} -> test_case
  {:error, changeset} -> handle_error(changeset)
end
```

### Direct struct creation

```elixir
%DeepEvalEx.TestCase{
  input: "Question",
  actual_output: "Answer"
}
```

## Context Alias

The `context` field is an alias for `retrieval_context`. Both work interchangeably:

```elixir
# These are equivalent
TestCase.new!(input: "Q", actual_output: "A", context: ["doc1", "doc2"])
TestCase.new!(input: "Q", actual_output: "A", retrieval_context: ["doc1", "doc2"])
```

## Metric Requirements

Different metrics require different fields:

| Metric | Required Fields |
|--------|-----------------|
| ExactMatch | `input`, `actual_output`, `expected_output` |
| GEval | Configurable via `evaluation_params` |
| Faithfulness | `input`, `actual_output`, `retrieval_context` |
| Hallucination | `input`, `actual_output`, `context` |
| AnswerRelevancy | `input`, `actual_output` |
| ContextualPrecision | `input`, `retrieval_context`, `expected_output` |
| ContextualRecall | `input`, `retrieval_context`, `expected_output` |

## Helper Functions

### `get_retrieval_context/1`

Returns the effective retrieval context:

```elixir
TestCase.get_retrieval_context(test_case)
# => ["doc1", "doc2"]
```

### `validate_params/2`

Validates that required parameters are present:

```elixir
TestCase.validate_params(test_case, [:input, :actual_output, :retrieval_context])
# => :ok | {:error, {:missing_params, [:retrieval_context]}}
```

## Type Specification

```elixir
@type t :: %DeepEvalEx.TestCase{
  input: String.t(),
  actual_output: String.t() | nil,
  expected_output: String.t() | nil,
  retrieval_context: [String.t()] | nil,
  context: [String.t()] | nil,
  tools_called: [ToolCall.t()] | nil,
  expected_tools: [ToolCall.t()] | nil,
  metadata: map() | nil,
  name: String.t() | nil,
  tags: [String.t()] | nil
}
```

## See Also

- [Result](Result.md) - Evaluation results
- [Metrics Overview](../metrics/Overview.md) - Available metrics and their requirements
