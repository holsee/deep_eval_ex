defmodule DeepEvalEx.MLLMImageTest do
  use ExUnit.Case, async: true

  alias DeepEvalEx.MLLMImage

  doctest MLLMImage

  @dot_path "test/fixtures/deepeval/multimodal/red_dot.png"
  @dot_base64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg=="

  describe "new/1" do
    test "takes base64 data with its mime type" do
      assert {:ok, image} = MLLMImage.new(data_base64: "AAAA", mime_type: "image/png", id: "dot")

      assert image == %MLLMImage{data_base64: "AAAA", mime_type: "image/png", id: "dot"}
    end

    test "derives a remote image's filename and mime type, and does not download it" do
      assert {:ok, image} = MLLMImage.new(url: "https://example.com/charts/sales.png?v=2")

      assert %MLLMImage{local: false, filename: "sales.png", mime_type: "image/png"} = image
      assert image.data_base64 == nil
    end

    test "leaves a remote image's mime type nil for an unknown extension" do
      assert {:ok, %MLLMImage{mime_type: nil, filename: "image"}} =
               MLLMImage.new(url: "https://example.com/image")
    end

    test "reads a local file into base64, deriving its filename and mime type" do
      assert {:ok, image} = MLLMImage.new(url: @dot_path)

      assert %MLLMImage{local: true, filename: "red_dot.png", mime_type: "image/png"} = image
      assert image.data_base64 == @dot_base64
    end

    test "reads a file:// URL" do
      url = "file://" <> Path.expand(@dot_path)

      assert {:ok, %MLLMImage{local: true, data_base64: @dot_base64}} = MLLMImage.new(url: url)
    end

    test "defaults its id to 32 hex characters, as uuid4().hex" do
      assert {:ok, %MLLMImage{id: id}} =
               MLLMImage.new(data_base64: "AAAA", mime_type: "image/png")

      assert id =~ ~r/\A[0-9a-f]{32}\z/
    end

    test "takes deepeval's keys, as an imagesMapping entry holds them" do
      assert {:ok, image} =
               MLLMImage.new(%{"dataBase64" => "AAAA", "mimeType" => "image/png", "_id" => "dot"})

      assert image.id == "dot"
    end

    test "returns deepeval's errors" do
      assert MLLMImage.new([]) ==
               {:error,
                "You must provide either a 'url' or both 'dataBase64' and 'mimeType' to create an MLLMImage."}

      assert MLLMImage.new(data_base64: "AAAA") ==
               {:error, "mimeType must be provided when initializing from Base64 data."}

      assert MLLMImage.new(url: "ftp://example.com/a.png") ==
               {:error,
                "Invalid remote URL format: ftp://example.com/a.png. URL must start with http:// or https://"}

      assert MLLMImage.new(url: @dot_path, local: false) == {:error, "Local path mismatch"}
    end

    test "new!/1 raises ArgumentError" do
      assert_raise ArgumentError, ~r/mimeType must be provided/, fn ->
        MLLMImage.new!(data_base64: "AAAA")
      end
    end
  end

  describe "placeholder/1" do
    test "is an IMAGE placeholder, or a PDF one for a PDF" do
      image = MLLMImage.new!(data_base64: "AAAA", mime_type: "image/png", id: "a")
      pdf = MLLMImage.new!(data_base64: "AAAA", mime_type: "application/pdf", id: "b")

      assert MLLMImage.placeholder(image) == "[DEEPEVAL:IMAGE:a]"
      assert "#{pdf}" == "[DEEPEVAL:PDF:b]"
    end
  end

  describe "parse/2" do
    test "splits text at placeholders, without empty pieces" do
      image = MLLMImage.new!(data_base64: "AAAA", mime_type: "image/png", id: "a")

      assert MLLMImage.parse("#{image}#{image} and text", %{"a" => image}) ==
               [image, image, " and text"]
    end

    test "takes an unknown id as the image's URL, as deepeval" do
      assert [%MLLMImage{url: "https://e.com/a.png", id: "https://e.com/a.png"}] =
               MLLMImage.parse("[DEEPEVAL:IMAGE:https://e.com/a.png]", %{})

      assert_raise ArgumentError, ~r/Invalid remote URL format: unknown/, fn ->
        MLLMImage.parse("[DEEPEVAL:IMAGE:unknown]", nil)
      end
    end
  end

  describe "mapping/2" do
    test "is the images named, in order of first appearance, or nil" do
      a = MLLMImage.new!(data_base64: "AAAA", mime_type: "image/png", id: "a")
      b = MLLMImage.new!(data_base64: "BBBB", mime_type: "image/png", id: "b")
      images = %{"a" => a, "b" => b}

      assert MLLMImage.mapping(["#{b}", nil, "#{a} #{b} [DEEPEVAL:IMAGE:z]"], images) ==
               [{"b", b}, {"a", a}]

      assert MLLMImage.mapping(["no images"], images) == nil
    end
  end

  describe "to_dump/1" do
    test "writes deepeval's dataclass dump, leaving out nil fields" do
      image = MLLMImage.new!(url: "https://example.com/cat.png", id: "cat")

      assert image |> MLLMImage.to_dump() |> Jason.encode!() ==
               ~s({"mimeType":"image/png","url":"https://example.com/cat.png","local":false,) <>
                 ~s("filename":"cat.png","_id":"cat"})
    end
  end

  describe "ensure_loaded/1" do
    test "reads a local image whose data was dropped" do
      image = %{MLLMImage.new!(url: @dot_path) | data_base64: nil}

      assert MLLMImage.ensure_loaded(image).data_base64 == @dot_base64
    end
  end
end
