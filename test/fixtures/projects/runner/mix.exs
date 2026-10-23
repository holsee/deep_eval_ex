# A project that runs `mix deep_eval.test` over test/runner_eval.exs, the
# mirror of test/fixtures/deepeval/cli/test_runner.py, for
# DeepEvalEx.CLI.IntegrationTest. It shares the repository's deps and builds
# into its own folder of the repository's _build.
defmodule Runner.MixProject do
  use Mix.Project

  @root Path.expand("../../../..", __DIR__)

  def project do
    [
      app: :runner,
      version: "0.1.0",
      elixir: "~> 1.15",
      deps_path: Path.join(@root, "deps"),
      lockfile: Path.join(@root, "mix.lock"),
      build_path: Path.join(@root, "_build/runner_fixture"),
      deps: [{:deep_eval_ex, path: @root}],
      # Not *_test.exs, so the repository's own `mix test` does not load it.
      test_load_filters: [&String.ends_with?(&1, "_eval.exs")]
    ]
  end

  def cli, do: [preferred_envs: ["deep_eval.test": :test]]
end
