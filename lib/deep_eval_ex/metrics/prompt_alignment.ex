# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/metrics/prompt_alignment/prompt_alignment.py
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.Metrics.PromptAlignment do
  @moduledoc """
  Prompt Alignment metric for checking that an LLM's output follows the
  instructions of its prompt template.

  A port of deepeval 4.3.1's `PromptAlignmentMetric`.

  ## How It Works

  1. **Generate verdicts** - Given the prompt instructions, the input and
     the actual output, determine for each instruction whether it is:
     - `yes` - Followed completely
     - `no` - Not followed, with a reason
     Other verdicts are dropped.
  2. **Calculate score** - (followed instructions) / (total verdicts), or
     `1` when the judge returns no verdicts
  3. **Higher score is better** - Success when score ≥ threshold

  ## Usage

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

  result.score   # => 0.5 (1 instruction followed out of 2)
  result.success # => true (0.5 >= 0.5 threshold)
  ```

  ## Options

  - `:prompt_instructions` - The instructions of the prompt the output was
    generated with, a non-empty list of strings (required)
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

  Measuring without `:prompt_instructions`, or with an empty list, raises
  `ArgumentError`, as deepeval's constructor raises `ValueError`.

  ## As a configured metric

  The instructions belong to the metric, as in deepeval's
  `PromptAlignmentMetric(prompt_instructions=...)`. To evaluate with other
  metrics, or two prompt templates at once, build the metric with `new/1`
  and pass the struct to `DeepEvalEx.evaluate/3`; its fields take
  precedence over the run's options:

  ```elixir
  metric = PromptAlignment.new(prompt_instructions: ["Reply in English."])
  DeepEvalEx.evaluate(test_cases, [metric, DeepEvalEx.Metrics.PIILeakage])
  ```

  ## System One

  Like deepeval 4.3.1's `PromptAlignmentMetric`, the metric can route its
  decisions to a System One model (see `DeepEvalEx.SystemOne.Mode`):

  - `:hybrid` - the System One model judges whether the output follows
    each instruction, one Noul per instruction
    (`DeepEvalEx.Prompts.PromptAlignment.system_one_verdict/0`) about
    `input` and `actual_output`, whose P(yes) is a verdict: `0.5` and above
    `yes` (followed), else `no`, with the reason `"P(yes)=0.97"`. The LLM
    writes the reason, and judges the instructions when the model fails;
    the result's `:system_one_fallback_reason` then says why
  - `:system_one` - one request about `input` and `actual_output`, one Noul
    per instruction
    (`DeepEvalEx.Prompts.PromptAlignment.system_one_questions/1`, see
    `DeepEvalEx.SystemOne.Runner`), answers the whole metric: no LLM call
    is made, and the score and reason are built from the answers
  """

  use DeepEvalEx.Metrics.BaseMetric, default_threshold: 0.5

  alias DeepEvalEx.{
    LLM.Adapter,
    Metrics.BaseMetric,
    Metrics.QAG,
    Metrics.Utils.Verbose,
    Result
  }

  alias DeepEvalEx.Prompts.EvaluationTemplate
  alias DeepEvalEx.Prompts.PromptAlignment, as: Template
  alias DeepEvalEx.Schemas.MetricOutputs.PromptAlignment, as: Schema
  alias DeepEvalEx.SystemOne.{Decision, EvalSpec, Runner, Scored, Spec}

  @enforce_keys [:prompt_instructions]
  defstruct [
    :prompt_instructions,
    :threshold,
    :strict_mode,
    :include_reason,
    :model,
    :verbose_mode,
    :flaky,
    :eval_mode,
    :system_one_model,
    :evaluation_template
  ]

  @type t :: %__MODULE__{
          prompt_instructions: [String.t(), ...],
          threshold: number() | nil,
          strict_mode: boolean() | nil,
          include_reason: boolean() | nil,
          model: term(),
          verbose_mode: boolean() | nil,
          flaky: boolean() | nil,
          eval_mode: atom() | String.t() | nil,
          system_one_model: term(),
          evaluation_template: module() | nil
        }

  @doc """
  Creates a PromptAlignment metric for `DeepEvalEx.evaluate/3`. See the
  moduledoc for the options; those left unset (`nil`) fall back to the
  run's options.

  Raises `ArgumentError`, as deepeval's constructor raises `ValueError`,
  when `:prompt_instructions` is missing or empty.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      prompt_instructions: instructions!(opts),
      threshold: BaseMetric.threshold(opts, default_threshold()),
      strict_mode: Keyword.get(opts, :strict_mode),
      include_reason: Keyword.get(opts, :include_reason),
      model: Keyword.get(opts, :model),
      verbose_mode: Keyword.get(opts, :verbose_mode),
      flaky: Keyword.get(opts, :flaky),
      eval_mode: Keyword.get(opts, :eval_mode),
      system_one_model: Keyword.get(opts, :system_one_model),
      evaluation_template: Keyword.get(opts, :evaluation_template)
    }
  end

  @impl true
  def metric_name, do: "Prompt Alignment"

  @impl true
  def required_params, do: [:input, :actual_output]

  @doc """
  Returns the judge model this metric calls with `opts`.
  """
  @impl true
  defdelegate evaluation_model(opts), to: Adapter, as: :model_name

  @doc """
  The whole metric as one System One request under the `:system_one` eval
  mode, deepeval's `_system_one_eval_spec`: one Noul per prompt instruction
  about the test case's `input` and `actual_output` (the metric's required
  params).

  A multimodal test case has none (`nil`), as in deepeval: System One
  reads text only.
  """
  @impl true
  def system_one_eval_spec(%{multimodal: true}, _opts), do: nil

  def system_one_eval_spec(_test_case, opts) do
    %EvalSpec{
      evaluation_params: required_params(),
      questions:
        Scored.parse!(
          EvaluationTemplate.render(opts, Template, :system_one_questions,
            prompt_instructions: instructions!(opts)
          )
        )
    }
  end

  @doc """
  Measures how many of the prompt instructions the actual output follows.

  ## Options

  - `:prompt_instructions` - The prompt's instructions (required)
  - `:threshold` - Minimum passing score (default: 0.5)
  - `:include_reason` - Whether to generate a reason (default: true)
  - `:adapter` - LLM adapter to use
  - `:model` - Model name
  """
  def do_measure(test_case, opts) do
    instructions = instructions!(opts)

    case Runner.run(__MODULE__, test_case, opts) do
      {:ok, result} -> {:ok, result}
      :continue -> measure_with_llm(test_case, instructions, opts)
    end
  end

  # deepeval's constructor check.
  defp instructions!(opts) do
    case Keyword.get(opts, :prompt_instructions) do
      [_ | _] = instructions -> instructions
      _ -> raise ArgumentError, "'prompt_instructions' must not be empty."
    end
  end

  defp measure_with_llm(test_case, instructions, opts) do
    threshold = BaseMetric.threshold(opts, default_threshold())
    include_reason = Keyword.get(opts, :include_reason, true)

    with {:ok, verdicts} <- generate_verdicts(instructions, test_case, opts),
         score = calculate_score(verdicts, threshold, opts),
         {:ok, reason} <-
           maybe_generate_reason(score, verdicts, test_case, include_reason, opts) do
      verbose_logs =
        Verbose.construct_verbose_logs(
          metric_name(),
          [
            "Prompt Instructions:\n#{Verbose.prettify_list(instructions)}",
            "Verdicts:\n#{verdicts |> Verbose.verdict_models() |> Verbose.prettify_list()}",
            "Score: #{Verbose.to_str(score)}\nReason: #{Verbose.to_str(reason)}"
          ],
          opts
        )

      {:ok,
       Result.new(
         metric: metric_name(),
         score: score,
         threshold: threshold,
         reason: reason,
         verbose_logs: verbose_logs,
         metadata: %{prompt_instructions: instructions, verdicts: verdicts}
       )}
    end
  end

  # Under :hybrid the System One model judges the instructions; the LLM does
  # when it is not asked or fails (deepeval's generate_qag_verdicts).
  defp generate_verdicts(instructions, test_case, opts) do
    spec = %Spec.Verdicts{
      instructions: EvaluationTemplate.render(opts, Template, :system_one_verdict),
      items: instructions,
      item_key: "instruction",
      state: [input: test_case.input, actual_output: test_case.actual_output]
    }

    decision_opts = Keyword.put_new(opts, :metric_name, metric_name())

    case Decision.verdicts(spec, QAG.yes_no(), decision_opts) do
      {:ok, verdicts} -> {:ok, verdicts}
      :llm -> llm_verdicts(instructions, test_case, opts)
    end
  end

  defp llm_verdicts(instructions, test_case, opts) do
    prompt =
      EvaluationTemplate.render(opts, Template, :generate_verdicts,
        prompt_instructions: instructions,
        input: test_case.input,
        actual_output: test_case.actual_output
      )

    case Adapter.generate_with_schema(prompt, Schema.verdicts_schema(), opts) do
      {:ok, response} -> Schema.parse_verdicts(response)
      {:error, _} = error -> error
    end
  end

  # deepeval 4.3.1 scores the verdicts that pass (`yes`, the instruction is
  # followed) over all verdicts, and an empty list as the integer 1
  defp calculate_score(verdicts, threshold, opts) do
    QAG.score_qag_verdicts(verdicts,
      passing: [:yes],
      strict_mode: Keyword.get(opts, :strict_mode, false),
      threshold: threshold
    )
  end

  defp maybe_generate_reason(_score, _verdicts, _test_case, false, _opts), do: {:ok, nil}

  # The reasons of the broken instructions, `nil` (Python's `None`) included
  defp maybe_generate_reason(score, verdicts, test_case, true, opts) do
    unalignment_reasons = for %{verdict: :no, reason: reason} <- verdicts, do: reason

    prompt =
      EvaluationTemplate.render(opts, Template, :generate_reason,
        unalignment_reasons: unalignment_reasons,
        input: test_case.input,
        actual_output: test_case.actual_output,
        score: score
      )

    case Adapter.generate_with_schema(prompt, Schema.reason_schema(), opts) do
      {:ok, response} -> Schema.parse_reason(response)
      {:error, _} = error -> error
    end
  end
end
