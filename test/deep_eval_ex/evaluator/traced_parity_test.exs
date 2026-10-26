defmodule DeepEvalEx.Evaluator.TracedParityTest do
  @moduledoc """
  Runs the traced fixtures' agent scripts over their goldens with
  `DeepEvalEx.evaluate_traced/3`, in each of the iterator's modes the
  scenario was generated in, and compares the test run file it saves, byte
  for byte after the fixtures' normalisation, with the one deepeval 4.3.1's
  `evals_iterator` wrote (`test_run_sync.json`, `test_run_async.json`): the
  whole file, so the iterator's own parts are compared too (one capture per
  golden, the sync wrapper strip, the uncaught error's marking, the
  `prompts` and `hyperparameters` its LLM spans log).

  When the scenario's metrics have ScriptedJudges, the prompts their
  judges got (`prompts_sync.json`, `prompts_async.json`) are compared too,
  each metric's on its own: deepeval's file lists them judge by judge.
  """

  use ExUnit.Case, async: true

  alias DeepEvalEx.Dataset.Golden
  alias DeepEvalEx.Evaluator.Traced
  alias DeepEvalEx.LLM.Adapters.Mock
  alias DeepEvalEx.Test.{ScriptedParity, TracedFixtures, TracingScenarios}

  @moduletag :parity
  @moduletag :tmp_dir
  # The run logs where it saved the test run.
  @moduletag :capture_log

  for scenario <- TracedFixtures.scenarios(),
      mode <- TracedFixtures.load!(scenario, "input.json")["modes"] do
    @external_resource Path.join([TracedFixtures.dir(), scenario, "test_run_#{mode}.json"])

    test "evaluate_traced runs #{scenario} as deepeval's #{mode} evals_iterator", %{
      tmp_dir: tmp_dir
    } do
      scenario = unquote(scenario)
      mode = unquote(mode)
      input = TracedFixtures.load!(scenario, "input.json")
      module = TracingScenarios.compile(scenario)
      TracingScenarios.script_judges(input)

      {_evaluation, _test_run, path} =
        Traced.run(
          goldens(input),
          fn golden ->
            TracingScenarios.run_steps(module, input["app"], %{"input" => golden.input})
          end,
          mode: String.to_existing_atom(mode),
          metrics: Enum.map(input["metrics"] || [], &TracingScenarios.metric/1),
          identifier: input["identifier"],
          ignore_errors: true,
          results_folder: tmp_dir,
          print_results: false
        )

      assert TracedFixtures.normalise(File.read!(path)) ==
               TracedFixtures.normalise(TracedFixtures.read!(scenario, "test_run_#{mode}.json"))

      if File.regular?(Path.join([TracedFixtures.dir(), scenario, "prompts_#{mode}.json"])) do
        expected = Jason.decode!(TracedFixtures.read!(scenario, "prompts_#{mode}.json"))
        assert_judge_prompts(input, Mock.scripted_prompts(), expected)
      end
    end
  end

  # Each judged metric's prompts, by the steps its responses script, as
  # ScriptedParity compares a scripted scenario's.
  defp assert_judge_prompts(input, ours, theirs) do
    steps =
      for spec <- (input["metrics"] || []) ++ function_metrics(input),
          responses = spec["responses"],
          do: Enum.map(responses.values, &elem(&1, 0))

    assert Enum.sort(List.flatten(steps)) == theirs |> Enum.map(& &1["step"]) |> Enum.sort()

    for judge_steps <- steps do
      ScriptedParity.assert_prompts(
        Enum.filter(ours, &(&1.step in judge_steps)),
        Enum.filter(theirs, &(&1["step"] in judge_steps))
      )
    end
  end

  defp function_metrics(input),
    do: Enum.flat_map(input["functions"].values, fn {_name, spec} -> spec["metrics"] || [] end)

  defp goldens(input) do
    for golden <- input["goldens"] do
      %Golden{
        input: golden["input"],
        expected_output: golden["expected_output"],
        name: golden["name"]
      }
    end
  end
end
