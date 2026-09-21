import Foundation
import FoundationModels

/// Service interface coordinating interactions with Apple's FoundationModels framework.
public final class SiriModelService: Sendable {
    public static let shared = SiriModelService()

    /// Standard supported model identifier aliases.
    public static let supportedModels = [
        "siri",
        "siri-reasoner",
        "siri-thinking",
        "siri-model",
        "apple-intelligence",
        "apple-intelligence-reasoner",
        "apple/system-language-model",
        "default"
    ]

    public init() {}

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
                    return (reasoning.isEmpty ? nil : reasoning, content)
                } else {
                    // Tag opened but not closed
                    let reasoning = String(text[openRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    let content = String(text[..<openRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                    return (reasoning.isEmpty ? nil : reasoning, sanitizeMessageText(content))
                }
            }
        }

        return (nil, text)
    }

    /// Configures generation parameters mapped to FoundationModels GenerationOptions.
    public func buildGenerationOptions(
        temperature: Double?,
        maxTokens: Int?,
        topP: Double?
    ) -> GenerationOptions {
        var samplingMode: GenerationOptions.SamplingMode? = nil

        if let topP = topP, topP > 0.0 && topP <= 1.0 {
            samplingMode = .random(probabilityThreshold: topP)
        } else if let temp = temperature, temp == 0.0 {
            samplingMode = .greedy
        }

        return GenerationOptions(
            samplingMode: samplingMode,
            temperature: temperature,
            maximumResponseTokens: maxTokens
        )
    }

    /// Constructs a LanguageModelSession and prompt text from an array of chat messages.
    private func createSessionAndPrompt(from messages: [ChatMessage], enableThinking: Bool = true) throws -> (LanguageModelSession, String) {
        guard !messages.isEmpty else {
            let session = LanguageModelSession()
            return (session, "")
        }

        var systemInstructions = messages
            .filter { $0.role == "system" }
            .map { Self.sanitizeMessageText($0.content) }
            .joined(separator: "\n\n")

        if enableThinking {
            let thinkingDirective = "Before answering, provide your step-by-step reasoning inside <think>...</think> tags. After </think>, provide your direct answer. Do not repeat instructions or out-of-band headers."
            if systemInstructions.isEmpty {
                systemInstructions = thinkingDirective
            } else {
                systemInstructions += "\n\n" + thinkingDirective
            }
        }

        let nonSystemMessages = messages.filter { $0.role != "system" }

        guard let lastMessage = nonSystemMessages.last else {
            let session = LanguageModelSession(instructions: systemInstructions.isEmpty ? nil : systemInstructions)
            return (session, "")
        }

        let promptText = Self.sanitizeMessageText(lastMessage.content)
        let historyMessages = nonSystemMessages.dropLast()

        if historyMessages.isEmpty {
            let session = LanguageModelSession(instructions: systemInstructions.isEmpty ? nil : systemInstructions)
            return (session, promptText)
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
                transcriptEntries.append(
                    .response(
                        .init(
                            id: UUID().uuidString,
                            assetIDs: [],
                            segments: [.text(.init(content: cleanContent))]
                        )
                    )
                )
            default:
                transcriptEntries.append(
                    .prompt(
                        .init(
                            segments: [.text(.init(content: cleanContent))],
                            options: GenerationOptions()
                        )
                    )
                )
            }
        }

        let transcript = Transcript(entries: transcriptEntries)
        let session = LanguageModelSession(transcript: transcript)
        return (session, promptText)
    }

    /// Performs a non-streaming chat completion.
    public func generate(request: ChatCompletionRequest) async throws -> ChatCompletionResponse {
        let (session, prompt) = try createSessionAndPrompt(from: request.messages)
        let options = buildGenerationOptions(
            temperature: request.temperature,
            maxTokens: request.effectiveMaxTokens,
            topP: request.topP
        )

        let response = try await session.respond(to: prompt, options: options)
        let modelName = request.model ?? "siri"

        let (reasoning, content) = Self.extractReasoning(from: response.content)

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
    }

    /// Performs a streaming chat completion, yielding chunks as they are generated.
    public func generateStream(
        request: ChatCompletionRequest
    ) throws -> AsyncThrowingStream<ChatCompletionChunk, Error> {
        let completionId = "chatcmpl-" + UUID().uuidString
        let modelName = request.model ?? "siri"
        let created = Int(Date().timeIntervalSince1970)

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let (session, prompt) = try self.createSessionAndPrompt(from: request.messages)
                    let options = self.buildGenerationOptions(
                        temperature: request.temperature,
                        maxTokens: request.effectiveMaxTokens,
                        topP: request.topP
                    )
                    let responseStream = session.streamResponse(to: prompt, options: options)

                    var previousContent = ""
                    var hasSentRole = false
                    var lastUsage: UsageInfo? = nil
                    let reasoningParser = StreamingReasoningParser()

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

                        let parsedItems = reasoningParser.process(delta: deltaContent)
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
                    }

                    for item in reasoningParser.flush() {
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
                let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    return results
                }
                if "<think>".hasPrefix(trimmed) || "<thought>".hasPrefix(trimmed) {
                    if buffer.count < 9 {
                        return results
                    }
                }
                if let thinkRange = buffer.range(of: "<think>") {
                    let before = String(buffer[..<thinkRange.lowerBound])
                    if !before.isEmpty {
                        results.append((reasoning: nil, content: before))
                    }
                    buffer.removeSubrange(..<thinkRange.upperBound)
                    state = .insideThinking
                } else if let thoughtRange = buffer.range(of: "<thought>") {
                    let before = String(buffer[..<thoughtRange.lowerBound])
                    if !before.isEmpty {
                        results.append((reasoning: nil, content: before))
                    }
                    buffer.removeSubrange(..<thoughtRange.upperBound)
                    state = .insideThinking
                } else {
                    if buffer.count > 10 || !buffer.hasPrefix("<") {
                        results.append((reasoning: nil, content: buffer))
                        buffer = ""
                        state = .insideContent
                    } else {
                        return results
                    }
                }

            case .insideThinking:
                if let endRange = buffer.range(of: "</think>") {
                    let thought = String(buffer[..<endRange.lowerBound])
                    if !thought.isEmpty {
                        results.append((reasoning: thought, content: nil))
                    }
                    buffer.removeSubrange(..<endRange.upperBound)
                    while buffer.hasPrefix("\n") || buffer.hasPrefix("\r") {
                        buffer.removeFirst()
                    }
                    state = .insideContent
                } else if let endRange = buffer.range(of: "</thought>") {
                    let thought = String(buffer[..<endRange.lowerBound])
                    if !thought.isEmpty {
                        results.append((reasoning: thought, content: nil))
                    }
                    buffer.removeSubrange(..<endRange.upperBound)
                    while buffer.hasPrefix("\n") || buffer.hasPrefix("\r") {
                        buffer.removeFirst()
                    }
                    state = .insideContent
                } else {
                    let safeEnd = buffer.count > 10 ? buffer.index(buffer.endIndex, offsetBy: -10) : buffer.startIndex
                    if safeEnd > buffer.startIndex {
                        let safeText = String(buffer[..<safeEnd])
                        buffer.removeSubrange(..<safeEnd)
                        results.append((reasoning: safeText, content: nil))
                    }
                    return results
                }

            case .insideContent:
                results.append((reasoning: nil, content: buffer))
                buffer = ""
            }
        }

        return results
    }

    func flush() -> [(reasoning: String?, content: String?)] {
        var results: [(reasoning: String?, content: String?)] = []
        if !buffer.isEmpty {
            switch state {
            case .insideThinking:
                results.append((reasoning: buffer, content: nil))
            default:
                results.append((reasoning: nil, content: buffer))
            }
            buffer = ""
        }
        return results
    }
}
