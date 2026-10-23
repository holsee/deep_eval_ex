defmodule DeepEvalEx.Tracing.AdapterSpansTest do
  # The tracing store is one global table and Req.Test stubs belong to the
  # test process, so the tests run concurrently.
  use ExUnit.Case, async: true

  alias DeepEvalEx.{Classifier, Result, TestCase, Tracing}
  alias DeepEvalEx.LLM.Adapter
  alias DeepEvalEx.LLM.Adapters.{Mock, OpenAI}
  alias DeepEvalEx.Tracing.{Span, Trace}

  @usage [mock_usage: [input_tokens: 12, output_tokens: 3]]

  defmodule FailingAdapter do
    @moduledoc false
    use DeepEvalEx.LLM.Adapter

    @impl true
    def generate(_prompt, _opts), do: {:error, %RuntimeError{message: "rate limited"}}
    @impl true
    def generate_with_schema(_prompt, _schema, _opts), do: {:error, :timeout}
    @impl true
    def model_name(_opts), do: "failing-model"
    @impl true
    def supports_structured_outputs?, do: true
    @impl true
    def supports_log_probs?, do: false
  end

  defmodule RaisingAdapter do
    @moduledoc false
    use DeepEvalEx.LLM.Adapter

    @impl true
    def generate(_prompt, _opts), do: raise("connection refused")
    @impl true
    def generate_with_schema(_prompt, _schema, _opts), do: raise("connection refused")
    @impl true
    def model_name(_opts), do: "raising-model"
    @impl true
    def supports_structured_outputs?, do: true
    @impl true
    def supports_log_probs?, do: false
  end

  defmodule JudgingMetric do
    @moduledoc false
    # A metric whose judge goes through the adapter facade.
    use DeepEvalEx.Metrics.BaseMetric

    @impl true
    def metric_name, do: "Judging"

    @impl true
    def required_params, do: []

    def do_measure(_test_case, opts) do
      {:ok, _} = Adapter.generate("judge this", Keyword.take(opts, [:adapter]))
      {:ok, Result.new(metric: metric_name(), score: 1.0, threshold: 0.5)}
    end
  end

  defp capture(fun), do: Tracing.capture([], fun)

  defp in_agent(fun), do: Tracing.span(:agent, [name: "agent"], fun)

  describe "the adapter facade" do
    test "records nothing outside a span" do
      assert {{:ok, "This is a mock response."}, []} =
               capture(fn -> Adapter.generate("hi", [adapter: :mock] ++ @usage) end)
    end

    test "records an :llm child with the model, tokens, input and output inside one" do
      {{:ok, text}, [trace]} =
        capture(fn -> in_agent(fn -> Adapter.generate("hi", [adapter: :mock] ++ @usage) end) end)

      assert [%Span{name: "agent", children: [llm]}] = trace.root_spans

      assert %Span{
               type: :llm,
               name: "generate",
               model: "mock-model",
               input: "hi",
               output: ^text,
               status: :success,
               input_token_count: 12.0,
               output_token_count: 3.0,
               provider: nil,
               integration: nil
             } = llm
    end

    test "names the span after the function and outputs the decoded answer" do
      Mock.script(%{"city" => [%{"city" => "Paris"}]})
      schema = %{"properties" => %{"city" => %{"type" => "string"}}}

      {_, [trace]} =
        capture(fn ->
          in_agent(fn ->
            Adapter.generate_with_schema("extract the city", schema, adapter: :mock)
          end)
        end)

      assert [%Span{children: [llm]}] = trace.root_spans
      assert %Span{name: "generate_with_schema", output: %{"city" => "Paris"}} = llm
      assert %Span{input_token_count: nil, output_token_count: nil} = llm
    end

    test "gives the trace the call's input and output before the root's" do
      {_, [trace]} =
        capture(fn ->
          Tracing.span(:agent, [name: "agent", input: "the question"], fn ->
            {:ok, _} = Adapter.generate("the prompt", adapter: :mock)
            "the agent's answer"
          end)
        end)

      assert %Trace{input: "the prompt", output: "This is a mock response."} = trace
    end

    test "keeps a trace input and output already set" do
      {_, [trace]} =
        capture(fn ->
          Tracing.trace([input: "set input", output: "set output"], fn ->
            in_agent(fn -> Adapter.generate("the prompt", adapter: :mock) end)
          end)
        end)

      assert %Trace{input: "set input", output: "set output"} = trace
    end

    test "marks the span errored for an error answer" do
      {_, [trace]} =
        capture(fn ->
          in_agent(fn ->
            {:error, _} = Adapter.generate("hi", adapter: FailingAdapter)
            {:error, :timeout} = Adapter.generate_with_schema("hi", %{}, adapter: FailingAdapter)
          end)
        end)

      assert [%Span{status: :success, children: [exception, reason]}] = trace.root_spans

      assert %Span{status: :errored, error: "rate limited", model: "failing-model", output: nil} =
               exception

      assert %Span{status: :errored, error: ":timeout"} = reason
      assert %Trace{input: nil} = trace
    end

    test "marks the span errored for a raise and re-raises it" do
      {_, [trace]} =
        capture(fn ->
          in_agent(fn ->
            assert_raise RuntimeError, "connection refused", fn ->
              Adapter.generate("hi", adapter: RaisingAdapter)
            end
          end)
        end)

      assert [%Span{children: [%Span{status: :errored, error: "connection refused"}]}] =
               trace.root_spans
    end

    test "takes the metrics and test-case fields of the trace's llm_span_context" do
      context = [
        metrics: [DeepEvalEx.Metrics.ExactMatch],
        metric_collection: "llm-collection",
        expected_output: "Paris",
        context: ["France's capital is Paris."],
        prompt: %{alias: "city-prompt", version: "00.00.01"}
      ]

      {_, [trace]} =
        capture(fn ->
          Tracing.trace([llm_span_context: context], fn ->
            in_agent(fn -> Adapter.generate("hi", adapter: :mock) end)
          end)
        end)

      assert [%Span{children: [llm]}] = trace.root_spans

      assert %Span{
               metrics: [DeepEvalEx.Metrics.ExactMatch],
               metric_collection: "llm-collection",
               expected_output: "Paris",
               context: ["France's capital is Paris."],
               prompt_alias: "city-prompt",
               prompt_version: "00.00.01"
             } = llm
    end

    test "takes a staged next_llm_span" do
      {_, [trace]} =
        capture(fn ->
          in_agent(fn ->
            Tracing.next_llm_span([metadata: %{"step" => "plan"}], fn ->
              Adapter.generate("hi", adapter: :mock)
            end)
          end)
        end)

      assert [%Span{children: [%Span{metadata: %{"step" => "plan"}}]}] = trace.root_spans
    end

    test "sets the OpenAI adapter's integration and provider, and its usage" do
      Req.Test.stub(OpenAI, fn conn ->
        Req.Test.json(conn, %{
          "choices" => [%{"message" => %{"role" => "assistant", "content" => "Paris"}}],
          "usage" => %{"prompt_tokens" => 20, "completion_tokens" => 2}
        })
      end)

      opts = [
        adapter: :openai,
        model: "gpt-4o-mini",
        api_key: "sk-test",
        req_options: [plug: {Req.Test, OpenAI}, retry: false]
      ]

      {{:ok, "Paris"}, [trace]} =
        capture(fn -> in_agent(fn -> Adapter.generate("capital?", opts) end) end)

      assert [%Span{integration: nil, children: [llm]}] = trace.root_spans

      assert %Span{
               model: "gpt-4o-mini",
               integration: "OpenAI",
               provider: "OpenAI",
               input_token_count: 20.0,
               output_token_count: 2.0,
               output: "Paris"
             } = llm
    end

    test "outputs a raw response's message text" do
      Req.Test.stub(OpenAI, fn conn ->
        Req.Test.json(conn, %{
          "choices" => [%{"message" => %{"content" => "7"}, "logprobs" => %{"content" => []}}]
        })
      end)

      opts = [
        adapter: :openai,
        model: "gpt-4o",
        api_key: "sk-test",
        req_options: [plug: {Req.Test, OpenAI}, retry: false]
      ]

      {_, [trace]} =
        capture(fn -> in_agent(fn -> Adapter.generate_raw_response("score?", opts) end) end)

      assert [%Span{children: [%Span{name: "generate_raw_response", output: "7"}]}] =
               trace.root_spans
    end
  end

  describe "judge calls" do
    test "a metric's judge call inside a span records no span" do
      {_, [trace]} =
        capture(fn ->
          in_agent(fn ->
            {:ok, _} =
              JudgingMetric.measure(TestCase.new!(input: "q", actual_output: "a"),
                adapter: :mock
              )
          end)
        end)

      assert [%Span{name: "agent", children: []}] = trace.root_spans
    end

    test "a classifier's judge call inside a span records no span" do
      Mock.script(%{"label,reason" => [%{"label" => "complied", "reason" => "Answers."}]})
      classifier = DeepEvalEx.Classifiers.refusal(adapter: :mock)

      {_, [trace]} =
        capture(fn ->
          in_agent(fn ->
            Classifier.classify(classifier, TestCase.new!(input: "q", actual_output: "a"))
          end)
        end)

      assert [%Span{name: "agent", children: []}] = trace.root_spans
    end
  end
end
