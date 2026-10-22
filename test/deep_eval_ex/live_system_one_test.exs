defmodule DeepEvalEx.LiveSystemOneTest do
  @moduledoc """
  End-to-end checks against TypeSafe's System One model, Jev.

  Excluded by default. Set `TYPESAFE_API_KEY` (and optionally
  `TYPESAFE_MODEL_NAME`) in `.devcontainer/.env`, recreate the container,
  then run:

      mix test --only live_system_one

  Without `TYPESAFE_API_KEY` the tests are skipped. `TYPESAFE_MODEL_NAME`
  defaults to `"jev-latest"`, as in deepeval's `TypeSafeModel`.

  This is a scaffold: there is no TypeSafe client yet, so the only check is
  that the credentials reach the test. Unit P4-9 replaces the placeholder
  with real `decide()` calls compared against the System One fixtures.
  """

  use ExUnit.Case, async: false

  alias DeepEvalEx.LLM.Adapter

  @moduletag :live_system_one
  @moduletag timeout: 300_000

  @configured Adapter.env("TYPESAFE_API_KEY") != nil
  @model Adapter.env("TYPESAFE_MODEL_NAME") || "jev-latest"

  describe "TypeSafe Jev (#{@model})" do
    @describetag skip: if(@configured, do: false, else: "TYPESAFE_API_KEY not set")

    # Placeholder until P4-9 adds the TypeSafe client and calls Jev.
    test "has TypeSafe credentials" do
      assert is_binary(Adapter.env("TYPESAFE_API_KEY"))
      assert is_binary(@model) and @model != ""
    end
  end
end
