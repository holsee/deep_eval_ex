defmodule DeepEvalEx.Test.SystemOneToy do
  @moduledoc """
  A toy third-party `DeepEvalEx.SystemOne.Adapter`, written only against the
  public contract, to show nothing in it is Jev-specific.

  It answers every question from the length of its instructions, needs an
  `:api_key` (`init/1` fails without one, permanently), has its own
  `context_budget/1`, and with `down: true` fails every request with a
  `ConnectionError`.
  """

  use DeepEvalEx.SystemOne.Adapter

  alias DeepEvalEx.LLM.Usage
  alias DeepEvalEx.SystemOne.{Answers, Error, Question}

  @impl true
  def model_name(opts), do: "toy-" <> Keyword.get(opts, :model, "v1")

  @impl true
  def init(opts) do
    if opts[:api_key],
      do: {:ok, opts},
      else:
        {:error,
         %Error{
           reason: :auth,
           type: "DeepEvalError",
           permanent?: true,
           message: "SystemOneToy needs :api_key"
         }}
  end

  @impl true
  def context_budget(_opts), do: {100_000, 200_000}

  @impl true
  def decide(_state, questions, opts) do
    if opts[:down] do
      {:error, %Error{reason: :connection, type: "ConnectionError", message: "toy is down"}}
    else
      {:ok, Enum.reduce(questions, %Answers{}, &answer/2), %Usage{cost: 0.0, input_tokens: 10}}
    end
  end

  defp answer({key, %Question.Noul{} = question}, acc),
    do: put_in(acc.nouls[key], %Answers.Noul{probability: p(question)})

  defp answer({key, %Question.Choice{options: [{first, _} | _] = options}}, acc) do
    rest = 0.4 / max(length(options) - 1, 1)
    probabilities = for {name, _} <- options, do: {name, if(name == first, do: 0.6, else: rest)}

    put_in(acc.choices[key], %Answers.Choice{
      choice: first,
      probabilities: probabilities,
      confidence: 0.6
    })
  end

  defp answer({key, %Question.Score{levels: levels}}, acc) do
    top = length(levels) - 1
    probabilities = for i <- 0..top, do: {i, 1.0 / length(levels)}

    put_in(acc.scores[key], %Answers.Score{
      score: top / 2,
      probabilities: probabilities,
      confidence: 0.5
    })
  end

  defp p(%Question.Noul{instructions: instructions}),
    do: rem(:erlang.phash2(instructions), 100) / 100
end
