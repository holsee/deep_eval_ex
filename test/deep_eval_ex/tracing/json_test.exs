defmodule DeepEvalEx.Tracing.JSONTest do
  # Not async: the mask tests change the :tracing application config.
  use ExUnit.Case, async: false

  alias DeepEvalEx.Schemas.ToolCall
  alias DeepEvalEx.Tracing.JSON

  doctest DeepEvalEx.Tracing.JSON

  defmodule Plain do
    defstruct [:name, :_secret, :items]
  end

  describe "make_serializable/1, deepeval's make_json_serializable" do
    test "keeps JSON scalars and strips NUL from strings" do
      assert JSON.make_serializable("a\0b") == "ab"
      assert JSON.make_serializable(3) == 3
      assert JSON.make_serializable(1.5) == 1.5
      assert JSON.make_serializable(true) == true
      assert JSON.make_serializable(false) == false
      assert JSON.make_serializable(nil) == nil
    end

    test "turns atoms into strings, as an enum into its value" do
      assert JSON.make_serializable(:success) == "success"
      assert JSON.make_serializable(%{status: :ok}) == %{"status" => "ok"}
    end

    test "turns tuples and sets into lists" do
      assert JSON.make_serializable({:ok, 1, "x"}) == ["ok", 1, "x"]
      assert JSON.make_serializable(a: 1) == [["a", 1]]
      assert JSON.make_serializable(MapSet.new([1])) == [1]
    end

    test "stringifies map keys as Python's str()" do
      assert JSON.make_serializable(%{:a => 1, "b" => 2, 3 => 3, 1.5 => 4, true => 5, nil => 6}) ==
               %{"a" => 1, "b" => 2, "3" => 3, "1.5" => 4, "True" => 5, "None" => 6}

      assert JSON.make_serializable(%{{1, 2} => :x}) == %{"{1, 2}" => "x"}
    end

    test "keeps a Jason.OrderedObject's order, serialising its values" do
      object = Jason.OrderedObject.new([{"z", :a}, {"a", {1, 2}}])

      assert %Jason.OrderedObject{values: [{"z", "a"}, {"a", [1, 2]}]} =
               JSON.make_serializable(object)
    end

    test "dumps a struct through DeepEvalEx.SystemOne.Dumpable when it implements it" do
      tool_call = %ToolCall{name: "search", input_parameters: %{q: :x}}

      assert %Jason.OrderedObject{
               values: [
                 {"name", "search"},
                 {"type", "FUNCTION"},
                 {"input_parameters", %{"q" => "x"}}
               ]
             } = JSON.make_serializable(tool_call)
    end

    test "sends a struct with String.Chars as text, as Python's str() fallback" do
      assert JSON.make_serializable(~D[2026-10-23]) == "2026-10-23"
    end

    test "takes any other struct's public fields, as vars()" do
      assert JSON.make_serializable(%Plain{name: "n", _secret: "s", items: {1}}) ==
               %{"name" => "n", "items" => [1]}

      assert JSON.make_serializable(%RuntimeError{message: "boom"}) == %{"message" => "boom"}
    end

    test "inspects pids, references, functions and non-UTF-8 binaries" do
      pid = self()
      ref = make_ref()
      fun = &String.upcase/1

      assert JSON.make_serializable(pid) == inspect(pid)
      assert JSON.make_serializable(ref) == inspect(ref)
      assert JSON.make_serializable(fun) == inspect(fun)
      assert JSON.make_serializable(<<255, 0>>) == inspect(<<255, 0>>)
    end

    test "output encodes with Jason" do
      term = %{a: [{:ok, self()}, MapSet.new([:x])], b: Jason.OrderedObject.new([{"k", nil}])}
      assert {:ok, _json} = term |> JSON.make_serializable() |> Jason.encode()
    end
  end

  describe "mask/1, trace_manager.mask" do
    setup do
      previous = Application.fetch_env(:deep_eval_ex, :tracing)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:deep_eval_ex, :tracing, value)
          :error -> Application.delete_env(:deep_eval_ex, :tracing)
        end
      end)
    end

    test "returns the data unchanged without a configured mask" do
      Application.delete_env(:deep_eval_ex, :tracing)
      assert JSON.mask(%{"password" => "hunter2"}) == %{"password" => "hunter2"}
    end

    test "applies a configured {module, function} or one-arity function" do
      Application.put_env(:deep_eval_ex, :tracing, mask: {__MODULE__, :redact})
      assert JSON.mask(%{"password" => "hunter2"}) == %{"password" => "***"}

      Application.put_env(:deep_eval_ex, :tracing, mask: fn _data -> "masked" end)
      assert JSON.mask(%{"password" => "hunter2"}) == "masked"
    end
  end

  def redact(%{"password" => _} = data), do: %{data | "password" => "***"}
end
