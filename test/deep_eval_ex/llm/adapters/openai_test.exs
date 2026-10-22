defmodule DeepEvalEx.LLM.Adapters.OpenAITest do
  # Mutates application and OS environment, so it cannot run concurrently.
  use ExUnit.Case, async: false

  alias DeepEvalEx.LLM.Adapters.OpenAI
  alias DeepEvalEx.LLM.Usage

  @stub OpenAI
  @base_opts [api_key: "sk-test", req_options: [plug: {Req.Test, @stub}, retry: false]]

  setup do
    saved_env = Map.new(~w(OPENAI_BASE_URL OPENAI_API_KEY), &{&1, System.get_env(&1)})
    saved_config = Map.new(~w(openai_base_url openai_temperature)a, &{&1, app_env(&1)})

    System.delete_env("OPENAI_BASE_URL")
    Enum.each(saved_config, fn {key, _} -> Application.delete_env(:deep_eval_ex, key) end)

    on_exit(fn ->
      Enum.each(saved_env, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      Enum.each(saved_config, fn
        {key, nil} -> Application.delete_env(:deep_eval_ex, key)
        {key, value} -> Application.put_env(:deep_eval_ex, key, value)
      end)
    end)

    :ok
  end

  defp app_env(key), do: Application.get_env(:deep_eval_ex, key)

  # Stubs the endpoint with a chat completion returning `content` and sends
  # the captured request back to the test process.
  defp stub_completion(content) do
    test_pid = self()

    Req.Test.stub(@stub, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request, conn, Jason.decode!(raw)})

      Req.Test.json(conn, %{
        "choices" => [%{"message" => %{"role" => "assistant", "content" => content}}]
      })
    end)
  end

  defp request_url(conn) do
    "#{conn.scheme}://#{conn.host}#{conn.request_path}"
  end

  describe "base URL" do
    test "defaults to the public OpenAI API" do
      stub_completion("hi")

      assert {:ok, "hi"} = OpenAI.generate("hello", @base_opts)
      assert_received {:request, conn, _body}
      assert conn.method == "POST"
      assert request_url(conn) == "https://api.openai.com/v1/chat/completions"
    end

    test "uses :base_url opt and strips a trailing slash" do
      stub_completion("hi")
      opts = [{:base_url, "https://gateway.example.com/openai/v1/"} | @base_opts]

      assert {:ok, "hi"} = OpenAI.generate("hello", opts)
      assert_received {:request, conn, _body}
      assert request_url(conn) == "https://gateway.example.com/openai/v1/chat/completions"
    end

    test "falls back to :openai_base_url config" do
      stub_completion("hi")
      Application.put_env(:deep_eval_ex, :openai_base_url, "https://config.example.com/v1")
      System.put_env("OPENAI_BASE_URL", "https://env.example.com/v1")

      assert {:ok, "hi"} = OpenAI.generate("hello", @base_opts)
      assert_received {:request, conn, _body}
      assert request_url(conn) == "https://config.example.com/v1/chat/completions"
    end

    test "falls back to OPENAI_BASE_URL env var" do
      stub_completion("hi")
      System.put_env("OPENAI_BASE_URL", "https://env.example.com/v1/")

      assert {:ok, "hi"} = OpenAI.generate("hello", @base_opts)
      assert_received {:request, conn, _body}
      assert request_url(conn) == "https://env.example.com/v1/chat/completions"
    end

    test "treats a blank OPENAI_BASE_URL as unset" do
      stub_completion("hi")
      System.put_env("OPENAI_BASE_URL", "")

      assert {:ok, "hi"} = OpenAI.generate("hello", @base_opts)
      assert_received {:request, conn, _body}
      assert request_url(conn) == "https://api.openai.com/v1/chat/completions"
    end

    test ":base_url opt wins over config and env" do
      stub_completion("hi")
      Application.put_env(:deep_eval_ex, :openai_base_url, "https://config.example.com/v1")
      System.put_env("OPENAI_BASE_URL", "https://env.example.com/v1")
      opts = [{:base_url, "https://opt.example.com/v1"} | @base_opts]

      assert {:ok, "hi"} = OpenAI.generate("hello", opts)
      assert_received {:request, conn, _body}
      assert request_url(conn) == "https://opt.example.com/v1/chat/completions"
    end
  end

  describe "request" do
    test "sends bearer auth and JSON content type" do
      stub_completion("hi")

      assert {:ok, "hi"} = OpenAI.generate("hello", @base_opts)
      assert_received {:request, conn, _body}
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer sk-test"]
      assert [content_type] = Plug.Conn.get_req_header(conn, "content-type")
      assert content_type =~ "application/json"
    end

    test "sends model, messages and max_completion_tokens, not max_tokens" do
      stub_completion("hi")

      assert {:ok, "hi"} = OpenAI.generate("hello", [{:model, "gpt-4o"} | @base_opts])
      assert_received {:request, _conn, body}
      assert body["model"] == "gpt-4o"
      assert body["messages"] == [%{"role" => "user", "content" => "hello"}]
      assert body["max_completion_tokens"] == 4096
      refute Map.has_key?(body, "max_tokens")
    end

    test "accepts :max_tokens as an alias for :max_completion_tokens" do
      stub_completion("hi")

      assert {:ok, "hi"} = OpenAI.generate("hello", [{:max_tokens, 256} | @base_opts])
      assert_received {:request, _conn, body}
      assert body["max_completion_tokens"] == 256
      refute Map.has_key?(body, "max_tokens")
    end

    test ":max_completion_tokens wins over :max_tokens" do
      stub_completion("hi")
      opts = [max_completion_tokens: 512, max_tokens: 256] ++ @base_opts

      assert {:ok, "hi"} = OpenAI.generate("hello", opts)
      assert_received {:request, _conn, body}
      assert body["max_completion_tokens"] == 512
    end

    test "defaults temperature to 0.0 like deepeval's GPTModel" do
      stub_completion("hi")

      assert {:ok, "hi"} = OpenAI.generate("hello", @base_opts)
      assert_received {:request, _conn, body}
      assert body["temperature"] == 0.0
    end

    test "sends temperature given via opts over :openai_temperature config" do
      stub_completion("hi")
      Application.put_env(:deep_eval_ex, :openai_temperature, 0.3)

      assert {:ok, "hi"} = OpenAI.generate("hello", [{:temperature, 0.7} | @base_opts])
      assert_received {:request, _conn, body}
      assert body["temperature"] == 0.7
    end

    test "sends temperature given via opts" do
      stub_completion("hi")

      assert {:ok, "hi"} = OpenAI.generate("hello", [{:temperature, 0.0} | @base_opts])
      assert_received {:request, _conn, body}
      assert body["temperature"] == 0.0
    end

    test "sends temperature given via :openai_temperature config" do
      stub_completion("hi")
      Application.put_env(:deep_eval_ex, :openai_temperature, 0.3)

      assert {:ok, "hi"} = OpenAI.generate("hello", @base_opts)
      assert_received {:request, _conn, body}
      assert body["temperature"] == 0.3
    end

    test "omits temperature for reasoning models, which reject it" do
      stub_completion("hi")

      for model <- ~w(o1 o3-mini o4-mini gpt-5 gpt-5-mini gpt-5.4),
          explicit <- [[], [temperature: 0.0]] do
        opts = [model: model] ++ explicit ++ @base_opts

        assert {:ok, "hi"} = OpenAI.generate("hello", opts)
        assert_received {:request, _conn, body}
        refute Map.has_key?(body, "temperature"), "expected no temperature for #{model}"
      end
    end
  end

  describe "generate_with_schema/3" do
    @schema %{
      "type" => "object",
      "properties" => %{"answer" => %{"type" => "string"}},
      "required" => ["answer"],
      "additionalProperties" => false
    }

    test "sends a strict json_schema response_format and parses the content" do
      stub_completion(~s({"answer": "4"}))

      assert {:ok, %{"answer" => "4"}} =
               OpenAI.generate_with_schema("What is 2+2?", @schema, @base_opts)

      assert_received {:request, _conn, body}

      assert body["response_format"] == %{
               "type" => "json_schema",
               "json_schema" => %{"name" => "response", "strict" => true, "schema" => @schema}
             }

      assert body["max_completion_tokens"] == 4096
      refute Map.has_key?(body, "max_tokens")
      assert body["temperature"] == 0.0
    end

    test "returns a json_parse_error for non-JSON content" do
      stub_completion("not json")

      assert {:error, {:json_parse_error, _, "not json"}} =
               OpenAI.generate_with_schema("What is 2+2?", @schema, @base_opts)
    end
  end

  describe "errors" do
    test "treats a blank OPENAI_API_KEY as unset" do
      System.put_env("OPENAI_API_KEY", "")
      opts = Keyword.delete(@base_opts, :api_key)

      assert_raise RuntimeError, ~r/OPENAI_API_KEY/, fn -> OpenAI.generate("hello", opts) end
    end

    test "maps non-200 responses to api_error" do
      error = %{"error" => %{"message" => "Incorrect API key provided"}}

      Req.Test.stub(@stub, fn conn ->
        conn |> Plug.Conn.put_status(401) |> Req.Test.json(error)
      end)

      assert {:error, {:api_error, 401, ^error}} = OpenAI.generate("hello", @base_opts)
    end

    test "returns unexpected_response when choices are missing" do
      Req.Test.stub(@stub, &Req.Test.json(&1, %{"object" => "chat.completion"}))

      assert {:error, {:unexpected_response, %{"object" => "chat.completion"}}} =
               OpenAI.generate("hello", @base_opts)
    end

    test "maps transport failures to request_failed" do
      Req.Test.stub(@stub, &Req.Test.transport_error(&1, :econnrefused))

      assert {:error, {:request_failed, %Req.TransportError{reason: :econnrefused}}} =
               OpenAI.generate("hello", @base_opts)
    end
  end

  describe "usage" do
    defp stub_completion_with_usage(content, usage) do
      Req.Test.stub(@stub, fn conn ->
        Req.Test.json(conn, %{
          "choices" => [%{"message" => %{"role" => "assistant", "content" => content}}],
          "usage" => usage
        })
      end)
    end

    test "records prompt and completion tokens priced for the requested model" do
      stub_completion_with_usage("hi", %{"prompt_tokens" => 1_000, "completion_tokens" => 500})

      {result, usages} =
        Usage.track(fn -> OpenAI.generate("hello", [{:model, "gpt-4o"} | @base_opts]) end)

      assert result == {:ok, "hi"}
      assert [%Usage{model: "gpt-4o", input_tokens: 1_000, output_tokens: 500} = usage] = usages
      assert_in_delta usage.cost, 0.0075, 1.0e-12
    end

    test "records usage for structured output requests" do
      stub_completion_with_usage(~s({"a": 1}), %{"prompt_tokens" => 3, "completion_tokens" => 2})

      {result, usages} =
        Usage.track(fn -> OpenAI.generate_with_schema("hello", %{}, @base_opts) end)

      assert result == {:ok, %{"a" => 1}}
      assert [%Usage{model: "gpt-4o-mini", input_tokens: 3, output_tokens: 2}] = usages
    end

    test "records nothing when the response carries no usage" do
      stub_completion("hi")

      assert {{:ok, "hi"}, []} = Usage.track(fn -> OpenAI.generate("hello", @base_opts) end)
    end
  end
end
