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
    booleans and deepeval `ToolCall`s and `RetrievedContextData`
  - `str/1` - Python's `str()`: a string as it is, a deepeval
    `RetrievedContextData` or `ToolCall` as pydantic prints it, anything
    else as `repr/1`
  - `format_fixed/2` - Python's `format(number, ".<n>f")`
  - `format_g/1` - Python's `format(number, "g")`, as in deepeval's
    `f"weight={weight:g}"`
  - `round/2` - Python's `round(number, ndigits)`, as in deepeval's
    `round(p, 3)` before a dict of probabilities is printed
  - `tojson/1` - Jinja's `tojson` filter on a string

  Floats are rounded from their exact binary value, ties to even, as
  CPython does, and `round/2` returns the float nearest the rounded
  decimal, so `repr/1` of the result prints what Python prints.
  """

  alias DeepEvalEx.MLLMImage
  alias DeepEvalEx.Schemas.{RetrievedContextData, ToolCall}
  alias DeepEvalEx.TestRun.JSON
  alias DeepEvalEx.Turn

  # Python's default precision for the "g" format.
  @g_precision 6

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
  - `DeepEvalEx.Turn`s as deepeval's `Turn.__repr__`,
    `Turn(role='user', content='Hi')` and the fields that are set
  - `DeepEvalEx.Schemas.RetrievedContextData` as pydantic's `__repr__`,
    `RetrievedContextData(context='...', source='...')`
  - `DeepEvalEx.Prompts.Python.EnumMember`s as `<Class.NAME: value>`
  - `DeepEvalEx.MLLMImage`s as their placeholder, unquoted, as
    `MLLMImage.__repr__`

  ## Examples

      iex> DeepEvalEx.Prompts.Python.repr(["Paris", "It's known for café culture."])
      ~S(['Paris', "It's known for café culture."])

      iex> DeepEvalEx.Prompts.Python.repr([1, 0.5, nil, true])
      "[1, 0.5, None, True]"
  """
  @spec repr(term()) :: String.t()
  def repr(term), do: term |> do_repr() |> IO.iodata_to_binary()

  @doc """
  Formats `term` like Python's `str(term)`, for what deepeval passes
  through `str()`: a string as it is, and a
  `DeepEvalEx.Schemas.RetrievedContextData` or a
  `DeepEvalEx.Schemas.ToolCall` as pydantic's `__str__`, every field as
  `name=repr(value)` joined with spaces (not deepeval's `model_serializer`
  or `ToolCall.__repr__`, which `str()` does not call). A tool call's
  `type` prints as its enum member, `<ToolCallType.FUNCTION: 'FUNCTION'>`.

  An atom is a string, as `repr/1` takes it. Anything else (a dict, a
  list, a number, `None`, a boolean) is its `repr/1`, as Python's `str()`
  of a built-in container or scalar is its `repr()`: deepeval's span and
  trace test cases take `str(span.input)` of the call's arguments.

  ## Examples

      iex> DeepEvalEx.Prompts.Python.str(Jason.OrderedObject.new([{"query", "hi"}, {"k", 2}]))
      "{'query': 'hi', 'k': 2}"

      iex> alias DeepEvalEx.Schemas.RetrievedContextData
      iex> DeepEvalEx.Prompts.Python.str(%RetrievedContextData{context: "It's here.", source: "wiki"})
      ~S(context="It's here." source='wiki')

      iex> DeepEvalEx.Prompts.Python.str(%DeepEvalEx.Schemas.ToolCall{name: "search", output: 1})
      "name='search' type=<ToolCallType.FUNCTION: 'FUNCTION'> description=None reasoning=None output=1 input_parameters=None"
  """
  @spec str(term()) :: String.t()
  def str(binary) when is_binary(binary), do: binary

  def str(%RetrievedContextData{context: context, source: source}),
    do: IO.iodata_to_binary(["context=", string(context), " source=", string(source)])

  def str(%ToolCall{} = tool_call) do
    type = tool_call.type |> Atom.to_string() |> String.upcase()

    [
      {"name", tool_call.name},
      {"type", %EnumMember{class: "ToolCallType", name: type, value: type}},
      {"description", tool_call.description},
      {"reasoning", tool_call.reasoning},
      {"output", tool_call.output},
      {"input_parameters", tool_call.input_parameters}
    ]
    |> Enum.map(fn {name, value} -> [name, ?=, do_repr(value)] end)
    |> Enum.intersperse(" ")
    |> IO.iodata_to_binary()
  end

  def str(atom) when is_atom(atom) and atom not in [nil, true, false], do: Atom.to_string(atom)
  def str(term), do: repr(term)

  @doc """
  Formats `string` like Jinja's `tojson` filter, which deepeval's templates
  use to embed a value in JSON: Python's `json.dumps` (non-ASCII escaped as
  `\\uXXXX`), then `<`, `>`, `&` and `'` escaped too, as Jinja's
  `htmlsafe_json_dumps` does.

  ## Examples

      iex> DeepEvalEx.Prompts.Python.tojson("Use <b> & 'quotes'")
      ~S("Use \\u003cb\\u003e \\u0026 \\u0027quotes\\u0027")
  """
  @spec tojson(String.t()) :: String.t()
  def tojson(string) when is_binary(string) do
    string
    |> JSON.encode!()
    |> String.replace(["<", ">", "&", "'"], fn
      "<" -> "\\u003c"
      ">" -> "\\u003e"
      "&" -> "\\u0026"
      "'" -> "\\u0027"
    end)
  end

  @doc """
  Formats `number` like Python's `format(number, ".<decimals>f")`.

  The number is rounded from its exact binary value, ties to even, as
  Python does: `0.125` is `"0.12"`, `0.375` is `"0.38"`. A negative number
  keeps its sign when it rounds to zero, `-0.0` included: `"-0.00"`.

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

  @doc """
  Formats `number` like Python's `format(number, "g")`.

  Six significant digits, rounded ties to even from the exact binary
  value. Numbers whose rounded decimal exponent is from -4 to 5 are
  written in fixed point, the rest in scientific notation with at least
  two exponent digits; trailing zeros and a trailing point are dropped.
  An integer is formatted as the float it converts to, as Python does.

  ## Examples

      iex> DeepEvalEx.Prompts.Python.format_g(1.0)
      "1"

      iex> DeepEvalEx.Prompts.Python.format_g(0.00001)
      "1e-05"

      iex> DeepEvalEx.Prompts.Python.format_g(1_234_567)
      "1.23457e+06"
  """
  @spec format_g(number()) :: String.t()
  def format_g(number) when is_integer(number), do: format_g(number * 1.0)

  def format_g(float) when is_float(float) do
    {sign, numerator, denominator} = rational(float)

    if numerator == 0 do
      sign <> "0"
    else
      {digits, exponent} = significant_digits(float, numerator, denominator, @g_precision)
      sign <> g_notation(Integer.to_string(digits), exponent)
    end
  end

  @doc """
  Rounds `number` like Python's `round(number, ndigits)`.

  A float is rounded to `ndigits` decimal places (tens, hundreds, ... when
  `ndigits` is negative) from its exact binary value, ties to even, and the
  result is the float nearest that decimal, keeping the sign of a value
  rounded to zero. An integer stays an integer: unchanged when `ndigits`
  is not negative, else rounded ties to even. Raises `ArgumentError`
  (Python's `OverflowError`) when the result is too large for a float.

  ## Examples

      iex> DeepEvalEx.Prompts.Python.round(0.6666666666666666, 3)
      0.667

      iex> DeepEvalEx.Prompts.Python.round(2.675, 2)
      2.67

      iex> DeepEvalEx.Prompts.Python.round(25, -1)
      20
  """
  @spec round(float(), integer()) :: float()
  @spec round(integer(), integer()) :: integer()
  def round(integer, ndigits) when is_integer(integer) and is_integer(ndigits) do
    if ndigits >= 0 do
      integer
    else
      scale = Integer.pow(10, -ndigits)
      rounded = round_ratio(abs(integer), scale) * scale
      if integer < 0, do: -rounded, else: rounded
    end
  end

  # CPython's NDIGITS_MAX and NDIGITS_MIN: beyond them a float is returned
  # as it is, or as a zero of its sign.
  def round(float, ndigits) when is_float(float) and is_integer(ndigits) and ndigits > 323,
    do: float

  def round(float, ndigits) when is_float(float) and is_integer(ndigits) and ndigits < -308,
    do: to_float(sign(float), 0, 1)

  def round(float, ndigits) when is_float(float) and is_integer(ndigits) do
    {sign, numerator, denominator} = rational(float)
    {numerator, denominator} = scale10(numerator, denominator, ndigits)
    rounded = round_ratio(numerator, denominator)
    {numerator, denominator} = scale10(rounded, 1, -ndigits)
    to_float(sign, numerator, denominator)
  end

  # A float as sign, integer mantissa and binary exponent:
  # |float| == mantissa * 2^exponent, exactly.
  defp decompose(float) do
    <<_sign::1, biased::11, fraction::52>> = <<float::float>>

    case biased do
      0 -> {sign(float), fraction, -1074}
      _ -> {sign(float), fraction + Bitwise.bsl(1, 52), biased - 1075}
    end
  end

  # The sign of a float, "-" for -0.0 too.
  defp sign(float) do
    <<sign::1, _::63>> = <<float::float>>
    if sign == 1, do: "-", else: ""
  end

  # A float as sign, numerator and denominator:
  # |float| == numerator / denominator, exactly.
  defp rational(float) do
    {sign, mantissa, exponent} = decompose(float)

    if exponent >= 0,
      do: {sign, Bitwise.bsl(mantissa, exponent), 1},
      else: {sign, mantissa, Bitwise.bsl(1, -exponent)}
  end

  # numerator / denominator * 10^power, as a ratio of integers.
  defp scale10(numerator, denominator, power) when power >= 0,
    do: {numerator * Integer.pow(10, power), denominator}

  defp scale10(numerator, denominator, power),
    do: {numerator, denominator * Integer.pow(10, -power)}

  # round(numerator * 2^exponent), ties to even.
  defp round_scaled(numerator, exponent) when exponent >= 0,
    do: Bitwise.bsl(numerator, exponent)

  defp round_scaled(numerator, exponent),
    do: round_ratio(numerator, Bitwise.bsl(1, -exponent))

  # round(numerator / denominator), ties to even, for non-negative values.
  defp round_ratio(numerator, denominator) do
    quotient = div(numerator, denominator)
    remainder = rem(numerator, denominator) * 2

    cond do
      remainder > denominator -> quotient + 1
      remainder == denominator and rem(quotient, 2) == 1 -> quotient + 1
      true -> quotient
    end
  end

  # The `precision` significant digits of numerator / denominator (> 0),
  # rounded ties to even, and the decimal exponent of the first digit:
  # the value is close to 0.d1d2... * 10^(exponent + 1).
  defp significant_digits(float, numerator, denominator, precision) do
    exponent =
      float
      |> abs()
      |> :math.log10()
      |> floor()
      |> fix_exponent(numerator, denominator)

    {scaled, scale} = scale10(numerator, denominator, precision - 1 - exponent)
    digits = round_ratio(scaled, scale)

    if digits == Integer.pow(10, precision),
      do: {Integer.pow(10, precision - 1), exponent + 1},
      else: {digits, exponent}
  end

  # Corrects a floating-point estimate of floor(log10(n / d)) exactly.
  defp fix_exponent(exponent, numerator, denominator) do
    cond do
      not at_least_pow10?(numerator, denominator, exponent) ->
        fix_exponent(exponent - 1, numerator, denominator)

      at_least_pow10?(numerator, denominator, exponent + 1) ->
        fix_exponent(exponent + 1, numerator, denominator)

      true ->
        exponent
    end
  end

  # n / d >= 10^power
  defp at_least_pow10?(numerator, denominator, power) when power >= 0,
    do: numerator >= denominator * Integer.pow(10, power)

  defp at_least_pow10?(numerator, denominator, power),
    do: numerator * Integer.pow(10, -power) >= denominator

  # Python's "g" layout of `digits` (the significant digits as a string)
  # whose first digit has decimal exponent `exponent`.
  defp g_notation(digits, exponent) when exponent >= -4 and exponent < @g_precision do
    {int, frac} =
      if exponent >= 0,
        do: String.split_at(digits, exponent + 1),
        else: {"0", String.duplicate("0", -exponent - 1) <> digits}

    case String.trim_trailing(frac, "0") do
      "" -> int
      frac -> int <> "." <> frac
    end
  end

  defp g_notation(digits, exponent) do
    {first, rest} = String.split_at(digits, 1)

    mantissa =
      case String.trim_trailing(rest, "0") do
        "" -> first
        rest -> first <> "." <> rest
      end

    exponent_sign = if exponent < 0, do: "-", else: "+"

    mantissa <>
      "e" <>
      exponent_sign <>
      (exponent |> abs() |> Integer.to_string() |> String.pad_leading(2, "0"))
  end

  # The float nearest numerator / denominator, ties to even, with `sign`.
  defp to_float(sign, 0, _denominator), do: if(sign == "-", do: -0.0, else: 0.0)

  defp to_float(sign, numerator, denominator) do
    exponent = bit_length(numerator) - bit_length(denominator) - 53

    exponent =
      if at_least_pow2?(numerator, denominator, exponent + 53),
        do: exponent + 1,
        else: exponent

    exponent = max(exponent, -1074)
    mantissa = round_ratio_pow2(numerator, denominator, exponent)

    {mantissa, exponent} =
      if mantissa == Bitwise.bsl(1, 53),
        do: {Bitwise.bsl(1, 52), exponent + 1},
        else: {mantissa, exponent}

    if exponent > 971, do: raise(ArgumentError, "rounding overflowed")

    sign_bit = if sign == "-", do: 1, else: 0

    <<float::float>> =
      if mantissa >= Bitwise.bsl(1, 52),
        do: <<sign_bit::1, exponent + 1075::11, mantissa - Bitwise.bsl(1, 52)::52>>,
        else: <<sign_bit::1, 0::11, mantissa::52>>

    float
  end

  # n / d >= 2^power
  defp at_least_pow2?(numerator, denominator, power) when power >= 0,
    do: numerator >= Bitwise.bsl(denominator, power)

  defp at_least_pow2?(numerator, denominator, power),
    do: Bitwise.bsl(numerator, -power) >= denominator

  # round(n / d / 2^exponent), ties to even.
  defp round_ratio_pow2(numerator, denominator, exponent) when exponent >= 0,
    do: round_ratio(numerator, Bitwise.bsl(denominator, exponent))

  defp round_ratio_pow2(numerator, denominator, exponent),
    do: round_ratio(Bitwise.bsl(numerator, -exponent), denominator)

  defp bit_length(integer), do: integer |> Integer.to_string(2) |> byte_size()

  defp do_repr(nil), do: "None"
  defp do_repr(true), do: "True"
  defp do_repr(false), do: "False"
  defp do_repr(atom) when is_atom(atom), do: string(Atom.to_string(atom))
  defp do_repr(binary) when is_binary(binary), do: string(binary)
  defp do_repr(integer) when is_integer(integer), do: Integer.to_string(integer)
  defp do_repr(float) when is_float(float), do: JSON.float_repr(float)
  defp do_repr(list) when is_list(list), do: [?[, list |> Enum.map(&do_repr/1) |> join(), ?]]
  defp do_repr(%ToolCall{} = tool_call), do: tool_call(tool_call)
  defp do_repr(%Turn{} = turn), do: turn(turn)
  defp do_repr(%MLLMImage{} = image), do: MLLMImage.placeholder(image)

  defp do_repr(%RetrievedContextData{context: context, source: source}),
    do: ["RetrievedContextData(context=", string(context), ", source=", string(source), ?)]

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

  # deepeval's Turn.__repr__: role and content, then the set fields, each
  # as name=repr(value), in its order.
  defp turn(%Turn{} = turn) do
    optional =
      for field <- [
            :audio,
            :latency_ms,
            :interrupted,
            :provider_transcript,
            :user_id,
            :retrieval_context,
            :tools_called,
            :metadata
          ],
          value <- [Map.fetch!(turn, field)],
          value != nil,
          do: [Atom.to_string(field), ?=, do_repr(value)]

    fields = [["role=", do_repr(turn.role)], ["content=", do_repr(turn.content)] | optional]
    ["Turn(", join(fields), ?)]
  end

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
  defp input_parameters_field(%Jason.OrderedObject{values: []}), do: nil
  defp input_parameters_field(params), do: json_field("input_parameters", params)

  defp output_field(nil), do: nil

  defp output_field(%Jason.OrderedObject{} = output), do: json_field("output", output)

  defp output_field(output) when is_map(output) and not is_struct(output),
    do: json_field("output", output)

  defp output_field(output), do: ["output=", do_repr(output)]

  defp json_field(name, map) do
    [first | rest] = map |> JSON.encode!(indent: 4, ensure_ascii: false) |> String.split("\n")
    [name, ?=, first, Enum.map(rest, &["\n    ", &1])]
  end
end
