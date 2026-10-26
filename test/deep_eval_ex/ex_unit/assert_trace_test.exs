defmodule DeepEvalEx.ExUnit.AssertTraceTest do
  use ExUnit.Case, async: true
  use DeepEvalEx.ExUnit

  alias DeepEvalEx.Dataset.Golden
  alias DeepEvalEx.{DeepEvalError, Result}
  alias DeepEvalEx.Metrics.ExactMatch
  alias DeepEvalEx.Tracing

  defmodule Probe do
    @moduledoc false
    # Reports the test case each measure gets, scoring 1.0 unless told.
    use DeepEvalEx.Metrics.BaseMetric

    defstruct [:name, :pid, score: 1.0, threshold: 0.5]

    @impl true
    def metric_name, do: "Probe"

    @impl true
    def metric_name(%__MODULE__{name: name}), do: name

    @impl true
    def required_params, do: [:input]

    def do_measure(test_case, opts) do
      send(opts[:pid], {:measured, opts[:name], test_case})
      {:ok, Result.new(metric: opts[:name], score: opts[:score], threshold: opts[:threshold])}
    end
  end

  defmodule Support do
    @moduledoc false
    use DeepEvalEx.Tracing

    deftraced answer(query), type: :agent do
      docs = retrieve(query)
      "Answer to #{query} from #{length(docs)} docs"
    end

    deftraced retrieve(query), type: :retriever do
      Tracing.update_current_span(retrieval_context: ["FAQ: #{query}"])
      ["FAQ: #{query}"]
    end

    deftraced fail(query), type: :agent do
      _ = query
      raise "agent gave up"
    end
  end

  @golden %Golden{
    input: "How do I reset my password?",
    expected_output: "Answer to How do I reset my password? from 1 docs",
    context: ["Passwords are reset from Settings."]
  }

  defp probe(name, opts \\ []), do: struct!(Probe, [name: name, pid: self()] ++ opts)

  # The agent under a span declaring `metrics`.
  defp answer_with(metrics) do
    Tracing.span(
      :agent,
      [name: "outer", input: %{"query" => @golden.input}, metrics: metrics],
      fn ->
        Support.answer(@golden.input)
      end
    )
  end

  test "measures the trace on the golden's input and the first span's output" do
    assert [%Result{metric: "Exact Match", success: true}] =
             assert_trace(@golden, [ExactMatch], fn -> Support.answer(@golden.input) end)
  end

  test "fills the trace-level test case from the golden" do
    assert_trace(@golden, [probe("trace")], fn -> Support.answer(@golden.input) end)

    assert_received {:measured, "trace", test_case}
    assert test_case.input == @golden.input
    assert test_case.actual_output == "Answer to How do I reset my password? from 1 docs"
    assert test_case.expected_output == @golden.expected_output
    assert test_case.context == @golden.context
  end

  test "measures span metrics on the span's own test case" do
    assert_trace(@golden, [], fn -> answer_with([probe("span")]) end)

    assert_received {:measured, "span", test_case}
    assert test_case.input == "{'query': 'How do I reset my password?'}"
    assert test_case.actual_output == "Answer to How do I reset my password? from 1 docs"
  end

  test "flunks with assert_test's message when a trace metric fails" do
    error =
      assert_raise ExUnit.AssertionError, fn ->
        assert_trace(@golden, [probe("strict", score: 0.2)], fn ->
          Support.answer(@golden.input)
        end)
      end

    assert error.message ==
             "Metrics: strict (score: 0.2, threshold: 0.5, strict: False, error: None, " <>
               "reason: None) failed."
  end

  test "fails the test case on a failing span metric, without listing it" do
    error =
      assert_raise ExUnit.AssertionError, fn ->
        assert_trace(@golden, [probe("trace")], fn -> answer_with([probe("span", score: 0.1)]) end)
      end

    assert error.message == "Metrics:  failed."
  end

  test "skips the metrics of a trace whose top-level span errored" do
    assert_raise RuntimeError, "agent gave up", fn ->
      assert_trace(@golden, [probe("trace")], fn -> Support.fail(@golden.input) end)
    end

    refute_received {:measured, _, _}

    assert [] =
             assert_trace(@golden, [probe("trace")], fn ->
               try do
                 Support.fail(@golden.input)
               rescue
                 _ -> :caught
               end
             end)

    refute_received {:measured, _, _}
  end

  test "joins spans made in other processes" do
    assert_trace(@golden, [probe("trace")], fn ->
      Task.async(fn -> Support.answer(@golden.input) end) |> Task.await()
    end)

    assert_received {:measured, "trace", %{actual_output: "Answer to " <> _}}
  end

  test "raises deepeval's error when the function makes no span" do
    error =
      assert_raise DeepEvalError, fn ->
        assert_trace(@golden, [ExactMatch], fn -> :untraced end)
      end

    assert error.message =~ "No active trace found for this test."
  end

  test "needs a metric somewhere, or expectations" do
    assert_raise ArgumentError, ~r/^1 test case is missing expectations\./, fn ->
      assert_trace(@golden, [], fn -> Support.answer(@golden.input) end)
    end
  end
end
