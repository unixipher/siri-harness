import Foundation

/// A single message entity within a chat completion request or response.
public struct ChatMessage: Codable, Sendable, Equatable {
    public var role: String
    public var content: String
    public var name: String?
    public var reasoning_content: String?
    public var reasoning: String?

    public init(
        role: String,
        content: String,
        name: String? = nil,
        reasoning_content: String? = nil,
        reasoning: String? = nil
    ) {
        self.role = role
        self.content = content
        self.name = name
        self.reasoning_content = reasoning_content
        self.reasoning = reasoning ?? reasoning_content
    }
}

/// Request parameters for chat completions compliant with the OpenAI specification.
public struct ChatCompletionRequest: Codable, Sendable {
    public var model: String?
    public var messages: [ChatMessage]
    public var temperature: Double?
    public var max_tokens: Int?
    public var max_completion_tokens: Int?
    public var stream: Bool?
    public var top_p: Double?
    public var reasoning_effort: String?

    public init(
        model: String? = nil,
        messages: [ChatMessage] = [],
        temperature: Double? = nil,
        max_tokens: Int? = nil,
        max_completion_tokens: Int? = nil,
        stream: Bool? = nil,
        top_p: Double? = nil,
        reasoning_effort: String? = nil
    ) {
        self.model = model
        self.messages = messages
        self.temperature = temperature
        self.max_tokens = max_tokens
        self.max_completion_tokens = max_completion_tokens
        self.stream = stream
        self.top_p = top_p
        self.reasoning_effort = reasoning_effort
    }

    public var effectiveMaxTokens: Int? {
        max_completion_tokens ?? max_tokens
    }

    public var topP: Double? {
        top_p
    }
}

/// Token usage metadata for completions.
public struct UsageInfo: Codable, Sendable, Equatable {
    public var prompt_tokens: Int
    public var completion_tokens: Int
    public var total_tokens: Int

    public init(prompt_tokens: Int = 0, completion_tokens: Int = 0, total_tokens: Int = 0) {
        self.prompt_tokens = prompt_tokens
        self.completion_tokens = completion_tokens
        self.total_tokens = total_tokens
    }
}

/// A completion choice returned by the model.
public struct ChatChoice: Codable, Sendable, Equatable {
    public var index: Int
    public var message: ChatMessage
    public var finish_reason: String?

    public init(index: Int = 0, message: ChatMessage, finish_reason: String? = "stop") {
        self.index = index
        self.message = message
        self.finish_reason = finish_reason
    }
}

/// Full chat completion response object.
public struct ChatCompletionResponse: Codable, Sendable {
    public var id: String
    public var object: String
    public var created: Int
    public var model: String
    public var choices: [ChatChoice]
    public var usage: UsageInfo?

    public init(
        id: String = "chatcmpl-" + UUID().uuidString,
        object: String = "chat.completion",
        created: Int = Int(Date().timeIntervalSince1970),
        model: String = "apple-intelligence",
        choices: [ChatChoice],
        usage: UsageInfo? = nil
    ) {
        self.id = id
        self.object = object
        self.created = created
        self.model = model
        self.choices = choices
        self.usage = usage
    }
}

/// Incremental content delta for streaming chunks.
public struct ChunkDelta: Codable, Sendable, Equatable {
    public var role: String?
    public var content: String?
    public var reasoning_content: String?
    public var reasoning: String?

    public init(
        role: String? = nil,
        content: String? = nil,
        reasoning_content: String? = nil,
        reasoning: String? = nil
    ) {
        self.role = role
        self.content = content
        self.reasoning_content = reasoning_content
        self.reasoning = reasoning ?? reasoning_content
    }
}

/// A choice object within a streaming completion chunk.
public struct ChunkChoice: Codable, Sendable, Equatable {
    public var index: Int
    public var delta: ChunkDelta
    public var finish_reason: String?

    public init(index: Int = 0, delta: ChunkDelta, finish_reason: String? = nil) {
        self.index = index
        self.delta = delta
        self.finish_reason = finish_reason
    }
}

/// A streaming chunk payload sent via Server-Sent Events.
public struct ChatCompletionChunk: Codable, Sendable {
    public var id: String
    public var object: String
    public var created: Int
    public var model: String
    public var choices: [ChunkChoice]
    public var usage: UsageInfo?

    public init(
        id: String,
        object: String = "chat.completion.chunk",
        created: Int = Int(Date().timeIntervalSince1970),
        model: String = "apple-intelligence",
        choices: [ChunkChoice],
        usage: UsageInfo? = nil
    ) {
        self.id = id
        self.object = object
        self.created = created
        self.model = model
        self.choices = choices
        self.usage = usage
    }
}

/// Model descriptor returned in model listing queries.
public struct ModelObject: Codable, Sendable {
    public var id: String
    public var object: String
    public var created: Int
    public var owned_by: String

    public init(
        id: String,
        object: String = "model",
        created: Int = 1717977600,
        owned_by: String = "apple"
    ) {
        self.id = id
        self.object = object
        self.created = created
        self.owned_by = owned_by
    }
}

/// List of available models.
public struct ModelListResponse: Codable, Sendable {
    public var object: String
    public var data: [ModelObject]

    public init(object: String = "list", data: [ModelObject]) {
        self.object = object
        self.data = data
    }
}
