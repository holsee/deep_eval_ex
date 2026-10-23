defmodule DeepEvalEx.TestRun.Cache.StoreTest do
  use ExUnit.Case, async: true

  alias DeepEvalEx.TestRun.Cache
  alias DeepEvalEx.TestRun.Cache.{CachedMetricData, CachedTestCase, CachedTestRun}
  alias DeepEvalEx.TestRun.Cache.{MetricConfiguration, Store}
  alias DeepEvalEx.TestRun.MetricData

  @moduletag :tmp_dir

  defp entry(name) do
    %CachedTestCase{
      cached_metrics_data: [
        %CachedMetricData{
          metric_data: %MetricData{name: name, score: 1.0, evaluation_cost: 0},
          metric_configuration: %MetricConfiguration{threshold: 0.5}
        }
      ]
    }
  end

  defp start(dir, opts \\ []) do
    {:ok, store} = Store.start_link(Keyword.merge([folder: dir, read_only: false], opts))
    store
  end

  defp write_cache(dir, entries) do
    File.write!(
      Path.join(dir, Cache.cache_file()),
      Cache.encode!(%CachedTestRun{test_cases_lookup_map: entries})
    )
  end

  defp read(dir, file), do: dir |> Path.join(file) |> File.read!() |> Cache.decode()

  defp keys(%CachedTestRun{test_cases_lookup_map: entries}), do: Enum.map(entries, &elem(&1, 0))

  test "looks keys up in the cache file, read on first use", %{tmp_dir: dir} do
    store = start(dir)
    write_cache(dir, [{"a", entry("A")}])

    assert %CachedTestCase{cached_metrics_data: [%{metric_data: %{name: "A"}}]} =
             Store.lookup(store, "a")

    assert Store.lookup(store, "b") == nil
    # Read once: a later change to the file is not seen.
    write_cache(dir, [{"b", entry("B")}])
    assert Store.lookup(store, "b") == nil
  end

  test "reads a missing or invalid cache file as an empty cache", %{tmp_dir: dir} do
    assert Store.lookup(start(dir), "a") == nil
    File.write!(Path.join(dir, Cache.cache_file()), "{not json")
    assert Store.lookup(start(dir), "a") == nil
  end

  test "put/4 files the entry in the cache it reads and writes both files through",
       %{tmp_dir: dir} do
    write_cache(dir, [{"old", entry("Old")}])
    store = start(dir)

    :ok = Store.put(store, "new", 0, entry("New"))

    assert %CachedTestCase{} = Store.lookup(store, "new")
    assert dir |> read(Cache.cache_file()) |> keys() == ["old", "new"]
    assert dir |> read(Cache.temp_cache_file()) |> keys() == ["new"]
  end

  test "wrap_up/1 leaves only this run's entries, in test case order, and deletes the temp file",
       %{tmp_dir: dir} do
    write_cache(dir, [{"old", entry("Old")}])
    store = start(dir)

    :ok = Store.put(store, "second", 1, entry("Second"))
    :ok = Store.put(store, "first", 0, entry("First"))
    # A repeated test case keeps its first place and its latest entry.
    :ok = Store.put(store, "first", 2, entry("Again"))
    :ok = Store.wrap_up(store)

    run = read(dir, Cache.cache_file())
    assert keys(run) == ["first", "second"]
    assert %{cached_metrics_data: [%{metric_data: %{name: "Again"}}]} = Cache.get(run, "first")
    refute File.exists?(Path.join(dir, Cache.temp_cache_file()))
  end

  test "wrap_up/1 writes an empty cache for a run that cached nothing", %{tmp_dir: dir} do
    write_cache(dir, [{"old", entry("Old")}])
    :ok = dir |> start() |> Store.wrap_up()

    assert File.read!(Path.join(dir, Cache.cache_file())) == ~s({"test_cases_lookup_map": {}})
  end

  test "with write_cache: false reads nothing, writes nothing and wrap_up/1 deletes both files",
       %{tmp_dir: dir} do
    write_cache(dir, [{"a", entry("A")}])
    File.write!(Path.join(dir, Cache.temp_cache_file()), "{}")
    store = start(dir, write_cache: false)

    assert Store.lookup(store, "a") == nil
    :ok = Store.put(store, "b", 0, entry("B"))
    assert dir |> read(Cache.cache_file()) |> keys() == ["a"]

    :ok = Store.wrap_up(store)
    assert File.ls!(dir) == []
  end

  test "on a read-only file system touches no file", %{tmp_dir: dir} do
    write_cache(dir, [{"a", entry("A")}])
    store = start(dir, read_only: true)

    assert Store.lookup(store, "a") == nil
    :ok = Store.put(store, "b", 0, entry("B"))
    :ok = Store.wrap_up(store)

    assert File.ls!(dir) == [Cache.cache_file()]
    assert dir |> read(Cache.cache_file()) |> keys() == ["a"]
  end

  test "leaves no partial file behind its atomic writes", %{tmp_dir: dir} do
    store = start(dir)
    for i <- 1..20, do: :ok = Store.put(store, "k#{i}", i, entry("M#{i}"))

    assert dir |> File.ls!() |> Enum.sort() == [Cache.cache_file(), Cache.temp_cache_file()]
  end
end
