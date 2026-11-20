import Foundation
@testable import SaySoUI
import XCTest

/// Avisos de licencia: el archivo se puede leer, lista los componentes y está al día.
final class LicensesTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func notices() throws -> ThirdPartyNotices {
        let url = Self.root.appendingPathComponent("Resources/ThirdPartyNotices.txt")
        return ThirdPartyNotices(text: try String(contentsOf: url, encoding: .utf8))
    }

    func testListsEveryComponentWithItsLicence() throws {
        let components = try notices().components
        XCTAssertEqual(components.map(\.license), [
            "MIT License", "MIT License", "MIT License", "Boost Software License 1.0", "zlib License", "Apache License 2.0",
        ])
        XCTAssertTrue(components[0].name.hasPrefix("GRDB.swift "))
        XCTAssertTrue(components[1].name.hasPrefix("WhisperKit"))
        XCTAssertEqual(components.suffix(3).map(\.name), ["TDLib", "zlib", "OpenSSL"])
        XCTAssertTrue(components.allSatisfy { $0.url.hasPrefix("https://") })
    }

    func testCarriesTheLicenceTexts() throws {
        let text = try notices().text
        XCTAssertTrue(text.contains("Permission is hereby granted, free of charge"))
        XCTAssertTrue(text.contains("Boost Software License - Version 1.0"))
        XCTAssertTrue(text.contains("Apache License"))
        XCTAssertTrue(text.contains("Jean-loup Gailly and Mark Adler"))
    }

    /// Si se actualiza una dependencia y no se regenera el archivo, las versiones dejan de cuadrar.
    func testVersionsMatchTheResolvedPackages() throws {
        let data = try Data(contentsOf: Self.root.appendingPathComponent("Package.resolved"))
        let resolved = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let pins = try XCTUnwrap(resolved["pins"] as? [[String: Any]])
        let text = try notices().text
        for identity in ["grdb.swift", "whisperkit", "tdlibframework"] {
            let pin = try XCTUnwrap(pins.first { $0["identity"] as? String == identity }, identity)
            let version = try XCTUnwrap((pin["state"] as? [String: Any])?["version"] as? String, identity)
            XCTAssertTrue(text.contains(" \(version)\n"),
                          "\(identity) \(version) no figura en ThirdPartyNotices.txt: ejecuta scripts/generate-third-party-notices.py")
        }
    }

    func testEmptyTextHasNoComponents() {
        XCTAssertEqual(ThirdPartyNotices(text: "").components, [])
    }
}
