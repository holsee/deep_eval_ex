defmodule DeepEvalEx.TestRun.JSONTest do
  use ExUnit.Case, async: true

  alias DeepEvalEx.TestRun.JSON

  doctest JSON

  # Expected strings were produced by Python's `json.dumps` (see
  # test/fixtures/python_json/generate.py).
  @fixtures Path.expand("../../fixtures/python_json", __DIR__)
  @external_resource Path.join(@fixtures, "cases.json")
  @external_resource Path.join(@fixtures, "floats.json")

  @cases @fixtures |> Path.join("cases.json") |> File.read!() |> Jason.decode!()
  @floats @fixtures |> Path.join("floats.json") |> File.read!() |> Jason.decode!()

  describe "encode!/1 matches Python's json.dumps byte for byte" do
    for %{"name" => name, "input" => input, "expected" => expected} <- @cases do
      @input input
      @expected expected

      test name do
        value = Jason.decode!(@input, objects: :ordered_objects)
        assert JSON.encode!(value) == @expected
      end
    end
  end

  describe "float_repr/1" do
    test "matches Python's repr for every float in the corpus" do
      mismatches =
        for [bits, expected] <- @floats,
            <<float::float-64>> = <<bits::unsigned-64>>,
            (actual = JSON.float_repr(float)) != expected,
            do: {float, actual, expected}

      assert length(@floats) > 3_000
      assert mismatches == []
    end

    test "keeps a decimal point on integral floats" do
      assert JSON.float_repr(1.0) == "1.0"
      assert JSON.float_repr(0.0) == "0.0"
      assert JSON.float_repr(1.0e15) == "1000000000000000.0"
    end

    test "switches to exponent notation like Python" do
      assert JSON.float_repr(1.0e16) == "1e+16"
      assert JSON.float_repr(1.5e-5) == "1.5e-05"
      assert JSON.float_repr(1.0e-4) == "0.0001"
    end
  end

  describe "encode!/1 with Elixir terms" do
    test "encodes atoms as strings and nil/booleans as JSON literals" do
      assert JSON.encode!([nil, true, false, :function]) == ~s([null, true, false, "function"])
    end

    test "encodes map keys as strings" do
      assert JSON.encode!(%{a: 1}) == ~s({"a": 1})
      assert JSON.encode!(%{1 => "x"}) == ~s({"1": "x"})
    end

    test "keeps the key order of ordered objects" do
      object = Jason.OrderedObject.new(z: 1, a: [], m: %{})
      assert JSON.encode!(object) == ~s({"z": 1, "a": [], "m": {}})
    end

    test "encodes tuples as arrays and structs as objects" do
      assert JSON.encode!({1, "a"}) == ~s([1, "a"])
      assert JSON.encode!(URI.parse("https://x.io")) =~ ~s("host": "x.io")
    end

    test "escapes non-ASCII characters like ensure_ascii=True" do
      assert JSON.encode!("é ✓ 😀") == ~S("\u00e9 \u2713 \ud83d\ude00")
    end

    test "raises on invalid UTF-8" do
      assert_raise ArgumentError, fn -> JSON.encode!(<<0xFF>>) end
    end

    test "raises on terms with no JSON representation" do
      assert_raise ArgumentError, fn -> JSON.encode!(self()) end
    end
  end

  # Expected strings are Python's json.dumps(value, indent=4) and
  # json.dumps(value, indent=4, ensure_ascii=False) for the same value.
  describe "encode!/2 options" do
    setup do
      value =
        Jason.OrderedObject.new([
          {"name", "get_weather"},
          {"nested",
           Jason.OrderedObject.new([{"a", [1, %{"b" => "café"}]}, {"e", []}, {"f", %{}}])},
          {"x", 1.0}
        ])

      %{value: value}
    end

    test ":indent pretty-prints like json.dumps(indent=n)", %{value: value} do
      assert JSON.encode!(value, indent: 4) ==
               """
               {
                   "name": "get_weather",
                   "nested": {
                       "a": [
                           1,
                           {
                               "b": "caf\\u00e9"
                           }
                       ],
                       "e": [],
                       "f": {}
                   },
                   "x": 1.0
               }\
               """
    end

    test "ensure_ascii: false keeps non-ASCII but escapes control characters", %{value: value} do
      assert JSON.encode!(value, indent: 4, ensure_ascii: false) =~ ~s("b": "café")
      assert JSON.encode!(["a\x01", "\x7F"], ensure_ascii: false) == ~s(["a\\u0001", "\x7F"])
    end
  end
end
