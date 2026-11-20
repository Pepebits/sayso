import SaySoCore
@testable import SaySoUI
import XCTest

/// Traducción al inglés: el archivo es válido, cubre las claves del código y respeta los huecos.
final class L10nTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let english = root.appendingPathComponent("Resources/en.lproj")

    private func table() throws -> [String: String] {
        let url = Self.english.appendingPathComponent("Localizable.strings")
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try XCTUnwrap(plist as? [String: String])
    }

    private func placeholders(_ text: String) -> Int {
        let pattern = try! NSRegularExpression(pattern: #"%(\d+\$)?@"#)
        return pattern.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    /// Claves literales pasadas a `tr("…")` en todo el código.
    private func keysInCode() throws -> Set<String> {
        let sources = Self.root.appendingPathComponent("Sources")
        let pattern = try NSRegularExpression(pattern: #"\btr\(\s*(?:[A-Za-z_.]+ \? )?"((?:[^"\\]|\\.)*)"(?:\s*:\s*"((?:[^"\\]|\\.)*)")?"#)
        var keys: Set<String> = []
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        while let file = files?.nextObject() as? URL {
            guard file.pathExtension == "swift" else { continue }
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                for group in 1...2 {
                    guard let range = Range(match.range(at: group), in: text) else { continue }
                    // El literal de Swift y la clave del archivo usan los mismos escapes básicos.
                    keys.insert(text[range].replacingOccurrences(of: #"\""#, with: "\"")
                        .replacingOccurrences(of: #"\n"#, with: "\n").replacingOccurrences(of: #"\'"#, with: "'"))
                }
            }
        }
        return keys
    }

    func testEveryKeyUsedInCodeHasAnEnglishTranslation() throws {
        let table = try table()
        let missing = try keysInCode().filter { table[$0] == nil }.sorted()
        XCTAssertTrue(missing.isEmpty, "Sin traducir: \(missing)")
    }

    func testPlaceholdersSurviveTranslation() throws {
        for (key, value) in try table() {
            XCTAssertEqual(placeholders(key), placeholders(value), "Huecos distintos en «\(key)»")
            XCTAssertFalse(value.trimmingCharacters(in: .whitespaces).isEmpty, "Traducción vacía de «\(key)»")
        }
    }

    func testLookupFormatsAndFallsBackToSpanish() throws {
        let previous = L10n.bundle
        defer { L10n.bundle = previous }
        L10n.bundle = try XCTUnwrap(Bundle(path: Self.english.path))
        XCTAssertEqual(tr("Permitir"), "Allow")
        XCTAssertEqual(tr("Paso %@ de %@", "2", "4"), "Step 2 of 4")
        XCTAssertEqual(tr("Texto que no existe en ningún sitio"), "Texto que no existe en ningún sitio")
        XCTAssertEqual(TaskSchedule.daily(hour: 9, minute: 0, weekdays: [1, 3]).summary(), "On Mon, Wed at 09:00")
    }

    func testSpanishIsTheDefaultWithoutBundledTranslations() {
        XCTAssertEqual(L10n.languageCode, "es")
        XCTAssertEqual(tr("Paso %@ de %@", "2", "4"), "Paso 2 de 4")
    }

    func testChosenLanguageOverridesTheSystemOne() throws {
        let previous = L10n.bundle
        defer { L10n.bundle = previous; L10n.forcedLanguage = nil }
        // Un bundle con las dos carpetas de idioma, como el de la app.
        L10n.bundle = try XCTUnwrap(Bundle(path: Self.root.appendingPathComponent("Resources").path))

        L10n.forcedLanguage = "en"
        XCTAssertEqual(L10n.forcedLanguage, "en")
        XCTAssertEqual(L10n.languageCode, "en")
        XCTAssertEqual(tr("Ajustes"), "Settings")

        L10n.forcedLanguage = "es"
        XCTAssertEqual(L10n.languageCode, "es")
        XCTAssertEqual(tr("Ajustes"), "Ajustes")

        // Un idioma que la app no lleva no cambia nada.
        L10n.forcedLanguage = "de"
        XCTAssertNil(L10n.forcedLanguage)

        L10n.forcedLanguage = "en"
        L10n.forcedLanguage = nil
        XCTAssertNil(L10n.forcedLanguage)
    }

    /// Los demás idiomas tienen que cubrir lo mismo que el inglés, que es el de referencia.
    func testEveryOtherLanguageCoversTheSameKeys() throws {
        let reference = try table()
        let resources = Self.root.appendingPathComponent("Resources")
        for code in LanguageChoice.allCases.compactMap(\.code) where code != "es" && code != "en" {
            let url = resources.appendingPathComponent("\(code).lproj/Localizable.strings")
            guard FileManager.default.fileExists(atPath: url.path) else {
                XCTFail("Falta la traducción de «\(code)»: \(url.path)")
                continue
            }
            let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
            let other = try XCTUnwrap(plist as? [String: String], code)
            let missing = reference.keys.filter { other[$0] == nil }.sorted()
            XCTAssertTrue(missing.isEmpty, "\(code): sin traducir \(missing.prefix(8))")
            for (key, value) in other {
                XCTAssertEqual(placeholders(key), placeholders(value), "\(code): huecos distintos en «\(key)»")
                XCTAssertFalse(value.trimmingCharacters(in: .whitespaces).isEmpty, "\(code): traducción vacía de «\(key)»")
            }
        }
    }

    func testEveryLanguageHasARegionAndANativeName() {
        for choice in LanguageChoice.allCases {
            guard let code = choice.code else { continue }
            XCTAssertNotNil(L10n.regions[code], code)
            XCTAssertNotNil(choice.nativeName, code)
        }
    }
}
