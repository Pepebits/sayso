import Foundation
@testable import SaySoCore
import XCTest

final class LogAndExportTests: XCTestCase {
    private var url: URL!

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("sayso-log-\(UUID().uuidString).log")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: url)
    }

    private func entry(_ second: Int, _ level: LogLevel = .info, _ category: String = LogCategory.app,
                       _ message: String = "hola") -> LogEntry {
        LogEntry(date: Date(timeIntervalSince1970: 1_800_000_000 + Double(second)), level: level,
                 category: category, message: message)
    }

    func testAppendReadAndClear() {
        let file = AppLogFile(url: url)
        XCTAssertEqual(file.entries(limit: 10), [])
        file.append(entry(1, .info, LogCategory.telegram, "Bot conectado"))
        file.append(entry(2, .error, LogCategory.dictation, "Fallo\ncon salto\ty tabulador"))
        file.append(entry(3, .warning, LogCategory.voice, "Respuesta lenta"))

        let read = file.entries(limit: 10)
        XCTAssertEqual(read.map(\.level), [.info, .error, .warning])
        XCTAssertEqual(read.map(\.category), ["telegram", "dictado", "voz"])
        // Cada entrada ocupa una sola línea: saltos y tabuladores pasan a espacios.
        XCTAssertEqual(read[1].message, "Fallo con salto y tabulador")
        XCTAssertEqual(read[0].date, entry(1).date)
        XCTAssertEqual(file.entries(limit: 2).map(\.message), ["Fallo con salto y tabulador", "Respuesta lenta"])

        file.clear()
        XCTAssertEqual(file.entries(limit: 10), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testBadLinesAreSkipped() throws {
        try Data("basura\n2027-01-15T08:00:00Z\tERROR\tapp\tbien\n\tsin fecha\tapp\tmal\n".utf8).write(to: url)
        XCTAssertEqual(AppLogFile(url: url).entries(limit: 10).map(\.message), ["bien"])
    }

    func testFileIsTrimmedToTheMostRecentHalf() {
        let file = AppLogFile(url: url, maxBytes: 2_000)
        for i in 0..<200 { file.append(entry(i, .info, LogCategory.app, "entrada número \(i)")) }
        let read = file.entries(limit: 1_000)
        XCTAssertEqual(read.last?.message, "entrada número 199")
        XCTAssertLessThan(read.count, 200)
        XCTAssertGreaterThan(read.count, 5)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        XCTAssertLessThanOrEqual(size, 2_100)
        // Lo que queda es un tramo seguido, sin huecos.
        let numbers = read.compactMap { Int($0.message.split(separator: " ").last ?? "") }
        XCTAssertEqual(numbers, Array((200 - read.count)..<200))
    }

    func testLogExports() throws {
        let entries = [entry(1, .error, LogCategory.plugins, "GitHub: falta \"token\", revisa"), entry(2)]
        XCTAssertEqual(Export.log(entries, as: .text),
                       "2027-01-15T08:00:01Z\tERROR\tplugins\tGitHub: falta \"token\", revisa\n2027-01-15T08:00:02Z\tINFO\tapp\thola\n")
        XCTAssertEqual(Export.log(entries, as: .csv), """
            date,level,category,message
            2027-01-15T08:00:01Z,error,plugins,"GitHub: falta ""token"", revisa"
            2027-01-15T08:00:02Z,info,app,hola

            """)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(Export.log(entries, as: .json).utf8)) as? [[String: String]])
        XCTAssertEqual(json.map { $0["level"] }, ["error", "info"])
        XCTAssertEqual(json[0]["date"], "2027-01-15T08:00:01Z")
        XCTAssertEqual(json[0]["message"], "GitHub: falta \"token\", revisa")
        XCTAssertEqual(Export.log([], as: .text), "")
        XCTAssertEqual(Export.log([], as: .csv), "date,level,category,message\n")
    }

    func testStatsExports() throws {
        let cal = Calendar.current
        let d1 = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 11, day: 17)))
        let d2 = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 11, day: 18)))
        let days = [DayUsage(day: d1), DayUsage(day: d2, totals: UsageTotals(requests: 105, dictations: 4, words: 61, seconds: 22.44))]
        let actions = [ActionBucket(day: d2, action: "vm.run", outcome: .failed, count: 2),
                       ActionBucket(day: d1, action: "mac.volume", outcome: .allowed, count: 1)]
        XCTAssertEqual(Export.stats(days: days, actions: actions, as: .csv), """
            day,requests,dictations,words,seconds
            2026-11-17,0,0,0,0.0
            2026-11-18,105,4,61,22.4

            """)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(Export.stats(days: days, actions: actions, as: .json).utf8)) as? [String: Any])
        let jsonDays = try XCTUnwrap(json["days"] as? [[String: Any]])
        XCTAssertEqual(jsonDays.last?["requests"] as? Int, 105)
        let jsonActions = try XCTUnwrap(json["actions"] as? [[String: Any]])
        XCTAssertEqual(jsonActions.map { $0["action"] as? String }, ["mac.volume", "vm.run"])
        XCTAssertEqual(jsonActions.last?["outcome"] as? String, "failed")
    }
}
