import Foundation
import SaySoCore
@testable import SaySoStore
import XCTest

final class SQLiteStoreTests: XCTestCase {
    private var store: SQLiteStore!

    override func setUpWithError() throws {
        store = try SQLiteStore.inMemory()
    }

    func testRules() throws {
        XCTAssertNil(try store.rule(for: "mac.volume"))
        try store.setRule(.allow, for: "mac.volume")
        try store.setRule(.never, for: "telegram.sendMessages")
        XCTAssertEqual(try store.rule(for: "mac.volume"), .allow)
        try store.setRule(.ask, for: "mac.volume")
        XCTAssertEqual(try store.rule(for: "mac.volume"), .ask)
        XCTAssertEqual(try store.allRules(), ["mac.volume": .ask, "telegram.sendMessages": .never])
        try store.setRule(nil, for: "mac.volume")
        XCTAssertNil(try store.rule(for: "mac.volume"))
    }

    func testActivityOrderScopeAndClear() throws {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let a = try store.appendActivity(.init(date: base, action: "mac.volume", summary: "v1",
                                               rule: .allow, outcome: .allowed, origin: "t1"))
        XCTAssertNotNil(a.id)
        try store.appendActivity(.init(date: base.addingTimeInterval(10), action: "telegram.sendMessages",
                                       summary: "t", rule: .ask, outcome: .denied))
        try store.appendActivity(.init(date: base.addingTimeInterval(20), action: "mac.note",
                                       summary: "n", rule: .ask, outcome: .failed))

        let all = try store.recentActivity(limit: 10, scope: nil)
        XCTAssertEqual(all.map(\.summary), ["n", "t", "v1"])
        XCTAssertEqual(all.last?.origin, "t1")
        XCTAssertEqual(all.first?.outcome, .failed)
        XCTAssertEqual(try store.recentActivity(limit: 1, scope: nil).map(\.summary), ["n"])
        XCTAssertEqual(try store.recentActivity(limit: 10, scope: "mac").map(\.summary), ["n", "v1"])
        XCTAssertEqual(try store.recentActivity(limit: 10, scope: "telegram").count, 1)

        XCTAssertEqual(try store.lastUse(of: "mac.volume"), base)
        XCTAssertNil(try store.lastUse(of: "mac.openURL"))

        try store.clearActivity(scope: "mac")
        XCTAssertEqual(try store.recentActivity(limit: 10, scope: nil).map(\.summary), ["t"])
        try store.clearActivity(scope: nil)
        XCTAssertTrue(try store.recentActivity(limit: 10, scope: nil).isEmpty)
    }

    func testNotes() throws {
        let n1 = try store.addNote(MemoryNote(text: "Prefiere café", source: "agente"))
        try store.addNote(MemoryNote(text: "Vive en Vigo"))
        XCTAssertEqual(try store.notes().map(\.text), ["Prefiere café", "Vive en Vigo"])
        XCTAssertEqual(try store.notes().first?.source, "agente")
        try store.deleteNote(id: try XCTUnwrap(n1.id))
        XCTAssertEqual(try store.notes().map(\.text), ["Vive en Vigo"])
    }

    func testSettingsAndCodable() throws {
        XCTAssertNil(try store.setting(SettingsKey.keepAwake))
        try store.setSetting("1", for: SettingsKey.keepAwake)
        XCTAssertEqual(try store.setting(SettingsKey.keepAwake), "1")
        try store.setSetting(nil, for: SettingsKey.keepAwake)
        XCTAssertNil(try store.setting(SettingsKey.keepAwake))

        let d = DictationSettings(side: .left, aiCorrection: true)
        try store.setCodableSetting(d, for: SettingsKey.dictation)
        XCTAssertEqual(try store.codableSetting(SettingsKey.dictation, as: DictationSettings.self), d)
    }

    func testSecrets() throws {
        let created = Date(timeIntervalSince1970: 500)
        try store.upsertSecret(SecretMeta(name: "GITHUB_TOKEN", reason: "PRs", status: .requested, createdAt: created))
        try store.upsertSecret(SecretMeta(name: "A_KEY", reason: "x", status: .stored))
        XCTAssertEqual(try store.secrets().map(\.name), ["A_KEY", "GITHUB_TOKEN"])

        let used = Date(timeIntervalSince1970: 900)
        try store.upsertSecret(SecretMeta(name: "GITHUB_TOKEN", reason: "PRs", status: .stored,
                                          lastUsed: used, createdAt: created))
        let gh = try XCTUnwrap(try store.secrets().first { $0.name == "GITHUB_TOKEN" })
        XCTAssertEqual(gh.status, .stored)
        XCTAssertEqual(gh.lastUsed, used)
        XCTAssertEqual(gh.createdAt, created)

        try store.deleteSecret(name: "GITHUB_TOKEN")
        XCTAssertEqual(try store.secrets().map(\.name), ["A_KEY"])
    }

    func testUsagePerLocalDay() throws {
        let cal = Calendar.current
        let morning = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 11, day: 18, hour: 0, minute: 5)))
        let night = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 11, day: 18, hour: 23, minute: 55)))
        let next = try XCTUnwrap(cal.date(byAdding: .day, value: 1, to: morning))

        XCTAssertEqual(try store.requestCount(on: morning), 0)
        try store.incrementRequests(on: morning)
        try store.incrementRequests(on: night)
        try store.incrementRequests(on: next)
        XCTAssertEqual(try store.requestCount(on: night), 2)
        XCTAssertEqual(try store.requestCount(on: next), 1)
    }

    func testDictationCountersAndStats() throws {
        let cal = Calendar.current
        let today = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 11, day: 18, hour: 15)))
        let yesterday = try XCTUnwrap(cal.date(byAdding: .day, value: -1, to: today))
        let longAgo = try XCTUnwrap(cal.date(byAdding: .day, value: -40, to: today))

        XCTAssertEqual(try store.usageStats(days: 7, now: today).allTime, UsageTotals())
        XCTAssertNil(try store.usageStats(days: 7, now: today).firstDay)

        try store.recordDictation(words: 12, seconds: 6.5, on: today)
        try store.recordDictation(words: 8, seconds: 3.5, on: today)
        try store.recordDictation(words: 30, seconds: 14, on: longAgo)
        try store.incrementRequests(on: today)
        try store.incrementRequests(on: yesterday)
        // Un dictado no cuenta como solicitud y una solicitud no toca los contadores del dictado.
        XCTAssertEqual(try store.requestCount(on: today), 1)

        try store.appendActivity(.init(date: today, action: "mac.volume", summary: "a", rule: .allow, outcome: .allowed))
        try store.appendActivity(.init(date: today.addingTimeInterval(60), action: "mac.volume", summary: "b",
                                       rule: .allow, outcome: .allowed))
        try store.appendActivity(.init(date: yesterday, action: "telegram.sendMessages", summary: "c",
                                       rule: .ask, outcome: .denied))
        try store.appendActivity(.init(date: longAgo, action: "vm.run", summary: "d", rule: .allow, outcome: .failed))

        let stats = try store.usageStats(days: 7, now: today)
        XCTAssertEqual(stats.days.count, 7)
        XCTAssertEqual(stats.days.last?.day, cal.startOfDay(for: today))
        XCTAssertEqual(stats.days.last?.totals, UsageTotals(requests: 1, dictations: 2, words: 20, seconds: 10))
        XCTAssertEqual(stats.days[5].totals, UsageTotals(requests: 1))
        XCTAssertEqual(stats.days[0].totals, UsageTotals())
        // Los totales cuentan también lo que queda fuera de la ventana.
        XCTAssertEqual(stats.allTime, UsageTotals(requests: 2, dictations: 3, words: 50, seconds: 24))
        XCTAssertEqual(stats.firstDay, cal.startOfDay(for: longAgo))
        XCTAssertEqual(stats.totals(lastDays: 1), UsageTotals(requests: 1, dictations: 2, words: 20, seconds: 10))
        XCTAssertEqual(stats.totals(lastDays: 2).requests, 2)

        XCTAssertEqual(Set(stats.actions), [
            ActionBucket(day: cal.startOfDay(for: today), action: "mac.volume", outcome: .allowed, count: 2),
            ActionBucket(day: cal.startOfDay(for: yesterday), action: "telegram.sendMessages", outcome: .denied, count: 1),
        ])
        XCTAssertEqual(stats.actions(lastDays: 1).map(\.count), [2])

        XCTAssertEqual(UsageStats.wordCount("  hola   mundo\nqué tal "), 4)
        XCTAssertEqual(UsageStats.wordCount(""), 0)
    }

    func testActivityCountAndPruneByAge() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let old = now.addingTimeInterval(-100 * 86_400)
        let recent = now.addingTimeInterval(-10 * 86_400)
        for (date, action) in [(old, "mac.volume"), (old, "telegram.sendMessages"), (recent, "mac.volume"), (now, "vm.run")] {
            try store.appendActivity(.init(date: date, action: ActionID(action), summary: "x", rule: .allow, outcome: .allowed))
        }
        try store.appendTurn(ConversationTurn(chatID: "1", role: .user, text: "viejo", date: old))
        try store.appendTurn(ConversationTurn(chatID: "1", role: .assistant, text: "nuevo", date: recent))

        XCTAssertEqual(try store.activityCount(scope: nil), 4)
        XCTAssertEqual(try store.activityCount(scope: "mac"), 2)
        XCTAssertEqual(try store.activityCount(scope: "plugin"), 0)

        let removed = try store.prune(olderThan: now.addingTimeInterval(-90 * 86_400))
        XCTAssertEqual(removed.activity, 2)
        XCTAssertEqual(removed.turns, 1)
        XCTAssertEqual(try store.activityCount(scope: nil), 2)
        XCTAssertEqual(try store.activityCount(scope: "mac"), 1)
        XCTAssertEqual(try store.turns(chatID: "1", limit: 10).map(\.text), ["nuevo"])
        // Repetirlo no borra nada más.
        let again = try store.prune(olderThan: now.addingTimeInterval(-90 * 86_400))
        XCTAssertEqual(again.activity + again.turns, 0)
    }

    func testTrimKeepsOnlyTheNewestRows() throws {
        let base = Date(timeIntervalSince1970: 50_000)
        for i in 0..<6 {
            try store.appendTurn(ConversationTurn(chatID: "1", role: .user, text: "t\(i)", date: base.addingTimeInterval(Double(i))))
        }
        let removed = try store.trim(keepActivity: 100, keepTurns: 4)
        XCTAssertEqual(removed.turns, 2)
        XCTAssertEqual(try store.turns(chatID: "1", limit: 10).map(\.text), ["t2", "t3", "t4", "t5"])
        XCTAssertEqual(try store.trim(keepActivity: 100, keepTurns: 4).turns, 0)
    }

    func testTurnsLastNChronological() throws {
        let base = Date(timeIntervalSince1970: 10_000)
        for i in 0..<5 {
            try store.appendTurn(ConversationTurn(chatID: "42", role: i.isMultiple(of: 2) ? .user : .assistant,
                                                  text: "m\(i)", date: base.addingTimeInterval(Double(i))))
        }
        try store.appendTurn(ConversationTurn(chatID: "7", role: .user, text: "otro", date: base))

        let last3 = try store.turns(chatID: "42", limit: 3)
        XCTAssertEqual(last3.map(\.text), ["m2", "m3", "m4"])
        XCTAssertEqual(last3.first?.role, .user)
        XCTAssertNotNil(last3.first?.id)
        XCTAssertEqual(try store.turns(chatID: "42", limit: 50).count, 5)

        try store.clearTurns(chatID: "42")
        XCTAssertTrue(try store.turns(chatID: "42", limit: 10).isEmpty)
        XCTAssertEqual(try store.turns(chatID: "7", limit: 10).count, 1)
    }

    func testFileDatabasePersists() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("sayso.sqlite")
        do {
            let s = try SQLiteStore(url: url)
            try s.setRule(.never, for: "mac.note")
        }
        let reopened = try SQLiteStore(url: url)
        XCTAssertEqual(try reopened.rule(for: "mac.note"), .never)
    }

    func testTaskRecipientIsSavedAndCleared() throws {
        let lucas = TaskRecipient(id: -100_123, title: "Lucas Moreno", kind: "privado", username: "lucas_mor82")
        let equipo = TaskRecipient(id: -200, title: "Equipo", kind: "grupo")
        var saved = try store.addTask(ScheduledTask(instruction: "Buenos días", schedule: .every(minutes: 60),
                                                    recipients: [lucas, equipo]))
        XCTAssertEqual(try store.tasks().first?.recipients, [lucas, equipo])
        XCTAssertEqual(try store.tasks().first?.recipients.first?.displayName, "Lucas Moreno (@lucas_mor82)")
        saved.recipients = [equipo]
        try store.updateTask(saved)
        XCTAssertEqual(try store.tasks().first?.recipients, [equipo])
        saved.recipients = []
        try store.updateTask(saved)
        XCTAssertEqual(try store.tasks().first?.recipients, [])
        XCTAssertEqual([lucas, equipo].names, "«Lucas Moreno» y «Equipo»")
        var auto = try store.addTask(ScheduledTask(instruction: "Sin preguntar", schedule: .every(minutes: 60),
                                                   recipients: [lucas], sendWithoutAsking: true))
        XCTAssertEqual(try store.tasks().last?.sendWithoutAsking, true)
        auto.sendWithoutAsking = false
        try store.updateTask(auto)
        XCTAssertEqual(try store.tasks().last?.sendWithoutAsking, false)
    }

    func testScheduledTasks() throws {
        XCTAssertTrue(try store.tasks().isEmpty)
        let next = Date(timeIntervalSince1970: 1_800_000_000)
        let saved = try store.addTask(ScheduledTask(instruction: "Calendario",
                                                    schedule: .daily(hour: 9, minute: 0, weekdays: [1, 2]), nextRun: next))
        try store.addTask(ScheduledTask(instruction: "Cada rato", schedule: .every(minutes: 15)))
        XCTAssertNotNil(saved.id)
        var all = try store.tasks()
        XCTAssertEqual(all.map(\.instruction), ["Calendario", "Cada rato"])
        XCTAssertEqual(all[0].schedule, .daily(hour: 9, minute: 0, weekdays: [1, 2]))
        XCTAssertEqual(all[0].nextRun, next)
        XCTAssertNil(all[1].nextRun)

        all[0].enabled = false
        all[0].lastRun = next
        all[0].lastResult = "Hecho"
        all[0].nextRun = nil
        try store.updateTask(all[0])
        let updated = try store.tasks()[0]
        XCTAssertFalse(updated.enabled)
        XCTAssertEqual(updated.lastResult, "Hecho")
        XCTAssertEqual(updated.lastRun, next)
        XCTAssertNil(updated.nextRun)

        try store.deleteTask(id: saved.id!)
        XCTAssertEqual(try store.tasks().map(\.instruction), ["Cada rato"])
    }

    func testNotesKeepTheirKind() throws {
        let saved = try store.addNote(MemoryNote(text: "Usa perros en vez de gatos", kind: .instruction))
        try store.addNote(MemoryNote(text: "Vive en Vigo"))
        XCTAssertEqual(try store.notes().map(\.kind), [.instruction, .fact])
        try store.setNoteKind(.fact, id: try XCTUnwrap(saved.id))
        XCTAssertEqual(try store.notes().map(\.kind), [.fact, .fact])
        try store.updateNoteText("Usa perros, nunca gatos", id: try XCTUnwrap(saved.id))
        XCTAssertEqual(try store.notes().first?.text, "Usa perros, nunca gatos")
        XCTAssertEqual(try store.notes().count, 2)
    }
}
