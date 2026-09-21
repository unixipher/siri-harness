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

    @Test("ModelListResponse lists supported models")
    func testModelListResponse() throws {
        let models = SiriModelService.supportedModels.map { ModelObject(id: $0) }
        let listResp = ModelListResponse(data: models)
        let encoded = try JSONEncoder().encode(listResp)
        let decoded = try JSONDecoder().decode(ModelListResponse.self, from: encoded)

        let modelIds = decoded.data.map(\.id)
        #expect(modelIds.contains("siri"))
        #expect(modelIds.contains("apple-intelligence"))
        #expect(modelIds.contains("apple/system-language-model"))
    }
}
