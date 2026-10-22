defmodule DeepEvalEx.Metrics.Utils.TurnWindowsTest do
  use ExUnit.Case, async: true

  alias DeepEvalEx.ConversationalTestCase
  alias DeepEvalEx.LLM.Adapters.Mock
  alias DeepEvalEx.Metrics.Utils.TurnWindows
  alias DeepEvalEx.Prompts.TurnFaithfulness
  alias DeepEvalEx.Schemas.MetricOutputs.Faithfulness

  doctest TurnWindows

  @turns [
    %{role: :user, content: "Hi"},
    %{role: :user, content: "Order 42?"},
    %{role: :assistant, content: "It shipped.", retrieval_context: ["Order 42 shipped."]},
    %{role: :user, content: "Refund?"},
    %{role: :assistant, content: "5 days.", retrieval_context: ["Refunds take 5 days."]}
  ]

  defp test_case(turns \\ @turns), do: ConversationalTestCase.new!(turns: turns)

  defp spec(score_window) do
    [
      metric_name: "Turn Test",
      threshold: 0.5,
      template: TurnFaithfulness,
      schema: Faithfulness,
      score_window: score_window
    ]
  end

  describe "windows/2" do
    test "is one window per unit interaction, of at most :window_size unit interactions" do
      assert [first, second] = TurnWindows.windows(test_case(), [])
      assert length(first) == 3
      assert length(second) == 5

      assert [_first, [%{content: "Refund?"}, %{content: "5 days."}]] =
               TurnWindows.windows(test_case(), window_size: 1)
    end
  end

  describe "contents/1" do
    test "joins the user turns and the assistant turns and gathers the retrieval context" do
      [_first, second] = TurnWindows.windows(test_case(), [])

      assert TurnWindows.contents(second) == %{
               input: "\nHi \nOrder 42? \nRefund? ",
               assistant_output: "\nIt shipped.\n5 days.",
               retrieval_context: ["Order 42 shipped.", "Refunds take 5 days."]
             }
    end
  end

  describe "measure/3" do
    test "averages the windows' scores as floats and explains them with the final reason" do
      Mock.script(%{"reason" => [%{"reason" => "Mostly fine."}]}, model: "scripted-judge")
      scores = [1, 0]

      score_window = fn %{input: input} ->
        score = if input =~ "Refund", do: Enum.at(scores, 1), else: Enum.at(scores, 0)
        {:ok, %{score: score, reason: "Window #{score}.", steps: ["Score: #{score} \n"]}}
      end

      assert {:ok, result} = TurnWindows.measure(spec(score_window), test_case(), adapter: :mock)

      assert result.score === 0.5
      assert result.reason == "Mostly fine."
      assert result.strict_applied
      assert [%{score: 1.0, reason: "Window 1."}, %{score: +0.0}] = result.metadata.windows

      assert result.verbose_logs ==
               "Window 1 \n \n \nScore: 1 \n \n \nWindow 2 \n \n \nScore: 0 \n \n \nFinal Score: 0.5\n"

      [%{prompt: prompt}] = Mock.scripted_prompts()

      assert prompt =~
               "Final Score: 0.5\n\nReasons: \n['Window 1.', 'Window 0.']\n\nSuccess: True\n"
    end

    test "scores the integer 1 without a window, with deepeval's reason and no judge call" do
      Mock.script(%{}, model: "scripted-judge")

      assert {:ok, result} =
               TurnWindows.measure(
                 spec(fn _ -> flunk("no window to score") end),
                 test_case([%{role: :user, content: "Hello?"}]),
                 adapter: :mock
               )

      assert result.score === 1

      assert result.reason ==
               "There were no retrieval contexts in your turns to evaluate, hence the score is 1"

      assert Mock.scripted_prompts() == []
    end

    test "stops at the first window that errors" do
      assert {:error, :boom} =
               TurnWindows.measure(spec(fn _ -> {:error, :boom} end), test_case(), [])
    end
  end
end
