import Foundation
import GRDB
import SaySoCore

/// Persistencia en SQLite con GRDB. Las fechas se guardan como segundos desde 1970.
public final class SQLiteStore: SaySoStoring, TaskStoring {
    // DatabaseQueue es Sendable y serializa los accesos.
    private let db: DatabaseQueue

    /// Abre (o crea) la base en `url` y aplica las migraciones pendientes.
    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        db = try DatabaseQueue(path: url.path, configuration: config)
        try Self.migrator.migrate(db)
    }

    private init(queue: DatabaseQueue) throws {
        db = queue
        try Self.migrator.migrate(db)
    }

    /// Base en memoria, para tests y vistas previas.
    public static func inMemory() throws -> SQLiteStore {
        try SQLiteStore(queue: DatabaseQueue())
    }

    // MARK: - Migraciones

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE rules (
                    action TEXT PRIMARY KEY NOT NULL,
                    rule TEXT NOT NULL
                );
                CREATE TABLE activity (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    date DOUBLE NOT NULL,
                    action TEXT NOT NULL,
                    scope TEXT NOT NULL,
                    summary TEXT NOT NULL,
                    rule TEXT NOT NULL,
                    outcome TEXT NOT NULL,
                    origin TEXT
                );
                CREATE INDEX activity_date ON activity(date);
                CREATE INDEX activity_scope ON activity(scope, date);
                CREATE INDEX activity_action ON activity(action, date);
                CREATE TABLE notes (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    text TEXT NOT NULL,
                    source TEXT NOT NULL,
                    createdAt DOUBLE NOT NULL
                );
                CREATE TABLE settings (
                    key TEXT PRIMARY KEY NOT NULL,
                    value TEXT NOT NULL
                );
                CREATE TABLE secrets (
                    name TEXT PRIMARY KEY NOT NULL,
                    reason TEXT NOT NULL,
                    status TEXT NOT NULL,
                    lastUsed DOUBLE,
                    createdAt DOUBLE NOT NULL
                );
                CREATE TABLE usage (
                    day TEXT PRIMARY KEY NOT NULL,
                    requests INTEGER NOT NULL DEFAULT 0
                );
                CREATE TABLE turns (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    chatID TEXT NOT NULL,
                    role TEXT NOT NULL,
                    text TEXT NOT NULL,
                    date DOUBLE NOT NULL
                );
                CREATE INDEX turns_chat ON turns(chatID, date);
                """)
        }
        m.registerMigration("v2-tasks") { db in
            try db.execute(sql: """
                CREATE TABLE tasks (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    instruction TEXT NOT NULL,
                    schedule TEXT NOT NULL,
                    enabled INTEGER NOT NULL DEFAULT 1,
                    createdAt DOUBLE NOT NULL,
                    nextRun DOUBLE,
                    lastRun DOUBLE,
                    lastResult TEXT
                );
                """)
        }
        m.registerMigration("v4-task-recipient") { db in
            try db.execute(sql: """
                ALTER TABLE tasks ADD COLUMN recipientID INTEGER;
                ALTER TABLE tasks ADD COLUMN recipientTitle TEXT;
                ALTER TABLE tasks ADD COLUMN recipientKind TEXT;
                """)
        }
        m.registerMigration("v5-task-recipients") { db in
            // Varios destinatarios por tarea, en JSON. Los de una sola columna pasan a la lista.
            try db.execute(sql: "ALTER TABLE tasks ADD COLUMN recipients TEXT")
            let rows = try Row.fetchAll(db, sql: "SELECT id, recipientID, recipientTitle, recipientKind FROM tasks WHERE recipientID IS NOT NULL")
            for row in rows {
                let one = TaskRecipient(id: row["recipientID"], title: row["recipientTitle"] ?? "",
                                        kind: row["recipientKind"] ?? "privado")
                try db.execute(sql: "UPDATE tasks SET recipients = ? WHERE id = ?",
                               arguments: [Self.recipientsJSON([one]), row["id"] as Int64])
            }
        }
        m.registerMigration("v6-note-kind") { db in
            try db.execute(sql: "ALTER TABLE notes ADD COLUMN kind TEXT NOT NULL DEFAULT 'dato'")
            // Las que ya parecen una orden pasan a instrucción.
            for row in try Row.fetchAll(db, sql: "SELECT id, text FROM notes") {
                if MemoryNote.looksLikeInstruction(row["text"]) {
                    try db.execute(sql: "UPDATE notes SET kind = 'instruccion' WHERE id = ?", arguments: [row["id"] as Int64])
                }
            }
        }
        m.registerMigration("v7-task-send-without-asking") { db in
            try db.execute(sql: "ALTER TABLE tasks ADD COLUMN sendWithoutAsking INTEGER NOT NULL DEFAULT 0")
        }
        m.registerMigration("v3-dictation-usage") { db in
            try db.execute(sql: """
                ALTER TABLE usage ADD COLUMN dictations INTEGER NOT NULL DEFAULT 0;
                ALTER TABLE usage ADD COLUMN words INTEGER NOT NULL DEFAULT 0;
                ALTER TABLE usage ADD COLUMN seconds DOUBLE NOT NULL DEFAULT 0;
                """)
        }
        return m
    }

    // MARK: - Reglas

    public func rule(for action: ActionID) throws -> PermissionRule? {
        try db.read { db in
            let raw = try String.fetchOne(db, sql: "SELECT rule FROM rules WHERE action = ?",
                                          arguments: [action.rawValue])
            return raw.flatMap(PermissionRule.init(rawValue:))
        }
    }

    public func setRule(_ rule: PermissionRule?, for action: ActionID) throws {
        try db.write { db in
            if let rule {
                try db.execute(sql: "INSERT OR REPLACE INTO rules (action, rule) VALUES (?, ?)",
                               arguments: [action.rawValue, rule.rawValue])
            } else {
                try db.execute(sql: "DELETE FROM rules WHERE action = ?", arguments: [action.rawValue])
            }
        }
    }

    public func allRules() throws -> [ActionID: PermissionRule] {
        try db.read { db in
            var out: [ActionID: PermissionRule] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT action, rule FROM rules") {
                if let rule = PermissionRule(rawValue: row["rule"]) {
                    out[ActionID(row["action"] as String)] = rule
                }
            }
            return out
        }
    }

    // MARK: - Registro de actividad

    @discardableResult
    public func appendActivity(_ entry: ActivityEntry) throws -> ActivityEntry {
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO activity (date, action, scope, summary, rule, outcome, origin)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [entry.date.timeIntervalSince1970, entry.action.rawValue, entry.action.scope,
                                 entry.summary, entry.rule.rawValue, entry.outcome.rawValue, entry.origin])
            var saved = entry
            saved.id = db.lastInsertedRowID
            return saved
        }
    }

    public func recentActivity(limit: Int, scope: String?) throws -> [ActivityEntry] {
        try db.read { db in
            let rows: [Row]
            if let scope {
                rows = try Row.fetchAll(db, sql: """
                    SELECT * FROM activity WHERE scope = ? ORDER BY date DESC, id DESC LIMIT ?
                    """, arguments: [scope, max(0, limit)])
            } else {
                rows = try Row.fetchAll(db, sql: "SELECT * FROM activity ORDER BY date DESC, id DESC LIMIT ?",
                                        arguments: [max(0, limit)])
            }
            return rows.compactMap(Self.activity(from:))
        }
    }

    public func activityCount(scope: String?) throws -> Int {
        try db.read { db in
            if let scope {
                return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM activity WHERE scope = ?", arguments: [scope]) ?? 0
            }
            return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM activity") ?? 0
        }
    }

    @discardableResult
    public func prune(olderThan cutoff: Date) throws -> (activity: Int, turns: Int) {
        try db.write { db in
            let limit = cutoff.timeIntervalSince1970
            try db.execute(sql: "DELETE FROM activity WHERE date < ?", arguments: [limit])
            let activity = db.changesCount
            try db.execute(sql: "DELETE FROM turns WHERE date < ?", arguments: [limit])
            return (activity, db.changesCount)
        }
    }

    public func lastUse(of action: ActionID) throws -> Date? {
        try db.read { db in
            try Double.fetchOne(db, sql: "SELECT MAX(date) FROM activity WHERE action = ?",
                                arguments: [action.rawValue])
                .map(Date.init(timeIntervalSince1970:))
        }
    }

    public func clearActivity(scope: String?) throws {
        try db.write { db in
            if let scope {
                try db.execute(sql: "DELETE FROM activity WHERE scope = ?", arguments: [scope])
            } else {
                try db.execute(sql: "DELETE FROM activity")
            }
        }
    }

    private static func activity(from row: Row) -> ActivityEntry? {
        guard let rule = PermissionRule(rawValue: row["rule"]),
              let outcome = ActivityOutcome(rawValue: row["outcome"]) else { return nil }
        return ActivityEntry(id: row["id"], date: Date(timeIntervalSince1970: row["date"]),
                             action: ActionID(row["action"] as String), summary: row["summary"],
                             rule: rule, outcome: outcome, origin: row["origin"])
    }

    // MARK: - Memoria

    public func notes() throws -> [MemoryNote] {
        try db.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM notes ORDER BY createdAt, id").map { row in
                MemoryNote(id: row["id"], text: row["text"], source: row["source"],
                           createdAt: Date(timeIntervalSince1970: row["createdAt"]),
                           kind: MemoryNote.Kind(rawValue: row["kind"] ?? "dato") ?? .fact)
            }
        }
    }

    @discardableResult
    public func addNote(_ note: MemoryNote) throws -> MemoryNote {
        try db.write { db in
            try db.execute(sql: "INSERT INTO notes (text, source, createdAt, kind) VALUES (?, ?, ?, ?)",
                           arguments: [note.text, note.source, note.createdAt.timeIntervalSince1970, note.kind.rawValue])
            var saved = note
            saved.id = db.lastInsertedRowID
            return saved
        }
    }

    public func setNoteKind(_ kind: MemoryNote.Kind, id: Int64) throws {
        try db.write { db in
            try db.execute(sql: "UPDATE notes SET kind = ? WHERE id = ?", arguments: [kind.rawValue, id])
        }
    }

    public func updateNoteText(_ text: String, id: Int64) throws {
        try db.write { db in
            try db.execute(sql: "UPDATE notes SET text = ? WHERE id = ?", arguments: [text, id])
        }
    }

    public func deleteNote(id: Int64) throws {
        try db.write { db in
            try db.execute(sql: "DELETE FROM notes WHERE id = ?", arguments: [id])
        }
    }

    // MARK: - Ajustes

    public func setting(_ key: String) throws -> String? {
        try db.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM settings WHERE key = ?", arguments: [key])
        }
    }

    public func setSetting(_ value: String?, for key: String) throws {
        try db.write { db in
            if let value {
                try db.execute(sql: "INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)",
                               arguments: [key, value])
            } else {
                try db.execute(sql: "DELETE FROM settings WHERE key = ?", arguments: [key])
            }
        }
    }

    // MARK: - Metadatos de secretos

    public func secrets() throws -> [SecretMeta] {
        try db.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM secrets ORDER BY name").compactMap { row in
                guard let status = SecretStatus(rawValue: row["status"]) else { return nil }
                let lastUsed: Double? = row["lastUsed"]
                return SecretMeta(name: row["name"], reason: row["reason"], status: status,
                                  lastUsed: lastUsed.map(Date.init(timeIntervalSince1970:)),
                                  createdAt: Date(timeIntervalSince1970: row["createdAt"]))
            }
        }
    }

    public func upsertSecret(_ meta: SecretMeta) throws {
        try db.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO secrets (name, reason, status, lastUsed, createdAt)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: [meta.name, meta.reason, meta.status.rawValue,
                                 meta.lastUsed?.timeIntervalSince1970, meta.createdAt.timeIntervalSince1970])
        }
    }

    public func deleteSecret(name: String) throws {
        try db.write { db in
            try db.execute(sql: "DELETE FROM secrets WHERE name = ?", arguments: [name])
        }
    }

    // MARK: - Uso

    /// Día natural en la zona horaria local, como «2026-11-18».
    static func dayKey(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    public func incrementRequests(on day: Date) throws {
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO usage (day, requests) VALUES (?, 1)
                ON CONFLICT(day) DO UPDATE SET requests = requests + 1
                """, arguments: [Self.dayKey(day)])
        }
    }

    public func requestCount(on day: Date) throws -> Int {
        try db.read { db in
            try Int.fetchOne(db, sql: "SELECT requests FROM usage WHERE day = ?",
                             arguments: [Self.dayKey(day)]) ?? 0
        }
    }

    public func recordDictation(words: Int, seconds: Double, on day: Date) throws {
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO usage (day, requests, dictations, words, seconds) VALUES (?, 0, 1, ?, ?)
                ON CONFLICT(day) DO UPDATE SET dictations = dictations + 1,
                    words = words + excluded.words, seconds = seconds + excluded.seconds
                """, arguments: [Self.dayKey(day), max(words, 0), max(seconds, 0)])
        }
    }

    /// Medianoche local del día de una clave «2026-11-18».
    static func date(fromDayKey key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    public func usageStats(days: Int, now: Date) throws -> UsageStats {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let window = (0..<max(days, 1)).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
        guard let first = window.first else { return UsageStats() }
        return try db.read { db in
            func totals(_ row: Row) -> UsageTotals {
                UsageTotals(requests: (row["requests"] as Int?) ?? 0, dictations: (row["dictations"] as Int?) ?? 0,
                            words: (row["words"] as Int?) ?? 0, seconds: (row["seconds"] as Double?) ?? 0)
            }
            var byDay: [String: UsageTotals] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT * FROM usage WHERE day >= ?", arguments: [Self.dayKey(first)]) {
                byDay[row["day"]] = totals(row)
            }
            let all = try Row.fetchOne(db, sql: """
                SELECT SUM(requests) AS requests, SUM(dictations) AS dictations, SUM(words) AS words,
                       SUM(seconds) AS seconds, MIN(day) AS firstDay FROM usage
                """)
            let firstKey: String? = all?["firstDay"]
            // El registro guarda la fecha exacta; el día se calcula en la zona horaria local.
            let buckets = try Row.fetchAll(db, sql: """
                SELECT date(date, 'unixepoch', 'localtime') AS day, action, outcome, COUNT(*) AS n
                FROM activity WHERE date >= ? GROUP BY day, action, outcome
                """, arguments: [first.timeIntervalSince1970]).compactMap { row -> ActionBucket? in
                    guard let day = Self.date(fromDayKey: row["day"]),
                          let outcome = ActivityOutcome(rawValue: row["outcome"]) else { return nil }
                    return ActionBucket(day: day, action: ActionID(row["action"] as String), outcome: outcome, count: row["n"])
                }
            return UsageStats(days: window.map { DayUsage(day: $0, totals: byDay[Self.dayKey($0)] ?? UsageTotals()) },
                              allTime: all.map(totals) ?? UsageTotals(),
                              firstDay: firstKey.flatMap(Self.date(fromDayKey:)),
                              actions: buckets)
        }
    }

    // MARK: - Conversaciones

    public func turns(chatID: String, limit: Int) throws -> [ConversationTurn] {
        try db.read { db in
            // Los últimos `limit`, devueltos en orden cronológico.
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM (
                    SELECT * FROM turns WHERE chatID = ? ORDER BY date DESC, id DESC LIMIT ?
                ) ORDER BY date ASC, id ASC
                """, arguments: [chatID, max(0, limit)])
            return rows.compactMap { row in
                guard let role = ConversationTurn.Role(rawValue: row["role"]) else { return nil }
                return ConversationTurn(id: row["id"], chatID: row["chatID"], role: role, text: row["text"],
                                        date: Date(timeIntervalSince1970: row["date"]))
            }
        }
    }

    public func appendTurn(_ turn: ConversationTurn) throws {
        try db.write { db in
            try db.execute(sql: "INSERT INTO turns (chatID, role, text, date) VALUES (?, ?, ?, ?)",
                           arguments: [turn.chatID, turn.role.rawValue, turn.text, turn.date.timeIntervalSince1970])
        }
    }

    public func clearTurns(chatID: String) throws {
        try db.write { db in
            try db.execute(sql: "DELETE FROM turns WHERE chatID = ?", arguments: [chatID])
        }
    }

    // MARK: - Tareas programadas

    public func tasks() throws -> [ScheduledTask] {
        try db.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM tasks ORDER BY id").compactMap { row in
                let raw: String = row["schedule"]
                guard let schedule = try? JSONDecoder().decode(TaskSchedule.self, from: Data(raw.utf8)) else { return nil }
                func date(_ column: String) -> Date? {
                    (row[column] as Double?).map(Date.init(timeIntervalSince1970:))
                }
                let recipients = (row["recipients"] as String?)
                    .flatMap { try? JSONDecoder().decode([TaskRecipient].self, from: Data($0.utf8)) } ?? []
                return ScheduledTask(id: row["id"], instruction: row["instruction"], schedule: schedule,
                                     enabled: (row["enabled"] as Int) != 0,
                                     createdAt: Date(timeIntervalSince1970: row["createdAt"]),
                                     nextRun: date("nextRun"), lastRun: date("lastRun"), lastResult: row["lastResult"],
                                     recipients: recipients,
                                     sendWithoutAsking: ((row["sendWithoutAsking"] as Int?) ?? 0) != 0)
            }
        }
    }

    static func recipientsJSON(_ recipients: [TaskRecipient]) -> String? {
        guard !recipients.isEmpty, let data = try? JSONEncoder().encode(recipients) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func scheduleJSON(_ schedule: TaskSchedule) throws -> String {
        String(decoding: try JSONEncoder().encode(schedule), as: UTF8.self)
    }

    @discardableResult
    public func addTask(_ task: ScheduledTask) throws -> ScheduledTask {
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO tasks (instruction, schedule, enabled, createdAt, nextRun, lastRun, lastResult, recipients,
                                   sendWithoutAsking)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [task.instruction, try Self.scheduleJSON(task.schedule), task.enabled ? 1 : 0,
                                 task.createdAt.timeIntervalSince1970, task.nextRun?.timeIntervalSince1970,
                                 task.lastRun?.timeIntervalSince1970, task.lastResult, Self.recipientsJSON(task.recipients),
                                 task.sendWithoutAsking ? 1 : 0])
            var saved = task
            saved.id = db.lastInsertedRowID
            return saved
        }
    }

    public func updateTask(_ task: ScheduledTask) throws {
        guard let id = task.id else { return }
        try db.write { db in
            try db.execute(sql: """
                UPDATE tasks SET instruction = ?, schedule = ?, enabled = ?, nextRun = ?, lastRun = ?, lastResult = ?,
                                 recipients = ?, recipientID = NULL, recipientTitle = NULL, recipientKind = NULL,
                                 sendWithoutAsking = ?
                WHERE id = ?
                """, arguments: [task.instruction, try Self.scheduleJSON(task.schedule), task.enabled ? 1 : 0,
                                 task.nextRun?.timeIntervalSince1970, task.lastRun?.timeIntervalSince1970,
                                 task.lastResult, Self.recipientsJSON(task.recipients), task.sendWithoutAsking ? 1 : 0, id])
        }
    }

    public func deleteTask(id: Int64) throws {
        try db.write { db in
            try db.execute(sql: "DELETE FROM tasks WHERE id = ?", arguments: [id])
        }
    }
}
