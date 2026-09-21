import Foundation
import Network

/// Represents an incoming HTTP request.
public struct HTTPRequest: Sendable {
    public let method: String
    public let uri: String
    public let path: String
    public let queryParams: [String: String]
    public let headers: [String: String]
    public let body: Data

    public init(
        method: String,
        uri: String,
        path: String,
        queryParams: [String: String],
        headers: [String: String],
        body: Data
    ) {
        self.method = method
        self.uri = uri
        self.path = path
        self.queryParams = queryParams
        self.headers = headers
        self.body = body
    }

    /// Parses an HTTP request from raw data buffer.
    /// Returns the parsed request and the count of bytes consumed if a complete request is available.
    public static func parse(from rawData: Data) -> (request: HTTPRequest?, bytesConsumed: Int) {
        let doubleCRLF = Data([0x0D, 0x0A, 0x0D, 0x0A])
        let doubleLF = Data([0x0A, 0x0A])

        var headerEndRange = rawData.range(of: doubleCRLF)
        var separatorLength = 4

        if headerEndRange == nil {
            headerEndRange = rawData.range(of: doubleLF)
            separatorLength = 2
        }

        guard let headerRange = headerEndRange else {
            return (nil, 0)
        }

        let headerData = rawData.subdata(in: 0..<headerRange.lowerBound)
        guard let headerString = String(data: headerData, encoding: .utf8) else {
            return (nil, 0)
        }

        let lines = headerString.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let requestLine = lines.first else {
            return (nil, 0)
        }

        let requestLineTokens = requestLine.split(separator: " ")
        guard requestLineTokens.count >= 2 else {
            return (nil, 0)
        }

        let method = String(requestLineTokens[0])
        let fullUri = String(requestLineTokens[1])

        let uriParts = fullUri.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = String(uriParts[0])
        var queryParams: [String: String] = [:]
        if uriParts.count > 1 {
            let queryString = String(uriParts[1])
            for pair in queryString.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let key = String(kv[0]).removingPercentEncoding ?? String(kv[0])
                let val = kv.count > 1 ? (String(kv[1]).removingPercentEncoding ?? String(kv[1])) : ""
                queryParams[key] = val
            }
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let colonIndex = line.firstIndex(of: ":") {
                let key = line[..<colonIndex].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }

        let contentLength = Int(headers["content-length"] ?? "") ?? 0
        let bodyStartIndex = headerRange.lowerBound + separatorLength
        let totalExpectedLength = bodyStartIndex + contentLength

        if rawData.count < totalExpectedLength {
            return (nil, 0)
        }

        let bodyData = rawData.subdata(in: bodyStartIndex..<totalExpectedLength)
        let request = HTTPRequest(
            method: method,
            uri: fullUri,
            path: path,
            queryParams: queryParams,
            headers: headers,
            body: bodyData
        )
        return (request, totalExpectedLength)
    }
}

/// Represents an HTTP response to be transmitted to the client.
public struct HTTPResponse: Sendable {
    public let statusCode: Int
    public let statusText: String
    public var headers: [String: String]
    public let body: Data

    public init(
        statusCode: Int,
        statusText: String? = nil,
        headers: [String: String] = [:],
        body: Data = Data()
    ) {
        self.statusCode = statusCode
        self.statusText = statusText ?? HTTPResponse.defaultStatusText(for: statusCode)
        self.headers = headers
        self.body = body
    }

    public static func defaultStatusText(for code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 500: return "Internal Server Error"
        default: return "Response"
        }
    }

    /// Creates an HTTP response with JSON payload and CORS headers.
    public static func json<T: Encodable>(_ value: T, statusCode: Int = 200) -> HTTPResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        do {
            let data = try encoder.encode(value)
            return HTTPResponse(
                statusCode: statusCode,
                headers: [
                    "Content-Type": "application/json; charset=utf-8",
                    "Content-Length": "\(data.count)",
                    "Access-Control-Allow-Origin": "*",
                    "Access-Control-Allow-Methods": "GET, POST, OPTIONS, PUT, DELETE",
                    "Access-Control-Allow-Headers": "*"
                ],
                body: data
            )
        } catch {
            let errJson = "{\"error\": \"\(error.localizedDescription)\"}".data(using: .utf8) ?? Data()
            return HTTPResponse(
                statusCode: 500,
                headers: ["Content-Type": "application/json"],
                body: errJson
            )
        }
    }

    /// Creates an HTTP response with pre-formatted raw JSON string.
    public static func rawJson(_ jsonString: String, statusCode: Int = 200) -> HTTPResponse {
        let data = jsonString.data(using: .utf8) ?? Data()
        return HTTPResponse(
            statusCode: statusCode,
            headers: [
                "Content-Type": "application/json; charset=utf-8",
                "Content-Length": "\(data.count)",
                "Access-Control-Allow-Origin": "*",
                "Access-Control-Allow-Methods": "GET, POST, OPTIONS, PUT, DELETE",
                "Access-Control-Allow-Headers": "*"
            ],
            body: data
        )
    }

    /// Returns a preflight CORS response.
    public static func corsPreflight() -> HTTPResponse {
        return HTTPResponse(
            statusCode: 204,
            headers: [
                "Access-Control-Allow-Origin": "*",
                "Access-Control-Allow-Methods": "GET, POST, OPTIONS, PUT, DELETE",
                "Access-Control-Allow-Headers": "*",
                "Access-Control-Max-Age": "86400",
                "Content-Length": "0"
            ],
            body: Data()
        )
    }

    /// Serializes the response into wire-format HTTP/1.1 bytes.
    public func serialize() -> Data {
        var headerLines: [String] = []
        headerLines.append("HTTP/1.1 \(statusCode) \(statusText)")

        var finalHeaders = headers
        if finalHeaders["Access-Control-Allow-Origin"] == nil {
            finalHeaders["Access-Control-Allow-Origin"] = "*"
        }
        if finalHeaders["Content-Length"] == nil && !body.isEmpty {
            finalHeaders["Content-Length"] = "\(body.count)"
        }

        for (key, value) in finalHeaders {
            headerLines.append("\(key): \(value)")
        }

        let headerString = headerLines.joined(separator: "\r\n") + "\r\n\r\n"
        var data = headerString.data(using: .utf8) ?? Data()
        data.append(body)
        return data
    }
}

/// Asynchronous HTTP 1.1 bridge server built on Network.framework.
public final class HTTPServer: @unchecked Sendable {
    public let host: String
    public let port: UInt16
    public let modelService: SiriModelService
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.apple.siri-harness.server", attributes: .concurrent)

    public init(host: String = "127.0.0.1", port: UInt16 = 8080, modelService: SiriModelService = .shared) {
        self.host = host
        self.port = port
        self.modelService = modelService
    }

    /// Starts listening for incoming connections.
    public func start() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "SiriHarness", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid port: \(port)"])
        }

        let listener = try NWListener(using: parameters, on: nwPort)
        self.listener = listener

        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("Server listening on http://\(self.host):\(self.port)")
            case .failed(let error):
                fputs("Server encountered error: \(error.localizedDescription)\n", stderr)
            case .cancelled:
                print("Server stopped.")
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.handleNewConnection(connection)
        }

        listener.start(queue: queue)
    }

    /// Stops the server.
    public func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handleNewConnection(_ connection: NWConnection) {
        let handler = ConnectionHandler(connection: connection, server: self)
        handler.start()
    }

    func dispatchRequest(_ request: HTTPRequest, on connection: NWConnection) async {
        if request.method.uppercased() == "OPTIONS" {
            let response = HTTPResponse.corsPreflight()
            sendResponse(response, on: connection, closeAfter: true)
            return
        }

        let path = request.path

        switch (request.method.uppercased(), path) {
        case ("GET", "/"), ("GET", "/health"):
            let healthInfo: [String: Any] = [
                "status": "healthy",
                "service": "SiriHarness",
                "engine": "Apple Intelligence Foundation Model",
                "models": SiriModelService.supportedModels,
                "endpoints": [
                    "/health",
                    "/v1/models",
                    "/v1/chat/completions"
                ]
            ]
            if let jsonData = try? JSONSerialization.data(withJSONObject: healthInfo, options: [.prettyPrinted]) {
                let response = HTTPResponse(
                    statusCode: 200,
                    headers: [
                        "Content-Type": "application/json; charset=utf-8",
                        "Content-Length": "\(jsonData.count)",
                        "Access-Control-Allow-Origin": "*"
                    ],
                    body: jsonData
                )
                sendResponse(response, on: connection, closeAfter: true)
            }

        case ("GET", "/v1/models"):
            let models = SiriModelService.supportedModels.map { ModelObject(id: $0) }
            let response = ModelListResponse(data: models)
            let httpResponse = HTTPResponse.json(response)
            sendResponse(httpResponse, on: connection, closeAfter: true)

        case ("POST", "/v1/chat/completions"):
            await handleChatCompletions(request, on: connection)

        default:
            let notFound = HTTPResponse.rawJson("{\"error\": {\"message\": \"Resource not found: \(path)\", \"type\": \"invalid_request_error\"}}", statusCode: 404)
            sendResponse(notFound, on: connection, closeAfter: true)
        }
    }

    private func handleChatCompletions(_ request: HTTPRequest, on connection: NWConnection) async {
        do {
            let chatRequest = try JSONDecoder().decode(ChatCompletionRequest.self, from: request.body)

            if chatRequest.stream == true {
                let sseHeaders = [
                    "HTTP/1.1 200 OK",
                    "Content-Type: text/event-stream; charset=utf-8",
                    "Cache-Control: no-cache",
                    "Connection: keep-alive",
                    "Access-Control-Allow-Origin: *",
                    "Access-Control-Allow-Methods: GET, POST, OPTIONS",
                    "Access-Control-Allow-Headers: *"
                ].joined(separator: "\r\n") + "\r\n\r\n"

                guard let headerData = sseHeaders.data(using: .utf8) else {
                    connection.cancel()
                    return
                }

                connection.send(content: headerData, completion: .contentProcessed({ _ in }))

                let stream = try modelService.generateStream(request: chatRequest)
                let encoder = JSONEncoder()

                for try await chunk in stream {
                    if let chunkJson = try? encoder.encode(chunk),
                       let chunkString = String(data: chunkJson, encoding: .utf8) {
                        let eventPayload = "data: \(chunkString)\n\n"
                        if let eventData = eventPayload.data(using: .utf8) {
                            connection.send(content: eventData, completion: .contentProcessed({ _ in }))
                        }
                    }
                }

                let donePayload = "data: [DONE]\n\n"
                if let doneData = donePayload.data(using: .utf8) {
                    connection.send(content: doneData, completion: .contentProcessed({ _ in
                        connection.cancel()
                    }))
                } else {
                    connection.cancel()
                }

            } else {
                let completion = try await modelService.generate(request: chatRequest)
                let httpResponse = HTTPResponse.json(completion)
                sendResponse(httpResponse, on: connection, closeAfter: true)
            }
        } catch {
            let errorResponse = HTTPResponse.rawJson("{\"error\": {\"message\": \"\(error.localizedDescription)\", \"type\": \"api_error\"}}", statusCode: 500)
            sendResponse(errorResponse, on: connection, closeAfter: true)
        }
    }

    private func sendResponse(_ response: HTTPResponse, on connection: NWConnection, closeAfter: Bool) {
        let data = response.serialize()
        connection.send(content: data, completion: .contentProcessed({ _ in
            if closeAfter {
                connection.cancel()
            }
        }))
    }
}

final class ConnectionHandler: @unchecked Sendable {
    let connection: NWConnection
    let server: HTTPServer
    var buffer = Data()

    init(connection: NWConnection, server: HTTPServer) {
        self.connection = connection
        self.server = server
    }

    func start() {
        let queue = DispatchQueue(label: "com.apple.siri-harness.conn.\(UUID().uuidString)")
        connection.start(queue: queue)
        receiveNext()
    }

    func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            guard let self = self else { return }

            if let data = content, !data.isEmpty {
                self.buffer.append(data)

                let (possibleRequest, bytesConsumed) = HTTPRequest.parse(from: self.buffer)
                if let request = possibleRequest {
                    self.buffer.removeSubrange(0..<bytesConsumed)
                    Task {
                        await self.server.dispatchRequest(request, on: self.connection)
                    }
                    return
                }
            }

            if isComplete || error != nil {
                self.connection.cancel()
            } else {
                self.receiveNext()
            }
        }
    }
}
