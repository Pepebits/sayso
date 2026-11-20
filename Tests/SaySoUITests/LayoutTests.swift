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
