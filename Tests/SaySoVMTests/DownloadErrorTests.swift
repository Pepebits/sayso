import Foundation
@testable import SaySoVM
import XCTest

final class DownloadErrorTests: XCTestCase {
    /// Los cortes de red se explican en palabras claras y dicen que se puede seguir.
    func testNetworkErrorsAreExplainedPlainly() {
        XCTAssertEqual(VMImageError.download(URLError(.cancelled)), .cancelled)
        let offline = VMImageError.download(URLError(.notConnectedToInternet)).errorDescription ?? ""
        XCTAssertTrue(offline.contains("internet"), offline)
        XCTAssertTrue(offline.contains("sigue donde se quedó"), offline)
        let lost = VMImageError.download(URLError(.networkConnectionLost)).errorDescription ?? ""
        XCTAssertTrue(lost.contains("se cortó"), lost)
    }

    func testPartialDownloadIsDetected() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = VMFiles(directory: dir)
        XCTAssertFalse(files.hasPartialDownload)
        try Data([1, 2, 3]).write(to: files.resumeData)
        XCTAssertTrue(files.hasPartialDownload)
    }
}
