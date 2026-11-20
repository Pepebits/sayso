@testable import SaySoUI
import XCTest

/// Contraste de la paleta según WCAG 2.2: texto 4,5:1; contornos de controles y gráficos 3:1.
final class PaletteTests: XCTestCase {
    private struct Mode {
        var name: String
        var pick: (PaletteColor) -> UInt32
    }

    private let modes = [
        Mode(name: "claro") { $0.light }, Mode(name: "oscuro") { $0.dark },
        Mode(name: "claro HC") { $0.lightHC }, Mode(name: "oscuro HC") { $0.darkHC },
    ]

    private func check(_ color: PaletteColor, _ label: String, atLeast minimum: Double,
                       file: StaticString = #filePath, line: UInt = #line) {
        for mode in modes {
            for (ground, groundName) in [(Palette.paper, "fondo"), (Palette.surface, "tarjeta")] {
                let ratio = Palette.contrast(mode.pick(color), mode.pick(ground))
                XCTAssertGreaterThanOrEqual(ratio, minimum, "\(label) sobre \(groundName), modo \(mode.name)",
                                            file: file, line: line)
            }
        }
    }

    func testContrastFormula() {
        XCTAssertEqual(Palette.contrast(0x000000, 0xFFFFFF), 21, accuracy: 0.01)
        XCTAssertEqual(Palette.contrast(0x777777, 0xFFFFFF), 4.48, accuracy: 0.01)
    }

    func testTextReachesAA() {
        check(Palette.ink, "texto", atLeast: 7)
        check(Palette.secondary, "secundario", atLeast: 4.5)
        check(Palette.tertiary, "terciario", atLeast: 4.5)
        check(Palette.destructive, "destructivo", atLeast: 4.5)
    }

    func testControlsAndIndicatorsReachThreeToOne() {
        check(Palette.controlBorder, "borde de control", atLeast: 3)
        check(Palette.running, "verde de en marcha", atLeast: 3)
        check(Palette.chartAI, "barras de la IA", atLeast: 3)
        check(Palette.chartVoice, "barras de la voz", atLeast: 3)
    }

    func testHighContrastVariantsAreStronger() {
        for color in [Palette.secondary, Palette.tertiary, Palette.controlBorder, Palette.border] {
            XCTAssertGreaterThan(Palette.contrast(color.lightHC, Palette.paper.light),
                                 Palette.contrast(color.light, Palette.paper.light))
            XCTAssertGreaterThan(Palette.contrast(color.darkHC, Palette.paper.dark),
                                 Palette.contrast(color.dark, Palette.paper.dark))
        }
    }

    func testFixedTagsStayLegible() {
        XCTAssertGreaterThanOrEqual(Palette.contrast(Theme.inkHex, 0xFDD400), 4.5)
        XCTAssertGreaterThanOrEqual(Palette.contrast(Theme.inkHex, 0x00C2BA), 4.5)
        // Texto del terminal sobre el bloque de tinta.
        XCTAssertGreaterThanOrEqual(Palette.contrast(Palette.destructive.dark, Theme.inkHex), 4.5)
    }
}
