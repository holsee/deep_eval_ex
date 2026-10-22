defmodule DeepEvalEx.LLM.Pricing do
  @moduledoc """
  Per-model token prices used to compute `DeepEvalEx.Result` evaluation costs.

  Prices are USD per 1M tokens. The built-in table mirrors the OpenAI and
  Anthropic prices in deepeval's model registry
  (`deepeval/models/llms/constants.py`). A model that is not priced has a
  `nil` cost: DeepEvalEx never guesses a price, just as deepeval leaves
  `evaluation_cost` as `None` for models it cannot price.

  ## Overriding prices

  Entries in the `:model_pricing` config take precedence over the built-in
  table, so you can price custom, self-hosted or newly released models:

      config :deep_eval_ex,
        model_pricing: %{
          "gpt-4o-mini" => %{input: 0.15, output: 0.60},
          "my-local-llama" => %{input: 0.0, output: 0.0}
        }

  Each entry must be a map with non-negative numeric `:input` and `:output`
  prices. A malformed entry raises an `ArgumentError` naming the model when
  it is looked up, rather than failing obscurely mid-measurement.
  """

  @type price :: %{input: number(), output: number()}

  # USD per 1M tokens, copied from deepeval 4.3.1's OPENAI_MODELS_DATA.
  # Models deepeval lists without a price (e.g. o1-mini) are left out.
  @openai_prices %{
    "gpt-3.5-turbo" => {0.50, 1.50},
    "gpt-3.5-turbo-0125" => {0.50, 1.50},
    "gpt-3.5-turbo-1106" => {1.00, 2.00},
    "gpt-4" => {30.00, 60.00},
    "gpt-4-32k" => {60.00, 120.00},
    "gpt-4-32k-0613" => {60.00, 120.00},
    "gpt-4-0125-preview" => {10.00, 30.00},
    "gpt-4-1106-preview" => {10.00, 30.00},
    "gpt-4-turbo" => {10.00, 30.00},
    "gpt-4-turbo-2024-04-09" => {10.00, 30.00},
    "gpt-4-turbo-preview" => {10.00, 30.00},
    "gpt-4o" => {2.50, 10.00},
    "gpt-4o-2024-05-13" => {2.50, 10.00},
    "gpt-4o-2024-08-06" => {2.50, 10.00},
    "gpt-4o-2024-11-20" => {2.50, 10.00},
    "gpt-4o-mini" => {0.15, 0.60},
    "gpt-4o-mini-2024-07-18" => {0.15, 0.60},
    "gpt-4.1" => {2.00, 8.00},
    "gpt-4.1-mini" => {0.40, 1.60},
    "gpt-4.1-nano" => {0.10, 0.40},
    "gpt-4.5-preview" => {75.00, 150.00},
    "gpt-4.5-preview-2025-02-27" => {75.00, 150.00},
    "o1" => {15.00, 60.00},
    "o1-2024-12-17" => {15.00, 60.00},
    "o1-preview" => {15.00, 60.00},
    "o1-preview-2024-09-12" => {15.00, 60.00},
    "o3-mini" => {1.10, 4.40},
    "o3-mini-2025-01-31" => {1.10, 4.40},
    "o4-mini" => {1.10, 4.40},
    "o4-mini-2025-04-16" => {1.10, 4.40},
    "gpt-5" => {1.25, 10.00},
    "gpt-5-2025-08-07" => {1.25, 10.00},
    "gpt-5-chat-latest" => {1.25, 10.00},
    "gpt-5-mini" => {0.25, 2.00},
    "gpt-5-mini-2025-08-07" => {0.25, 2.00},
    "gpt-5-nano" => {0.05, 0.40},
    "gpt-5-nano-2025-08-07" => {0.05, 0.40},
    "gpt-5.1" => {1.25, 10.00},
    "gpt-5.2" => {1.75, 14.00},
    "gpt-5.4" => {2.50, 15.00},
    "gpt-5.4-2026-03-05" => {2.50, 15.00},
    "gpt-5.4-mini" => {0.75, 4.50},
    "gpt-5.5" => {5.00, 30.00},
    "gpt-5.5-2026-04-23" => {5.00, 30.00},
    "gpt-5.6-sol" => {4.00, 20.00},
    "gpt-5.6-terra" => {2.00, 12.00},
    "gpt-5.6-luna" => {0.20, 1.20},
    "gpt-6-astra" => {10.00, 50.00},
    "gpt-6-sol" => {2.00, 10.00},
    "gpt-6-luna" => {0.10, 0.50}
  }

  # USD per 1M tokens, copied from deepeval 4.3.1's ANTHROPIC_MODELS_DATA.
  @anthropic_prices %{
    "claude-3-opus-20240229" => {15.00, 75.00},
    "claude-3-sonnet-20240229" => {3.00, 15.00},
    "claude-3-haiku-20240307" => {0.25, 1.25},
    "claude-3-5-sonnet-20240620" => {3.00, 15.00},
    "claude-3-5-sonnet-20241022" => {3.00, 15.00},
    "claude-3-5-haiku-20241022" => {0.80, 4.00},
    "claude-3-7-sonnet-20250219" => {3.00, 15.00},
    "claude-opus-4-20250514" => {15.00, 75.00},
    "claude-opus-4-1-20250805" => {15.00, 75.00},
    "claude-sonnet-4-20250514" => {3.00, 15.00},
    "claude-sonnet-4-5-20250929" => {3.00, 15.00},
    "claude-haiku-4-5-20251001" => {1.00, 5.00},
    "claude-opus-4-5-20251124" => {5.00, 25.00},
    "claude-opus-4-6-20250610" => {5.00, 25.00},
    "claude-sonnet-4-6-20250514" => {3.00, 15.00},
    "claude-3-opus" => {15.00, 75.00},
    "claude-3-sonnet" => {3.00, 15.00},
    "claude-3-haiku" => {0.25, 1.25},
    "claude-3-5-sonnet" => {3.00, 15.00},
    "claude-3-5-haiku" => {0.80, 4.00},
    "claude-opus-4" => {15.00, 75.00},
    "claude-sonnet-4" => {3.00, 15.00},
    "claude-sonnet-4-5" => {3.00, 15.00},
    "claude-haiku-4-5" => {1.00, 5.00},
    "claude-opus-4-5" => {5.00, 25.00},
    "claude-opus-4-7" => {5.00, 25.00},
    "claude-opus-4-8" => {5.00, 25.00},
    "claude-opus-5" => {5.00, 25.00},
    "claude-opus-5-5" => {4.00, 20.00},
    "claude-sonnet-5" => {2.00, 10.00},
    "claude-fable-5" => {10.00, 50.00},
    "claude-fable-5-1" => {10.00, 50.00},
    "claude-opus-4-6" => {5.00, 25.00},
    "claude-sonnet-4-6" => {3.00, 15.00},
    "claude-3-7-sonnet-latest" => {3.00, 15.00},
    "claude-3-5-sonnet-latest" => {3.00, 15.00},
    "claude-3-5-haiku-latest" => {0.80, 4.00},
    "claude-3-opus-latest" => {15.00, 75.00}
  }

  @prices Map.merge(@openai_prices, @anthropic_prices)

  @doc """
  Returns the per-1M-token price of `model`, or `nil` when it is not priced.

  The `:model_pricing` config is consulted before the built-in table. Raises
  `ArgumentError` when the config is not a map or the model's entry is not a
  valid price.

  ## Examples

      iex> DeepEvalEx.LLM.Pricing.price("gpt-4o-mini")
      %{input: 0.15, output: 0.6}

      iex> DeepEvalEx.LLM.Pricing.price("unknown-model")
      nil
  """
  @spec price(String.t() | nil) :: price() | nil
  def price(nil), do: nil

  def price(model) when is_binary(model) do
    case Map.fetch(overrides(), model) do
      {:ok, price} ->
        validate_price!(model, price)

      :error ->
        case Map.fetch(@prices, model) do
          {:ok, {input, output}} -> %{input: input, output: output}
          :error -> nil
        end
    end
  end

  defp overrides do
    case Application.get_env(:deep_eval_ex, :model_pricing, %{}) do
      overrides when is_map(overrides) ->
        overrides

      other ->
        raise ArgumentError,
              ":model_pricing must be a map of model name to " <>
                "%{input: number, output: number} (USD per 1M tokens), got: #{inspect(other)}"
    end
  end

  defp validate_price!(_model, %{input: input, output: output} = price)
       when is_number(input) and input >= 0 and is_number(output) and output >= 0,
       do: price

  defp validate_price!(model, price) do
    raise ArgumentError,
          ":model_pricing entry for #{inspect(model)} must be " <>
            "%{input: number, output: number} with non-negative USD prices per 1M tokens, " <>
            "got: #{inspect(price)}"
  end

  @doc """
  Returns the USD cost of a call to `model`, or `nil` when the model is not
  priced or a token count is unknown.

  ## Examples

      iex> DeepEvalEx.LLM.Pricing.cost("gpt-4o-mini", 1_000_000, 0)
      0.15

      iex> DeepEvalEx.LLM.Pricing.cost("unknown-model", 100, 50)
      nil
  """
  @spec cost(String.t() | nil, non_neg_integer() | nil, non_neg_integer() | nil) ::
          float() | nil
  def cost(_model, nil, _output_tokens), do: nil
  def cost(_model, _input_tokens, nil), do: nil

  def cost(model, input_tokens, output_tokens) do
    case price(model) do
      %{input: input, output: output} ->
        (input_tokens * input + output_tokens * output) / 1_000_000

      nil ->
        nil
    end
  end
end
