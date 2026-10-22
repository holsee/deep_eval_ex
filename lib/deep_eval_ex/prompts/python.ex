# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0

defmodule DeepEvalEx.Prompts.Python do
  @moduledoc """
  Python formatting that deepeval's prompts and reasons depend on.

  deepeval renders its prompt templates with Jinja, which prints a list as
  Python's `str(list)` (`['a', "it's"]`), and builds reasons with
  f-strings, which do the same. Scores are passed to templates already
  formatted as `format(score, ".2f")`. To send the same bytes, DeepEvalEx
  formats these values the way Python does:

  - `repr/1` - Python's `repr()` of strings, lists, dicts, numbers, `None`,
    booleans and deepeval `ToolCall`s
  - `format_fixed/2` - Python's `format(number, ".<n>f")`
  """

  alias DeepEvalEx.Schemas.ToolCall
  alias DeepEvalEx.TestRun.JSON

  defmodule EnumMember do
    @moduledoc """
    A member of a Python `Enum`, which `DeepEvalEx.Prompts.Python.repr/1`
    prints as Python does: `<Verdict.YES: 'yes'>`.
    """

    @enforce_keys [:class, :name, :value]
    defstruct [:class, :name, :value]

    @type t :: %__MODULE__{class: String.t(), name: String.t(), value: term()}
  end

  # Assigned code points Python 3.11 (Unicode 14.0) does not consider
  # printable, so `repr/1` escapes them: categories Cc, Cf, Co, Cs, Zl, Zp
  # and Zs other than the space. Generated with `str.isprintable()` and
  # `unicodedata.category()`.
  @non_printable [
    0x0..0x1F,
    0x7F..0xA0,
    0xAD..0xAD,
    0x600..0x605,
    0x61C..0x61C,
    0x6DD..0x6DD,
    0x70F..0x70F,
    0x890..0x891,
    0x8E2..0x8E2,
    0x1680..0x1680,
    0x180E..0x180E,
    0x2000..0x200F,
    0x2028..0x202F,
    0x205F..0x2064,
    0x2066..0x206F,
    0x3000..0x3000,
    0xD800..0xF8FF,
    0xFEFF..0xFEFF,
    0xFFF9..0xFFFB,
    0x110BD..0x110BD,
    0x110CD..0x110CD,
    0x13430..0x13438,
    0x1BCA0..0x1BCA3,
    0x1D173..0x1D17A,
    0xE0001..0xE0001,
    0xE0020..0xE007F,
    0xF0000..0xFFFFD,
    0x100000..0x10FFFD
  ]

  @doc """
  Formats `term` like Python's `repr(term)`.

  - strings in single quotes, or double quotes when they contain a single
    quote and no double quote; backslashes, the quote, `\\t`, `\\n`, `\\r`
    and non-printable characters escaped as Python escapes them
  - atoms as strings (`:yes` as `'yes'`), `nil` as `None`, booleans as
    `True` / `False`
  - integers, and floats as `DeepEvalEx.TestRun.JSON.float_repr/1`
  - lists as `[a, b]`; maps and `Jason.OrderedObject`s as `{k: v}`, in
    iteration order
  - `DeepEvalEx.Schemas.ToolCall`s as deepeval's `ToolCall.__repr__`
  - `DeepEvalEx.Prompts.Python.EnumMember`s as `<Class.NAME: value>`

  ## Examples

      iex> DeepEvalEx.Prompts.Python.repr(["Paris", "It's known for café culture."])
      ~S(['Paris', "It's known for café culture."])

      iex> DeepEvalEx.Prompts.Python.repr([1, 0.5, nil, true])
      "[1, 0.5, None, True]"
  """
  @spec repr(term()) :: String.t()
  def repr(term), do: term |> do_repr() |> IO.iodata_to_binary()

  @doc """
  Formats `number` like Python's `format(number, ".<decimals>f")`.

  The number is rounded from its exact binary value, ties to even, as
  Python does: `0.125` is `"0.12"`, `0.375` is `"0.38"`.

  ## Examples

      iex> DeepEvalEx.Prompts.Python.format_fixed(0.5, 2)
      "0.50"

      iex> DeepEvalEx.Prompts.Python.format_fixed(2 / 3, 2)
      "0.67"
  """
  @spec format_fixed(number(), non_neg_integer()) :: String.t()
  def format_fixed(number, decimals) when is_integer(number),
    do: format_fixed(number * 1.0, decimals)

  def format_fixed(float, decimals) when is_float(float) and decimals >= 0 do
    {sign, mantissa, exponent} = decompose(float)
    scale = Integer.pow(10, decimals)
    digits = round_scaled(mantissa * scale, exponent)

    int = digits |> div(scale) |> Integer.to_string()

    frac =
      if decimals == 0,
        do: "",
        else:
          "." <>
            (digits |> rem(scale) |> Integer.to_string() |> String.pad_leading(decimals, "0"))

    sign <> int <> frac
  end

  # A float as sign, integer mantissa and binary exponent:
  # |float| == mantissa * 2^exponent, exactly.
  defp decompose(float) do
    <<sign::1, biased::11, fraction::52>> = <<float::float>>
    sign = if sign == 1 and float != 0.0, do: "-", else: ""

    case biased do
      0 -> {sign, fraction, -1074}
      _ -> {sign, fraction + Bitwise.bsl(1, 52), biased - 1075}
    end
  end

  # round(numerator * 2^exponent), ties to even.
  defp round_scaled(numerator, exponent) when exponent >= 0,
    do: Bitwise.bsl(numerator, exponent)

  defp round_scaled(numerator, exponent) do
    denominator = Bitwise.bsl(1, -exponent)
    quotient = div(numerator, denominator)
    remainder = rem(numerator, denominator) * 2

    cond do
      remainder > denominator -> quotient + 1
      remainder == denominator and rem(quotient, 2) == 1 -> quotient + 1
      true -> quotient
    end
  end

  defp do_repr(nil), do: "None"
  defp do_repr(true), do: "True"
  defp do_repr(false), do: "False"
  defp do_repr(atom) when is_atom(atom), do: string(Atom.to_string(atom))
  defp do_repr(binary) when is_binary(binary), do: string(binary)
  defp do_repr(integer) when is_integer(integer), do: Integer.to_string(integer)
  defp do_repr(float) when is_float(float), do: JSON.float_repr(float)
  defp do_repr(list) when is_list(list), do: [?[, list |> Enum.map(&do_repr/1) |> join(), ?]]
  defp do_repr(%ToolCall{} = tool_call), do: tool_call(tool_call)

  defp do_repr(%EnumMember{class: class, name: name, value: value}),
    do: [?<, class, ?., name, ": ", do_repr(value), ?>]

  defp do_repr(%Jason.OrderedObject{values: pairs}), do: dict(pairs)
  defp do_repr(map) when is_map(map) and not is_struct(map), do: dict(map)

  defp dict(pairs) do
    [
      ?{,
      pairs |> Enum.map(fn {key, value} -> [do_repr(key), ": ", do_repr(value)] end) |> join(),
      ?}
    ]
  end

  defp join(items), do: Enum.intersperse(items, ", ")

  defp string(binary) do
    quote_char =
      if String.contains?(binary, "'") and not String.contains?(binary, "\""), do: ?", else: ?'

    [quote_char, for(<<char::utf8 <- binary>>, do: escape(char, quote_char)), quote_char]
  end

  defp escape(quote_char, quote_char), do: [?\\, quote_char]
  defp escape(?\\, _quote_char), do: "\\\\"
  defp escape(?\t, _quote_char), do: "\\t"
  defp escape(?\n, _quote_char), do: "\\n"
  defp escape(?\r, _quote_char), do: "\\r"

  defp escape(char, _quote_char) when char in 0x20..0x7E, do: <<char>>

  defp escape(char, _quote_char) do
    if Enum.any?(@non_printable, &(char in &1)), do: hex_escape(char), else: <<char::utf8>>
  end

  defp hex_escape(char) when char < 0x100, do: "\\x" <> hex(char, 2)
  defp hex_escape(char) when char < 0x10000, do: "\\u" <> hex(char, 4)
  defp hex_escape(char), do: "\\U" <> hex(char, 8)

  defp hex(char, width),
    do: char |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(width, "0")

  # deepeval's ToolCall.__repr__: the set fields one per line, dict
  # input_parameters and output as json.dumps(indent=4, ensure_ascii=False).
  defp tool_call(%ToolCall{} = tool_call) do
    fields =
      Enum.reject(
        [
          string_field("name", tool_call.name),
          string_field("type", tool_call.type |> to_string() |> String.upcase()),
          string_field("description", tool_call.description),
          string_field("reasoning", tool_call.reasoning),
          input_parameters_field(tool_call.input_parameters),
          output_field(tool_call.output)
        ],
        &is_nil/1
      )

    ["ToolCall(\n    ", Enum.intersperse(fields, ",\n    "), "\n)"]
  end

  defp string_field(_name, nil), do: nil
  defp string_field(_name, ""), do: nil
  defp string_field(name, value), do: [name, "=\"", value, ?"]

  defp input_parameters_field(nil), do: nil
  defp input_parameters_field(params) when params == %{}, do: nil
  defp input_parameters_field(params), do: json_field("input_parameters", params)

  defp output_field(nil), do: nil

  defp output_field(output) when is_map(output) and not is_struct(output),
    do: json_field("output", output)

  defp output_field(output), do: ["output=", do_repr(output)]

  defp json_field(name, map) do
    [first | rest] = map |> JSON.encode!(indent: 4, ensure_ascii: false) |> String.split("\n")
    [name, ?=, first, Enum.map(rest, &["\n    ", &1])]
  end
end
