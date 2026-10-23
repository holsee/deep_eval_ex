# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/metrics/argument_correctness/argument_correctness.py
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.Metrics.ArgumentCorrectness do
  @moduledoc """
  Argument Correctness metric for checking that an agent calls its tools
  with the right arguments.

  A port of deepeval 4.3.1's `ArgumentCorrectnessMetric`. Where
  `DeepEvalEx.Metrics.ToolCorrectness` asks whether the agent called the
  right tools, this metric asks whether the input parameters of each call
  address the input; it needs no expected tools.

  ## How It Works

  1. **Generate verdicts** - Given the input and the tool calls, each
     printed as deepeval's `ToolCall.__repr__`, determine for each call
     whether its input parameters are:
     - `yes` - Relevant and correct for the input
     - `no` - Not, or missing, with a reason
     Other verdicts are dropped.
  2. **Calculate score** - (correct tool calls) / (total verdicts), or `1`
     when the judge returns no verdicts
  3. **Higher score is better** - Success when score ≥ threshold

  A test case with no tool calls (`tools_called: []`) scores `1.0` with
  the reason `"No tool calls provided"`, as in deepeval: no judge or System
  One model is asked.

  ## Usage

  ```elixir
  alias DeepEvalEx.{TestCase, Metrics.ArgumentCorrectness}
  alias DeepEvalEx.Schemas.ToolCall

  test_case = TestCase.new!(
    input: "Book a table for two in Zürich on Friday.",
    tools_called: [
      %ToolCall{name: "restaurant_search", input_parameters: %{"city" => "Zürich"}},
      %ToolCall{name: "book_table", input_parameters: %{"day" => "Saturday"}}
    ]
  )

  {:ok, result} = ArgumentCorrectness.measure(test_case)
  result.score   # => 0.5 (1 tool call with correct arguments out of 2)
  result.success # => true (0.5 >= 0.5 threshold)
  ```

  ## Options

  - `:threshold` - Minimum passing score (default: 0.5, higher is better)
  - `:strict_mode` - Force the threshold to `1` and score below it `0`
    (default: false)
  - `:include_reason` - Generate explanation (default: true)
  - `:model` - LLM model for evaluation
  - `:evaluation_template` - A module overriding some of the prompts, see
    `DeepEvalEx.Prompts.EvaluationTemplate` (default: `nil`, deepeval's
    templates)
  - `:verbose_mode` - Print the result's `:verbose_logs` after measuring
    (default: false)
  - `:eval_mode` and `:system_one_model` - who decides, see "System One"

  ## System One

  Like deepeval 4.3.1's `ArgumentCorrectnessMetric`, the metric can route
  its decisions to a System One model (see `DeepEvalEx.SystemOne.Mode`):

  - `:hybrid` - the System One model judges each tool call, one Noul per
    call (`DeepEvalEx.Prompts.ArgumentCorrectness.system_one_verdict/0`)
    holding the call's `__repr__`, about `input`; its P(yes) is a verdict:
    `0.5` and above `yes` (correct), else `no`, with the reason
    `"P(yes)=0.92"`. The LLM writes the reason, and judges the tool calls
    when the model fails; the result's `:system_one_fallback_reason` then
    says why
  - `:system_one` - one request about `input` and the structured
    `tools_called` answers the whole metric
    (`DeepEvalEx.Prompts.ArgumentCorrectness.system_one_questions/0`, see
    `DeepEvalEx.SystemOne.Runner`): no LLM call is made, and the score and
    reason are built from the answers
  """

  use DeepEvalEx.Metrics.BaseMetric, default_threshold: 0.5

  alias DeepEvalEx.{
    LLM.Adapter,
    Metrics.BaseMetric,
    Metrics.QAG,
    Metrics.Utils.Verbose,
    Prompts.Python,
    Result
  }

  alias DeepEvalEx.Prompts.ArgumentCorrectness, as: Template
  alias DeepEvalEx.Prompts.EvaluationTemplate
  alias DeepEvalEx.Schemas.MetricOutputs.ArgumentCorrectness, as: Schema
  alias DeepEvalEx.SystemOne.{Decision, EvalSpec, Runner, Scored, Spec}

  @impl true
  def metric_name, do: "Argument Correctness"

  @impl true
  def required_params, do: [:input, :tools_called]

  @doc """
  Returns the judge model this metric calls with `opts`.
  """
  @impl true
  defdelegate evaluation_model(opts), to: Adapter, as: :model_name

  @doc """
  The whole metric as one System One request under the `:system_one` eval
  mode, deepeval's `_system_one_eval_spec`: its questions about the test
  case's `input` and structured `tools_called` (the metric's required
  params).

  A multimodal test case has none (`nil`), as in deepeval: System One
  reads text only.
  """
  @impl true
  def system_one_eval_spec(%{multimodal: true}, _opts), do: nil

  def system_one_eval_spec(_test_case, opts) do
    %EvalSpec{
      evaluation_params: required_params(),
      questions: Scored.parse!(EvaluationTemplate.render(opts, Template, :system_one_questions))
    }
  end

  @doc """
  Measures how many of the tool calls pass input parameters that correctly
  address the input.

  ## Options

  - `:threshold` - Minimum passing score (default: 0.5)
  - `:include_reason` - Whether to generate a reason (default: true)
  - `:adapter` - LLM adapter to use
  - `:model` - Model name
  """
  def do_measure(%{tools_called: []}, opts), do: {:ok, no_tool_calls(opts)}

  def do_measure(test_case, opts) do
    case Runner.run(__MODULE__, test_case, opts) do
      {:ok, result} -> {:ok, result}
      :continue -> measure_with_llm(test_case, opts)
    end
  end

  # deepeval decides a test case without tool calls before any System One
  # or LLM call: the float 1.0, and no verdicts.
  defp no_tool_calls(opts) do
    score = 1.0
    reason = "No tool calls provided"

    Result.new(
      metric: metric_name(),
      score: score,
      threshold: BaseMetric.threshold(opts, default_threshold()),
      reason: reason,
      verbose_logs: verbose_logs([], score, reason, opts),
      metadata: %{verdicts: []}
    )
  end

  defp measure_with_llm(test_case, opts) do
    # deepeval passes the test case's multimodal flag to its templates.
    opts = Keyword.put(opts, :multimodal, Map.get(test_case, :multimodal, false))
    threshold = BaseMetric.threshold(opts, default_threshold())
    include_reason = Keyword.get(opts, :include_reason, true)

    with {:ok, verdicts} <- generate_verdicts(test_case, opts),
         score = calculate_score(verdicts, threshold, opts),
         {:ok, reason} <-
           maybe_generate_reason(score, verdicts, test_case, include_reason, opts) do
      {:ok,
       Result.new(
         metric: metric_name(),
         score: score,
         threshold: threshold,
         reason: reason,
         verbose_logs: verbose_logs(verdicts, score, reason, opts),
         metadata: %{verdicts: verdicts}
       )}
    end
  end

  defp verbose_logs(verdicts, score, reason, opts) do
    Verbose.construct_verbose_logs(
      metric_name(),
      [
        "Verdicts:\n#{verdicts |> Verbose.verdict_models() |> Verbose.prettify_list()}",
        "Score: #{Verbose.to_str(score)}\nReason: #{Verbose.to_str(reason)}"
      ],
      opts
    )
  end

  # Under :hybrid the System One model judges each tool call, as its
  # repr(); the LLM does when it is not asked or fails (deepeval's
  # generate_qag_verdicts).
  defp generate_verdicts(test_case, opts) do
    spec = %Spec.Verdicts{
      instructions: EvaluationTemplate.render(opts, Template, :system_one_verdict),
      items: Enum.map(test_case.tools_called, &Python.repr/1),
      item_key: "tool_call",
      state: [input: test_case.input]
    }

    decision_opts = Keyword.put_new(opts, :metric_name, metric_name())

    case Decision.verdicts(spec, QAG.yes_no(), decision_opts) do
      {:ok, verdicts} -> {:ok, verdicts}
      :llm -> llm_verdicts(test_case, opts)
    end
  end

  defp llm_verdicts(test_case, opts) do
    prompt =
      EvaluationTemplate.render(opts, Template, :generate_verdicts,
        input: test_case.input,
        tools_called: test_case.tools_called,
        multimodal: opts[:multimodal]
      )

    case Adapter.generate_with_schema(prompt, Schema.verdicts_schema(), opts) do
      {:ok, response} -> Schema.parse_verdicts(response)
      {:error, _} = error -> error
    end
  end

  # deepeval 4.3.1 scores the verdicts that pass (`yes`, the arguments are
  # correct) over all verdicts, and an empty list as the integer 1
  defp calculate_score(verdicts, threshold, opts) do
    QAG.score_qag_verdicts(verdicts,
      passing: [:yes],
      strict_mode: Keyword.get(opts, :strict_mode, false),
      threshold: threshold
    )
  end

  defp maybe_generate_reason(_score, _verdicts, _test_case, false, _opts), do: {:ok, nil}

  # The reasons of the incorrect tool calls, `nil` (Python's `None`) included
  defp maybe_generate_reason(score, verdicts, test_case, true, opts) do
    incorrect_tool_calls_reasons = for %{verdict: :no, reason: reason} <- verdicts, do: reason

    prompt =
      EvaluationTemplate.render(opts, Template, :generate_reason,
        incorrect_tool_calls_reasons: incorrect_tool_calls_reasons,
        input: test_case.input,
        score: score,
        multimodal: opts[:multimodal]
      )

    case Adapter.generate_with_schema(prompt, Schema.reason_schema(), opts) do
      {:ok, response} -> Schema.parse_reason(response)
      {:error, _} = error -> error
    end
  end
end
