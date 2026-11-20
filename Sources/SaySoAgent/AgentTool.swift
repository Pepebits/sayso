import Foundation
import SaySoCore

/// Contexto de una llamada a herramienta.
public struct ToolContext: Sendable, Hashable {
    /// Chat que originó la petición.
    public var chatID: String?
    /// Origen para el registro de actividad («telegram:123»).
    public var origin: String?
    /// En una tarea programada para otras personas: a quién va lo que se envíe sin destinatario.
    public var recipients: [TaskRecipient]
    /// Lo que se manda a `recipients` está autorizado de antemano por el usuario.
    public var recipientsPreapproved: Bool

    public init(chatID: String? = nil, origin: String? = nil, recipients: [TaskRecipient] = [],
                recipientsPreapproved: Bool = false) {
        self.chatID = chatID
        self.origin = origin
        self.recipients = recipients
        self.recipientsPreapproved = recipientsPreapproved
    }
}

/// Herramienta que el agente puede invocar.
public protocol AgentTool: Sendable {
    var name: String { get }
    var description: String { get }
    /// JSON Schema del objeto de entrada.
    var inputSchema: JSONValue { get }
    /// Devuelve un texto con el resultado para el modelo.
    func call(input: JSONValue, context: ToolContext) async throws -> String
}

public extension AgentTool {
    var spec: ToolSpec { ToolSpec(name: name, description: description, inputSchema: inputSchema) }
}

/// Parámetros de herramienta no válidos; se devuelve al modelo como error.
public struct ToolInputError: Error, LocalizedError, Sendable, Equatable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

// MARK: - Validación de parámetros

extension JSONValue {
    /// Texto obligatorio, no vacío y con longitud máxima.
    func requiredString(_ key: String, maxLength: Int = 2000) throws -> String {
        guard let raw = self[key]?.stringValue else { throw ToolInputError("Falta el parámetro «\(key)» (texto).") }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw ToolInputError("El parámetro «\(key)» está vacío.") }
        guard value.count <= maxLength else { throw ToolInputError("«\(key)» supera \(maxLength) caracteres.") }
        return value
    }

    /// Texto opcional; vacío equivale a ausente.
    func optionalString(_ key: String, maxLength: Int = 2000) throws -> String? {
        guard let v = self[key], !v.isNull else { return nil }
        guard let raw = v.stringValue else { throw ToolInputError("«\(key)» debe ser texto.") }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return nil }
        guard value.count <= maxLength else { throw ToolInputError("«\(key)» supera \(maxLength) caracteres.") }
        return value
    }
}
