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
| `retrieval_context` | `[String.t()]` | Context chunks your retriever returned at run time, for RAG metrics |
| `context` | `[String.t()]` | Ideal, ground-truth context for the input, for Hallucination |
| `tools_called` | `[ToolCall.t()]` | List of tool calls made by the LLM; `nil` when not given (an empty list means no tools were called) |
| `expected_tools` | `[ToolCall.t()]` | Expected tool calls for tool use evaluation; `nil` when not given |
| `mcp_servers` | `[MCPServer.t()]` | The MCP servers the application could use (see "MCP") |
| `mcp_tools_called`, `mcp_resources_called`, `mcp_prompts_called` | `[MCPToolCall.t()]`, `[MCPResourceCall.t()]`, `[MCPPromptCall.t()]` | The MCP calls made (see "MCP") |
| `metadata` | `map()` | Additional metadata |
| `name` | `String.t()` | Optional name/identifier for the test case |
| `tags` | `[String.t()]` | Tags for filtering/grouping |
| `images` | `%{String.t() => MLLMImage.t()}` | The images the test case's placeholders name (see "Images") |
| `multimodal` | `boolean()` | Whether the test case holds images; `new/1` sets it when a placeholder appears |

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

### Images

An image goes into a text field as its placeholder, which interpolating a
`DeepEvalEx.MLLMImage` gives, and into `:images`. The judge then sees the
image itself (see "Multimodal Prompts" in the LLM Adapters page), the
metrics use deepeval's multimodal prompts, and the test run exports the
images as `imagesMapping`:

```elixir
alias DeepEvalEx.{MLLMImage, TestCase}

chart = MLLMImage.new!(url: "https://example.com/charts/sales.png")
photo = MLLMImage.new!(url: "priv/photos/receipt.jpg")
logo = MLLMImage.new!(data_base64: base64_png, mime_type: "image/png")

test_case = TestCase.new!(
  input: "What does #{chart} show?",
  actual_output: "Sales doubled in 2024.",
  images: [chart, photo, logo]
)

test_case.multimodal
#=> true
```

A remote image is sent to the judge by URL (Ollama downloads it); a local
file is read when the image is created. A multimodal test case has no
`:system_one` form, as in deepeval: System One reads text only.

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

### MCP

A test case (or a conversation, and each of its turns) can record the
Model Context Protocol servers its application could use and the MCP calls
it made, as deepeval 4.3.1's `MCPServer`, `MCPToolCall`, `MCPResourceCall`
and `MCPPromptCall`. A call's `result` is plain data shaped as the MCP
spec's result (`CallToolResult`, `ReadResourceResult`, `GetPromptResult`),
kept as given:

```elixir
test_case =
  TestCase.new!(
    input: "What's the weather in Paris?",
    actual_output: "18°C, partly cloudy",
    mcp_servers: [
      %{server_name: "weather", transport: :stdio, available_tools: [%{"name" => "get_weather"}]}
    ],
    tools_called: [%{name: "get_weather", input_parameters: %{"city" => "Paris"}}],
    mcp_tools_called: [
      %{
        name: "get_weather",
        args: %{"city" => "Paris"},
        result: %{"content" => [%{"type" => "text", "text" => "18°C, partly cloudy"}]}
      }
    ]
  )
```

When the test case is evaluated, each tool call named among its servers'
available tools becomes an MCP tool call (`type: :mcp`, exported as
`"type": "MCP"`), as deepeval's `evaluate()` does; `DeepEvalEx.evaluate/3`
also takes `mcp_servers:` for the test cases that list none of their own.
The MCP calls are not exported in a test run (deepeval does not export
them), but expectations and System One states see them, and conversational
metrics can name a turn's MCP calls as evaluation params.

## Context and Retrieval Context

As in deepeval 4.3.1, `context` and `retrieval_context` are separate fields,
and neither stands in for the other:

- `retrieval_context` is what your retriever returned at run time. Faithfulness,
  ContextualPrecision, ContextualRecall and ContextualRelevancy read it
- `context` is the ideal, ground-truth context for the input. Hallucination
  reads it

A test case with only `context` fails Faithfulness with
`'retrieval_context' cannot be None for the 'Faithfulness' metric`, and one
with only `retrieval_context` fails Hallucination the same way. Exports
include each field only when it is set (`context`, `retrievalContext`).

```elixir
TestCase.new!(
  input: "Who wrote Hamlet?",
  actual_output: "Shakespeare wrote Hamlet.",
  context: ["Hamlet is a tragedy written by William Shakespeare."],
  retrieval_context: ["Hamlet, Prince of Denmark, by William Shakespeare."]
)
```

> Before this release `context` was copied into `retrieval_context` and each
> satisfied a metric requiring the other. Set the field each metric reads.

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
| ContextualRelevancy | `input`, `retrieval_context` |
| Bias | `input`, `actual_output` |
| Toxicity | `input`, `actual_output` |
| PIILeakage | `input`, `actual_output` |
| PromptAlignment | `input`, `actual_output` (and the metric's `prompt_instructions`) |
| Summarization | `input` (the original text), `actual_output` (the summary) |
| ArgumentCorrectness | `input`, `tools_called` |

## Helper Functions

### `validate_params/2`

Validates that required parameters are present, as deepeval's
`check_llm_test_case_params`. Only `nil` is missing (empty lists and strings
are present), except that a required `actual_output` must not be the empty
string, which is checked first:

```elixir
TestCase.validate_params(test_case, [:input, :actual_output, :retrieval_context])
# => :ok
#  | {:error, {:missing_params, [:retrieval_context]}}
#  | {:error, {:empty_param, :actual_output}}
```

An errored result renders these with deepeval's `MissingTestCaseParamsError`
message, e.g. `'actual_output' and 'retrieval_context' cannot be None for the
'Faithfulness' metric` (see [Result](Result.md)).

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
