defmodule DeepEvalEx.LLM.Adapters.ReqLLMTest do
  # Req.Test stubs belong to the test process and the adapter reads no
  # global state, so the tests run concurrently.
  use ExUnit.Case, async: true

  alias DeepEvalEx.LLM.Adapter
  alias DeepEvalEx.LLM.Adapters.ReqLLM, as: Adapters
  alias DeepEvalEx.LLM.Usage
  alias DeepEvalEx.Metrics.{ConversationalGEval, GEval}
  alias DeepEvalEx.Tracing
  alias DeepEvalEx.Tracing.Span

  @stub __MODULE__
  @opts [api_key: "test-key", req_options: [plug: {Req.Test, @stub}]]

  # A gateway speaking OpenAI Chat Completions, as an inline ReqLLM model spec.
  @gateway %{
    provider: :openai,
    id: "aws-bedrock-runtime/openai/gpt-6.1-sol@global",
    base_url: "https://gateway.example.com/v1",
    extra: %{wire: %{protocol: "openai_chat"}}
  }

  @schema %{
    "type" => "object",
    "properties" => %{
      "verdict" => %{"type" => "string", "enum" => ["yes", "no"]},
      "reason" => %{"type" => "string"}
    },
    "required" => ["verdict"]
  }

  # Stubs every provider endpoint with `content` in that provider's response
  # shape, and sends each captured request back to the test process.
  defp stub(content, usage \\ %{input: 10, output: 5}) do
    test_pid = self()

    Req.Test.stub(@stub, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request, conn, Jason.decode!(raw)})
      Req.Test.json(conn, response(conn, content, usage))
    end)
  end

  defp response(%{request_path: "/v1/messages"}, content, usage) do
    %{
      "id" => "msg_1",
      "type" => "message",
      "role" => "assistant",
      "model" => "claude-haiku-4-5-20251001",
      "content" => [%{"type" => "text", "text" => content}],
      "stop_reason" => "end_turn",
      "usage" => %{"input_tokens" => usage.input, "output_tokens" => usage.output}
    }
  end

  defp response(%{host: "generativelanguage.googleapis.com"}, content, usage) do
    %{
      "candidates" => [
        %{
          "content" => %{"role" => "model", "parts" => [%{"text" => content}]},
          "finishReason" => "STOP"
        }
      ],
      "usageMetadata" => %{
        "promptTokenCount" => usage.input,
        "candidatesTokenCount" => usage.output,
        "totalTokenCount" => usage.input + usage.output
      }
    }
  end

  defp response(%{request_path: "/v1/responses"}, content, usage) do
    %{
      "id" => "resp_1",
      "object" => "response",
      "status" => "completed",
      "model" => "gpt-4o-mini",
      "output" => [
        %{
          "type" => "message",
          "id" => "msg_1",
          "role" => "assistant",
          "status" => "completed",
          "content" => [%{"type" => "output_text", "text" => content, "annotations" => []}]
        }
      ]
    }
    |> put_usage(usage, %{"input_tokens" => usage[:input], "output_tokens" => usage[:output]})
  end

  defp response(_conn, content, usage) do
    %{
      "id" => "chatcmpl-1",
      "object" => "chat.completion",
      "model" => "gateway-model",
      "choices" => [
        %{
          "index" => 0,
          "message" => %{"role" => "assistant", "content" => content},
          "finish_reason" => "stop"
        }
      ]
    }
    |> put_usage(usage, %{
      "prompt_tokens" => usage[:input],
      "completion_tokens" => usage[:output]
    })
  end

  defp put_usage(body, nil, _usage), do: body
  defp put_usage(body, _usage, wire), do: Map.put(body, "usage", wire)

  defp url(conn), do: "#{conn.scheme}://#{conn.host}#{conn.request_path}"

  describe "generate/2" do
    test "sends an OpenAI model's prompt to the Responses API and returns the text" do
      stub("Paris")

      assert {:ok, "Paris"} =
               Adapters.generate("Capital of France?", [model: "openai:gpt-4o-mini"] ++ @opts)

      assert_received {:request, conn, body}
      assert url(conn) == "https://api.openai.com/v1/responses"
      assert body["model"] == "gpt-4o-mini"

      assert [%{"role" => "user", "content" => [%{"text" => "Capital of France?"}]}] =
               body["input"]
    end

    test "sends an Anthropic model's prompt to the Messages API with temperature 0.0" do
      stub("Paris")

      assert {:ok, "Paris"} =
               Adapters.generate(
                 "Capital of France?",
                 [model: "anthropic:claude-haiku-4-5"] ++ @opts
               )

      assert_received {:request, conn, body}
      assert url(conn) == "https://api.anthropic.com/v1/messages"
      assert body["model"] =~ "claude-haiku-4-5"
      assert body["messages"] == [%{"role" => "user", "content" => "Capital of France?"}]
      assert body["temperature"] == 0.0
    end

    test "sends :temperature and :max_tokens when given" do
      stub("Paris")

      opts = [model: "anthropic:claude-haiku-4-5", temperature: 0.7, max_tokens: 256] ++ @opts
      assert {:ok, "Paris"} = Adapters.generate("Capital of France?", opts)

      assert_received {:request, _conn, body}
      assert body["temperature"] == 0.7
      assert body["max_tokens"] == 256
    end

    test "reaches an OpenAI-compatible gateway through an inline model spec" do
      stub("Paris")

      assert {:ok, "Paris"} = Adapters.generate("Capital of France?", [model: @gateway] ++ @opts)

      assert_received {:request, conn, body}
      assert url(conn) == "https://gateway.example.com/v1/chat/completions"
      assert body["model"] == "aws-bedrock-runtime/openai/gpt-6.1-sol@global"
      assert body["messages"] == [%{"role" => "user", "content" => "Capital of France?"}]
      assert body["temperature"] == 0.0
    end

    test "sends to the :base_url option" do
      stub("Paris")
      opts = [model: "anthropic:claude-haiku-4-5", base_url: "https://proxy.example.com"]

      assert {:ok, "Paris"} = Adapters.generate("Capital of France?", opts ++ @opts)

      assert_received {:request, conn, _body}
      assert url(conn) == "https://proxy.example.com/v1/messages"
    end

    test "returns ReqLLM's error for a failed request" do
      Req.Test.stub(@stub, fn conn ->
        conn
        |> Plug.Conn.put_status(401)
        |> Req.Test.json(%{"error" => %{"type" => "authentication_error", "message" => "bad"}})
      end)

      opts = [model: "anthropic:claude-haiku-4-5", req_llm_options: [max_retries: 0]] ++ @opts

      assert {:error, %ReqLLM.Error.API.Request{status: 401}} =
               Adapters.generate("Capital of France?", opts)
    end

    test "returns ReqLLM's error for an unknown provider" do
      assert {:error, _reason} = Adapters.generate("hi", [model: "nope:some-model"] ++ @opts)
    end
  end

  describe "generate_with_schema/3" do
    test "asks an Anthropic model for a strict JSON schema and returns the object" do
      stub(~s({"verdict": "yes", "reason": null}))

      assert {:ok, %{"verdict" => "yes", "reason" => nil}} =
               Adapters.generate_with_schema(
                 "Is Paris in France?",
                 @schema,
                 [model: "anthropic:claude-haiku-4-5"] ++ @opts
               )

      assert_received {:request, conn, body}
      assert url(conn) == "https://api.anthropic.com/v1/messages"

      # Optional fields become required but nullable, as for the OpenAI
      # adapter (DeepEvalEx.LLM.StrictSchema).
      assert %{"type" => "json_schema", "schema" => schema} = body["output_format"]
      assert schema["additionalProperties"] == false
      assert Enum.sort(schema["required"]) == ["reason", "verdict"]
      assert schema["properties"]["reason"]["type"] == ["string", "null"]
    end

    test "asks an OpenAI model for a strict JSON schema" do
      stub(~s({"verdict": "no", "reason": "Lyon is not the capital"}))

      assert {:ok, %{"verdict" => "no", "reason" => "Lyon is not the capital"}} =
               Adapters.generate_with_schema(
                 "Is Lyon the capital of France?",
                 @schema,
                 [model: "openai:gpt-4o-mini"] ++ @opts
               )

      assert_received {:request, _conn, body}

      assert %{"type" => "json_schema", "strict" => true, "schema" => schema} =
               body["text"]["format"]

      assert schema["properties"]["reason"]["type"] == ["string", "null"]
    end

    test "takes a schema module exporting json_schema/0" do
      stub(~s({"verdict": "yes", "reason": "Paris is in France"}))

      defmodule VerdictSchema do
        @moduledoc false
        def json_schema do
          %{
            "type" => "object",
            "properties" => %{"verdict" => %{"type" => "string"}},
            "required" => ["verdict"]
          }
        end
      end

      assert {:ok, %{"verdict" => "yes"}} =
               Adapters.generate_with_schema(
                 "Is Paris in France?",
                 VerdictSchema,
                 [model: "google:gemini-2.5-flash"] ++ @opts
               )

      assert_received {:request, conn, body}

      assert url(conn) ==
               "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent"

      assert body["generationConfig"]["responseJsonSchema"]["required"] == ["verdict"]
    end
  end

  describe "usage" do
    test "prices a model DeepEvalEx knows with DeepEvalEx.LLM.Pricing" do
      stub("Paris", %{input: 1_000, output: 500})

      {{:ok, "Paris"}, usages} =
        Usage.track(fn ->
          Adapters.generate("Capital of France?", [model: "openai:gpt-4o-mini"] ++ @opts)
        end)

      # gpt-4o-mini: $0.15 input and $0.60 output per 1M tokens.
      assert [
               %Usage{model: "openai:gpt-4o-mini", input_tokens: 1_000, output_tokens: 500} =
                 usage
             ] =
               usages

      assert_in_delta usage.cost, 1_000 * 0.15e-6 + 500 * 0.60e-6, 1.0e-12
    end

    test "takes ReqLLM's cost for a model DeepEvalEx does not price" do
      stub("Paris", %{input: 1_000, output: 500})

      {{:ok, "Paris"}, [usage]} =
        Usage.track(fn ->
          Adapters.generate("Capital of France?", [model: "google:gemini-2.5-flash"] ++ @opts)
        end)

      assert %Usage{model: "google:gemini-2.5-flash", input_tokens: 1_000, output_tokens: 500} =
               usage

      # ReqLLM's catalog price for gemini-2.5-flash: $0.30 and $2.50 per 1M.
      assert_in_delta usage.cost, 1_000 * 0.30e-6 + 500 * 2.50e-6, 1.0e-12
    end

    test "leaves the cost nil when neither DeepEvalEx nor ReqLLM prices the model" do
      stub("Paris")

      {{:ok, "Paris"}, [usage]} =
        Usage.track(fn -> Adapters.generate("hi", [model: @gateway] ++ @opts) end)

      assert %Usage{input_tokens: 10, output_tokens: 5, cost: nil} = usage
    end

    test "leaves token counts nil when the provider reports none" do
      stub("Paris", nil)

      {{:ok, "Paris"}, [usage]} =
        Usage.track(fn -> Adapters.generate("hi", [model: "openai:gpt-4o-mini"] ++ @opts) end)

      assert %Usage{input_tokens: nil, output_tokens: nil, cost: nil} = usage
    end
  end

  describe "model_name/1" do
    test "is the model spec" do
      assert Adapters.model_name(model: "google:gemini-2.5-flash") == "google:gemini-2.5-flash"
    end

    test "is provider:id for an inline model spec" do
      assert Adapters.model_name(model: @gateway) ==
               "openai:aws-bedrock-runtime/openai/gpt-6.1-sol@global"
    end

    test "requires a model" do
      assert_raise ArgumentError, ~r/ReqLLM model spec/, fn -> Adapters.model_name([]) end
    end
  end

  describe "through DeepEvalEx.LLM.Adapter" do
    test "resolves the :req_llm provider atom" do
      assert Adapter.get_adapter(:req_llm) == Adapters
      assert Adapter.native?(adapter: :req_llm)

      assert Adapter.model_name(adapter: {:req_llm, "groq:llama-3.3-70b-versatile"}) ==
               "groq:llama-3.3-70b-versatile"
    end

    test "lets GEval and ConversationalGEval judge with an inline model spec" do
      opts = [adapter: :req_llm, model: @gateway]
      name = "openai:aws-bedrock-runtime/openai/gpt-6.1-sol@global"

      assert GEval.evaluation_model(opts) == name
      assert ConversationalGEval.evaluation_model(opts) == name
    end

    test "loads a JSON answer through generate_with_schema/3" do
      stub(~s({"verdict": "yes", "reason": null}))
      opts = [adapter: {:req_llm, "anthropic:claude-haiku-4-5"}] ++ @opts

      assert {:ok, %{"verdict" => "yes"}} = Adapter.generate_with_schema("hi", @schema, opts)
    end

    test "records an :llm span with the model spec and token counts inside a trace" do
      stub("Paris")
      opts = [adapter: {:req_llm, "anthropic:claude-haiku-4-5"}] ++ @opts

      {{:ok, "Paris"}, [trace]} =
        Tracing.capture([], fn ->
          Tracing.span(:agent, [name: "agent"], fn -> Adapter.generate("Capital?", opts) end)
        end)

      assert [%Span{children: [llm]}] = trace.root_spans

      assert %Span{
               type: :llm,
               name: "generate",
               model: "anthropic:claude-haiku-4-5",
               input: "Capital?",
               output: "Paris",
               input_token_count: 10.0,
               output_token_count: 5.0
             } = llm
    end
  end
end
