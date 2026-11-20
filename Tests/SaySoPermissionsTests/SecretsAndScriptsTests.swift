import Foundation
import SaySoCore
@testable import SaySoPermissions
import XCTest

final class SecretRedactorTests: XCTestCase {
    private let secret = "s3cr3t valor/+=?&ñ"

    private func redactor(_ values: [String: String]) -> SecretRedactor {
        SecretRedactor { values }
    }

    func testLiteral() {
        let r = redactor(["API_KEY": secret])
        XCTAssertEqual(r.redact("clave: \(secret)."), "clave: [API_KEY].")
        XCTAssertEqual(r.redact("\(secret)\(secret)"), "[API_KEY][API_KEY]")
    }

    func testBase64() {
        let r = redactor(["API_KEY": secret])
        let b64 = Data(secret.utf8).base64EncodedString()
        XCTAssertEqual(r.redact("Authorization: Basic \(b64)"), "Authorization: Basic [API_KEY]")
        let noPad = b64.trimmingCharacters(in: CharacterSet(charactersIn: "="))
        XCTAssertEqual(r.redact("x=\(noPad)"), "x=[API_KEY]")
    }

    func testURLEncoded() {
        let r = redactor(["API_KEY": secret])
        let strict = secret.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"))!
        XCTAssertNotEqual(strict, secret)
        XCTAssertEqual(r.redact("https://x.com/?k=\(strict)"), "https://x.com/?k=[API_KEY]")
        let query = secret.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        XCTAssertEqual(r.redact("?k=\(query)"), "?k=[API_KEY]")
    }

    func testShortValuesIgnored() {
        let r = redactor(["PIN": "12345", "EMPTY": ""])
        XCTAssertEqual(r.redact("pin 12345"), "pin 12345")
    }

    func testLongestFirst() {
        let r = redactor(["SHORT": "abcdef", "LONG": "abcdef-ghijkl"])
        XCTAssertEqual(r.redact("abcdef-ghijkl y abcdef"), "[LONG] y [SHORT]")
    }

    func testValuesAreReadOnEachCall() {
        let vault = InMemoryVault()
        let r = SecretRedactor { vault.allValues() }
        XCTAssertEqual(r.redact("token123"), "token123")
        try? vault.setValue("token123", for: "T")
        XCTAssertEqual(r.redact("token123"), "[T]")
    }
}

final class InMemoryVaultTests: XCTestCase {
    func testRoundTrip() throws {
        let vault = InMemoryVault()
        XCTAssertNil(try vault.value(for: "a"))
        try vault.setValue("1", for: "a")
        try vault.setValue("2", for: "a")
        XCTAssertEqual(try vault.value(for: "a"), "2")
        try vault.removeValue(for: "a")
        XCTAssertNil(try vault.value(for: "a"))
    }
}

final class MacScriptRunnerTests: XCTestCase {
    func testVolumeIsClamped() throws {
        XCTAssertEqual(try MacScriptRunner.validated(.volume(percent: 150)), .volume(percent: 100))
        XCTAssertEqual(try MacScriptRunner.validated(.volume(percent: -20)), .volume(percent: 0))
        XCTAssertEqual(try MacScriptRunner.validated(.volume(percent: 35)), .volume(percent: 35))
    }

    func testOnlyHTTPAndHTTPSURLs() throws {
        for ok in ["https://example.com/a?b=1", "http://example.com", "HTTPS://EXAMPLE.COM"] {
            XCTAssertNoThrow(try MacScriptRunner.validated(.openURL(URL(string: ok)!)), ok)
        }
        for bad in ["file:///etc/passwd", "javascript:alert(1)", "ftp://x.com", "x-apple.systempreferences:foo",
                    "mailto:a@b.com", "https:///sinhost"] {
            XCTAssertThrowsError(try MacScriptRunner.validated(.openURL(URL(string: bad)!)), bad) { error in
                guard case MacScriptError.invalidURL = error else { return XCTFail("\(error)") }
            }
        }
    }

    func testRequestsGoThroughBrokerWithRealParameters() async throws {
        let broker = RecordingBroker()
        let runner = MacScriptRunner(broker: broker)

        do { _ = try await runner.run(.volume(percent: 300), origin: "chat:1"); XCTFail() } catch {}
        do { _ = try await runner.run(.note(title: "Compra", body: "\" & do shell script \"rm\""), origin: nil); XCTFail() } catch {}

        let reqs = broker.requests
        XCTAssertEqual(reqs.map(\.action), ["mac.volume", "mac.note"])
        XCTAssertEqual(reqs[0].parameters["volumen"], "100")
        XCTAssertTrue(reqs[0].summary.contains("100"))
        XCTAssertEqual(reqs[0].origin, "chat:1")
        XCTAssertEqual(reqs[1].parameters["título"], "Compra")
        XCTAssertTrue(reqs[1].summary.contains("do shell script"))
    }

    func testInvalidURLNeverReachesBroker() async {
        let broker = RecordingBroker()
        let runner = MacScriptRunner(broker: broker)
        do {
            _ = try await runner.run(.openURL(URL(string: "file:///tmp")!), origin: nil)
            XCTFail()
        } catch {
            XCTAssertEqual(error as? MacScriptError, .invalidURL("file:///tmp"))
        }
        XCTAssertTrue(broker.requests.isEmpty)
    }

    func testCalendarFormatting() {
        let start = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(MacScriptRunner.format(events: []), "No hay eventos hoy.")
        let text = MacScriptRunner.format(events: [("Comida", start, start.addingTimeInterval(3600), false, "Vigo"),
                                                   ("Vacaciones", start, start, true, nil)])
        XCTAssertTrue(text.hasPrefix("Eventos de hoy:\n- "))
        XCTAssertTrue(text.contains("Comida (Vigo)"))
        XCTAssertTrue(text.contains("- Todo el día: Vacaciones"))
    }

    func testCalendarCanReadOtherDaysAndRanges() {
        let cal = Calendar.current
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 12))!
        let friday = cal.date(from: DateComponents(year: 2026, month: 11, day: 27))!
        XCTAssertEqual(MacScriptRunner.format(events: [], start: friday, days: 1, now: now),
                       "No hay eventos (viernes, 27 de noviembre).", "otro día no dice «hoy»")
        let event = cal.date(from: DateComponents(year: 2026, month: 11, day: 28, hour: 10))!
        let week = MacScriptRunner.format(events: [("Dentista", event, event.addingTimeInterval(1800), false, nil)],
                                          start: friday, days: 7, now: now)
        XCTAssertTrue(week.hasPrefix("Eventos (viernes, 27 de noviembre – jueves, 3 de diciembre):"), week)
        XCTAssertTrue(week.contains("- sábado, 28 de noviembre, "), "con varios días, cada evento lleva su día")
        XCTAssertTrue(MacScriptRunner.calendarRange(start: now, days: 1, now: now).contains("hoy"))
        XCTAssertTrue(MacScriptRunner.calendarRange(start: friday, days: 7, now: now).contains(" al "))
        XCTAssertEqual(MacScriptCall.calendar(start: friday, days: 3).script, .calendarToday,
                       "misma acción que antes: la regla de permisos guardada sigue valiendo")
    }

    func testRemindersListCarriesTheIDsForLaterChanges() {
        let due = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 24, hour: 9))!
        let text = MacScriptRunner.format(reminders: [
            .init(id: "B", title: "Comprar pilas", due: nil, list: "Casa", done: false),
            .init(id: "A", title: "Dentista", due: due, list: "Recordatorios", done: false),
        ])
        let lines = text.split(separator: "\n")
        XCTAssertTrue(lines[0].hasPrefix("id A · Dentista · "), "los que tienen fecha, primero")
        XCTAssertEqual(lines[1], "id B · Comprar pilas · lista «Casa»")
        XCTAssertEqual(MacScriptRunner.format(reminders: []), "No hay recordatorios.")
        let ask = MacScriptRunner.request(for: .changeReminder(id: "A", title: "Dentista", change: .delete), origin: nil)
        XCTAssertEqual(ask.action, MacScript.changeReminder.action)
        XCTAssertTrue(ask.summary.contains("Dentista"))
    }
}
