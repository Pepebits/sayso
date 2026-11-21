import Foundation
import SaySoCore

/// Bloque de contenido normalizado entre proveedores.
public enum ContentBlock: Sendable, Hashable {
    case text(String)
    case toolUse(id: String, name: String, input: JSONValue)
    case toolResult(toolUseID: String, content: String, isError: Bool)
    /// Una imagen para modelos que las ven (JPEG o PNG).
    case image(mediaType: String, data: Data)
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
    /// El modelo puede ver imágenes.
    var supportsImages: Bool { get }
}

public extension ModelProvider {
    var supportsImages: Bool { false }
}

public enum ProviderError: Error, LocalizedError, Sendable, Equatable {
    case missingKey(String)
    case http(status: Int, message: String)
    case invalidResponse(String)
    case timeout

    public var errorDescription: String? {
        switch self {
        case let .missingKey(name):
            return tr("Falta la clave de API (%@). Añádela en SaySo → Modelo.", "\(name)")
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

/// Reintentos de una petición al modelo ante fallos pasajeros: saturación (429, 529), errores del
/// servidor y cortes de red. Solo se repite la petición al modelo, nunca una herramienta: no se hace
/// nada dos veces.
public enum ModelRetry {
    /// Esperas antes de cada reintento, en segundos (con un poco de azar para no ir a la vez).
    static let delays: [Double] = [1, 3, 8]
    /// Si el proveedor pide esperar más que esto, no compensa: se falla y se avisa.
    static let maxRetryAfter: Double = 30
    /// Escala de las esperas; los tests la ponen a 0.
    nonisolated(unsafe) static var scale: Double = 1

    static func isRetryable(status: Int) -> Bool {
        [408, 409, 425, 429, 500, 502, 503, 504, 529].contains(status)
    }

    static func isRetryable(_ error: Error) -> Bool {
        guard let error = error as? URLError else { return false }
        return [.networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost,
                .cannotFindHost, .dnsLookupFailed, .secureConnectionFailed].contains(error.code)
    }

    /// Segundos que pide la cabecera `retry-after` (solo la forma en segundos).
    static func retryAfter(_ response: HTTPURLResponse) -> Double? {
        (response.value(forHTTPHeaderField: "retry-after")).flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    }

    static func wait(_ seconds: Double) async throws {
        guard seconds * scale > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(seconds * scale * 1_000_000_000))
    }
}

extension HTTPTransport {
    /// `sendJSON` con reintentos ante fallos pasajeros (para las peticiones al modelo).
    func sendModelJSON(_ request: URLRequest) async throws -> JSONValue {
        var attempt = 0
        while true {
            let delay = attempt < ModelRetry.delays.count ? ModelRetry.delays[attempt] : nil
            do {
                let (data, response) = try await send(request)
                if (200..<300).contains(response.statusCode) {
                    do { return try JSONValue.parse(data) } catch {
                        throw ProviderError.invalidResponse("JSON no válido")
                    }
                }
                let error = ProviderError.from(status: response.statusCode, body: data)
                guard let delay, ModelRetry.isRetryable(status: response.statusCode) else { throw error }
                let asked = ModelRetry.retryAfter(response)
                if let asked, asked > ModelRetry.maxRetryAfter { throw error }
                try await ModelRetry.wait(max(asked ?? 0, delay * Double.random(in: 0.8...1.2)))
            } catch let error as URLError where ModelRetry.isRetryable(error) {
                guard let delay else { throw error }
                try await ModelRetry.wait(delay * Double.random(in: 0.8...1.2))
            }
            attempt += 1
        }
    }

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


/// Apunta los tokens de cada petición: los que dice el proveedor o, si no los da, una estimación
/// por caracteres (unos 3,5 por token).
public enum TokenMeter {
    public static func record(_ request: ModelRequest, _ response: ModelResponse, store: SaySoStoring?, on day: Date = Date()) {
        guard let store else { return }
        let estimated = response.inputTokens == nil || response.outputTokens == nil
        let input = response.inputTokens ?? estimate(request)
        let output = response.outputTokens ?? Int(Double(response.text.count) / 3.5)
        try? store.recordTokens(model: request.model, input: input, output: output, estimated: estimated, on: day)
    }

    static func estimate(_ request: ModelRequest) -> Int {
        let messages = request.messages.reduce(0) { $0 + String(describing: $1.content).count }
        let tools = request.tools.reduce(0) { $0 + String(describing: $1).count }
        return Int(Double(request.system.count + messages + tools) / 3.5)
    }
}
