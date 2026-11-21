@testable import SaySoUI
import XCTest

/// Las rejillas de módulos reducen columnas antes que recortar su contenido.
final class LayoutTests: XCTestCase {
    func testGridKeepsWantedColumnsWhenTheyFit() {
        XCTAssertEqual(TileGridLayout.columns(wanted: 3, width: 760, minTileWidth: 226, spacing: 12), 3)
        XCTAssertEqual(TileGridLayout.columns(wanted: 2, width: 760, minTileWidth: 344, spacing: 12), 2)
    }

    func testGridDropsColumnsInANarrowWindow() {
        // Ventana al ancho mínimo (920): quedan unos 625 puntos de contenido.
        XCTAssertEqual(TileGridLayout.columns(wanted: 3, width: 625, minTileWidth: 226, spacing: 12), 2)
        XCTAssertEqual(TileGridLayout.columns(wanted: 2, width: 625, minTileWidth: 344, spacing: 12), 1)
    }

    func testGridNeverGoesBelowOneColumn() {
        XCTAssertEqual(TileGridLayout.columns(wanted: 3, width: 40, minTileWidth: 226, spacing: 12), 1)
        XCTAssertEqual(TileGridLayout.columns(wanted: 0, width: 760, minTileWidth: nil, spacing: 12), 1)
    }
}

/// Añadir una cuenta de IA de fuera del Mac pide permiso explícito; una local, no.
final class ProviderConsentTests: XCTestCase {
    func testOnlyLocalProvidersSkipConsent() {
        XCTAssertTrue(AddAccountSheet.isLocal(URL(string: "http://localhost:11434/v1")!))
        XCTAssertTrue(AddAccountSheet.isLocal(URL(string: "http://127.0.0.1:8080")!))
        XCTAssertTrue(AddAccountSheet.isLocal(URL(string: "http://estudio.local:1234")!))
        XCTAssertFalse(AddAccountSheet.isLocal(URL(string: "https://api.anthropic.com")!))
        XCTAssertFalse(AddAccountSheet.isLocal(URL(string: "https://localhost.example.com")!))
    }
}

final class PublicPagesTests: XCTestCase {
    func testPrivacyPolicyFollowsTheAppLanguage() {
        XCTAssertEqual(PublicPages.privacy(language: "es").absoluteString, "https://pepebits.github.io/sayso/privacidad/")
        XCTAssertEqual(PublicPages.privacy(language: "gl").absoluteString, "https://pepebits.github.io/sayso/privacidad/")
        XCTAssertEqual(PublicPages.privacy(language: "fr").absoluteString, "https://pepebits.github.io/sayso/privacy/")
    }
}
