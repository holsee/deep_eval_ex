defmodule DeepEvalEx.Report.TerminalTest do
  use ExUnit.Case, async: true

  alias DeepEvalEx.Report.{Console, Panel, Table, Terminal, Tree}

  defp lines(iodata), do: iodata |> IO.iodata_to_binary() |> String.split("\n", trim: true)

  describe "render/2 (snapshots, without colour)" do
    test "draws a panel around a tree of tables, wrapping the widest column" do
      metrics = %Table{
        title: "Metrics",
        title_justify: :left,
        show_edge: false,
        expand: true,
        columns: [%{header: "Status", justify: :center}, %{header: "Metric"}, %{header: "Reason"}],
        rows: [
          [
            {:style, "bold green", "PASS"},
            "Faithfulness",
            "No contradictions in the answer at all."
          ],
          {:confident_ai, ["never", "drawn", "row"]}
        ]
      }

      data = %Table{
        columns: [%{header: "Key"}, %{header: "Value"}],
        show_header: false,
        box: :none,
        padding: 2,
        rows: [["Input:", "Hi"]]
      }

      panel = %Panel{
        border_style: "red",
        padding: {1, 2},
        content: %Tree{
          label: {:style, "red bold", "❌ case 测试"},
          children: [%Tree{label: data}, %Tree{label: metrics}]
        }
      }

      assert lines(Terminal.render(panel, width: 50, color: false)) ==
               [
                 "╭────────────────────────────────────────────────╮",
                 "│                                                │",
                 "│  ❌ case 测试                                  │",
                 "│  ├──   Input:    Hi                            │",
                 "│  └── Metrics                                   │",
                 "│       Status ┃ Metric       ┃ Reason           │",
                 "│      ━━━━━━━━╇━━━━━━━━━━━━━━╇━━━━━━━━━━━━━━━━  │",
                 "│        PASS  │ Faithfulness │ No               │",
                 "│              │              │ contradictions   │",
                 "│              │              │ in the answer    │",
                 "│              │              │ at all.          │",
                 "│                                                │",
                 "╰────────────────────────────────────────────────╯"
               ]
    end

    test "draws a table with its title, leaving out Confident AI's rows" do
      table = %Table{
        title: "Test Results",
        columns: [%{header: "Test case"}, %{header: "Score"}],
        rows: [["a", "1.0"], {:confident_ai, ["Note", ""]}]
      }

      assert lines(Terminal.render(table, width: 50, color: false)) ==
               [
                 "    Test Results     ",
                 "┏━━━━━━━━━━━┳━━━━━━━┓",
                 "┃ Test case ┃ Score ┃",
                 "┡━━━━━━━━━━━╇━━━━━━━┩",
                 "│ a         │ 1.0   │",
                 "└───────────┴───────┘"
               ]
    end

    # Regression: with the console at 80 columns (no terminal, COLUMNS
    # unset), the widest column used to absorb the whole overflow and
    # collapse to one column, printing "Score" a character per line. Rich
    # narrows the widest columns together (Table._collapse_widths); the
    # expected lines are Rich's (test/fixtures/deepeval/report/exact_match).
    test "narrows the widest columns together, as Rich does, when the table does not fit" do
      score = fn score, verdict ->
        "#{score} (threshold=1.0, evaluation model=n/a, reason=The actual and expected " <>
          "outputs are #{verdict}., error=None)"
      end

      table = %Table{
        title: "Test Results",
        columns:
          Enum.map(
            ["Test case", "Metric", "Score", "Status", "Overall Success Rate"],
            &%{header: &1}
          ),
        rows: [
          ["test exact match passes", "", "", "", "100.0% | passed=1 | failed=0"],
          ["", "Exact Match", score.("1.0", "exact matches"), {:style, "green", "PASSED"}, ""]
        ]
      }

      assert lines(Terminal.render(table, width: 80, color: false)) ==
               [
                 "                                  Test Results                                  ",
                 "┏━━━━━━━━━━━━━━━━━━┳━━━━━━━━━━━━━┳━━━━━━━━━━━━━━━━━┳━━━━━━━━┳━━━━━━━━━━━━━━━━━━┓",
                 "┃                  ┃             ┃                 ┃        ┃ Overall Success  ┃",
                 "┃ Test case        ┃ Metric      ┃ Score           ┃ Status ┃ Rate             ┃",
                 "┡━━━━━━━━━━━━━━━━━━╇━━━━━━━━━━━━━╇━━━━━━━━━━━━━━━━━╇━━━━━━━━╇━━━━━━━━━━━━━━━━━━┩",
                 "│ test exact match │             │                 │        │ 100.0% |         │",
                 "│ passes           │             │                 │        │ passed=1 |       │",
                 "│                  │             │                 │        │ failed=0         │",
                 "│                  │ Exact Match │ 1.0             │ PASSED │                  │",
                 "│                  │             │ (threshold=1.0, │        │                  │",
                 "│                  │             │ evaluation      │        │                  │",
                 "│                  │             │ model=n/a,      │        │                  │",
                 "│                  │             │ reason=The      │        │                  │",
                 "│                  │             │ actual and      │        │                  │",
                 "│                  │             │ expected        │        │                  │",
                 "│                  │             │ outputs are     │        │                  │",
                 "│                  │             │ exact matches., │        │                  │",
                 "│                  │             │ error=None)     │        │                  │",
                 "└──────────────────┴─────────────┴─────────────────┴────────┴──────────────────┘"
               ]
    end

    test "cuts a word wider than its column with an ellipsis, or folds it under :fold" do
      table = %Table{
        columns: [%{header: "A"}, %{header: "B", overflow: :fold}],
        rows: [["abcdefghij", "abcdefghij"]]
      }

      assert lines(Terminal.render(table, width: 13, color: false)) ==
               [
                 "┏━━━━━┳━━━━━┓",
                 "┃ A   ┃ B   ┃",
                 "┡━━━━━╇━━━━━┩",
                 "│ ab… │ abc │",
                 "│     │ def │",
                 "│     │ ghi │",
                 "│     │ j   │",
                 "└─────┴─────┘"
               ]
    end

    test "draws every line within the width" do
      test_result = %DeepEvalEx.TestResult{
        name: "a very long test case name " <> String.duplicate("x", 80),
        success: false,
        index: 0,
        input: String.duplicate("word ", 40),
        actual_output: "out",
        metrics_data: [
          DeepEvalEx.Result.new(
            metric: "M",
            score: 0.1,
            threshold: 0.5,
            reason: String.duplicate("why ", 30)
          )
        ]
      }

      for line <- lines(Terminal.render(Console.build([test_result]), width: 60, color: false)) do
        width = line |> String.graphemes() |> Enum.map(&Terminal.grapheme_width/1) |> Enum.sum()
        assert width <= 60, "too wide: #{inspect(line)}"
      end
    end
  end

  describe "render_text/2" do
    test "styles text with ANSI escapes when colour is on" do
      text = [{:style, "bold red", "FAIL"}, " x ", {:style, "rgb(1,2,3)", "y"}]

      assert IO.iodata_to_binary(Terminal.render_text(text, color: true)) ==
               "\e[1m\e[31mFAIL\e[0m x \e[38;2;1;2;3my\e[0m"

      assert IO.iodata_to_binary(Terminal.render_text(text, color: false)) == "FAIL x y"
    end
  end

  describe "grapheme_width/1" do
    test "counts emoji and East Asian wide characters as two columns" do
      assert Enum.map(~w(a é ✅ ❌ ➖ 🚀 测 ⚠ ✓ ❤️), &Terminal.grapheme_width/1) ==
               [1, 1, 2, 2, 2, 2, 2, 1, 1, 2]
    end
  end
end
