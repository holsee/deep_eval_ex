defmodule DeepEvalEx.SystemOne.ExportTest do
  @moduledoc """
  Compares the test run exports of the `hybrid` System One fixtures
  (`test/fixtures/deepeval/system_one/*_hybrid*`) with deepeval's
  `test_run.json`, byte for byte.

  The hybrid metrics themselves land with P4, so a `Replay` metric stands
  in for each one: it replays the System One requests deepeval's metric
  made (`decide.json`) through `DeepEvalEx.SystemOne.decide/3`, booking
  their usage or falling back as the decision helpers do, asks its LLM
  judge when the scenario had one, and returns the score, reason and
  verbose logs deepeval measured (`measure.json`). What is under test is
  everything else in the export: `evaluationModel` names the LLM judge
  even when only System One was asked, the judge's nil seed voids the
  cost, System One's token counts are kept, and a fallback leaves no token
  keys at all.
  """

  use ExUnit.Case, async: true

  alias DeepEvalEx.LLM.Usage
  alias DeepEvalEx.SystemOne.Adapters.Mock
  alias DeepEvalEx.SystemOne.{Decision, Question}
  alias DeepEvalEx.TestCase

  @moduletag :parity
  @moduletag :tmp_dir

  @fixtures Path.expand("../../fixtures/deepeval/system_one", __DIR__)

  # Single-turn scenarios only: Replay is a single-turn metric. The
  # conversational hybrid scenarios (a test case with turns) are compared
  # with the real metrics by DeepEvalEx.Metrics.SystemOneParityTest.
  @scenarios @fixtures
             |> File.ls!()
             |> Enum.filter(&String.contains?(&1, "_hybrid"))
             |> Enum.reject(fn scenario ->
               [@fixtures, scenario, "input.json"]
               |> Path.join()
               |> File.read!()
               |> Jason.decode!()
               |> get_in(["test_case", "turns"])
             end)
             |> Enum.sort()

  for scenario <- @scenarios, file <- ~w(input.json decide.json measure.json test_run.json) do
    @external_resource Path.join([@fixtures, scenario, file])
  end

  defmodule ReplayJudge do
    @moduledoc false
    # A custom (non-native) LLM judge named after opts[:model]: deepeval's
    # scripted judge, or its exploding LLM when the scenario has no
    # responses.
    use DeepEvalEx.LLM.Adapter

    @impl true
    def generate(_prompt, _opts), do: {:ok, "{}"}

    @impl true
    def generate_with_schema(_prompt, _schema, _opts), do: {:ok, %{}}

    @impl true
    def model_name(opts), do: Keyword.fetch!(opts, :model)

    @impl true
    def supports_structured_outputs?, do: true

    @impl true
    def supports_log_probs?, do: false
  end

  defmodule Replay do
    @moduledoc false
    # Replays a hybrid fixture metric's System One requests, then its LLM
    # judge calls, and returns what deepeval measured.
    use DeepEvalEx.Metrics.BaseMetric

    alias DeepEvalEx.LLM.Adapter
    alias DeepEvalEx.SystemOne

    defstruct [
      :name,
      :requests,
      :measured,
      :eval_mode,
      :system_one_model,
      :adapter,
      :model,
      judge?: false,
      threshold: 0.5,
      strict_mode: false
    ]

    @impl true
    def metric_name, do: "Replay"

    @impl true
    def metric_name(%__MODULE__{name: name}), do: name

    @impl true
    def required_params, do: []

    @impl true
    defdelegate evaluation_model(opts), to: Adapter, as: :model_name

    def do_measure(_test_case, opts) do
      model = Keyword.fetch!(opts, :system_one).model

      # System One first, so its usage is recorded before the judge's.
      for {state, questions} <- Keyword.fetch!(opts, :requests) do
        case SystemOne.decide(state, questions, system_one_model: model) do
          {:ok, _answers, usage} -> Usage.record(usage || %Usage{source: :system_one})
          {:error, error} -> Decision.handle_failure(error, opts)
        end
      end

      if Keyword.fetch!(opts, :judge?), do: {:ok, _} = Adapter.generate("replay", opts)

      measured = Keyword.fetch!(opts, :measured)

      {:ok,
       Result.new(
         metric: Keyword.fetch!(opts, :name),
         score: measured["score"],
         threshold: measured["threshold"],
         reason: measured["reason"],
         verbose_logs: measured["verbose_logs"]
       )}
    end
  end

  test "covers every single-turn hybrid scenario" do
    assert length(@scenarios) == 32
  end

  for scenario <- @scenarios do
    test "#{scenario} exports deepeval's test_run.json", %{tmp_dir: tmp_dir} do
      scenario = unquote(scenario)
      input = load(scenario, "input.json")
      [metric] = input["metrics"]
      [requests] = load(scenario, "decide.json")["measure"]
      [measured] = load(scenario, "measure.json")
      theirs = File.read!(Path.join([@fixtures, scenario, "test_run.json"]))
      [[name]] = metric_names(theirs)

      replay = %Replay{
        name: name,
        requests: Enum.map(requests, &request/1),
        measured: Map.new(measured.values),
        eval_mode: :hybrid,
        system_one_model: Mock.from_fixture(input["system_one"]),
        adapter: ReplayJudge,
        model: input["judge_model"] || "exploding-llm",
        judge?: Map.has_key?(input, "responses"),
        threshold: metric["params"]["threshold"],
        strict_mode: strict_mode(metric)
      }

      {_results, _test_run, path} =
        DeepEvalEx.evaluate_run([test_case(scenario)], [replay], results_folder: tmp_dir)

      assert normalise(File.read!(path)) == normalise(theirs)
    end
  end

  # deepeval's JsonCorrectness is strict unless told otherwise.
  defp strict_mode(metric) do
    case metric["params"]["strict_mode"] do
      nil -> metric["kind"] == "json_correctness"
      strict_mode -> strict_mode
    end
  end

  defp load(scenario, file) do
    [@fixtures, scenario, file]
    |> Path.join()
    |> File.read!()
    |> Jason.decode!(objects: :ordered_objects)
  end

  # The test case's own fields; tool calls as plain maps.
  defp test_case(scenario) do
    [@fixtures, scenario, "input.json"]
    |> Path.join()
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("test_case")
    |> TestCase.new!()
  end

  # A recorded decide() call as the state and questions to send again.
  defp request(call) do
    questions = for {key, question} <- call["questions"].values, do: {key, question(question)}
    {call["state"], questions}
  end

  defp question(wire) do
    case wire["type"] do
      "noul" ->
        criteria = wire["criteria"] || %{}

        %Question.Noul{
          instructions: wire["instructions"],
          true: criteria["true"],
          false: criteria["false"]
        }

      "score" ->
        %Question.Score{instructions: wire["instructions"], levels: wire["criteria"]}

      "choice" ->
        %Question.Choice{instructions: wire["instructions"], options: wire["criteria"].values}
    end
  end

  defp metric_names(test_run) do
    for test_case <- Jason.decode!(test_run)["testCases"],
        do: Enum.map(test_case["metricsData"], & &1["name"])
  end

  # The run-level runDuration, the wall-clock time of the whole run, is the
  # only key following testFailed.
  defp normalise(json) do
    String.replace(json, ~r/("testFailed": \d+, "runDuration": )[^,}]+/, "\\1\"<normalised>\"")
  end
end
