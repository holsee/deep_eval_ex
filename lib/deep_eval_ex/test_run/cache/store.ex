# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/test_run/cache.py (TestRunCacheManager)
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.TestRun.Cache.Store do
  @moduledoc """
  The test-run cache files of one run, deepeval 4.3.1's
  `TestRunCacheManager`: a process that reads `.deepeval-cache.json` and
  writes this run's entries (see `DeepEvalEx.TestRun.Cache`).

  `DeepEvalEx.evaluate_run/3` starts one per call, so concurrent runs never
  share state. The files follow deepeval's:

  - `lookup/2` reads the cache file the first time it is asked, and finds
    the entry of a key there. An unreadable or invalid file is an empty
    cache
  - `put/3` files this run's entry for a key, in the cache it reads (so a
    test case repeated later in the run hits) and in this run's own
    entries. Both files are written through (`.deepeval-cache.json` and
    `.temp-deepeval-cache.json`), each replaced atomically
  - `wrap_up/1` ends the run: the cache file then holds only this run's
    entries, in test case order, and the temp file is deleted

  With `write_cache: false` the store reads and writes nothing, and
  `wrap_up/1` deletes both files, as deepeval's `disable_write_cache`. On a
  read-only file system (`DEEPEVAL_FILE_SYSTEM=READ_ONLY`) it does nothing
  at all, as deepeval without its file lock. A file that cannot be written
  logs a warning, as deepeval prints one, and the run goes on.
  """

  use GenServer

  require Logger

  alias DeepEvalEx.Config
  alias DeepEvalEx.TestRun.Cache
  alias DeepEvalEx.TestRun.Cache.{CachedTestCase, CachedTestRun}

  @type t :: GenServer.server()

  @doc """
  Starts a store.

  ## Options

  - `:write_cache` - Read and write the cache (default: `true`); `false`
    makes `wrap_up/1` delete it
  - `:folder` - The cache folder (default: the `:cache_folder` setting,
    see `DeepEvalEx.Config`)
  - `:read_only` - Touch no file (default: `DeepEvalEx.Config.read_only?/0`)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    state = %{
      write_cache: Keyword.get(opts, :write_cache, true),
      folder: Keyword.get_lazy(opts, :folder, fn -> Config.get(:cache_folder) end),
      read_only: Keyword.get_lazy(opts, :read_only, &Config.read_only?/0),
      # The cache file's entries, loaded on first use: {keys in order, map}.
      main: nil,
      # This run's entries: key => {order, entry}.
      fresh: %{}
    }

    GenServer.start_link(__MODULE__, state)
  end

  @doc """
  The entry of `key` in the cache, or `nil`; always `nil` when the store
  does not write (deepeval's `get_cached_test_case`).
  """
  @spec lookup(t(), String.t()) :: CachedTestCase.t() | nil
  def lookup(store, key), do: GenServer.call(store, {:lookup, key}, :infinity)

  @doc """
  Files `entry` under `key` for this run, `order` being its test case's
  place in the run (the cache file's order after `wrap_up/1`); a later
  `put/4` of the same key replaces it (deepeval's `cache_test_case`).
  """
  @spec put(t(), String.t(), non_neg_integer(), CachedTestCase.t()) :: :ok
  def put(store, key, order, %CachedTestCase{} = entry),
    do: GenServer.call(store, {:put, key, order, entry}, :infinity)

  @doc """
  Ends the run (deepeval's `wrap_up_cached_test_run`): the cache file is
  replaced by this run's entries and the temp file deleted, or both are
  deleted when the store does not write.
  """
  @spec wrap_up(t()) :: :ok
  def wrap_up(store), do: GenServer.call(store, :wrap_up, :infinity)

  @doc "Stops the store."
  @spec stop(t()) :: :ok
  def stop(store), do: GenServer.stop(store)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:lookup, _key}, _from, %{read_only: true} = state), do: {:reply, nil, state}
  def handle_call(_request, _from, %{read_only: true} = state), do: {:reply, :ok, state}

  def handle_call({:lookup, _key}, _from, %{write_cache: false} = state),
    do: {:reply, nil, state}

  def handle_call({:lookup, key}, _from, state) do
    state = load(state)
    {_keys, entries} = state.main
    {:reply, Map.get(entries, key), state}
  end

  def handle_call({:put, _key, _order, _entry}, _from, %{write_cache: false} = state),
    do: {:reply, :ok, state}

  def handle_call({:put, key, order, entry}, _from, state) do
    %{main: {keys, entries}} = state = load(state)
    keys = if Map.has_key?(entries, key), do: keys, else: keys ++ [key]
    main = {keys, Map.put(entries, key, entry)}

    fresh =
      Map.update(state.fresh, key, {order, entry}, fn {first, _entry} -> {first, entry} end)

    state = %{state | main: main, fresh: fresh}
    write(state, Cache.cache_file(), main_run(state))
    write(state, Cache.temp_cache_file(), fresh_run(state))
    {:reply, :ok, state}
  end

  def handle_call(:wrap_up, _from, %{write_cache: false} = state) do
    File.rm(path(state, Cache.cache_file()))
    File.rm(path(state, Cache.temp_cache_file()))
    {:reply, :ok, state}
  end

  def handle_call(:wrap_up, _from, state) do
    write(state, Cache.cache_file(), fresh_run(state))
    File.rm(path(state, Cache.temp_cache_file()))
    {:reply, :ok, state}
  end

  defp load(%{main: nil} = state) do
    run =
      case File.read(path(state, Cache.cache_file())) do
        {:ok, contents} -> Cache.decode(contents)
        {:error, _reason} -> %CachedTestRun{}
      end

    pairs = run.test_cases_lookup_map
    %{state | main: {Enum.map(pairs, &elem(&1, 0)), Map.new(pairs)}}
  end

  defp load(state), do: state

  defp main_run(%{main: {keys, entries}}),
    do: %CachedTestRun{test_cases_lookup_map: Enum.map(keys, &{&1, Map.fetch!(entries, &1)})}

  defp fresh_run(%{fresh: fresh}) do
    entries =
      fresh
      |> Enum.sort_by(fn {_key, {order, _entry}} -> order end)
      |> Enum.map(fn {key, {_order, entry}} -> {key, entry} end)

    %CachedTestRun{test_cases_lookup_map: entries}
  end

  defp path(state, file), do: Path.join(state.folder, file)

  # Replaced atomically, so a reader never sees a partial file.
  defp write(state, file, run) do
    path = path(state, file)
    tmp = "#{path}.#{System.unique_integer([:positive])}.tmp"

    with :ok <- File.mkdir_p(state.folder),
         :ok <- File.write(tmp, Cache.encode!(run)),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        File.rm(tmp)

        Logger.warning(
          "DeepEvalEx failed to write the test-run cache #{path}: #{inspect(reason)}"
        )
    end
  end
end
