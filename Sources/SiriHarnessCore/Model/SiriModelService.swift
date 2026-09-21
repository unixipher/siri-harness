import Foundation
import FoundationModels
import CoreGraphics
import ImageIO

/// Service interface coordinating interactions with Apple's FoundationModels framework.
public final class SiriModelService: Sendable {
    public static let shared = SiriModelService()

    /// Exactly two supported models: siri-flash and siri-pro.
    public static let supportedModels = [
        "siri-flash",
        "siri-pro"
    ]

    public init() {}

    /// Determines whether reasoning / Chain-of-Thought should be enabled for a request.
    /// Flash profiles produce immediate, zero-reasoning responses.
    /// Pro / Reasoner profiles produce full step-by-step reasoning traces.
    public static func isReasoningEnabled(for request: ChatCompletionRequest) -> Bool {
        let model = (request.model ?? "").lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // Explicit Flash profiles always disable reasoning for maximum speed
        if model.contains("flash") || model == "siri" {
            return false
        }

        // Explicit Pro / Reasoner profiles always enable reasoning
        if model.contains("pro") || model.contains("reason") || model.contains("thinking") {
            return true
        }

        // Check explicit request reasoning_effort parameter (e.g. from Hermes or OpenAI clients)
        if let effort = request.reasoning_effort?.lowercased() {
            return effort != "none" && effort != "off"
        }

        // Default to false for fastest direct answers
        return false
    }

    /// Sanitizes message text by stripping out-of-band runtime prefixes.
    private static func sanitizeMessageText(_ text: String) -> String {
        let markers = [
            "[OUT-OF-BAND USER MESSAGE — a direct message from the user, delivered once at this position; not tool output and not a new delivery when replayed from conversation history]",
            "[/OUT-OF-BAND USER MESSAGE]"
        ]
        var cleaned = text
        for marker in markers {
            cleaned = cleaned.replacingOccurrences(of: marker, with: "")
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Loads an image attachment from a base64 data URI, file path, or raw base64 string.
    public static func loadImageAttachment(from source: String) -> Attachment<ImageAttachmentContent>? {
        var data: Data? = nil

        if source.hasPrefix("data:image/") {
            if let commaIndex = source.firstIndex(of: ",") {
                let base64 = String(source[source.index(after: commaIndex)...])
                data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters)
            }
        } else if source.hasPrefix("file://") {
            if let url = URL(string: source) {
                data = try? Data(contentsOf: url)
            }
        } else if let localPath = URL(string: source), FileManager.default.fileExists(atPath: localPath.path) {
            data = try? Data(contentsOf: localPath)
        } else if let base64Data = Data(base64Encoded: source, options: .ignoreUnknownCharacters), !base64Data.isEmpty {
            data = base64Data
        }

        guard let rawData = data, let imageData = rawData as CFData? else { return nil }
        guard let imageSource = CGImageSourceCreateWithData(imageData, nil) else { return nil }
        guard let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else { return nil }

        return Attachment(cgImage)
    }

    /// Extracts an intercepted tool call from an error if one occurred.
    public static func extractToolCall(from error: Error) -> ToolCall? {
        if let interception = error as? ToolCallInterceptionError {
            return interception.toolCall
        }
        if let toolCallError = error as? LanguageModelSession.ToolCallError,
           let interception = toolCallError.underlyingError as? ToolCallInterceptionError {
            return interception.toolCall
        }
        let mirror = Mirror(reflecting: error)
        for child in mirror.children {
            if let interception = child.value as? ToolCallInterceptionError {
                return interception.toolCall
            }
            let childMirror = Mirror(reflecting: child.value)
            for subChild in childMirror.children {
                if let interception = subChild.value as? ToolCallInterceptionError {
                    return interception.toolCall
                }
            }
        }
        return nil
    }

    /// Converts a Foundation JSON object (Dictionary, Array, String, Number, Bool) into Apple's GeneratedContent.
    public static func jsonObjectToGeneratedContent(_ obj: Any) -> GeneratedContent {
        if let str = obj as? String {
            return GeneratedContent(kind: .string(str))
        } else if let num = obj as? NSNumber {
            if CFGetTypeID(num) == CFBooleanGetTypeID() {
                return GeneratedContent(kind: .bool(num.boolValue))
            } else {
                return GeneratedContent(kind: .number(num.doubleValue))
            }
        } else if let dict = obj as? [String: Any] {
            var props: [String: GeneratedContent] = [:]
            var keys: [String] = []
            for (k, v) in dict {
                props[k] = jsonObjectToGeneratedContent(v)
                keys.append(k)
            }
            return GeneratedContent(kind: .structure(properties: props, orderedKeys: keys))
        } else if let arr = obj as? [Any] {
            return GeneratedContent(kind: .array(arr.map { jsonObjectToGeneratedContent($0) }))
        }
        return GeneratedContent(kind: .null)
    }

    /// Extracts reasoning content from <think> or <thought> tags.
    public static func extractReasoning(from rawText: String) -> (reasoning: String?, content: String) {
        let text = sanitizeMessageText(rawText)

        // Pattern matching <think>...</think> or <thought>...</thought>
        let thinkPatterns = [
            ("<think>", "</think>"),
            ("<thought>", "</thought>")
        ]

        for (openTag, closeTag) in thinkPatterns {
            if let openRange = text.range(of: openTag) {
                if let closeRange = text.range(of: closeTag, range: openRange.upperBound..<text.endIndex) {
                    let reasoning = String(text[openRange.upperBound..<closeRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                    var content = (String(text[..<openRange.lowerBound]) + String(text[closeRange.upperBound...])).trimmingCharacters(in: .whitespacesAndNewlines)
                    content = sanitizeMessageText(content)
                    content = normalizeContentFormat(content)
                    return (reasoning.isEmpty ? nil : reasoning, content)
                } else {
                    // Tag opened but not closed
                    let reasoning = String(text[openRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    var content = String(text[..<openRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                    content = sanitizeMessageText(content)
                    content = normalizeContentFormat(content)
                    return (reasoning.isEmpty ? nil : reasoning, content)
                }
            }
        }

        let normalized = normalizeContentFormat(text)
        return (nil, normalized)
    }

    /// Unwraps simulated tool call or mock search JSON payloads into natural human-readable text.
    public static func normalizeContentFormat(_ text: String) -> String {
        var clean = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if clean.hasPrefix("```") {
            let lines = clean.components(separatedBy: .newlines)
            if lines.count >= 3 && lines.last?.trimmingCharacters(in: .whitespaces).hasPrefix("```") == true {
                let inner = lines.dropFirst().dropLast().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if inner.hasPrefix("{") && inner.hasSuffix("}") {
                    clean = inner
                }
            }
        }

        guard clean.hasPrefix("{") && clean.hasSuffix("}") else {
            return text
        }

        guard let data = clean.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return text
        }

        if let result = dict["web_search_result"] as? String, !result.isEmpty {
            return result
        }
        if let answer = dict["answer"] as? String, !answer.isEmpty {
            return answer
        }
        if let response = dict["response"] as? String, !response.isEmpty {
            return response
        }
        if let message = dict["message"] as? String, !message.isEmpty, !message.contains("Searching for") {
            return message
        }

        return text
    }

    /// Configures generation parameters mapped to FoundationModels GenerationOptions.
    public func buildGenerationOptions(
        temperature: Double?,
        maxTokens: Int?,
        topP: Double?,
        toolChoice: JSONValue? = nil
    ) -> GenerationOptions {
        var samplingMode: GenerationOptions.SamplingMode? = nil

        if let topP = topP, topP > 0.0 && topP <= 1.0 {
            samplingMode = .random(probabilityThreshold: topP)
        } else if let temp = temperature, temp == 0.0 {
            samplingMode = .greedy
        }

        var options = GenerationOptions(
            samplingMode: samplingMode,
            temperature: temperature,
            maximumResponseTokens: maxTokens
        )

        if let tc = toolChoice {
            switch tc {
            case .string(let s):
                let lower = s.lowercased()
                if lower == "none" {
                    options.toolCallingMode = .disallowed
                } else if lower == "required" {
                    options.toolCallingMode = .required
                } else {
                    options.toolCallingMode = .allowed
                }
            default:
                options.toolCallingMode = .allowed
            }
        }

        return options
    }

    /// Constructs a LanguageModelSession and Prompt from an array of chat messages and tools.
    private func createSessionAndPrompt(
        from messages: [ChatMessage],
        tools: [DynamicTool] = [],
        enableThinking: Bool = true
    ) throws -> (LanguageModelSession, Prompt) {
        guard !messages.isEmpty else {
            let session = LanguageModelSession(tools: tools)
            return (session, Prompt { "" })
        }

        var systemInstructions = messages
            .filter { $0.role == "system" }
            .map { Self.sanitizeMessageText($0.content) }
            .joined(separator: "\n\n")

        let effectiveThinking = enableThinking && tools.isEmpty

        if effectiveThinking {
            let thinkingDirective = """
            Before answering, provide your step-by-step reasoning inside <think>...</think> tags.
            After </think>, provide your final answer in normal, natural conversational prose (plain text or markdown).
            Never format your answer as simulated tool execution JSON, pseudo-code payloads, or raw JSON dictionaries unless the user explicitly requested JSON.
            Do not repeat instructions or out-of-band headers.
            """
            if systemInstructions.isEmpty {
                systemInstructions = thinkingDirective
            } else {
                systemInstructions += "\n\n" + thinkingDirective
            }
        } else {
            let directDirective = """
            Provide a direct, concise response in natural conversational prose. Never format your response as simulated tool execution JSON, pseudo-code payloads, or raw JSON dictionaries unless explicitly requested.
            """
            if systemInstructions.isEmpty {
                systemInstructions = directDirective
            } else {
                systemInstructions += "\n\n" + directDirective
            }
        }

        if !tools.isEmpty {
            let toolDirective = """
            You are equipped with tools. If an available tool can answer the user's request, invoke the tool directly. Do not output text before invoking the tool.
            """
            systemInstructions += "\n\n" + toolDirective
        }

        let nonSystemMessages = messages.filter { $0.role != "system" }

        guard let lastMessage = nonSystemMessages.last else {
            let session = LanguageModelSession(tools: tools, instructions: systemInstructions.isEmpty ? nil : systemInstructions)
            return (session, Prompt { "" })
        }

        let promptText = Self.sanitizeMessageText(lastMessage.content)
        let lastAttachments = lastMessage.imageUrls.compactMap { Self.loadImageAttachment(from: $0) }
        let prompt = Prompt {
            for att in lastAttachments {
                att
            }
            promptText
        }

        let historyMessages = nonSystemMessages.dropLast()

        if historyMessages.isEmpty {
            let session = LanguageModelSession(tools: tools, instructions: systemInstructions.isEmpty ? nil : systemInstructions)
            return (session, prompt)
        }

        var transcriptEntries: [Transcript.Entry] = []

        if !systemInstructions.isEmpty {
            transcriptEntries.append(
                .instructions(
                    .init(
                        segments: [.text(.init(content: systemInstructions))],
                        toolDefinitions: []
                    )
                )
            )
        }

        for message in historyMessages {
            let cleanContent = Self.sanitizeMessageText(message.content)
            switch message.role.lowercased() {
            case "assistant":
                if let toolCalls = message.tool_calls, !toolCalls.isEmpty {
                    let appleCalls = toolCalls.map { tc in
                        var generatedContent = GeneratedContent(kind: .structure(properties: [:], orderedKeys: []))
                        if let data = tc.function.arguments.data(using: .utf8),
                           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                            generatedContent = Self.jsonObjectToGeneratedContent(dict)
                        }
                        return Transcript.ToolCall(id: tc.id, toolName: tc.function.name, arguments: generatedContent)
                    }
                    transcriptEntries.append(.toolCalls(Transcript.ToolCalls(appleCalls)))
                } else {
                    transcriptEntries.append(
                        .response(
                            .init(
                                id: UUID().uuidString,
                                assetIDs: [],
                                segments: [.text(.init(content: cleanContent))]
                            )
                        )
                    )
                }
            case "tool":
                let callId = message.tool_call_id ?? UUID().uuidString
                let toolName = message.name ?? "tool"
                transcriptEntries.append(
                    .toolOutput(
                        Transcript.ToolOutput(
                            id: callId,
                            toolName: toolName,
                            segments: [.text(.init(content: cleanContent))]
                        )
                    )
                )
            default:
                var segments: [Transcript.Segment] = []
                segments.append(.text(.init(content: cleanContent)))
                transcriptEntries.append(
                    .prompt(
                        .init(
                            segments: segments,
                            options: GenerationOptions()
                        )
                    )
                )
            }
        }

        let transcript = Transcript(entries: transcriptEntries)
        let session = LanguageModelSession(tools: tools, transcript: transcript)
        return (session, prompt)
    }

    /// Performs a non-streaming chat completion.
    public func generate(request: ChatCompletionRequest) async throws -> ChatCompletionResponse {
        let enableThinking = Self.isReasoningEnabled(for: request)
        let dynamicTools = (request.tools ?? []).map { DynamicTool(definition: $0) }
        let (session, prompt) = try createSessionAndPrompt(
            from: request.messages,
            tools: dynamicTools,
            enableThinking: enableThinking
        )
        let options = buildGenerationOptions(
            temperature: request.temperature,
            maxTokens: request.effectiveMaxTokens,
            topP: request.topP,
            toolChoice: request.tool_choice
        )
        let modelName = request.model ?? (enableThinking ? "siri-pro" : "siri-flash")

        do {
            let response = try await session.respond(to: prompt, options: options)

            let (reasoning, content) = enableThinking
                ? Self.extractReasoning(from: response.content)
                : (nil, Self.normalizeContentFormat(Self.sanitizeMessageText(response.content)))

            let usage = UsageInfo(
                prompt_tokens: response.usage.input.totalTokenCount,
                completion_tokens: response.usage.output.totalTokenCount,
                total_tokens: response.usage.totalTokenCount
            )

            let choice = ChatChoice(
                index: 0,
                message: ChatMessage(
                    role: "assistant",
                    content: content,
                    reasoning_content: reasoning,
                    reasoning: reasoning
                ),
                finish_reason: "stop"
            )

            return ChatCompletionResponse(
                id: "chatcmpl-" + UUID().uuidString,
                object: "chat.completion",
                created: Int(Date().timeIntervalSince1970),
                model: modelName,
                choices: [choice],
                usage: usage
            )
        } catch {
            if let toolCall = Self.extractToolCall(from: error) {
                let choice = ChatChoice(
                    index: 0,
                    message: ChatMessage(
                        role: "assistant",
                        content: "",
                        tool_calls: [toolCall]
                    ),
                    finish_reason: "tool_calls"
                )
                return ChatCompletionResponse(
                    id: "chatcmpl-" + UUID().uuidString,
                    object: "chat.completion",
                    created: Int(Date().timeIntervalSince1970),
                    model: modelName,
                    choices: [choice],
                    usage: nil
                )
            }
            throw error
        }
    }

    /// Performs a streaming chat completion, yielding chunks as they are generated.
    public func generateStream(
        request: ChatCompletionRequest
    ) throws -> AsyncThrowingStream<ChatCompletionChunk, Error> {
        let completionId = "chatcmpl-" + UUID().uuidString
        let enableThinking = Self.isReasoningEnabled(for: request)
        let dynamicTools = (request.tools ?? []).map { DynamicTool(definition: $0) }
        let modelName = request.model ?? (enableThinking ? "siri-pro" : "siri-flash")
        let created = Int(Date().timeIntervalSince1970)

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let (session, prompt) = try self.createSessionAndPrompt(
                        from: request.messages,
                        tools: dynamicTools,
                        enableThinking: enableThinking
                    )
                    let options = self.buildGenerationOptions(
                        temperature: request.temperature,
                        maxTokens: request.effectiveMaxTokens,
                        topP: request.topP,
                        toolChoice: request.tool_choice
                    )
                    let responseStream = session.streamResponse(to: prompt, options: options)

                    var previousContent = ""
                    var hasSentRole = false
                    var lastUsage: UsageInfo? = nil
                    let reasoningParser = enableThinking ? StreamingReasoningParser() : nil

                    do {
                        for try await chunk in responseStream {
                            let fullContent = chunk.content
                            let deltaContent: String
                            if fullContent.hasPrefix(previousContent) {
                                deltaContent = String(fullContent.dropFirst(previousContent.count))
                            } else {
                                deltaContent = fullContent
                            }
                            previousContent = fullContent

                            lastUsage = UsageInfo(
                                prompt_tokens: chunk.usage.input.totalTokenCount,
                                completion_tokens: chunk.usage.output.totalTokenCount,
                                total_tokens: chunk.usage.totalTokenCount
                            )

                            if let parser = reasoningParser {
                                let parsedItems = parser.process(delta: deltaContent)
                                for item in parsedItems {
                                    let deltaRole: String? = hasSentRole ? nil : "assistant"
                                    hasSentRole = true

                                    let chunkObject = ChatCompletionChunk(
                                        id: completionId,
                                        object: "chat.completion.chunk",
                                        created: created,
                                        model: modelName,
                                        choices: [
                                            ChunkChoice(
                                                index: 0,
                                                delta: ChunkDelta(
                                                    role: deltaRole,
                                                    content: item.content,
                                                    reasoning_content: item.reasoning,
                                                    reasoning: item.reasoning
                                                ),
                                                finish_reason: nil
                                            )
                                        ],
                                        usage: nil
                                    )
                                    continuation.yield(chunkObject)
                                }
                            } else {
                                // Flash mode: direct instant streaming without reasoning delay
                                let deltaRole: String? = hasSentRole ? nil : "assistant"
                                hasSentRole = true

                                if !deltaContent.isEmpty || deltaRole != nil {
                                    let chunkObject = ChatCompletionChunk(
                                        id: completionId,
                                        object: "chat.completion.chunk",
                                        created: created,
                                        model: modelName,
                                        choices: [
                                            ChunkChoice(
                                                index: 0,
                                                delta: ChunkDelta(
                                                    role: deltaRole,
                                                    content: deltaContent.isEmpty ? nil : deltaContent,
                                                    reasoning_content: nil,
                                                    reasoning: nil
                                                ),
                                                finish_reason: nil
                                            )
                                        ],
                                        usage: nil
                                    )
                                    continuation.yield(chunkObject)
                                }
                            }
                        }

                        if let parser = reasoningParser {
                            for item in parser.flush() {
                                let deltaRole: String? = hasSentRole ? nil : "assistant"
                                hasSentRole = true

                                let chunkObject = ChatCompletionChunk(
                                    id: completionId,
                                    object: "chat.completion.chunk",
                                    created: created,
                                    model: modelName,
                                    choices: [
                                        ChunkChoice(
                                            index: 0,
                                            delta: ChunkDelta(
                                                role: deltaRole,
                                                content: item.content,
                                                reasoning_content: item.reasoning,
                                                reasoning: item.reasoning
                                            ),
                                            finish_reason: nil
                                        )
                                    ],
                                    usage: nil
                                )
                                continuation.yield(chunkObject)
                            }
                        }

                        let finalChunk = ChatCompletionChunk(
                            id: completionId,
                            object: "chat.completion.chunk",
                            created: created,
                            model: modelName,
                            choices: [
                                ChunkChoice(
                                    index: 0,
                                    delta: ChunkDelta(role: nil, content: nil),
                                    finish_reason: "stop"
                                )
                            ],
                            usage: lastUsage
                        )
                        continuation.yield(finalChunk)
                        continuation.finish()
                    } catch {
                        if let toolCall = Self.extractToolCall(from: error) {
                            let toolChunk = ChatCompletionChunk(
                                id: completionId,
                                object: "chat.completion.chunk",
                                created: created,
                                model: modelName,
                                choices: [
                                    ChunkChoice(
                                        index: 0,
                                        delta: ChunkDelta(
                                            role: "assistant",
                                            content: nil,
                                            tool_calls: [
                                                ToolCallChunk(
                                                    index: 0,
                                                    id: toolCall.id,
                                                    type: "function",
                                                    function: FunctionCallChunk(
                                                        name: toolCall.function.name,
                                                        arguments: toolCall.function.arguments
                                                    )
                                                )
                                            ]
                                        ),
                                        finish_reason: "tool_calls"
                                    )
                                ],
                                usage: nil
                            )
                            continuation.yield(toolChunk)
                            continuation.finish()
                        } else {
                            throw error
                        }
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

/// Incrementally extracts <think>...</think> reasoning traces from streaming tokens.
final class StreamingReasoningParser: @unchecked Sendable {
    private enum State {
        case pendingTag
        case insideThinking
        case insideContent
    }

    private var state: State = .pendingTag
    private var buffer = ""

    func process(delta: String) -> [(reasoning: String?, content: String?)] {
        buffer += delta
        var results: [(reasoning: String?, content: String?)] = []

        while !buffer.isEmpty {
            switch state {
            case .pendingTag:
                if buffer.hasPrefix("<think>") {
                    buffer.removeFirst("<think>".count)
                    state = .insideThinking
                } else if buffer.hasPrefix("<thought>") {
                    buffer.removeFirst("<thought>".count)
                    state = .insideThinking
                } else if "<think>".hasPrefix(buffer) || "<thought>".hasPrefix(buffer) {
                    return results
                } else {
                    state = .insideContent
                    let toYield = buffer
                    buffer = ""
                    results.append((reasoning: nil, content: toYield))
                }

            case .insideThinking:
                let closeThink = "</think>"
                let closeThought = "</thought>"

                if let range = buffer.range(of: closeThink) {
                    let reasoningPart = String(buffer[..<range.lowerBound])
                    buffer.removeSubrange(..<range.upperBound)
                    state = .insideContent
                    if !reasoningPart.isEmpty {
                        results.append((reasoning: reasoningPart, content: nil))
                    }
                } else if let range = buffer.range(of: closeThought) {
                    let reasoningPart = String(buffer[..<range.lowerBound])
                    buffer.removeSubrange(..<range.upperBound)
                    state = .insideContent
                    if !reasoningPart.isEmpty {
                        results.append((reasoning: reasoningPart, content: nil))
                    }
                } else {
                    let safeCount = buffer.count - min(buffer.count, closeThink.count)
                    if safeCount > 0 {
                        let index = buffer.index(buffer.startIndex, offsetBy: safeCount)
                        let safeReasoning = String(buffer[..<index])
                        buffer.removeSubrange(..<index)
                        results.append((reasoning: safeReasoning, content: nil))
                    }
                    return results
                }

            case .insideContent:
                let toYield = buffer
                buffer = ""
                results.append((reasoning: nil, content: toYield))
            }
        }

        return results
    }

    func flush() -> [(reasoning: String?, content: String?)] {
        guard !buffer.isEmpty else { return [] }
        let remaining = buffer
        buffer = ""
        switch state {
        case .pendingTag, .insideContent:
            return [(reasoning: nil, content: remaining)]
        case .insideThinking:
            return [(reasoning: remaining, content: nil)]
        }
    }
}
