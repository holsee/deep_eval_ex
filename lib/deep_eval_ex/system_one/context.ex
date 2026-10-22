defmodule DeepEvalEx.SystemOne.Context do
  @moduledoc """
  What a metric measures with, as far as System One is concerned: its
  effective eval mode, its System One model and whether it has an LLM. A
  port of deepeval 4.3.1's `initialize_model` and
  `initialize_system_one_model`, which a metric's constructor runs.

  `resolve!/2` builds it from a metric's options and
  `c:DeepEvalEx.Metrics.BaseMetric.measure/2` passes it to `do_measure/2` as
  `opts[:system_one]`. `DeepEvalEx.Evaluator` resolves it for every metric
  before any of them starts, so a misconfigured System One model fails the
  evaluation up front, as deepeval fails when the metric is built.

  ## Fields

  - `:mode` - the eval mode the metric runs in,
    `DeepEvalEx.SystemOne.Mode.effective/2`: `:system_one` runs as
    `:hybrid` for a metric without `system_one_eval_spec/2`
  - `:model` - the initialised `DeepEvalEx.SystemOne.Model`, `nil` under
    `:llm`, where no System One model is built (so a missing TypeSafe key
    is not an error)
  - `:llm?` - whether the metric has an LLM: `false` under `:system_one`,
    where nothing falls back to the LLM, so no LLM adapter is resolved and
    no LLM key is needed (`initialize_model` returns `(None, True)`)

  A metric whose `c:DeepEvalEx.Metrics.BaseMetric.system_one?/0` returns
  `false` (GEval, ExactMatch) takes no part in System One, as deepeval's
  metrics that never call `initialize_system_one_model`: its context is the
  `:llm` one in every mode, so it keeps its LLM and builds no System One
  model.

  ## Options

  - `:eval_mode` - see `DeepEvalEx.SystemOne.Mode.resolve/1`
  - `:system_one_model` - see `DeepEvalEx.SystemOne.Model.resolve/1`
    (default: the `:system_one_model` application config, else Jev)
  - `:system_one` - an already resolved context, returned as it is
  """

  alias DeepEvalEx.DeepEvalError
  alias DeepEvalEx.SystemOne.{Mode, Model}

  @type t :: %__MODULE__{
          mode: Mode.t(),
          model: Model.t() | nil,
          llm?: boolean()
        }

  defstruct mode: :llm, model: nil, llm?: true

  @typesafe DeepEvalEx.SystemOne.Adapters.TypeSafe

  @doc """
  Resolves the context `metric` (a metric module) measures with under
  `opts`.

  Raises `ArgumentError` for an unrecognised `:eval_mode` or
  `:system_one_model`, and `DeepEvalEx.DeepEvalError` when the model's
  `c:DeepEvalEx.SystemOne.Adapter.init/1` rejects its options, with
  deepeval's text:

      DEEPEVAL_EVAL_MODE=hybrid routes metric decisions to TypeSafe AI Jev,
      but it is not usable: <error> Configure it with `deepeval set-typesafe
      --prompt-api-key` or switch back with `deepeval set-eval-mode llm`.

  (on one line). For a model other than TypeSafe's, the text names the
  model and asks to fix its options instead.

  ## Examples

      iex> DeepEvalEx.SystemOne.Context.resolve!(DeepEvalEx.Metrics.ExactMatch, eval_mode: :llm)
      %DeepEvalEx.SystemOne.Context{mode: :llm, model: nil, llm?: true}
  """
  @spec resolve!(module(), keyword()) :: t()
  def resolve!(metric, opts) when is_atom(metric) and is_list(opts) do
    case Keyword.get(opts, :system_one) do
      %__MODULE__{} = context ->
        context

      _ ->
        if system_one?(metric),
          do: metric |> Mode.effective(opts) |> build(Keyword.get(opts, :system_one_model)),
          else: llm_only(opts)
    end
  end

  # A metric whose system_one?/0 returns false (GEval, ExactMatch) never
  # calls initialize_system_one_model in deepeval: it measures as under :llm
  # in every mode.
  defp system_one?(metric) do
    not (Code.ensure_loaded?(metric) and function_exported?(metric, :system_one?, 0) and
           not metric.system_one?())
  end

  defp llm_only(opts) do
    # Still raises for an unrecognised :eval_mode option.
    Mode.resolve(opts)
    build(:llm, nil)
  end

  defp build(:llm, _model), do: %__MODULE__{mode: :llm, model: nil, llm?: true}

  defp build(mode, spec) do
    model = Model.resolve(spec)

    case Model.init(model) do
      {:ok, model} -> %__MODULE__{mode: mode, model: model, llm?: mode != :system_one}
      {:error, error} -> raise DeepEvalError, message: not_usable(mode, model, error)
    end
  end

  # initialize_system_one_model's message.
  defp not_usable(mode, %Model{adapter: adapter, name: name}, error) do
    {target, fix} =
      if adapter == @typesafe,
        do: {"TypeSafe AI Jev", "Configure it with `deepeval set-typesafe --prompt-api-key`"},
        else: {name, "Fix its options"}

    "DEEPEVAL_EVAL_MODE=#{mode} routes metric decisions to #{target}, but it is not usable: " <>
      "#{Exception.message(error)} #{fix} or switch back with `deepeval set-eval-mode llm`."
  end
end
