# Tool Correctness Metric

An agentic LLM metric that assesses your LLM agent's function/tool calling ability. It compares whether every tool expected to be used was indeed called and whether the selection of tools was optimal. The metric supports both deterministic comparison and optional LLM-based tool selection scoring.

## When to Use

- Agent tool calling evaluation — verifying tools were invoked correctly
- Function calling validation — checking parameter and output correctness
- Tool selection optimality — assessing whether the best tools were chosen from available options
- Agentic workflow testing — end-to-end evaluation of multi-step tool use

## How It Works

1. **Deterministic comparison** — Compare `tools_called` against `expected_tools` using one of three modes: default (unordered greedy matching), exact match, or ordering-aware (weighted LCS)
2. **Optional LLM-based tool selection** — When `available_tools` is provided, an LLM evaluates whether the tools selected were optimal given the full set of available tools
3. **Final score** — `min(tool_calling_score, tool_selection_score)`. Higher is better; success when `score >= threshold`

## Required Parameters

| Parameter | Description |
|-----------|-------------|
| `:input` | The input prompt/question |
| `:actual_output` | The LLM's response |
| `:tools_called` | List of `ToolCall` structs representing tools actually called |
| `:expected_tools` | List of `ToolCall` structs representing expected tool calls |

## Basic Usage

```elixir
alias DeepEvalEx.{TestCase, Metrics.ToolCorrectness}
alias DeepEvalEx.Schemas.ToolCall

test_case = TestCase.new!(
  input: "What if these shoes don't fit?",
  actual_output: "We offer a 30-day full refund at no extra cost.",
  tools_called: [
    %ToolCall{name: "WebSearch"},
    %ToolCall{name: "ToolQuery"}
  ],
  expected_tools: [
    %ToolCall{name: "WebSearch"}
  ]
)

{:ok, result} = ToolCorrectness.measure(test_case)

result.score   # => 1.0 (expected tool was called)
result.success # => true
```

## Options

### Basic Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `:threshold` | float | 0.5 | Score threshold for pass/fail (higher is better) |
| `:include_reason` | boolean | true | Generate explanation |
| `:strict_mode` | boolean | false | Binary scoring: 1 for perfection, 0 otherwise; overrides threshold to 1.0 |

### Advanced Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `:should_exact_match` | boolean | false | All-or-nothing positional matching; length mismatch → 0.0 |
| `:should_consider_ordering` | boolean | false | Use weighted LCS to enforce tool call order |
| `:evaluation_params` | list | `[]` | Additional `ToolCall` fields to compare: `:input_parameters`, `:output` |
| `:available_tools` | list or nil | nil | List of `ToolCall` structs; triggers LLM-based tool selection scoring |
| `:adapter` | atom | default | LLM adapter (only needed when `available_tools` is set) |
| `:model` | string | default | Model name (only needed when `available_tools` is set) |

:::info
Since `should_exact_match` is a stricter criterion than `should_consider_ordering`, setting `should_consider_ordering` will have no effect when `should_exact_match` is set to `true`.
:::

## Scoring Modes

### Default Mode (Unordered Greedy Matching)

For each expected tool, find the best matching called tool greedily. Extra tools do not penalise.

**Score** = total matches / |expected|

```elixir
test_case = TestCase.new!(
  input: "Find applicants",
  actual_output: "Found 3 results.",
  tools_called: [
    %ToolCall{name: "search_db"},
    %ToolCall{name: "format_results"},
    %ToolCall{name: "log_query"}
  ],
  expected_tools: [
    %ToolCall{name: "search_db"},
    %ToolCall{name: "format_results"}
  ]
)

{:ok, result} = ToolCorrectness.measure(test_case)
result.score  # => 1.0 (both expected tools were called; extra "log_query" ignored)
```

### Exact Match Mode

Lists must be the same length and each position is compared. Any mismatch → score 0.0.

```elixir
{:ok, result} = ToolCorrectness.measure(test_case,
  should_exact_match: true
)
result.score  # => 0.0 (length mismatch: 3 called vs 2 expected)
```

### Ordering Mode (Weighted LCS)

Uses a weighted Longest Common Subsequence algorithm to enforce that tools were called in the correct relative order.

**Score** = weighted LCS score / |expected|

```elixir
test_case = TestCase.new!(
  input: "Process order",
  actual_output: "Done.",
  tools_called: [
    %ToolCall{name: "validate"},
    %ToolCall{name: "charge"},
    %ToolCall{name: "notify"}
  ],
  expected_tools: [
    %ToolCall{name: "validate"},
    %ToolCall{name: "charge"},
    %ToolCall{name: "notify"}
  ]
)

{:ok, result} = ToolCorrectness.measure(test_case,
  should_consider_ordering: true
)
result.score  # => 1.0 (correct order)
```

### Parameter Matching

Include `:input_parameters` and/or `:output` in `evaluation_params` to compare beyond tool names. Parameter similarity is computed via recursive dictionary comparison returning a fractional score (0.0–1.0).

```elixir
test_case = TestCase.new!(
  input: "Look up user 42",
  actual_output: "Found user.",
  tools_called: [
    %ToolCall{name: "find_user", input_parameters: %{"id" => 42, "include_email" => true}}
  ],
  expected_tools: [
    %ToolCall{name: "find_user", input_parameters: %{"id" => 42}}
  ]
)

{:ok, result} = ToolCorrectness.measure(test_case,
  evaluation_params: [:input_parameters]
)
# Fractional score based on parameter overlap
```

## Understanding Scores

| Score | Meaning |
|-------|---------|
| 0.0 | No expected tools were called correctly |
| 0.5 | Half of expected tools matched |
| 1.0 | All expected tools called correctly (best) |

**Note:** Higher is better. A score of 1.0 means all expected tools were called with the correct parameters (if specified) and in the correct order (if ordering is enabled).

## Tool Selection Scoring

When `available_tools` is provided, an LLM evaluates whether the tools selected by the agent were optimal given all available options. The final score is `min(tool_calling_score, tool_selection_score)`.

Without `available_tools`, the metric is **fully deterministic** — no LLM calls are made.

The LLM scores tool selection on a 5-point scale:

| Score | Meaning |
|-------|---------|
| 1.0 | Perfect — optimal tool selection |
| 0.75 | Good — mostly optimal with minor improvements possible |
| 0.5 | Acceptable — some suboptimal choices |
| 0.25 | Poor — significant suboptimal selections |
| 0.0 | Incorrect — entirely wrong tool selection |

```elixir
available = [
  %ToolCall{name: "WebSearch", description: "Search the web"},
  %ToolCall{name: "DatabaseQuery", description: "Query internal DB"},
  %ToolCall{name: "Calculator", description: "Perform calculations"},
  %ToolCall{name: "EmailSend", description: "Send emails"}
]

{:ok, result} = ToolCorrectness.measure(test_case,
  available_tools: available,
  adapter: :openai,
  model: "gpt-4o"
)

result.metadata.tool_calling_score    # Deterministic score
result.metadata.tool_selection_score  # LLM-based score
result.score                          # min of both
```

## Result Structure

```elixir
%DeepEvalEx.Result{
  metric: "Tool Correctness",
  score: 1.0,
  success: true,
  threshold: 0.5,
  reason: "[\n\t Tool Calling Reason: All expected tools [\"WebSearch\"] were called...\n\t Tool Selection Reason: No available tools were provided...\n]\n",
  latency_ms: 42,
  metadata: %{
    tool_calling_score: 1.0,
    tool_selection_score: 1.0,
    tool_selection_reason: "No available tools were provided to assess tool selection criteria",
    should_exact_match: false,
    should_consider_ordering: false,
    evaluation_params: [],
    strict_mode: false
  }
}
```

## Adjusting Threshold

```elixir
# Strict: require near-perfect tool calling
{:ok, result} = ToolCorrectness.measure(test_case, threshold: 0.9)

# Lenient: allow partial matches
{:ok, result} = ToolCorrectness.measure(test_case, threshold: 0.3)
```

## Specifying LLM Model

An LLM is only required when `available_tools` is provided for tool selection scoring. Without it, the metric is fully deterministic.

```elixir
{:ok, result} = ToolCorrectness.measure(test_case,
  available_tools: available,
  adapter: :openai,
  model: "gpt-4o"
)

# Or use Anthropic
{:ok, result} = ToolCorrectness.measure(test_case,
  available_tools: available,
  adapter: :anthropic,
  model: "claude-3-haiku-20240307"
)
```

## Error Handling

```elixir
case ToolCorrectness.measure(test_case) do
  {:ok, result} ->
    if result.success do
      IO.puts("Tools called correctly!")
    else
      IO.puts("Tool correctness score too low: #{result.score}")
    end

  {:error, {:missing_params, params}} ->
    IO.puts("Missing required parameters: #{inspect(params)}")

  {:error, {:api_error, status, body}} ->
    IO.puts("API error (tool selection): #{status}")
end
```

## Best Practices

### Start Simple, Add Strictness Gradually

Begin with the default mode (name matching only), then add `evaluation_params`, ordering, or exact matching as your agent matures:

```elixir
# Phase 1: Just check tool names
ToolCorrectness.measure(test_case)

# Phase 2: Also verify parameters
ToolCorrectness.measure(test_case, evaluation_params: [:input_parameters])

# Phase 3: Enforce ordering
ToolCorrectness.measure(test_case,
  evaluation_params: [:input_parameters],
  should_consider_ordering: true
)
```

### Use `available_tools` for Selection Quality

Provide the full set of tools available to your agent to catch cases where the correct tool was called but a better alternative existed.

### Combine with Other Metrics

Tool correctness tells you *what* was called — pair it with output quality metrics (GEval, Faithfulness) to evaluate the full agent pipeline.

## Example: Complete Evaluation

```elixir
alias DeepEvalEx.{TestCase, Metrics.ToolCorrectness}
alias DeepEvalEx.Schemas.ToolCall

# Simulate an agent handling a customer refund request
test_case = TestCase.new!(
  input: "I want to return order #12345 and get a refund",
  actual_output: "I've initiated the return for order #12345. Your refund of £49.99 will be processed within 5-7 business days.",
  tools_called: [
    %ToolCall{
      name: "lookup_order",
      input_parameters: %{"order_id" => "12345"},
      output: "Order #12345: Running shoes, £49.99, delivered"
    },
    %ToolCall{
      name: "initiate_return",
      input_parameters: %{"order_id" => "12345", "reason" => "customer_request"},
      output: "Return initiated, refund in 5-7 days"
    }
  ],
  expected_tools: [
    %ToolCall{
      name: "lookup_order",
      input_parameters: %{"order_id" => "12345"}
    },
    %ToolCall{
      name: "initiate_return",
      input_parameters: %{"order_id" => "12345", "reason" => "customer_request"}
    }
  ]
)

# Evaluate with parameter matching and ordering
{:ok, result} = ToolCorrectness.measure(test_case,
  evaluation_params: [:input_parameters],
  should_consider_ordering: true,
  threshold: 0.7
)

IO.puts("Tool Correctness Score: #{result.score}")
IO.puts("Success: #{result.success}")
IO.puts("Calling Score: #{result.metadata.tool_calling_score}")
IO.puts("Reason: #{result.reason}")

# Expected output:
# Tool Correctness Score: 1.0
# Success: true
# Calling Score: 1.0
```

## Source

Ported from `deepeval/metrics/tool_correctness/tool_correctness.py`
