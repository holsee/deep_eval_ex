defmodule DeepEvalEx.Dataset.Persona do
  @moduledoc """
  Who the simulated user of a conversation is, deepeval 4.3.1's `Persona`
  (`dataset/golden.py`).

  A persona pairs with a `DeepEvalEx.Dataset.ConversationalGolden`: the
  persona is *who* the user is, while the golden's `:scenario` and
  `:expected_outcome` are *what* they are trying to do. It succeeds the
  golden's deprecated `:user_description`.

  ## Fields

  - `:characteristics` - The free-form persona prompt: demographics,
    personality, speaking style; who the user is, never what they want
    (required)
  - `:name` - The user's name
  - `:metadata` - A map of further details

  deepeval's voice-only settings (`interruption_behavior`, `speaks_first`,
  `muted`, `voice`, `background_noise`, `multilingual_stt`,
  `hold_timeout`), which text simulations ignore, are not ported: `new/1`
  drops them with every other key it does not know, as deepeval's
  `extra="ignore"`.

  ## Examples

      iex> alias DeepEvalEx.Dataset.Persona
      iex> persona = Persona.new!(name: "Ann", characteristics: "A busy parent, short on patience.")
      iex> Persona.prompt_block(persona)
      "<persona>\\nName: Ann\\n\\nA busy parent, short on patience.\\n</persona>"
  """

  import Peri

  alias DeepEvalEx.TestRun.JSON

  @type t :: %__MODULE__{
          name: String.t() | nil,
          characteristics: String.t(),
          metadata: map() | nil
        }

  @enforce_keys [:characteristics]
  defstruct [:name, :characteristics, :metadata]

  @fields ~w(name characteristics metadata)

  defschema(:persona_schema, %{
    name: :string,
    characteristics: {:required, :string},
    metadata: :map
  })

  @doc """
  Creates a persona from a keyword list or a map, with atom or string keys.
  Unknown keys, the voice-only settings among them, are dropped.
  """
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_list(attrs), do: new(Map.new(attrs))

  def new(attrs) when is_map(attrs) do
    case attrs |> normalize_attrs() |> persona_schema() do
      {:ok, validated} -> {:ok, struct(__MODULE__, validated)}
      {:error, _} = err -> err
    end
  end

  @doc """
  Creates a persona, raising on error.
  """
  @spec new!(keyword() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, persona} -> persona
      {:error, errors} -> raise "Invalid persona: #{inspect(errors)}"
    end
  end

  @doc """
  Renders the persona for a simulator prompt, deepeval's `prompt_block()`
  without the voice-only behaviour lines.

  The sections are the name (`"Name: <name>"`, when not empty), the
  trimmed characteristics and the metadata (`"Details:"` and the metadata
  as `json.dumps(metadata, indent=2)` writes it, when not empty), joined
  by blank lines and wrapped in `<persona>` tags. Empty sections are left
  out. The metadata's keys come in map order, where deepeval keeps the
  dict's insertion order.
  """
  @spec prompt_block(t()) :: String.t()
  def prompt_block(%__MODULE__{} = persona) do
    body =
      [
        if(persona.name not in [nil, ""], do: "Name: #{persona.name}"),
        String.trim(persona.characteristics),
        if(persona.metadata not in [nil, %{}],
          do: "Details:\n" <> JSON.encode!(persona.metadata, indent: 2)
        )
      ]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join("\n\n")

    "<persona>\n#{body}\n</persona>"
  end

  @doc false
  # Peri custom validator for a golden's persona: a Persona, or a map or
  # keyword list that builds one.
  @spec cast(term()) :: {:ok, t() | nil} | {:error, String.t(), keyword()}
  def cast(nil), do: {:ok, nil}
  def cast(%__MODULE__{} = persona), do: {:ok, persona}

  def cast(attrs) when (is_map(attrs) and not is_struct(attrs)) or is_list(attrs) do
    case new(attrs) do
      {:ok, persona} ->
        {:ok, persona}

      {:error, errors} ->
        {:error, "invalid persona %{persona}: %{errors}",
         [persona: inspect(attrs), errors: inspect(errors)]}
    end
  end

  def cast(other),
    do:
      {:error, "must be a Persona, a map or a keyword list, got %{value}",
       [value: inspect(other)]}

  defp normalize_attrs(attrs) do
    attrs
    |> Map.new(fn {k, v} -> {key_string(k), v} end)
    |> Map.take(@fields)
    |> Map.new(fn {k, v} -> {String.to_existing_atom(k), v} end)
  end

  defp key_string(key) when is_atom(key), do: Atom.to_string(key)
  defp key_string(key), do: key
end
