import Foundation
import SaySoCore

/// Chat Completions: OpenAI, OpenRouter, xAI, Ollama, LM Studio.
public struct OpenAICompatibleProvider: ModelProvider {
    public let baseURL: URL
    public let fullModel: String
    public let fastModel: String
    /// Opcional: los modelos locales no la necesitan.
    private let apiKey: String?
    private let transport: HTTPTransport
    public let supportsImages: Bool

    public init(baseURL: URL, apiKey: String?, fullModel: String, fastModel: String,
                transport: HTTPTransport = URLSessionTransport(), supportsImages: Bool = false) {
        self.supportsImages = supportsImages
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.fullModel = fullModel
        self.fastModel = fastModel
        self.transport = transport
    }

    public func complete(_ request: ModelRequest) async throws -> ModelResponse {
        let url = baseURL.appendingPathComponent("chat").appendingPathComponent("completions")
        var headers: [String: String] = [:]
        if let apiKey, !apiKey.isEmpty { headers["Authorization"] = "Bearer \(apiKey)" }
        // Los modelos locales pueden tardar mucho en cargar.
        let urlRequest = try URLRequest.postJSON(url, body: Self.body(for: request, disableThinking: disablesThinking,
                                                                         completionTokens: usesCompletionTokens),
                                                 headers: headers, timeout: 300)
        return try Self.parse(await transport.sendModelJSON(urlRequest))
    }

    // MARK: Conversión

    /// DeepSeek razona antes de responder por defecto, con esfuerzo alto: multiplica la espera y,
    /// con herramientas, exige devolverle su razonamiento en cada petición. Se desactiva.
    var disablesThinking: Bool { baseURL.host?.hasSuffix("deepseek.com") == true }

    /// OpenAI ya no acepta `max_tokens` en sus modelos de razonamiento (o1, o3, GPT-5…): usa
    /// `max_completion_tokens`, que valen todos. El resto de compatibles sigue con `max_tokens`.
    var usesCompletionTokens: Bool { baseURL.host == "api.openai.com" }

    static func body(for request: ModelRequest, disableThinking: Bool = false, completionTokens: Bool = false) -> JSONValue {
        var messages: [JSONValue] = []
        if !request.fullSystem.isEmpty { messages.append(["role": "system", "content": .string(request.fullSystem)]) }
        for message in request.messages { messages.append(contentsOf: encode(message)) }
        var body: [String: JSONValue] = [
            "model": .string(request.model),
            (completionTokens ? "max_completion_tokens" : "max_tokens"): .number(Double(request.maxTokens)),
            "messages": .array(messages),
        ]
        if disableThinking { body["thinking"] = ["type": "disabled"] }
        if !request.tools.isEmpty {
            body["tools"] = .array(request.tools.map {
                ["type": "function", "function": [
                    "name": .string($0.name), "description": .string($0.description), "parameters": $0.inputSchema,
                ]]
            })
        }
        return .object(body)
    }

    /// Un mensaje normalizado puede dar varios mensajes de Chat Completions (uno por resultado de herramienta).
    static func encode(_ message: ModelMessage) -> [JSONValue] {
        var texts: [String] = []
        var calls: [JSONValue] = []
        var results: [JSONValue] = []
        var images: [JSONValue] = []
        for block in message.content {
            switch block {
            case let .text(t): texts.append(t)
            case let .toolUse(id, name, input):
                calls.append(["id": .string(id), "type": "function", "function": [
                    "name": .string(name), "arguments": .string(input.jsonString()),
                ]])
            case let .toolResult(id, content, isError):
                results.append(["role": "tool", "tool_call_id": .string(id),
                                "content": .string(isError ? "ERROR: \(content)" : content)])
            case let .image(mediaType, data):
                images.append(["type": "image_url",
                               "image_url": ["url": .string("data:\(mediaType);base64,\(data.base64EncodedString())")]])
            }
        }
        let text = texts.joined(separator: "\n")
        switch message.role {
        case .assistant:
            var m: [String: JSONValue] = ["role": "assistant", "content": text.isEmpty ? .null : .string(text)]
            if !calls.isEmpty { m["tool_calls"] = .array(calls) }
            return [.object(m)]
        case .user:
            var out = results
            // Los mensajes de herramienta no llevan imágenes: van en un mensaje del usuario detrás.
            if !images.isEmpty {
                let parts: [JSONValue] = (text.isEmpty ? [] : [["type": "text", "text": .string(text)]]) + images
                out.append(["role": "user", "content": .array(parts)])
            } else if !text.isEmpty {
                out.append(["role": "user", "content": .string(text)])
            }
            return out
        }
    }

    static func parse(_ json: JSONValue) throws -> ModelResponse {
        guard let choice = json["choices"]?[0], let message = choice["message"] else {
            throw ProviderError.invalidResponse("falta «choices»")
        }
        var blocks: [ContentBlock] = []
        if let text = message["content"]?.stringValue, !text.isEmpty {
            blocks.append(.text(text))
        } else if let parts = message["content"]?.arrayValue {
            let text = parts.compactMap { $0["text"]?.stringValue }.joined()
            if !text.isEmpty { blocks.append(.text(text)) }
        }
        for (i, call) in (message["tool_calls"]?.arrayValue ?? []).enumerated() {
            guard let fn = call["function"], let name = fn["name"]?.stringValue else { continue }
            let id = call["id"]?.stringValue ?? "call_\(i)"
            let input: JSONValue
            switch fn["arguments"] {
            case let .string(raw)?:
                input = raw.trimmingCharacters(in: .whitespaces).isEmpty ? [:] : ((try? JSONValue.parse(raw)) ?? [:])
            case let .object(o)?: input = .object(o) // algunos servidores locales
            default: input = [:]
            }
            blocks.append(.toolUse(id: id, name: name, input: input))
        }
        let stop: StopReason
        switch choice["finish_reason"]?.stringValue {
        case "stop", nil: stop = .endTurn
        case "tool_calls", "function_call": stop = .toolUse
        case "length": stop = .maxTokens
        case let other?: stop = .other(other)
        }
        return ModelResponse(content: blocks, stopReason: stop,
                             inputTokens: json["usage"]?["prompt_tokens"]?.intValue,
                             outputTokens: json["usage"]?["completion_tokens"]?.intValue)
    }
}
