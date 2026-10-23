defmodule DeepEvalEx.Dataset.LoaderParityTest do
  @moduledoc """
  Loads the files under test/fixtures/deepeval/datasets with
  `DeepEvalEx.Dataset.EvaluationDataset`'s loaders and compares what they
  load with what deepeval 4.3.1's loaders loaded from the same files
  (`loads.json`, written by scripts/parity/generate_dataset_fixtures.py).
  The `saved` case's files were written by deepeval's own `save_as`.
  """

  use ExUnit.Case, async: true

  alias DeepEvalEx.Dataset.{EvaluationDataset, Golden}
  alias DeepEvalEx.Schemas.{RetrievedContextData, ToolCall}
  alias DeepEvalEx.TestCase

  @fixtures Path.expand("../../fixtures/deepeval/datasets", __DIR__)

  # deepeval's keyword argument spelled otherwise here
  @renamed_kwargs %{"addtional_metadata_key_name" => :additional_metadata_key_name}

  for case_dir <- @fixtures |> File.ls!() |> Enum.sort(),
      {load, index} <-
        Path.join([@fixtures, case_dir, "loads.json"])
        |> File.read!()
        |> Jason.decode!()
        |> Enum.with_index() do
    @load load
    @case_dir case_dir

    test "#{case_dir} ##{index}: #{load["loader"]}(#{load["file"]}) as deepeval" do
      path = Path.join([@fixtures, @case_dir, @load["file"]])

      case @load do
        %{"raised" => %{"type" => type, "message" => message}} ->
          error = assert_raise ArgumentError, fn -> run(@load, path) end
          # deepeval's own ValueErrors are matched by message; pydantic's
          # ValidationErrors and Python's TypeErrors only by kind.
          if type == "ValueError" do
            assert String.replace(error.message, Path.dirname(path) <> "/", "") == message
          end

        %{"goldens" => goldens} ->
          assert Enum.map(run(@load, path).goldens, &dump_golden/1) === goldens

        %{"test_cases" => test_cases} ->
          assert Enum.map(run(@load, path).test_cases, &dump_test_case/1) === test_cases
      end
    end
  end

  defp run(%{"loader" => loader, "args" => args, "kwargs" => kwargs}, path) do
    # The loader and option names are atoms only once EvaluationDataset is
    # loaded, which no other test may have done yet when this one runs first.
    Code.ensure_loaded!(EvaluationDataset)

    opts =
      Enum.map(kwargs, fn {key, value} ->
        {Map.get_lazy(@renamed_kwargs, key, fn -> String.to_existing_atom(key) end), value}
      end)

    apply(
      EvaluationDataset,
      String.to_existing_atom(loader),
      [EvaluationDataset.new(), path] ++ args ++ [opts]
    )
  end

  defp dump_golden(%Golden{} = golden) do
    %{
      "input" => golden.input,
      "actual_output" => golden.actual_output,
      "expected_output" => golden.expected_output,
      "context" => golden.context,
      "retrieval_context" => dump_retrieval_context(golden.retrieval_context),
      "additional_metadata" => golden.additional_metadata,
      "comments" => golden.comments,
      "tools_called" => dump_tools(golden.tools_called),
      "expected_tools" => dump_tools(golden.expected_tools),
      "token_cost" => golden.token_cost,
      "input_token_count" => golden.input_token_count,
      "output_token_count" => golden.output_token_count,
      "source_file" => golden.source_file,
      "name" => golden.name,
      "custom_column_key_values" => golden.custom_column_key_values,
      "expectations" => dump_expectations(golden.expectations),
      "expected_labels" => golden.expected_labels
    }
  end

  defp dump_test_case(%TestCase{} = test_case) do
    %{
      "input" => test_case.input,
      "actual_output" => test_case.actual_output,
      "expected_output" => test_case.expected_output,
      "context" => test_case.context,
      "retrieval_context" => dump_retrieval_context(test_case.retrieval_context),
      "tools_called" => dump_tools(test_case.tools_called),
      "expected_tools" => dump_tools(test_case.expected_tools),
      "metadata" => test_case.metadata,
      "expectations" => dump_expectations(test_case.expectations),
      "dataset_rank" => test_case.dataset_rank
    }
  end

  defp dump_retrieval_context(nil), do: nil

  defp dump_retrieval_context(items) do
    Enum.map(items, fn
      %RetrievedContextData{source: source, context: context} ->
        %{"source" => source, "context" => context}

      text ->
        text
    end)
  end

  defp dump_tools(nil), do: nil

  defp dump_tools(tools) do
    Enum.map(tools, fn %ToolCall{} = tool ->
      %{
        "name" => tool.name,
        "type" => tool.type |> Atom.to_string() |> String.upcase(),
        "description" => tool.description,
        "reasoning" => tool.reasoning,
        "input_parameters" => tool.input_parameters,
        "output" => tool.output
      }
    end)
  end

  defp dump_expectations(nil), do: nil

  defp dump_expectations(expectations) do
    %{
      "model" => expectations.model,
      "eval_mode" => expectations.eval_mode && Atom.to_string(expectations.eval_mode),
      "must" => expectations.must,
      "must_not" => expectations.must_not
    }
  end
end
