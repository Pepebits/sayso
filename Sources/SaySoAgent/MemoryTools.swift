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
        var kind = input["kind"]?.stringValue.flatMap(MemoryNote.Kind.init(rawValue:))
            ?? (MemoryNote.looksLikeInstruction(text) ? .instruction : .fact)
        // Tras leer contenido ajeno en el turno, una «instrucción» podría venir de ahí y aplicarse en
        // todas las conversaciones: se guarda como dato y el usuario la puede cambiar en Memoria.
        let tainted = GuardContext.current?.isTainted ?? false
        if tainted, kind == .instruction { kind = .fact }
        if let twin = try store.notes().first(where: { Self.isNearDuplicate($0.text, text) }) {
            return "No guardado: ya hay una nota casi igual («\(String(twin.text.prefix(120)))»). Si es un registro de " +
                "lo que haces, llévalo en un archivo de ~/sayso/registro/, no en la memoria."
        }
        try store.addNote(MemoryNote(text: text, source: tainted ? "agente (tras leer contenido ajeno)" : "agente", kind: kind))
        if tainted, input["kind"]?.stringValue == "instruccion" {
            return "Guardado en memoria como dato, no como instrucción: en este turno has leído contenido de otras personas. Si el usuario quiere que sea una instrucción, puede cambiarlo en SaySo → Memoria."
        }
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
            "- #\(note.id ?? 0) [\(note.kind == .instruction ? "instrucción" : "dato"), \(f.string(from: note.createdAt))] \(note.text)"
        }.joined(separator: "\n")
    }
}

/// `memory_forget` y `memory_update`: borrar o corregir una nota por su número (el de memory_search).
/// Tras leer contenido ajeno no se tocan las notas: un mensaje podría pedir «olvida tus reglas».
public struct MemoryEditTool: AgentTool {
    public enum Mode: Sendable { case forget, update }
    let store: SaySoStoring
    let mode: Mode
    public init(store: SaySoStoring, mode: Mode) {
        self.store = store
        self.mode = mode
    }

    public var name: String { mode == .forget ? "memory_forget" : "memory_update" }
    public var description: String {
        switch mode {
        case .forget:
            return "Borra una nota de la memoria por su número (búscalo antes con memory_search). Úsala cuando el " +
                "usuario diga que algo ya no es así o que lo olvides («ya no vivo en Vigo», «olvida eso de los perros»)."
        case .update:
            return "Corrige una nota de la memoria por su número (búscalo antes con memory_search): texto nuevo y, " +
                "si cambia, «kind» (dato o instruccion). Mejor que borrar y guardar otra."
        }
    }
    public var inputSchema: JSONValue {
        switch mode {
        case .forget:
            return .objectSchema(["id": ["type": "integer", "description": "Número de la nota"]], required: ["id"])
        case .update:
            return .objectSchema([
                "id": ["type": "integer", "description": "Número de la nota"],
                "text": .property("string", "Texto nuevo de la nota, en una frase"),
                "kind": ["type": "string", "enum": ["dato", "instruccion"], "description": "dato o instruccion"],
            ], required: ["id", "text"])
        }
    }

    public func call(input: JSONValue, context: ToolContext) async throws -> String {
        guard let id = input["id"]?.intValue.map(Int64.init) else { throw ToolInputError("Falta «id» (número de la nota).") }
        guard let note = try store.notes().first(where: { $0.id == id }) else {
            return "No existe la nota #\(id): búscala con memory_search."
        }
        if GuardContext.current?.isTainted ?? false {
            return "No cambiado: en este turno has leído contenido de otras personas. Si el usuario quiere cambiar la " +
                "memoria, que te lo pida en otro mensaje o lo haga en SaySo → Memoria."
        }
        switch mode {
        case .forget:
            try store.deleteNote(id: id)
            return "Nota #\(id) borrada: «\(String(note.text.prefix(120)))»."
        case .update:
            let text = try input.requiredString("text", maxLength: 1000)
            try store.updateNoteText(text, id: id)
            if let kind = input["kind"]?.stringValue.flatMap(MemoryNote.Kind.init(rawValue:)), kind != note.kind {
                try store.setNoteKind(kind, id: id)
            }
            return "Nota #\(id) corregida."
        }
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
                                computer: AgentComputer? = nil, secrets: ComputerSecrets? = nil,
                                vision: Bool = false) -> [AgentTool] {
        MacTools.all(runner: runner) + [RememberTool(store: store), MemorySearchTool(store: store),
                                        MemoryEditTool(store: store, mode: .forget), MemoryEditTool(store: store, mode: .update),
                                        NewConversationTool(store: store), RequestSecretTool(store: store)]
            + (computer.map { ComputerTools.all(computer: $0, secrets: secrets, vision: vision, jobs: store) } ?? [])
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
