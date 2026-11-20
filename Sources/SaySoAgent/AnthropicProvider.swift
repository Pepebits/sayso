import Foundation
import SaySoCore

/// Messages API de Anthropic.
public struct AnthropicProvider: ModelProvider {
    public let baseURL: URL
    public let fullModel: String
    public let fastModel: String
    public var supportsImages: Bool { true }
    private let apiKey: String
    private let transport: HTTPTransport

    public init(apiKey: String, baseURL: URL = URL(string: "https://api.anthropic.com")!,
                fullModel: String, fastModel: String, transport: HTTPTransport = URLSessionTransport()) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.fullModel = fullModel
        self.fastModel = fastModel
        self.transport = transport
    }

    public func complete(_ request: ModelRequest) async throws -> ModelResponse {
        let url = baseURL.appendingPathComponent("v1").appendingPathComponent("messages")
        let urlRequest = try URLRequest.postJSON(url, body: Self.body(for: request), headers: [
            "x-api-key": apiKey,
            "anthropic-version": "2023-06-01",
        ])
        return try Self.parse(await transport.sendJSON(urlRequest))
    }

    // MARK: Conversión

    static func body(for request: ModelRequest) -> JSONValue {
        var body: [String: JSONValue] = [
            "model": .string(request.model),
            "max_tokens": .number(Double(request.maxTokens)),
            "messages": .array(request.messages.map(encode)),
        ]
        if !request.system.isEmpty { body["system"] = .string(request.system) }
        if !request.tools.isEmpty {
            body["tools"] = .array(request.tools.map {
                ["name": .string($0.name), "description": .string($0.description), "input_schema": $0.inputSchema]
            })
        }
        return .object(body)
    }

    static func encode(_ message: ModelMessage) -> JSONValue {
        let blocks: [JSONValue] = message.content.map { block in
            switch block {
            case let .text(t):
                return ["type": "text", "text": .string(t)]
            case let .toolUse(id, name, input):
                return ["type": "tool_use", "id": .string(id), "name": .string(name), "input": input]
            case let .toolResult(id, content, isError):
                var r: [String: JSONValue] = ["type": "tool_result", "tool_use_id": .string(id), "content": .string(content)]
                if isError { r["is_error"] = true }
                return .object(r)
            case let .image(mediaType, data):
                return ["type": "image", "source": ["type": "base64", "media_type": .string(mediaType),
                                                    "data": .string(data.base64EncodedString())]]
            }
        }
        return ["role": .string(message.role.rawValue), "content": .array(blocks)]
    }

    static func parse(_ json: JSONValue) throws -> ModelResponse {
        guard let items = json["content"]?.arrayValue else {
            throw ProviderError.invalidResponse("falta «content»")
        }
        var blocks: [ContentBlock] = []
        for item in items {
            switch item["type"]?.stringValue {
            case "text":
                if let t = item["text"]?.stringValue { blocks.append(.text(t)) }
            case "tool_use":
                guard let id = item["id"]?.stringValue, let name = item["name"]?.stringValue else { continue }
                blocks.append(.toolUse(id: id, name: name, input: item["input"] ?? [:]))
            default:
                continue
            }
        }
        let stop: StopReason
        switch json["stop_reason"]?.stringValue {
        case "end_turn", "stop_sequence", nil: stop = .endTurn
        case "tool_use": stop = .toolUse
        case "max_tokens": stop = .maxTokens
        case let other?: stop = .other(other)
        }
        // Lo leído de caché también ocupa contexto.
        let usage = json["usage"]
        let input = usage?["input_tokens"]?.intValue.map {
            $0 + (usage?["cache_read_input_tokens"]?.intValue ?? 0) + (usage?["cache_creation_input_tokens"]?.intValue ?? 0)
        }
        return ModelResponse(content: blocks, stopReason: stop, inputTokens: input,
                             outputTokens: usage?["output_tokens"]?.intValue)
    }
}
