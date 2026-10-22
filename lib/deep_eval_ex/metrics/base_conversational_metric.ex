defmodule DeepEvalEx.Metrics.BaseConversationalMetric do
  @moduledoc """
  Behaviour for conversational (multi-turn) metrics, deepeval 4.3.1's
  `BaseConversationalMetric`: metrics that judge a whole
  `DeepEvalEx.ConversationalTestCase` rather than one input and output.

  It is `DeepEvalEx.Metrics.BaseMetric` for conversations. `use` gives a
  conversational metric the same `measure/2` wrapper, with deepeval's
  strict mode, score-only thresholds and flakiness, telemetry, LLM usage
  tracking and cost seeding (deepeval's `prepare_measure`), and the same
  System One hooks (see "System One" in `DeepEvalEx.Metrics.BaseMetric`):

  - the `:eval_mode` and `:system_one_model` options, resolved into the
    `DeepEvalEx.SystemOne.Context` that `do_measure/2` gets as
    `opts[:system_one]`;
  - the optional `c:system_one_eval_spec/2`, deepeval's
    `_system_one_eval_spec`, without which `:system_one` runs as
    `:hybrid`;
  - the optional `c:system_one?/0` and `c:system_one_model?/0`;
  - a fresh `DeepEvalEx.SystemOne.Ledger` per measure, whose confidence
    and fallback reason are set on the result as `:confidence` and
    `:system_one_fallback_reason`.

  What differs is the test case and its validation. `c:required_params/0`
  returns `DeepEvalEx.Params.MultiTurn` params, and `validate_test_case/1`
  checks them with `DeepEvalEx.ConversationalTestCase.validate_params/3`,
  deepeval's `check_conversational_test_case_params`, so a test case that
  lacks one returns its error, rendered with deepeval's message by
  `DeepEvalEx.Result.error/3` and raised by `DeepEvalEx.Evaluator` as a
  `DeepEvalEx.MissingTestCaseParamsError` (or skipped with
  `:skip_on_missing_params`). A test case that is not a
  `DeepEvalEx.ConversationalTestCase` returns
  `{:error, :not_conversational_test_case}`, deepeval's `ValueError`.

  ## Implementing a conversational metric

      defmodule MyApp.Politeness do
        use DeepEvalEx.Metrics.BaseConversationalMetric,
          default_threshold: 0.5,
          requires_chatbot_role: true

        @impl true
        def metric_name, do: "Politeness"

        @impl true
        def required_params, do: [:role, :content]

        def do_measure(test_case, opts) do
          score = score_turns(test_case.turns)

          {:ok,
           DeepEvalEx.Result.new(
             metric: metric_name(),
             score: score,
             threshold: Keyword.get(opts, :threshold, default_threshold())
           )}
        end
      end

  ## `use` options

  - `:default_threshold` - `default_threshold/0` (default: `0.5`; `nil`
    makes the metric score-only by default)
  - `:requires_chatbot_role` - `c:requires_chatbot_role?/0`, deepeval's
    `_requires_chatbot_role`: the test case must have a `:chatbot_role`
    (default: `false`)

  deepeval's `_requires_mcp_servers` has no counterpart, as DeepEvalEx does
  not port MCP servers.
  """

  alias DeepEvalEx.ConversationalTestCase
  alias DeepEvalEx.Metrics.BaseMetric
  alias DeepEvalEx.Params.MultiTurn

  @type test_case :: ConversationalTestCase.t()
  @type opts :: keyword()

  @doc """
  Returns the name of this metric, deepeval's `__name__` for a built-in
  one (e.g. `"Role Adherence"`).
  """
  @callback metric_name() :: String.t()

  @doc """
  Optional callback returning the name of a configured metric struct. See
  `c:DeepEvalEx.Metrics.BaseMetric.metric_name/1`.
  """
  @callback metric_name(metric :: struct()) :: String.t()

  @doc """
  Returns the multi-turn params the metric requires, deepeval's
  `_required_test_case_params`, checked by `validate_test_case/1` (see
  `DeepEvalEx.ConversationalTestCase.validate_params/3` for which are
  checked).
  """
  @callback required_params() :: [MultiTurn.t()]

  @doc """
  Returns whether the test case must have a `:chatbot_role`, deepeval's
  `_requires_chatbot_role`. Set with the `:requires_chatbot_role` `use`
  option.
  """
  @callback requires_chatbot_role?() :: boolean()

  @doc """
  Measures a conversational test case. See
  `c:DeepEvalEx.Metrics.BaseMetric.measure/2`.
  """
  @callback measure(test_case(), opts()) :: BaseMetric.measure_result()

  @doc """
  Optional callback giving the metric's default options. See
  `c:DeepEvalEx.Metrics.BaseMetric.default_opts/0`.
  """
  @callback default_opts() :: keyword()

  @doc """
  Optional callback naming the judge model the metric calls with `opts`.
  See `c:DeepEvalEx.Metrics.BaseMetric.evaluation_model/1`.
  """
  @callback evaluation_model(opts()) :: String.t() | nil

  @doc """
  Optional callback describing how the metric runs as one System One
  request under `:system_one`, deepeval's `_system_one_eval_spec` for a
  `ConversationalTestCase`. See
  `c:DeepEvalEx.Metrics.BaseMetric.system_one_eval_spec/2`.
  """
  @callback system_one_eval_spec(test_case(), opts()) :: DeepEvalEx.SystemOne.EvalSpec.t() | nil

  @doc """
  Optional callback returning `false` for a metric that takes no part in
  System One. See `c:DeepEvalEx.Metrics.BaseMetric.system_one?/0`.
  """
  @callback system_one?() :: boolean()

  @doc """
  Optional callback returning `false` for a metric that follows its eval
  mode but never builds a System One model. See
  `c:DeepEvalEx.Metrics.BaseMetric.system_one_model?/0`.
  """
  @callback system_one_model?() :: boolean()

  @doc """
  Optional callback giving the evaluation model a result reports for the
  judge model `model` (the name the LLM adapter reported, else
  `c:evaluation_model/1`'s), when it names more than the model, as
  `DeepEvalEx.Metrics.ConversationalGEval`'s audio judge.
  """
  @callback describe_evaluation_model(model :: String.t(), opts()) :: String.t()

  @doc """
  Optional callback returning the copy of a metric struct that deepeval's
  asynchronous `evaluate()` would measure (its `copy_metrics` rebuilds each
  metric from its attributes), when it differs from the metric. The
  `DeepEvalEx.Evaluator` measures `copy_metric(metric)` unless
  `run_async: false`, as deepeval's synchronous executor measures the
  metric itself.
  """
  @callback copy_metric(metric :: struct()) :: struct()

  @optional_callbacks [
    describe_evaluation_model: 2,
    copy_metric: 1,
    default_opts: 0,
    metric_name: 1,
    evaluation_model: 1,
    system_one_eval_spec: 2,
    system_one?: 0,
    system_one_model?: 0
  ]

  defmacro __using__(opts \\ []) do
    default_threshold = Keyword.get(opts, :default_threshold, 0.5)
    requires_chatbot_role = Keyword.get(opts, :requires_chatbot_role, false)

    quote do
      @behaviour DeepEvalEx.Metrics.BaseConversationalMetric

      alias DeepEvalEx.{ConversationalTestCase, Result}

      @default_threshold unquote(default_threshold)

      @doc """
      Returns the default threshold for this metric.
      """
      @spec default_threshold() :: number() | nil
      def default_threshold, do: @default_threshold

      def requires_chatbot_role?, do: unquote(requires_chatbot_role)

      @doc """
      Validates that a test case is a conversational test case with what
      this metric requires (see
      `DeepEvalEx.ConversationalTestCase.validate_params/3`).
      """
      @spec validate_test_case(term()) ::
              :ok
              | {:error,
                 ConversationalTestCase.validation_error() | :not_conversational_test_case}
      def validate_test_case(%ConversationalTestCase{} = test_case) do
        ConversationalTestCase.validate_params(test_case, required_params(),
          requires_chatbot_role: requires_chatbot_role?()
        )
      end

      def validate_test_case(_test_case), do: {:error, :not_conversational_test_case}

      @doc """
      Measures a conversational test case with validation and telemetry,
      as `DeepEvalEx.Metrics.BaseMetric`'s `measure/2` measures a
      `DeepEvalEx.TestCase`.
      """
      @spec measure(ConversationalTestCase.t(), keyword()) ::
              {:ok, Result.t()} | {:error, term()}
      def measure(test_case, opts \\ []),
        do: unquote(BaseMetric).run_measure(__MODULE__, test_case, opts)

      @doc """
      Implement this function with your metric logic.

      The `measure/2` callback wraps this with validation and telemetry.
      """
      @spec do_measure(ConversationalTestCase.t(), keyword()) ::
              {:ok, Result.t()} | {:error, term()}
      def do_measure(_test_case, _opts) do
        raise "do_measure/2 not implemented for #{__MODULE__}"
      end

      defoverridable measure: 2,
                     do_measure: 2,
                     validate_test_case: 1,
                     requires_chatbot_role?: 0
    end
  end
end
