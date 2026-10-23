# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/evaluate/console_report.py and the output of
# deepeval/test_run/test_run.py (display_results_table, wrap_up_test_run)
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.Report do
  @moduledoc """
  deepeval 4.3.1's console output as data: the evaluation report
  `evaluate()` prints, the `Test Results` table and the wrap-up summary.

  deepeval draws these with Rich. DeepEvalEx keeps what deepeval hands to
  Rich as data instead (ADR-0010 §9): panels (`DeepEvalEx.Report.Panel`),
  trees (`DeepEvalEx.Report.Tree`), tables (`DeepEvalEx.Report.Table`) and
  `t:text/0`, whose cells hold exactly deepeval's strings with their Rich
  markup kept as `{:style, style, text}` tuples. `markup/1` gives back the
  string deepeval passes to Rich and `plain/1` the text Rich prints.

  - `DeepEvalEx.Report.Console` builds the evaluation report
    (`EvaluationConsoleReport`)
  - `DeepEvalEx.Report.ResultsTable` builds the `Test Results` table
    (`display_results_table`)
  - `DeepEvalEx.Report.Summary` builds the wrap-up's warnings and summary
  - `DeepEvalEx.Report.Markdown` writes the report as Markdown
    (`export_to_markdown`)
  - `DeepEvalEx.Report.Terminal` draws any of them with box-drawing
    characters and ANSI colours

  The strings match deepeval's byte for byte. Tables are drawn with Rich's
  column widths and wrapping; panels and trees only resemble Rich's.
  """

  alias DeepEvalEx.TestRun.JSON

  @typedoc ~s|A Rich style, such as `"bold red"` or `"rgb(106,0,255) bold"`.|
  @type style :: String.t()

  @typedoc """
  Text with Rich markup as data: a string, a styled `{:style, style, text}`
  or a list of texts, concatenated.
  """
  @type text :: String.t() | {:style, style(), text()} | [text()]

  @typedoc "Anything `DeepEvalEx.Report.Terminal.render/2` draws."
  @type renderable ::
          DeepEvalEx.Report.Panel.t()
          | DeepEvalEx.Report.Tree.t()
          | DeepEvalEx.Report.Table.t()
          | text()

  defmodule Table do
    @moduledoc """
    A table as deepeval builds it with Rich's `Table`: its title, columns
    and rows of `t:DeepEvalEx.Report.text/0` cells.

    A row is a list of cells, or `{:confident_ai, cells}` for a row that
    only advertises Confident AI: kept so the rows match deepeval's, never
    drawn by `DeepEvalEx.Report.Terminal` (ADR-0010 decision 6).

    `:box` is `:heavy_head` (Rich's default) or `:none`; `:show_edge`,
    `:show_header`, `:expand`, `:title_justify`, `:header_style` and
    `:padding` (spaces either side of a cell) are Rich's options, as are a
    column's `:width`, `:max_width`, `:no_wrap` and `:overflow` (what a
    word wider than its column does: `:ellipsis`, Rich's default, cuts it
    with `…`, `:fold` breaks it across lines, `:crop` cuts it).
    """

    @typedoc "A column: its header and Rich's column options."
    @type column :: %{
            required(:header) => String.t(),
            optional(:justify) => :left | :center | :right,
            optional(:style) => DeepEvalEx.Report.style() | nil,
            optional(:width) => pos_integer() | nil,
            optional(:max_width) => pos_integer() | nil,
            optional(:no_wrap) => boolean(),
            optional(:overflow) => :fold | :crop | :ellipsis
          }

    @type row :: [DeepEvalEx.Report.text()] | {:confident_ai, [DeepEvalEx.Report.text()]}

    @type t :: %__MODULE__{
            title: DeepEvalEx.Report.text() | nil,
            columns: [column()],
            rows: [row()],
            show_header: boolean(),
            show_edge: boolean(),
            box: :heavy_head | :none,
            expand: boolean(),
            title_justify: :left | :center,
            header_style: DeepEvalEx.Report.style() | nil,
            padding: non_neg_integer()
          }

    defstruct title: nil,
              columns: [],
              rows: [],
              show_header: true,
              show_edge: true,
              box: :heavy_head,
              expand: false,
              title_justify: :center,
              header_style: nil,
              padding: 1
  end

  defmodule Panel do
    @moduledoc """
    A bordered box around one renderable, as Rich's `Panel(expand=True)`:
    `:border_style` (`nil` is Rich's `"none"`) and `:padding`, the
    `{vertical, horizontal}` blank space inside the border.
    """

    @type t :: %__MODULE__{
            content: DeepEvalEx.Report.renderable(),
            border_style: DeepEvalEx.Report.style() | nil,
            padding: {non_neg_integer(), non_neg_integer()}
          }

    defstruct content: "", border_style: nil, padding: {0, 1}
  end

  defmodule Tree do
    @moduledoc """
    A tree as Rich's `Tree`: a label (text or a table) and child trees, as
    `Tree.add/1` makes them.
    """

    @type t :: %__MODULE__{
            label: DeepEvalEx.Report.text() | DeepEvalEx.Report.Table.t(),
            children: [t()]
          }

    defstruct label: "", children: []
  end

  @doc """
  The Rich markup string deepeval writes for `text`.

  ## Examples

      iex> DeepEvalEx.Report.markup([{:style, "bold red", "FAIL"}, " now"])
      "[bold red]FAIL[/bold red] now"
  """
  @spec markup(text()) :: String.t()
  def markup(text), do: text |> do_markup() |> IO.iodata_to_binary()

  defp do_markup(text) when is_binary(text), do: text
  defp do_markup({:style, style, text}), do: ["[", style, "]", do_markup(text), "[/", style, "]"]
  defp do_markup(texts) when is_list(texts), do: Enum.map(texts, &do_markup/1)

  @doc """
  The text Rich prints for `text`, without its styles.

  ## Examples

      iex> DeepEvalEx.Report.plain([{:style, "bold red", "FAIL"}, " now"])
      "FAIL now"
  """
  @spec plain(text()) :: String.t()
  def plain(text), do: text |> do_plain() |> IO.iodata_to_binary()

  defp do_plain(text) when is_binary(text), do: text
  defp do_plain({:style, _style, text}), do: do_plain(text)
  defp do_plain(texts) when is_list(texts), do: Enum.map(texts, &do_plain/1)

  @doc false
  # Python's str() of a report value: None is "None".
  @spec py_str(term()) :: String.t()
  def py_str(nil), do: "None"
  def py_str(value) when is_binary(value), do: value
  def py_str(true), do: "True"
  def py_str(false), do: "False"
  def py_str(value) when is_integer(value), do: Integer.to_string(value)
  def py_str(value) when is_float(value), do: JSON.float_repr(value)
  def py_str(value) when is_atom(value), do: Atom.to_string(value)

  @doc false
  # Python's len() of a string: its code points.
  @spec py_len(String.t()) :: non_neg_integer()
  def py_len(string), do: string |> String.to_charlist() |> length()

  @doc false
  # Python's string[:n]: the first n code points.
  @spec py_take(String.t(), non_neg_integer()) :: String.t()
  def py_take(string, n), do: string |> String.to_charlist() |> Enum.take(n) |> List.to_string()

  @doc false
  # Python's truthiness of an optional string: nil and "" are falsy.
  @spec presence(String.t() | nil) :: String.t() | nil
  def presence(""), do: nil
  def presence(value), do: value

  @doc false
  # A float as Python's repr() of float(value).
  @spec float_str(number()) :: String.t()
  def float_str(value), do: JSON.float_repr(value / 1)
end
