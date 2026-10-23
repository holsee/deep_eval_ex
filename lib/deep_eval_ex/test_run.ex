defmodule DeepEvalEx.TestRun do
  @moduledoc """
  A completed evaluation run in deepeval's `TestRun` export format.

  deepeval saves every `evaluate()` call as a `test_run_<timestamp>.json`
  file (see `DeepEvalEx.TestRun.LocalStore`). This module builds the same
  structure from DeepEvalEx results, so tools that read deepeval's exports
  can read DeepEvalEx's too.

      {results, _test_run, _path} = DeepEvalEx.evaluate_run(test_cases, metrics)
      test_run = DeepEvalEx.TestRun.from_results(test_cases, results)

      test_run
      |> DeepEvalEx.TestRun.to_map()
      |> DeepEvalEx.TestRun.JSON.encode!()

  `DeepEvalEx.evaluate_run/3` does all of this, including the timing, and
  writes the file when a results folder is configured.

  ## Fields

  Fields mirror deepeval's `TestRun` (snake_case here, camelCase in the
  export, in this order):

  - `:test_file` - The test file the run came from, or `nil` (`testFile`)
  - `:test_cases` - One `DeepEvalEx.TestRun.TestCase` per evaluated test case
  - `:conversational_test_cases` - One `DeepEvalEx.TestRun.ConversationalTestCase`
    per evaluated `DeepEvalEx.ConversationalTestCase`
  - `:metrics_scores` - Per metric: every score, plus pass, fail and error
    counts, in the order metrics first appear. The metric data of a test
    case's traced spans counts after the test case's own, as deepeval's
    `calculate_metrics_scores` folds it in
  - `:trace_metrics_scores` - The per-span metric scores, as the JSON
    `DeepEvalEx.TestRun.TraceMetricScores.compute/1` builds, or `nil` when
    no traced span has metric data
  - `:identifier` - Optional name for the run
  - `:hyperparameters` - `{name, value}` pairs with values stringified as
    deepeval does (see `process_hyperparameters/1`), or `nil`
  - `:prompts` - deepeval's prompt data, as raw JSON: `[]` for a run built
    by `from_results/3`, as deepeval's `evaluate()` writes without `Prompt`
    hyperparameters, and `nil` (left out of the export) when not set
  - `:test_passed` / `:test_failed` - Number of passing and failing test
    cases; a test case whose `success` is `nil` counts as neither
  - `:run_duration` - Wall-clock time of the whole run, in seconds
  - `:evaluation_cost` - Sum of the test cases' costs; `nil` when no metric
    reported a cost
  - `:dataset_alias`, `:dataset_id`, `:dataset_version` - The dataset the
    test cases came from, or `nil`
  - `:official` - Whether the run is marked official (default: `false`)
  - `:extra` - Keys deepeval does not model either, see "Raw JSON"

  ## Loading deepeval's files

  `load/1` reads a `test_run_<timestamp>.json` written by deepeval (or by
  `DeepEvalEx.TestRun.LocalStore`) back into a test run, and `from_map/1`
  does the same for already decoded JSON. `to_results/1` turns a loaded run
  into `DeepEvalEx.TestCase`s (or `DeepEvalEx.ConversationalTestCase`s) and
  `DeepEvalEx.Result`s:

      {:ok, test_run} = DeepEvalEx.TestRun.load("eval_results/test_run_20261022_101500.json")
      {test_cases, results} = DeepEvalEx.TestRun.to_results(test_run)

  Loading is lossless: `load/1`, then `to_map/1` and
  `DeepEvalEx.TestRun.JSON.encode!/1` give back deepeval's file byte for
  byte, traces, prompts and dataset keys included. Values are kept as they
  are in the file (an integer test case `runDuration` stays an integer,
  JSON objects stay `Jason.OrderedObject`s).

  ## Raw JSON

  Parts of deepeval's format DeepEvalEx does not interpret are kept as the
  decoded JSON they were loaded from, and written back unchanged in the
  position deepeval's models declare them:

  - on the run: `:trace_metrics_scores` (computed by `from_test_cases/2`,
    kept as it is on load) and `:prompts`
  - on each `DeepEvalEx.TestRun.TestCase`: `:expectations_data`,
    `:images_mapping` and `:trace`
  - on each `DeepEvalEx.TestRun.ConversationalTestCase`:
    `:expectations_data` and `:images_mapping`
  - on each `DeepEvalEx.TestRun.MetricData`: `:expectations_data`

  `from_results/3` writes a test case's `:expectations_data` itself, from
  its expectations' result (see `DeepEvalEx.TestRun.ExpectationsData`), in
  the same JSON shape.

  Keys deepeval itself does not model (deepeval ignores them on load) are
  kept too, as `{key, value}` pairs in each struct's `:extra`, in the
  file's order, and written back after the modelled keys. deepeval never
  writes such keys, so its own files round-trip byte for byte.
  """

  alias DeepEvalEx.ConversationalTestCase, as: EvalConversationalTestCase
  alias DeepEvalEx.{Result, TestRun}
  alias DeepEvalEx.Schemas.{RetrievedContextData, ToolCall}
  alias DeepEvalEx.TestCase, as: EvalTestCase
  alias DeepEvalEx.TestRun.{ExpectationsData, JSON, TraceMetricScores}
  alias Jason.OrderedObject

  @type metric_scores :: %{
          metric: String.t(),
          scores: [float()],
          passes: non_neg_integer(),
          fails: non_neg_integer(),
          errors: non_neg_integer()
        }

  @typedoc "Decoded JSON DeepEvalEx keeps as it is (see \"Raw JSON\")."
  @type raw :: term()

  @typedoc "Keys deepeval does not model, in the order they were read."
  @type extra :: [{String.t(), raw()}]

  @type t :: %__MODULE__{
          test_file: String.t() | nil,
          test_cases: [TestRun.TestCase.t()],
          conversational_test_cases: [TestRun.ConversationalTestCase.t()],
          metrics_scores: [metric_scores()],
          trace_metrics_scores: raw() | nil,
          identifier: String.t() | nil,
          hyperparameters: [{String.t(), String.t()}] | nil,
          prompts: [raw()] | nil,
          test_passed: non_neg_integer(),
          test_failed: non_neg_integer(),
          run_duration: float(),
          evaluation_cost: float() | nil,
          dataset_alias: String.t() | nil,
          dataset_id: String.t() | nil,
          dataset_version: String.t() | nil,
          official: boolean(),
          extra: extra()
        }

  defstruct test_file: nil,
            test_cases: [],
            conversational_test_cases: [],
            metrics_scores: [],
            trace_metrics_scores: nil,
            identifier: nil,
            hyperparameters: nil,
            prompts: nil,
            test_passed: 0,
            test_failed: 0,
            run_duration: 0.0,
            evaluation_cost: nil,
            dataset_alias: nil,
            dataset_id: nil,
            dataset_version: nil,
            official: false,
            extra: []

  defmodule MetricData do
    @moduledoc """
    One metric's result on one test case, as deepeval's `MetricData`.

    Built from a `DeepEvalEx.Result` by `from_result/1`, and turned back
    into one by `to_result/1`. An errored result keeps its threshold, error
    and cost but has no score or reason, as in deepeval. `:strict_mode` and
    `:flaky` are the result's, and so are `:verbose_logs`, exported last as
    deepeval's `verboseLogs`. A score-only metric has neither `:threshold`
    nor `:success` (`nil`), and the export leaves both out, as deepeval's
    `exclude_none` does. The cost is a float, but in a row this run cached
    (`DeepEvalEx.TestRun.Cache`), which keeps deepeval's integer `0`.

    `:expectations_data` and `:extra` hold loaded JSON DeepEvalEx does not
    interpret (see "Raw JSON" in `DeepEvalEx.TestRun`).
    """

    @type t :: %__MODULE__{
            name: String.t(),
            threshold: number() | nil,
            success: boolean() | nil,
            score: number() | nil,
            reason: String.t() | nil,
            strict_mode: boolean(),
            flaky: boolean(),
            evaluation_model: String.t() | nil,
            error: String.t() | nil,
            evaluation_cost: number() | nil,
            input_tokens: non_neg_integer() | nil,
            output_tokens: non_neg_integer() | nil,
            verbose_logs: String.t() | nil,
            expectations_data: DeepEvalEx.TestRun.raw() | nil,
            extra: DeepEvalEx.TestRun.extra()
          }

    defstruct [
      :name,
      :threshold,
      :success,
      :score,
      :reason,
      :evaluation_model,
      :error,
      :evaluation_cost,
      :input_tokens,
      :output_tokens,
      :verbose_logs,
      :expectations_data,
      strict_mode: false,
      flaky: false,
      extra: []
    ]

    @doc """
    Converts a result into metric data, with the result's strict mode and
    flakiness. The result's `:expectations_data`, if any, becomes the
    metric data's, as JSON (`DeepEvalEx.TestRun.ExpectationsData.to_map/1`).
    """
    @spec from_result(Result.t()) :: t()
    def from_result(%Result{} = result) do
      errored? = Result.errored?(result)

      %__MODULE__{
        name: result.metric,
        threshold: result.threshold,
        success: result.success,
        score: if(errored?, do: nil, else: result.score),
        reason: if(errored?, do: nil, else: result.reason),
        strict_mode: result.strict_mode,
        flaky: result.flaky,
        evaluation_model: result.evaluation_model,
        error: result.error,
        evaluation_cost: result.evaluation_cost,
        input_tokens: result.input_tokens,
        output_tokens: result.output_tokens,
        verbose_logs: result.verbose_logs,
        expectations_data:
          result.expectations_data && ExpectationsData.to_map(result.expectations_data)
      }
    end

    @doc """
    Converts metric data into a result, keeping its strict mode and
    flakiness.
    """
    @spec to_result(t()) :: Result.t()
    def to_result(%__MODULE__{} = data) do
      %Result{
        metric: data.name,
        score: data.score,
        success: data.success,
        reason: data.reason,
        threshold: data.threshold,
        error: data.error,
        strict_mode: data.strict_mode,
        flaky: data.flaky,
        evaluation_model: data.evaluation_model,
        evaluation_cost: data.evaluation_cost,
        input_tokens: data.input_tokens,
        output_tokens: data.output_tokens,
        verbose_logs: data.verbose_logs
      }
    end
  end

  defmodule TestCase do
    @moduledoc """
    One evaluated test case, as deepeval's `LLMApiTestCase`.

    Carries the test case's fields, the metric data of each of its results,
    whether no metric failed (`:success`; flaky and score-only metrics never
    decide it, as in deepeval's `update_status`), its summed `:evaluation_cost`
    (`nil` when no metric reported one) and its `:run_duration` in seconds.
    `:name` defaults to `"test_case_<order>"` as in deepeval.

    As in deepeval's async executor, a `:run_duration` under one second is
    the integer `0` (exported as `0`, not `0.0`); longer ones are floats.

    `:success` is `nil` for a test case loaded without one: deepeval leaves
    it unset (`None`) until a metric decides it, and such a test case
    neither passes nor fails.

    `:expectations_data`, `:images_mapping`, `:trace` and `:extra` hold
    loaded JSON DeepEvalEx does not interpret (see "Raw JSON" in
    `DeepEvalEx.TestRun`).
    """

    alias DeepEvalEx.Schemas.ToolCall

    @type t :: %__MODULE__{
            name: String.t(),
            input: String.t() | nil,
            actual_output: String.t() | nil,
            expected_output: String.t() | nil,
            context: [String.t()] | nil,
            retrieval_context: [String.t()] | nil,
            tools_called: [ToolCall.t()] | nil,
            expected_tools: [ToolCall.t()] | nil,
            token_cost: float() | nil,
            input_token_count: non_neg_integer() | nil,
            output_token_count: non_neg_integer() | nil,
            completion_time: float() | nil,
            tags: [String.t()] | nil,
            flaky: boolean(),
            success: boolean() | nil,
            metrics_data: [MetricData.t()],
            run_duration: float() | 0,
            evaluation_cost: float() | nil,
            order: non_neg_integer() | nil,
            metadata: map() | nil,
            comments: String.t() | nil,
            expectations_data: DeepEvalEx.TestRun.raw() | nil,
            images_mapping: DeepEvalEx.TestRun.raw() | nil,
            trace: DeepEvalEx.TestRun.raw() | nil,
            extra: DeepEvalEx.TestRun.extra()
          }

    defstruct [
      :name,
      :input,
      :actual_output,
      :expected_output,
      :context,
      :retrieval_context,
      :tools_called,
      :expected_tools,
      :token_cost,
      :input_token_count,
      :output_token_count,
      :completion_time,
      :tags,
      :evaluation_cost,
      :order,
      :metadata,
      :comments,
      :expectations_data,
      :images_mapping,
      :trace,
      flaky: false,
      success: true,
      metrics_data: [],
      run_duration: 0,
      extra: []
    ]

    @doc """
    Converts an evaluated test case back into a `DeepEvalEx.TestCase`.

    Keeps the test case's own fields and drops the evaluation (`:success`,
    `:metrics_data`, `:run_duration`, `:evaluation_cost` and `:order`).
    Tool call lists pass through as they are: an unset one stays `nil`, the
    `DeepEvalEx.TestCase` default, and an empty one stays `[]`, so a metric
    requiring them still reports an unset one missing.
    """
    @spec to_test_case(t()) :: DeepEvalEx.TestCase.t()
    def to_test_case(%__MODULE__{} = test_case) do
      %DeepEvalEx.TestCase{
        name: test_case.name,
        input: test_case.input,
        actual_output: test_case.actual_output,
        expected_output: test_case.expected_output,
        context: test_case.context,
        retrieval_context: test_case.retrieval_context,
        tools_called: test_case.tools_called,
        expected_tools: test_case.expected_tools,
        token_cost: test_case.token_cost,
        input_token_count: test_case.input_token_count,
        output_token_count: test_case.output_token_count,
        completion_time: test_case.completion_time,
        tags: test_case.tags,
        flaky: test_case.flaky,
        metadata: test_case.metadata,
        comments: test_case.comments
      }
    end
  end

  defmodule Turn do
    @moduledoc """
    One turn of an evaluated conversation, as deepeval's `TurnApi`.

    `:role` is the turn's role as a string (`"user"` or `"assistant"`) and
    `:order` its position in the conversation. `:retrieval_context` holds
    strings only: a `DeepEvalEx.Schemas.RetrievedContextData` is flattened to
    its context, and an empty list is `nil`, as deepeval's `create_api_turn`.

    `:user_id` and `:comments` are only ever set by loading a file:
    deepeval's `create_api_turn` passes `user_id` by its field name, which
    `TurnApi` (aliased `userId`) ignores, and never passes `comments`.

    `:extra` holds keys deepeval does not model (see "Raw JSON" in
    `DeepEvalEx.TestRun`).
    """

    alias DeepEvalEx.Schemas.ToolCall

    @type t :: %__MODULE__{
            role: String.t(),
            content: String.t(),
            order: non_neg_integer(),
            user_id: String.t() | nil,
            retrieval_context: [String.t()] | nil,
            tools_called: [ToolCall.t()] | nil,
            comments: String.t() | nil,
            extra: DeepEvalEx.TestRun.extra()
          }

    defstruct [
      :role,
      :content,
      :order,
      :user_id,
      :retrieval_context,
      :tools_called,
      :comments,
      extra: []
    ]

    @doc """
    The evaluated turn of `turn`, at position `order` in its conversation,
    as deepeval's `create_api_turn`: the role as a string, the retrieval
    context flattened (see the module documentation) and no `:user_id`.
    """
    @spec from_turn(DeepEvalEx.Turn.t(), non_neg_integer()) :: t()
    def from_turn(%DeepEvalEx.Turn{} = turn, order) do
      %__MODULE__{
        role: Atom.to_string(turn.role),
        content: turn.content,
        order: order,
        retrieval_context: DeepEvalEx.TestRun.flat_contexts(turn.retrieval_context),
        tools_called: turn.tools_called
      }
    end

    @doc """
    Converts an evaluated turn back into a `DeepEvalEx.Turn`, keeping its
    role, content, user, retrieval context and tool calls.

    Raises `ArgumentError` for a role other than `"user"` or `"assistant"`.
    """
    @spec to_turn(t()) :: DeepEvalEx.Turn.t()
    def to_turn(%__MODULE__{} = turn) do
      role =
        case DeepEvalEx.Turn.cast_role(turn.role) do
          {:ok, role} ->
            role

          {:error, _message, _context} ->
            raise ArgumentError, "invalid turn role: #{inspect(turn.role)}"
        end

      %DeepEvalEx.Turn{
        role: role,
        content: turn.content,
        user_id: turn.user_id,
        retrieval_context: turn.retrieval_context,
        tools_called: turn.tools_called
      }
    end
  end

  defmodule ConversationalTestCase do
    @moduledoc """
    One evaluated conversation, as deepeval's `ConversationalApiTestCase`.

    Carries the conversational test case's fields, its turns as
    `DeepEvalEx.TestRun.Turn`s, the metric data of each of its results,
    whether no metric failed (`:success`; flaky metrics never decide it, as
    in deepeval's `update_metric_data`), its summed `:evaluation_cost` (`nil`
    when no metric reported one) and its `:run_duration` in seconds.
    `:name` defaults to `"conversational_test_case_<order>"` as in deepeval.

    Unlike a `DeepEvalEx.TestRun.TestCase`, `:run_duration` is always a
    float: deepeval adds the time the metrics took to its initial `0.0`, so
    an instantaneous run is not recorded as the integer `0`.

    `:success` is `nil` for a test case loaded without one, which neither
    passes nor fails.

    `:expectations_data`, `:images_mapping` and `:extra` hold loaded JSON
    DeepEvalEx does not interpret (see "Raw JSON" in `DeepEvalEx.TestRun`).
    """

    alias DeepEvalEx.TestRun.{MetricData, Turn}

    @type t :: %__MODULE__{
            name: String.t(),
            success: boolean() | nil,
            metrics_data: [MetricData.t()],
            run_duration: number(),
            evaluation_cost: float() | nil,
            turns: [Turn.t()],
            order: non_neg_integer() | nil,
            scenario: String.t() | nil,
            expected_outcome: String.t() | nil,
            user_description: String.t() | nil,
            context: [String.t()] | nil,
            comments: String.t() | nil,
            metadata: map() | nil,
            tags: [String.t()] | nil,
            flaky: boolean(),
            expectations_data: DeepEvalEx.TestRun.raw() | nil,
            images_mapping: DeepEvalEx.TestRun.raw() | nil,
            extra: DeepEvalEx.TestRun.extra()
          }

    defstruct [
      :name,
      :evaluation_cost,
      :order,
      :scenario,
      :expected_outcome,
      :user_description,
      :context,
      :comments,
      :metadata,
      :tags,
      :expectations_data,
      :images_mapping,
      success: true,
      metrics_data: [],
      run_duration: 0.0,
      turns: [],
      flaky: false,
      extra: []
    ]

    @doc """
    Converts an evaluated conversation back into a
    `DeepEvalEx.ConversationalTestCase`, built by
    `DeepEvalEx.ConversationalTestCase.new!/1` so its modality flags are set.

    Keeps the test case's own fields and turns (see `Turn.to_turn/1`) and
    drops the evaluation. Raises for a test case without turns, which
    deepeval's `ConversationalTestCase` rejects too.
    """
    @spec to_test_case(t()) :: DeepEvalEx.ConversationalTestCase.t()
    def to_test_case(%__MODULE__{} = test_case) do
      [
        name: test_case.name,
        turns: Enum.map(test_case.turns, &Turn.to_turn/1),
        scenario: test_case.scenario,
        expected_outcome: test_case.expected_outcome,
        user_description: test_case.user_description,
        context: test_case.context,
        comments: test_case.comments,
        metadata: test_case.metadata,
        tags: test_case.tags,
        flaky: test_case.flaky
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> DeepEvalEx.ConversationalTestCase.new!()
    end
  end

  @doc """
  Builds a test run from test cases and their results.

  `results` holds one result list per test case, as returned by
  `DeepEvalEx.evaluate_run/3`. Skipped results (`DeepEvalEx.Result.skipped/2`)
  are left out, and so are test cases without other results, as deepeval
  leaves out test cases no metric ran on. A test case's `order` (and so its
  `"test_case_<order>"` name) is its `:dataset_rank`, else its position in
  `test_cases`, as deepeval's `create_api_test_case`. As deepeval's
  `sort_test_cases`, `testCases` are then sorted by order, and when two
  test cases share one (test cases ranked by different datasets) the
  orders are renumbered from 0 and the names left as they are; the
  `metricsScores` keep the order of `test_cases`. Each metric's
  `strictMode` and `flaky` come from its result.

  `DeepEvalEx.ConversationalTestCase`s become
  `DeepEvalEx.TestRun.ConversationalTestCase`s in `conversationalTestCases`,
  named `"conversational_test_case_<order>"` by default and sorted alike.
  As deepeval counts the two kinds separately, a conversational test case's
  position is among the conversational ones only. Each turn's retrieval
  context is flattened as for a test case (see `DeepEvalEx.TestRun.Turn`),
  and the test case's duration is a float. Their metric data follows the
  single-turn test cases' in `metricsScores`, and their success counts
  towards `testPassed` and `testFailed`.

  A test case with expectations has an `"Expectations"` result (see
  `DeepEvalEx.Dataset.Expectations`): as deepeval's `update_metric_data`
  and `ApiMetricsData` serializer, it becomes the test case's
  `:expectations_data` (`DeepEvalEx.TestRun.ExpectationsData.to_map/1`)
  instead of one of its `:metrics_data`, and is left out of
  `metricsScores`, but it still decides the test case's success and adds
  to its cost.

  A test case succeeds unless a non-flaky metric failed: score-only results
  (`success: nil`) and flaky ones never decide it, as in deepeval's
  `update_status`. In `metricsScores`, results without a score or a success
  are counted as `errors`, as deepeval counts them.

  ## Options

  - `:run_durations` - Seconds each test case took, in `test_cases` order.
    As in deepeval, a (single-turn) test case that took under one second is
    recorded as the integer `0` (default: all `0`)
  - `:run_duration` - Seconds the whole run took (default: `0.0`)
  - `:identifier` - Name for the run
  - `:hyperparameters` - Keyword list or map of hyperparameters, see
    `process_hyperparameters/1`
  - `:test_file` - The test file the run came from
  - `:dataset_alias`, `:dataset_id`, `:dataset_version` - The dataset the
    test cases came from
  - `:official` - Marks the run official (default: `false`)
  - `:test_name` - The name of test cases without one, instead of
    `"test_case_<order>"`: under `mix deep_eval.test`, the ExUnit test that
    evaluated them, as deepeval names them after the pytest test
    (`PYTEST_RUN_TEST_NAME`)

  `prompts` is `[]`, as deepeval's `evaluate()` writes it when no
  hyperparameter is a `Prompt`; `from_test_cases/2` takes a `:prompts`
  option, `nil` for a `deepeval test run`'s run, which never sets them.
  """
  @spec from_results(
          [EvalTestCase.t() | EvalConversationalTestCase.t()],
          [[Result.t()]],
          keyword()
        ) :: t()
  def from_results(test_cases, results, opts \\ []) do
    durations =
      Keyword.get_lazy(opts, :run_durations, fn -> Enum.map(test_cases, fn _ -> 0 end) end)

    {conversational, api_test_cases} =
      [test_cases, results, durations]
      |> Enum.zip()
      |> index_by_kind()
      |> Enum.flat_map(fn {{test_case, case_results, duration}, index} ->
        case Enum.reject(case_results, & &1.skipped) do
          [] ->
            []

          kept ->
            api = api_test_case(test_case, kept, duration, test_case.dataset_rank || index)
            [name_after_test(api, test_case, Keyword.get(opts, :test_name))]
        end
      end)
      |> Enum.split_with(&match?(%ConversationalTestCase{}, &1))

    from_test_cases(api_test_cases ++ conversational, opts)
  end

  @doc """
  Builds a test run from evaluated test cases, in the order they were
  evaluated, as deepeval's `wrap_up_test_run` finalizes the test cases its
  `TestRunManager` collected.

  `DeepEvalEx.TestRun.TestCase`s become the run's `testCases` and
  `DeepEvalEx.TestRun.ConversationalTestCase`s its
  `conversationalTestCases`, each sorted as in `from_results/3`;
  `metricsScores`, `traceMetricsScores` (from the test cases' `trace`s,
  see `DeepEvalEx.TestRun.TraceMetricScores`), `testPassed`, `testFailed`
  and `evaluationCost` are computed over them in the given order. Takes
  the options of `from_results/3` except `:run_durations`.
  """
  @spec from_test_cases([TestRun.TestCase.t() | ConversationalTestCase.t()], keyword()) :: t()
  def from_test_cases(evaluated, opts \\ []) do
    {conversational, api_test_cases} =
      Enum.split_with(evaluated, &match?(%ConversationalTestCase{}, &1))

    {test_passed, test_failed} = count_successes(evaluated)

    %__MODULE__{
      test_file: Keyword.get(opts, :test_file),
      test_cases: sort_test_cases(api_test_cases),
      conversational_test_cases: sort_test_cases(conversational),
      metrics_scores: metrics_scores(evaluated),
      trace_metrics_scores: TraceMetricScores.compute(evaluated),
      identifier: Keyword.get(opts, :identifier),
      hyperparameters: process_hyperparameters(Keyword.get(opts, :hyperparameters)),
      prompts: Keyword.get(opts, :prompts, []),
      test_passed: test_passed,
      test_failed: test_failed,
      run_duration: to_float(Keyword.get(opts, :run_duration, 0.0)),
      evaluation_cost: sum_costs(evaluated),
      dataset_alias: Keyword.get(opts, :dataset_alias),
      dataset_id: Keyword.get(opts, :dataset_id),
      dataset_version: Keyword.get(opts, :dataset_version),
      official: Keyword.get(opts, :official, false)
    }
  end

  @doc """
  Normalises hyperparameters as deepeval's `process_hyperparameters` does.

  Takes a keyword list or a map with atom or string keys and returns
  `{name, value}` pairs, keeping the order of a keyword list. `nil` values
  are dropped and the rest are stringified like Python's `str()`: strings
  and atoms as they are, integers in decimal, floats as in
  `DeepEvalEx.TestRun.JSON.float_repr/1` and booleans as `"True"` or
  `"False"`. Returns `nil` for `nil`.

  Raises `ArgumentError` for any other value, as deepeval raises a
  `TypeError`.

  ## Examples

      iex> DeepEvalEx.TestRun.process_hyperparameters(model: "gpt-4o", temperature: 0.7, k: 5)
      [{"model", "gpt-4o"}, {"temperature", "0.7"}, {"k", "5"}]
  """
  @spec process_hyperparameters(keyword() | map() | nil) :: [{String.t(), String.t()}] | nil
  def process_hyperparameters(nil), do: nil

  def process_hyperparameters(hyperparameters)
      when is_list(hyperparameters) or is_map(hyperparameters) do
    for {key, value} <- hyperparameters, not is_nil(value) do
      {hyperparameter_key(key), hyperparameter_value(key, value)}
    end
  end

  defp hyperparameter_key(key) when is_binary(key), do: key
  defp hyperparameter_key(key) when is_atom(key), do: Atom.to_string(key)

  defp hyperparameter_key(key) do
    raise ArgumentError, "hyperparameter key #{inspect(key)} must be a string or an atom"
  end

  defp hyperparameter_value(_key, value) when is_binary(value), do: value
  defp hyperparameter_value(_key, true), do: "True"
  defp hyperparameter_value(_key, false), do: "False"
  defp hyperparameter_value(_key, value) when is_atom(value), do: Atom.to_string(value)
  defp hyperparameter_value(_key, value) when is_integer(value), do: Integer.to_string(value)
  defp hyperparameter_value(_key, value) when is_float(value), do: JSON.float_repr(value)

  defp hyperparameter_value(key, value) do
    raise ArgumentError,
          "hyperparameter #{inspect(to_string(key))} must be a string, number, boolean " <>
            "or atom, got: #{inspect(value)}"
  end

  @doc """
  Converts a test run into deepeval's export structure.

  Returns nested `Jason.OrderedObject`s with deepeval's camelCase keys in
  the declaration order of deepeval's pydantic models, leaving out `nil`
  values as `model_dump(by_alias=True, exclude_none=True)` does (`false`,
  `0` and empty lists are kept). Encode it with
  `DeepEvalEx.TestRun.JSON.encode!/1` for deepeval's exact bytes, or with
  `Jason` for ordinary JSON.

  An empty `retrieval_context` list is left out, while empty `tools_called`
  and `expected_tools` lists are kept, as deepeval does. A conversational
  test case's `runDuration` is written as a float, as deepeval's
  `ConversationalApiTestCase` coerces it. Raw JSON
  fields are written as they are, and `:extra` keys after the others (see
  "Raw JSON" in the module documentation).
  """
  @spec to_map(t()) :: OrderedObject.t()
  def to_map(%__MODULE__{} = test_run) do
    ordered(
      [
        testFile: test_run.test_file,
        testCases: Enum.map(test_run.test_cases, &test_case_map/1),
        conversationalTestCases:
          Enum.map(test_run.conversational_test_cases, &conversational_test_case_map/1),
        metricsScores: Enum.map(test_run.metrics_scores, &metric_scores_map/1),
        traceMetricsScores: test_run.trace_metrics_scores,
        identifier: test_run.identifier,
        hyperparameters: test_run.hyperparameters && OrderedObject.new(test_run.hyperparameters),
        prompts: test_run.prompts,
        testPassed: test_run.test_passed,
        testFailed: test_run.test_failed,
        runDuration: to_float(test_run.run_duration),
        evaluationCost: to_float(test_run.evaluation_cost),
        datasetAlias: test_run.dataset_alias,
        datasetId: test_run.dataset_id,
        datasetVersion: test_run.dataset_version,
        official: test_run.official
      ],
      test_run.extra
    )
  end

  @doc """
  Reads a deepeval test run file.

  Decodes the file with JSON objects kept in order and passes it to
  `from_map/1`.

  ## Returns

  - `{:ok, test_run}`
  - `{:error, posix}` - The file could not be read
  - `{:error, %Jason.DecodeError{}}` - The file is not JSON
  - `{:error, {:invalid_test_run, message}}` - See `from_map/1`
  """
  @spec load(Path.t()) ::
          {:ok, t()}
          | {:error, File.posix() | Jason.DecodeError.t() | {:invalid_test_run, String.t()}}
  def load(path) do
    with {:ok, json} <- File.read(path),
         {:ok, decoded} <- Jason.decode(json, objects: :ordered_objects) do
      from_map(decoded)
    end
  end

  @doc """
  Builds a test run from decoded deepeval JSON.

  Takes deepeval's camelCase keys, in maps or `Jason.OrderedObject`s (use
  `Jason.decode(json, objects: :ordered_objects)` to keep the key order of
  metadata, tool call parameters, hyperparameters and raw JSON for
  re-encoding). Keys DeepEvalEx does not model are kept as raw JSON (see
  "Raw JSON" in the module documentation).

  Only test case, conversational test case and metric data `name`s, each
  turn's `role` and `content`, and each `metricsScores` entry's `metric`
  are required. Missing optional keys get deepeval's defaults, with these
  exceptions where DeepEvalEx needs a value:

  - a (conversational) test case's `order` is its position in `testCases`
    (`conversationalTestCases`), and a turn's its position in `turns`
  - a test case's `runDuration` is `0`
  - a conversational test case's `success` and a test case's `metricsData`
    are optional (`nil` and `[]`)
  - `metricsScores` is computed from the test cases, and `testPassed` and
    `testFailed` from the test cases' and conversational test cases'
    `success`, as deepeval's `calculate_test_passes_and_fails` does: one
    without `success` counts as neither

  An explicit JSON `null` is read like a missing key. deepeval saves with
  `exclude_none=True`, so its files never contain `null` (a test case whose
  `success` is `None` has no `success` key). A test case or metric without
  `success` is read as `nil`, as deepeval's `LLMApiTestCase` and
  `MetricData` default it to `None`, and stays out of the export. Like
  deepeval, DeepEvalEx never writes `null` back for a key it models.

  Returns `{:error, {:invalid_test_run, message}}` when a required key is
  missing or a value has the wrong shape; the message starts with the path
  of the value, e.g. `"testCases[1].name: expected a string, got nil"`.

  ## Examples

      iex> {:ok, test_run} =
      ...>   DeepEvalEx.TestRun.from_map(%{
      ...>     "testCases" => [
      ...>       %{"name" => "greeting", "input" => "Hi", "success" => true, "metricsData" => []}
      ...>     ],
      ...>     "datasetAlias" => "smoke"
      ...>   })
      iex> [%DeepEvalEx.TestRun.TestCase{name: "greeting", success: true}] = test_run.test_cases
      iex> {test_run.test_passed, test_run.dataset_alias}
      {1, "smoke"}
  """
  @spec from_map(map()) :: {:ok, t()} | {:error, {:invalid_test_run, String.t()}}
  def from_map(map) do
    {:ok, parse_test_run(map)}
  catch
    {:invalid_test_run, _message} = reason -> {:error, reason}
  end

  @doc """
  Converts a test run into the test cases and result lists it was built
  from, the inverse of `from_results/3`.

  Returns `{test_cases, results}` with one `DeepEvalEx.TestCase` and one
  list of `DeepEvalEx.Result`s per evaluated test case, in the shape
  `DeepEvalEx.evaluate_run/3` returns, followed by one
  `DeepEvalEx.ConversationalTestCase` and its results per conversational
  test case. See `TestCase.to_test_case/1`,
  `ConversationalTestCase.to_test_case/1` and `MetricData.to_result/1` for
  what is kept.
  """
  @spec to_results(t()) ::
          {[EvalTestCase.t() | EvalConversationalTestCase.t()], [[Result.t()]]}
  def to_results(%__MODULE__{} = test_run) do
    {
      Enum.map(test_run.test_cases, &TestCase.to_test_case/1) ++
        Enum.map(test_run.conversational_test_cases, &ConversationalTestCase.to_test_case/1),
      Enum.map(test_run.test_cases ++ test_run.conversational_test_cases, fn test_case ->
        Enum.map(test_case.metrics_data, &MetricData.to_result/1)
      end)
    }
  end

  # Under `deepeval test run`, an unnamed test case is named after the test
  # that evaluated it (PYTEST_RUN_TEST_NAME).
  defp name_after_test(api, %{name: nil}, test_name) when is_binary(test_name),
    do: %{api | name: test_name}

  defp name_after_test(api, _test_case, _test_name), do: api

  # deepeval's executors count single- and multi-turn test cases apart:
  # each item is paired with its position among the test cases of its kind.
  defp index_by_kind(items) do
    {indexed, _counts} =
      Enum.map_reduce(items, %{}, fn {test_case, _results, _duration} = item, counts ->
        kind = test_case.__struct__
        index = Map.get(counts, kind, 0)
        {{item, index}, Map.put(counts, kind, index + 1)}
      end)

    indexed
  end

  # deepeval's create_api_test_case for a ConversationalTestCase; its
  # update_run_duration adds the time taken to the initial 0.0.
  defp api_test_case(%EvalConversationalTestCase{} = test_case, results, duration, order) do
    all_data = Enum.map(results, &MetricData.from_result/1)
    {expectations_data, metrics_data} = split_expectations(all_data)

    %ConversationalTestCase{
      expectations_data: expectations_data,
      name: test_case.name || "conversational_test_case_#{order}",
      success: case_success(all_data),
      metrics_data: metrics_data,
      run_duration: to_float(duration || 0),
      evaluation_cost: sum_costs(all_data),
      turns: test_case.turns |> Enum.with_index() |> Enum.map(&api_turn/1),
      order: order,
      scenario: test_case.scenario,
      expected_outcome: test_case.expected_outcome,
      user_description: test_case.user_description,
      context: test_case.context,
      comments: test_case.comments,
      metadata: test_case.metadata,
      tags: test_case.tags,
      flaky: test_case.flaky || false
    }
  end

  defp api_test_case(test_case, results, duration, order) do
    all_data = Enum.map(results, &MetricData.from_result/1)
    {expectations_data, metrics_data} = split_expectations(all_data)

    %TestCase{
      expectations_data: expectations_data,
      name: test_case.name || "test_case_#{order}",
      input: test_case.input,
      actual_output: test_case.actual_output,
      expected_output: test_case.expected_output,
      context: test_case.context,
      retrieval_context: test_case.retrieval_context |> contexts() |> non_empty(),
      tools_called: test_case.tools_called,
      expected_tools: test_case.expected_tools,
      token_cost: test_case.token_cost,
      input_token_count: test_case.input_token_count,
      output_token_count: test_case.output_token_count,
      completion_time: test_case.completion_time,
      tags: test_case.tags,
      flaky: test_case.flaky || false,
      success: case_success(all_data),
      metrics_data: metrics_data,
      run_duration: case_duration(duration),
      evaluation_cost: sum_costs(all_data),
      order: order,
      metadata: test_case.metadata,
      comments: test_case.comments
    }
  end

  @doc false
  # deepeval's update_metric_data and ApiMetricsData serializer: the
  # expectation evaluator's row gives the test case its expectationsData (a
  # copy with the row's cost) and is not exported as metric data, nor
  # counted in metricsScores; it still decides the test case's success and
  # adds to its cost. Also DeepEvalEx.Evaluator.Agentic's.
  @spec split_expectations([MetricData.t()]) :: {raw() | nil, [MetricData.t()]}
  def split_expectations(metrics_data) do
    {expectations, metrics} = Enum.split_with(metrics_data, & &1.expectations_data)
    {Enum.find_value(expectations, & &1.expectations_data), metrics}
  end

  defp api_turn({%DeepEvalEx.Turn{} = turn, order}), do: Turn.from_turn(turn, order)

  @doc false
  # deepeval's create_api_test_case keeps only a RetrievedContextData's
  # context, and leaves out an empty list.
  @spec flat_contexts([String.t() | RetrievedContextData.t()] | nil) :: [String.t()] | nil
  def flat_contexts(retrieval_context), do: retrieval_context |> contexts() |> non_empty()

  # deepeval's async executor records a test case that finished in under a
  # second as 0 ("all metrics were from cache"). It assigns the int without
  # pydantic coercion, so the export has `"runDuration": 0`, not `0.0`.
  defp case_duration(duration) when is_number(duration) and duration >= 1, do: duration / 1
  defp case_duration(_duration), do: 0

  # deepeval's update_status (and ConversationalApiTestCase's
  # update_metric_data): a test case starts successful and fails only when a
  # non-flaky metric's success is False; None (score-only) leaves it.
  defp case_success(metrics_data) do
    not Enum.any?(metrics_data, &(not &1.flaky and &1.success == false))
  end

  # deepeval's calculate_test_passes_and_fails: a test case without a
  # verdict (success None) neither passes nor fails.
  # deepeval's sort_test_cases: a stable sort by order, test cases without
  # one (an assert_test's) last, then _assign_unique_orders: a test case
  # without an order gets the one after its predecessor's, and when two are
  # equal every order is renumbered from 0.
  defp sort_test_cases(test_cases) do
    sorted = Enum.sort_by(test_cases, &if(&1.order, do: {0, &1.order}, else: {1, 0}))

    {filled, _next} =
      Enum.map_reduce(sorted, 0, fn test_case, next ->
        order = test_case.order || next
        {%{test_case | order: order}, order + 1}
      end)

    if filled |> Enum.uniq_by(& &1.order) |> length() == length(filled) do
      filled
    else
      filled
      |> Enum.with_index()
      |> Enum.map(fn {test_case, order} -> %{test_case | order: order} end)
    end
  end

  defp count_successes(successes) do
    Enum.reduce(successes, {0, 0}, fn
      %{success: true}, {passed, failed} -> {passed + 1, failed}
      %{success: false}, {passed, failed} -> {passed, failed + 1}
      _no_verdict, counts -> counts
    end)
  end

  # deepeval's calculate_metrics_scores: a test case's own metric data, then
  # its traced spans'.
  defp metrics_scores(test_cases) do
    {order, scores} =
      for %{metrics_data: metrics_data} = test_case <- test_cases,
          data <- metrics_data ++ TraceMetricScores.span_metrics_data(test_case),
          reduce: {[], %{}} do
        {order, scores} ->
          order = if Map.has_key?(scores, data.name), do: order, else: [data.name | order]

          entry =
            Map.get(scores, data.name, %{
              metric: data.name,
              scores: [],
              passes: 0,
              fails: 0,
              errors: 0
            })

          {order, Map.put(scores, data.name, add_score(entry, data))}
      end

    order
    |> Enum.reverse()
    |> Enum.map(fn name -> Map.update!(scores[name], :scores, &Enum.reverse/1) end)
  end

  # As deepeval's construct_metrics_scores, a result without a score or a
  # success (errored, or score-only) counts as an error.
  defp add_score(entry, %MetricData{score: score, success: success})
       when is_nil(score) or is_nil(success),
       do: Map.update!(entry, :errors, &(&1 + 1))

  defp add_score(entry, %MetricData{score: score, success: success}) do
    entry = Map.update!(entry, :scores, &[to_float(score) | &1])

    if success,
      do: Map.update!(entry, :passes, &(&1 + 1)),
      else: Map.update!(entry, :fails, &(&1 + 1))
  end

  # Summed in order, skipping unknown costs; nil when there are none.
  defp sum_costs(items) do
    Enum.reduce(items, nil, fn
      %{evaluation_cost: nil}, total -> total
      %{evaluation_cost: cost}, nil -> cost
      %{evaluation_cost: cost}, total -> total + cost
    end)
  end

  defp test_case_map(%TestCase{} = test_case) do
    ordered(
      [
        expectationsData: test_case.expectations_data,
        name: test_case.name,
        input: test_case.input,
        actualOutput: test_case.actual_output,
        expectedOutput: test_case.expected_output,
        context: test_case.context,
        retrievalContext: test_case.retrieval_context,
        toolsCalled: tool_calls_map(test_case.tools_called),
        expectedTools: tool_calls_map(test_case.expected_tools),
        tokenCost: to_float(test_case.token_cost),
        inputTokenCount: test_case.input_token_count,
        outputTokenCount: test_case.output_token_count,
        completionTime: to_float(test_case.completion_time),
        tags: test_case.tags,
        flaky: test_case.flaky,
        imagesMapping: test_case.images_mapping,
        success: test_case.success,
        metricsData: Enum.map(test_case.metrics_data, &metric_data_map/1),
        runDuration: test_case.run_duration,
        evaluationCost: to_float(test_case.evaluation_cost),
        order: test_case.order,
        metadata: test_case.metadata,
        comments: test_case.comments,
        trace: test_case.trace
      ],
      test_case.extra
    )
  end

  defp conversational_test_case_map(%ConversationalTestCase{} = test_case) do
    ordered(
      [
        expectationsData: test_case.expectations_data,
        name: test_case.name,
        success: test_case.success,
        metricsData: Enum.map(test_case.metrics_data, &metric_data_map/1),
        runDuration: to_float(test_case.run_duration),
        evaluationCost: to_float(test_case.evaluation_cost),
        turns: Enum.map(test_case.turns, &turn_map/1),
        order: test_case.order,
        scenario: test_case.scenario,
        expectedOutcome: test_case.expected_outcome,
        userDescription: test_case.user_description,
        context: test_case.context,
        comments: test_case.comments,
        metadata: test_case.metadata,
        imagesMapping: test_case.images_mapping,
        tags: test_case.tags,
        flaky: test_case.flaky
      ],
      test_case.extra
    )
  end

  defp turn_map(%Turn{} = turn) do
    ordered(
      [
        role: turn.role,
        content: turn.content,
        order: turn.order,
        userId: turn.user_id,
        retrievalContext: turn.retrieval_context,
        toolsCalled: tool_calls_map(turn.tools_called),
        comments: turn.comments
      ],
      turn.extra
    )
  end

  @doc false
  # One metric data as deepeval dumps it (see to_map/1); also the
  # metric_data of DeepEvalEx.TestRun.Cache's entries.
  @spec metric_data_to_map(MetricData.t()) :: OrderedObject.t()
  def metric_data_to_map(%MetricData{} = data), do: metric_data_map(data)

  @doc false
  # Parses one decoded metric data object, as load/1 does.
  @spec metric_data_from_map(term()) ::
          {:ok, MetricData.t()} | {:error, {:invalid_test_run, String.t()}}
  def metric_data_from_map(map) do
    {:ok, parse_metric_data(map, "metric_data")}
  catch
    {:invalid_test_run, _message} = reason -> {:error, reason}
  end

  defp metric_data_map(%MetricData{} = data) do
    ordered(
      [
        name: data.name,
        threshold: to_float(data.threshold),
        success: data.success,
        score: to_float(data.score),
        reason: data.reason,
        strictMode: data.strict_mode,
        flaky: data.flaky,
        evaluationModel: data.evaluation_model,
        error: data.error,
        evaluationCost: to_float(data.evaluation_cost),
        inputTokenCount: data.input_tokens,
        outputTokenCount: data.output_tokens,
        verboseLogs: data.verbose_logs,
        expectationsData: data.expectations_data
      ],
      data.extra
    )
  end

  defp metric_scores_map(scores) do
    ordered(
      metric: scores.metric,
      scores: scores.scores,
      passes: scores.passes,
      fails: scores.fails,
      errors: scores.errors
    )
  end

  defp tool_calls_map(nil), do: nil
  defp tool_calls_map(tool_calls), do: tool_calls_to_maps(tool_calls)

  @doc false
  # deepeval's ToolCall dump, by alias without None values; also the tool
  # calls of DeepEvalEx.Tracing.Api's exports.
  @spec tool_calls_to_maps([ToolCall.t()]) :: [OrderedObject.t()]
  def tool_calls_to_maps(tool_calls) do
    Enum.map(tool_calls, fn tool_call ->
      ordered(
        name: tool_call.name,
        type: tool_call.type |> to_string() |> String.upcase(),
        description: tool_call.description,
        reasoning: tool_call.reasoning,
        output: tool_call.output,
        inputParameters: tool_call.input_parameters
      )
    end)
  end

  # An ordered object of the non-nil pairs, with string keys, followed by
  # the extra (unmodelled) pairs as they were read, nil values included.
  defp ordered(pairs, extra \\ []) do
    pairs
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Enum.map(fn {key, value} -> {Atom.to_string(key), value} end)
    |> Kernel.++(extra)
    |> OrderedObject.new()
  end

  # Parsing deepeval JSON. Errors are thrown as {:invalid_test_run, message}
  # and caught by from_map/1.

  # The keys of deepeval's TestRun, LLMApiTestCase, ConversationalApiTestCase,
  # TurnApi and MetricData; any other key is kept in :extra.
  @test_run_keys ~w(testFile testCases conversationalTestCases metricsScores
                    traceMetricsScores identifier hyperparameters prompts testPassed
                    testFailed runDuration evaluationCost datasetAlias datasetId
                    datasetVersion official)
  @test_case_keys ~w(expectationsData name input actualOutput expectedOutput context
                     retrievalContext toolsCalled expectedTools tokenCost inputTokenCount
                     outputTokenCount completionTime tags flaky imagesMapping success
                     metricsData runDuration evaluationCost order metadata comments trace)
  @conversational_test_case_keys ~w(expectationsData name success metricsData runDuration
                                    evaluationCost turns order scenario expectedOutcome
                                    userDescription context comments metadata imagesMapping
                                    tags flaky)
  @turn_keys ~w(role content order userId retrievalContext toolsCalled comments)
  @metric_data_keys ~w(name threshold success score reason strictMode flaky evaluationModel
                       error evaluationCost inputTokenCount outputTokenCount verboseLogs
                       expectationsData)

  # The pairs of the keys not in known, in the map's order.
  defp extra(map, known), do: Enum.reject(map, fn {key, _value} -> key in known end)

  defp parse_test_run(map) do
    object!(map, "test run")

    test_cases =
      map
      |> list!("testCases", "")
      |> indexed("testCases", fn test_case, path, index ->
        parse_test_case(test_case, path, index)
      end)

    conversational_test_cases =
      map
      |> list!("conversationalTestCases", "")
      |> indexed("conversationalTestCases", &parse_conversational_test_case/3)

    evaluated = test_cases ++ conversational_test_cases

    metrics_scores =
      case map["metricsScores"] do
        nil ->
          metrics_scores(evaluated)

        scores ->
          scores |> list_value!("metricsScores") |> indexed("metricsScores", &parse_scores/3)
      end

    {test_passed, test_failed} = count_successes(evaluated)

    %__MODULE__{
      test_file: map["testFile"],
      test_cases: test_cases,
      conversational_test_cases: conversational_test_cases,
      metrics_scores: metrics_scores,
      trace_metrics_scores: map["traceMetricsScores"],
      identifier: map["identifier"],
      hyperparameters: parse_hyperparameters(map["hyperparameters"]),
      prompts: map["prompts"],
      test_passed: value(map, "testPassed", test_passed),
      test_failed: value(map, "testFailed", test_failed),
      run_duration: value(map, "runDuration", 0.0),
      evaluation_cost: map["evaluationCost"],
      dataset_alias: map["datasetAlias"],
      dataset_id: map["datasetId"],
      dataset_version: map["datasetVersion"],
      official: value(map, "official", false),
      extra: extra(map, @test_run_keys)
    }
  end

  defp parse_test_case(map, path, index) do
    object!(map, path)

    %TestCase{
      expectations_data: map["expectationsData"],
      name: string!(map, "name", path),
      input: map["input"],
      actual_output: map["actualOutput"],
      expected_output: map["expectedOutput"],
      context: map["context"],
      retrieval_context: map["retrievalContext"],
      tools_called: parse_tool_calls(map, "toolsCalled", path),
      expected_tools: parse_tool_calls(map, "expectedTools", path),
      token_cost: map["tokenCost"],
      input_token_count: map["inputTokenCount"],
      output_token_count: map["outputTokenCount"],
      completion_time: map["completionTime"],
      tags: map["tags"],
      flaky: value(map, "flaky", false),
      images_mapping: map["imagesMapping"],
      success: map["success"],
      metrics_data: parse_metrics_data(map, path),
      run_duration: value(map, "runDuration", 0),
      evaluation_cost: map["evaluationCost"],
      order: value(map, "order", index),
      metadata: map["metadata"],
      comments: map["comments"],
      trace: map["trace"],
      extra: extra(map, @test_case_keys)
    }
  end

  defp parse_conversational_test_case(map, path, index) do
    object!(map, path)

    %ConversationalTestCase{
      expectations_data: map["expectationsData"],
      name: string!(map, "name", path),
      success: map["success"],
      metrics_data: parse_metrics_data(map, path),
      run_duration: value(map, "runDuration", 0.0),
      evaluation_cost: map["evaluationCost"],
      turns: map |> list!("turns", path) |> indexed(path <> ".turns", &parse_turn/3),
      order: value(map, "order", index),
      scenario: map["scenario"],
      expected_outcome: map["expectedOutcome"],
      user_description: map["userDescription"],
      context: map["context"],
      comments: map["comments"],
      metadata: map["metadata"],
      images_mapping: map["imagesMapping"],
      tags: map["tags"],
      flaky: value(map, "flaky", false),
      extra: extra(map, @conversational_test_case_keys)
    }
  end

  defp parse_turn(map, path, index) do
    object!(map, path)

    %Turn{
      role: string!(map, "role", path),
      content: string!(map, "content", path),
      order: value(map, "order", index),
      user_id: map["userId"],
      retrieval_context: map["retrievalContext"],
      tools_called: parse_tool_calls(map, "toolsCalled", path),
      comments: map["comments"],
      extra: extra(map, @turn_keys)
    }
  end

  defp parse_metrics_data(map, path) do
    map
    |> list!("metricsData", path)
    |> indexed(path <> ".metricsData", fn data, data_path, _index ->
      parse_metric_data(data, data_path)
    end)
  end

  defp parse_metric_data(map, path) do
    object!(map, path)

    %MetricData{
      name: string!(map, "name", path),
      threshold: map["threshold"],
      success: map["success"],
      score: map["score"],
      reason: map["reason"],
      strict_mode: value(map, "strictMode", false),
      flaky: value(map, "flaky", false),
      evaluation_model: map["evaluationModel"],
      error: map["error"],
      evaluation_cost: map["evaluationCost"],
      input_tokens: map["inputTokenCount"],
      output_tokens: map["outputTokenCount"],
      verbose_logs: map["verboseLogs"],
      expectations_data: map["expectationsData"],
      extra: extra(map, @metric_data_keys)
    }
  end

  defp parse_scores(map, path, _index) do
    object!(map, path)

    %{
      metric: string!(map, "metric", path),
      scores: list!(map, "scores", path),
      passes: value(map, "passes", 0),
      fails: value(map, "fails", 0),
      errors: value(map, "errors", 0)
    }
  end

  defp parse_tool_calls(map, key, path) do
    case map[key] do
      nil ->
        nil

      tool_calls ->
        tool_calls
        |> list_value!(join(path, key))
        |> indexed(join(path, key), fn tool_call, tool_path, _index ->
          parse_tool_call(tool_call, tool_path)
        end)
    end
  end

  defp parse_tool_call(map, path) do
    object!(map, path)

    %ToolCall{
      name: string!(map, "name", path),
      type: tool_type(map["type"], path),
      description: map["description"],
      reasoning: map["reasoning"],
      input_parameters: map["inputParameters"],
      output: map["output"]
    }
  end

  defp tool_type(nil, _path), do: :function

  defp tool_type(type, path) when is_binary(type) do
    case String.upcase(type) do
      "FUNCTION" -> :function
      "MCP" -> :mcp
      _other -> invalid!(path <> ".type", "expected \"FUNCTION\" or \"MCP\"", type)
    end
  end

  defp tool_type(type, path), do: invalid!(path <> ".type", "expected a string", type)

  defp parse_hyperparameters(nil), do: nil

  defp parse_hyperparameters(hyperparameters) do
    object!(hyperparameters, "hyperparameters")
    Enum.map(hyperparameters, fn {key, value} -> {key, value} end)
  end

  # Applies fun.(item, "<path>[<index>]", index) to each item.
  defp indexed(items, path, fun) do
    items
    |> Enum.with_index()
    |> Enum.map(fn {item, index} -> fun.(item, "#{path}[#{index}]", index) end)
  end

  defp value(map, key, default) do
    case map[key] do
      nil -> default
      value -> value
    end
  end

  defp object!(value, _path) when is_map(value), do: value
  defp object!(value, path), do: invalid!(path, "expected a JSON object", value)

  defp list!(map, key, path) do
    case map[key] do
      nil -> []
      list -> list_value!(list, join(path, key))
    end
  end

  defp list_value!(list, _path) when is_list(list), do: list
  defp list_value!(value, path), do: invalid!(path, "expected a list", value)

  defp string!(map, key, path) do
    case map[key] do
      string when is_binary(string) -> string
      value -> invalid!(join(path, key), "expected a string", value)
    end
  end

  defp join("", key), do: key
  defp join(path, key), do: path <> "." <> key

  defp invalid!(path, expected, value) do
    throw({:invalid_test_run, "#{path}: #{expected}, got #{inspect(value)}"})
  end

  # deepeval's create_api_test_case keeps only a RetrievedContextData's context
  defp contexts(nil), do: nil

  defp contexts(retrieval_context),
    do: Enum.map(retrieval_context, &RetrievedContextData.context/1)

  defp non_empty([]), do: nil
  defp non_empty(list), do: list

  defp to_float(nil), do: nil
  defp to_float(number), do: number / 1
end
