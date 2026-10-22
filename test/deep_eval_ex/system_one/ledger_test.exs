defmodule DeepEvalEx.SystemOne.LedgerTest do
  use ExUnit.Case, async: true

  alias DeepEvalEx.LLM.Usage
  alias DeepEvalEx.SystemOne.{Answers, Ledger}

  doctest Ledger

  describe "track/1" do
    test "starts empty and returns what was recorded" do
      {result, ledger} =
        Ledger.track(fn ->
          assert Ledger.current() == %Ledger{}
          Ledger.note_fallback("ConnectionError: Jev is down")
          Ledger.disable()
          :done
        end)

      assert result == :done

      assert ledger == %Ledger{
               fallback_reasons: ["ConnectionError: Jev is down"],
               disabled?: true
             }
    end

    test "sets an enclosing ledger aside and restores it unchanged" do
      {_, outer} =
        Ledger.track(fn ->
          Ledger.record_confidence(0.9)

          {_, inner} =
            Ledger.track(fn ->
              refute Ledger.confidence()
              Ledger.record_confidence(0.1)
            end)

          assert inner.confidence == 0.1
          assert Ledger.confidence() == 0.9
        end)

      assert outer.confidence == 0.9
      assert Ledger.current() == nil
    end

    test "restores the enclosing ledger when fun raises" do
      Ledger.track(fn ->
        Ledger.note_fallback("outer")

        assert_raise RuntimeError, fn ->
          Ledger.track(fn ->
            Ledger.note_fallback("inner")
            raise "boom"
          end)
        end

        assert Ledger.fallback_reason() == "outer"
      end)
    end
  end

  describe "without an open ledger" do
    test "every call is a no-op" do
      assert Ledger.record_confidence(0.5) == 0.5
      assert Ledger.put_confidence(0.5) == :ok
      assert Ledger.note_fallback("x") == :ok
      assert Ledger.disable() == :ok
      assert Ledger.confidence() == nil
      assert Ledger.fallback_reason() == nil
      refute Ledger.disabled?()
      assert Ledger.current() == nil
    end
  end

  describe "record_confidence/1" do
    test "keeps the minimum across requests and returns the request's own" do
      {_, ledger} =
        Ledger.track(fn ->
          assert Ledger.record_confidence(0.6) == 0.6
          assert Ledger.record_confidence(0.9) == 0.9
          assert Ledger.record_confidence(nil) == nil
        end)

      assert ledger.confidence == 0.6
    end

    test "takes the least decisive answer of an Answers or a per-type map" do
      answers = %Answers{
        nouls: %{"q_0" => %Answers.Noul{probability: 0.6}},
        choices: %{"q_1" => %Answers.Choice{choice: "a", probabilities: [], confidence: 0.9}}
      }

      {_, ledger} =
        Ledger.track(fn ->
          # abs(2 * 0.6 - 1) in Python
          assert Ledger.record_confidence(answers) == 0.19999999999999996
          assert Ledger.record_confidence(answers.choices) == 0.9
          assert Ledger.record_confidence(%{}) == nil
          assert Ledger.record_confidence(%Answers{}) == nil
        end)

      assert ledger.confidence == 0.19999999999999996
    end

    test "keeps the current value on a tie, as Python's min" do
      {_, ledger} =
        Ledger.track(fn ->
          Ledger.record_confidence(0.0)
          Ledger.record_confidence(0)
        end)

      assert ledger.confidence === 0.0
    end
  end

  test "put_confidence/1 replaces the running minimum" do
    {_, ledger} =
      Ledger.track(fn ->
        Ledger.record_confidence(0.1)
        Ledger.put_confidence(0.7)
      end)

    assert ledger.confidence == 0.7
  end

  test "fallback reasons join with \"; \" in the order they were noted" do
    Ledger.track(fn ->
      assert Ledger.fallback_reason() == nil
      Ledger.note_fallback("ConnectionError: Jev is down")
      Ledger.note_fallback("context limit (rejected by Jev)")

      assert Ledger.fallback_reason() ==
               "ConnectionError: Jev is down; context limit (rejected by Jev)"
    end)
  end

  describe "across Usage.async/1 and Usage.await/2" do
    test "a task sees the caller's ledger and folds its records back" do
      {_, ledger} =
        Ledger.track(fn ->
          Ledger.record_confidence(0.5)
          Ledger.note_fallback("first")
          Ledger.disable()

          task =
            Usage.async(fn ->
              assert Ledger.disabled?()
              assert Ledger.confidence() == 0.5
              Ledger.record_confidence(0.2)
              Ledger.note_fallback("from task")
              :ok
            end)

          Ledger.note_fallback("second")
          assert Usage.await(task) == :ok
        end)

      assert ledger.confidence == 0.2
      assert ledger.disabled?
      assert ledger.fallback_reasons == ["first", "second", "from task"]
    end

    test "concurrent tasks each add their own records" do
      {_, ledger} =
        Ledger.track(fn ->
          tasks =
            for confidence <- [0.9, 0.3] do
              Usage.async(fn ->
                Ledger.record_confidence(confidence)
                Ledger.note_fallback("task #{confidence}")
              end)
            end

          Enum.each(tasks, &Usage.await/1)
        end)

      assert ledger.confidence == 0.3
      assert ledger.fallback_reasons == ["task 0.9", "task 0.3"]
      refute ledger.disabled?
    end

    test "a task disabling System One disables the caller" do
      {_, ledger} =
        Ledger.track(fn ->
          [fn -> Ledger.disable() end] |> Enum.map(&Usage.async/1) |> Enum.each(&Usage.await/1)
        end)

      assert ledger.disabled?
    end

    test "a task started without a ledger opens none" do
      task = Usage.async(fn -> Ledger.current() end)
      assert Usage.await(task) == nil
      assert Ledger.current() == nil
    end
  end
end
