defmodule DeepEvalEx.SystemOne.Batch do
  @moduledoc """
  Batched System One for `DeepEvalEx.Evaluator`: every metric System One
  judges on a test case, asked in as few requests as the context budget
  allows. A port of deepeval 4.3.1's `system_one_batch.py`.

  Under the `:system_one` eval mode a metric's own measure sends one
  request (`DeepEvalEx.SystemOne.Runner`), re-sending the same test case
  each time. System One answers every question in a request independently
  against one shared state, so before a test case's metrics run,
  `prefetch/3` merges their states and questions into one request and hands
  each metric back its own answers and share of the usage. Each metric then
  runs its normal `measure/2` with them (`opts[:system_one_prefetched]`), so
  scoring, strict mode, usage, telemetry and timeouts take the same path as
  an unbatched measure.

  ## Candidates

  As deepeval's `_candidates`, a metric is a candidate when its effective
  eval mode (its `DeepEvalEx.SystemOne.Context`) is `:system_one`
  (deepeval also leaves out multimodal test cases, whose metrics all
  decline them). With fewer than two candidates nothing is batched. A
  `DeepEvalEx.ConversationalTestCase`'s conversational metrics are batched
  likewise, their states merged turn by turn. A candidate whose
  `c:DeepEvalEx.Metrics.BaseMetric.system_one_eval_spec/2` declines the test
  case (ToolCorrectness always does) still counts, then runs its own
  measure.

  ## Requests

  Each candidate's test case params are validated and its request built
  (`DeepEvalEx.SystemOne.Runner.request_for/3`). The requests are packed
  greedily, in metric order: a metric joins the first request that asks the
  same model (by name), whose state merges with its own
  (`DeepEvalEx.SystemOne.State.merge/2`) and that stays within the model's
  context budget once merged, or starts a new one. A request's question
  keys are prefixed `"m<j>."`, `j` being the metric's place in it.

  The requests run concurrently, each checked against the context budget
  first, and every request's usage is split among its metrics by their
  share of its questions (`split_usage/2`).

  ## Errors

  Nothing falls back to the LLM. A failed request fails each of its
  metrics with a `DeepEvalEx.SystemOne.Batch.Error` whose message is
  deepeval's `format_error_text` (`"ConnectionError: Jev is down"`), and
  so does a candidate whose params or request could not be prepared. A
  context overflow of a request asking for one metric only is reported as
  that metric's `DeepEvalEx.ContextWindowExceededError`, as unbatched.
  """

  alias DeepEvalEx.LLM.Usage

  alias DeepEvalEx.{
    ConversationalTestCase,
    MissingTestCaseParamsError,
    Result,
    SystemOne,
    TestCase
  }

  alias DeepEvalEx.Prompts.Python
  alias DeepEvalEx.SystemOne.{Answers, Context, Decision, Limits, Model, Runner, State}

  defmodule Error do
    @moduledoc """
    A batched System One request, or the preparation of a metric's part in
    it, failed. `:message` is deepeval's `format_error_text` of the
    failure, `"<type>: <message>"`, which an ignored error records;
    `:original` is the failure itself: the exception to re-raise, or the
    `DeepEvalEx.TestCase.validate_params/2` error of a test case missing
    the metric's params.
    """

    @type t :: %__MODULE__{message: String.t(), original: Exception.t() | term()}

    defexception [:message, :original]
  end

  @typedoc "A metric to batch: its module and the options it measures with."
  @type entry :: {module(), keyword()}

  @typedoc """
  What a metric measures with instead of its own request
  (`opts[:system_one_prefetched]`): its answers, keys unprefixed, and
  usage share, or the request's error.
  """
  @type prefetched :: {:answers, Answers.t(), Usage.t() | nil} | {:error, Error.t()}

  @typedoc """
  A metric's part in the batch: `nil` when it was not batched, so measures
  as usual; `{:setup_failed, error}` when its params or request could not
  be prepared, so it errors without measuring; otherwise what it was
  prefetched.
  """
  @type outcome :: prefetched() | {:setup_failed, Error.t()} | nil

  @doc """
  Prefetches the System One answers of the `:system_one` metrics among
  `entries` on `test_case`, returning each entry's `t:outcome/0` in order.
  See the module docs.

  ## Options

  - `:timeout` - how long the requests may take, in milliseconds or
    `:infinity` (default: `:infinity`). Metrics whose request is still
    running then are not prefetched
  - `:max_concurrency` - the most requests sent at once (default: all)
  """
  @spec prefetch(TestCase.t() | ConversationalTestCase.t(), [entry()], keyword()) ::
          [outcome()]
  def prefetch(test_case, entries, opts \\ [])

  def prefetch(test_case, entries, opts)
      when (is_struct(test_case, TestCase) or is_struct(test_case, ConversationalTestCase)) and
             is_list(entries) do
    candidates =
      for {{module, metric_opts}, index} <- Enum.with_index(entries),
          candidate?(module, test_case, metric_opts),
          do: {index, module, metric_opts}

    outcomes =
      if length(candidates) < 2,
        do: %{},
        else: batch(test_case, candidates, opts)

    for index <- 0..(length(entries) - 1)//1, do: Map.get(outcomes, index)
  end

  # deepeval's _candidates: metrics of the test case's kind (conversational
  # metrics for a conversational test case) whose effective eval mode is
  # :system_one. DeepEvalEx has no result cache. A multimodal test case's
  # metrics all decline it, so it is not batched.
  defp candidate?(_module, %ConversationalTestCase{multimodal: true}, _opts), do: false

  defp candidate?(module, test_case, opts) do
    accepts?(module, test_case) and
      match?(%Context{mode: :system_one}, Keyword.get(opts, :system_one))
  end

  # A metric of the test case's kind; the expectations evaluator
  # (`accepts_test_case?/1`) takes both kinds, as deepeval has one evaluator
  # class per kind.
  defp accepts?(module, test_case) do
    if Code.ensure_loaded?(module) and function_exported?(module, :accepts_test_case?, 1),
      do: module.accepts_test_case?(test_case),
      else: conversational_metric?(module) == is_struct(test_case, ConversationalTestCase)
  end

  # A BaseConversationalMetric, which alone defines requires_chatbot_role?/0.
  defp conversational_metric?(module),
    do: Code.ensure_loaded?(module) and function_exported?(module, :requires_chatbot_role?, 0)

  defp batch(test_case, candidates, opts) do
    {failed, prepared} =
      candidates
      |> Enum.map(&setup(&1, test_case))
      |> Enum.reject(&is_nil/1)
      |> Enum.split_with(&match?({_index, {:setup_failed, _}}, &1))

    prepared
    |> Enum.map(fn {_index, entry} -> entry end)
    |> pack()
    |> run(opts)
    |> Enum.concat(failed)
    |> Map.new()
  end

  # deepeval's _setup: `nil` leaves the metric to its own measure.
  defp setup({index, module, opts}, test_case) do
    name = Keyword.get(opts, :metric_name) || module.metric_name()

    with :ok <- validate(module, test_case),
         {spec, state, questions} <- Runner.request_for(module, test_case, opts) do
      %Context{model: model} = Keyword.fetch!(opts, :system_one)

      {index,
       %{
         index: index,
         name: name,
         model: model,
         spec: spec,
         state: state,
         questions: questions
       }}
    else
      nil ->
        nil

      {:error, reason} ->
        missing = %MissingTestCaseParamsError{
          message: Result.error(name, reason).error,
          metric: name,
          reason: reason
        }

        {index, {:setup_failed, failure(missing, reason)}}
    end
  rescue
    exception ->
      {index, {:setup_failed, failure(exception, exception)}}
  end

  defp validate(module, test_case) do
    if function_exported?(module, :validate_test_case, 1),
      do: module.validate_test_case(test_case),
      else: :ok
  end

  # deepeval's _pack: each entry joins the first request that admits it,
  # or starts a new one.
  defp pack(entries), do: Enum.reduce(entries, [], &admit(&2, &1))

  defp admit([], entry), do: [%{entries: [entry], state: entry.state, model: entry.model}]

  defp admit([request | rest], entry) do
    case merge(request, entry) do
      nil -> [request | admit(rest, entry)]
      merged -> [merged | rest]
    end
  end

  defp merge(%{model: model} = request, entry) do
    with true <- model.name == entry.model.name,
         %Jason.OrderedObject{} = state <- State.merge(request.state, entry.state),
         merged = %{request | entries: request.entries ++ [entry], state: state},
         :ok <- Limits.check(state, questions(merged), Model.context_budget(model)) do
      merged
    else
      _refused -> nil
    end
  end

  defp questions(%{entries: entries}) do
    for {entry, j} <- Enum.with_index(entries),
        {key, question} <- entry.questions,
        do: {"m#{j}.#{key}", question}
  end

  defp run(requests, opts) do
    requests
    |> Task.async_stream(&call/1,
      ordered: true,
      timeout: Keyword.get(opts, :timeout, :infinity),
      on_timeout: :kill_task,
      max_concurrency: Keyword.get(opts, :max_concurrency, max(length(requests), 1))
    )
    |> Enum.zip(requests)
    |> Enum.flat_map(fn
      {{:ok, result}, request} -> settle(request, result)
      {{:exit, _reason}, _request} -> []
    end)
  end

  # deepeval's _call: the merged state is the whole test case, the largest
  # any metric builds, so the budget is checked here rather than left to
  # the model.
  @spec call(map()) :: {:ok, Answers.t(), Usage.t() | nil} | {:error, Exception.t()}
  defp call(%{model: model, state: state, entries: entries} = request) do
    questions = questions(request)

    with :ok <- Limits.check(state, questions, Model.context_budget(model)) do
      SystemOne.decide(state, questions,
        system_one_model: model,
        mode: :system_one,
        metrics: Enum.map(entries, & &1.name),
        batched?: length(entries) > 1
      )
    end
  rescue
    exception -> {:error, exception}
  end

  # deepeval's _settle.
  defp settle(%{entries: entries}, {:ok, answers, usage}) do
    shares = split_usage(usage, Enum.map(entries, &length(&1.questions)))

    for {{entry, share}, j} <- entries |> Enum.zip(shares) |> Enum.with_index() do
      {entry.index, {:answers, Answers.take_prefix(answers, "m#{j}."), share}}
    end
  end

  defp settle(%{entries: entries}, {:error, error}) do
    error = request_error(entries, error)
    failure = {:error, failure(error, error)}
    for entry <- entries, do: {entry.index, failure}
  end

  defp failure(exception, original),
    do: %Error{message: SystemOne.Error.format(exception), original: original}

  # deepeval's _request_error.
  defp request_error([entry], %SystemOne.Error{reason: :context_limit} = error),
    do: Decision.context_limit_error(entry.name, error)

  defp request_error(_entries, error), do: error

  @doc """
  Splits a request's `usage` among its metrics by `weights`, their numbers
  of questions, deepeval's `_split_cost`: each share's cost is the cost
  times the metric's fraction of the questions, and its token counts are
  apportioned so that they add up to the request's (`apportion/2`). An
  unpriced request (`nil`) gives every metric `nil`.

  ## Examples

      iex> usage = %DeepEvalEx.LLM.Usage{cost: 0.000126, input_tokens: 3001, output_tokens: 0}
      iex> usage |> DeepEvalEx.SystemOne.Batch.split_usage([3, 3, 3]) |> Enum.map(&{&1.cost, &1.input_tokens})
      [{4.2e-05, 1000}, {4.2e-05, 1001}, {4.2e-05, 1000}]
  """
  @spec split_usage(Usage.t() | nil, [pos_integer()]) :: [Usage.t() | nil]
  def split_usage(nil, weights), do: Enum.map(weights, fn _ -> nil end)

  def split_usage(%Usage{} = usage, weights) do
    whole = Enum.sum(weights)

    [
      weights,
      apportion(usage.input_tokens, weights),
      apportion(usage.output_tokens, weights)
    ]
    |> Enum.zip_with(fn [weight, input_tokens, output_tokens] ->
      fraction = weight / whole

      %{
        usage
        | cost: usage.cost && usage.cost * fraction,
          input_tokens: input_tokens,
          output_tokens: output_tokens
      }
    end)
  end

  @doc """
  Splits the integer `total` by `weights` so that the parts add up to it,
  deepeval's `_apportion`: each part ends where the running share of the
  total, rounded half to even as Python's `round/1`, does. `nil` gives `nil`
  parts.

  ## Examples

      iex> DeepEvalEx.SystemOne.Batch.apportion(3001, [3, 3, 3])
      [1000, 1001, 1000]

      iex> DeepEvalEx.SystemOne.Batch.apportion(nil, [1, 2])
      [nil, nil]
  """
  @spec apportion(non_neg_integer() | nil, [pos_integer()]) :: [non_neg_integer() | nil]
  def apportion(nil, weights), do: Enum.map(weights, fn _ -> nil end)

  def apportion(total, weights) when is_integer(total) do
    whole = Enum.sum(weights)

    bounds =
      weights
      |> Enum.scan(&(&1 + &2))
      |> Enum.map(&round_half_even(total * &1 / whole))

    [0 | bounds]
    |> Enum.zip(bounds)
    |> Enum.map(fn {low, high} -> high - low end)
  end

  defp round_half_even(float), do: float |> Python.round(0) |> trunc()
end
