defmodule DeepEvalEx.MLLMImage do
  @moduledoc """
  An image (or PDF) in a test case, deepeval 4.3.1's `MLLMImage`
  (`test_case/llm_test_case.py`).

  A test case's text fields stay strings: an image goes in as its
  placeholder, `[DEEPEVAL:IMAGE:<id>]` (`[DEEPEVAL:PDF:<id>]` for a PDF),
  which `to_string/1` (and so string interpolation) gives, as deepeval's
  `str()` and f-strings do. The judge adapters replace each placeholder by
  the image itself (see `DeepEvalEx.LLM.Multimodal`).

  deepeval keeps every image it creates in a process-wide registry, which
  the placeholders are looked up in. DeepEvalEx keeps no global state: the
  test case carries its images instead, in its `:images` field
  (`DeepEvalEx.TestCase` and `DeepEvalEx.ConversationalTestCase`), and the
  metrics pass them to the judge with the prompt.

      image = DeepEvalEx.MLLMImage.new!(url: "https://example.com/cat.png")

      DeepEvalEx.TestCase.new!(
        input: "What animal is in \#{image}?",
        actual_output: "A cat.",
        images: [image]
      )

  ## Sources

  `new/1` takes exactly what deepeval's constructor takes:

  - `:url` - a local file path (or `file://` URL), whose bytes are read
    into `:data_base64` and whose `:filename` and `:mime_type` (guessed
    from the extension, else `"image/jpeg"`) are derived; or an `http://`
    or `https://` URL, which is not downloaded, with the `:filename` and
    `:mime_type` (`nil` when the extension is unknown) of its path
  - `:data_base64` and `:mime_type` - the image's bytes, base64-encoded

  `:local` is derived from `:url`, and, when given, must agree with it.
  `:id` defaults to a random 32-character hex string, as deepeval's
  `uuid4().hex`.

  ## Export

  A test run exports the images a test case's placeholders name as its
  `imagesMapping`, each as `to_dump/1` writes it (deepeval's dataclass
  dump: `dataBase64`, `mimeType`, `url`, `local`, `filename` and `_id`,
  leaving out what is `nil`). `new/1` reads that shape back.
  """

  @enforce_keys [:id]
  defstruct [:data_base64, :mime_type, :url, :local, :filename, :id]

  @type t :: %__MODULE__{
          data_base64: String.t() | nil,
          mime_type: String.t() | nil,
          url: String.t() | nil,
          local: boolean() | nil,
          filename: String.t() | nil,
          id: String.t()
        }

  # deepeval's placeholder pattern (check_if_multimodal, set_is_multimodal,
  # parse_multimodal_string and _get_images_mapping).
  @placeholder ~r/\[DEEPEVAL:(?:IMAGE|PDF):(.*?)\]/
  @whole_placeholder ~r/\A\[DEEPEVAL:(?:IMAGE|PDF):(.*?)\]\z/

  # deepeval's field names (the dataclass dump) and DeepEvalEx's, by field.
  @key_aliases [
    data_base64: ["dataBase64", "data_base64"],
    mime_type: ["mimeType", "mime_type"],
    url: ["url"],
    local: ["local"],
    filename: ["filename"],
    id: ["_id", "id"]
  ]

  @doc """
  Creates an image, as deepeval's `MLLMImage(...)` (see "Sources" above).
  Keys may be atoms or strings, deepeval's names (`dataBase64`, `mimeType`,
  `_id`) or DeepEvalEx's.

  Returns `{:error, message}` with deepeval's message where deepeval
  raises: neither `:url` nor `:data_base64` given, `:data_base64` without
  `:mime_type`, a `:local` that disagrees with the `:url`, a local file
  that cannot be read, or a URL that is neither local nor `http(s)://`.

  ## Examples

      iex> {:ok, image} = DeepEvalEx.MLLMImage.new(data_base64: "AAAA", mime_type: "image/png", id: "dot")
      iex> to_string(image)
      "[DEEPEVAL:IMAGE:dot]"

      iex> DeepEvalEx.MLLMImage.new(url: "cat.png")
      {:error, "Invalid remote URL format: cat.png. URL must start with http:// or https://"}
  """
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, String.t()}
  def new(attrs) when is_list(attrs), do: new(Map.new(attrs))

  def new(attrs) when is_map(attrs) do
    attrs = normalize_attrs(attrs)
    image = struct(__MODULE__, Map.put_new_lazy(attrs, :id, &random_id/0))

    cond do
      # deepeval's `not self.url and not self.dataBase64`: "" is missing too.
      image.url in [nil, ""] and image.data_base64 in [nil, ""] ->
        {:error,
         "You must provide either a 'url' or both 'dataBase64' and 'mimeType' to create an MLLMImage."}

      not is_nil(image.data_base64) ->
        if is_nil(image.mime_type),
          do: {:error, "mimeType must be provided when initializing from Base64 data."},
          else: {:ok, image}

      true ->
        from_url(image)
    end
  end

  @doc """
  Creates an image, raising `ArgumentError` where `new/1` returns an error.
  """
  @spec new!(keyword() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, image} -> image
      {:error, message} -> raise ArgumentError, message
    end
  end

  @doc """
  The image's placeholder, deepeval's `_placeholder()`:
  `[DEEPEVAL:PDF:<id>]` for an `application/pdf`, else
  `[DEEPEVAL:IMAGE:<id>]`.
  """
  @spec placeholder(t()) :: String.t()
  def placeholder(%__MODULE__{mime_type: "application/pdf", id: id}), do: "[DEEPEVAL:PDF:#{id}]"
  def placeholder(%__MODULE__{id: id}), do: "[DEEPEVAL:IMAGE:#{id}]"

  @doc """
  Whether `text` holds a placeholder, deepeval's `check_if_multimodal`.
  `nil` holds none.

  ## Examples

      iex> DeepEvalEx.MLLMImage.multimodal?("Look: [DEEPEVAL:IMAGE:abc]")
      true

      iex> DeepEvalEx.MLLMImage.multimodal?("No image here")
      false
  """
  @spec multimodal?(String.t() | nil) :: boolean()
  def multimodal?(text) when is_binary(text), do: Regex.match?(@placeholder, text)
  def multimodal?(nil), do: false

  @doc """
  The ids the placeholders in `text` name, in order, deepeval's
  `re.findall` of the placeholder pattern.

  ## Examples

      iex> DeepEvalEx.MLLMImage.ids("[DEEPEVAL:IMAGE:a] and [DEEPEVAL:PDF:b]")
      ["a", "b"]
  """
  @spec ids(String.t() | nil) :: [String.t()]
  def ids(text) when is_binary(text),
    do: @placeholder |> Regex.scan(text, capture: :all_but_first) |> List.flatten()

  def ids(nil), do: []

  @doc """
  Splits `text` at its placeholders into text and images, deepeval's
  `MLLMImage.parse_multimodal_string`: each placeholder becomes the image
  `images` (a map of id to image) holds for its id, and the text around
  them stays, without empty pieces.

  As in deepeval, an id `images` does not hold is taken as the image's URL
  (`new!(url: id, id: id)`), which raises `ArgumentError` unless it is a
  local path or an `http(s)://` URL.

  ## Examples

      iex> image = DeepEvalEx.MLLMImage.new!(data_base64: "AAAA", mime_type: "image/png", id: "dot")
      iex> DeepEvalEx.MLLMImage.parse("A \#{image}.", %{"dot" => image})
      ["A ", image, "."]
  """
  @spec parse(String.t(), %{optional(String.t()) => t()} | nil) :: [String.t() | t()]
  def parse(text, images) when is_binary(text) do
    images = images || %{}

    @placeholder
    |> Regex.split(text, include_captures: true)
    |> Enum.flat_map(fn
      "" ->
        []

      piece ->
        case Regex.run(@whole_placeholder, piece, capture: :all_but_first) do
          [id] -> [lookup(id, images)]
          nil -> [piece]
        end
    end)
  end

  defp lookup(id, images) do
    case Map.fetch(images, id) do
      {:ok, image} -> image
      :error -> new!(url: id, id: id)
    end
  end

  @doc """
  The image with its `:data_base64` read from its local file when it has
  none, deepeval's `ensure_images_loaded`. A remote or base64 image is
  returned as it is.
  """
  @spec ensure_loaded(t()) :: t()
  def ensure_loaded(%__MODULE__{local: true, data_base64: nil, url: url} = image),
    do: %{image | data_base64: url |> process_url() |> File.read!() |> Base.encode64()}

  def ensure_loaded(%__MODULE__{} = image), do: image

  @doc """
  The image as a `data:` URI, or `nil` without base64 data or a mime type,
  deepeval's `as_data_uri()`.

  ## Examples

      iex> image = DeepEvalEx.MLLMImage.new!(data_base64: "AAAA", mime_type: "image/png")
      iex> DeepEvalEx.MLLMImage.as_data_uri(image)
      "data:image/png;base64,AAAA"
  """
  @spec as_data_uri(t()) :: String.t() | nil
  def as_data_uri(%__MODULE__{data_base64: data, mime_type: mime})
      when is_binary(data) and data != "" and is_binary(mime) and mime != "",
      do: "data:#{mime};base64,#{data}"

  def as_data_uri(%__MODULE__{}), do: nil

  @doc """
  Whether the image is fetched by URL rather than sent as data: an
  `http(s)://` image deepeval did not read (`image.url and not
  image.local`).
  """
  @spec remote?(t()) :: boolean()
  def remote?(%__MODULE__{url: url, local: local}), do: is_binary(url) and url != "" and !local

  @doc """
  The image as a test run's `imagesMapping` holds it, deepeval's dump of
  the dataclass: `dataBase64`, `mimeType`, `url`, `local`, `filename` and
  `_id`, in that order, leaving out the `nil` ones.

  ## Examples

      iex> image = DeepEvalEx.MLLMImage.new!(data_base64: "AAAA", mime_type: "image/png", id: "dot")
      iex> image |> DeepEvalEx.MLLMImage.to_dump() |> Jason.encode!()
      ~S({"dataBase64":"AAAA","mimeType":"image/png","_id":"dot"})
  """
  @spec to_dump(t()) :: Jason.OrderedObject.t()
  def to_dump(%__MODULE__{} = image) do
    [
      {"dataBase64", image.data_base64},
      {"mimeType", image.mime_type},
      {"url", image.url},
      {"local", image.local},
      {"filename", image.filename},
      {"_id", image.id}
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Jason.OrderedObject.new()
  end

  @doc """
  The images of `images` that the placeholders of `texts` name, as
  `[{id, image}]` in the order the placeholders first appear, or `nil`
  when there are none: deepeval's `_get_images_mapping`. Ids `images` does
  not hold are left out, and so is anything in `texts` that is not a
  string.
  """
  @spec mapping([term()], %{optional(String.t()) => t()} | nil) :: [{String.t(), t()}] | nil
  def mapping(texts, images) do
    images = images || %{}

    texts
    |> Enum.flat_map(fn text -> if is_binary(text), do: ids(text), else: [] end)
    |> Enum.uniq()
    |> Enum.flat_map(fn id ->
      case Map.fetch(images, id) do
        {:ok, image} -> [{id, image}]
        :error -> []
      end
    end)
    |> case do
      [] -> nil
      pairs -> pairs
    end
  end

  @doc false
  # The images of a test case's `:images` option, a list or a map of
  # images (or of attributes `new/1` takes), as a map of id to image.
  @spec cast_images(term()) ::
          {:ok, %{optional(String.t()) => t()}} | {:error, String.t(), keyword()}
  def cast_images(images) when is_map(images) and not is_struct(images),
    do: images |> Map.values() |> cast_images()

  def cast_images(images) when is_list(images) do
    Enum.reduce_while(images, {:ok, %{}}, fn image, {:ok, acc} ->
      case cast_image(image) do
        {:ok, image} -> {:cont, {:ok, Map.put(acc, image.id, image)}}
        {:error, message} -> {:halt, {:error, "invalid image: %{message}", [message: message]}}
      end
    end)
  end

  def cast_images(other),
    do: {:error, "expected a list of images, got %{images}", [images: inspect(other)]}

  defp cast_image(%__MODULE__{} = image), do: {:ok, image}
  defp cast_image(attrs) when is_map(attrs) or is_list(attrs), do: new(attrs)
  defp cast_image(other), do: {:error, "expected an MLLMImage, got #{inspect(other)}"}

  defp from_url(%__MODULE__{url: url, local: given_local} = image) do
    local = local_path?(url)

    cond do
      not is_nil(given_local) and given_local != local ->
        {:error, "Local path mismatch"}

      local ->
        from_local(%{image | local: true})

      String.starts_with?(url, ["http://", "https://"]) ->
        filename = url |> URI.parse() |> Map.get(:path) |> basename()
        {:ok, %{image | local: false, filename: filename, mime_type: guess_mime(filename)}}

      true ->
        {:error, "Invalid remote URL format: #{url}. URL must start with http:// or https://"}
    end
  end

  defp from_local(%__MODULE__{url: url} = image) do
    path = process_url(url)
    image = %{image | filename: basename(path), mime_type: guess_mime(path) || "image/jpeg"}

    case File.read(path) do
      {:ok, bytes} -> {:ok, %{image | data_base64: Base.encode64(bytes)}}
      {:error, _reason} -> {:error, "Image file not found: #{path}"}
    end
  end

  # deepeval's is_local_path: an existing path, or a file:// URL of one.
  defp local_path?(url), do: File.exists?(url) or File.exists?(file_url_path(url) || "")

  # deepeval's process_url: an existing path as it is, a file:// URL as its
  # unquoted path, anything else as it is.
  defp process_url(url) do
    if File.exists?(url), do: url, else: file_url_path(url) || url
  end

  defp file_url_path(url) do
    case URI.parse(url) do
      %URI{scheme: "file", host: host, path: path} when host in [nil, ""] ->
        URI.decode(path || "")

      %URI{scheme: "file", host: host, path: path} ->
        URI.decode("//#{host}#{path}")

      _other ->
        nil
    end
  end

  # Python's os.path.basename: what follows the last slash, so "" for a
  # path ending in one.
  defp basename(nil), do: ""
  defp basename(path), do: path |> String.split("/") |> List.last()

  # Python's mimetypes.guess_type: nil for an unknown extension.
  defp guess_mime(path) do
    case MIME.from_path(path) do
      "application/octet-stream" -> nil
      mime -> mime
    end
  end

  defp random_id, do: 16 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

  defp normalize_attrs(attrs) do
    attrs = Map.new(attrs, fn {key, value} -> {to_string(key), value} end)

    Enum.flat_map(@key_aliases, fn {field, aliases} ->
      case Enum.find(aliases, &Map.has_key?(attrs, &1)) do
        nil -> []
        key -> [{field, Map.fetch!(attrs, key)}]
      end
    end)
    |> Map.new()
  end

  defimpl String.Chars do
    def to_string(image), do: DeepEvalEx.MLLMImage.placeholder(image)
  end
end
