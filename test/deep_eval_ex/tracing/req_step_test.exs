defmodule DeepEvalEx.Tracing.ReqStepTest do
  # The tracing store is one global table and Req.Test stubs belong to the
  # test process, so the tests run concurrently.
  use ExUnit.Case, async: true

  alias DeepEvalEx.Tracing
  alias DeepEvalEx.Tracing.{ReqStep, Span, Trace}

  @messages [
    %{"role" => "system", "content" => "Be brief."},
    %{"role" => "user", "content" => "Capital of France?"}
  ]

  @chat %{
    "model" => "gpt-4o-mini-2024-07-18",
    "choices" => [%{"message" => %{"role" => "assistant", "content" => "Paris"}}],
    "usage" => %{"prompt_tokens" => 21, "completion_tokens" => 1}
  }

  defp req(opts \\ []) do
    Req.new(base_url: "http://llm.test", plug: {Req.Test, __MODULE__}, retry: false)
    |> ReqStep.attach(opts)
  end

  defp stub(body, status \\ 200) do
    Req.Test.stub(__MODULE__, fn conn ->
      conn |> Plug.Conn.put_status(status) |> Req.Test.json(body)
    end)
  end

  defp chat(req, json \\ %{model: "gpt-4o-mini", messages: @messages}),
    do: Req.post!(req, url: "/chat/completions", json: json)

  defp capture(fun), do: Tracing.capture([], fun)

  defp in_agent(fun), do: Tracing.span(:agent, [name: "agent"], fun)

  test "records nothing outside a span" do
    stub(@chat)
    assert {%Req.Response{status: 200}, []} = capture(fn -> chat(req()) end)
  end

  test "records an OpenAI chat completion as an :llm child" do
    stub(@chat)

    {_, [trace]} =
      capture(fn ->
        in_agent(fn -> chat(req(provider: "OpenAI", integration: "OpenAI")) end)
      end)

    assert [%Span{name: "agent", children: [llm]}] = trace.root_spans

    assert %Span{
             type: :llm,
             name: "llm_generation",
             model: "gpt-4o-mini",
             input: @messages,
             output: "Paris",
             input_token_count: 21.0,
             output_token_count: 1.0,
             provider: "OpenAI",
             integration: "OpenAI",
             status: :success
           } = llm

    assert %Trace{input: "Capital of France?", output: "Paris"} = trace
  end

  test "reads Anthropic and Ollama responses" do
    stub(%{
      "model" => "claude-sonnet-4-5",
      "content" => [%{"type" => "text", "text" => "Paris"}],
      "usage" => %{"input_tokens" => 9, "output_tokens" => 4}
    })

    {_, [anthropic]} =
      capture(fn -> in_agent(fn -> chat(req(), %{messages: @messages}) end) end)

    assert [%Span{children: [llm]}] = anthropic.root_spans

    assert %Span{
             model: "claude-sonnet-4-5",
             output: "Paris",
             input_token_count: 9.0,
             output_token_count: 4.0
           } = llm

    stub(%{"message" => %{"content" => "Lyon"}, "prompt_eval_count" => 5, "eval_count" => 2})

    {_, [ollama]} =
      capture(fn -> in_agent(fn -> chat(req(name: "ollama", model: "llama3")) end) end)

    assert [%Span{children: [llm]}] = ollama.root_spans

    assert %Span{
             name: "ollama",
             model: "gpt-4o-mini",
             output: "Lyon",
             input_token_count: 5.0,
             output_token_count: 2.0
           } = llm
  end

  test "reads an OpenAI Responses answer and a JSON body" do
    stub(%{
      "output" => [
        %{"type" => "message", "content" => [%{"type" => "output_text", "text" => "Par"}]},
        %{"type" => "message", "content" => [%{"type" => "output_text", "text" => "is"}]}
      ],
      "usage" => %{"input_tokens" => 3, "output_tokens" => 2}
    })

    body = Jason.encode!(%{model: "gpt-4.1", input: "Capital of France?"})

    {_, [trace]} =
      capture(fn ->
        in_agent(fn -> Req.post!(req(), url: "/responses", body: body) end)
      end)

    assert [%Span{children: [llm]}] = trace.root_spans
    assert %Span{model: "gpt-4.1", input: "Capital of France?", output: "Paris"} = llm
  end

  test "marks the span errored for an error status" do
    stub(%{"error" => %{"message" => "Rate limit"}}, 429)

    {_, [trace]} = capture(fn -> in_agent(fn -> chat(req()) end) end)

    assert [%Span{status: :success, children: [llm]}] = trace.root_spans
    assert %Span{status: :errored, error: "HTTP 429: " <> _, output: nil} = llm
    assert %Trace{input: nil} = trace
  end

  test "marks the span errored for a transport error" do
    Req.Test.stub(__MODULE__, &Req.Test.transport_error(&1, :econnrefused))

    {_, [trace]} =
      capture(fn -> in_agent(fn -> {:error, _} = Req.post(req(), url: "/x", json: %{}) end) end)

    assert [%Span{children: [%Span{status: :errored, error: "connection refused"}]}] =
             trace.root_spans
  end

  test "records retries as one span that ends with the final response" do
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(__MODULE__, fn conn ->
      case Agent.get_and_update(attempts, &{&1, &1 + 1}) do
        0 -> conn |> Plug.Conn.put_status(503) |> Req.Test.json(%{})
        _ -> Req.Test.json(conn, @chat)
      end
    end)

    retrying = Req.merge(req(), retry: :transient, retry_delay: 0, retry_log_level: false)

    {_, [trace]} = capture(fn -> in_agent(fn -> chat(retrying) end) end)

    assert Agent.get(attempts, & &1) == 2
    assert [%Span{children: [%Span{status: :success, output: "Paris"}]}] = trace.root_spans
  end

  test "records nothing under suppress/1" do
    stub(@chat)

    {_, [trace]} =
      capture(fn -> in_agent(fn -> Tracing.suppress(fn -> chat(req()) end) end) end)

    assert [%Span{children: []}] = trace.root_spans
  end

  test "rejects an unknown option" do
    assert_raise ArgumentError, fn -> ReqStep.attach(Req.new(), bogus: 1) end
  end
end
