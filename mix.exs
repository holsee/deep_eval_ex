defmodule DeepEvalEx.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/holsee/deep_eval_ex"

  def project do
    [
      app: :deep_eval_ex,
      version: @version,
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
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

      # mix deep_eval.test and the ExUnit integration use Mix and ExUnit.
      dialyzer: [plt_add_apps: [:mix, :ex_unit]],

      # Test
      test_coverage: [tool: ExCoveralls],
      # The fixture projects run their own tests (see
      # test/deep_eval_ex/cli/integration_test.exs).
      test_ignore_filters: [&String.starts_with?(&1, "test/fixtures/")]
    ]
  end

  def cli do
    [
      preferred_envs: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.html": :test,
        "deep_eval.test": :test
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {DeepEvalEx.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      # HTTP client
      {:req, "~> 0.7"},

      # JSON
      {:jason, "~> 1.4"},

      # Schema validation
      {:peri, "~> 0.3"},

      # Option validation
      {:nimble_options, "~> 1.0"},

      # CSV parsing (dataset loaders)
      {:nimble_csv, "~> 1.3"},

      # Observability
      {:telemetry, "~> 1.0"},

      # Optional: providers beyond the native adapters, through
      # DeepEvalEx.LLM.Adapters.ReqLLM
      {:req_llm, "~> 1.29", optional: true},

      # Dev/Test
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:mox, "~> 1.0", only: :test},
      {:plug, "~> 1.16", only: :test},
      {:excoveralls, "~> 0.18", only: :test}
    ]
  end

  defp aliases do
    []
  end

  defp package do
    [
      maintainers: ["holsee"],
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib .formatter.exs mix.exs README.md CHANGELOG.md LICENSE NOTICE)
    ]
  end

  defp docs do
    [
      main: "overview",
      logo: "deepevalex.png",
      source_ref: "v#{@version}",
      extras: [
        {"README.md", [title: "Overview", filename: "overview"]},
        {"CHANGELOG.md", [title: "Changelog"]},
        {"LICENSE", [title: "License"]},
        {"NOTICE", [title: "Notice"]},
        {"ROADMAP.md", [title: "Roadmap"]},
        # Guides
        "wiki/guides/Quick-Start.md",
        "wiki/guides/Configuration.md",
        "wiki/guides/ExUnit-Integration.md",
        "wiki/guides/Custom-Metrics.md",
        "wiki/guides/Custom-LLM-Adapters.md",
        "wiki/guides/Telemetry.md",
        "wiki/guides/Tracing.md",
        "wiki/guides/Datasets.md",
        "wiki/guides/Classifiers.md",
        "wiki/guides/Expectations.md",
        "wiki/guides/Synthesizer.md",
        "wiki/guides/Conversation-Simulator.md",
        "wiki/guides/Test-Run-Cache.md",
        "wiki/guides/Console-Report.md",
        "wiki/guides/Phoenix-Integration.md",
        # Metrics
        {"wiki/metrics/Overview.md", [title: "Metrics Overview", filename: "metrics-overview"]},
        "wiki/metrics/ExactMatch.md",
        "wiki/metrics/PatternMatch.md",
        "wiki/metrics/JsonCorrectness.md",
        "wiki/metrics/GEval.md",
        "wiki/metrics/ConversationalGEval.md",
        "wiki/metrics/DAG.md",
        "wiki/metrics/ConversationalJevEval.md",
        "wiki/metrics/TurnRelevancy.md",
        "wiki/metrics/ConversationCompleteness.md",
        "wiki/metrics/KnowledgeRetention.md",
        "wiki/metrics/RoleAdherence.md",
        "wiki/metrics/GoalAccuracy.md",
        "wiki/metrics/ToolUse.md",
        "wiki/metrics/TurnFaithfulness.md",
        "wiki/metrics/TurnContextualPrecision.md",
        "wiki/metrics/TurnContextualRecall.md",
        "wiki/metrics/TurnContextualRelevancy.md",
        "wiki/metrics/Faithfulness.md",
        "wiki/metrics/Hallucination.md",
        "wiki/metrics/AnswerRelevancy.md",
        "wiki/metrics/ContextualPrecision.md",
        "wiki/metrics/ContextualRecall.md",
        "wiki/metrics/ContextualRelevancy.md",
        "wiki/metrics/Bias.md",
        "wiki/metrics/Toxicity.md",
        "wiki/metrics/PIILeakage.md",
        "wiki/metrics/PromptAlignment.md",
        "wiki/metrics/Summarization.md",
        "wiki/metrics/ToolCorrectness.md",
        "wiki/metrics/ArgumentCorrectness.md",
        "wiki/metrics/ToolPermission.md",
        "wiki/metrics/TaskCompletion.md",
        "wiki/metrics/StepEfficiency.md",
        "wiki/metrics/PlanQuality.md",
        "wiki/metrics/PlanAdherence.md",
        "wiki/metrics/AgentLoopDetection.md",
        # API
        "wiki/api/TestCase.md",
        "wiki/api/Result.md",
        "wiki/api/EvaluationResult.md",
        "wiki/api/Evaluator.md",
        "wiki/api/TestRun.md",
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
        "docs/adr/0008-peri-schema-validation-replacing-ecto.md",
        "docs/adr/0009-system-one-models-and-eval-modes.md",
        "docs/adr/0010-test-runner-report-cache-classifiers.md",
        "docs/adr/0011-tracing-span-api-and-agentic-evaluation.md",
        {"docs/adr/template.md", [title: "ADR Template"]}
      ],
      # ADR-0011 names the internal DeepEvalEx.Scope and, as shorthand,
      # DeepEvalEx.ExUnit.assert_trace/3.
      skip_code_autolink_to: ["DeepEvalEx.Scope", "ExUnit.assert_trace/3"],
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
          DeepEvalEx.ConversationalTestCase,
          DeepEvalEx.MLLMImage,
          DeepEvalEx.Turn,
          DeepEvalEx.MCP,
          DeepEvalEx.MCPServer,
          DeepEvalEx.MCPToolCall,
          DeepEvalEx.MCPResourceCall,
          DeepEvalEx.MCPPromptCall,
          DeepEvalEx.ArenaTestCase,
          DeepEvalEx.Contestant,
          DeepEvalEx.Result,
          DeepEvalEx.EvaluationResult,
          DeepEvalEx.TestResult,
          DeepEvalEx.Evaluator,
          DeepEvalEx.Evaluator.Agentic,
          DeepEvalEx.Evaluator.Traced
        ],
        Metrics: ~r/DeepEvalEx\.Metrics\..*/,
        Classifiers: [
          DeepEvalEx.Classifier,
          DeepEvalEx.Classifiers,
          DeepEvalEx.Classification,
          DeepEvalEx.Classifier.Utils
        ],
        "LLM Adapters": ~r/DeepEvalEx\.LLM\..*/,
        "System One": ~r/DeepEvalEx\.SystemOne(\..*)?$/,
        Datasets: ~r/DeepEvalEx\.Dataset(\..*)?$/,
        Synthesizer: ~r/DeepEvalEx\.Synthesizer(\..*)?$/,
        "Conversation Simulator": ~r/DeepEvalEx\.ConversationSimulator(\..*)?$/,
        Reports: ~r/DeepEvalEx\.Report(\..*)?$/,
        Tracing: ~r/DeepEvalEx\.Tracing(\..*)?$/,
        "Test Runner": [
          DeepEvalEx.ExUnit,
          DeepEvalEx.ExUnit.Collector,
          DeepEvalEx.ExUnit.Formatter,
          DeepEvalEx.ExUnit.Repeat,
          DeepEvalEx.CLI.TestArgs,
          Mix.Tasks.DeepEval.Test
        ],
        Schemas: ~r/DeepEvalEx\.Schemas\..*/,
        Telemetry: [DeepEvalEx.Telemetry]
      ]
    ]
  end
end
