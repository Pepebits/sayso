import Foundation
import SaySoCore

/// `SaySoStoring` en memoria para los tests.
final class FakeStore: SaySoStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var rules: [ActionID: PermissionRule] = [:]
    private var activity: [ActivityEntry] = []
    private var memory: [MemoryNote] = []
    private var settings: [String: String] = [:]
    private var secretMetas: [String: SecretMeta] = [:]
    private var usage: [String: Int] = [:]
    private var chat: [ConversationTurn] = []
    private var nextID: Int64 = 1

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }

    func rule(for action: ActionID) throws -> PermissionRule? { locked { rules[action] } }
    func setRule(_ rule: PermissionRule?, for action: ActionID) throws { locked { rules[action] = rule } }
    func allRules() throws -> [ActionID: PermissionRule] { locked { rules } }

    func appendActivity(_ entry: ActivityEntry) throws -> ActivityEntry {
        locked {
            var e = entry
            e.id = nextID
            nextID += 1
            activity.append(e)
            return e
        }
    }

    func recentActivity(limit: Int, scope: String?) throws -> [ActivityEntry] {
        locked { Array(activity.reversed().filter { scope == nil || $0.action.scope == scope }.prefix(limit)) }
    }

    func lastUse(of action: ActionID) throws -> Date? { locked { activity.last { $0.action == action }?.date } }
    func clearActivity(scope: String?) throws { locked { activity.removeAll { scope == nil || $0.action.scope == scope } } }

    func notes() throws -> [MemoryNote] { locked { memory } }
    func addNote(_ note: MemoryNote) throws -> MemoryNote { locked { memory.append(note); return note } }
    func deleteNote(id: Int64) throws { locked { memory.removeAll { $0.id == id } } }

    func setting(_ key: String) throws -> String? { locked { settings[key] } }
    func setSetting(_ value: String?, for key: String) throws { locked { settings[key] = value } }

    func secrets() throws -> [SecretMeta] { locked { Array(secretMetas.values) } }
    func upsertSecret(_ meta: SecretMeta) throws { locked { secretMetas[meta.name] = meta } }
    func deleteSecret(name: String) throws { locked { secretMetas[name] = nil } }

    func incrementRequests(on day: Date) throws { locked { usage["\(day)", default: 0] += 1 } }
    func requestCount(on day: Date) throws -> Int { locked { usage["\(day)"] ?? 0 } }

    func turns(chatID: String, limit: Int) throws -> [ConversationTurn] {
        locked { Array(chat.filter { $0.chatID == chatID }.suffix(limit)) }
    }
    func appendTurn(_ turn: ConversationTurn) throws { locked { chat.append(turn) } }
    func clearTurns(chatID: String) throws { locked { chat.removeAll { $0.chatID == chatID } } }

    /// Registro en orden de inserción.
    var log: [ActivityEntry] { locked { activity } }
}

/// Presentador que responde siempre lo mismo y cuenta las preguntas.
final class FakePresenter: ConfirmationPresenter, @unchecked Sendable {
    private let lock = NSLock()
    private let answer: ConfirmationResult
    private let delay: UInt64
    private var _asked: [ActionRequest] = []
    private var inFlight = 0
    private var _maxConcurrent = 0

    init(_ answer: ConfirmationResult, delayNanoseconds: UInt64 = 0) {
        self.answer = answer
        self.delay = delayNanoseconds
    }

    var asked: [ActionRequest] { lock.lock(); defer { lock.unlock() }; return _asked }
    var maxConcurrent: Int { lock.lock(); defer { lock.unlock() }; return _maxConcurrent }

    func confirm(_ request: ActionRequest, descriptor: ActionDescriptor?) async -> ConfirmationResult {
        lock.withLock {
            _asked.append(request)
            inFlight += 1
            _maxConcurrent = max(_maxConcurrent, inFlight)
        }
        if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
        lock.withLock { inFlight -= 1 }
        return answer
    }
}

/// Motor que registra las peticiones y deniega sin ejecutar nada.
final class RecordingBroker: PermissionBrokering, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [ActionRequest] = []
    var requests: [ActionRequest] { lock.lock(); defer { lock.unlock() }; return _requests }

    func run<T: Sendable>(_ request: ActionRequest, operation: @Sendable () async throws -> T) async throws -> T {
        lock.withLock { _requests.append(request) }
        throw PermissionError.denied(request.action, reason: "test")
    }
}
