defmodule DeepEvalEx.Test.TracedFixtures do
  @moduledoc """
  Reads the traced fixtures of `test/fixtures/deepeval/traced/` (see the
  fixtures' README) and normalises the values that differ between two
  identical deepeval runs, so DeepEvalEx's output can be compared with
  deepeval's byte for byte.

  `normalise/1` works on JSON text, so both sides keep their exact encoding:

  - span and trace uuids become `"<uuid-N>"`, numbered by first appearance,
    so `parentUuid` links are still compared
  - span and trace times (`startTime`, `endTime`) must be
    `to_zod_compatible_iso` strings (milliseconds, `Z`) with the start not
    after the end, and become `"<timestamp>"`
  - `tokenIntervals` keys must be the same strings with microseconds, and
    become `"<timestamp-us-N>"`, numbered by appearance, so a document
    keeps distinct keys
  - every `runDuration` becomes `"<normalised>"`: the iterators time each
    test case with `perf_counter`, unlike `evaluate()`'s async executor

  A time that is not in deepeval's format raises instead of being replaced.
  """

  alias Jason.OrderedObject

  @fixtures Path.expand("../fixtures/deepeval/traced", __DIR__)

  @uuid ~r/[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}/
  @millis ~r/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z\z/
  @micros ~r/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{6}Z\z/
  @span_time ~r/("(?:startTime|endTime)": )"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z"/
  @interval_key ~r/"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{6}Z"(?=: )/
  @any_time ~r/\d{4}-\d\d-\d\dT\d\d:\d\d/

  @doc "The traced fixtures' directory."
  @spec dir() :: Path.t()
  def dir, do: @fixtures

  @doc "The traced scenarios, sorted: the directories holding an `input.json`."
  @spec scenarios() :: [String.t()]
  def scenarios do
    @fixtures
    |> File.ls!()
    |> Enum.filter(&File.regular?(Path.join([@fixtures, &1, "input.json"])))
    |> Enum.sort()
  end

  @doc "A scenario's file, read as is."
  @spec read!(String.t(), String.t()) :: String.t()
  def read!(scenario, file), do: [@fixtures, scenario, file] |> Path.join() |> File.read!()

  @doc "A scenario's file, decoded with its objects' key order."
  @spec load!(String.t(), String.t()) :: term()
  def load!(scenario, file), do: scenario |> read!(file) |> decode!()

  @doc "JSON text decoded with its objects' key order."
  @spec decode!(String.t()) :: term()
  def decode!(json), do: Jason.decode!(json, objects: :ordered_objects)

  @doc """
  `json` with its uuids, times and run durations replaced (see the
  moduledoc). Raises `ArgumentError` when a time is not in deepeval's
  format, or a span or trace ends before it starts.
  """
  @spec normalise(String.t()) :: String.t()
  def normalise(json) do
    json |> decode!() |> check_times!("$")

    normalised =
      json
      |> replace_uuids()
      |> String.replace(@span_time, ~s(\\1"<timestamp>"))
      |> replace_interval_keys()
      |> String.replace(~r/("runDuration": )[^,}\n]+/, ~s(\\1"<normalised>"))

    if Regex.match?(@any_time, normalised) do
      raise ArgumentError, "a time outside startTime, endTime and tokenIntervals keys"
    end

    normalised
  end

  defp replace_uuids(json) do
    numbers =
      @uuid
      |> Regex.scan(json)
      |> Enum.map(&hd/1)
      |> Enum.uniq()
      |> Enum.with_index(1)
      |> Map.new()

    Regex.replace(@uuid, json, &"<uuid-#{Map.fetch!(numbers, &1)}>")
  end

  # Regex.split/3 with captures alternates text and keys.
  defp replace_interval_keys(json) do
    {parts, _count} =
      @interval_key
      |> Regex.split(json, include_captures: true)
      |> Enum.with_index()
      |> Enum.map_reduce(1, fn
        {_key, i}, n when rem(i, 2) == 1 -> {~s("<timestamp-us-#{n}>"), n + 1}
        {text, _i}, n -> {text, n}
      end)

    Enum.join(parts)
  end

  defp check_times!(%OrderedObject{values: values} = object, path) do
    if Enum.any?(values, fn {key, _} -> key in ["startTime", "endTime"] end) do
      start_time = check_time!(object["startTime"], @millis, "#{path}.startTime")
      end_time = check_time!(object["endTime"], @millis, "#{path}.endTime")

      if start_time > end_time do
        raise ArgumentError, "#{path}: ends (#{end_time}) before it starts (#{start_time})"
      end
    end

    case object["tokenIntervals"] do
      %OrderedObject{values: intervals} ->
        for {key, _} <- intervals, do: check_time!(key, @micros, "#{path}.tokenIntervals")

      _ ->
        :ok
    end

    for {key, value} <- values, do: check_times!(value, "#{path}.#{key}")
    :ok
  end

  defp check_times!(list, path) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.each(fn {item, i} -> check_times!(item, "#{path}[#{i}]") end)
  end

  defp check_times!(_value, _path), do: :ok

  defp check_time!(time, regex, path) do
    if is_binary(time) and Regex.match?(regex, time) do
      time
    else
      raise ArgumentError, "#{path}: #{inspect(time)} is not a to_zod_compatible_iso time"
    end
  end
end
