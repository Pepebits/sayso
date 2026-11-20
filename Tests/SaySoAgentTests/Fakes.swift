import Foundation
import SaySoCore
@testable import SaySoAgent

// Dobles de prueba: sin red real.

/// Caja con cerrojo para estado mutable compartido.
final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.withLock { value } }
    func set(_ v: Value) { lock.withLock { value = v } }
    @discardableResult func update<R>(_ body: (inout Value) -> R) -> R { lock.withLock { body(&value) } }
}

/// `SaySoStoring` en memoria.
final class MemoryStore: SaySoStoring, @unchecked Sendable {
    private let lock = NSLock()
    var rules: [ActionID: PermissionRule] = [:]
    var activity: [ActivityEntry] = []
    var memory: [MemoryNote] = []
    var settings: [String: String] = [:]
    var secretList: [SecretMeta] = []
    var requests: [Date] = []
    var conversation: [ConversationTurn] = []

    private func sync<R>(_ body: () throws -> R) rethrows -> R { lock.lock(); defer { lock.unlock() }; return try body() }

    func rule(for action: ActionID) throws -> PermissionRule? { sync { rules[action] } }
    func setRule(_ rule: PermissionRule?, for action: ActionID) throws { sync { rules[action] = rule } }
    func allRules() throws -> [ActionID: PermissionRule] { sync { rules } }
    func appendActivity(_ entry: ActivityEntry) throws -> ActivityEntry { sync { activity.append(entry); return entry } }
    func recentActivity(limit: Int, scope: String?) throws -> [ActivityEntry] { sync { Array(activity.reversed().prefix(limit)) } }
    func lastUse(of action: ActionID) throws -> Date? { sync { activity.last { $0.action == action }?.date } }
    func clearActivity(scope: String?) throws { sync { activity.removeAll() } }
    func notes() throws -> [MemoryNote] { sync { memory } }
    func addNote(_ note: MemoryNote) throws -> MemoryNote {
        sync { var n = note; n.id = Int64(memory.count + 1); memory.append(n); return n }
    }
    func deleteNote(id: Int64) throws { sync { memory.removeAll { $0.id == id } } }
    func updateNoteText(_ text: String, id: Int64) throws {
        sync { if let i = memory.firstIndex(where: { $0.id == id }) { memory[i].text = text } }
    }
    func setNoteKind(_ kind: MemoryNote.Kind, id: Int64) throws {
        sync { if let i = memory.firstIndex(where: { $0.id == id }) { memory[i].kind = kind } }
    }
    func setting(_ key: String) throws -> String? { sync { settings[key] } }
    func setSetting(_ value: String?, for key: String) throws { sync { settings[key] = value } }
    func secrets() throws -> [SecretMeta] { sync { secretList } }
    func upsertSecret(_ meta: SecretMeta) throws {
        sync { secretList.removeAll { $0.name == meta.name }; secretList.append(meta) }
    }
    func deleteSecret(name: String) throws { sync { secretList.removeAll { $0.name == name } } }
    func incrementRequests(on day: Date) throws { sync { requests.append(day) } }
    func requestCount(on day: Date) throws -> Int { sync { requests.count } }
    func turns(chatID: String, limit: Int) throws -> [ConversationTurn] {
        sync { Array(conversation.filter { $0.chatID == chatID }.suffix(limit)) }
    }
    func appendTurn(_ turn: ConversationTurn) throws { sync { conversation.append(turn) } }
    func clearTurns(chatID: String) throws { sync { conversation.removeAll { $0.chatID == chatID } } }
}

/// Transporte HTTP falso: registra peticiones y responde con un manejador.
final class FakeTransport: HTTPTransport, @unchecked Sendable {
    let requests = Locked<[URLRequest]>([])
    let handler: @Sendable (URLRequest) throws -> (Int, Data)

    init(handler: @escaping @Sendable (URLRequest) throws -> (Int, Data)) { self.handler = handler }

    convenience init(status: Int = 200, json: String) {
        self.init { _ in (status, Data(json.utf8)) }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.update { $0.append(request) }
        let (status, data) = try handler(request)
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    func bodies() -> [JSONValue] { requests.get().compactMap { $0.httpBody.flatMap { try? JSONValue.parse($0) } } }
}

/// Proveedor falso con respuestas encoladas.
final class FakeProvider: ModelProvider, @unchecked Sendable {
    let fullModel = "full-model"
    let fastModel = "fast-model"
    let requests = Locked<[ModelRequest]>([])
    private let responses: Locked<[ModelResponse]>
    private let fallback: ModelResponse?
    let delay: UInt64

    init(_ responses: [ModelResponse], fallback: ModelResponse? = nil, delayNanos: UInt64 = 0) {
        self.responses = Locked(responses)
        self.fallback = fallback
        self.delay = delayNanos
    }

    func complete(_ request: ModelRequest) async throws -> ModelResponse {
        requests.update { $0.append(request) }
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        if let next = responses.update({ $0.isEmpty ? nil : $0.removeFirst() }) { return next }
        if let fallback { return fallback }
        throw ProviderError.invalidResponse("sin respuestas")
    }
}

struct FakeRedactor: SecretRedacting {
    func redact(_ text: String) -> String { text.replacingOccurrences(of: "sk-SECRETO", with: "[API_KEY]") }
}

/// Broker falso: permite o deniega y registra.
final class FakeBroker: PermissionBrokering, @unchecked Sendable {
    let allow: Bool
    let requests = Locked<[ActionRequest]>([])
    init(allow: Bool) { self.allow = allow }
    func run<T: Sendable>(_ request: ActionRequest, operation: @Sendable () async throws -> T) async throws -> T {
        requests.update { $0.append(request) }
        guard allow else { throw PermissionError.denied(request.action, reason: "denegado por el usuario") }
        return try await operation()
    }
}

/// Herramienta falsa que devuelve su entrada o lanza el error indicado.
struct FakeTool: AgentTool {
    var name = "echo"
    var description = "Devuelve el texto"
    var inputSchema: JSONValue = .objectSchema(["text": .property("string", "texto")], required: ["text"])
    var error: Error?
    let calls = Locked<[JSONValue]>([])

    func call(input: JSONValue, context: ToolContext) async throws -> String {
        calls.update { $0.append(input) }
        if let error { throw error }
        return "eco: \(input["text"]?.stringValue ?? "") sk-SECRETO"
    }
}

final class FakeMacRunner: MacScriptRunning, @unchecked Sendable {
    let calls = Locked<[MacScriptCall]>([])
    func run(_ call: MacScriptCall, origin: String?) async throws -> String {
        calls.update { $0.append(call) }
        return "ok"
    }
}

extension ModelResponse {
    static func text(_ t: String) -> ModelResponse { .init(content: [.text(t)], stopReason: .endTurn) }
    static func tool(_ name: String, _ input: JSONValue, id: String = "t1") -> ModelResponse {
        .init(content: [.toolUse(id: id, name: name, input: input)], stopReason: .toolUse)
    }
}
