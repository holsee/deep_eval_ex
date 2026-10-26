# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0

defmodule DeepEvalEx.Report.Terminal do
  @moduledoc """
  Draws `DeepEvalEx.Report` data in a terminal, with box-drawing characters
  and ANSI colours.

  Panels fill the width and trees draw Rich's guides. Tables are laid out
  as Rich 14 lays them out: each column as wide as its longest line, and,
  when the table does not fit, the widest columns narrowed together
  towards the next widest (`Table._calculate_column_widths`), cells
  wrapped at word boundaries (`divide_line`) with a word wider than its
  column cut with `…` (or folded, for a column with `overflow: :fold`), and
  headers aligned to the bottom of their row. Without colour, the
  `Test Results` table and its turn tables come out byte for byte as
  deepeval prints them; this is checked against Rich's own renders at 60,
  80, 100, 120 and 160 columns (the report fixtures' `table_<width>.txt`).
  Panels and trees only resemble Rich's (ADR-0010 decision 10). Rows
  tagged `:confident_ai` are not drawn.

  Emoji and East Asian wide characters count as two columns.

  ## Colour

  Styles are drawn as ANSI escapes the way deepeval's Rich `Console`
  decides it (`Console.is_terminal`, `is_dumb_terminal`, `no_color`):

  - only when writing to a terminal: `TTY_COMPATIBLE=1` says it is one and
    `TTY_COMPATIBLE=0` that it is not; else a set `FORCE_COLOR` says it is
    one when not empty and is not one when empty; else it is one when
    standard output is a terminal;
  - not on a dumb terminal, whose `TERM` is `dumb` or `unknown`;
  - with `NO_COLOR` set and not empty, without colours: bold, dim and
    italic are still drawn.

  Standard output is a terminal when the `:stdout` option of
  `:io.getopts(:standard_io)` says so (OTP 26 and later report whether
  the emulator's standard output is a TTY). On an older OTP, which lacks
  it, its `:terminal` option, else a width from `:io.columns/0`, stands
  in. A run under CI, through a pipe, or in `docker exec` or
  `devcontainer exec` without `-t` therefore prints no escapes, as
  deepeval does. Rich's colour system (8, 256 or true colour) is not
  ported: `rgb(...)` styles are drawn as true colour.

  ## Options

  - `:width` - Columns to draw in (default: `width/1`)
  - `:color` - `true` or `false` to draw styles as ANSI escapes or not,
    whatever the terminal and environment (default: as Rich decides, see
    "Colour")
  """

  alias DeepEvalEx.Report
  alias DeepEvalEx.Report.{Panel, Table, Tree}

  # A drawn line: its iodata and its width in columns.
  @typep line :: {iodata(), non_neg_integer()}

  # How styles are drawn: not at all, fully, or without colours (NO_COLOR).
  @typep color :: boolean() | :no_color

  @doc """
  Draws `renderables` (one or a list), one after the other, each line
  ending with a newline.
  """
  @spec render(Report.renderable() | [Report.renderable()], keyword()) :: iodata()
  def render(renderables, opts \\ []) do
    ctx = %{width: width(opts), color: color(opts)}

    renderables
    |> List.wrap()
    |> Enum.flat_map(&draw(&1, ctx.width, ctx))
    |> Enum.map(fn {iodata, _width} -> [iodata, "\n"] end)
  end

  @doc """
  Draws `text` as it is, without wrapping, styled when colour is on.
  """
  @spec render_text(Report.text(), keyword()) :: iodata()
  def render_text(text, opts \\ []) do
    color = color(opts)

    text
    |> glyphs([])
    |> chunk_styles()
    |> Enum.map(fn {styles, string} -> styled(string, styles, color) end)
  end

  @doc """
  The width, in columns, `render/2` draws in, as Rich's `Console.size`
  works it out:

  1. the `:width` option;
  2. 80 on a dumb terminal (see "Colour" in the moduledoc), unless both
     `COLUMNS` and `LINES` are set;
  3. the `COLUMNS` environment variable, when it is all digits;
  4. the terminal's width, when one is attached (`:io.columns/0`);
  5. 80.

  So a run without a terminal (CI, a pipe, `docker exec` without `-t`)
  and `COLUMNS` unset draws 80 columns wide, as deepeval does.

  Two edge cases differ from Rich. `COLUMNS=0` gives 80: Rich's `Console`
  takes it as a width of 0 and draws nothing. And `COLUMNS` must be ASCII
  digits, where Python's `str.isdigit` also accepts other Unicode digits.
  """
  @spec width(keyword()) :: pos_integer()
  def width(opts \\ []) do
    columns = env_digits("COLUMNS")

    cond do
      opts[:width] -> opts[:width]
      columns != nil and env_digits("LINES") != nil -> positive_or_80(columns)
      dumb_terminal?() -> 80
      columns != nil -> positive_or_80(columns)
      true -> terminal_columns() || 80
    end
  end

  # Rich reads COLUMNS and LINES only when they are all digits.
  defp env_digits(var) do
    value = System.get_env(var, "")
    if value =~ ~r/\A[0-9]+\z/, do: String.to_integer(value)
  end

  defp positive_or_80(0), do: 80
  defp positive_or_80(columns), do: columns

  defp terminal_columns do
    case :io.columns() do
      {:ok, columns} when columns > 0 -> columns
      _no_terminal -> nil
    end
  end

  @spec color(keyword()) :: color()
  defp color(opts) do
    case Keyword.fetch(opts, :color) do
      {:ok, color} when is_boolean(color) -> color
      _auto -> auto_color()
    end
  end

  # Console._detect_color_system and Console.no_color.
  defp auto_color do
    cond do
      not terminal?() or dumb_terminal?() -> false
      System.get_env("NO_COLOR", "") != "" -> :no_color
      true -> true
    end
  end

  # Console.is_terminal: TTY_COMPATIBLE, then FORCE_COLOR, then whether
  # standard output is a TTY.
  defp terminal? do
    case System.get_env("TTY_COMPATIBLE") do
      "0" ->
        false

      "1" ->
        true

      _auto ->
        case System.get_env("FORCE_COLOR") do
          nil -> stdout_tty?()
          force_color -> force_color != ""
        end
    end
  end

  # Console.is_dumb_terminal.
  defp dumb_terminal? do
    terminal?() and String.downcase(System.get_env("TERM", "")) in ["dumb", "unknown"]
  end

  # :io.columns/0 alone cannot tell: a terminal whose size is unknown
  # (a pseudo-terminal of 0x0, say) answers {:error, :enotsup} too.
  defp stdout_tty? do
    case :io.getopts(:standard_io) do
      opts when is_list(opts) -> Keyword.get_lazy(opts, :stdout, fn -> older_otp_tty?(opts) end)
      _error -> false
    end
  end

  defp older_otp_tty?(opts),
    do: Keyword.get_lazy(opts, :terminal, fn -> terminal_columns() != nil end)

  # -- Renderables ---------------------------------------------------------

  @spec draw(Report.renderable(), pos_integer(), map()) :: [line()]
  defp draw(%Panel{} = panel, width, ctx), do: draw_panel(panel, width, ctx)
  defp draw(%Tree{} = tree, width, ctx), do: draw_tree(tree, width, ctx)
  defp draw(%Table{} = table, width, ctx), do: draw_table(table, width, ctx)

  defp draw(text, width, ctx),
    do: text |> glyphs([]) |> wrap(width) |> Enum.map(&draw_glyphs(&1, ctx))

  defp draw_panel(%Panel{padding: {vpad, hpad}} = panel, width, ctx) do
    width = max(width, 2 * hpad + 3)
    inner = width - 2 - 2 * hpad
    border = border_styles(panel.border_style)
    blank = {:binary.copy(" ", inner), inner}

    body =
      List.duplicate(blank, vpad) ++
        draw(panel.content, inner, ctx) ++ List.duplicate(blank, vpad)

    side = styled("│", border, ctx.color)
    pad = :binary.copy(" ", hpad)

    [{styled("╭" <> String.duplicate("─", width - 2) <> "╮", border, ctx.color), width}] ++
      Enum.map(body, fn line -> {[side, pad, pad_line(line, inner), pad, side], width} end) ++
      [{styled("╰" <> String.duplicate("─", width - 2) <> "╯", border, ctx.color), width}]
  end

  defp border_styles(nil), do: []
  defp border_styles("none"), do: []
  defp border_styles(style), do: [style]

  defp draw_tree(%Tree{label: label, children: children}, width, ctx) do
    last = length(children) - 1

    child_lines =
      children
      |> Enum.with_index()
      |> Enum.flat_map(fn {child, index} ->
        {first, rest} = if index == last, do: {"└── ", "    "}, else: {"├── ", "│   "}

        case draw_tree(child, max(width - 4, 1), ctx) do
          [] ->
            []

          [head | tail] ->
            [prefix(first, head) | Enum.map(tail, &prefix(rest, &1))]
        end
      end)

    draw(label, width, ctx) ++ child_lines
  end

  defp prefix(guide, {iodata, width}), do: {[guide, iodata], width + 4}

  # -- Tables --------------------------------------------------------------

  # Rich's Table: column widths from Table._calculate_column_widths, cells
  # wrapped as Text.wrap wraps them, headers aligned to the bottom of their
  # row and other cells to the top. Widths below include the padding.
  defp draw_table(%Table{} = table, width, ctx) do
    rows = Enum.reject(table.rows, &match?({:confident_ai, _}, &1))
    columns = table.columns
    boxed? = table.box != :none
    extra = extra_width(table, length(columns))

    header =
      if table.show_header do
        styles = if table.header_style, do: [table.header_style], else: []
        [Enum.map(columns, &{:style, Enum.join(styles, " "), &1.header})]
      else
        []
      end

    cells =
      Enum.with_index(columns, fn column, i ->
        [column | Enum.map(header ++ rows, &Enum.at(&1, i))]
      end)

    widths = column_widths(table, cells, width - extra)
    table_width = Enum.sum(widths) + extra

    header_lines =
      Enum.flat_map(header, &draw_row(&1, columns, widths, ctx, table, boxed?, "┃", :bottom))

    body = Enum.flat_map(rows, &draw_row(&1, columns, widths, ctx, table, boxed?, "│", :top))

    title(table, table_width, ctx) ++
      top(table, widths, boxed?) ++
      header_lines ++
      header_rule(table, widths, boxed?) ++ body ++ bottom(table, widths, boxed?)
  end

  # The box's edges and the separators between columns (Table._extra_width).
  defp extra_width(%Table{box: :none}, _columns), do: 0
  defp extra_width(%Table{show_edge: true}, columns), do: columns + 1
  defp extra_width(_table, columns), do: columns - 1

  # Table._calculate_column_widths: each column as wide as its widest line,
  # collapsed like Rich's when the table does not fit, an expanding table
  # sharing the spare columns out by width.
  defp column_widths(table, cells, max_width) do
    pad = 2 * table.padding
    widths = Enum.map(cells, &(&1 |> measure_column(pad, max_width) |> elem(1) |> max(1)))

    {widths, table_width} =
      if Enum.sum(widths) > max_width,
        do: shrink_widths(widths, cells, pad, max_width),
        else: {widths, Enum.sum(widths)}

    if table.expand and table_width < max_width and Enum.sum(widths) > 0 do
      widths
      |> Enum.zip(ratio_distribute(max_width - table_width, widths))
      |> Enum.map(fn {width, extra} -> width + extra end)
    else
      widths
    end
  end

  # Collapses the wrapable columns, then, as a last resort, narrows every
  # column evenly; returns the widths remeasured and the table's width.
  defp shrink_widths(widths, cells, pad, max_width) do
    wrapable = Enum.map(cells, fn [column | _] -> wrapable?(column) end)
    widths = collapse_widths(widths, wrapable, max_width)
    excess = Enum.sum(widths) - max_width

    widths =
      if excess > 0,
        do: ratio_reduce(excess, Enum.map(widths, fn _ -> 1 end), widths, widths),
        else: widths

    remeasured =
      Enum.zip_with(widths, cells, fn width, cells ->
        cells |> measure_column(pad, width) |> elem(1)
      end)

    {remeasured, Enum.sum(widths)}
  end

  defp wrapable?(column), do: is_nil(column[:width]) and not Map.get(column, :no_wrap, false)

  # Table._measure_column: {minimum, maximum} of a column's cells, the
  # header first, with padding.
  defp measure_column(_cells, _pad, max_width) when max_width < 1, do: {0, 0}

  defp measure_column([column | cells], pad, max_width) do
    case column[:width] do
      nil ->
        measures = Enum.map(cells, &measure_cell(&1, pad, max_width))
        minimum = measures |> Enum.map(&elem(&1, 0)) |> Enum.max(fn -> 1 end)
        maximum = measures |> Enum.map(&elem(&1, 1)) |> Enum.max(fn -> max_width end)
        limit = column[:max_width]

        {minimum, maximum}
        |> with_maximum(max_width)
        |> then(&if limit, do: with_maximum(&1, limit + pad), else: &1)

      width ->
        with_maximum({width + pad, width + pad}, max_width)
    end
  end

  # Measurement.get of a padded cell (Padding and Text.__rich_measure__):
  # its longest word and its longest line.
  defp measure_cell(text, pad, max_width) do
    padded =
      if max_width - pad < 1 do
        {max_width, max_width}
      else
        {minimum, maximum} = text |> measure_text() |> measurement(max_width)
        with_maximum({minimum + pad, maximum + pad}, max_width)
      end

    measurement(padded, max_width)
  end

  defp measure_text(text) do
    plain = Report.plain(text)
    longest = fn strings -> strings |> Enum.map(&string_width/1) |> Enum.max(fn -> nil end) end
    maximum = plain |> String.split("\n") |> longest.() |> Kernel.||(0)
    {longest.(String.split(plain)) || maximum, maximum}
  end

  defp measurement(_measurement, max_width) when max_width < 1, do: {0, 0}

  defp measurement(measurement, max_width) do
    case measurement |> normalize() |> with_maximum(max_width) do
      {_minimum, maximum} when maximum < 1 -> {0, 0}
      measured -> normalize(measured)
    end
  end

  defp normalize({minimum, maximum}) do
    minimum = min(max(0, minimum), maximum)
    {max(0, minimum), max(0, max(minimum, maximum))}
  end

  defp with_maximum({minimum, maximum}, width), do: {min(minimum, width), min(maximum, width)}

  # Table._collapse_widths: narrows the widest wrapable columns, together,
  # towards the next widest, until the table fits or they are as narrow.
  defp collapse_widths(widths, wrapable, max_width) do
    excess = Enum.sum(widths) - max_width

    if Enum.any?(wrapable) and Enum.sum(widths) != 0 and excess > 0,
      do: collapse_widest(widths, wrapable, max_width, excess),
      else: widths
  end

  defp collapse_widest(widths, wrapable, max_width, excess) do
    pairs = Enum.zip(widths, wrapable)
    widest = for({width, true} <- pairs, do: width) |> Enum.max()
    next = for {width, wrap?} <- pairs, wrap? and width != widest, do: width
    difference = widest - Enum.max(next, fn -> 0 end)

    if difference == 0 do
      widths
    else
      ratios = Enum.map(pairs, &if(&1 == {widest, true}, do: 1, else: 0))
      maximums = Enum.map(widths, fn _ -> min(excess, difference) end)

      excess
      |> ratio_reduce(ratios, maximums, widths)
      |> collapse_widths(wrapable, max_width)
    end
  end

  # rich._ratio.ratio_reduce: takes `total` off `values` in proportion to
  # `ratios`, at most `maximums`.
  defp ratio_reduce(total, ratios, maximums, values) do
    ratios =
      Enum.zip_with(ratios, maximums, fn ratio, maximum -> if maximum == 0, do: 0, else: ratio end)

    [ratios, maximums, values]
    |> Enum.zip()
    |> Enum.map_reduce({total, Enum.sum(ratios)}, fn
      {ratio, maximum, value}, {remaining, total_ratio} when ratio > 0 and total_ratio > 0 ->
        distributed = min(maximum, round_half_even(ratio * remaining, total_ratio))
        {value - distributed, {remaining - distributed, total_ratio - ratio}}

      {_ratio, _maximum, value}, acc ->
        {value, acc}
    end)
    |> elem(0)
  end

  # rich._ratio.ratio_distribute without minimums: shares `total` out in
  # proportion to `ratios`, rounding up.
  defp ratio_distribute(total, ratios) do
    ratios
    |> Enum.map_reduce({total, Enum.sum(ratios)}, fn ratio, {remaining, total_ratio} ->
      distributed =
        if total_ratio > 0, do: ceil_div(ratio * remaining, total_ratio), else: remaining

      {distributed, {remaining - distributed, total_ratio - ratio}}
    end)
    |> elem(0)
  end

  # Python's round() of numerator / denominator: halves to even.
  defp round_half_even(numerator, denominator) do
    quotient = Integer.floor_div(numerator, denominator)
    remainder = numerator - quotient * denominator

    cond do
      2 * remainder > denominator -> quotient + 1
      2 * remainder < denominator -> quotient
      rem(quotient, 2) == 0 -> quotient
      true -> quotient + 1
    end
  end

  defp ceil_div(numerator, denominator), do: -Integer.floor_div(-numerator, denominator)

  defp title(%Table{title: nil}, _width, _ctx), do: []

  defp title(%Table{title: title, title_justify: justify}, width, ctx) do
    title
    |> glyphs(["italic"])
    |> wrap(width, justify: justify)
    |> Enum.reject(&(&1 == []))
    |> Enum.map(fn glyphs ->
      line = draw_glyphs(glyphs, ctx)
      if justify == :center, do: {center(line, width), width}, else: line
    end)
  end

  defp center({iodata, w}, width) do
    left = div(max(width - w, 0), 2)
    [:binary.copy(" ", left), iodata, :binary.copy(" ", max(width - w - left, 0))]
  end

  defp top(%Table{show_edge: true}, widths, true), do: [rule(widths, "┏", "━", "┳", "┓")]
  defp top(_table, _widths, _boxed?), do: []

  defp header_rule(%Table{show_header: true, show_edge: edge?}, widths, true) do
    if edge?,
      do: [rule(widths, "┡", "━", "╇", "┩")],
      else: [rule(widths, "", "━", "╇", "")]
  end

  defp header_rule(_table, _widths, _boxed?), do: []

  defp bottom(%Table{show_edge: true}, widths, true), do: [rule(widths, "└", "─", "┴", "┘")]
  defp bottom(_table, _widths, _boxed?), do: []

  defp rule(widths, left, fill, cross, right) do
    middle = Enum.map_join(widths, cross, &String.duplicate(fill, &1))
    line = left <> middle <> right
    {line, string_width(line)}
  end

  defp draw_row(cells, columns, widths, ctx, table, boxed?, bar, vertical) do
    wrapped =
      [cells, columns, widths]
      |> Enum.zip()
      |> Enum.map(fn {cell, column, width} -> draw_cell(cell, column, width, table, ctx) end)

    height = wrapped |> Enum.map(&length/1) |> Enum.max(fn -> 1 end)
    separator = if boxed?, do: bar, else: ""
    edge = if boxed? and table.show_edge, do: bar, else: ""

    aligned =
      Enum.zip_with(wrapped, widths, fn lines, width ->
        blank = List.duplicate({:binary.copy(" ", width), width}, height - length(lines))
        if vertical == :bottom, do: blank ++ lines, else: lines ++ blank
      end)

    for i <- 0..(height - 1) do
      cells = Enum.map(aligned, &(&1 |> Enum.at(i) |> elem(0)))

      {[edge, Enum.intersperse(cells, separator), edge],
       Enum.sum(widths) + extra_width(table, length(widths))}
    end
  end

  # A cell's lines, each `width` columns wide with the table's padding.
  defp draw_cell(cell, column, width, table, ctx) do
    pad = table.padding
    content = width - 2 * pad

    if content < 1 do
      [{:binary.copy(" ", width), width}]
    else
      styles = if column[:style], do: [column.style], else: []
      justify = Map.get(column, :justify, :left)
      spaces = :binary.copy(" ", pad)

      cell
      |> glyphs(styles)
      |> wrap(content,
        justify: justify,
        overflow: Map.get(column, :overflow, :ellipsis),
        no_wrap: Map.get(column, :no_wrap, false)
      )
      |> Enum.map(fn glyphs ->
        {[spaces, glyphs |> draw_glyphs(ctx) |> justify(content, justify), spaces], width}
      end)
    end
  end

  defp justify({iodata, w}, width, :right), do: [:binary.copy(" ", max(width - w, 0)), iodata]
  defp justify(line, width, :center), do: center(line, width)
  defp justify(line, width, _left), do: pad_line(line, width)

  defp pad_line({iodata, w}, width), do: [iodata, :binary.copy(" ", max(width - w, 0))]

  # -- Text ----------------------------------------------------------------

  # A text as glyphs: {grapheme, columns, styles}.
  defp glyphs(text, styles) when is_binary(text) do
    text |> String.graphemes() |> Enum.map(&{&1, grapheme_width(&1), styles})
  end

  defp glyphs({:style, style, text}, styles), do: glyphs(text, styles ++ [style])
  defp glyphs(texts, styles) when is_list(texts), do: Enum.flat_map(texts, &glyphs(&1, styles))

  defp string_width(string),
    do: string |> String.graphemes() |> Enum.map(&grapheme_width/1) |> Enum.sum()

  # Rich's Text.wrap: lines of at most `width` columns, broken at newlines
  # and before words that do not fit (divide_line). A word wider than a
  # line is folded across lines (overflow `:fold`, Rich's default for
  # text) or cut with an ellipsis (`:ellipsis`, its default in tables).
  defp wrap(glyphs, width, opts \\ []) do
    width = max(width, 1)
    justify = Keyword.get(opts, :justify, :left)
    overflow = Keyword.get(opts, :overflow, :fold)

    glyphs
    |> Enum.reduce([[]], fn
      {"\n", _, _}, lines -> [[] | lines]
      glyph, [current | rest] -> [[glyph | current] | rest]
    end)
    |> Enum.reverse()
    |> Enum.flat_map(fn line ->
      line
      |> Enum.reverse()
      |> wrap_line(width, overflow, Keyword.get(opts, :no_wrap, false))
      |> Enum.map(&(&1 |> justify_glyphs(justify) |> truncate(width, overflow)))
    end)
  end

  defp wrap_line(line, _width, _overflow, true = _no_wrap), do: [line]

  defp wrap_line(line, width, overflow, false) do
    line
    |> divide(divide_line(line, width, overflow == :fold))
    |> Enum.map(&rstrip_end(&1, width))
  end

  # Lines.justify: centred and right-justified lines lose trailing spaces.
  defp justify_glyphs(line, justify) when justify in [:center, :right],
    do: trim_trailing_spaces(line)

  defp justify_glyphs(line, _justify), do: line

  # rich._wrap.divide_line: the glyph offsets to break `glyphs` at.
  defp divide_line(glyphs, width, fold?) do
    glyphs
    |> words(0, [])
    |> Enum.reduce({[], 0}, fn {start, word}, {breaks, offset} ->
      word_length = word |> trim_trailing_spaces() |> glyphs_width()

      cond do
        width - offset >= word_length ->
          {breaks, offset + glyphs_width(word)}

        word_length > width and fold? ->
          fold_word(chop_glyphs(word, width), start, breaks)

        word_length > width ->
          {add_break(breaks, start), glyphs_width(word)}

        offset > 0 and start > 0 ->
          {[start | breaks], glyphs_width(word)}

        true ->
          {breaks, offset}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp fold_word([last], start, breaks), do: {add_break(breaks, start), glyphs_width(last)}

  defp fold_word([line | rest], start, breaks),
    do: fold_word(rest, start + length(line), add_break(breaks, start))

  defp add_break(breaks, 0), do: breaks
  defp add_break(breaks, start), do: [start | breaks]

  # rich._wrap.words: each word with the whitespace after it (and, for the
  # first, before it), with its offset.
  defp words(glyphs, start, acc) do
    {lead, rest} = Enum.split_while(glyphs, &space?/1)
    {body, rest} = Enum.split_while(rest, &(not space?(&1)))

    if body == [] do
      Enum.reverse(acc)
    else
      {trail, rest} = Enum.split_while(rest, &space?/1)
      word = lead ++ body ++ trail
      words(rest, start + length(word), [{start, word} | acc])
    end
  end

  defp space?({grapheme, _, _}), do: String.trim(grapheme) == ""

  # rich.cells.chop_cells: `glyphs` in lines of at most `width` columns.
  defp chop_glyphs(glyphs, width) do
    {lines, line, _used} =
      Enum.reduce(glyphs, {[], [], 0}, fn {_, w, _} = glyph, {lines, line, used} ->
        if used + w > width,
          do: {[Enum.reverse(line) | lines], [glyph], w},
          else: {lines, [glyph | line], used + w}
      end)

    Enum.reverse([Enum.reverse(line) | lines])
  end

  defp divide(glyphs, offsets) do
    {lines, rest, _at} =
      Enum.reduce(offsets, {[], glyphs, 0}, fn offset, {lines, rest, at} ->
        {line, rest} = Enum.split(rest, offset - at)
        {[line | lines], rest, offset}
      end)

    Enum.reverse([rest | lines])
  end

  # Text.rstrip_end: drops trailing whitespace past `width` code points.
  defp rstrip_end(glyphs, width) do
    excess = codepoints(glyphs) - width

    if excess > 0 do
      trailing = glyphs |> Enum.reverse() |> Enum.take_while(&space?/1) |> length()
      Enum.drop(glyphs, -min(trailing, excess))
    else
      glyphs
    end
  end

  defp codepoints(glyphs),
    do: glyphs |> Enum.map(fn {grapheme, _, _} -> String.length(grapheme) end) |> Enum.sum()

  # Text.truncate: a line wider than `width` cut to fit, ending in an
  # ellipsis under `:ellipsis`.
  defp truncate(glyphs, width, overflow) do
    if glyphs_width(glyphs) > width do
      case overflow do
        :ellipsis ->
          kept = set_cell_size(glyphs, width - 1)
          styles = glyphs |> Enum.at(length(kept)) |> elem(2)
          kept ++ [{"…", 1, styles}]

        _crop_or_fold ->
          set_cell_size(glyphs, width)
      end
    else
      glyphs
    end
  end

  # rich.cells.set_cell_size, cropping: the glyphs that fit in `width`
  # columns, a space standing in for half a wide character.
  defp set_cell_size(_glyphs, width) when width <= 0, do: []

  defp set_cell_size(glyphs, width) do
    {kept, used} =
      Enum.reduce_while(glyphs, {[], 0}, fn {_, w, _} = glyph, {kept, used} ->
        if used + w > width, do: {:halt, {kept, used}}, else: {:cont, {[glyph | kept], used + w}}
      end)

    Enum.reverse(kept) ++ List.duplicate({" ", 1, []}, width - used)
  end

  defp trim_trailing_spaces(glyphs) do
    glyphs |> Enum.reverse() |> Enum.drop_while(&space?/1) |> Enum.reverse()
  end

  defp glyphs_width(glyphs), do: glyphs |> Enum.map(&elem(&1, 1)) |> Enum.sum()

  defp draw_glyphs(glyphs, ctx) do
    iodata =
      glyphs
      |> chunk_styles()
      |> Enum.map(fn {styles, string} -> styled(string, styles, ctx.color) end)

    {iodata, glyphs_width(glyphs)}
  end

  defp chunk_styles(glyphs) do
    glyphs
    |> Enum.chunk_by(&elem(&1, 2))
    |> Enum.map(fn [{_, _, styles} | _] = chunk ->
      {styles, Enum.map_join(chunk, &elem(&1, 0))}
    end)
  end

  defp styled(string, _styles, false), do: string
  defp styled(string, [], true), do: string

  defp styled(string, styles, color) do
    case styles |> Enum.flat_map(&String.split/1) |> Enum.map_join(&ansi(&1, color)) do
      "" -> string
      codes -> [codes, string, IO.ANSI.reset()]
    end
  end

  @colors ~w(black red green yellow blue magenta cyan white)
  @attributes ~w(bold dim italic)

  # Segment.remove_color: NO_COLOR keeps the attributes only.
  defp ansi(style, :no_color), do: if(style in @attributes, do: ansi(style), else: "")
  defp ansi(style, true), do: ansi(style)

  defp ansi("bold"), do: IO.ANSI.bright()
  defp ansi("dim"), do: IO.ANSI.faint()
  defp ansi("italic"), do: IO.ANSI.italic()
  defp ansi(color) when color in @colors, do: apply(IO.ANSI, String.to_existing_atom(color), [])

  defp ansi("rgb(" <> rest) do
    case rest |> String.trim_trailing(")") |> String.split(",") |> Enum.map(&Integer.parse/1) do
      [{r, ""}, {g, ""}, {b, ""}] -> "\e[38;2;#{r};#{g};#{b}m"
      _ -> ""
    end
  end

  defp ansi(_style), do: ""

  # -- Widths --------------------------------------------------------------

  @doc false
  # The columns a grapheme takes: 2 for emoji and East Asian wide
  # characters, 0 for a lone combining mark, else 1.
  @spec grapheme_width(String.t()) :: non_neg_integer()
  def grapheme_width(grapheme) do
    codepoints = String.to_charlist(grapheme)

    cond do
      0xFE0F in codepoints -> 2
      Enum.any?(codepoints, &wide?/1) -> 2
      Enum.all?(codepoints, &zero_width?/1) -> 0
      true -> 1
    end
  end

  defp zero_width?(cp) do
    cp in 0x0300..0x036F or cp in 0x200B..0x200F or cp in 0xFE00..0xFE0F or cp == 0x200D
  end

  @wide [
    0x1100..0x115F,
    0x231A..0x231B,
    0x2329..0x232A,
    0x23E9..0x23EC,
    0x23F0..0x23F0,
    0x23F3..0x23F3,
    0x25FD..0x25FE,
    0x2614..0x2615,
    0x2648..0x2653,
    0x267F..0x267F,
    0x2693..0x2693,
    0x26A1..0x26A1,
    0x26AA..0x26AB,
    0x26BD..0x26BE,
    0x26C4..0x26C5,
    0x26CE..0x26CE,
    0x26D4..0x26D4,
    0x26EA..0x26EA,
    0x26F2..0x26F3,
    0x26F5..0x26F5,
    0x26FA..0x26FA,
    0x26FD..0x26FD,
    0x2705..0x2705,
    0x270A..0x270B,
    0x2728..0x2728,
    0x274C..0x274C,
    0x274E..0x274E,
    0x2753..0x2755,
    0x2757..0x2757,
    0x2795..0x2797,
    0x27B0..0x27B0,
    0x27BF..0x27BF,
    0x2B1B..0x2B1C,
    0x2B50..0x2B50,
    0x2B55..0x2B55,
    0x2E80..0x303E,
    0x3041..0x33FF,
    0x3400..0x4DBF,
    0x4E00..0x9FFF,
    0xA000..0xA4CF,
    0xAC00..0xD7A3,
    0xF900..0xFAFF,
    0xFE30..0xFE4F,
    0xFF00..0xFF60,
    0xFFE0..0xFFE6,
    0x1F004..0x1F004,
    0x1F0CF..0x1F0CF,
    0x1F18E..0x1F18E,
    0x1F191..0x1F19A,
    0x1F200..0x1F64F,
    0x1F680..0x1F6FF,
    0x1F7E0..0x1F7EB,
    0x1F90C..0x1F9FF,
    0x1FA70..0x1FAFF,
    0x20000..0x3FFFD
  ]

  defp wide?(cp), do: Enum.any?(@wide, &(cp in &1))
end
