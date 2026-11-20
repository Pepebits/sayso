import Foundation
import SaySoCore

/// Bloque de contenido normalizado entre proveedores.
public enum ContentBlock: Sendable, Hashable {
    case text(String)
    case toolUse(id: String, name: String, input: JSONValue)
    case toolResult(toolUseID: String, content: String, isError: Bool)
}

public struct ModelMessage: Sendable, Hashable {
    public enum Role: String, Sendable { case user, assistant }
    public var role: Role
    public var content: [ContentBlock]

    public init(role: Role, content: [ContentBlock]) {
        self.role = role
        self.content = content
    }

    public static func user(_ text: String) -> ModelMessage { .init(role: .user, content: [.text(text)]) }
    public static func assistant(_ text: String) -> ModelMessage { .init(role: .assistant, content: [.text(text)]) }
}

/// Herramienta tal como se anuncia al modelo.
public struct ToolSpec: Sendable, Hashable {
    public var name: String
    public var description: String
    /// JSON Schema del objeto de entrada.
    public var inputSchema: JSONValue

    public init(name: String, description: String, inputSchema: JSONValue) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

public struct ModelRequest: Sendable, Hashable {
    public var model: String
    public var system: String
    public var messages: [ModelMessage]
    public var tools: [ToolSpec]
    public var maxTokens: Int

    public init(model: String, system: String, messages: [ModelMessage], tools: [ToolSpec] = [], maxTokens: Int = 4096) {
        self.model = model
        self.system = system
        self.messages = messages
        self.tools = tools
        self.maxTokens = maxTokens
    }
}

public enum StopReason: Sendable, Hashable {
    case endTurn, toolUse, maxTokens
    case other(String)
}

public struct ToolCall: Sendable, Hashable {
    public var id: String
    public var name: String
    public var input: JSONValue
}

public struct ModelResponse: Sendable, Hashable {
    public var content: [ContentBlock]
    public var stopReason: StopReason
    /// Tokens de entrada y de salida, si el proveedor los dice.
    public var inputTokens: Int?
    public var outputTokens: Int?

    public init(content: [ContentBlock], stopReason: StopReason, inputTokens: Int? = nil, outputTokens: Int? = nil) {
        self.content = content
        self.stopReason = stopReason
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }

    /// Texto concatenado de los bloques de texto.
    public var text: String {
        content.compactMap { if case let .text(t) = $0 { return t }; return nil }.joined(separator: "\n")
    }

    public var toolCalls: [ToolCall] {
        content.compactMap {
            if case let .toolUse(id, name, input) = $0 { return ToolCall(id: id, name: name, input: input) }
            return nil
        }
    }
}

/// Proveedor de modelos. Sin streaming por ahora.
public protocol ModelProvider: Sendable {
    /// Modelo completo, para tareas con herramientas.
    var fullModel: String { get }
    /// Modelo rápido, para corrección y respuestas triviales.
    var fastModel: String { get }
    func complete(_ request: ModelRequest) async throws -> ModelResponse
}

public enum ProviderError: Error, LocalizedError, Sendable, Equatable {
    case missingKey(String)
    case http(status: Int, message: String)
    case invalidResponse(String)
    case timeout

    public var errorDescription: String? {
        switch self {
        case let .missingKey(name):
            return tr("Falta la clave de API (%@). Añádela en Ajustes → Cuentas.", "\(name)")
        case let .http(status, message):
            let base: String
            switch status {
            case 401: base = tr("La clave de API no es válida.")
            case 403: base = tr("La clave de API no tiene permiso para este modelo.")
            case 404: base = tr("No se encuentra el modelo o la URL del proveedor.")
            case 408: base = tr("El proveedor tardó demasiado en responder.")
            case 413: base = tr("La petición es demasiado grande para el modelo.")
            case 429: base = tr("Límite de peticiones alcanzado; espera un poco y vuelve a intentarlo.")
            case 529, 503: base = tr("El proveedor está saturado; inténtalo de nuevo en unos minutos.")
            case 500...599: base = tr("El proveedor ha fallado (error %@).", "\(status)")
            default: base = "Error del proveedor (\(status))."
            }
            return message.isEmpty ? base : "\(base) \(message)"
        case let .invalidResponse(detail):
            return tr("Respuesta del proveedor no válida: %@", "\(detail)")
        case .timeout:
            return tr("El modelo tardó demasiado en responder.")
        }
    }

    /// Construye el error a partir del cuerpo de una respuesta HTTP fallida.
    static func from(status: Int, body: Data) -> ProviderError {
        var message = ""
        if let json = try? JSONValue.parse(body) {
            message = json["error"]?["message"]?.stringValue
                ?? json["error"]?.stringValue
                ?? json["message"]?.stringValue
                ?? ""
        }
        if message.count > 300 { message = String(message.prefix(300)) + "…" }
        return .http(status: status, message: message)
    }
}

extension HTTPTransport {
    /// Envía y devuelve el JSON, o lanza `ProviderError` si el código no es 2xx.
    func sendJSON(_ request: URLRequest) async throws -> JSONValue {
        let (data, response) = try await send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw ProviderError.from(status: response.statusCode, body: data)
        }
        do { return try JSONValue.parse(data) } catch {
            throw ProviderError.invalidResponse("JSON no válido")
        }
    }
}
