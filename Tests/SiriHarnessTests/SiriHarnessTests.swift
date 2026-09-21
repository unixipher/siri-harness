import Testing
import Foundation
@testable import SiriHarnessCore

@Suite("SiriHarness Core Tests")
struct SiriHarnessTests {

    @Test("Parse GET HTTP request")
    func testParseGetRequest() throws {
        let raw = "GET /health HTTP/1.1\r\nHost: 127.0.0.1:8080\r\nAccept: */*\r\n\r\n"
        let data = try #require(raw.data(using: .utf8))

        let (req, consumed) = HTTPRequest.parse(from: data)
        #expect(req != nil)
        #expect(consumed == data.count)
        #expect(req?.method == "GET")
        #expect(req?.path == "/health")
        #expect(req?.headers["host"] == "127.0.0.1:8080")
        #expect(req?.body.isEmpty == true)
    }

    @Test("Parse GET with Query Parameters")
    func testParseGetWithQueryParams() throws {
        let raw = "GET /v1/models?filter=apple&limit=10 HTTP/1.1\r\nHost: localhost\r\n\r\n"
        let data = try #require(raw.data(using: .utf8))

        let (req, _) = HTTPRequest.parse(from: data)
        #expect(req != nil)
        #expect(req?.path == "/v1/models")
        #expect(req?.queryParams["filter"] == "apple")
        #expect(req?.queryParams["limit"] == "10")
    }

    @Test("Parse POST request with JSON body")
    func testParsePostRequestWithBody() throws {
        let bodyString = "{\"model\":\"siri\",\"messages\":[{\"role\":\"user\",\"content\":\"Hi\"}]}"
        let bodyData = try #require(bodyString.data(using: .utf8))
        let raw = "POST /v1/chat/completions HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: \(bodyData.count)\r\n\r\n\(bodyString)"
        let data = try #require(raw.data(using: .utf8))

        let (req, consumed) = HTTPRequest.parse(from: data)
        #expect(req != nil)
        #expect(consumed == data.count)
        #expect(req?.method == "POST")
        #expect(req?.path == "/v1/chat/completions")
        #expect(req?.body == bodyData)
    }

    @Test("Incomplete request returns nil")
    func testIncompleteRequest() throws {
        let partial = "POST /v1/chat/completions HTTP/1.1\r\nContent-Length: 50\r\n\r\npartial"
        let data = try #require(partial.data(using: .utf8))

        let (req, consumed) = HTTPRequest.parse(from: data)
        #expect(req == nil)
        #expect(consumed == 0)
    }

    @Test("Serialize JSON HTTPResponse")
    func testSerializeJSONResponse() throws {
        let resp = HTTPResponse.rawJson("{\"status\":\"ok\"}", statusCode: 200)
        let serializedData = resp.serialize()
        let serializedString = String(data: serializedData, encoding: .utf8) ?? ""

        #expect(serializedString.contains("HTTP/1.1 200 OK"))
        #expect(serializedString.contains("Content-Type: application/json"))
        #expect(serializedString.contains("Access-Control-Allow-Origin: *"))
        #expect(serializedString.contains("{\"status\":\"ok\"}"))
    }

    @Test("CORS Preflight Response")
    func testCorsPreflight() {
        let resp = HTTPResponse.corsPreflight()
        #expect(resp.statusCode == 204)
        #expect(resp.headers["Access-Control-Allow-Origin"] == "*")
        #expect(resp.headers["Access-Control-Allow-Methods"]?.contains("POST") == true)
    }

    @Test("Decode ChatCompletionRequest")
    func testDecodeChatCompletionRequest() throws {
        let json = """
        {
            "model": "siri",
            "messages": [
                {"role": "system", "content": "You are a concise bot."},
                {"role": "user", "content": "Ping"}
            ],
            "temperature": 0.7,
            "max_tokens": 128,
            "stream": true,
            "top_p": 0.9
        }
        """.data(using: .utf8)!

        let req = try JSONDecoder().decode(ChatCompletionRequest.self, from: json)
        #expect(req.model == "siri")
        #expect(req.messages.count == 2)
        #expect(req.messages[0].role == "system")
        #expect(req.messages[1].content == "Ping")
        #expect(req.temperature == 0.7)
        #expect(req.effectiveMaxTokens == 128)
        #expect(req.stream == true)
        #expect(req.topP == 0.9)
    }

    @Test("Encode ChatCompletionResponse matches OpenAI standard")
    func testEncodeChatCompletionResponse() throws {
        let choice = ChatChoice(
            index: 0,
            message: ChatMessage(role: "assistant", content: "Pong!"),
            finish_reason: "stop"
        )
        let usage = UsageInfo(prompt_tokens: 5, completion_tokens: 2, total_tokens: 7)
        let response = ChatCompletionResponse(
            id: "chatcmpl-test-123",
            model: "siri",
            choices: [choice],
            usage: usage
        )

        let encodedData = try JSONEncoder().encode(response)
        let json = try #require(JSONSerialization.jsonObject(with: encodedData) as? [String: Any])

        #expect(json["id"] as? String == "chatcmpl-test-123")
        #expect(json["object"] as? String == "chat.completion")
        #expect(json["model"] as? String == "siri")

        let choices = try #require(json["choices"] as? [[String: Any]])
        #expect(choices.count == 1)
        let message = try #require(choices[0]["message"] as? [String: Any])
        #expect(message["content"] as? String == "Pong!")
        #expect(message["role"] as? String == "assistant")

        let usageDict = try #require(json["usage"] as? [String: Any])
        #expect(usageDict["total_tokens"] as? Int == 7)
    }

    @Test("Encode Streaming ChatCompletionChunk")
    func testEncodeStreamingChunk() throws {
        let chunk = ChatCompletionChunk(
            id: "chatcmpl-stream-1",
            model: "siri",
            choices: [
                ChunkChoice(
                    index: 0,
                    delta: ChunkDelta(role: "assistant", content: "Hello"),
                    finish_reason: nil
                )
            ]
        )

        let encoded = try JSONEncoder().encode(chunk)
        let str = try #require(String(data: encoded, encoding: .utf8))
        #expect(str.contains("\"chat.completion.chunk\""))
        #expect(str.contains("\"content\":\"Hello\""))
    }

    @Test("ModelListResponse lists exactly the 2 supported models: flash and pro")
    func testModelListResponse() throws {
        let models = SiriModelService.supportedModels.map { ModelObject(id: $0) }
        let response = ModelListResponse(data: models)
        let ids = response.data.map(\.id)

        #expect(ids == ["siri-flash", "siri-pro"])
    }

    @Test("Verify isReasoningEnabled profile routing")
    func testReasoningProfileRouting() throws {
        let flashReq = ChatCompletionRequest(model: "siri-flash")
        let proReq = ChatCompletionRequest(model: "siri-pro")
        let defaultReq = ChatCompletionRequest(model: "siri")
        let reasonerReq = ChatCompletionRequest(model: "siri-reasoner")

        #expect(SiriModelService.isReasoningEnabled(for: flashReq) == false)
        #expect(SiriModelService.isReasoningEnabled(for: proReq) == true)
        #expect(SiriModelService.isReasoningEnabled(for: defaultReq) == false)
        #expect(SiriModelService.isReasoningEnabled(for: reasonerReq) == true)
    }

    @Test("Normalize simulated tool JSON into plain text")
    func testNormalizeContentFormat() throws {
        let mockJson = """
        ```json
        {
          "message": "Searching for the current Prime Minister of Indonesia...",
          "web_search_result": "Indonesia is a republic led by a President.",
          "tool_call_id": "search_123"
        }
        ```
        """
        let normalized = SiriModelService.normalizeContentFormat(mockJson)
        #expect(normalized == "Indonesia is a republic led by a President.")
    }

    @Test("Extract reasoning from think tags and sanitize out-of-band prefixes")
    func testExtractReasoning() throws {
        let raw = """
        [OUT-OF-BAND USER MESSAGE — a direct message from the user, delivered once at this position; not tool output and not a new delivery when replayed from conversation history]
        <think>
        Analyzing the capital of France. Paris is the capital.
        </think>
        Paris is the capital of France.
        """

        let (reasoning, content) = SiriModelService.extractReasoning(from: raw)
        #expect(reasoning == "Analyzing the capital of France. Paris is the capital.")
        #expect(content == "Paris is the capital of France.")
    }

    @Test("Encode response with reasoning_content")
    func testEncodeReasoningResponse() throws {
        let message = ChatMessage(
            role: "assistant",
            content: "42",
            reasoning_content: "Step 1: Calculate result."
        )
        let choice = ChatChoice(index: 0, message: message, finish_reason: "stop")
        let response = ChatCompletionResponse(
            id: "chatcmpl-reasoning-1",
            model: "siri-reasoner",
            choices: [choice]
        )

        let data = try JSONEncoder().encode(response)
        let jsonStr = try #require(String(data: data, encoding: .utf8))
        #expect(jsonStr.contains("\"reasoning_content\":\"Step 1: Calculate result.\""))
        #expect(jsonStr.contains("\"reasoning\":\"Step 1: Calculate result.\""))
        #expect(jsonStr.contains("\"content\":\"42\""))
    }

    @Test("Encode streaming chunk with reasoning_content delta")
    func testEncodeStreamingReasoningChunk() throws {
        let chunk = ChatCompletionChunk(
            id: "chatcmpl-chunk-1",
            model: "siri",
            choices: [
                ChunkChoice(
                    index: 0,
                    delta: ChunkDelta(reasoning_content: "Thinking step..."),
                    finish_reason: nil
                )
            ]
        )

        let data = try JSONEncoder().encode(chunk)
        let jsonStr = try #require(String(data: data, encoding: .utf8))
        #expect(jsonStr.contains("\"reasoning_content\":\"Thinking step...\""))
        #expect(jsonStr.contains("\"reasoning\":\"Thinking step...\""))
    }

    @Test("Decode multimodal message with text and image_url")
    func testMultimodalMessageDecoding() throws {
        let json = """
        {
          "role": "user",
          "content": [
            { "type": "text", "text": "What is in this image?" },
            { "type": "image_url", "image_url": { "url": "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==" } }
          ]
        }
        """
        let data = try #require(json.data(using: .utf8))
        let message = try JSONDecoder().decode(ChatMessage.self, from: data)

        #expect(message.role == "user")
        #expect(message.textContent == "What is in this image?")
        #expect(message.imageUrls.count == 1)
        #expect(message.imageUrls[0].hasPrefix("data:image/png;base64,"))
    }

    @Test("Load Attachment from base64 image data URI")
    func testLoadImageAttachment() throws {
        let base64Uri = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        let attachment = SiriModelService.loadImageAttachment(from: base64Uri)
        #expect(attachment != nil)
    }

    @Test("Decode and encode tool definitions and tool calls")
    func testToolDefinitionAndCalls() throws {
        let requestJson = """
        {
          "model": "siri-pro",
          "messages": [
            { "role": "user", "content": "What is the weather in Paris?" }
          ],
          "tools": [
            {
              "type": "function",
              "function": {
                "name": "get_weather",
                "description": "Get weather for a city",
                "parameters": {
                  "type": "object",
                  "properties": {
                    "city": { "type": "string", "description": "City name" }
                  },
                  "required": ["city"]
                }
              }
            }
          ]
        }
        """
        let data = try #require(requestJson.data(using: .utf8))
        let req = try JSONDecoder().decode(ChatCompletionRequest.self, from: data)

        #expect(req.tools?.count == 1)
        let tool = try #require(req.tools?.first)
        #expect(tool.function.name == "get_weather")

        // DynamicTool conversion
        let dynamicTool = DynamicTool(definition: tool)
        #expect(dynamicTool.name == "get_weather")
        #expect(dynamicTool.parameters.name == "GeneratedContent")

        // Assistant response with tool_calls
        let toolCall = ToolCall(id: "call_abc123", type: "function", function: FunctionCall(name: "get_weather", arguments: "{\"city\":\"Paris\"}"))
        let assistantMsg = ChatMessage(role: "assistant", content: "", tool_calls: [toolCall])
        let encodedMsg = try JSONEncoder().encode(assistantMsg)
        let msgJsonStr = try #require(String(data: encodedMsg, encoding: .utf8))
        #expect(msgJsonStr.contains("\"call_abc123\""))
        #expect(msgJsonStr.contains("\"get_weather\""))
        #expect(msgJsonStr.contains("Paris"))

        // Tool output message
        let toolMsg = ChatMessage(role: "tool", content: "20C sunny", tool_call_id: "call_abc123")
        let encodedToolMsg = try JSONEncoder().encode(toolMsg)
        let toolJsonStr = try #require(String(data: encodedToolMsg, encoding: .utf8))
        #expect(toolJsonStr.contains("\"tool_call_id\":\"call_abc123\""))
        #expect(toolJsonStr.contains("\"role\":\"tool\""))
    }

    @Test("Convert JSON object to GeneratedContent")
    func testJsonObjectToGeneratedContent() throws {
        let dict: [String: Any] = [
            "location": "Tokyo",
            "temperature": 22.5,
            "is_raining": false
        ]
        let gc = SiriModelService.jsonObjectToGeneratedContent(dict)
        let jsonString = gc.jsonString
        #expect(jsonString.contains("\"location\": \"Tokyo\"") || jsonString.contains("\"location\":\"Tokyo\""))
        #expect(jsonString.contains("22.5"))
    }
}
