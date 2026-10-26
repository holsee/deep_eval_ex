defmodule DeepEvalEx.LLM.UsageTest do
  use ExUnit.Case, async: true

  alias DeepEvalEx.LLM.{Adapter, Usage}

  doctest Usage

  describe "new/3" do
    test "prices the call from the model's pricing" do
      usage = Usage.new("gpt-4o-mini", 1_000_000, 0)

      assert %Usage{model: "gpt-4o-mini", input_tokens: 1_000_000, output_tokens: 0} = usage
      assert_in_delta usage.cost, 0.15, 1.0e-12
    end

    test "leaves cost nil for an unpriced model" do
      assert %Usage{cost: nil, input_tokens: 10} = Usage.new("unpriced-model", 10, 5)
    end
  end

  describe "track/1" do
    test "collects every usage recorded while the function runs, in order" do
      {result, usages} =
        Usage.track(fn ->
          Usage.record(Usage.new("gpt-4o", 1, 2))
          Usage.record(Usage.new("gpt-4o", 3, 4))
          :done
        end)

      assert result == :done
      assert [%Usage{input_tokens: 1}, %Usage{input_tokens: 3}] = usages
    end

    test "record/1 outside a scope is a no-op" do
      assert Usage.record(Usage.new("gpt-4o", 1, 2)) == :ok
      assert {:ok, []} = Usage.track(fn -> :ok end)
    end

    test "nested scopes are isolated and the outer scope is restored" do
      {inner, outer} =
        Usage.track(fn ->
          Usage.record(Usage.new("gpt-4o", 1, 1))
          {_, inner} = Usage.track(fn -> Usage.record(Usage.new("gpt-4o", 2, 2)) end)
          Usage.record(Usage.new("gpt-4o", 3, 3))
          inner
        end)

      assert Enum.map(inner, & &1.input_tokens) == [2]
      assert Enum.map(outer, & &1.input_tokens) == [1, 3]
    end

    test "restores the outer scope when the function raises" do
      {_, usages} =
        Usage.track(fn ->
          assert_raise RuntimeError, fn ->
            Usage.track(fn -> raise "boom" end)
          end

          Usage.record(Usage.new("gpt-4o", 1, 1))
        end)

      assert length(usages) == 1
    end
  end

  describe "async/1 and await/2" do
    test "propagate usage recorded in a task to the caller's scope" do
      {result, usages} =
        Usage.track(fn ->
          task =
            Usage.async(fn ->
              Usage.record(Usage.new("gpt-4o", 7, 8))
              :from_task
            end)

          Usage.await(task)
        end)

      assert result == :from_task
      assert [%Usage{input_tokens: 7, output_tokens: 8}] = usages
    end
  end

  describe "seed/1" do
    test "zeroes cost and tokens for a native LLM, as deepeval's prepare_measure" do
      assert Usage.seed(true) == %Usage{
               source: :seed,
               cost: 0.0,
               input_tokens: 0,
               output_tokens: 0
             }
    end

    test "leaves them nil otherwise, which voids the summed cost but adds no tokens" do
      assert Usage.seed(false) == %Usage{source: :seed}

      summary =
        Usage.summarize([
          Usage.seed(false),
          %Usage{model: "fake-jev", source: :system_one, cost: 4.2e-05, input_tokens: 1000}
        ])

      assert %{evaluation_cost: nil, input_tokens: 1000, output_tokens: nil} = summary
    end
  end

  describe "summarize/1" do
    test "is nil when no LLM call was made" do
      assert Usage.summarize([]) == nil
    end

    test "sums tokens and cost and reports the model" do
      summary =
        Usage.summarize([
          %Usage{model: "gpt-4o", input_tokens: 10, output_tokens: 5, cost: 0.25},
          %Usage{model: "gpt-4o", input_tokens: 20, output_tokens: 15, cost: 0.5}
        ])

      assert summary == %{
               evaluation_model: "gpt-4o",
               input_tokens: 30,
               output_tokens: 20,
               evaluation_cost: 0.75
             }
    end

    test "cost is nil when any call's cost is unknown, as in deepeval" do
      summary =
        Usage.summarize([
          %Usage{model: "custom", input_tokens: 10, output_tokens: 5, cost: 0.25},
          %Usage{model: "custom", input_tokens: 1, output_tokens: 1, cost: nil}
        ])

      assert summary.evaluation_cost == nil
      assert summary.input_tokens == 11
    end

    test "takes the evaluation model from LLM usages only" do
      summary =
        Usage.summarize([
          %Usage{source: :seed, cost: 0.0, input_tokens: 0, output_tokens: 0},
          %Usage{model: "fake-jev", source: :system_one, cost: 4.2e-05, input_tokens: 1000},
          %Usage{model: "scripted-judge", cost: 0.0}
        ])

      assert summary == %{
               evaluation_model: "scripted-judge",
               input_tokens: 1000,
               output_tokens: 0,
               evaluation_cost: 4.2e-05
             }
    end

    test "has no evaluation model when no LLM usage was recorded" do
      summary = Usage.summarize([%Usage{model: "fake-jev", source: :system_one, cost: 0.0}])

      assert summary.evaluation_model == nil
      assert summary.evaluation_cost == 0.0
    end

    test "token counts are nil when no call reported them" do
      summary = Usage.summarize([%Usage{model: "custom"}])

      assert summary == %{
               evaluation_model: "custom",
               input_tokens: nil,
               output_tokens: nil,
               evaluation_cost: nil
             }
    end
  end

  describe "Adapter.generate/2 and generate_with_schema/3" do
    defmodule NoUsageAdapter do
      use DeepEvalEx.LLM.Adapter

      @impl true
      def generate(_prompt, _opts), do: {:ok, "text"}
      @impl true
      def generate_with_schema(_prompt, _schema, _opts), do: {:ok, %{}}
      @impl true
      def model_name(opts), do: "custom/" <> Keyword.fetch!(opts, :model)
      @impl true
      def supports_structured_outputs?, do: true
      @impl true
      def supports_log_probs?, do: false
    end

    test "record the adapter's model even when it reports no usage" do
      {_, usages} =
        Usage.track(fn ->
          Adapter.generate("hi", adapter: NoUsageAdapter, model: "m1")
          Adapter.generate_with_schema("hi", %{}, adapter: NoUsageAdapter, model: "m1")
        end)

      assert [%Usage{model: "custom/m1", input_tokens: nil}, %Usage{model: "custom/m1"}] =
               usages
    end

    test "record the usage an adapter reports" do
      {_, usages} =
        Usage.track(fn ->
          Adapter.generate("hi", adapter: :mock, mock_usage: [input_tokens: 4, output_tokens: 2])
        end)

      assert [%Usage{model: "mock-model", input_tokens: 4, output_tokens: 2}] = usages
    end
  end
end
