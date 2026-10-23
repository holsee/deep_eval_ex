defmodule DeepEvalEx.LLM.Multimodal do
  @moduledoc """
  Multimodal prompt content for the judge adapters, deepeval 4.3.1's
  `models/llms/multimodal.py` and the `_prompt_content` /
  `_prompt_messages` of its OpenAI, Anthropic and Ollama models.

  A metric's prompt is a string. When the test case holds images, their
  placeholders (`[DEEPEVAL:IMAGE:<id>]`, see `DeepEvalEx.MLLMImage`) appear
  in it, and the metric passes the test case's images to the adapter as
  the `:images` option (a map of id to image). Each adapter then splits
  the prompt at the placeholders (`parts/2`) and sends the text and the
  images in its API's shape:

  - OpenAI (`openai_content/2`): `text` and `image_url` content parts; a
    local or base64 image as a `data:` URI, a remote one as its URL
  - Anthropic (`anthropic_content/2`): `text` and `image` content blocks;
    a remote image as a `url` source, any other as a `base64` source
  - Ollama (`ollama_messages/3`): one user message per piece, the text as
    its `content`, an image as its base64 `images`; a remote image is
    downloaded first

  A prompt without placeholders is sent as before, the prompt string as
  the user message's content. deepeval's audio parts are not ported.
  """

  alias DeepEvalEx.MLLMImage

  @type images :: %{optional(String.t()) => MLLMImage.t()} | nil

  @doc """
  The prompt split at its placeholders into text and images, or `nil`
  when it holds none, deepeval's `multimodal_parts` (without audio). An
  unknown id is taken as the image's URL, see `DeepEvalEx.MLLMImage.parse/2`.

  ## Examples

      iex> DeepEvalEx.LLM.Multimodal.parts("No images", %{})
      nil
  """
  @spec parts(String.t(), images()) :: [String.t() | MLLMImage.t()] | nil
  def parts(prompt, images) when is_binary(prompt) do
    if MLLMImage.multimodal?(prompt), do: MLLMImage.parse(prompt, images)
  end

  @doc """
  The content of an OpenAI chat message for `prompt`, deepeval's
  `to_openai_content` (without inlining remote images): the prompt itself
  when it holds no placeholder, else a list of `text` and `image_url`
  parts.

  ## Examples

      iex> image = DeepEvalEx.MLLMImage.new!(data_base64: "AAAA", mime_type: "image/png", id: "dot")
      iex> DeepEvalEx.LLM.Multimodal.openai_content("See \#{image}", %{"dot" => image})
      [
        %{type: "text", text: "See "},
        %{type: "image_url", image_url: %{url: "data:image/png;base64,AAAA"}}
      ]
  """
  @spec openai_content(String.t(), images()) :: String.t() | [map()]
  def openai_content(prompt, images) do
    case parts(prompt, images) do
      nil -> prompt
      parts -> Enum.map(parts, &openai_part/1)
    end
  end

  defp openai_part(text) when is_binary(text), do: %{type: "text", text: text}

  defp openai_part(%MLLMImage{} = image) do
    url =
      if MLLMImage.remote?(image) do
        image.url
      else
        image = MLLMImage.ensure_loaded(image)
        "data:#{image.mime_type};base64,#{image.data_base64}"
      end

    %{type: "image_url", image_url: %{url: url}}
  end

  @doc """
  The content of an Anthropic message for `prompt`, deepeval's
  `AnthropicModel._prompt_content`: the prompt itself when it holds no
  placeholder, else a list of `text` and `image` blocks. A base64 or
  local image without a mime type is sent as `image/jpeg`.

  ## Examples

      iex> image = DeepEvalEx.MLLMImage.new!(url: "https://example.com/cat.png", id: "cat")
      iex> DeepEvalEx.LLM.Multimodal.anthropic_content("\#{image}?", %{"cat" => image})
      [
        %{type: "image", source: %{type: "url", url: "https://example.com/cat.png"}},
        %{type: "text", text: "?"}
      ]
  """
  @spec anthropic_content(String.t(), images()) :: String.t() | [map()]
  def anthropic_content(prompt, images) do
    case parts(prompt, images) do
      nil -> prompt
      parts -> Enum.map(parts, &anthropic_part/1)
    end
  end

  defp anthropic_part(text) when is_binary(text), do: %{type: "text", text: text}

  defp anthropic_part(%MLLMImage{} = image) do
    if MLLMImage.remote?(image) do
      %{type: "image", source: %{type: "url", url: image.url}}
    else
      image = MLLMImage.ensure_loaded(image)

      %{
        type: "image",
        source: %{
          type: "base64",
          media_type: image.mime_type || "image/jpeg",
          data: image.data_base64
        }
      }
    end
  end

  @doc """
  The messages of an Ollama chat request for `prompt`, deepeval's
  `OllamaModel._prompt_messages`: one user message holding the prompt
  when it has no placeholder, else one user message per piece, a text's
  `content` or an image's base64 `images`.

  A remote image is downloaded with `Req.get/2` and `req_options` (the
  adapter's `:req_options`) and sent as the bytes it served. deepeval
  re-encodes it as a JPEG with Pillow first; DeepEvalEx has no image
  library, so it sends the image as it is. A failed download is
  `{:error, {:image_fetch_failed, url, reason}}`.
  """
  @spec ollama_messages(String.t(), images(), keyword()) ::
          {:ok, [map()]} | {:error, {:image_fetch_failed, String.t(), term()}}
  def ollama_messages(prompt, images, req_options \\ []) do
    case parts(prompt, images) do
      nil ->
        {:ok, [%{role: "user", content: prompt}]}

      parts ->
        parts
        |> Enum.reduce_while({:ok, []}, &add_ollama_message(&1, &2, req_options))
        |> case do
          {:ok, messages} -> {:ok, Enum.reverse(messages)}
          error -> error
        end
    end
  end

  defp add_ollama_message(part, {:ok, messages}, req_options) do
    case ollama_message(part, req_options) do
      {:ok, message} -> {:cont, {:ok, [message | messages]}}
      {:error, _} = error -> {:halt, error}
    end
  end

  defp ollama_message(text, _req_options) when is_binary(text),
    do: {:ok, %{role: "user", content: text}}

  defp ollama_message(%MLLMImage{} = image, req_options) do
    if MLLMImage.remote?(image) do
      with {:ok, {bytes, _mime}} <- fetch_remote_image(image, req_options),
           do: {:ok, %{role: "user", images: [Base.encode64(bytes)]}}
    else
      {:ok, %{role: "user", images: [MLLMImage.ensure_loaded(image).data_base64]}}
    end
  end

  @doc """
  Downloads a remote image, deepeval's `fetch_remote_image`: its bytes and
  mime type (the response's `content-type`, else the image's, else
  `"image/jpeg"`). `req_options` are merged into the `Req.get/2` call.
  """
  @spec fetch_remote_image(MLLMImage.t(), keyword()) ::
          {:ok, {binary(), String.t()}} | {:error, {:image_fetch_failed, String.t(), term()}}
  def fetch_remote_image(%MLLMImage{url: url} = image, req_options \\ []) do
    case Req.get(url, Keyword.merge([decode_body: false, retry: false], req_options)) do
      {:ok, %Req.Response{status: status, body: body} = response} when status in 200..299 ->
        mime =
          case Req.Response.get_header(response, "content-type") do
            [type | _] -> type
            [] -> image.mime_type || "image/jpeg"
          end

        {:ok, {body, mime}}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:image_fetch_failed, url, {:http_status, status}}}

      {:error, exception} ->
        {:error, {:image_fetch_failed, url, exception}}
    end
  end
end
