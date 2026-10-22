# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/metrics/json_correctness/json_correctness.py
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.Metrics.JsonCorrectness do
  @moduledoc """
  JSON correctness metric checking that an LLM's output is JSON matching an
  expected schema.

  A port of deepeval 4.3.1's `JsonCorrectnessMetric`. The check is made in
  code; the LLM judge only explains a failure.

  ## How It Works

  1. **Validate** - The actual output is parsed as JSON and validated
     against `:expected_schema`
     - `1` - It matches (the integer, as deepeval scores it)
     - `0` - It is not JSON, or does not match
  2. **Reason** - A match gets deepeval's fixed reason, `"The generated
     Json matches and is syntactically correct to the expected schema."`,
     without a judge call; otherwise the judge compares the output with the
     schema (`DeepEvalEx.Prompts.JsonCorrectness.generate_reason/1`)

  The metric is **strict by default**, as deepeval's: the threshold is the
  integer `1` unless `strict_mode: false` is given.

  ## The expected schema

  deepeval takes a pydantic model and validates with its
  `model_validate_json`, printing its `model_json_schema()` in the reason
  prompt. DeepEvalEx takes that JSON Schema itself, and validates with
  `DeepEvalEx.Metrics.Utils.JSONSchema`, which lists the keywords it
  supports. Give it as:

  - a JSON string, decoded keeping its key order, so the reason prompt
    prints it exactly as deepeval prints the model's schema (paste
    `json.dumps(Model.model_json_schema())` to match deepeval byte for
    byte)
  - a `Jason.OrderedObject`, likewise
  - a map, with string or atom keys, printed in map order

  Validation follows JSON Schema rather than pydantic's lax mode, which
  also accepts numeric strings for numbers and `"yes"` or `1` for booleans
  (see `DeepEvalEx.Metrics.Utils.JSONSchema`). Peri schemas, the library's
  own, are not accepted: they cannot be printed as the JSON Schema deepeval
  shows the judge.

  ## Usage

  ```elixir
  alias DeepEvalEx.{TestCase, Metrics.JsonCorrectness}

  schema = ~S({
    "properties": {"name": {"type": "string"}, "age": {"type": "integer"}},
    "required": ["name", "age"],
    "title": "Person",
    "type": "object"
  })

  test_case = TestCase.new!(
    input: "Return the customer's profile as JSON.",
    actual_output: ~s({"name": "Ana", "age": 30})
  )

  {:ok, result} = JsonCorrectness.measure(test_case, expected_schema: schema)

  result.score   # => 1
  result.success # => true
  ```

  ## Options

  - `:expected_schema` - The JSON Schema the output must match (required),
    see "The expected schema"
  - `:strict_mode` - Force the threshold to `1` (default: **true**, as
    deepeval's)
  - `:threshold` - Minimum passing score when not strict (default: 0.5)
  - `:include_reason` - Explain the score (default: true)
  - `:model` - LLM model for the reason
  - `:evaluation_template` - A module overriding some of the prompts, see
    `DeepEvalEx.Prompts.EvaluationTemplate` (default: `nil`, deepeval's
    templates)
  - `:verbose_mode` - Print the result's `:verbose_logs` after measuring
    (default: false)
  - `:eval_mode` - see "Eval Modes"

  Measuring without `:expected_schema`, or with one that is not a JSON
  object, raises `ArgumentError`, as deepeval's constructor requires its
  model.

  ## As a configured metric

  The schema belongs to the metric, as in deepeval's
  `JsonCorrectnessMetric(expected_schema=...)`. To evaluate with other
  metrics, or two schemas at once, build the metric with `new/1` and pass
  the struct to `DeepEvalEx.evaluate/3`; its fields take precedence over
  the run's options:

  ```elixir
  metric = JsonCorrectness.new(expected_schema: schema)
  DeepEvalEx.evaluate(test_cases, [metric, DeepEvalEx.Metrics.AnswerRelevancy])
  ```

  ## Eval Modes

  As in deepeval, the score is decided in code in every mode, so System One
  has nothing to decide: `system_one_eval_spec/2` returns `nil` and no
  System One model is built or asked (`system_one_model?/0`), so no
  TypeSafe key is needed.

  - `:llm` and `:hybrid` - the LLM judge explains a failure
  - `:system_one` - there is no LLM: the reason of a failure is the
    validation error (`DeepEvalEx.Metrics.Utils.JSONSchema.validate_json/2`),
    as deepeval's is pydantic's, and the result has no evaluation model and
    a zero cost

  Under `evaluate/3` a `:system_one` JsonCorrectness counts towards batching
  its test case's `:system_one` metrics, as in deepeval, but asks nothing in
  the batch.
  """

  use DeepEvalEx.Metrics.BaseMetric, default_threshold: 0.5

  alias DeepEvalEx.{
    LLM.Adapter,
    Metrics.BaseMetric,
    Metrics.Utils.JSONSchema,
    Metrics.Utils.Verbose
  }

  alias DeepEvalEx.Prompts.EvaluationTemplate
  alias DeepEvalEx.Prompts.JsonCorrectness, as: Template
  alias DeepEvalEx.Schemas.MetricOutputs.JsonCorrectness, as: Schema
  alias DeepEvalEx.SystemOne.Context

  @correct_reason "The generated Json matches and is syntactically correct to the expected schema."

  @enforce_keys [:expected_schema]
  defstruct [
    :expected_schema,
    :threshold,
    :strict_mode,
    :include_reason,
    :model,
    :verbose_mode,
    :flaky,
    :eval_mode,
    :evaluation_template
  ]

  @type t :: %__MODULE__{
          expected_schema: map() | Jason.OrderedObject.t(),
          threshold: number() | nil,
          strict_mode: boolean(),
          include_reason: boolean() | nil,
          model: term(),
          verbose_mode: boolean() | nil,
          flaky: boolean() | nil,
          eval_mode: atom() | String.t() | nil,
          evaluation_template: module() | nil
        }

  @doc """
  Creates a JsonCorrectness metric for `DeepEvalEx.evaluate/3`, as
  deepeval's constructor: strict unless `strict_mode: false`, its threshold
  then the integer `1`, its schema normalised (see "The expected schema").
  The other options left unset (`nil`) fall back to the run's options.

  Raises `ArgumentError`, as deepeval's constructor requires its model,
  when `:expected_schema` is missing or not a JSON object.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    opts = Keyword.merge(default_opts(), opts)

    %__MODULE__{
      expected_schema: expected_schema!(opts),
      threshold: BaseMetric.threshold(opts, default_threshold()),
      strict_mode: Keyword.fetch!(opts, :strict_mode),
      include_reason: Keyword.get(opts, :include_reason),
      model: Keyword.get(opts, :model),
      verbose_mode: Keyword.get(opts, :verbose_mode),
      flaky: Keyword.get(opts, :flaky),
      eval_mode: Keyword.get(opts, :eval_mode),
      evaluation_template: Keyword.get(opts, :evaluation_template)
    }
  end

  @doc """
  deepeval's constructor defaults that differ from every metric's:
  `strict_mode: true`.
  """
  @impl true
  def default_opts, do: [strict_mode: true]

  @impl true
  def metric_name, do: "Json Correctness"

  @impl true
  def required_params, do: [:input, :actual_output]

  @doc """
  Returns the judge model this metric calls with `opts`.
  """
  @impl true
  defdelegate evaluation_model(opts), to: Adapter, as: :model_name

  @doc """
  Always `nil`, deepeval's `_system_one_eval_spec`: the score is decided in
  code by validating the output against the schema, so System One has
  nothing to decide. Exporting it keeps the metric on `:system_one`, where
  it has no LLM (see "Eval Modes").
  """
  @impl true
  def system_one_eval_spec(_test_case, _opts), do: nil

  @doc """
  `false`: deepeval's JsonCorrectness never builds a System One model, so
  none is resolved or initialised for it in any mode.
  """
  @impl true
  def system_one_model?, do: false

  @doc """
  Measures whether the actual output is JSON matching `:expected_schema`.
  """
  def do_measure(test_case, opts) do
    schema = expected_schema!(opts)
    threshold = BaseMetric.threshold(opts, default_threshold())
    actual_output = test_case.actual_output

    {score, validation_error} =
      case JSONSchema.validate_json(actual_output, schema) do
        :ok -> {1, nil}
        {:error, message} -> {0, message}
      end

    with {:ok, reason} <- reason(score, validation_error, actual_output, schema, opts) do
      verbose_logs =
        Verbose.construct_verbose_logs(
          metric_name(),
          [
            "LLM outputed Json:\n#{actual_output}",
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
         metadata: %{validation_error: validation_error}
       )}
    end
  end

  # deepeval's generate_reason: none when not asked, the fixed reason for a
  # match, the validation error without an LLM (:system_one), else the
  # judge's.
  defp reason(score, validation_error, actual_output, schema, opts) do
    cond do
      Keyword.get(opts, :include_reason, true) == false -> {:ok, nil}
      score == 1 -> {:ok, @correct_reason}
      not llm?(opts) -> {:ok, validation_error}
      true -> generate_reason(actual_output, schema, opts)
    end
  end

  defp llm?(opts), do: not match?(%Context{llm?: false}, Keyword.get(opts, :system_one))

  defp generate_reason(actual_output, schema, opts) do
    prompt =
      EvaluationTemplate.render(opts, Template, :generate_reason,
        actual_output: actual_output,
        expected_schema: schema,
        is_valid_json: false
      )

    case Adapter.generate_with_schema(prompt, Schema.reason_schema(), opts) do
      {:ok, response} -> Schema.parse_reason(response)
      {:error, _} = error -> error
    end
  end

  defp expected_schema!(opts) do
    case Keyword.get(opts, :expected_schema) do
      nil ->
        raise ArgumentError,
              "JsonCorrectness requires an :expected_schema (a JSON Schema: a JSON string or a map)."

      schema ->
        JSONSchema.normalize!(schema)
    end
  end
end
