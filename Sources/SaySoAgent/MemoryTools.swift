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
            "en Vigo»). La memoria va en cada conversación, así que guarda solo lo que valga para muchas: no la " +
            "uses como registro de lo que haces (fotos enviadas, tareas hechas, búsquedas). Para llevar esa cuenta " +
            "escribe en un archivo de tu ordenador Linux, en ~/sayso/registro/. No guardes secretos ni contraseñas."
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
        if let twin = try store.notes().first(where: { Self.isNearDuplicate($0.text, text) }) {
            return "No guardado: ya hay una nota casi igual («\(String(twin.text.prefix(120)))»). Si es un registro de " +
                "lo que haces, llévalo en un archivo de ~/sayso/registro/, no en la memoria."
        }
        try store.addNote(MemoryNote(text: text, source: "agente", kind: kind))
        return kind == .instruction ? "Guardado en memoria como instrucción." : "Guardado en memoria como dato."
    }

    /// Palabras de una nota, sin tildes ni mayúsculas; los números cuentan como palabras.
    static func words(_ text: String) -> Set<String> {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "es_ES"))
        return Set(folded.split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 1 })
    }

    /// Casi la misma nota: comparten el 75 % de las palabras, o una contiene a la otra.
    static func isNearDuplicate(_ a: String, _ b: String) -> Bool {
        let x = words(a), y = words(b)
        guard !x.isEmpty, !y.isEmpty else { return a == b }
        if x.isSubset(of: y) || y.isSubset(of: x) { return true }
        return Double(x.intersection(y).count) / Double(x.union(y).count) >= 0.75
    }
}

/// `memory_search(query)`: busca en todas las notas, también en las que no caben en la petición.
public struct MemorySearchTool: AgentTool {
    let store: SaySoStoring
    public init(store: SaySoStoring) { self.store = store }

    public var name: String { "memory_search" }
    public var description: String {
        "Busca en la memoria del usuario, también en los datos antiguos que no aparecen en tus instrucciones."
    }
    public var inputSchema: JSONValue {
        .objectSchema(["query": .property("string", "Palabras a buscar")], required: ["query"])
    }

    public func call(input: JSONValue, context: ToolContext) async throws -> String {
        let query = try input.requiredString("query", maxLength: 200)
        let wanted = RememberTool.words(query)
        guard !wanted.isEmpty else { throw ToolInputError("«query» necesita al menos una palabra.") }
        let scored = try store.notes().map { note in (note, RememberTool.words(note.text).intersection(wanted).count) }
            .filter { $0.1 > 0 }
            .sorted { ($0.1, $0.0.createdAt) > ($1.1, $1.0.createdAt) }
        guard !scored.isEmpty else { return "No hay nada en memoria sobre «\(query)»." }
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_ES")
        f.dateFormat = "d MMM yyyy"
        return scored.prefix(20).map { note, _ in
            "- [\(note.kind == .instruction ? "instrucción" : "dato"), \(f.string(from: note.createdAt))] \(note.text)"
        }.joined(separator: "\n")
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
                                computer: AgentComputer? = nil, secrets: ComputerSecrets? = nil) -> [AgentTool] {
        MacTools.all(runner: runner) + [RememberTool(store: store), MemorySearchTool(store: store), NewConversationTool(store: store),
                                        RequestSecretTool(store: store)]
            + (computer.map { ComputerTools.all(computer: $0, secrets: secrets) } ?? [])
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
