import SaySoCore
@testable import SaySoUI
import XCTest

/// Buscador de la barra lateral: qué encuentra, por qué y en qué orden.
final class SearchTests: XCTestCase {
    func testEmptyQueryListsEveryScreenInOrder() {
        XCTAssertEqual(SettingsScreen.search("  ").map(\.screen), SettingsScreen.allCases)
        XCTAssertTrue(SettingsScreen.search("").allSatisfy { $0.reason == nil })
    }

    func testFindsScreensByNameIgnoringCaseAndAccents() {
        XCTAssertEqual(SettingsScreen.search("estadisticas").map(\.screen), [.estadisticas])
        XCTAssertEqual(SettingsScreen.search("TELE").first?.screen, .telegram)
        XCTAssertNil(SettingsScreen.search("TELE").first?.reason)
    }

    func testFindsASettingInsideAScreenAndSaysWhich() {
        let idioma = SettingsScreen.search("idioma")
        XCTAssertEqual(idioma.map(\.screen), [.ajustes])
        XCTAssertEqual(idioma.first?.reason, "Idioma")
        XCTAssertEqual(SettingsScreen.search("corregir").first, .init(screen: .dictado, reason: "Corregir con IA", rank: 1))
        // Una palabra que no se ve en la pantalla también vale, y se dice cuál ha coincidido.
        XCTAssertEqual(SettingsScreen.search("whisper").first, .init(screen: .dictado, reason: "whisper", rank: 2))
    }

    func testNameMatchesComeBeforeSettingMatches() {
        // «registros» es una pantalla y también un ajuste dentro de otras.
        let hits = SettingsScreen.search("regist")
        XCTAssertEqual(hits.first?.screen, .registros)
        XCTAssertNil(hits.first?.reason)
        XCTAssertEqual(hits.map(\.rank), hits.map(\.rank).sorted())
    }

    func testSearchingAGroupNameListsItsScreens() {
        XCTAssertEqual(Set(SettingsScreen.search("permisos").map(\.screen)).isSuperset(of: [.telegram, .mac, .secretos]), true)
        XCTAssertEqual(SettingsScreen.search("xyzzy"), [])
    }

    /// Cada ajuste del índice tiene que existir con ese nombre en el código de su pantalla: si se
    /// renombra un rótulo, el buscador no debe seguir anunciando el antiguo.
    func testEveryTopicIsARealLabelSomewhereInTheUI() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/SaySoUI")
        var code = ""
        for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        where file.pathExtension == "swift" && file.lastPathComponent != "SettingsRootView.swift" {
            code += try String(contentsOf: file, encoding: .utf8)
        }
        for screen in SettingsScreen.allCases {
            XCTAssertFalse(screen.topics.isEmpty, "\(screen.rawValue) sin ajustes en el índice")
            for topic in screen.topics {
                XCTAssertTrue(code.contains("\"\(topic)\""), "«\(topic)» no aparece como rótulo en ninguna pantalla")
            }
        }
    }
}
