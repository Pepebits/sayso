import SaySoCore
@testable import SaySoVM
import XCTest

final class MachineSizeTests: XCTestCase {
    func testTheDiskGrowsButNeverShrinks() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sayso-vm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = VMFiles(directory: dir)
        FileManager.default.createFile(atPath: files.disk.path, contents: Data(count: 1024))
        XCTAssertTrue(try files.growDisk(to: 1 << 30))
        XCTAssertEqual(files.diskSize, 1 << 30)
        XCTAssertFalse(try files.growDisk(to: 1 << 20), "más pequeño: no se toca")
        XCTAssertEqual(files.diskSize, 1 << 30)
        XCTAssertLessThan(DiskMeasure.allocated(files.disk), 1 << 20, "disperso: no ocupa el gigabyte")
    }

    func testOptionsLeaveRoomForTheMac() {
        XCTAssertEqual(ComputerResources.cpuOptions(cores: 8), [1, 2, 4, 6])
        XCTAssertEqual(ComputerResources.cpuOptions(cores: 2), [1])
        XCTAssertEqual(ComputerResources.memoryOptions(physical: 16 << 30), [2, 4, 6, 8])
        XCTAssertEqual(ComputerResources.diskOptions(current: 16), [16, 32, 64, 128, 256])
        XCTAssertEqual(ComputerResources.diskOptions(current: 40), [40, 64, 128, 256], "nunca por debajo del actual")
    }
}
