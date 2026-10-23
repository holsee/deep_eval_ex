defmodule DeepEvalEx.Dataset.ConversationalGoldenTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias DeepEvalEx.ConversationalTestCase
  alias DeepEvalEx.Dataset.{ConversationalGolden, Persona}
  alias DeepEvalEx.Schemas.RetrievedContextData
  alias DeepEvalEx.Turn

  doctest DeepEvalEx.Dataset.ConversationalGolden

  @persona %Persona{name: "Ann", characteristics: "A busy parent"}

  describe "new/1" do
    test "builds a golden from deepeval's field names, as atoms or strings" do
      attrs = %{
        "scenario" => "A customer asks for a refund",
        "expected_outcome" => "The refund is issued",
        "persona" => %{"name" => "Ann", "characteristics" => "A busy parent", "voice" => "x"},
        "context" => ["Refunds within 30 days"],
        "additional_metadata" => %{"channel" => "chat"},
        "comments" => "Hand-written",
        "name" => "refund",
        "custom_column_key_values" => %{"team" => "billing"},
        "expectations" => %{"must" => [" Apologise "]},
        expected_labels: %{"tone" => "polite"},
        turns: [
          %{"role" => "user", "content" => "Refund please", "retrieval_context" => ["policy"]},
          Turn.new!(role: :assistant, content: "Done")
        ]
      }

      assert {:ok, golden} = ConversationalGolden.new(attrs)

      assert %ConversationalGolden{
               scenario: "A customer asks for a refund",
               expected_outcome: "The refund is issued",
               persona: @persona,
               user_description: "A busy parent",
               context: ["Refunds within 30 days"],
               additional_metadata: %{"channel" => "chat"},
               comments: "Hand-written",
               name: "refund",
               custom_column_key_values: %{"team" => "billing"},
               expectations: %{must: ["Apologise"], must_not: []},
               expected_labels: %{"tone" => "polite"},
               turns: [
                 %Turn{role: :user, content: "Refund please", retrieval_context: ["policy"]},
                 %Turn{role: :assistant, content: "Done"}
               ]
             } = golden
    end

    test "requires a scenario" do
      assert {:error, _} = ConversationalGolden.new(expected_outcome: "x")
      assert {:error, _} = ConversationalGolden.new(scenario: 1)
    end

    test "takes expectedLabels as deepeval's only validation alias, ignoring the other camelCase names" do
      {:ok, golden} =
        ConversationalGolden.new(%{
          "scenario" => "s",
          "expectedLabels" => %{"a" => "b"},
          "expected_labels" => %{"a" => "c"},
          "expectedOutcome" => "o",
          "userDescription" => "u",
          "additionalMetadata" => %{"a" => 1}
        })

      assert golden.expected_labels == %{"a" => "b"}
      assert golden.expected_outcome == nil
      assert golden.user_description == nil
      assert golden.additional_metadata == nil
    end

    test "rejects invalid turns" do
      assert {:error, _} = ConversationalGolden.new(scenario: "s", turns: [%{"role" => "bot"}])
      assert {:error, _} = ConversationalGolden.new(scenario: "s", turns: ["hi"])
    end

    test "keeps empty or missing turns, as deepeval's Optional[List[Turn]]" do
      assert ConversationalGolden.new!(scenario: "s").turns == nil
      assert ConversationalGolden.new!(scenario: "s", turns: []).turns == []
    end
  end

  describe "persona and the deprecated user_description" do
    test "a persona sets user_description to its characteristics" do
      golden = ConversationalGolden.new!(scenario: "s", persona: @persona)
      assert golden.user_description == "A busy parent"
    end

    test "a user_description alone becomes a persona, with a deprecation warning" do
      stderr =
        capture_io(:stderr, fn ->
          golden = ConversationalGolden.new!(scenario: "s", user_description: "A student")
          assert golden.persona == %Persona{characteristics: "A student"}
          assert golden.user_description == "A student"
        end)

      assert stderr =~ "'user_description' is deprecated"
    end

    test "a matching user_description is accepted with a persona, without a warning" do
      assert capture_io(:stderr, fn ->
               golden =
                 ConversationalGolden.new!(
                   scenario: "s",
                   persona: @persona,
                   user_description: "A busy parent"
                 )

               assert golden.persona == @persona
             end) == ""
    end

    test "a conflicting user_description is an error" do
      assert {:error, message} =
               ConversationalGolden.new(scenario: "s", persona: @persona, user_description: "x")

      assert message ==
               "Pass either 'persona' or the deprecated 'user_description', not both with " <>
                 "conflicting text."
    end

    test "an invalid persona is an error" do
      assert {:error, _} = ConversationalGolden.new(scenario: "s", persona: %{"name" => "Ann"})
      assert {:error, _} = ConversationalGolden.new(scenario: "s", persona: "Ann")
    end
  end

  describe "to_test_case/1" do
    test "maps the golden's fields onto a conversational test case" do
      golden =
        ConversationalGolden.new!(
          scenario: "s",
          expected_outcome: "o",
          persona: @persona,
          context: ["c"],
          additional_metadata: %{"k" => "v"},
          comments: "note",
          name: "n",
          custom_column_key_values: %{"x" => "y"},
          expectations: %{"must" => ["m"]},
          expected_labels: %{"l" => "a"},
          turns: [%{role: :user, content: "Hi"}]
        )

      assert %ConversationalTestCase{
               turns: [%Turn{role: :user, content: "Hi"}],
               scenario: "s",
               expected_outcome: "o",
               user_description: "A busy parent",
               context: ["c"],
               name: "n",
               metadata: %{"k" => "v"},
               comments: "note",
               expected_labels: %{"l" => "a"},
               expectations: %{must: ["m"]}
             } = ConversationalGolden.to_test_case(golden)
    end

    test "raises without turns, as deepeval's ConversationalTestCase(turns=[])" do
      assert_raise ArgumentError, ~r/'turns' must not be empty/, fn ->
        ConversationalGolden.to_test_case(ConversationalGolden.new!(scenario: "s"))
      end
    end
  end

  describe "from_test_case/1" do
    test "rebuilds a minimal persona from the user description, without a warning" do
      test_case =
        ConversationalTestCase.new!(
          turns: [%{role: :user, content: "Hi"}],
          scenario: "s",
          expected_outcome: "o",
          user_description: "A student",
          context: ["c"],
          metadata: %{"k" => "v"},
          name: "dropped",
          comments: "dropped",
          expectations: %{"must" => ["m"]}
        )

      assert capture_io(:stderr, fn ->
               assert %ConversationalGolden{
                        scenario: "s",
                        turns: [%Turn{content: "Hi"}],
                        expected_outcome: "o",
                        persona: %Persona{characteristics: "A student"},
                        user_description: "A student",
                        context: ["c"],
                        additional_metadata: %{"k" => "v"},
                        name: nil,
                        comments: nil,
                        expectations: %{must: ["m"]}
                      } = ConversationalGolden.from_test_case(test_case)
             end) == ""
    end

    test "leaves the persona out when the user description is nil or empty" do
      test_case =
        ConversationalTestCase.new!(turns: [%{role: :user, content: "Hi"}], scenario: "s")

      assert %ConversationalGolden{persona: nil, user_description: nil} =
               ConversationalGolden.from_test_case(test_case)

      assert %ConversationalGolden{persona: nil, user_description: nil} =
               ConversationalGolden.from_test_case(%{test_case | user_description: ""})
    end

    test "requires a scenario, with deepeval's message" do
      test_case = ConversationalTestCase.new!(turns: [%{role: :user, content: "Hi"}])

      assert_raise ArgumentError,
                   "Please provide a scenario in your 'ConversationalTestCase' to convert it " <>
                     "to a 'ConversationalGolden'.",
                   fn -> ConversationalGolden.from_test_case(test_case) end
    end
  end

  describe "convert_goldens_to_test_cases/1 and convert_test_cases_to_goldens/1" do
    test "convert in order, ranking test cases by position" do
      goldens =
        for scenario <- ["a", "b"] do
          ConversationalGolden.new!(
            scenario: scenario,
            turns: [
              %{role: :user, content: scenario, retrieval_context: [%{context: "c", source: "s"}]}
            ]
          )
        end

      test_cases = ConversationalGolden.convert_goldens_to_test_cases(goldens)
      assert Enum.map(test_cases, &{&1.scenario, &1.dataset_rank}) == [{"a", 0}, {"b", 1}]

      assert [%Turn{retrieval_context: [%RetrievedContextData{context: "c", source: "s"}]}] =
               hd(test_cases).turns

      assert test_cases
             |> ConversationalGolden.convert_test_cases_to_goldens()
             |> Enum.map(& &1.scenario) ==
               ["a", "b"]
    end
  end
end
