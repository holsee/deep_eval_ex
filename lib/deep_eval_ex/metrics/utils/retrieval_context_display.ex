defmodule DeepEvalEx.Metrics.Utils.RetrievalContextDisplay do
  @moduledoc """
  The retrieval context as a multimodal metric's prompt shows it, deepeval
  4.3.1's `metrics/retrieval_context_display.py`.
  """

  alias DeepEvalEx.MLLMImage

  # The placeholder pattern, capturing its kind and id.
  @placeholder ~r/\[DEEPEVAL:(IMAGE|PDF):(.*?)\]/

  @doc """
  The retrieval context split into its text and image nodes, each text
  node prefixed `"Node <n>: "` and each image preceded by a `"Node <n>:"`
  label, numbered across the whole list: deepeval's `id_retrieval_context`
  over `convert_to_multi_modal_array`. Printed as a Python list
  (`DeepEvalEx.Prompts.Python.repr/1`), an image shows as its placeholder.

  An image is looked up in `images` (a map of id to
  `DeepEvalEx.MLLMImage`); an id it does not hold is shown by its
  placeholder as written, where deepeval would build the image from the id
  as a URL first.

  ## Examples

      iex> alias DeepEvalEx.Metrics.Utils.RetrievalContextDisplay
      iex> nodes = RetrievalContextDisplay.id_retrieval_context(["Cats purr. [DEEPEVAL:IMAGE:cat]"], nil)
      iex> DeepEvalEx.Prompts.Python.repr(nodes)
      "['Node 1: Cats purr. ', 'Node 2:', [DEEPEVAL:IMAGE:cat]]"
  """
  @spec id_retrieval_context([String.t()], %{optional(String.t()) => MLLMImage.t()} | nil) ::
          [String.t() | MLLMImage.t()]
  def id_retrieval_context(retrieval_context, images) do
    retrieval_context
    |> Enum.flat_map(&split(&1, images || %{}))
    |> Enum.with_index(1)
    |> Enum.flat_map(fn
      {text, n} when is_binary(text) -> ["Node #{n}: #{text}"]
      {image, n} -> ["Node #{n}:", image]
    end)
  end

  defp split(text, images) do
    @placeholder
    |> Regex.split(text, include_captures: true)
    |> Enum.flat_map(fn
      "" ->
        []

      piece ->
        case Regex.run(~r/\A\[DEEPEVAL:(IMAGE|PDF):(.*?)\]\z/, piece, capture: :all_but_first) do
          [kind, id] -> [Map.get_lazy(images, id, fn -> placeholder_image(kind, id) end)]
          nil -> [piece]
        end
    end)
  end

  defp placeholder_image("PDF", id), do: %MLLMImage{id: id, mime_type: "application/pdf"}
  defp placeholder_image("IMAGE", id), do: %MLLMImage{id: id}
end
