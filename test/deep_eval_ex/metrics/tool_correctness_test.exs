defmodule DeepEvalEx.Metrics.ToolCorrectnessTest do
  use ExUnit.Case, async: true

  alias DeepEvalEx.LLM.Adapters.Mock
  alias DeepEvalEx.Metrics.ToolCorrectness
  alias DeepEvalEx.Schemas.ToolCall
  alias DeepEvalEx.TestCase

  defp tool(name, params \\ nil, output \\ nil) do
    %ToolCall{name: name, input_parameters: params, output: output}
  end

  defp case_with(called, expected) do
    %TestCase{
      input: "test query",
      actual_output: "",
      tools_called: Enum.map(called, &tool/1),
      expected_tools: Enum.map(expected, &tool/1)
    }
  end

  describe "non-exact match (default mode)" do
    test "returns score 1.0 for perfect match" do
      tc = case_with(["tool_a", "tool_b"], ["tool_a", "tool_b"])

      assert {:ok, result} = ToolCorrectness.measure(tc)
      assert result.score == 1.0
      assert result.success == true
      assert result.metric == "Tool Correctness"
    end

    test "returns score 0.0 for no match" do
      tc = case_with(["tool_c"], ["tool_a", "tool_b"])

      assert {:ok, result} = ToolCorrectness.measure(tc)
      assert result.score == 0.0
      assert result.success == false
    end

    test "returns proportional score for partial match" do
      tc = case_with(["tool_a", "tool_c"], ["tool_a", "tool_b"])

      assert {:ok, result} = ToolCorrectness.measure(tc)
      assert result.score == 0.5
    end

    test "extra tools do not reduce score" do
      tc = case_with(["tool_a", "tool_b", "tool_extra"], ["tool_a", "tool_b"])

      assert {:ok, result} = ToolCorrectness.measure(tc)
      assert result.score == 1.0
    end

    test "order does not matter in default mode" do
      tc = case_with(["tool_b", "tool_a"], ["tool_a", "tool_b"])

      assert {:ok, result} = ToolCorrectness.measure(tc)
      assert result.score == 1.0
    end

    test "greedy matching with duplicates" do
      # Two expected tool_a, only one called → 0.5
      tc = case_with(["tool_a"], ["tool_a", "tool_a"])

      assert {:ok, result} = ToolCorrectness.measure(tc)
      assert result.score == 0.5
    end

    test "both empty lists returns 1.0" do
      tc = %TestCase{
        input: "test",
        actual_output: "",
        tools_called: [],
        expected_tools: []
      }

      assert {:ok, result} = ToolCorrectness.measure(tc)
      assert result.score == 1.0
    end

    test "empty expected with called tools returns 0.0" do
      tc = %TestCase{
        input: "test",
        actual_output: "",
        tools_called: [tool("tool_a")],
        expected_tools: []
      }

      assert {:ok, result} = ToolCorrectness.measure(tc)
      assert result.score == 0.0
    end

    test "empty called with expected tools returns 0.0" do
      tc = %TestCase{
        input: "test",
        actual_output: "",
        tools_called: [],
        expected_tools: [tool("tool_a")]
      }

      assert {:ok, result} = ToolCorrectness.measure(tc)
      assert result.score == 0.0
    end
  end

  describe "exact match mode" do
    test "score 1.0 when lists are identical (positional)" do
      tc = case_with(["tool_a", "tool_b"], ["tool_a", "tool_b"])

      assert {:ok, result} = ToolCorrectness.measure(tc, should_exact_match: true)
      assert result.score == 1.0
    end

    test "score 0.0 when lengths differ (extra tools)" do
      tc = case_with(["tool_a", "tool_b", "tool_c"], ["tool_a", "tool_b"])

      assert {:ok, result} = ToolCorrectness.measure(tc, should_exact_match: true)
      assert result.score == 0.0
    end

    test "score 0.0 when lengths differ (missing tools)" do
      tc = case_with(["tool_a"], ["tool_a", "tool_b"])

      assert {:ok, result} = ToolCorrectness.measure(tc, should_exact_match: true)
      assert result.score == 0.0
    end

    test "score 0.0 when positions mismatch" do
      tc = case_with(["tool_b", "tool_a"], ["tool_a", "tool_b"])

      assert {:ok, result} = ToolCorrectness.measure(tc, should_exact_match: true)
      assert result.score == 0.0
    end

    test "both empty lists returns 1.0" do
      tc = %TestCase{
        input: "test",
        actual_output: "",
        tools_called: [],
        expected_tools: []
      }

      assert {:ok, result} = ToolCorrectness.measure(tc, should_exact_match: true)
      assert result.score == 1.0
    end

    test "exact match with input_parameters" do
      tc = %TestCase{
        input: "test",
        actual_output: "",
        tools_called: [tool("search", %{"q" => "paris"})],
        expected_tools: [tool("search", %{"q" => "paris"})]
      }

      assert {:ok, result} =
               ToolCorrectness.measure(tc,
                 should_exact_match: true,
                 evaluation_params: [:input_parameters]
               )

      assert result.score == 1.0
    end

    test "exact match fails with different input_parameters" do
      tc = %TestCase{
        input: "test",
        actual_output: "",
        tools_called: [tool("search", %{"q" => "london"})],
        expected_tools: [tool("search", %{"q" => "paris"})]
      }

      assert {:ok, result} =
               ToolCorrectness.measure(tc,
                 should_exact_match: true,
                 evaluation_params: [:input_parameters]
               )

      assert result.score == 0.0
    end
  end

  describe "ordering mode (weighted LCS)" do
    test "score 1.0 when order matches" do
      tc = case_with(["tool_a", "tool_b", "tool_c"], ["tool_a", "tool_b", "tool_c"])

      assert {:ok, result} = ToolCorrectness.measure(tc, should_consider_ordering: true)
      assert result.score == 1.0
    end

    test "score 1.0 when expected subsequence is present in order" do
      tc = case_with(["tool_x", "tool_a", "tool_y", "tool_b"], ["tool_a", "tool_b"])

      assert {:ok, result} = ToolCorrectness.measure(tc, should_consider_ordering: true)
      assert result.score == 1.0
    end

    test "partial score when order is disrupted" do
      # Expected: a, b, c. Called: c, a, b.
      # LCS of expected in called: a, b (2 of 3)
      tc = case_with(["tool_c", "tool_a", "tool_b"], ["tool_a", "tool_b", "tool_c"])

      assert {:ok, result} = ToolCorrectness.measure(tc, should_consider_ordering: true)
      assert_in_delta result.score, 2 / 3, 0.001
    end

    test "score 0.0 when no expected tools are present" do
      tc = case_with(["tool_x", "tool_y"], ["tool_a", "tool_b"])

      assert {:ok, result} = ToolCorrectness.measure(tc, should_consider_ordering: true)
      assert result.score == 0.0
    end

    test "both empty lists with ordering returns 1.0" do
      tc = %TestCase{
        input: "test",
        actual_output: "",
        tools_called: [],
        expected_tools: []
      }

      assert {:ok, result} = ToolCorrectness.measure(tc, should_consider_ordering: true)
      assert result.score == 1.0
    end

    test "empty expected with ordering returns 0.0" do
      tc = %TestCase{
        input: "test",
        actual_output: "",
        tools_called: [tool("tool_a")],
        expected_tools: []
      }

      assert {:ok, result} = ToolCorrectness.measure(tc, should_consider_ordering: true)
      assert result.score == 0.0
    end
  end

  describe "exact match + ordering combined" do
    # In Python, should_exact_match takes precedence over should_consider_ordering
    test "fails for different order" do
      tc = case_with(["tool_b", "tool_a"], ["tool_a", "tool_b"])

      assert {:ok, result} =
               ToolCorrectness.measure(tc,
                 should_exact_match: true,
                 should_consider_ordering: true
               )

      assert result.score == 0.0
    end

    test "passes for identical sequence" do
      tc = case_with(["tool_a", "tool_b"], ["tool_a", "tool_b"])

      assert {:ok, result} =
               ToolCorrectness.measure(tc,
                 should_exact_match: true,
                 should_consider_ordering: true
               )

      assert result.score == 1.0
    end

    test "fails when lengths differ" do
      tc = case_with(["tool_a", "tool_b", "tool_c"], ["tool_a", "tool_b"])

      assert {:ok, result} =
               ToolCorrectness.measure(tc,
                 should_exact_match: true,
                 should_consider_ordering: true
               )

      assert result.score == 0.0
    end
  end

  describe "evaluation_params with :input_parameters" do
    test "matches when both name and params match" do
      tc = %TestCase{
        input: "test",
        actual_output: "",
        tools_called: [tool("search", %{"q" => "paris"})],
        expected_tools: [tool("search", %{"q" => "paris"})]
      }

      assert {:ok, result} =
               ToolCorrectness.measure(tc, evaluation_params: [:input_parameters])

      assert result.score == 1.0
    end

    test "fractional score for partial parameter match" do
      tc = %TestCase{
        input: "test",
        actual_output: "",
        tools_called: [tool("search", %{"q" => "paris", "limit" => 10})],
        expected_tools: [tool("search", %{"q" => "paris", "limit" => 5})]
      }

      assert {:ok, result} =
               ToolCorrectness.measure(tc, evaluation_params: [:input_parameters])

      # q matches (0.5), limit differs (0.0) → similarity = 0.5
      assert result.score == 0.5
    end

    test "score 0.0 when all params differ" do
      tc = %TestCase{
        input: "test",
        actual_output: "",
        tools_called: [tool("search", %{"q" => "london"})],
        expected_tools: [tool("search", %{"q" => "paris"})]
      }

      assert {:ok, result} =
               ToolCorrectness.measure(tc, evaluation_params: [:input_parameters])

      assert result.score == 0.0
    end

    test "recursive map comparison" do
      tc = %TestCase{
        input: "test",
        actual_output: "",
        tools_called: [
          tool("search", %{"filters" => %{"country" => "JP", "type" => "school"}})
        ],
        expected_tools: [
          tool("search", %{"filters" => %{"country" => "JP", "type" => "school"}})
        ]
      }

      assert {:ok, result} =
               ToolCorrectness.measure(tc, evaluation_params: [:input_parameters])

      assert result.score == 1.0
    end

    test "missing keys reduce score proportionally" do
      tc = %TestCase{
        input: "test",
        actual_output: "",
        tools_called: [tool("search", %{"q" => "paris", "extra" => "val"})],
        expected_tools: [tool("search", %{"q" => "paris"})]
      }

      assert {:ok, result} =
               ToolCorrectness.measure(tc, evaluation_params: [:input_parameters])

      # Union has 2 keys, intersection has 1 matching key → 1/2 = 0.5
      assert result.score == 0.5
    end
  end

  describe "evaluation_params with :output" do
    test "matches when output is identical" do
      tc = %TestCase{
        input: "test",
        actual_output: "",
        tools_called: [tool("search", nil, "result")],
        expected_tools: [tool("search", nil, "result")]
      }

      assert {:ok, result} =
               ToolCorrectness.measure(tc, evaluation_params: [:output])

      assert result.score == 1.0
    end

    test "score 0.0 when output differs" do
      tc = %TestCase{
        input: "test",
        actual_output: "",
        tools_called: [tool("search", nil, "wrong")],
        expected_tools: [tool("search", nil, "right")]
      }

      assert {:ok, result} =
               ToolCorrectness.measure(tc, evaluation_params: [:output])

      assert result.score == 0.0
    end
  end

  describe "strict_mode" do
    test "zeroes score below threshold" do
      tc = case_with(["tool_a", "tool_c"], ["tool_a", "tool_b"])

      assert {:ok, result} = ToolCorrectness.measure(tc, strict_mode: true)
      # Without strict: score = 0.5, threshold = 0.5 → pass
      # With strict: threshold forced to 1.0, 0.5 < 1.0 → score zeroed
      assert result.score == 0.0
      assert result.threshold == 1.0
      assert result.success == false
    end

    test "passes with perfect score in strict mode" do
      tc = case_with(["tool_a", "tool_b"], ["tool_a", "tool_b"])

      assert {:ok, result} = ToolCorrectness.measure(tc, strict_mode: true)
      assert result.score == 1.0
      assert result.threshold == 1.0
      assert result.success == true
    end

    test "strict mode metadata flag is set" do
      tc = case_with(["tool_a"], ["tool_a"])

      assert {:ok, result} = ToolCorrectness.measure(tc, strict_mode: true)
      assert result.metadata.strict_mode == true
    end
  end

  describe "include_reason" do
    test "includes reason by default" do
      tc = case_with(["tool_a"], ["tool_a"])

      assert {:ok, result} = ToolCorrectness.measure(tc)
      assert is_binary(result.reason)
      assert result.reason =~ "Tool Calling Reason"
      assert result.reason =~ "Tool Selection Reason"
    end

    test "omits reason when include_reason is false" do
      tc = case_with(["tool_a"], ["tool_a"])

      assert {:ok, result} = ToolCorrectness.measure(tc, include_reason: false)
      assert result.reason == nil
    end
  end

  describe "tool selection score (LLM-based)" do
    setup do
      Mock.clear_responses()
      :ok
    end

    test "calls LLM when available_tools provided" do
      Mock.set_schema_response(
        ~r/Tool Selection/,
        %{"score" => 0.75, "reason" => "Good tool selection with minor issues."}
      )

      available = [tool("search"), tool("lookup"), tool("delete")]

      tc = %TestCase{
        input: "Find user info",
        actual_output: "",
        tools_called: [tool("search")],
        expected_tools: [tool("search")]
      }

      assert {:ok, result} =
               ToolCorrectness.measure(tc,
                 available_tools: available,
                 adapter: :mock
               )

      # tool_calling_score = 1.0, tool_selection_score = 0.75
      # final = min(1.0, 0.75) = 0.75
      assert result.score == 0.75
      assert result.metadata.tool_calling_score == 1.0
      assert result.metadata.tool_selection_score == 0.75
    end

    test "defaults to 1.0 when no available_tools" do
      tc = case_with(["tool_a"], ["tool_a"])

      assert {:ok, result} = ToolCorrectness.measure(tc)
      assert result.metadata.tool_selection_score == 1.0
      assert result.metadata.tool_selection_reason =~ "No available tools"
    end

    test "final score is min of calling and selection scores" do
      Mock.set_schema_response(
        ~r/Tool Selection/,
        %{"score" => 0.5, "reason" => "Mixed selection."}
      )

      tc = case_with(["tool_a", "tool_b"], ["tool_a", "tool_b"])

      assert {:ok, result} =
               ToolCorrectness.measure(tc,
                 available_tools: [tool("tool_a"), tool("tool_b"), tool("tool_c")],
                 adapter: :mock
               )

      # tool_calling = 1.0, tool_selection = 0.5
      assert result.score == 0.5
    end
  end

  describe "validation" do
    test "returns error when tools_called is nil" do
      # Force nil by bypassing Ecto defaults
      tc = %{
        %TestCase{input: "test", actual_output: ""}
        | tools_called: nil,
          expected_tools: nil
      }

      assert {:error, {:missing_params, params}} = ToolCorrectness.measure(tc)
      assert :tools_called in params
      assert :expected_tools in params
    end

    test "returns error when expected_tools is nil" do
      tc = %{
        %TestCase{input: "test", actual_output: "", tools_called: [tool("tool_a")]}
        | expected_tools: nil
      }

      assert {:error, {:missing_params, [:expected_tools]}} = ToolCorrectness.measure(tc)
    end

    test "empty lists are valid (not errors)" do
      tc = %TestCase{
        input: "test",
        actual_output: "",
        tools_called: [],
        expected_tools: []
      }

      assert {:ok, result} = ToolCorrectness.measure(tc)
      assert result.score == 1.0
    end
  end

  describe "metadata" do
    test "metric_name/0 returns correct name" do
      assert ToolCorrectness.metric_name() == "Tool Correctness"
    end

    test "required_params/0 returns required parameters" do
      assert ToolCorrectness.required_params() == [:tools_called, :expected_tools]
    end

    test "default_threshold/0 returns 0.5" do
      assert ToolCorrectness.default_threshold() == 0.5
    end
  end

  describe "result" do
    test "includes latency_ms" do
      tc = case_with(["tool_a"], ["tool_a"])

      assert {:ok, result} = ToolCorrectness.measure(tc)
      assert is_integer(result.latency_ms)
      assert result.latency_ms >= 0
    end

    test "includes tool calling and selection metadata" do
      tc = case_with(["tool_a"], ["tool_a"])

      assert {:ok, result} = ToolCorrectness.measure(tc)
      assert is_float(result.metadata.tool_calling_score)
      assert is_float(result.metadata.tool_selection_score)
      assert is_binary(result.metadata.tool_selection_reason)
    end

    test "reason includes both calling and selection reasons" do
      tc = case_with(["tool_a"], ["tool_a"])

      assert {:ok, result} = ToolCorrectness.measure(tc)
      assert result.reason =~ "Tool Calling Reason:"
      assert result.reason =~ "Tool Selection Reason:"
    end
  end
end
