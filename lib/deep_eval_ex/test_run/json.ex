defmodule DeepEvalEx.TestRun.JSON do
  @moduledoc """
  JSON encoder producing the same bytes as Python's `json.dumps` defaults.

  deepeval writes test runs with `json.dump(body, f, cls=TestRunEncoder)`,
  so a byte-compatible export needs Python's formatting rather than
  `Jason`'s:

  - `", "` between items and `": "` between keys and values
  - `ensure_ascii=True`: every character outside printable ASCII
    (`0x20..0x7E`) is escaped as `\\uXXXX` (lowercase hex, surrogate pairs
    above the BMP), except `\\b`, `\\f`, `\\n`, `\\r` and `\\t`
  - floats formatted like Python's `repr/1` (see `float_repr/1`): `1.0`,
    `0.25`, `1e-05`, `1e+16`

  ## Supported terms

  - `nil`, `true`, `false`, numbers and UTF-8 binaries
  - other atoms, encoded as strings
  - lists and tuples, encoded as arrays
  - maps, encoded as objects in map iteration order; keys may be strings,
    atoms or numbers. Use `Jason.OrderedObject` for a fixed key order
  - other structs, encoded as the object of their fields

  Anything else (pids, functions, invalid UTF-8, ...) raises `ArgumentError`.
  """

  @doc """
  Encodes `term` as JSON text formatted like Python's `json.dumps(term)`.

  ## Examples

      iex> DeepEvalEx.TestRun.JSON.encode!(%{"score" => 1.0, "name" => "café"})
      ~S({"name": "caf\\u00e9", "score": 1.0})
  """
  @spec encode!(term()) :: String.t()
  def encode!(term), do: term |> value() |> IO.iodata_to_binary()

  @doc """
  Formats a float exactly like Python's `repr(float)`.

  Uses the shortest digits that round-trip, written in positional notation
  with at least one decimal (`100.0`) unless the decimal exponent is below
  -4 or above 15, where Python switches to exponent notation with a signed,
  two-digit minimum exponent (`1e-05`, `1.5e+16`).

  ## Examples

      iex> DeepEvalEx.TestRun.JSON.float_repr(0.1 + 0.2)
      "0.30000000000000004"

      iex> DeepEvalEx.TestRun.JSON.float_repr(1.0e16)
      "1e+16"
  """
  @spec float_repr(float()) :: String.t()
  def float_repr(float) when is_float(float) do
    {sign, short} =
      case :erlang.float_to_binary(float, [:short]) do
        "-" <> rest -> {"-", rest}
        short -> {"", short}
      end

    {digits, decpt} = digits_and_point(short)
    sign <> format_float(digits, decpt)
  end

  # Splits Erlang's shortest representation (e.g. "1.5e-5", "123.25") into
  # its significant digits and the decimal point position, such that the
  # value is 0.<digits> * 10^decpt.
  defp digits_and_point(short) do
    {mantissa, exponent} =
      case String.split(short, "e") do
        [mantissa, exponent] -> {mantissa, String.to_integer(exponent)}
        [mantissa] -> {mantissa, 0}
      end

    {int, frac} =
      case String.split(mantissa, ".") do
        [int, frac] -> {int, frac}
        [int] -> {int, ""}
      end

    all = int <> frac
    trimmed = String.trim_leading(all, "0")
    decpt = byte_size(int) + exponent - (byte_size(all) - byte_size(trimmed))
    {String.trim_trailing(trimmed, "0"), decpt}
  end

  defp format_float("", _decpt), do: "0.0"

  defp format_float(digits, decpt) when decpt <= -4 or decpt > 16 do
    <<first::binary-size(1), rest::binary>> = digits
    mantissa = if rest == "", do: first, else: first <> "." <> rest
    exponent = decpt - 1
    exp_sign = if exponent < 0, do: "-", else: "+"

    mantissa <>
      "e" <> exp_sign <> String.pad_leading(Integer.to_string(abs(exponent)), 2, "0")
  end

  defp format_float(digits, decpt) when decpt <= 0 do
    "0." <> String.duplicate("0", -decpt) <> digits
  end

  defp format_float(digits, decpt) when decpt >= byte_size(digits) do
    digits <> String.duplicate("0", decpt - byte_size(digits)) <> ".0"
  end

  defp format_float(digits, decpt) do
    <<int::binary-size(decpt), frac::binary>> = digits
    int <> "." <> frac
  end

  defp value(nil), do: "null"
  defp value(true), do: "true"
  defp value(false), do: "false"
  defp value(atom) when is_atom(atom), do: string(Atom.to_string(atom))
  defp value(binary) when is_binary(binary), do: string(binary)
  defp value(integer) when is_integer(integer), do: Integer.to_string(integer)
  defp value(float) when is_float(float), do: float_repr(float)
  defp value(list) when is_list(list), do: array(list)
  defp value(tuple) when is_tuple(tuple), do: array(Tuple.to_list(tuple))
  defp value(%Jason.OrderedObject{values: pairs}), do: object(pairs)
  defp value(%_{} = struct), do: struct |> Map.from_struct() |> object()
  defp value(map) when is_map(map), do: object(map)

  defp value(other) do
    raise ArgumentError, "cannot encode #{inspect(other)} as JSON"
  end

  defp array([]), do: "[]"
  defp array(items), do: [?[, items |> Enum.map(&value/1) |> Enum.intersperse(", "), ?]]

  defp object(pairs) when pairs == %{} or pairs == [], do: "{}"

  defp object(pairs) do
    members =
      pairs
      |> Enum.map(fn {key, val} -> [key(key), ": ", value(val)] end)
      |> Enum.intersperse(", ")

    [?{, members, ?}]
  end

  # Python's json converts these key types to strings; others are errors.
  defp key(key) when is_binary(key), do: string(key)
  defp key(key) when key in [nil, true, false], do: value(key)
  defp key(key) when is_atom(key), do: string(Atom.to_string(key))
  defp key(key) when is_integer(key), do: [?", Integer.to_string(key), ?"]
  defp key(key) when is_float(key), do: [?", float_repr(key), ?"]

  defp key(key) do
    raise ArgumentError, "cannot encode #{inspect(key)} as a JSON object key"
  end

  defp string(binary) do
    unless String.valid?(binary) do
      raise ArgumentError, "cannot encode invalid UTF-8 #{inspect(binary)} as JSON"
    end

    [?", escape(binary, []), ?"]
  end

  defp escape(<<>>, acc), do: acc
  defp escape(<<char::utf8, rest::binary>>, acc), do: escape(rest, [acc | escape_char(char)])

  defp escape_char(?"), do: "\\\""
  defp escape_char(?\\), do: "\\\\"
  defp escape_char(?\n), do: "\\n"
  defp escape_char(?\r), do: "\\r"
  defp escape_char(?\t), do: "\\t"
  defp escape_char(?\b), do: "\\b"
  defp escape_char(?\f), do: "\\f"
  defp escape_char(char) when char in 0x20..0x7E, do: <<char>>
  defp escape_char(char) when char < 0x10000, do: unicode_escape(char)

  defp escape_char(char) do
    code = char - 0x10000

    [
      unicode_escape(0xD800 + Bitwise.bsr(code, 10)),
      unicode_escape(0xDC00 + Bitwise.band(code, 0x3FF))
    ]
  end

  defp unicode_escape(code) do
    hex = code |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(4, "0")
    "\\u" <> hex
  end
end
