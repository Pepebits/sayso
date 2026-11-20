import Foundation
import SaySoCore

/// `remember(text)`: guarda una nota de memoria si el usuario lo permite.
public struct RememberTool: AgentTool {
    let store: SaySoStoring
    public init(store: SaySoStoring) { self.store = store }

    public var name: String { "remember" }
    public var description: String {
        "Guarda en la memoria algo duradero sobre el usuario. «kind»: «instruccion» si es una orden que debes " +
            "seguir siempre («cuando te pida X, haz Y», «respóndeme en gallego»), «dato» si es información («vive " +
            "en Vigo»). No guardes secretos ni contraseñas."
    }
    public var inputSchema: JSONValue {
        .objectSchema([
            "text": .property("string", "Lo que hay que recordar, en una frase"),
            "kind": ["type": "string", "enum": ["dato", "instruccion"], "description": "dato o instruccion"],
        ], required: ["text"])
    }

    public func call(input: JSONValue, context: ToolContext) async throws -> String {
        let text = try input.requiredString("text", maxLength: 1000)
        if try store.setting(SettingsKey.rememberNew) == "0" {
            return "No guardado: el usuario ha desactivado que se recuerden datos nuevos."
        }
        let kind = input["kind"]?.stringValue.flatMap(MemoryNote.Kind.init(rawValue:))
            ?? (MemoryNote.looksLikeInstruction(text) ? .instruction : .fact)
        try store.addNote(MemoryNote(text: text, source: "agente", kind: kind))
        return kind == .instruction ? "Guardado en memoria como instrucción." : "Guardado en memoria como dato."
    }
}

/// `request_secret(name, reason)`: pide un secreto por nombre. Nunca recibe ni devuelve valores.
public struct RequestSecretTool: AgentTool {
    let store: SaySoStoring
    public init(store: SaySoStoring) { self.store = store }

    public var name: String { "request_secret" }
    public var description: String {
        "Pide al usuario que guarde una credencial (p. ej. GITHUB_TOKEN) en la app SaySo, en Secretos. " +
            "No devuelve el valor. Nunca pidas claves por el chat."
    }
    public var inputSchema: JSONValue {
        .objectSchema([
            "name": .property("string", "Nombre en MAYÚSCULAS_CON_GUIONES_BAJOS, p. ej. GITHUB_TOKEN"),
            "reason": .property("string", "Para qué se necesita"),
        ], required: ["name", "reason"])
    }

    static func isValidName(_ name: String) -> Bool {
        guard (1...64).contains(name.count), let first = name.unicodeScalars.first,
              CharacterSet.uppercaseLetters.contains(first) else { return false }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_")
        return name.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    public func call(input: JSONValue, context: ToolContext) async throws -> String {
        let name = try input.requiredString("name", maxLength: 64).uppercased()
        guard Self.isValidName(name) else {
            throw ToolInputError("«name» solo admite letras mayúsculas, números y guiones bajos (p. ej. GITHUB_TOKEN).")
        }
        let reason = try input.requiredString("reason", maxLength: 500)
        if let existing = try store.secrets().first(where: { $0.name == name }), existing.status == .stored {
            return "El secreto \(name) ya está guardado en la app."
        }
        try store.upsertSecret(SecretMeta(name: name, reason: reason, status: .requested))
        return "Solicitado. El usuario debe introducir \(name) en SaySo → Secretos; dile que no lo pegue en el chat."
    }
}

public enum AgentTools {
    /// Herramientas base del host: Mac, memoria y secretos; y las del ordenador Linux si existe.
    public static func standard(runner: MacScriptRunning, store: SaySoStoring,
                                computer: AgentComputer? = nil) -> [AgentTool] {
        MacTools.all(runner: runner) + [RememberTool(store: store), NewConversationTool(store: store), RequestSecretTool(store: store)]
            + (computer.map(ComputerTools.all) ?? [])
    }
}

/// `new_conversation()`: olvida el historial de este chat. Las notas de memoria no se tocan.
public struct NewConversationTool: AgentTool {
    let store: SaySoStoring
    public init(store: SaySoStoring) { self.store = store }

    public var name: String { "new_conversation" }
    public var description: String {
        "Empieza una conversación nueva: borra el historial de este chat, no las notas de memoria. Úsala " +
            "cuando el usuario diga «olvida esta conversación», «empecemos de cero», «nueva conversación» o " +
            "parecido. No la uses por tu cuenta."
    }
    public var inputSchema: JSONValue { .objectSchema([:], required: []) }

    /// Borra los turnos de un chat y su medida de contexto.
    public static func reset(chatID: String, store: SaySoStoring) throws {
        // La voz y el bot son una sola conversación: se empieza de cero en los dos.
        let chats = AgentLoop.conversationChats(for: chatID, store: store)
        var summaries: [String: ContextSummary] = (try? store.codableSetting(SettingsKey.contextSummaries)) ?? [:]
        summaries[AgentLoop.summaryKey(for: chatID, store: store)] = nil
        try store.setCodableSetting(summaries, for: SettingsKey.contextSummaries)
        var all: [String: ContextUsage] = (try? store.codableSetting(SettingsKey.contextUsage)) ?? [:]
        for chat in chats {
            try store.clearTurns(chatID: chat)
            all[chat] = nil
        }
        try store.setCodableSetting(all, for: SettingsKey.contextUsage)
    }

    public func call(input: JSONValue, context: ToolContext) async throws -> String {
        guard let chatID = context.chatID else { throw ToolInputError("No sé de qué conversación se trata.") }
        try Self.reset(chatID: chatID, store: store)
        return "Historial de esta conversación borrado. Las notas de memoria siguen ahí."
    }
}
