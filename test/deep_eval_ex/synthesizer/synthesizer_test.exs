defmodule DeepEvalEx.SynthesizerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias DeepEvalEx.Dataset.Golden
  alias DeepEvalEx.LLM.Adapters.Mock
  alias DeepEvalEx.LLM.Usage
  alias DeepEvalEx.Prompts.Python
  alias DeepEvalEx.Synthesizer
  alias DeepEvalEx.Synthesizer.{Evolution, EvolutionConfig, FiltrationConfig, StylingConfig}

  doctest DeepEvalEx.Synthesizer.Evolution
  doctest DeepEvalEx.Synthesizer.EvolutionConfig
  doctest DeepEvalEx.Synthesizer.FiltrationConfig
  doctest DeepEvalEx.Synthesizer.StylingConfig
  doctest DeepEvalEx.Synthesizer.Schema

  # A stateless judge answering from the prompt alone, so concurrent calls
  # get the same answers in any order. Native when built as NativeJudge.
  defmodule EchoJudge do
    @moduledoc false
    use DeepEvalEx.LLM.Adapter

    alias DeepEvalEx.LLM.Usage

    @impl true
    def generate(_prompt, _opts) do
      Usage.record(Usage.new("gpt-4o-mini", 1_000, 100))
      {:ok, "Evolved."}
    end

    @impl true
    def generate_with_schema(prompt, %{"properties" => properties}, opts) do
      Usage.record(Usage.new("gpt-4o-mini", 1_000, 100))

      case properties |> Map.keys() |> Enum.sort() do
        ["data"] ->
          [context] = Regex.run(~r/Context:\n\s*(\[.*\])/, prompt, capture: :all_but_first)
          {:ok, %{"data" => [%{"input" => "About " <> context}]}}

        ["feedback", "score"] ->
          {:ok, %{"feedback" => "Clear.", "score" => Keyword.get(opts, :score, 1)}}

        ["response"] ->
          {:ok, %{"response" => "Response"}}
      end
    end

    @impl true
    def model_name(_opts), do: "echo-judge"

    @impl true
    def supports_structured_outputs?, do: true

    @impl true
    def supports_log_probs?, do: false
  end

  defmodule NativeJudge do
    @moduledoc false
    use DeepEvalEx.LLM.Adapter

    @impl true
    def native?, do: true

    @impl true
    defdelegate generate(prompt, opts), to: EchoJudge
    @impl true
    defdelegate generate_with_schema(prompt, schema, opts), to: EchoJudge
    @impl true
    def model_name(_opts), do: "gpt-4o-mini"
    @impl true
    def supports_structured_outputs?, do: true
    @impl true
    def supports_log_probs?, do: false
  end

  # A custom judge that takes no schema: deepeval's TypeError fallback.
  defmodule TextJudge do
    @moduledoc false
    use DeepEvalEx.LLM.Adapter

    @impl true
    def generate(_prompt, _opts) do
      {:ok, ~s({"data": [{"input": "Plain?"}]})}
    end

    @impl true
    def generate_with_schema(_prompt, _schema, _opts), do: raise("not called")
    @impl true
    def model_name(_opts), do: "text-judge"
    @impl true
    def supports_structured_outputs?, do: false
    @impl true
    def supports_log_probs?, do: false
  end

  @styling [scenario: "Tourists", task: "Travel assistant", input_format: "A question"]

  describe "new/1" do
    test "defaults to deepeval's configs, the model as critic" do
      synthesizer = Synthesizer.new(adapter: :mock, model: "judge")

      assert synthesizer.max_concurrent == 100

      assert synthesizer.filtration_config == %FiltrationConfig{
               critic_adapter: :mock,
               critic_model: "judge"
             }

      assert synthesizer.evolution_config.num_evolutions == 1

      assert Keyword.keys(synthesizer.evolution_config.evolutions) ==
               Evolution.all()

      assert Enum.all?(synthesizer.evolution_config.evolutions, fn {_, w} -> w == 1 / 7 end)
      assert synthesizer.styling_config == %StylingConfig{}
      refute synthesizer.set_styling_config
      assert synthesizer.synthetic_goldens == []
      assert synthesizer.synthesis_cost == nil
    end

    test "a filtration config without a critic leaves the default model, as initialize_model(None)" do
      synthesizer = Synthesizer.new(adapter: :mock, filtration_config: [max_quality_retries: 1])
      assert synthesizer.filtration_config.critic_adapter == nil
      assert synthesizer.filtration_config.max_quality_retries == 1
    end

    test "takes config structs and marks a given styling config" do
      styling = StylingConfig.new(@styling)
      synthesizer = Synthesizer.new(styling_config: styling)

      assert synthesizer.styling_config == styling
      assert synthesizer.set_styling_config
    end

    test "raises on unknown options and invalid configs" do
      assert_raise ArgumentError, ~r/unknown synthesizer options: \[:async_mode\]/, fn ->
        Synthesizer.new(async_mode: false)
      end

      assert_raise ArgumentError, ~r/max_concurrent/, fn -> Synthesizer.new(max_concurrent: 0) end

      assert_raise ArgumentError, ~r/unknown evolution: :deeper/, fn ->
        EvolutionConfig.new(evolutions: [deeper: 1])
      end

      assert_raise ArgumentError, ~r/non-negative numbers/, fn ->
        EvolutionConfig.new(evolutions: [reasoning: -1])
      end

      assert_raise ArgumentError, ~r/max_quality_retries/, fn ->
        FiltrationConfig.new(max_quality_retries: -1)
      end

      assert_raise ArgumentError, ~r/must be a string/, fn -> StylingConfig.new(task: 1) end
      assert_raise KeyError, fn -> StylingConfig.new(tone: "dry") end
    end
  end

  describe "EvolutionConfig.pick/1" do
    test "draws every evolution with weight, none without" do
      picks =
        for _ <- 1..200,
            into: MapSet.new(),
            do: EvolutionConfig.pick(reasoning: 1, constrained: 0, in_breadth: 3)

      assert picks == MapSet.new([:reasoning, :in_breadth])
    end

    test "raises when the weights add up to zero" do
      assert_raise ArgumentError, "Total of weights must be greater than zero", fn ->
        EvolutionConfig.pick(reasoning: 0)
      end
    end
  end

  describe "generate_goldens_from_contexts/3" do
    test "keeps the order of contexts and inputs when run concurrently" do
      contexts = for i <- 1..20, do: ["Fact #{i}."]

      synthesizer =
        Synthesizer.new(adapter: EchoJudge, evolution_config: [evolutions: [reasoning: 1]])

      assert {:ok, synthesizer} =
               Synthesizer.generate_goldens_from_contexts(synthesizer, contexts,
                 max_goldens_per_context: 1
               )

      assert Enum.map(synthesizer.synthetic_goldens, & &1.context) == contexts

      assert Enum.map(synthesizer.synthetic_goldens, & &1.expected_output) ==
               List.duplicate("Response", 20)

      assert synthesizer.synthesis_cost == nil
    end

    test "sums a native model's cost, printing it with cost_tracking" do
      synthesizer =
        Synthesizer.new(
          adapter: NativeJudge,
          cost_tracking: true,
          evolution_config: [evolutions: [reasoning: 1]],
          filtration_config: [critic_adapter: EchoJudge]
        )

      output =
        capture_io(fn ->
          {result, usages} =
            Usage.track(fn ->
              Synthesizer.generate_goldens_from_contexts(synthesizer, [["A."]],
                max_goldens_per_context: 1
              )
            end)

          send(self(), {:result, result, usages})
        end)

      assert_received {:result, {:ok, synthesizer}, usages}

      # Inputs, evolution and expected output from the native model; the
      # custom critic's call is recorded but adds no cost.
      call_cost = Usage.new("gpt-4o-mini", 1_000, 100).cost
      assert_in_delta synthesizer.synthesis_cost, 3 * call_cost, 1.0e-12
      assert length(usages) == 4

      assert output ==
               "💰 API cost: #{Python.format_fixed(synthesizer.synthesis_cost, 6)}\n"
    end

    test "asks a custom judge without structured outputs with plain generate" do
      synthesizer =
        Synthesizer.new(
          adapter: TextJudge,
          evolution_config: [evolutions: [constrained: 1]],
          filtration_config: [max_quality_retries: 0]
        )

      assert {:ok, synthesizer} =
               Synthesizer.generate_goldens_from_contexts(synthesizer, [["A."]],
                 include_expected_output: false
               )

      assert [%Golden{additional_metadata: %{"evolutions" => ["Constrained"]}} = golden] =
               synthesizer.synthetic_goldens

      # The evolution's raw text is the evolved input.
      assert golden.input == ~s({"data": [{"input": "Plain?"}]})
    end

    test "returns the first error: a missing scripted response" do
      Mock.script(%{"data" => [%{"data" => [%{"input" => "Why?"}]}]})
      synthesizer = Synthesizer.new(adapter: :mock)

      assert {:error, {:no_scripted_response, "feedback,score", 0}} =
               Synthesizer.generate_goldens_from_contexts(synthesizer, [["A."]])
    end

    test "returns an answer outside its schema as an error" do
      Mock.script(%{"data" => [%{"data" => [%{"text" => "Why?"}]}]})
      synthesizer = Synthesizer.new(adapter: :mock)

      assert {:error,
              {:invalid_response, "SyntheticDataList", %{"data" => [%{"text" => "Why?"}]}}} =
               Synthesizer.generate_goldens_from_contexts(synthesizer, [["A."]])
    end
  end

  describe "generate_goldens_from_scratch/3" do
    test "raises deepeval's error without a full styling" do
      synthesizer = Synthesizer.new(adapter: :mock, styling_config: [scenario: "S", task: "T"])

      assert_raise ArgumentError, ~r/must not be None when generation goldens from scratch/, fn ->
        Synthesizer.generate_goldens_from_scratch(synthesizer, 1)
      end
    end

    test "raises when only Multi-context is left to draw" do
      Mock.script(%{"data" => [%{"data" => [%{"input" => "Why?"}]}]})

      synthesizer =
        Synthesizer.new(
          adapter: :mock,
          styling_config: @styling,
          evolution_config: [evolutions: [multi_context: 1]]
        )

      assert_raise ArgumentError, "Total of weights must be greater than zero", fn ->
        Synthesizer.generate_goldens_from_scratch(synthesizer, 1)
      end
    end
  end

  describe "generate_goldens_from_goldens/3" do
    test "extracts the styling from at most ten of the goldens' inputs" do
      goldens = for i <- 1..12, do: Golden.new!(input: "Question #{i}?")

      Mock.script(%{
        "input_format,scenario,task" => [
          %{"scenario" => "Users", "task" => "Answering", "input_format" => "Questions"}
        ],
        "data" => [%{"data" => []}]
      })

      synthesizer = Synthesizer.new(adapter: :mock)

      assert {:ok, synthesizer} = Synthesizer.generate_goldens_from_goldens(synthesizer, goldens)
      assert synthesizer.synthetic_goldens == []

      assert synthesizer.styling_config == %StylingConfig{
               scenario: "Users",
               task: "Answering",
               input_format: "Questions"
             }

      [%{step: "input_format,scenario,task", prompt: prompt}, %{step: "data", prompt: scratch}] =
        Mock.scripted_prompts()

      [inputs] =
        Regex.run(~r/Here are the inputs to analyze:\n\n\s*(\[.*\])/, prompt,
          capture: :all_but_first
        )

      sampled =
        Regex.scan(~r/'(Question \d+\?)'/, inputs, capture: :all_but_first) |> List.flatten()

      assert length(sampled) == 10
      assert Enum.uniq(sampled) == sampled
      assert Enum.all?(sampled, &(&1 in Enum.map(goldens, fn g -> g.input end)))
      # From scratch: two goldens per golden.
      assert scratch =~ "num prompts: 24"
    end
  end
end
