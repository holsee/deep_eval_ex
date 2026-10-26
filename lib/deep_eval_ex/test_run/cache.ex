# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/test_run/cache.py and deepeval/utils.py (serialize)
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.TestRun.Cache do
  @moduledoc """
  The test-run cache, deepeval 4.3.1's `test_run/cache.py`: metric results
  and classifications of earlier runs, reused instead of measuring again.

  The cache lives in the cache folder (`.deepeval/` by default, see
  `DeepEvalEx.Config`) as deepeval's `.deepeval-cache.json`, in deepeval's
  format byte for byte, so DeepEvalEx and deepeval read each other's
  files. While a run writes, its own entries are kept in
  `.temp-deepeval-cache.json` too. `DeepEvalEx.TestRun.Cache.Store` reads
  and writes the files for one run; this module is the pure part: keys,
  the file's structs, encoding and matching.

  ## Keys

  An entry is keyed by its test case (`key/2`): the `input`,
  `actual_output`, `expected_output`, `context` and `retrieval_context`
  (a `DeepEvalEx.Schemas.RetrievedContextData` flattened to its context),
  the run's hyperparameters and, when the test case has expectations,
  the expectations and the evidence they are judged on. The key is
  deepeval's `serialize()`: JSON with every object's keys sorted and every
  list sorted by its items' JSON, so the order of `context` does not
  matter. Other test case fields (`name`, `tags`, tools) are not keyed.

  ## Entries

  Each entry (`CachedTestCase`) holds the error-free metric data of the
  run that wrote it, each with its metric's configuration
  (`MetricConfiguration`, see `metric_configuration/3`), and its error-free
  classifications with their classifier's configuration. A metric's cached
  data is reused only for a metric of the same name whose configuration
  matches (`same_metric_config?/2`): its threshold, strict mode, judge
  (`evaluation_model`, so a System One model's results never serve the
  LLM's), `include_reason` and its own settings, such as GEval's criteria.

  Cached rows cost `0`: a reused result reports `evaluation_cost: 0.0` and
  no token counts.
  """

  alias DeepEvalEx.{Classification, Classifier, ConversationalTestCase, Result, TestCase, TestRun}
  alias DeepEvalEx.Dataset.Expectations
  alias DeepEvalEx.Metrics.BaseMetric
  alias DeepEvalEx.Schemas.RetrievedContextData
  alias DeepEvalEx.TestRun.{ExpectationsData, JSON, MetricData}
  alias Jason.OrderedObject

  @cache_file ".deepeval-cache.json"
  @temp_cache_file ".temp-deepeval-cache.json"

  defmodule MetricConfiguration do
    @moduledoc """
    The configuration a cached metric result was measured with, deepeval's
    `MetricConfiguration`. Fields are deepeval's, in its order; `nil` ones
    are not written. `:evaluation_params` are deepeval's parameter names
    (`"actual_output"`).
    """

    @type t :: %__MODULE__{
            threshold: float() | nil,
            evaluation_model: String.t() | nil,
            strict_mode: boolean(),
            criteria: String.t() | nil,
            include_reason: boolean() | nil,
            n: integer() | nil,
            evaluation_steps: [String.t()] | nil,
            assessment_questions: [String.t()] | nil,
            embeddings: String.t() | nil,
            evaluation_params: [String.t()] | nil
          }

    defstruct [
      :threshold,
      :evaluation_model,
      :criteria,
      :include_reason,
      :n,
      :evaluation_steps,
      :assessment_questions,
      :embeddings,
      :evaluation_params,
      strict_mode: false
    ]

    @doc false
    @spec fields() :: [atom()]
    def fields do
      [:threshold, :evaluation_model, :strict_mode, :criteria, :include_reason, :n] ++
        [:evaluation_steps, :assessment_questions, :embeddings, :evaluation_params]
    end
  end

  defmodule CachedMetricData do
    @moduledoc "A cached metric result with its configuration, deepeval's `CachedMetricData`."

    @type t :: %__MODULE__{
            metric_data: MetricData.t(),
            metric_configuration: MetricConfiguration.t()
          }

    @enforce_keys [:metric_data, :metric_configuration]
    defstruct [:metric_data, :metric_configuration]
  end

  defmodule ClassifierConfiguration do
    @moduledoc """
    The configuration a cached classification was made with, deepeval's
    `ClassifierConfiguration`: the classifier's labels (names and
    descriptions), judge, `include_reason` and `allow_none`.
    """

    @type t :: %__MODULE__{
            labels: [Classifier.label()],
            evaluation_model: String.t() | nil,
            include_reason: boolean(),
            allow_none: boolean()
          }

    @enforce_keys [:labels]
    defstruct [:labels, :evaluation_model, include_reason: true, allow_none: false]
  end

  defmodule CachedClassification do
    @moduledoc "A cached classification with its configuration, deepeval's `CachedClassification`."

    @type t :: %__MODULE__{
            classification: Classification.t(),
            classifier_configuration: ClassifierConfiguration.t()
          }

    @enforce_keys [:classification, :classifier_configuration]
    defstruct [:classification, :classifier_configuration]
  end

  defmodule CachedTestCase do
    @moduledoc "One cache entry, deepeval's `CachedTestCase`."

    @type t :: %__MODULE__{
            cached_metrics_data: [CachedMetricData.t()],
            cached_classifications: [CachedClassification.t()],
            hyperparameters: String.t() | nil
          }

    defstruct cached_metrics_data: [], cached_classifications: [], hyperparameters: nil
  end

  defmodule CachedTestRun do
    @moduledoc """
    A cache file, deepeval's `CachedTestRun`: its entries as
    `{key, CachedTestCase}` pairs, in the file's order.
    """

    @type t :: %__MODULE__{
            test_cases_lookup_map: [{String.t(), CachedTestCase.t()}]
          }

    defstruct test_cases_lookup_map: []
  end

  @doc "The cache file's name in the cache folder, deepeval's `CACHE_FILE_NAME`."
  @spec cache_file() :: String.t()
  def cache_file, do: @cache_file

  @doc "The running run's cache file, deepeval's `TEMP_CACHE_FILE_NAME`."
  @spec temp_cache_file() :: String.t()
  def temp_cache_file, do: @temp_cache_file

  ## Keys

  @doc """
  The key of `test_case`'s entry under the run's `hyperparameters` (a map,
  or `nil`), deepeval's `serialize(cache_dict)`; see "Keys".

  ## Examples

      iex> test_case = %DeepEvalEx.TestCase{input: "Q", actual_output: "A", context: ["b", "a"]}
      iex> DeepEvalEx.TestRun.Cache.key(test_case, nil)
      ~s({"actual_output": "A", "context": ["a", "b"], "expected_output": null, "hyperparameters": null, "input": "Q", "retrieval_context": null})
  """
  @spec key(TestCase.t(), map() | nil) :: String.t()
  def key(%TestCase{} = test_case, hyperparameters) do
    fields = [
      {"input", test_case.input},
      {"actual_output", test_case.actual_output},
      {"expected_output", test_case.expected_output},
      {"context", test_case.context},
      {"retrieval_context", retrieval_context(test_case.retrieval_context)},
      {"hyperparameters", hyperparameters}
    ]

    fields =
      if Expectations.present?(test_case.expectations),
        do:
          fields ++
            [
              {"expectations", expectations_dump(test_case.expectations)},
              {"expectation_evidence", Expectations.evidence(test_case)}
            ],
        else: fields

    fields |> OrderedObject.new() |> serialize()
  end

  @doc false
  # deepeval's utils.serialize: json.dumps(serialize_dict_with_sorting(obj),
  # sort_keys=True). Objects (maps, ordered objects) get their keys sorted
  # and lists their items sorted by json.dumps(item), recursively.
  @spec serialize(term()) :: String.t()
  def serialize(term), do: term |> sorted() |> JSON.encode!()

  defp sorted(%OrderedObject{values: values}), do: sorted_object(values)
  defp sorted(%_{} = struct), do: struct
  defp sorted(map) when is_map(map), do: sorted_object(Map.to_list(map))

  defp sorted(list) when is_list(list) do
    list
    |> Enum.map(&sorted/1)
    |> Enum.sort_by(&JSON.encode!/1)
  end

  defp sorted(term), do: term

  defp sorted_object(pairs) do
    pairs
    |> Enum.map(fn {key, value} -> {to_string(key), sorted(value)} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> OrderedObject.new()
  end

  # deepeval keys a RetrievedContextData by its context, and an empty
  # retrieval context as None.
  defp retrieval_context(nil), do: nil
  defp retrieval_context([]), do: nil

  defp retrieval_context(items) do
    Enum.map(items, fn
      %RetrievedContextData{context: context} -> context
      text -> text
    end)
  end

  # Expectations.model_dump(mode="json"): every field, nil included.
  defp expectations_dump(expectations) do
    OrderedObject.new([
      {"model", expectations.model},
      {"eval_mode", expectations.eval_mode && Atom.to_string(expectations.eval_mode)},
      {"must", expectations.must},
      {"must_not", expectations.must_not}
    ])
  end

  ## The file

  @doc """
  The bytes deepeval's `CachedTestRun.save` writes for `cached_test_run`:
  `model_dump(by_alias=True, exclude_none=True)` through `json.dump`.

  Metric data and classifications take their camelCase aliases, the rest
  deepeval's snake_case field names. The cost of a row cached by this run
  is the integer `0`, as deepeval assigns it.
  """
  @spec encode!(CachedTestRun.t()) :: String.t()
  def encode!(%CachedTestRun{test_cases_lookup_map: entries}) do
    JSON.encode!(
      OrderedObject.new([
        {"test_cases_lookup_map",
         OrderedObject.new(Enum.map(entries, fn {key, entry} -> {key, entry_map(entry)} end))}
      ])
    )
  end

  defp entry_map(%CachedTestCase{} = entry) do
    without_nils([
      {"cached_metrics_data", Enum.map(entry.cached_metrics_data, &cached_metric_data_map/1)},
      {"cached_classifications",
       Enum.map(entry.cached_classifications, &cached_classification_map/1)},
      {"hyperparameters", entry.hyperparameters}
    ])
  end

  defp cached_metric_data_map(%CachedMetricData{} = cached) do
    OrderedObject.new([
      {"metric_data", metric_data_map(cached.metric_data)},
      {"metric_configuration", metric_configuration_map(cached.metric_configuration)}
    ])
  end

  # TestRun's metric data, but a row cached by this run keeps its integer 0.
  defp metric_data_map(%MetricData{evaluation_cost: cost} = data) do
    %OrderedObject{values: values} = TestRun.metric_data_to_map(data)

    if is_integer(cost),
      do:
        OrderedObject.new(List.keyreplace(values, "evaluationCost", 0, {"evaluationCost", cost})),
      else: OrderedObject.new(values)
  end

  @doc false
  # A metric configuration as the cache file writes it.
  @spec configuration_to_map(MetricConfiguration.t()) :: OrderedObject.t()
  def configuration_to_map(configuration), do: metric_configuration_map(configuration)

  @doc false
  # A decoded metric_configuration object, as decode/1 reads it.
  @spec configuration_from_map(map()) :: MetricConfiguration.t()
  def configuration_from_map(configuration) do
    %MetricConfiguration{
      threshold: to_float(configuration["threshold"]),
      evaluation_model: configuration["evaluation_model"],
      strict_mode: configuration["strict_mode"] || false,
      criteria: configuration["criteria"],
      include_reason: configuration["include_reason"],
      n: configuration["n"],
      evaluation_steps: configuration["evaluation_steps"],
      assessment_questions: configuration["assessment_questions"],
      embeddings: configuration["embeddings"],
      evaluation_params: configuration["evaluation_params"]
    }
  end

  defp metric_configuration_map(%MetricConfiguration{} = configuration) do
    MetricConfiguration.fields()
    |> Enum.map(fn
      :threshold -> {"threshold", to_float(configuration.threshold)}
      field -> {Atom.to_string(field), Map.fetch!(configuration, field)}
    end)
    |> without_nils()
  end

  defp cached_classification_map(%CachedClassification{} = cached) do
    %OrderedObject{values: values} = Classification.to_map(cached.classification)

    values =
      case cached.classification.evaluation_cost do
        cost when is_integer(cost) ->
          List.keyreplace(values, "evaluationCost", 0, {"evaluationCost", cost})

        _cost ->
          values
      end

    OrderedObject.new([
      {"classification", without_nils(values)},
      {"classifier_configuration", classifier_configuration_map(cached.classifier_configuration)}
    ])
  end

  defp classifier_configuration_map(%ClassifierConfiguration{} = configuration) do
    without_nils([
      {"labels",
       Enum.map(configuration.labels, fn {name, description} ->
         without_nils([{"name", name}, {"description", description}])
       end)},
      {"evaluation_model", configuration.evaluation_model},
      {"include_reason", configuration.include_reason},
      {"allow_none", configuration.allow_none}
    ])
  end

  defp without_nils(pairs),
    do: pairs |> Enum.reject(fn {_key, value} -> is_nil(value) end) |> OrderedObject.new()

  @doc """
  Reads a cache file's contents, deepeval's `CachedTestRun.load`.

  Values are coerced as deepeval's pydantic models load them (a metric's
  `threshold`, `score` and `evaluationCost` become floats). Contents that
  are not a valid cache file are read as an empty cache, as deepeval
  starts a new one.
  """
  @spec decode(binary()) :: CachedTestRun.t()
  def decode(binary) when is_binary(binary) do
    with {:ok, %OrderedObject{} = object} <- Jason.decode(binary, objects: :ordered_objects),
         {:ok, entries} <- decode_entries(object["test_cases_lookup_map"]) do
      %CachedTestRun{test_cases_lookup_map: entries}
    else
      _invalid -> %CachedTestRun{}
    end
  end

  defp decode_entries(nil), do: {:ok, []}

  defp decode_entries(%OrderedObject{values: values}) do
    {:ok, Enum.map(values, fn {key, entry} -> {key, decode_entry!(entry)} end)}
  rescue
    _invalid -> :error
  end

  defp decode_entries(_other), do: :error

  defp decode_entry!(%OrderedObject{} = entry) do
    %CachedTestCase{
      cached_metrics_data: Enum.map(entry["cached_metrics_data"] || [], &decode_metric_data!/1),
      cached_classifications:
        Enum.map(entry["cached_classifications"] || [], &decode_classification!/1),
      hyperparameters: entry["hyperparameters"]
    }
  end

  defp decode_metric_data!(%OrderedObject{} = cached) do
    {:ok, data} = TestRun.metric_data_from_map(cached["metric_data"])

    %CachedMetricData{
      metric_data: %{
        data
        | threshold: to_float(data.threshold),
          score: to_float(data.score),
          evaluation_cost: to_float(data.evaluation_cost)
      },
      metric_configuration: configuration_from_map(cached["metric_configuration"])
    }
  end

  defp decode_classification!(%OrderedObject{} = cached) do
    classification = cached["classification"]
    configuration = cached["classifier_configuration"]

    %CachedClassification{
      classification: %Classification{
        name: classification["name"],
        label: classification["label"],
        expected_label: classification["expectedLabel"],
        success: classification["success"],
        reason: classification["reason"],
        evaluation_model: classification["evaluationModel"],
        error: classification["error"],
        evaluation_cost: to_float(classification["evaluationCost"]),
        input_tokens: classification["inputTokenCount"],
        output_tokens: classification["outputTokenCount"]
      },
      classifier_configuration: %ClassifierConfiguration{
        labels: Enum.map(configuration["labels"], &{&1["name"], &1["description"]}),
        evaluation_model: configuration["evaluation_model"],
        include_reason:
          if(is_nil(configuration["include_reason"]),
            do: true,
            else: configuration["include_reason"]
          ),
        allow_none: configuration["allow_none"] || false
      }
    }
  end

  @doc """
  The entry under `key`, or `nil`.
  """
  @spec get(CachedTestRun.t(), String.t()) :: CachedTestCase.t() | nil
  def get(%CachedTestRun{test_cases_lookup_map: entries}, key) do
    case List.keyfind(entries, key, 0) do
      {^key, entry} -> entry
      nil -> nil
    end
  end

  ## Metrics

  @doc """
  The configuration of a metric `module` measuring with `opts` (the
  options it measures with, see `DeepEvalEx.Evaluator`), deepeval's
  `create_metric_configuration`: before measuring when `result` is `nil`,
  else as the measure that returned `result` left it.

  The fields every metric has come from `opts`: the threshold (`1` in
  strict mode), the judge (the LLM's name, or the System One model's
  under `:system_one`; after measuring, the result's), `strict_mode` and
  `include_reason` (default `true`, as deepeval's metrics take it). A
  metric module adds its own settings with the optional
  `c:DeepEvalEx.Metrics.BaseMetric.cache_configuration/2` callback; one
  that takes no `include_reason`, as deepeval's ExactMatch or GEval, sets
  it to `false` there.
  """
  @spec metric_configuration(module(), keyword(), Result.t() | nil) :: MetricConfiguration.t()
  def metric_configuration(module, opts, result \\ nil) do
    defaults = %{
      threshold: threshold(module, opts),
      evaluation_model: evaluation_model(module, opts, result),
      strict_mode: Keyword.get(opts, :strict_mode, false),
      include_reason: Keyword.get(opts, :include_reason, true)
    }

    overrides =
      if exported?(module, :cache_configuration, 2),
        do: module.cache_configuration(opts, result),
        else: %{}

    struct!(MetricConfiguration, Map.merge(defaults, overrides))
  end

  defp threshold(module, opts) do
    default = if exported?(module, :default_threshold, 0), do: module.default_threshold()
    opts |> BaseMetric.threshold(default) |> to_float()
  end

  defp evaluation_model(_module, _opts, %Result{evaluation_model: model}), do: model

  defp evaluation_model(module, opts, nil),
    do: BaseMetric.usage_fields(module, opts, []).evaluation_model

  @doc """
  Whether a metric configured as `current` (its configuration before
  measuring) may reuse a result cached with `cached`, deepeval's
  `same_metric_configs`.

  Compares the threshold, judge, strict mode, `include_reason`, `n`,
  `embeddings`, `evaluation_params` and `assessment_questions`. The
  evaluation steps are compared when the metric has some; otherwise its
  criteria are (GEval's), and a metric with neither skips the check. As in
  deepeval, settings a metric only gets while measuring (GEval's generated
  steps, Summarization's generated assessment questions) are compared too:
  a Summarization that generated its questions is never reused.
  """
  @spec same_metric_config?(MetricConfiguration.t(), MetricConfiguration.t()) :: boolean()
  def same_metric_config?(%MetricConfiguration{} = current, %MetricConfiguration{} = cached) do
    compared = [
      :threshold,
      :evaluation_model,
      :strict_mode,
      :include_reason,
      :n,
      :embeddings,
      :evaluation_params,
      :assessment_questions
    ]

    Enum.all?(compared, &same?(Map.fetch!(current, &1), Map.fetch!(cached, &1))) and
      same_steps?(current, cached)
  end

  defp same_steps?(%{evaluation_steps: steps}, cached) when not is_nil(steps),
    do: steps == cached.evaluation_steps

  defp same_steps?(%{criteria: criteria}, cached) when not is_nil(criteria),
    do: criteria == cached.criteria

  defp same_steps?(_current, _cached), do: true

  # Python's ==: 1 == 1.0.
  defp same?(a, b) when is_number(a) and is_number(b), do: a == b
  defp same?(a, b), do: a === b

  @doc """
  The cached data of the metric named `name` and configured as `current`
  in `cached_test_case`, deepeval's `Cache.get_metric_data`: the first row
  of that name whose configuration matches (`same_metric_config?/2`), or
  `nil`. `nil` too without an entry.
  """
  @spec metric_data(String.t(), MetricConfiguration.t(), CachedTestCase.t() | nil) ::
          CachedMetricData.t() | nil
  def metric_data(_name, _current, nil), do: nil

  def metric_data(name, %MetricConfiguration{} = current, %CachedTestCase{} = cached_test_case) do
    Enum.find(cached_test_case.cached_metrics_data, fn cached ->
      cached.metric_data.name == name and
        same_metric_config?(current, cached.metric_configuration)
    end)
  end

  @doc """
  The cache row of a measured, error-free `result` with its metric's
  `configuration`: its metric data, cost `0`.
  """
  @spec cached_metric_data(Result.t(), MetricConfiguration.t()) :: CachedMetricData.t()
  def cached_metric_data(%Result{} = result, %MetricConfiguration{} = configuration) do
    %CachedMetricData{
      metric_data: %{MetricData.from_result(result) | evaluation_cost: 0},
      metric_configuration: configuration
    }
  end

  @doc """
  The result a metric reports when it reuses `cached`, as deepeval's
  evaluation copies a cached row onto the metric: its score, threshold,
  success, reason, strict mode, judge and verbose logs, its cost (`0.0`)
  and no token counts, with the metric's current `flaky`. An expectation
  evaluator's result also gets its cached expectations data, at the same
  cost.
  """
  @spec cached_result(CachedMetricData.t(), boolean()) :: Result.t()
  def cached_result(%CachedMetricData{metric_data: data}, flaky) do
    cost = to_float(data.evaluation_cost)
    result = MetricData.to_result(data)

    expectations_data =
      if data.expectations_data,
        do: %{ExpectationsData.from_map(data.expectations_data) | evaluation_cost: cost}

    %{
      result
      | evaluation_cost: cost,
        input_tokens: nil,
        output_tokens: nil,
        flaky: flaky,
        expectations_data: expectations_data
    }
  end

  @doc """
  The metric configuration a reused result is cached with again: the
  metric's configuration before measuring, with the threshold, strict mode
  and judge of the row it reused, as deepeval caches the metric its cached
  row was copied onto.
  """
  @spec reused_configuration(MetricConfiguration.t(), CachedMetricData.t()) ::
          MetricConfiguration.t()
  def reused_configuration(%MetricConfiguration{} = current, %CachedMetricData{metric_data: data}) do
    %{
      current
      | threshold: to_float(data.threshold),
        strict_mode: data.strict_mode,
        evaluation_model: data.evaluation_model
    }
  end

  ## Classifications

  @doc """
  The configuration of `classifier` under the run's `opts`, deepeval's
  `Cache.create_classifier_configuration`: its labels with their
  descriptions, its judge, `include_reason` and `allow_none`.
  """
  @spec classifier_configuration(Classifier.t(), keyword()) :: ClassifierConfiguration.t()
  def classifier_configuration(%Classifier{} = classifier, opts) do
    %ClassifierConfiguration{
      labels: classifier.labels,
      evaluation_model: Classifier.configured_model(classifier, opts),
      include_reason: classifier.include_reason,
      allow_none: classifier.allow_none
    }
  end

  @doc """
  The cached classification of the classifier named `name` and configured
  as `configuration` in `cached_test_case`, deepeval's
  `Cache.get_classification`: same name, same configuration and no error;
  `nil` otherwise.
  """
  @spec classification(String.t(), ClassifierConfiguration.t(), CachedTestCase.t() | nil) ::
          CachedClassification.t() | nil
  def classification(_name, _configuration, nil), do: nil

  def classification(name, %ClassifierConfiguration{} = configuration, cached_test_case) do
    Enum.find(cached_test_case.cached_classifications, fn cached ->
      cached.classification.name == name and is_nil(cached.classification.error) and
        cached.classifier_configuration == configuration
    end)
  end

  @doc """
  The classification reused from `cached` on `test_case`, as deepeval's
  `hydrate_classifier_from_cache` then `create_classification`: the cached
  label, reason, judge, cost and token counts, with the expected label of
  `test_case` and the verdict against it recomputed.
  """
  @spec cached_classification_result(
          CachedClassification.t(),
          TestCase.t() | ConversationalTestCase.t()
        ) :: Classification.t()
  def cached_classification_result(%CachedClassification{classification: cached}, test_case) do
    expected = Classifier.expected_label(test_case, cached.name)
    classification = %{cached | expected_label: expected, error: nil}
    %{classification | success: Classifier.success(classification, expected)}
  end

  @doc """
  The cache row of an error-free `classification` with its classifier's
  `configuration`, cost `0`.
  """
  @spec cached_classification(Classification.t(), ClassifierConfiguration.t()) ::
          CachedClassification.t()
  def cached_classification(%Classification{} = classification, configuration) do
    %CachedClassification{
      classification: %{classification | evaluation_cost: 0},
      classifier_configuration: configuration
    }
  end

  defp exported?(module, function, arity),
    do: Code.ensure_loaded?(module) and function_exported?(module, function, arity)

  defp to_float(nil), do: nil
  defp to_float(number) when is_number(number), do: number / 1
  defp to_float(other), do: other
end
