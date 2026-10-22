defmodule DeepEvalEx.TestRun.LocalStore do
  @moduledoc """
  Writes test runs to disk the way deepeval's local store does.

  Each run is saved as `test_run_<YYYYMMDD_HHMMSS>.json` (local time) in the
  results folder, optionally inside a results subfolder. When a file of that
  name already exists (two runs in the same second) `_2`, `_3`, ... is
  appended. The content is `DeepEvalEx.TestRun.to_map/1` encoded with
  `DeepEvalEx.TestRun.JSON`, byte-compatible with deepeval's own files.

  The results folder is the `:results_folder` option or, when that is not
  set, the `:results_folder` setting: `config :deep_eval_ex, results_folder:`
  or the `DEEPEVAL_RESULTS_FOLDER` environment variable, as in deepeval (see
  `DeepEvalEx.Config`). With none set nothing is written.

      {:ok, path} = DeepEvalEx.TestRun.LocalStore.write(test_run,
        results_folder: "eval_results",
        results_subfolder: "nightly"
      )
  """

  alias DeepEvalEx.{Config, TestRun}
  alias DeepEvalEx.TestRun.JSON

  @doc """
  Writes `test_run` to the configured results folder.

  Creates the folder when needed and never overwrites an existing file, even
  when several runs write at once.

  ## Options

  - `:results_folder` - Folder to write to (default: the `:results_folder`
    setting, see `DeepEvalEx.Config`)
  - `:results_subfolder` - Subfolder of the results folder to write to
  - `:now` - `NaiveDateTime` used for the file name (default: the current
    local time)

  ## Returns

  - `{:ok, path}` - The file written
  - `:skip` - No results folder is configured
  - `{:error, {:not_a_directory, dir}}` - The target folder is a file
  - `{:error, reason}` - The file could not be written
  """
  @spec write(TestRun.t(), keyword()) :: {:ok, Path.t()} | :skip | {:error, term()}
  def write(%TestRun{} = test_run, opts \\ []) do
    case resolve_target_dir(opts[:results_folder], opts[:results_subfolder]) do
      nil -> :skip
      dir -> write_to_dir(dir, test_run, opts)
    end
  end

  @doc """
  Resolves the folder test runs are written to, or `nil` when none is set.

  `results_folder` falls back to `config :deep_eval_ex, results_folder:`,
  then the `DEEPEVAL_RESULTS_FOLDER` environment variable; empty values
  count as unset. A non-empty `results_subfolder` is joined to it.
  """
  @spec resolve_target_dir(Path.t() | nil, Path.t() | nil) :: Path.t() | nil
  def resolve_target_dir(results_folder, results_subfolder \\ nil) do
    case presence(results_folder) || Config.get(:results_folder) do
      nil ->
        nil

      folder ->
        if presence(results_subfolder), do: Path.join(folder, results_subfolder), else: folder
    end
  end

  defp write_to_dir(dir, test_run, opts) do
    content = test_run |> TestRun.to_map() |> JSON.encode!()

    timestamp =
      opts
      |> Keyword.get_lazy(:now, &NaiveDateTime.local_now/0)
      |> Calendar.strftime("%Y%m%d_%H%M%S")

    if File.regular?(dir) do
      {:error, {:not_a_directory, dir}}
    else
      with :ok <- File.mkdir_p(dir) do
        create(dir, timestamp, content, 1)
      end
    end
  end

  # Opening with :exclusive fails when the file exists, so concurrent writers
  # each claim a distinct name instead of overwriting one another.
  defp create(dir, timestamp, content, n) do
    path = Path.join(dir, file_name(timestamp, n))

    case File.open(path, [:write, :exclusive, :binary]) do
      {:ok, file} ->
        result =
          with :ok <- IO.binwrite(file, content),
               :ok <- :file.sync(file),
               do: {:ok, path}

        File.close(file)
        result

      {:error, :eexist} ->
        create(dir, timestamp, content, n + 1)

      {:error, _reason} = error ->
        error
    end
  end

  defp file_name(timestamp, 1), do: "test_run_#{timestamp}.json"
  defp file_name(timestamp, n), do: "test_run_#{timestamp}_#{n}.json"

  defp presence(nil), do: nil
  defp presence(""), do: nil
  defp presence(value), do: value
end
