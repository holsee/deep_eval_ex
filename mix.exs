defmodule DeepEvalEx.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/holsee/deep_eval_ex"

  def project do
    [
      app: :deep_eval_ex,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),

      # Hex
      description: "LLM evaluation framework for Elixir - port of DeepEval",
      package: package(),

      # Docs
      name: "DeepEvalEx",
      source_url: @source_url,
      docs: docs(),

      # Test
      test_coverage: [tool: ExCoveralls]
    ]
  end

  def cli do
    [
      preferred_envs: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.html": :test
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {DeepEvalEx.Application, []}
    ]
  end

  defp deps do
    [
      # HTTP client
      {:req, "~> 0.5"},

      # JSON
      {:jason, "~> 1.4"},

      # Schema validation (embedded, no DB)
      {:ecto, "~> 3.11"},

      # Option validation
      {:nimble_options, "~> 1.0"},

      # Observability
      {:telemetry, "~> 1.0"},

      # Dev/Test
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:mox, "~> 1.0", only: :test},
      {:excoveralls, "~> 0.18", only: :test}
    ]
  end

  defp aliases do
    [
      test: ["test --trace"]
    ]
  end

  defp package do
    [
      maintainers: ["holsee"],
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE NOTICE)
    ]
  end

  defp docs do
    [
      main: "overview",
      logo: "deepevalex.png",
      source_ref: "v#{@version}",
      extras: [
        {"README.md", [title: "Overview", filename: "overview"]},
        {"LICENSE", [title: "License"]},
        {"NOTICE", [title: "Notice"]},
        # Guides
        "wiki/guides/Quick-Start.md",
        "wiki/guides/Configuration.md",
        "wiki/guides/ExUnit-Integration.md",
        "wiki/guides/Custom-Metrics.md",
        "wiki/guides/Custom-LLM-Adapters.md",
        "wiki/guides/Telemetry.md",
        "wiki/guides/Phoenix-Integration.md",
        # Metrics
        {"wiki/metrics/Overview.md", [title: "Metrics Overview", filename: "metrics-overview"]},
        "wiki/metrics/ExactMatch.md",
        "wiki/metrics/GEval.md",
        "wiki/metrics/Faithfulness.md",
        "wiki/metrics/Hallucination.md",
        "wiki/metrics/AnswerRelevancy.md",
        "wiki/metrics/ContextualPrecision.md",
        "wiki/metrics/ContextualRecall.md",
        # API
        "wiki/api/TestCase.md",
        "wiki/api/Result.md",
        "wiki/api/Evaluator.md",
        "wiki/api/LLM-Adapters.md",
        # Architecture
        {"docs/adr/README.md", [title: "ADR Index", filename: "adr-index"]},
        "docs/adr/0001-behaviour-based-plugin-architecture.md",
        "docs/adr/0002-ecto-schemas-without-database.md",
        "docs/adr/0003-telemetry-first-observability.md",
        "docs/adr/0004-concurrent-evaluation-with-task-async-stream.md",
        "docs/adr/0005-multi-step-prompting-for-rag-metrics.md",
        "docs/adr/0006-json-schema-for-structured-outputs.md",
        "docs/adr/0007-basemetric-macro-for-instrumentation.md",
        {"docs/adr/template.md", [title: "ADR Template"]}
      ],
      groups_for_extras: [
        Guides: ~r/wiki\/guides\/.*/,
        Metrics: ~r/wiki\/metrics\/.*/,
        API: ~r/wiki\/api\/.*/,
        Architecture: ~r/docs\/adr\/.*/
      ],
      groups_for_modules: [
        "Public API": [
          DeepEvalEx,
          DeepEvalEx.TestCase,
          DeepEvalEx.Result,
          DeepEvalEx.Evaluator
        ],
        Metrics: ~r/DeepEvalEx\.Metrics\..*/,
        "LLM Adapters": ~r/DeepEvalEx\.LLM\..*/,
        Schemas: ~r/DeepEvalEx\.Schemas\..*/,
        Telemetry: [DeepEvalEx.Telemetry]
      ]
    ]
  end
end
