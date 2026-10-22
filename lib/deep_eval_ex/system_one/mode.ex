defmodule DeepEvalEx.SystemOne.Mode do
  @moduledoc """
  Resolves who decides in an LLM-as-a-judge metric, as deepeval 4.3.1's
  `config/eval_mode.py`.

  - `:llm` - the evaluation LLM runs the whole chain (extraction, decision,
    reason). The default.
  - `:hybrid` - the LLM extracts and writes the reason, and a System One
    model answers the decision points wired for it. A System One call that
    fails at runtime hands that one decision back to the LLM.
  - `:system_one` - the System One model runs the whole metric as one
    request and the reason is deterministic. No LLM is built or called, and
    nothing falls back.

  ## Precedence

  `resolve/1` takes the metric's `:eval_mode` option first, then
  `DeepEvalEx.Config.get(:eval_mode)` (the `:eval_mode` application config,
  then `DEEPEVAL_EVAL_MODE`), then `:llm`. Every value is read
  case-insensitively with surrounding whitespace ignored (`normalize/1`).
  An unrecognised `:eval_mode` option raises, since the caller typed it; an
  unrecognised setting counts as unset, so it never breaks loading.

  Gate code on the resolved atom (or `uses_system_one?/1`), never by
  comparing strings.
  """

  alias DeepEvalEx.Config
  alias DeepEvalEx.Prompts.Python

  @typedoc "An eval mode."
  @type t :: :llm | :hybrid | :system_one

  @modes [:llm, :hybrid, :system_one]

  @doc """
  The eval modes, in deepeval's order.

  ## Examples

      iex> DeepEvalEx.SystemOne.Mode.modes()
      [:llm, :hybrid, :system_one]
  """
  @spec modes() :: [t(), ...]
  def modes, do: @modes

  @doc """
  The mode a raw value names, or `nil` when it is unset, blank or
  unrecognised, as deepeval's `normalize_eval_mode`.

  Strings and atoms are read case-insensitively with surrounding whitespace
  ignored. There are no alternative spellings.

  ## Examples

      iex> DeepEvalEx.SystemOne.Mode.normalize(" Hybrid ")
      :hybrid

      iex> DeepEvalEx.SystemOne.Mode.normalize("system-one")
      nil
  """
  @spec normalize(term()) :: t() | nil
  def normalize(mode) when mode in @modes, do: mode

  def normalize(value) when (is_binary(value) or is_atom(value)) and not is_nil(value) do
    text = value |> to_string() |> String.trim() |> String.downcase()
    Enum.find(@modes, &(Atom.to_string(&1) == text))
  end

  def normalize(_value), do: nil

  @doc """
  The eval mode for a metric, as deepeval's `resolve_eval_mode`.

  Takes the metric's options (reading `:eval_mode`) or the `:eval_mode`
  value itself. A `nil` value falls through to the setting, then `:llm`
  (see the moduledoc).

  Raises `ArgumentError` for an unrecognised `:eval_mode`, with deepeval's
  message.

  ## Examples

      iex> DeepEvalEx.SystemOne.Mode.resolve(eval_mode: "SYSTEM_ONE")
      :system_one

      iex> DeepEvalEx.SystemOne.Mode.resolve(:hybrid)
      :hybrid
  """
  @spec resolve(keyword() | term()) :: t()
  def resolve(opts) when is_list(opts), do: opts |> Keyword.get(:eval_mode) |> resolve()

  def resolve(nil), do: Config.get(:eval_mode) || :llm

  def resolve(override) do
    normalize(override) ||
      raise ArgumentError,
            "Unsupported eval_mode #{Python.repr(override)}. " <>
              "Valid values: #{Enum.join(@modes, ", ")}."
  end

  @doc """
  `resolve/1` for a classifier, as deepeval's
  `resolve_classifier_eval_mode`.

  A classifier is already one Choice over its labels, so it has no LLM
  extraction for `:hybrid` to keep: `:hybrid`, from the option or the
  setting, runs it as `:llm`.

  ## Examples

      iex> DeepEvalEx.SystemOne.Mode.for_classifier(eval_mode: :hybrid)
      :llm
  """
  @spec for_classifier(keyword() | term()) :: :llm | :system_one
  def for_classifier(opts) do
    case resolve(opts) do
      :hybrid -> :llm
      mode -> mode
    end
  end

  @doc """
  Whether any System One call can happen in `mode`: every mode but `:llm`.

  ## Examples

      iex> DeepEvalEx.SystemOne.Mode.uses_system_one?(:hybrid)
      true

      iex> DeepEvalEx.SystemOne.Mode.uses_system_one?(:llm)
      false
  """
  @spec uses_system_one?(t()) :: boolean()
  def uses_system_one?(mode) when mode in @modes, do: mode != :llm

  @doc """
  The mode `metric` actually runs in, as deepeval's `effective_eval_mode`.

  `mode_or_opts` is what `resolve/1` takes. A metric that cannot run as one
  System One request runs `:system_one` as `:hybrid`: System One at its
  decision points, the LLM covering a failed call. A metric can run as one
  request when its module exports `system_one_eval_spec/2` (deepeval's
  `has_whole_metric_form`), even if the callback returns `nil` for every
  test case, as a metric with its own System One decisions does.

  ## Examples

      iex> DeepEvalEx.SystemOne.Mode.effective(Enum, eval_mode: :system_one)
      :hybrid
  """
  @spec effective(module(), keyword() | term()) :: t()
  def effective(metric, mode_or_opts) when is_atom(metric) do
    case resolve(mode_or_opts) do
      :system_one -> if whole_metric_form?(metric), do: :system_one, else: :hybrid
      mode -> mode
    end
  end

  defp whole_metric_form?(metric) do
    Code.ensure_loaded?(metric) and function_exported?(metric, :system_one_eval_spec, 2)
  end
end
