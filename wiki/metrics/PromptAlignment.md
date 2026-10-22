# PromptAlignment Metric

PromptAlignment measures whether an LLM's output follows the instructions of the prompt template that produced it. You list the instructions; the judge decides, for each one, whether the output follows it completely; the score is the share followed.

## When to Use

- Regression testing a system prompt: formatting rules, tone, language, things never to say
- Comparing models or prompt versions on how faithfully they follow instructions
- Guarding structured-output contracts ("answer in one sentence", "respond in JSON")

## How It Works

1. **Generate verdicts** - Given the prompt instructions, the input and the actual output, determine for each instruction whether it is:
   - `yes` - Followed completely (the judge is told to be extra strict)
   - `no` - Not followed, with a reason
2. **Calculate score** - `(followed instructions) / (total verdicts)`, or `1` when the judge returns no verdicts. Verdicts other than `yes` and `no` are dropped
3. **Higher score is better** - Success when score ≥ threshold

## Required Parameters

| Parameter | Description |
|-----------|-------------|
| `:input` | The input prompt/question |
| `:actual_output` | The LLM's response, judged against the instructions |

The metric also needs `:prompt_instructions`, a non-empty list of strings. Measuring without it, or with an empty list, raises `ArgumentError`, as deepeval's constructor raises `ValueError`.

## Basic Usage

```elixir
alias DeepEvalEx.{TestCase, Metrics.PromptAlignment}

test_case = TestCase.new!(
  input: "Say hello to the new team member.",
  actual_output: "Hello and welcome to the team!"
)

{:ok, result} =
  PromptAlignment.measure(test_case,
    prompt_instructions: ["Reply in English.", "Respond in all upper case."]
  )

result.score   # => 0.5 (1 of 2 instructions followed)
result.reason  # => "The score is 0.50 because the output is not in upper case."
result.success # => true (0.5 >= 0.5 threshold)
```

### With other metrics

The instructions belong to the metric, as deepeval's `PromptAlignmentMetric(prompt_instructions=...)`. Build it with `new/1` to evaluate it alongside other metrics; its fields take precedence over the run's options:

```elixir
metric = PromptAlignment.new(prompt_instructions: ["Reply in English."], threshold: 0.8)

DeepEvalEx.evaluate(test_cases, [metric, DeepEvalEx.Metrics.PIILeakage])
```

## Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `:prompt_instructions` | list of strings | required | The prompt template's instructions |
| `:threshold` | float | 0.5 | Minimum passing score (higher is better) |
| `:strict_mode` | boolean | false | Threshold `1`, and a score below it is `0` |
| `:include_reason` | boolean | true | Generate explanation |
| `:adapter` | atom | :openai | LLM adapter to use |
| `:model` | string | default | Model name |
| `:verbose_mode` | boolean | false | Print the verbose logs after measuring |
| `:eval_mode` | atom | configured (`:llm`) | `:llm`, `:hybrid` or `:system_one`, see below |
| `:system_one_model` | term | TypeSafe Jev | The System One model for `:hybrid` and `:system_one` |

## Understanding Scores

| Score | Meaning |
|-------|---------|
| 1.0 | Every instruction is followed (best) |
| 0.5 | Half of the instructions are followed |
| 0.0 | No instruction is followed (worst) |

## System One

As deepeval 4.3.1's `PromptAlignmentMetric`, the metric can hand its decisions to a System One model (ADR-0009):

- `eval_mode: :hybrid` - the System One model is asked whether the output completely follows each instruction when responding to the input, one Noul per instruction (`instruction_0`, `instruction_1`, ...) in one request about `input` and `actual_output`. P(yes) of `0.5` and above is `yes` (followed), below is `no`, each with the reason `"P(yes)=0.97"`. The LLM writes the reason, and judges the instructions when the request fails; `system_one_fallback_reason` then says why
- `eval_mode: :system_one` - one request about `input` and `actual_output`, one Noul per instruction, answers the whole metric; no LLM is called. It can be batched with the test case's other `system_one` metrics

```elixir
{:ok, result} =
  PromptAlignment.measure(test_case,
    prompt_instructions: ["Reply in English."],
    eval_mode: :system_one
  )
```

## Result Structure

```elixir
%DeepEvalEx.Result{
  metric: "Prompt Alignment",
  score: 0.5,
  success: true,
  threshold: 0.5,
  reason: "The score is 0.50 because the output is not in upper case.",
  metadata: %{
    prompt_instructions: ["Reply in English.", "Respond in all upper case."],
    verdicts: [
      %{verdict: :yes, reason: nil},
      %{verdict: :no, reason: "The output is not in upper case."}
    ]
  }
}
```

## Source

Ported from `deepeval/metrics/prompt_alignment/prompt_alignment.py`
