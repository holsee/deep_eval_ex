defmodule DeepEvalEx.Test.JSONDiff do
  @moduledoc """
  Lists the differences between two decoded JSON documents, for parity
  assertions that should say what differs before comparing raw bytes.

  Objects decoded with `objects: :ordered_objects` are compared key order
  included; plain maps by their keys. Numbers must match in type as well as
  value: deepeval writes the integer `1` and the float `1.0` differently.
  """

  alias Jason.OrderedObject

  @doc """
  Returns every difference between `ours` and `theirs` (deepeval's), as
  `"<path>: <what>"` strings rooted at `path`. Empty when they are equal.
  """
  @spec diff(term(), term(), String.t()) :: [String.t()]
  def diff(ours, theirs, path \\ "$")

  def diff(%OrderedObject{values: ours}, %OrderedObject{values: theirs}, path) do
    our_keys = Enum.map(ours, &elem(&1, 0))
    their_keys = Enum.map(theirs, &elem(&1, 0))

    if our_keys == their_keys do
      [ours, theirs]
      |> Enum.zip()
      |> Enum.flat_map(fn {{key, our_value}, {key, their_value}} ->
        diff(our_value, their_value, "#{path}.#{key}")
      end)
    else
      ["#{path}: keys #{inspect(our_keys)}, deepeval has #{inspect(their_keys)}"]
    end
  end

  def diff(ours, theirs, path) when is_map(ours) and is_map(theirs) do
    our_keys = ours |> Map.keys() |> Enum.sort()
    their_keys = theirs |> Map.keys() |> Enum.sort()

    if our_keys == their_keys do
      Enum.flat_map(our_keys, &diff(ours[&1], theirs[&1], "#{path}.#{&1}"))
    else
      ["#{path}: keys #{inspect(our_keys)}, deepeval has #{inspect(their_keys)}"]
    end
  end

  def diff(ours, theirs, path) when is_list(ours) and is_list(theirs) do
    if length(ours) == length(theirs) do
      [ours, theirs]
      |> Enum.zip()
      |> Enum.with_index()
      |> Enum.flat_map(fn {{our_item, their_item}, index} ->
        diff(our_item, their_item, "#{path}[#{index}]")
      end)
    else
      ["#{path}: #{length(ours)} items, deepeval has #{length(theirs)}"]
    end
  end

  def diff(ours, theirs, path) do
    cond do
      type(ours) != type(theirs) ->
        ["#{path}: #{describe(ours)}, deepeval has #{describe(theirs)}"]

      ours !== theirs ->
        ["#{path}: #{inspect(ours)}, deepeval has #{inspect(theirs)}"]

      true ->
        []
    end
  end

  defp describe(value), do: "#{type(value)} #{inspect(value)}"

  defp type(value) when is_integer(value), do: :integer
  defp type(value) when is_float(value), do: :float
  defp type(value) when is_binary(value), do: :string
  defp type(value) when is_boolean(value), do: :boolean
  defp type(nil), do: :null
  defp type(value) when is_list(value), do: :array
  defp type(%OrderedObject{}), do: :object
  defp type(value) when is_map(value), do: :object
  defp type(value), do: {:term, value}
end
