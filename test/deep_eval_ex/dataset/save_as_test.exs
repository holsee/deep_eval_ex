defmodule DeepEvalEx.Dataset.SaveAsTest do
  @moduledoc """
  Behaviour of `DeepEvalEx.Dataset.EvaluationDataset.save_as/4` beyond the
  deepeval fixtures (save_as_parity_test.exs): file names, directories,
  which items are written, and the errors raised.
  """

  use ExUnit.Case, async: true

  alias DeepEvalEx.Dataset.{EvaluationDataset, Golden}
  alias DeepEvalEx.TestCase

  @moduletag :tmp_dir
  @moduletag :capture_log

  defp dataset, do: EvaluationDataset.new([Golden.new!(input: "What is 2 + 2?")])

  describe "file name" do
    test "defaults to the local time, as deepeval's %Y%m%d_%H%M%S", %{tmp_dir: dir} do
      before = NaiveDateTime.local_now()
      path = EvaluationDataset.save_as(dataset(), :json, dir)
      after_save = NaiveDateTime.local_now()

      assert Path.dirname(path) == dir
      assert [_, stamp] = Regex.run(~r/^(\d{8}_\d{6})\.json$/, Path.basename(path))
      assert File.exists?(path)

      {:ok, saved_at} = stamp |> String.replace("_", "") |> parse_stamp()
      assert NaiveDateTime.compare(saved_at, NaiveDateTime.truncate(before, :second)) != :lt
      assert NaiveDateTime.compare(saved_at, after_save) != :gt
    end

    test "takes :file_name, without the extension", %{tmp_dir: dir} do
      assert EvaluationDataset.save_as(dataset(), :csv, dir, file_name: "goldens") ==
               Path.join(dir, "goldens.csv")
    end

    test "overwrites an existing file", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "goldens.jsonl"), "old\n")
      path = EvaluationDataset.save_as(dataset(), :jsonl, dir, file_name: "goldens")
      assert File.read!(path) =~ ~s("input": "What is 2 + 2?")
      refute File.read!(path) =~ "old"
    end
  end

  test "creates the directory and its parents", %{tmp_dir: dir} do
    directory = Path.join([dir, "a", "b"])
    path = EvaluationDataset.save_as(dataset(), :json, directory, file_name: "d")
    assert path == Path.join(directory, "d.json")
    assert File.exists?(path)
  end

  test "logs the path, as deepeval prints it", %{tmp_dir: dir} do
    log =
      ExUnit.CaptureLog.capture_log([level: :info], fn ->
        send(self(), {:path, EvaluationDataset.save_as(dataset(), :csv, dir, file_name: "d")})
      end)

    assert_received {:path, path}
    assert log =~ "Evaluation dataset saved at #{path}!"
  end

  test "accepts deepeval's file type strings", %{tmp_dir: dir} do
    for type <- ["csv", "json", "jsonl"] do
      assert EvaluationDataset.save_as(dataset(), type, dir, file_name: "d") ==
               Path.join(dir, "d.#{type}")
    end
  end

  describe "test cases" do
    setup do
      %{
        dataset:
          EvaluationDataset.add_test_case(
            dataset(),
            TestCase.new!(input: "What is 3 + 3?", actual_output: "6")
          )
      }
    end

    test "are left out by default", %{tmp_dir: dir, dataset: dataset} do
      path = EvaluationDataset.save_as(dataset, :jsonl, dir, file_name: "d")
      assert path |> File.read!() |> String.split("\n", trim: true) |> length() == 1
    end

    test "follow the goldens with :include_test_cases", %{tmp_dir: dir, dataset: dataset} do
      path =
        EvaluationDataset.save_as(dataset, :jsonl, dir, file_name: "d", include_test_cases: true)

      assert path
             |> File.read!()
             |> String.split("\n", trim: true)
             |> Enum.map(&Jason.decode!(&1)["input"]) == ["What is 2 + 2?", "What is 3 + 3?"]
    end

    test "alone are enough to save with :include_test_cases", %{tmp_dir: dir} do
      dataset =
        EvaluationDataset.add_test_case(EvaluationDataset.new(), TestCase.new!(input: "x"))

      path =
        EvaluationDataset.save_as(dataset, :csv, dir, file_name: "d", include_test_cases: true)

      assert File.read!(path) =~ "\r\nx,"
    end
  end

  test "a golden's token cost and counts are not written, as deepeval", %{tmp_dir: dir} do
    golden =
      Golden.new!(input: "x", token_cost: 0.5, input_token_count: 1, output_token_count: 2)

    path = EvaluationDataset.save_as(EvaluationDataset.new([golden]), :json, dir, file_name: "d")

    assert [%{"token_cost" => nil, "input_token_count" => nil, "output_token_count" => nil}] =
             Jason.decode!(File.read!(path))
  end

  describe "errors" do
    test "an unknown file type raises deepeval's message", %{tmp_dir: dir} do
      for type <- [:xml, "JSON", nil] do
        assert_raise ArgumentError,
                     "Invalid file type. Available file types to save as: csv, json, jsonl",
                     fn -> EvaluationDataset.save_as(dataset(), type, dir) end
      end

      assert File.ls!(dir) == []
    end

    test "a dataset without goldens raises deepeval's message", %{tmp_dir: dir} do
      dataset =
        EvaluationDataset.add_test_case(EvaluationDataset.new(), TestCase.new!(input: "x"))

      assert_raise ArgumentError,
                   "No goldens found. Please generate goldens before attempting to save data as csv",
                   fn -> EvaluationDataset.save_as(dataset, :csv, dir) end

      assert File.ls!(dir) == []
    end

    test "an unknown option raises", %{tmp_dir: dir} do
      assert_raise NimbleOptions.ValidationError, fn ->
        EvaluationDataset.save_as(dataset(), :csv, dir, filename: "d")
      end
    end

    test "a directory that cannot be created raises File.Error", %{tmp_dir: dir} do
      file = Path.join(dir, "file")
      File.write!(file, "")

      assert_raise File.Error, fn ->
        EvaluationDataset.save_as(dataset(), :csv, Path.join(file, "sub"))
      end
    end
  end

  defp parse_stamp(
         <<y::binary-4, mo::binary-2, d::binary-2, h::binary-2, mi::binary-2, s::binary-2>>
       ) do
    NaiveDateTime.new(
      String.to_integer(y),
      String.to_integer(mo),
      String.to_integer(d),
      String.to_integer(h),
      String.to_integer(mi),
      String.to_integer(s)
    )
  end
end
