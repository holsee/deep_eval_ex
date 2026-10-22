defmodule DeepEvalEx.SystemOne do
  @moduledoc """
  The single call site for System One models, which answer typed questions
  about a JSON state with probabilities instead of text (TypeSafe AI's Jev,
  or any `DeepEvalEx.SystemOne.Adapter`).

  deepeval 4.3.1 lets a metric route its decisions to such a model. Every
  request goes through `decide/3` here, which:

  - resolves the System One model (see `DeepEvalEx.SystemOne.Model`)
  - wraps the call in a `[:deep_eval_ex, :system_one, :request]` telemetry
    span
  - returns System One errors as `{:error, exception}`, whether the adapter
    returned or raised them, and lets anything else propagate, as deepeval
    catches only its `_system_one_error_types`
  - stamps the call's usage as System One's and returns it, without
    recording it, so the caller decides how to book it

  `noul/3`, `choice/3` and `score/3` return the answers of one type, as
  deepeval's `DeepEvalBaseSystemOneModel.noul`, `choice` and `score` do.

  ## Examples

      questions = [
        {"q_0", %DeepEvalEx.SystemOne.Question.Noul{instructions: "`actual_output` answers `input`."}}
      ]

      {:ok, answers, usage} =
        DeepEvalEx.SystemOne.decide(%{"test_case" => %{"input" => "Q", "actual_output" => "A"}},
          questions,
          system_one_model: {MyApp.LogprobJudge, api_key: "..."}
        )

  ## System One errors

  These are handled, deepeval's `_system_one_error_types`:

  - `DeepEvalEx.SystemOne.Error`
  - `DeepEvalEx.DeepEvalError` and `DeepEvalEx.ContextWindowExceededError`
  - `Req.TransportError`, returned as an `Error` with `reason: :timeout`
    (type `"TimeoutError"`) for a timeout, otherwise `reason: :connection`
    (type `"ConnectionError"`)
  - an exit on timeout, returned as an `Error` with `reason: :timeout`

  Any other exception, returned or raised, propagates (a `KeyError` is a
  bug, never a fallback). An adapter reply outside its contract raises
  `ArgumentError`.

  ## Telemetry

  `[:deep_eval_ex, :system_one, :request, :start | :stop | :exception]`,
  with the metadata `:model` (the model name), `:mode`, `:metrics`,
  `:question_count` and `:batched?`, plus `:error` on a `:stop` for a
  handled error. `:stop` measures `:duration`, and `:input_tokens`,
  `:output_tokens` and `:cost` when the request reported them.
  """

  alias DeepEvalEx.{ContextWindowExceededError, DeepEvalError}
  alias DeepEvalEx.LLM.Usage
  alias DeepEvalEx.SystemOne.{Adapter, Answers, Error, Model, Question}

  @event [:deep_eval_ex, :system_one, :request]

  @type result :: {:ok, Answers.t(), Usage.t() | nil} | {:error, Exception.t()}

  @doc """
  Asks the System One model every question about `state`.

  Returns `{:ok, answers, usage}`, where `usage` is the request's
  `DeepEvalEx.LLM.Usage` with `source: :system_one` (named after the model
  when the adapter left it unnamed) or `nil` when the request could not be
  priced, or `{:error, exception}` for a System One error (see the module
  docs).

  ## Options

  - `:system_one_model` - the model, anything
    `DeepEvalEx.SystemOne.Model.resolve/1` accepts (default: `nil`, the
    configured model)
  - `:mode` - the eval mode the request is made under, for telemetry
  - `:metrics` - the names of the metrics the request decides for, for
    telemetry (default: `[]`)
  - `:batched?` - whether the request merges several metrics' questions,
    for telemetry (default: `false`)
  """
  @spec decide(Adapter.state(), Question.questions(), keyword()) :: result()
  def decide(state, questions, opts \\ []) when is_list(questions) do
    model = Model.resolve(Keyword.get(opts, :system_one_model))

    metadata = %{
      model: model.name,
      mode: Keyword.get(opts, :mode),
      metrics: Keyword.get(opts, :metrics, []),
      question_count: length(questions),
      batched?: Keyword.get(opts, :batched?, false)
    }

    :telemetry.span(@event, metadata, fn ->
      result = call(model, state, questions)
      {result, measurements(result), stop_metadata(metadata, result)}
    end)
  end

  @doc """
  Asks `decide/3` and returns the Noul answers only, by key.
  """
  @spec noul(Adapter.state(), Question.questions(), keyword()) ::
          {:ok, %{String.t() => Answers.Noul.t()}, Usage.t() | nil} | {:error, Exception.t()}
  def noul(state, questions, opts \\ []), do: state |> decide(questions, opts) |> take(:nouls)

  @doc """
  Asks `decide/3` and returns the Choice answers only, by key.
  """
  @spec choice(Adapter.state(), Question.questions(), keyword()) ::
          {:ok, %{String.t() => Answers.Choice.t()}, Usage.t() | nil} | {:error, Exception.t()}
  def choice(state, questions, opts \\ []), do: state |> decide(questions, opts) |> take(:choices)

  @doc """
  Asks `decide/3` and returns the Score answers only, by key.
  """
  @spec score(Adapter.state(), Question.questions(), keyword()) ::
          {:ok, %{String.t() => Answers.Score.t()}, Usage.t() | nil} | {:error, Exception.t()}
  def score(state, questions, opts \\ []), do: state |> decide(questions, opts) |> take(:scores)

  defp take({:ok, answers, usage}, kind), do: {:ok, Map.fetch!(answers, kind), usage}
  defp take({:error, _} = error, _kind), do: error

  defp call(%Model{adapter: adapter, opts: opts} = model, state, questions) do
    state |> adapter.decide(questions, opts) |> reply(model)
  rescue
    exception ->
      if system_one_error?(exception),
        do: {:error, normalize(exception)},
        else: reraise(exception, __STACKTRACE__)
  catch
    :exit, {:timeout, _} ->
      {:error,
       %Error{reason: :timeout, type: "TimeoutError", message: "System One request timed out"}}
  end

  defp reply({:ok, %Answers{} = answers, usage}, model)
       when is_nil(usage) or is_struct(usage, Usage),
       do: {:ok, answers, stamp(usage, model)}

  defp reply({:error, exception}, _model) when is_exception(exception) do
    if system_one_error?(exception), do: {:error, normalize(exception)}, else: raise(exception)
  end

  defp reply(other, %Model{adapter: adapter}) do
    raise ArgumentError,
          "System One adapter #{inspect(adapter)} returned #{inspect(other)}; expected " <>
            "{:ok, %DeepEvalEx.SystemOne.Answers{}, %DeepEvalEx.LLM.Usage{} | nil} or {:error, exception}"
  end

  defp system_one_error?(exception) do
    is_struct(exception, Error) or is_struct(exception, DeepEvalError) or
      is_struct(exception, ContextWindowExceededError) or is_struct(exception, Req.TransportError)
  end

  defp normalize(%Req.TransportError{reason: :timeout} = exception),
    do: %Error{reason: :timeout, type: "TimeoutError", message: Exception.message(exception)}

  defp normalize(%Req.TransportError{} = exception),
    do: %Error{
      reason: :connection,
      type: "ConnectionError",
      message: Exception.message(exception)
    }

  defp normalize(exception), do: exception

  defp stamp(nil, _model), do: nil

  defp stamp(%Usage{} = usage, %Model{name: name}),
    do: %{usage | source: :system_one, model: usage.model || name}

  defp measurements({:ok, _answers, %Usage{} = usage}) do
    for {key, value} <- [
          input_tokens: usage.input_tokens,
          output_tokens: usage.output_tokens,
          cost: usage.cost
        ],
        value != nil,
        into: %{},
        do: {key, value}
  end

  defp measurements(_result), do: %{}

  defp stop_metadata(metadata, {:error, error}), do: Map.put(metadata, :error, error)
  defp stop_metadata(metadata, _result), do: metadata
end
