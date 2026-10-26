defmodule DeepEvalEx.Tracing.JSON do
  @moduledoc """
  Span values made safe to export: deepeval 4.3.1's `make_json_serializable`
  (`tracing/utils.py`) and `trace_manager.mask` (`tracing/tracing.py`).

  `make_serializable/1` turns any term into one `Jason` encodes:

  - strings lose embedded NUL characters; numbers, booleans and `nil` are
    kept;
  - other atoms become strings, as an enum becomes its value;
  - lists, tuples and `MapSet`s become lists;
  - map keys become strings as Python's `str()` makes them (`1`, `"1.5"`,
    `"True"`, `"None"`; atoms by name; other terms through `inspect/1`);
  - a `Jason.OrderedObject` keeps its order;
  - a struct implementing `DeepEvalEx.SystemOne.Dumpable` is dumped
    through it, one implementing `String.Chars` (a `Date`) becomes its
    text, as Python's `str()` fallback, and any other struct becomes a map
    of its fields, leaving out those starting with `_`, as `vars()`;
  - pids, references, ports, functions and binaries that are not UTF-8
    become their `inspect/1` text, as does an improper list.

  Python's circular-reference and non-finite float cases cannot occur.

  ## Masking

  `mask/1` applies the configured mask to a span's or trace's default
  input and output, as `trace_manager.configure(mask=...)`:

      config :deep_eval_ex, :tracing, mask: {MyApp.Redact, :redact}

  The mask is a `{module, function}` or a one-arity function; without one
  the data is returned unchanged.

  ## Examples

      iex> DeepEvalEx.Tracing.JSON.make_serializable(%{status: :ok, result: {1, "a\\0b"}})
      %{"result" => [1, "ab"], "status" => "ok"}
  """

  alias DeepEvalEx.Prompts.Python
  alias DeepEvalEx.SystemOne.Dumpable

  @doc """
  Converts a term into one `Jason` can encode, as deepeval's
  `make_json_serializable`; see the moduledoc for the rules.
  """
  @spec make_serializable(term()) :: term()
  def make_serializable(binary) when is_binary(binary) do
    if String.valid?(binary), do: String.replace(binary, <<0>>, ""), else: inspect(binary)
  end

  def make_serializable(value) when is_number(value) or is_boolean(value) or is_nil(value),
    do: value

  def make_serializable(atom) when is_atom(atom), do: Atom.to_string(atom)

  def make_serializable(list) when is_list(list) do
    if proper_list?(list), do: serialize_list(list), else: inspect(list)
  end

  def make_serializable(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> serialize_list()

  def make_serializable(%Jason.OrderedObject{values: values}) do
    Jason.OrderedObject.new(
      for {key, value} <- values, do: {key_str(key), make_serializable(value)}
    )
  end

  def make_serializable(%MapSet{} = set), do: set |> MapSet.to_list() |> serialize_list()

  def make_serializable(struct) when is_struct(struct) do
    cond do
      Dumpable.impl_for(struct) != Dumpable.Any ->
        struct |> Dumpable.dump() |> make_serializable()

      String.Chars.impl_for(struct) ->
        to_string(struct)

      true ->
        struct |> Map.from_struct() |> Map.reject(&private_field?/1) |> make_serializable()
    end
  end

  def make_serializable(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {key_str(key), make_serializable(value)} end)
  end

  def make_serializable(other), do: inspect(other)

  @doc """
  Applies the configured mask (see "Masking" in the moduledoc) to `data`,
  as deepeval's `trace_manager.mask`.
  """
  @spec mask(term()) :: term()
  def mask(data) do
    case Keyword.get(Application.get_env(:deep_eval_ex, :tracing, []), :mask) do
      nil -> data
      {module, function} -> apply(module, function, [data])
      fun when is_function(fun, 1) -> fun.(data)
    end
  end

  defp serialize_list(list), do: Enum.map(list, &make_serializable/1)

  # Python's `str(key)`.
  defp key_str(key) when is_binary(key), do: key
  defp key_str(key) when is_number(key) or is_boolean(key) or is_nil(key), do: Python.repr(key)
  defp key_str(key) when is_atom(key), do: Atom.to_string(key)
  defp key_str(key), do: inspect(key)

  defp proper_list?([]), do: true
  defp proper_list?([_ | tail]), do: proper_list?(tail)
  defp proper_list?(_tail), do: false

  defp private_field?({key, _value}), do: key |> Atom.to_string() |> String.starts_with?("_")
end
