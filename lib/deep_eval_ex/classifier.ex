# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/classifiers/base_classifier.py and
# deepeval/classifiers/classifier/classifier.py
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.Classifier do
  @moduledoc """
  A classifier assigns a test case exactly one label from a closed set,
  deepeval 4.3.1's `Classifier` (and `BaseClassifier`).

  Unlike a metric it has no score or threshold. It only passes or fails
  when the test case declares the label it expects, in
  `expected_labels[classifier.name]`; otherwise its `DeepEvalEx.Classification`
  has `success: nil`, as a score-only metric's result does.

      refusal =
        DeepEvalEx.Classifier.new!(
          name: "refusal",
          labels: [
            {"complied", "The response answers the request."},
            {"refused", "The response declines the request."}
          ]
        )

      test_case =
        DeepEvalEx.TestCase.new!(
          input: "Tell me the exam answers.",
          actual_output: "I can't share those.",
          expected_labels: %{"refusal" => "refused"}
        )

      DeepEvalEx.Classifier.classify(refusal, test_case)
      #=> %DeepEvalEx.Classification{name: "refusal", label: "refused", success: true, ...}

      DeepEvalEx.evaluate([test_case], [], classifiers: [refusal])

  `DeepEvalEx.Classifiers` builds deepeval's thirteen built-in classifiers.

  ## Labels

  A label is a name, or a name with a description: the description is the
  label's boundary, as G-Eval's criteria are a score's. Labels are kept as
  `{name, description}` pairs (see `DeepEvalEx.Classifier.Utils.normalize_labels!/1`).
  `"NONE"` is reserved: with `allow_none: true` the judge may decline to
  classify, which gives `label: nil` and no error.

  ## Eval modes

  The eval mode is `DeepEvalEx.SystemOne.Mode.for_classifier/1` of
  `:eval_mode`: a classifier has no `:hybrid`, which runs it as `:llm`.

  - `:llm` - one schema call to the LLM judge over
    `DeepEvalEx.Prompts.Classifier.classify_single_turn/1` (or
    `classify_multi_turn/1` for a `DeepEvalEx.ConversationalTestCase`),
    answering `label` and `reason`
  - `:system_one` - one Choice question, keyed `"label"`, to the System One
    model, its options the labels (and `NONE` with `allow_none`), its state
    the test case's populated fields. The reason is
    `DeepEvalEx.SystemOne.Scoring.classification_reason/2`. Nothing falls
    back to the LLM, and classifiers are never batched with metrics

  In both modes the answer is then resolved onto a declared label
  (`DeepEvalEx.Classifier.Utils.resolve_label/3`); an answer that matches
  none is recorded as the classification's error: `"Judge returned 'x',
  which is not one of the declared labels (a, b)."`.

  Usage is seeded as a metric's: `0` for a native LLM judge or under
  `:system_one`, `nil` for a custom judge.

  ## Custom classifiers

  deepeval's `BaseClassifier` subclasses are modules implementing the
  optional `c:classify/3` callback, given as `:impl`. The callback gets the
  classifier, the test case and the options, and returns the raw label and
  reason, which are resolved as above.

  ## Fields

  - `:name` - The classifier's name, the key of `expected_labels` (required)
  - `:labels` - The `{name, description}` labels (required)
  - `:model`, `:adapter` - The LLM judge (default: the run's, else the
    configured default model), as for metrics
  - `:system_one_model` - The System One model under `:system_one`
  - `:eval_mode` - `:llm` or `:system_one` (`:hybrid` runs as `:llm`;
    default: the run's, else the `:eval_mode` setting, else `:llm`)
  - `:template` - A module overriding the `:llm` prompts, see
    `DeepEvalEx.Prompts.Classifier` (deepeval's `classification_template`)
  - `:impl` - A module implementing `c:classify/3`
  - `:include_reason` - Keep the judge's reason (default: `true`)
  - `:allow_none` - Let the judge decline to classify (default: `false`)

  `:model`, `:adapter`, `:system_one_model`, `:eval_mode` and `:template`
  left `nil` take the options passed to `classify/3` (and the evaluation's
  options), as a metric struct's unset fields do.
  """

  alias DeepEvalEx.{Classification, ConversationalTestCase, DeepEvalError, TestCase}
  alias DeepEvalEx.Classifier.Utils
  alias DeepEvalEx.LLM.{Adapter, Usage}
  alias DeepEvalEx.Metrics.BaseMetric
  alias DeepEvalEx.Prompts.Classifier, as: Prompts
  alias DeepEvalEx.Prompts.{EvaluationTemplate, Python}
  alias DeepEvalEx.SystemOne
  alias DeepEvalEx.SystemOne.{Context, Question, Scoring}
  alias DeepEvalEx.Tracing

  @typedoc "A label: its name and its description, if any."
  @type label :: {name :: String.t(), description :: String.t() | nil}

  @type t :: %__MODULE__{
          name: String.t(),
          labels: [label()],
          model: term(),
          adapter: term(),
          system_one_model: term(),
          eval_mode: term(),
          template: module() | nil,
          impl: module() | nil,
          include_reason: boolean(),
          allow_none: boolean()
        }

  @enforce_keys [:name, :labels]
  defstruct [
    :name,
    :labels,
    :model,
    :adapter,
    :system_one_model,
    :eval_mode,
    :template,
    :impl,
    include_reason: true,
    allow_none: false
  ]

  # Fields that default to the run's options of the same name.
  @run_options [:model, :adapter, :system_one_model, :eval_mode]

  @doc """
  Classifies `test_case` for a custom classifier (`:impl`), as a
  `BaseClassifier` subclass's `classify()`: returns the judge's raw label
  and reason, which `classify/3` resolves onto the declared labels, or an
  error.
  """
  @callback classify(t(), test_case :: struct(), opts :: keyword()) ::
              {:ok, %{label: String.t() | nil, reason: String.t() | nil}} | {:error, term()}

  @optional_callbacks classify: 3

  @doc """
  Builds a classifier from `opts` (see "Fields").

  Raises `ArgumentError` with deepeval's message for a blank `:name` and
  for invalid labels (see `DeepEvalEx.Classifier.Utils.normalize_labels!/1`).

  ## Examples

      iex> classifier = DeepEvalEx.Classifier.new!(name: "tone", labels: ["formal", {"casual", "Relaxed."}])
      iex> classifier.labels
      [{"formal", nil}, {"casual", "Relaxed."}]
  """
  @spec new!(keyword()) :: t()
  def new!(opts) when is_list(opts) do
    name = Keyword.get(opts, :name)

    if not is_binary(name) or String.trim(name) == "" do
      raise ArgumentError, "Classifier 'name' cannot be empty."
    end

    struct!(__MODULE__, Keyword.put(opts, :labels, Utils.normalize_labels!(opts[:labels])))
  end

  @doc """
  The names of the classifier's labels, in order.
  """
  @spec label_names(t()) :: [String.t()]
  def label_names(%__MODULE__{labels: labels}), do: Enum.map(labels, &elem(&1, 0))

  @doc """
  Whether a classification passes against `expected`, deepeval's
  `is_successful`: `nil` without an expected label, `false` for an errored
  classification, else whether its label is the expected one.

  ## Examples

      iex> DeepEvalEx.Classifier.success(%DeepEvalEx.Classification{name: "c", label: "a"}, "a")
      true
      iex> DeepEvalEx.Classifier.success(%DeepEvalEx.Classification{name: "c", label: "a"}, nil)
      nil
  """
  @spec success(Classification.t(), String.t() | nil) :: boolean() | nil
  def success(%Classification{}, nil), do: nil
  def success(%Classification{error: error}, _expected) when not is_nil(error), do: false
  def success(%Classification{label: label}, expected), do: label == expected

  @doc """
  Classifies `test_case`, a `DeepEvalEx.TestCase` or a
  `DeepEvalEx.ConversationalTestCase`, and returns its
  `DeepEvalEx.Classification`, with the test case's expected label (if
  any) and the verdict against it.

  An answer that is not one of the labels is the classification's error.
  A judge that fails (the LLM or System One model errors, or the test case
  has nothing to classify) raises, as deepeval's `classify()` does: the
  exception it raised, else `DeepEvalEx.DeepEvalError`. Evaluating with
  `ignore_errors: true` records the error instead (see
  `DeepEvalEx.Evaluator`).

  The judge's calls are not traced (`DeepEvalEx.Tracing.suppress/1`), as
  a metric's are not.

  ## Options

  Run-level defaults for the fields left `nil` (see "Fields"): `:model`,
  `:adapter`, `:system_one_model`, `:eval_mode` and `:evaluation_template`,
  plus any LLM adapter option. A resolved `DeepEvalEx.SystemOne.Context`
  in `:system_one` is used as it is.
  """
  @spec classify(t(), TestCase.t() | ConversationalTestCase.t(), keyword()) ::
          Classification.t()
  def classify(%__MODULE__{} = classifier, test_case, opts \\ []) do
    case run(classifier, test_case, opts) do
      {:ok, classification} ->
        classification

      {:error, exception, stacktrace, _classification} when is_exception(exception) ->
        reraise exception, stacktrace || []

      {:error, _reason, _stacktrace, classification} ->
        raise DeepEvalError, message: classification.error
    end
  end

  @doc false
  # classify/3 without raising: {:ok, classification}, or {:error, reason,
  # stacktrace | nil, classification} where the classification records the
  # error message (str(exception), as deepeval's evaluation does), the
  # judge and the usage spent before it.
  @spec run(t(), TestCase.t() | ConversationalTestCase.t(), keyword()) ::
          {:ok, Classification.t()}
          | {:error, term(), Exception.stacktrace() | nil, Classification.t()}
  def run(%__MODULE__{} = classifier, test_case, opts) do
    opts = classify_opts(classifier, opts)
    context = context(classifier, opts)
    opts = Keyword.put(opts, :system_one, context)

    # The judge's calls stay out of a user's trace, as deepeval's internal
    # observe on a classifier's methods.
    {outcome, usages} =
      Tracing.suppress(fn ->
        BaseMetric.track_usage(fn ->
          seed(classifier, context, opts)
          decide(classifier, test_case, context, opts)
        end)
      end)

    base = %Classification{
      name: classifier.name,
      expected_label: expected_label(test_case, classifier.name),
      evaluation_model: evaluation_model(classifier, context, opts, usages)
    }

    base = put_usage(base, usages)

    case outcome do
      {:ok, {raw_label, reason}} ->
        {:ok, finalize(classifier, base, raw_label, reason)}

      {:error, reason} ->
        {:error, reason, nil, errored(base, reason)}

      {:raised, exception, stacktrace} ->
        {:error, exception, stacktrace, errored(base, exception)}
    end
  end

  @doc false
  # The classification of a classifier that errored with `reason` before
  # (or without) running: deepeval's create_classification after
  # safe_a_classify recorded str(exception).
  @spec error_classification(t(), struct(), term(), keyword()) :: Classification.t()
  def error_classification(%__MODULE__{} = classifier, test_case, reason, opts) do
    opts = classify_opts(classifier, opts)
    context = context(classifier, opts)

    errored(
      %Classification{
        name: classifier.name,
        expected_label: expected_label(test_case, classifier.name),
        evaluation_model: evaluation_model(classifier, context, opts, [])
      }
      |> put_usage([seed_usage(classifier, context, opts)] |> Enum.reject(&is_nil/1)),
      reason
    )
  end

  @doc false
  # The judge the classifier names before classifying under `opts`
  # (run-level defaults), deepeval's classifier.evaluation_model: the LLM's
  # name, or the System One model's under :system_one; nil for a custom
  # classifier, whose judge is only known once it reports usage.
  @spec configured_model(t(), keyword()) :: String.t() | nil
  def configured_model(%__MODULE__{} = classifier, opts) do
    opts = classify_opts(classifier, opts)
    evaluation_model(classifier, context(classifier, opts), opts, [])
  end

  @doc false
  # The classifier's System One context under `opts` (run-level defaults),
  # resolved before any test case as the Evaluator's preflight does.
  @spec resolve_context!(t(), keyword()) :: Context.t()
  def resolve_context!(%__MODULE__{} = classifier, opts),
    do: context(classifier, classify_opts(classifier, opts))

  # The classifier's fields win over the run's options; its template is the
  # prompts' evaluation_template.
  defp classify_opts(classifier, opts) do
    opts =
      Enum.reduce(@run_options, opts, fn key, opts ->
        case Map.fetch!(classifier, key) do
          nil -> opts
          value -> Keyword.put(opts, key, value)
        end
      end)

    case classifier.template do
      nil -> opts
      template -> Keyword.put(opts, :evaluation_template, template)
    end
  end

  defp context(%__MODULE__{impl: impl}, _opts) when not is_nil(impl), do: %Context{}
  defp context(_classifier, opts), do: Context.resolve_classifier!(opts)

  # deepeval's _reset_usage: zero for a native judge or System One (no
  # LLM), nil for a custom judge. A custom classifier starts from nothing.
  defp seed(classifier, context, opts) do
    case seed_usage(classifier, context, opts) do
      nil -> :ok
      usage -> Usage.record(usage)
    end
  end

  defp seed_usage(%__MODULE__{impl: impl}, _context, _opts) when not is_nil(impl), do: nil
  defp seed_usage(_classifier, %Context{llm?: false}, _opts), do: Usage.seed(true)
  defp seed_usage(_classifier, _context, opts), do: Usage.seed(Adapter.native?(opts))

  # deepeval's (self.model or self.system_one_model).get_model_name().
  defp evaluation_model(%__MODULE__{impl: impl}, _context, _opts, usages) when not is_nil(impl),
    do: (Usage.summarize(usages) || %{evaluation_model: nil}).evaluation_model

  defp evaluation_model(_classifier, %Context{llm?: false, model: model}, _opts, _usages),
    do: model && model.name

  defp evaluation_model(_classifier, _context, opts, _usages), do: Adapter.model_name(opts)

  defp put_usage(classification, usages) do
    case Usage.summarize(usages) do
      nil ->
        classification

      summary ->
        %{
          classification
          | evaluation_cost: summary.evaluation_cost,
            input_tokens: summary.input_tokens,
            output_tokens: summary.output_tokens
        }
    end
  end

  @doc false
  # The test case's expected label for the classifier named `name`, if any.
  @spec expected_label(struct(), String.t()) :: String.t() | nil
  def expected_label(test_case, name),
    do: (Map.get(test_case, :expected_labels) || %{}) |> Map.get(name)

  # Asks the judge: {:ok, {raw_label, reason}} or {:error, reason}.
  defp decide(%__MODULE__{impl: impl} = classifier, test_case, _context, opts)
       when not is_nil(impl) do
    case impl.classify(classifier, test_case, opts) do
      {:ok, %{} = answer} -> {:ok, {Map.get(answer, :label), Map.get(answer, :reason)}}
      {:error, _reason} = error -> error
    end
  end

  defp decide(classifier, test_case, %Context{mode: :system_one} = context, _opts) do
    multi_turn = is_struct(test_case, ConversationalTestCase)

    state =
      if multi_turn,
        do: Utils.multi_turn_state(test_case),
        else: Utils.single_turn_state(test_case)

    question = %Question.Choice{
      instructions:
        Prompts.system_one_classify(allow_none: classifier.allow_none, multi_turn: multi_turn),
      options: options(classifier)
    }

    case SystemOne.choice(state, [{"label", question}],
           system_one_model: context.model,
           mode: :system_one,
           metrics: [classifier.name]
         ) do
      {:ok, %{"label" => answer}, usage} ->
        book(usage)

        reason =
          if classifier.include_reason,
            do: Scoring.classification_reason(context.model.name, answer)

        {:ok, {answer.choice, reason}}

      # Under :system_one nothing falls back: the error surfaces.
      {:error, error} ->
        raise error
    end
  end

  defp decide(classifier, test_case, _context, opts) do
    prompt = prompt(classifier, test_case, opts)

    case Adapter.generate_with_schema(prompt, schema(), opts) do
      {:ok, answer} -> {:ok, {answer["label"], answer["reason"]}}
      {:error, _reason} = error -> error
    end
  end

  defp options(classifier) do
    options = classifier.labels

    if classifier.allow_none,
      do: options ++ [{Utils.none_label(), "None of the other labels apply."}],
      else: options
  end

  # An unpriced request (nil) voids the summed cost, as deepeval's
  # _accrue_cost(None).
  defp book(nil), do: Usage.record(%Usage{source: :system_one})
  defp book(%Usage{} = usage), do: Usage.record(usage)

  defp prompt(classifier, %ConversationalTestCase{} = test_case, opts) do
    EvaluationTemplate.render(opts, Prompts, :classify_multi_turn,
      labels: Utils.format_labels(classifier.labels),
      test_case_content: Utils.multi_turn_content(test_case),
      turns: Utils.turns(test_case),
      allow_none: classifier.allow_none
    )
  end

  defp prompt(classifier, %TestCase{} = test_case, opts) do
    EvaluationTemplate.render(opts, Prompts, :classify_single_turn,
      labels: Utils.format_labels(classifier.labels),
      test_case_content: Utils.single_turn_content(test_case),
      allow_none: classifier.allow_none
    )
  end

  defp prompt(_classifier, test_case, _opts) do
    raise ArgumentError,
          "Classifier expects an LLMTestCase or ConversationalTestCase, got " <>
            "#{inspect(test_case)}."
  end

  # deepeval's ClassificationResult.
  defp schema do
    %{
      "type" => "object",
      "properties" => %{
        "label" => %{"type" => "string"},
        "reason" => %{"type" => "string"}
      },
      "required" => ["label", "reason"],
      "additionalProperties" => false
    }
  end

  # deepeval's _finalize, then create_classification.
  defp finalize(classifier, classification, raw_label, reason) do
    {label, error} =
      case Utils.resolve_label(raw_label, classifier.labels, classifier.allow_none) do
        nil -> {nil, undeclared(classifier, raw_label)}
        "NONE" -> {nil, nil}
        label -> {label, nil}
      end

    reason = if classifier.include_reason and is_nil(error), do: reason

    classification = %{classification | label: label, reason: reason, error: error}
    %{classification | success: success(classification, classification.expected_label)}
  end

  defp undeclared(classifier, raw_label) do
    allowed = Enum.join(label_names(classifier), ", ")
    allowed = if classifier.allow_none, do: allowed <> ", or no classification", else: allowed

    "Judge returned '#{python_str(raw_label)}', which is not one of the declared labels " <>
      "(#{allowed})."
  end

  defp errored(classification, reason) do
    classification = %{classification | label: nil, reason: nil, error: error_message(reason)}
    %{classification | success: success(classification, classification.expected_label)}
  end

  # str(exception), as deepeval's safe_a_classify records it.
  defp error_message(reason) when is_exception(reason), do: Exception.message(reason)
  defp error_message(reason) when is_binary(reason), do: reason
  defp error_message(reason), do: inspect(reason)

  defp python_str(nil), do: "None"
  defp python_str(value) when is_binary(value), do: value
  defp python_str(value), do: Python.repr(value)
end
