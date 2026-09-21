import Foundation
import FoundationModels

/// Error thrown when a dynamic tool is executed by the foundation model.
/// We intercept the invocation to package and return standard OpenAI `tool_calls`.
public struct ToolCallInterceptionError: Error, Sendable {
    public let toolCall: ToolCall

    public init(toolCall: ToolCall) {
        self.toolCall = toolCall
    }
}

/// A dynamic wrapper conforming to Apple's native `FoundationModels.Tool` protocol.
/// Converts an OpenAI `ToolDefinition` into an Apple `GenerationSchema` and intercepts calls.
public struct DynamicTool: Tool, Sendable {
    public typealias Arguments = GeneratedContent
    public typealias Output = String

    public let name: String
    public let description: String
    public let parameters: GenerationSchema
    public let includesSchemaInInstructions: Bool = true

    public init(definition: ToolDefinition) {
        self.name = definition.function.name
        self.description = definition.function.description ?? "Invokes \(definition.function.name)"

        var schemaProperties: [GenerationSchema.Property] = []

        if let params = definition.function.parameters,
           case .object(let dict) = params,
           let props = dict["properties"],
           case .object(let propDict) = props {

            for (propName, propVal) in propDict {
                var propDesc: String? = nil

                if case .object(let p) = propVal {
                    if let d = p["description"], case .string(let s) = d {
                        propDesc = s
                    }
                    if let t = p["type"], case .string(let typeStr) = t {
                        switch typeStr.lowercased() {
                        case "number":
                            schemaProperties.append(GenerationSchema.Property(name: propName, description: propDesc, type: Double.self))
                            continue
                        case "integer":
                            schemaProperties.append(GenerationSchema.Property(name: propName, description: propDesc, type: Int.self))
                            continue
                        case "boolean":
                            schemaProperties.append(GenerationSchema.Property(name: propName, description: propDesc, type: Bool.self))
                            continue
                        default:
                            break
                        }
                    }
                }
                schemaProperties.append(GenerationSchema.Property(name: propName, description: propDesc, type: String.self))
            }
        }

        self.parameters = GenerationSchema(
            type: GeneratedContent.self,
            description: self.description,
            properties: schemaProperties
        )
    }

    public func call(arguments: GeneratedContent) async throws -> String {
        let jsonArgs = arguments.jsonString
        let toolCall = ToolCall(
            id: "call_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12),
            type: "function",
            function: FunctionCall(name: name, arguments: jsonArgs)
        )
        throw ToolCallInterceptionError(toolCall: toolCall)
    }
}
