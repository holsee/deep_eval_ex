# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/metrics/base_metric.py (PromptMixin._get_prompt) and
# deepeval/templates/template_class.py (make_template_class)
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.Prompts.EvaluationTemplate do
  @moduledoc """
  Per-metric prompt overrides, deepeval 4.3.1's `evaluation_template`.

  Every LLM-judged metric takes an `:evaluation_template` option naming a
  module that replaces some of the metric's prompts. Each prompt module
  (`DeepEvalEx.Prompts.Faithfulness`, `DeepEvalEx.Prompts.GEval`, ...) is
  also a behaviour whose optional callbacks are its templates, so an
  override implements that behaviour and defines only the templates it
  changes; every other template falls back to the default, one callback at
  a time, as deepeval's `PromptMixin._get_prompt` falls back to the bundled
  template when the `evaluation_template` class has no such method:

      defmodule MyFaithfulnessTemplate do
        @behaviour DeepEvalEx.Prompts.Faithfulness

        alias DeepEvalEx.Prompts.Faithfulness

        @impl true
        def generate_claims(opts) do
          "Only extract claims about pricing.\\n\\n" <> Faithfulness.generate_claims(opts)
        end

        @impl true
        def system_one_verdict, do: "Is `claim` stated in `retrieval_context`?"
      end

      DeepEvalEx.Metrics.Faithfulness.measure(test_case,
        evaluation_template: MyFaithfulnessTemplate
      )

  A template takes the keyword list its default takes (or nothing, for the
  System One templates without arguments) and returns the prompt. The
  System One templates, deepeval's `_experimental_system_one_*` entries,
  are overridable like any other: `system_one_verdict/0` gives the
  instructions of each `:hybrid` Decision and `system_one_questions` the
  questions the `:system_one` eval mode asks, as JSON that
  `DeepEvalEx.SystemOne.Scored.parse!/1` reads.

  Templates a metric borrows from another metric are not overridden, as
  deepeval's explicit `template_class` bypasses the override: Summarization
  always extracts its claims and truths with
  `DeepEvalEx.Prompts.Faithfulness`.
  """

  @typedoc "A template name and arity, such as `{:generate_claims, 1}`."
  @type template :: {atom(), 0 | 1}

  @doc """
  Makes the calling prompt module a behaviour whose optional callbacks are
  `templates`, a keyword list of template names and arities (`0` for a
  template without arguments, `1` for one taking a keyword list).
  """
  defmacro __using__(opts) do
    templates = Keyword.fetch!(opts, :templates)

    callbacks =
      for {name, arity} <- templates do
        case arity do
          0 -> quote(do: @callback(unquote(name)() :: String.t()))
          1 -> quote(do: @callback(unquote(name)(opts :: keyword()) :: String.t()))
        end
      end

    quote do
      unquote_splicing(callbacks)
      @optional_callbacks unquote(templates)
    end
  end

  @doc """
  Renders the template `name` without arguments, from the
  `:evaluation_template` in `opts` when it defines `name/0`, else from
  `default`.
  """
  @spec render(keyword(), module(), atom()) :: String.t()
  def render(opts, default, name), do: dispatch(opts, default, name, [])

  @doc """
  Renders the template `name` with `assigns`, from the
  `:evaluation_template` in `opts` when it defines `name/1`, else from
  `default`.

  Raises `ArgumentError` when the `:evaluation_template` is not a module
  that can be loaded.

  ## Examples

      iex> DeepEvalEx.Prompts.EvaluationTemplate.render(
      ...>   [],
      ...>   DeepEvalEx.Prompts.Faithfulness,
      ...>   :generate_claims,
      ...>   actual_output: "Paris is in France."
      ...> ) == DeepEvalEx.Prompts.Faithfulness.generate_claims(actual_output: "Paris is in France.")
      true
  """
  @spec render(keyword(), module(), atom(), keyword()) :: String.t()
  def render(opts, default, name, assigns) when is_list(assigns),
    do: dispatch(opts, default, name, [assigns])

  defp dispatch(opts, default, name, args) do
    opts
    |> Keyword.get(:evaluation_template)
    |> template_module(default, name, length(args))
    |> apply(name, args)
  end

  defp template_module(nil, default, _name, _arity), do: default

  defp template_module(module, default, name, arity) when is_atom(module) do
    case Code.ensure_loaded(module) do
      {:module, ^module} ->
        if function_exported?(module, name, arity), do: module, else: default

      {:error, reason} ->
        raise ArgumentError,
              "evaluation_template #{inspect(module)} could not be loaded: #{inspect(reason)}"
    end
  end

  defp template_module(other, _default, _name, _arity) do
    raise ArgumentError, "evaluation_template must be a module, got: #{inspect(other)}"
  end
end
