# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0

defmodule DeepEvalEx.Report.Terminal do
  @moduledoc """
  Draws `DeepEvalEx.Report` data in a terminal, with box-drawing characters
  and ANSI colours.

  Panels fill the width, trees draw Rich's guides, tables size their
  columns to their contents and wrap the widest when they do not fit. The
  output resembles Rich's but is not byte-identical (ADR-0010 decision 10):
  the strings inside it are deepeval's, the layout is DeepEvalEx's. Rows
  tagged `:confident_ai` are not drawn.

  Emoji and East Asian wide characters count as two columns.

  ## Options

  - `:width` - Columns to draw in (default: the `COLUMNS` environment
    variable, else the terminal's width, else 80)
  - `:color` - Draw styles as ANSI escapes (default: `IO.ANSI.enabled?/0`,
    unless the `NO_COLOR` environment variable is set)
  """

  alias DeepEvalEx.Report
  alias DeepEvalEx.Report.{Panel, Table, Tree}

  # A drawn line: its iodata and its width in columns.
  @typep line :: {iodata(), non_neg_integer()}

  @doc """
  Draws `renderables` (one or a list), one after the other, each line
  ending with a newline.
  """
  @spec render(Report.renderable() | [Report.renderable()], keyword()) :: iodata()
  def render(renderables, opts \\ []) do
    ctx = %{width: width(opts), color: color?(opts)}

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
    color = color?(opts)

    text
    |> glyphs([])
    |> chunk_styles()
    |> Enum.map(fn {styles, string} -> styled(string, styles, color) end)
  end

  defp width(opts) do
    with nil <- Keyword.get(opts, :width),
         nil <- env_columns() do
      case :io.columns() do
        {:ok, columns} -> columns
        _ -> 80
      end
    end
  end

  defp env_columns do
    case Integer.parse(System.get_env("COLUMNS", "")) do
      {columns, ""} when columns > 0 -> columns
      _ -> nil
    end
  end

  defp color?(opts) do
    case Keyword.fetch(opts, :color) do
      {:ok, color} -> color
      :error -> System.get_env("NO_COLOR", "") == "" and IO.ANSI.enabled?()
    end
  end

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

  defp draw_table(%Table{} = table, width, ctx) do
    rows = Enum.reject(table.rows, &match?({:confident_ai, _}, &1))
    columns = table.columns
    n = length(columns)
    boxed? = table.box != :none
    pad = table.padding
    edges = if boxed? and table.show_edge, do: 2, else: 0
    separators = if boxed?, do: n - 1, else: 0
    overhead = n * 2 * pad + separators + edges

    widths =
      columns
      |> Enum.with_index()
      |> Enum.map(fn {column, i} ->
        cells = Enum.map(rows, &Enum.at(&1, i))
        cells = if table.show_header, do: [column.header | cells], else: cells
        natural = cells |> Enum.map(&text_width/1) |> Enum.max(fn -> 0 end)

        natural
        |> min(Map.get(column, :max_width) || natural)
        |> then(&(Map.get(column, :width) || &1))
      end)
      |> fit(width - overhead, table.expand)

    header =
      if table.show_header do
        header_styles = if table.header_style, do: [table.header_style], else: []
        cells = Enum.map(columns, &{:style, Enum.join(header_styles, " "), &1.header})
        draw_row(cells, columns, widths, ctx, table, boxed?, "┃")
      else
        []
      end

    body = Enum.flat_map(rows, &draw_row(&1, columns, widths, ctx, table, boxed?, "│"))
    table_width = Enum.sum(widths) + overhead

    title(table, table_width, ctx) ++
      top(table, widths, pad, boxed?) ++
      header ++
      header_rule(table, widths, pad, boxed?) ++ body ++ bottom(table, widths, pad, boxed?)
  end

  # Shrinks the widest column until the table fits; an expanding table
  # gives its spare columns to its widest column.
  defp fit(widths, available, expand?) do
    available = max(available, length(widths))
    total = Enum.sum(widths)

    cond do
      total > available ->
        {widest, index} = widths |> Enum.with_index() |> Enum.max_by(&elem(&1, 0))

        widths
        |> List.replace_at(index, max(widest - (total - available), 1))
        |> fit(available, false)

      expand? and total < available and widths != [] ->
        {widest, index} = widths |> Enum.with_index() |> Enum.max_by(&elem(&1, 0))
        List.replace_at(widths, index, widest + available - total)

      true ->
        widths
    end
  end

  defp title(%Table{title: nil}, _width, _ctx), do: []

  defp title(%Table{title: title, title_justify: justify}, width, ctx) do
    title
    |> glyphs(["italic"])
    |> wrap(width)
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

  defp top(%Table{show_edge: true}, widths, pad, true),
    do: [rule(widths, pad, "┏", "━", "┳", "┓")]

  defp top(_table, _widths, _pad, _boxed?), do: []

  defp header_rule(%Table{show_header: true, show_edge: edge?}, widths, pad, true) do
    if edge?,
      do: [rule(widths, pad, "┡", "━", "╇", "┩")],
      else: [rule(widths, pad, "", "━", "╇", "")]
  end

  defp header_rule(_table, _widths, _pad, _boxed?), do: []

  defp bottom(%Table{show_edge: true}, widths, pad, true),
    do: [rule(widths, pad, "└", "─", "┴", "┘")]

  defp bottom(_table, _widths, _pad, _boxed?), do: []

  defp rule(widths, pad, left, fill, cross, right) do
    middle = Enum.map_join(widths, cross, &String.duplicate(fill, &1 + 2 * pad))
    line = left <> middle <> right
    {line, text_width(line)}
  end

  defp draw_row(cells, columns, widths, ctx, table, boxed?, bar) do
    pad = :binary.copy(" ", table.padding)

    wrapped =
      [cells, columns, widths]
      |> Enum.zip()
      |> Enum.map(fn {cell, column, width} ->
        styles = if column[:style], do: [column.style], else: []
        cell |> glyphs(styles) |> wrap(width) |> Enum.map(&draw_glyphs(&1, ctx))
      end)

    height = wrapped |> Enum.map(&length/1) |> Enum.max(fn -> 1 end)
    separator = if boxed?, do: bar, else: ""
    edge = if boxed? and table.show_edge, do: bar, else: ""

    for i <- 0..(height - 1) do
      cells =
        [wrapped, columns, widths]
        |> Enum.zip()
        |> Enum.map(fn {lines, column, width} ->
          line = Enum.at(lines, i, {"", 0})
          [pad, justify(line, width, Map.get(column, :justify, :left)), pad]
        end)

      {[edge, Enum.intersperse(cells, separator), edge], row_width(widths, table, boxed?)}
    end
  end

  defp row_width(widths, table, boxed?) do
    n = length(widths)
    separators = if boxed?, do: n - 1, else: 0
    edges = if boxed? and table.show_edge, do: 2, else: 0
    Enum.sum(widths) + n * 2 * table.padding + separators + edges
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

  defp text_width(%Table{}), do: 0

  defp text_width(text) do
    text
    |> Report.plain()
    |> String.split("\n")
    |> Enum.map(fn line ->
      line |> String.graphemes() |> Enum.map(&grapheme_width/1) |> Enum.sum()
    end)
    |> Enum.max()
  end

  # Wraps glyphs into lines of at most `width` columns, at spaces where it
  # can and inside words where it must; newlines always break.
  defp wrap(glyphs, width) do
    glyphs
    |> Enum.reduce([[]], fn
      {"\n", _, _}, lines -> [[] | lines]
      glyph, [current | rest] -> [[glyph | current] | rest]
    end)
    |> Enum.reverse()
    |> Enum.flat_map(&(&1 |> Enum.reverse() |> wrap_paragraph(max(width, 1))))
  end

  defp wrap_paragraph([], _width), do: [[]]

  defp wrap_paragraph(glyphs, width) do
    glyphs
    |> Enum.chunk_by(&(elem(&1, 0) == " "))
    |> Enum.reduce({[], [], 0}, fn word, {lines, line, used} ->
      word_width = glyphs_width(word)
      space? = match?([{" ", _, _} | _], word)

      cond do
        used + word_width <= width -> {lines, line ++ word, used + word_width}
        space? -> {[line | lines], [], 0}
        line == [] -> split_word(word, width, lines)
        true -> split_word(word, width, [trim_trailing_spaces(line) | lines])
      end
    end)
    |> then(fn {lines, line, _used} -> Enum.reverse([line | lines]) end)
    |> Enum.map(&trim_trailing_spaces/1)
  end

  defp split_word(word, width, lines) do
    Enum.reduce(word, {lines, [], 0}, fn {_, w, _} = glyph, {lines, line, used} ->
      if used + w > width and line != [],
        do: {[line | lines], [glyph], w},
        else: {lines, line ++ [glyph], used + w}
    end)
  end

  defp trim_trailing_spaces(glyphs) do
    glyphs |> Enum.reverse() |> Enum.drop_while(&(elem(&1, 0) == " ")) |> Enum.reverse()
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

  defp styled(string, styles, true) do
    case styles |> Enum.flat_map(&String.split/1) |> Enum.map_join(&ansi/1) do
      "" -> string
      codes -> [codes, string, IO.ANSI.reset()]
    end
  end

  @colors ~w(black red green yellow blue magenta cyan white)

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
