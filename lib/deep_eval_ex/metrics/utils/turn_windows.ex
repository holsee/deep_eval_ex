# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from the shared shape of deepeval/metrics/turn_faithfulness,
# turn_contextual_precision, turn_contextual_recall and
# turn_contextual_relevancy
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.Metrics.Utils.TurnWindows do
  @moduledoc """
  The loop deepeval 4.3.1's Turn RAG metrics share
  (`DeepEvalEx.Metrics.TurnFaithfulness`,
  `DeepEvalEx.Metrics.TurnContextualPrecision`,
  `DeepEvalEx.Metrics.TurnContextualRecall` and
  `DeepEvalEx.Metrics.TurnContextualRelevancy`): each runs its single-turn
  counterpart's judgement on every sliding window of a conversation, then
  averages the windows' scores and explains them.

  1. `windows/2` - the conversation's unit interactions, a window of at
     most `:window_size` (default 10) ending at each, flattened into turns
  2. `contents/1` - a window as the single-turn judgement sees it: its user
     turns, its assistant turns, and the retrieval context of its assistant
     turns
  3. `measure/3` - scores each window with the metric's judgement, in
     order (deepeval gathers them; one after the other, a scripted judge
     answers them in the same order), averages the scores (`1` without a
     window), writes the final reason from every window's reason and the
     verbose logs
  """

  alias DeepEvalEx.{ConversationalTestCase, LLM.Adapter, Result, Turn}
  alias DeepEvalEx.Metrics.Utils.{Turns, Verbose}
  alias DeepEvalEx.Prompts.EvaluationTemplate

  @default_window_size 10

  @typedoc """
  A window as the single-turn judgement sees it, see `contents/1`.
  """
  @type contents :: %{
          input: String.t(),
          assistant_output: String.t(),
          retrieval_context: [String.t() | DeepEvalEx.Schemas.RetrievedContextData.t()]
        }

  @typedoc """
  A window's outcome, deepeval's `Interaction*Score`: its score (a float,
  as pydantic stores it), its reason and the lines its verbose logs show
  after `"Window <n> \\n"`; any other key is kept in the result's metadata.
  """
  @type window_score :: %{
          required(:score) => float(),
          required(:reason) => String.t() | nil,
          required(:steps) => [String.t()],
          optional(atom()) => term()
        }

  @doc """
  The conversation's sliding windows of unit interactions, each flattened
  into its turns (`DeepEvalEx.Metrics.Utils.Turns`).

  ## Options

  - `:window_size` - the most unit interactions in a window (default: 10)
  """
  @spec windows(ConversationalTestCase.t(), keyword()) :: [[Turn.t()]]
  def windows(%ConversationalTestCase{turns: turns}, opts) do
    turns
    |> Turns.get_unit_interactions()
    |> Turns.get_turns_in_sliding_window(Keyword.get(opts, :window_size, @default_window_size))
    |> Enum.map(&Enum.concat/1)
  end

  @doc """
  A window's user turns, each as `"\\n<content> "`, its assistant turns,
  each as `"\\n<content>"`, and the retrieval context of its assistant
  turns, in order, as deepeval's metrics build them.

  ## Examples

      iex> window = [
      ...>   DeepEvalEx.Turn.new!(role: :user, content: "Hi"),
      ...>   DeepEvalEx.Turn.new!(role: :assistant, content: "Hello!", retrieval_context: ["Greet."])
      ...> ]
      iex> DeepEvalEx.Metrics.Utils.TurnWindows.contents(window)
      %{input: "\\nHi ", assistant_output: "\\nHello!", retrieval_context: ["Greet."]}
  """
  @spec contents([Turn.t()]) :: contents()
  def contents(window) do
    Enum.reduce(window, %{input: "", assistant_output: "", retrieval_context: []}, fn
      %Turn{role: :user, content: content}, acc ->
        %{acc | input: acc.input <> "\n#{content} "}

      %Turn{content: content, retrieval_context: retrieval_context}, acc ->
        %{
          acc
          | assistant_output: acc.assistant_output <> "\n#{content}",
            retrieval_context: acc.retrieval_context ++ (retrieval_context || [])
        }
    end)
  end

  @doc """
  Measures `test_case` window by window with `score_window`, a function of
  a window's `t:contents/0` that returns `{:ok, t:window_score/0}` or an
  error, which stops the measure.

  The score is the mean of the windows' scores (a float), or the integer
  `1` without a window; it passes at the threshold or above. With
  `:include_reason` (the default) the judge explains it from every
  window's reason (the template's `generate_final_reason`), unless there is
  no window, which deepeval explains as `"There were no retrieval contexts
  in your turns to evaluate, hence the score is 1"`. The verbose logs show
  each window's steps and the final score.

  `:strict_mode` clamps each window's score (`score_window` applies it),
  never the mean, as in deepeval: the result is `:strict_applied`, so a
  strict mean of `0.5` stays `0.5` and fails the threshold of `1`.

  ## Spec

  - `:score_window` - the window judgement, see above
  - `:metric_name` - the result's metric name
  - `:threshold` - the metric's threshold
  - `:template` - the prompt module of `generate_final_reason`
  - `:schema` - the module whose `reason_schema/0` and `parse_reason/1`
    ask for and read the final reason
  """
  @spec measure(keyword(), ConversationalTestCase.t(), keyword()) ::
          {:ok, Result.t()} | {:error, term()}
  def measure(spec, test_case, opts) do
    score_window = Keyword.fetch!(spec, :score_window)
    threshold = Keyword.fetch!(spec, :threshold)

    with {:ok, scores} <- score_windows(windows(test_case, opts), score_window),
         score = calculate_score(scores),
         {:ok, reason} <- final_reason(spec, score, score >= threshold, scores, opts) do
      verbose_logs =
        Verbose.construct_verbose_logs(
          Keyword.fetch!(spec, :metric_name),
          verbose_steps(scores) ++
            [
              "Final Score: #{Verbose.to_str(score)}\n",
              "Final Reason: #{Verbose.to_str(reason)}\n"
            ],
          opts
        )

      {:ok,
       Result.new(
         metric: Keyword.fetch!(spec, :metric_name),
         score: score,
         threshold: threshold,
         reason: reason,
         verbose_logs: verbose_logs,
         metadata: %{windows: Enum.map(scores, &Map.delete(&1, :steps))},
         strict_applied: true
       )}
    end
  end

  defp score_windows(windows, score_window) do
    Enum.reduce_while(windows, {:ok, []}, fn window, {:ok, scores} ->
      case score_window.(contents(window)) do
        {:ok, score} -> {:cont, {:ok, [%{score | score: score.score / 1} | scores]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, scores} -> {:ok, Enum.reverse(scores)}
      error -> error
    end
  end

  # deepeval's _calculate_score: the integer 1 without a window.
  defp calculate_score([]), do: 1
  defp calculate_score(scores), do: Enum.sum(Enum.map(scores, & &1.score)) / length(scores)

  # deepeval's _generate_reason.
  defp final_reason(spec, score, success, scores, opts) do
    cond do
      not Keyword.get(opts, :include_reason, true) ->
        {:ok, nil}

      scores == [] ->
        {:ok, "There were no retrieval contexts in your turns to evaluate, hence the score is 1"}

      true ->
        schema = Keyword.fetch!(spec, :schema)

        prompt =
          EvaluationTemplate.render(opts, Keyword.fetch!(spec, :template), :generate_final_reason,
            final_score: score,
            success: success,
            reasons: Enum.map(scores, & &1.reason)
          )

        case Adapter.generate_with_schema(prompt, schema.reason_schema(), opts) do
          {:ok, response} -> schema.parse_reason(response)
          {:error, _} = error -> error
        end
    end
  end

  # deepeval's _get_verbose_steps: each window's steps, counting from 1.
  defp verbose_steps(scores) do
    scores
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {%{steps: steps}, index} -> ["Window #{index} \n" | steps] end)
  end
end
