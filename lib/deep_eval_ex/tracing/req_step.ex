defmodule DeepEvalEx.Tracing.ReqStep do
  @moduledoc """
  Req steps that record an app's own LLM requests as `:llm` spans, the
  Elixir counterpart of deepeval 4.3.1's `deepeval.openai` and
  `deepeval.anthropic` patchers for an app that calls its provider with
  `Req` rather than through `DeepEvalEx.LLM.Adapter` (whose calls are
  traced already).

      req =
        Req.new(base_url: "https://api.openai.com/v1", auth: {:bearer, key})
        |> DeepEvalEx.Tracing.ReqStep.attach(provider: "OpenAI", integration: "OpenAI")

      Req.post!(req, url: "/chat/completions", json: %{model: "gpt-4o-mini", messages: messages})

  Each request made inside a span is one `:llm` span, a child of the
  current span; a request outside any span records nothing (deepeval's
  `_drop_if_root`), and neither does one under
  `DeepEvalEx.Tracing.suppress/1`. Retries and redirects are part of the
  request's span, which closes with the final response.

  The span reads the provider's JSON:

  - its model is the request's `"model"` (else the response's), and its
    input the request's `"messages"` (else its `"input"` or `"prompt"`);
  - its output is the answer's text: OpenAI's chat `choices[0].message.content`
    or Responses `output_text` parts, Anthropic's first `content` block's
    `text`, or Ollama's `message.content` or `response`;
  - its token counts are the response's `usage` (`prompt_tokens` and
    `completion_tokens`, or `input_tokens` and `output_tokens`) or
    Ollama's `prompt_eval_count` and `eval_count`;
  - a response with status 400 or above, or a transport error, makes it
    `:errored`, as the Python clients raise.

  The trace takes the first user message (else the messages) as its input
  and the answer as its output when it has none yet, and
  `DeepEvalEx.Tracing.trace/2`'s `:llm_span_context` gives the span its
  metrics, metric collection, prompt and test-case fields, as in deepeval.
  Tool calls in a response are not recorded.

  The steps need `Req`, which DeepEvalEx depends on.
  """

  alias DeepEvalEx.Tracing.LLMSpan

  @span :deep_eval_ex_llm_span
  @opts :deep_eval_ex_llm_span_opts

  @doc """
  Adds the steps to `request`: the span opens after the other request
  steps and closes after the other response and error steps.

  ## Options

  - `:name` - The span's name, by default `"llm_generation"`, the name
    deepeval's patchers give it
  - `:provider`, `:integration` - The span's, e.g. `"OpenAI"` (deepeval's
    `Provider` and `Integration` values); by default none, so the span
    takes its parent's integration
  - `:model` - The span's model, when the request and response name none
  - `:metadata` - The span's metadata
  """
  @spec attach(Req.Request.t(), keyword()) :: Req.Request.t()
  def attach(%Req.Request{} = request, opts \\ []) do
    opts = Keyword.validate!(opts, [:name, :provider, :integration, :model, :metadata])

    request
    |> Req.Request.put_private(@opts, opts)
    |> Req.Request.append_request_steps(deep_eval_ex_open_span: &open_span/1)
    |> Req.Request.append_response_steps(deep_eval_ex_close_span: &close_span/1)
    |> Req.Request.append_error_steps(deep_eval_ex_close_span: &close_span/1)
  end

  @doc false
  # A retry or redirect runs the request steps again with the open span in
  # the request: it stays the one span.
  @spec open_span(Req.Request.t()) :: Req.Request.t()
  def open_span(request) do
    if Req.Request.get_private(request, @span) do
      request
    else
      opts = Req.Request.get_private(request, @opts, [])
      body = request_body(request)

      span_opts =
        [
          name: Keyword.get(opts, :name, "llm_generation"),
          model: string(body["model"]) || Keyword.get(opts, :model),
          input: messages(body)
        ] ++ Keyword.take(opts, [:provider, :integration, :metadata])

      case LLMSpan.open(span_opts) do
        {:ok, ctx} -> Req.Request.put_private(request, @span, ctx)
        :ignored -> request
      end
    end
  end

  @doc false
  @spec close_span({Req.Request.t(), Req.Response.t() | Exception.t()}) ::
          {Req.Request.t(), Req.Response.t() | Exception.t()}
  def close_span({request, response_or_exception}) do
    case Req.Request.get_private(request, @span) do
      nil ->
        {request, response_or_exception}

      ctx ->
        LLMSpan.close(ctx, outcome(request_body(request), response_or_exception))
        {Req.Request.put_private(request, @span, nil), response_or_exception}
    end
  end

  defp outcome(_request_body, %Req.Response{status: status, body: body}) when status >= 400,
    do: [error: "HTTP #{status}: #{inspect(body)}"] ++ tokens(body)

  defp outcome(request_body, %Req.Response{body: body}) do
    [
      output: output(body),
      trace_input: first_user_message(request_body) || messages(request_body)
    ] ++
      tokens(body) ++ model(request_body, body)
  end

  defp outcome(_request_body, exception), do: [error: Exception.message(exception)]

  # The request's JSON: the `:json` option, else a JSON body.
  defp request_body(request) do
    case request.options[:json] do
      json when is_map(json) -> stringify_keys(json)
      nil -> decode(request.body)
      _other -> %{}
    end
  end

  defp decode(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{} = json} -> json
      _ -> %{}
    end
  end

  defp decode(_body), do: %{}

  defp stringify_keys(json), do: json |> Jason.encode!() |> Jason.decode!()

  defp messages(%{"messages" => messages}), do: messages
  defp messages(%{"input" => input}), do: input
  defp messages(%{"prompt" => prompt}), do: prompt
  defp messages(_body), do: nil

  defp first_user_message(%{"messages" => messages}) when is_list(messages) do
    Enum.find_value(messages, fn
      %{"role" => "user", "content" => content} -> content
      _message -> nil
    end)
  end

  defp first_user_message(%{"input" => input}) when is_binary(input), do: input
  defp first_user_message(%{"prompt" => prompt}) when is_binary(prompt), do: prompt
  defp first_user_message(_body), do: nil

  # OpenAI chat completions
  defp output(%{"choices" => [%{"message" => message} | _]}), do: Map.get(message, "content")
  # OpenAI Responses
  defp output(%{"output" => items}) when is_list(items) do
    for(
      %{"content" => parts} when is_list(parts) <- items,
      %{"type" => "output_text", "text" => text} <- parts,
      do: text
    )
    |> Enum.join()
  end

  # Anthropic Messages
  defp output(%{"content" => [%{"text" => text} | _]}), do: text
  # Ollama chat and generate
  defp output(%{"message" => %{"content" => content}}), do: content
  defp output(%{"response" => response}) when is_binary(response), do: response
  defp output(_body), do: nil

  defp tokens(%{"usage" => %{} = usage}) do
    [
      input_token_count: usage["prompt_tokens"] || usage["input_tokens"],
      output_token_count: usage["completion_tokens"] || usage["output_tokens"]
    ]
  end

  defp tokens(%{} = body) do
    [input_token_count: body["prompt_eval_count"], output_token_count: body["eval_count"]]
  end

  defp tokens(_body), do: []

  # A model only the response names (the span opened without one).
  defp model(%{"model" => model}, _response_body) when is_binary(model), do: []
  defp model(_request_body, %{"model" => model}) when is_binary(model), do: [model: model]
  defp model(_request_body, _response_body), do: []

  defp string(value) when is_binary(value), do: value
  defp string(_value), do: nil
end
