import Foundation
import FoundationModels

/// Service interface coordinating interactions with Apple's FoundationModels framework.
public final class SiriModelService: Sendable {
    public static let shared = SiriModelService()

    /// Standard supported model identifier aliases.
    public static let supportedModels = [
        "siri",
        "siri-model",
        "apple-intelligence",
        "apple/system-language-model",
        "default"
    ]

    public init() {}

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
    private func createSessionAndPrompt(from messages: [ChatMessage]) throws -> (LanguageModelSession, String) {
        guard !messages.isEmpty else {
            let session = LanguageModelSession()
            return (session, "")
        }

        let systemInstructions = messages
            .filter { $0.role == "system" }
            .map(\.content)
            .joined(separator: "\n\n")

        let nonSystemMessages = messages.filter { $0.role != "system" }

        guard let lastMessage = nonSystemMessages.last else {
            let session = LanguageModelSession(instructions: systemInstructions.isEmpty ? nil : systemInstructions)
            return (session, "")
        }

        let promptText = lastMessage.content
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
            switch message.role.lowercased() {
            case "assistant":
                transcriptEntries.append(
                    .response(
                        .init(
                            id: UUID().uuidString,
                            assetIDs: [],
                            segments: [.text(.init(content: message.content))]
                        )
                    )
                )
            default:
                transcriptEntries.append(
                    .prompt(
                        .init(
                            segments: [.text(.init(content: message.content))],
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

        let usage = UsageInfo(
            prompt_tokens: response.usage.input.totalTokenCount,
            completion_tokens: response.usage.output.totalTokenCount,
            total_tokens: response.usage.totalTokenCount
        )

        let choice = ChatChoice(
            index: 0,
            message: ChatMessage(role: "assistant", content: response.content),
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
                                        delta: ChunkDelta(role: deltaRole, content: deltaContent.isEmpty ? nil : deltaContent),
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
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
