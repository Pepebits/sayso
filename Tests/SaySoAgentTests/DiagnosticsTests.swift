import Foundation
import SaySoCore
import XCTest

final class DiagnosticsTests: XCTestCase {
    func testScrubHidesPersonalData() {
        let text = """
        /Users/someone/Library/x.log ana.perez@example.com +34 600 123 456 @anna_design \
        chat 123456789 «Equipo diseño» v0.3.0 (7) port 8080
        """
        let out = DiagnosticsReport.scrub(text, home: "/Users/someone")
        XCTAssertEqual(out, "~/Library/x.log <email> <phone> @<user> chat <number> «…» v0.3.0 (7) port 8080")
    }

    func testScrubHidesTokens() {
        let out = DiagnosticsReport.scrub("bot 123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsaw0 key sk-ant-api03-abcdefghijklmnop", home: "/x")
        XCTAssertEqual(out, "bot <bot-token> key <api-key>")
    }

    func testParsesACrashReport() throws {
        let header = #"{"app_name":"SaySo","timestamp":"2026-11-19 02:26:10.00 +0100","app_version":"0.3.0","os_version":"macOS 27.2 (27C50)"}"#
        let body = #"""
        {"exception":{"type":"EXC_CRASH","signal":"SIGABRT"},"termination":{"indicator":"Abort trap: 6"},
         "asi":{"libsystem_c.dylib":["abort() called"]},"faultingThread":1,
         "usedImages":[{"name":"libsystem_kernel.dylib"},{"name":"SaySo"}],
         "threads":[{"frames":[]},{"frames":[{"imageIndex":0,"symbol":"__pthread_kill"},{"imageIndex":1,"symbol":"td::Scheduler::clear()"},{"imageIndex":1,"imageOffset":4096}]}]}
        """#
        let crash = try XCTUnwrap(CrashSummary.parse(header + "\n" + body))
        XCTAssertEqual(crash.exception, "EXC_CRASH (SIGABRT)")
        XCTAssertEqual(crash.reasons, ["abort() called", "Abort trap: 6"])
        XCTAssertEqual(crash.frames, ["libsystem_kernel.dylib  __pthread_kill", "SaySo  td::Scheduler::clear()", "SaySo  +0x1000"])
        XCTAssertEqual(crash.appVersion, "0.3.0")
        XCTAssertNotNil(crash.date)
        XCTAssertNil(CrashSummary.parse("not a report"))
    }

    func testReportKeepsRecentWarningsOnlyAndRedacts() {
        let now = Date()
        let logs = [
            LogEntry(date: now.addingTimeInterval(-60), level: .error, category: "telegram", message: "Fallo con token sk-SECRET-123"),
            LogEntry(date: now.addingTimeInterval(-60), level: .info, category: "app", message: "solo info"),
            LogEntry(date: now.addingTimeInterval(-30 * 86_400), level: .error, category: "app", message: "muy antiguo"),
        ]
        let report = DiagnosticsReport.make(appVersion: "0.3.0 (7)", osVersion: "macOS 27.2", machine: "Mac16,1",
                                            state: [("Agent", "running")], logs: logs, crashes: [], now: now,
                                            home: "/Users/someone",
                                            redact: { $0.replacingOccurrences(of: "sk-SECRET-123", with: "[KEY]") })
        XCTAssertTrue(report.contains("Fallo con token [KEY]"))
        XCTAssertFalse(report.contains("solo info"))
        XCTAssertFalse(report.contains("muy antiguo"))
        XCTAssertTrue(report.contains("- Agent: running"))
        XCTAssertTrue(report.contains("None in the last 30 days."))
    }

    func testCrashFramesKeepSwiftAttributes() {
        let crash = CrashSummary(date: nil, appVersion: "0.3.0", osVersion: "macOS", exception: "EXC_BAD_ACCESS (SIGSEGV)",
                                 reasons: [], frames: ["SaySo  thunk for @escaping @callee_guaranteed () -> ()",
                                                       "SaySo  /Users/someone/x.swift"])
        let report = DiagnosticsReport.make(appVersion: "0.3.0", osVersion: "macOS", machine: "Mac", state: [],
                                            logs: [], crashes: [crash], home: "/Users/someone")
        XCTAssertTrue(report.contains("thunk for @escaping @callee_guaranteed () -> ()"))
        XCTAssertTrue(report.contains("SaySo  ~/x.swift"))
        XCTAssertFalse(report.contains("\u{1}"))
    }
}
