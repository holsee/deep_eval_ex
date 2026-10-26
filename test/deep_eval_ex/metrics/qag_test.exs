# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0

defmodule DeepEvalEx.Metrics.QAGTest do
  use ExUnit.Case, async: true

  alias DeepEvalEx.Metrics.QAG

  doctest QAG

  describe "vocabularies" do
    test "match deepeval's YES_NO and YES_NO_BORDERLINE" do
      assert QAG.yes_no() == [:yes, :no]
      assert QAG.yes_no_borderline() == [:yes, :no, :borderline]
    end
  end

  describe "normalize_qag_verdict/2" do
    test "maps exact replies to verdicts" do
      assert QAG.normalize_qag_verdict("yes") == :yes
      assert QAG.normalize_qag_verdict("no") == :no
      assert QAG.normalize_qag_verdict("borderline", QAG.yes_no_borderline()) == :borderline
    end

    test "defaults to the yes/no vocabulary" do
      assert QAG.normalize_qag_verdict("borderline") == nil
    end

    test "strips, lower-cases and keeps only the leading word" do
      assert QAG.normalize_qag_verdict("  YES ") == :yes
      assert QAG.normalize_qag_verdict("No, it's off-topic") == :no
      assert QAG.normalize_qag_verdict("Borderline.", QAG.yes_no_borderline()) == :borderline
    end

    test "maps the legacy idk alias to borderline" do
      assert QAG.normalize_qag_verdict("idk", QAG.yes_no_borderline()) == :borderline

      assert QAG.normalize_qag_verdict("IDK - not mentioned", QAG.yes_no_borderline()) ==
               :borderline
    end

    test "drops the legacy alias when borderline is not allowed" do
      assert QAG.normalize_qag_verdict("idk") == nil
    end

    test "returns nil for replies outside the vocabulary" do
      for raw <- ["maybe", "", "   ", "42", "yesno", "- yes", nil, 1, true, %{}, ["yes"]] do
        assert QAG.normalize_qag_verdict(raw, QAG.yes_no_borderline()) == nil,
               "expected #{inspect(raw)} to be dropped"
      end
    end

    test "keeps verdict atoms within the vocabulary" do
      assert QAG.normalize_qag_verdict(:yes) == :yes
      assert QAG.normalize_qag_verdict(:borderline, QAG.yes_no_borderline()) == :borderline
      assert QAG.normalize_qag_verdict(:borderline) == nil
      assert QAG.normalize_qag_verdict(:no, [:yes]) == nil
    end
  end

  describe "parse_verdicts/2" do
    test "normalises each verdict and keeps its reason" do
      response = %{
        "verdicts" => [
          %{"verdict" => "Yes"},
          %{"verdict" => "idk", "reason" => "Not mentioned."}
        ]
      }

      assert QAG.parse_verdicts(response, QAG.yes_no_borderline()) ==
               {:ok,
                [
                  %{verdict: :yes, reason: nil},
                  %{verdict: :borderline, reason: "Not mentioned."}
                ]}
    end

    test "drops verdicts outside the vocabulary" do
      response = %{
        "verdicts" => [
          %{"verdict" => "no", "reason" => "Contradicts."},
          %{"verdict" => "unsure", "reason" => "?"},
          %{"verdict" => "borderline", "reason" => "Not mentioned."},
          %{"reason" => "No verdict at all."},
          "yes"
        ]
      }

      assert QAG.parse_verdicts(response, QAG.yes_no()) ==
               {:ok, [%{verdict: :no, reason: "Contradicts."}]}
    end

    test "rejects a response without a verdicts list" do
      assert QAG.parse_verdicts(%{"other" => []}, QAG.yes_no()) ==
               {:error, {:invalid_verdicts_response, %{"other" => []}}}
    end
  end

  describe "score_qag_verdicts/2" do
    defp verdicts(atoms), do: Enum.map(atoms, &%{verdict: &1, reason: nil})

    test "scores the fraction of verdicts in the passing set as a float" do
      assert QAG.score_qag_verdicts(verdicts([:yes, :no, :yes, :no]), passing: [:yes]) === 0.5
      assert QAG.score_qag_verdicts(verdicts([:yes, :yes]), passing: [:yes]) === 1.0
      assert QAG.score_qag_verdicts(verdicts([:no]), passing: [:yes]) === 0.0
    end

    test "sets the polarity with the passing set" do
      mixed = verdicts([:yes, :no, :borderline, :borderline])

      assert QAG.score_qag_verdicts(mixed, passing: [:yes]) === 0.25
      assert QAG.score_qag_verdicts(mixed, passing: [:no]) === 0.25
      assert QAG.score_qag_verdicts(mixed, passing: [:yes, :borderline]) === 0.75
    end

    test "normalises raw string verdicts before counting" do
      raw = [%{verdict: "Yes."}, %{verdict: "idk"}, %{verdict: "no"}]

      assert QAG.score_qag_verdicts(raw, passing: [:yes, :borderline]) == 2 / 3
    end

    test "ignores nil entries" do
      assert QAG.score_qag_verdicts([nil, %{verdict: :yes}, nil, %{verdict: :no}],
               passing: [:yes]
             ) === 0.5
    end

    test "scores an empty list as the integer 1, as deepeval's int default" do
      assert QAG.score_qag_verdicts([], passing: [:yes]) === 1
      assert QAG.score_qag_verdicts([nil], passing: [:yes]) === 1
    end

    test "takes the empty score from :empty_score" do
      assert QAG.score_qag_verdicts([], passing: [:yes], empty_score: 0) === 0
    end

    test "clamps a score below the threshold to the integer 0 in strict mode" do
      verdicts = verdicts([:yes, :no])

      assert QAG.score_qag_verdicts(verdicts, passing: [:yes], strict_mode: true, threshold: 1) ===
               0

      assert QAG.score_qag_verdicts(verdicts, passing: [:yes], strict_mode: true, threshold: 0.5) ===
               0.5

      assert QAG.score_qag_verdicts(verdicts, passing: [:yes], strict_mode: false, threshold: 1) ===
               0.5
    end

    test "does not clamp the empty score in strict mode" do
      assert QAG.score_qag_verdicts([], passing: [:yes], strict_mode: true, threshold: 1) === 1

      assert QAG.score_qag_verdicts([],
               passing: [:yes],
               empty_score: 0,
               strict_mode: true,
               threshold: 1
             ) === 0
    end

    test "requires a threshold in strict mode" do
      assert_raise KeyError, fn ->
        QAG.score_qag_verdicts(verdicts([:yes]), passing: [:yes], strict_mode: true)
      end
    end
  end
end
