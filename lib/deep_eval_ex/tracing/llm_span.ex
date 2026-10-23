defmodule DeepEvalEx.Tracing.LLMSpan do
  @moduledoc false
  # The LLM span an instrumented client call records: what deepeval 4.3.1's
  # `deepeval.openai` and `deepeval.anthropic` patchers do around a
  # `create` call (`_patch_sync_openai_client_method`,
  # `model_integrations/utils.py` `_update_all_attributes`), shared by the
  # `DeepEvalEx.LLM.Adapter` facade and `DeepEvalEx.Tracing.ReqStep`.
  #
  # - The span is `:llm`, opened with `drop_if_root: true`: a call outside
  #   any span records nothing (and so does one under `Tracing.suppress/1`,
  #   a metric's judge call).
  # - `Tracing.llm_span_context/0` gives it its `:metrics` and
  #   `:metric_collection` when it opens, and its `:expected_output`,
  #   `:expected_tools`, `:context`, `:retrieval_context` and `:prompt` when
  #   it closes, as the patchers read `current_llm_context`.
  # - A successful call sets the token counts (`update_llm_span`), and the
  #   trace's input and output unless already set, as the patchers'
  #   `__update_input_and_output_of_current_trace`. As there, this happens
  #   before the root span closes, so the call's input wins over the root's
  #   arguments.

  alias DeepEvalEx.Tracing
  alias DeepEvalEx.Tracing.{Ctx, JSON, Store}

  @typedoc """
  How the call ended, returned by the function `run/2` runs alongside its
  result:

  - `:output` - the span's output, and the trace's when it has none
  - `:error` - the error text; the span is `:errored`
  - `:input_token_count`, `:output_token_count` - set unless `nil`
  - `:model` - the model the response names, set when truthy
  - `:trace_input` - the trace's input when it has none (the first user
    message, else the messages)
  """
  @type outcome :: keyword()

  @context_span_fields [:expected_output, :expected_tools, :context, :retrieval_context]

  @doc false
  # Runs `fun`, which returns `{result, outcome}`, inside an LLM span opened
  # with `opts` (`Tracing.open_span/2`'s, `:drop_if_root` forced), and
  # returns `result`. A raise, throw or exit marks the span errored and is
  # re-raised.
  @spec run(keyword(), (-> {result, outcome()})) :: result when result: term()
  def run(opts, fun) when is_function(fun, 0) do
    case open(opts) do
      :ignored ->
        {result, _outcome} = fun.()
        result

      {:ok, ctx} ->
        try do
          fun.()
        catch
          kind, reason ->
            Tracing.close_span(ctx, exception: {kind, reason, __STACKTRACE__})
            :erlang.raise(kind, reason, __STACKTRACE__)
        else
          {result, outcome} ->
            close(ctx, outcome)
            result
        end
    end
  end

  @doc false
  # Opens the LLM span: `:ignored` outside any span or when suppressed.
  @spec open(keyword()) :: {:ok, Ctx.t()} | :ignored
  def open(opts) do
    context = Tracing.llm_span_context() || []

    opts =
      opts
      |> Keyword.merge(Keyword.take(context, [:metrics, :metric_collection]))
      |> Keyword.put(:drop_if_root, true)

    Tracing.open_span(:llm, opts)
  end

  @doc false
  # Closes the span `open/1` opened, with how the call ended.
  @spec close(Ctx.t(), outcome()) :: :ok
  def close(%Ctx{trace_uuid: trace_uuid} = ctx, outcome) do
    case Keyword.fetch(outcome, :error) do
      {:ok, error} ->
        put_tokens(outcome)
        Tracing.close_span(ctx, error: error)

      :error ->
        context = Tracing.llm_span_context() || []
        Tracing.update_current_span(Keyword.take(context, @context_span_fields))
        put_tokens(outcome, Keyword.get(context, :prompt))
        output = Keyword.get(outcome, :output)
        put_trace_defaults(trace_uuid, Keyword.get(outcome, :trace_input), output)
        Tracing.close_span(ctx, output: output)
    end
  end

  defp put_tokens(outcome, prompt \\ nil) do
    Tracing.update_llm_span(
      model: Keyword.get(outcome, :model),
      input_token_count: Keyword.get(outcome, :input_token_count),
      output_token_count: Keyword.get(outcome, :output_token_count),
      prompt: prompt
    )
  end

  # `current_trace.input is None` / `.output is None`: only a trace with no
  # input (output) yet takes the call's.
  defp put_trace_defaults(trace_uuid, input, output) do
    unless is_nil(input), do: Store.put_new_trace_attr(trace_uuid, :input, serializable(input))
    unless is_nil(output), do: Store.put_new_trace_attr(trace_uuid, :output, serializable(output))
  end

  defp serializable(value), do: value |> JSON.make_serializable() |> JSON.mask()
end
