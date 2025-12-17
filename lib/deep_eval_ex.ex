# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# This file is part of DeepEvalEx, a derivative work of DeepEval
# (https://github.com/confident-ai/deepeval) by Confident AI.

defmodule DeepEvalEx do
  @moduledoc """
  DeepEvalEx - LLM Evaluation Framework for Elixir

  A pure Elixir port of DeepEval, providing metrics and tooling
  to evaluate Large Language Model outputs.

  This project is a derivative work of [DeepEval](https://github.com/confident-ai/deepeval)
  by Confident AI, licensed under Apache 2.0.

  ## Quick Start

      # Define a test case
      test_case = %DeepEvalEx.TestCase{
        input: "What is the capital of France?",
        actual_output: "The capital of France is Paris.",
        expected_output: "Paris"
      }

      # Create a metric
      metric = DeepEvalEx.Metrics.GEval.new(
        name: "Correctness",
        criteria: "Determine if the actual output is factually correct",
        evaluation_params: [:input, :actual_output]
      )

      # Evaluate
      {:ok, result} = DeepEvalEx.evaluate(test_case, [metric])

  ## Metrics

  DeepEvalEx provides several evaluation metrics:

  - `DeepEvalEx.Metrics.GEval` - Flexible criteria-based evaluation
  - `DeepEvalEx.Metrics.Faithfulness` - RAG: claims supported by context
  - `DeepEvalEx.Metrics.Hallucination` - Detects unsupported statements
  - `DeepEvalEx.Metrics.AnswerRelevancy` - Response relevance to question
  - `DeepEvalEx.Metrics.ContextualPrecision` - RAG retrieval ranking quality
  - `DeepEvalEx.Metrics.ContextualRecall` - RAG coverage of ground truth
  - `DeepEvalEx.Metrics.ExactMatch` - Simple string comparison

  ## LLM Providers

  Supports multiple LLM backends:

  - OpenAI (gpt-4o, gpt-4o-mini, gpt-3.5-turbo)
  - Anthropic (claude-3-opus, claude-3-sonnet, claude-3-haiku)
  - Ollama (local models)

  ## Configuration

      config :deep_eval_ex,
        default_model: :openai,
        openai_api_key: System.get_env("OPENAI_API_KEY"),
        default_threshold: 0.5,
        max_concurrency: 10
  """

  alias DeepEvalEx.{Evaluator, Result, TestCase}

  @doc """
  Evaluate a single test case against one or more metrics.

  ## Options

  - `:threshold` - Score threshold for pass/fail (default: 0.5)
  - `:model` - LLM model to use for evaluation
  - `:timeout` - Timeout per metric in milliseconds (default: 60_000)

  ## Examples

      {:ok, results} = DeepEvalEx.evaluate(test_case, [metric])

      # With options
      {:ok, results} = DeepEvalEx.evaluate(test_case, [metric],
        threshold: 0.7,
        model: {:openai, "gpt-4o"}
      )
  """
  @spec evaluate(TestCase.t(), [module() | struct()], keyword()) ::
          {:ok, [Result.t()]} | {:error, term()}
  def evaluate(test_case, metrics, opts \\ []) do
    Evaluator.evaluate([test_case], metrics, opts)
    |> case do
      [results] -> {:ok, results}
      error -> {:error, error}
    end
  end

  @doc """
  Evaluate multiple test cases against metrics concurrently.

  Leverages BEAM's lightweight processes for parallel evaluation.

  ## Options

  - `:concurrency` - Max concurrent evaluations (default: schedulers * 2)
  - `:threshold` - Score threshold for pass/fail (default: 0.5)
  - `:model` - LLM model to use for evaluation
  - `:timeout` - Timeout per evaluation in milliseconds (default: 60_000)

  ## Examples

      results = DeepEvalEx.evaluate_batch(test_cases, [metric1, metric2],
        concurrency: 20
      )
  """
  @spec evaluate_batch([TestCase.t()], [module() | struct()], keyword()) :: [[Result.t()]]
  def evaluate_batch(test_cases, metrics, opts \\ []) do
    Evaluator.evaluate(test_cases, metrics, opts)
  end

  @doc """
  Get the configured default LLM model.
  """
  def default_model do
    Application.get_env(:deep_eval_ex, :default_model, {:openai, "gpt-4o-mini"})
  end

  @doc """
  Get the configured default threshold for pass/fail.
  """
  def default_threshold do
    Application.get_env(:deep_eval_ex, :default_threshold, 0.5)
  end
end
