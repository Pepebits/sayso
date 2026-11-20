import Foundation
@testable import SaySoPermissions
import XCTest

/// El borrado total usa `rm -rf`: estas pruebas fijan qué rutas puede tocar y cuáles no.
final class CleanupTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/ana")

    func testLeftoversAreOnlyThisAppsFoldersInTheUserLibrary() throws {
        let plan = CleanupPlan(bundleID: "com.pepebits.sayso", home: home, pid: 42, appPath: "/Applications/SaySo.app")
        try plan.validate()
        XCTAssertEqual(plan.leftovers.map(\.path), [
            "/Users/ana/Library/Application Support/SaySo",
            "/Users/ana/Library/Preferences/com.pepebits.sayso.plist",
            "/Users/ana/Library/Caches/com.pepebits.sayso",
            "/Users/ana/Library/Saved Application State/com.pepebits.sayso.savedState",
            "/Users/ana/Library/HTTPStorages/com.pepebits.sayso",
            "/Users/ana/Library/WebKit/com.pepebits.sayso",
        ])
        XCTAssertEqual(Array(plan.arguments[2...5]), ["sayso-cleanup", "42", "com.pepebits.sayso", "/Applications/SaySo.app"])
        XCTAssertEqual(Array(plan.arguments[6...]), plan.leftovers.map(\.path))
    }

    func testRefusesSuspiciousIdentifiersHomesAndAppPaths() {
        XCTAssertThrowsError(try CleanupPlan(bundleID: "sayso", home: home, pid: 1).validate())
        XCTAssertThrowsError(try CleanupPlan(bundleID: "com.pepebits/../..", home: home, pid: 1).validate())
        XCTAssertThrowsError(try CleanupPlan(bundleID: "com.pepebits.say so", home: home, pid: 1).validate())
        XCTAssertThrowsError(try CleanupPlan(bundleID: "com.pepebits.sayso", home: URL(fileURLWithPath: "/"), pid: 1).validate())
        XCTAssertThrowsError(try CleanupPlan(bundleID: "com.pepebits.sayso", home: home, pid: 1, appPath: "/").validate())
        XCTAssertThrowsError(try CleanupPlan(bundleID: "com.pepebits.sayso", home: home, pid: 1, appPath: "relativa/SaySo.app").validate())
        XCTAssertThrowsError(try CleanupPlan(bundleID: "com.pepebits.sayso", home: home, pid: 1, appPath: "/Applications").validate())
        XCTAssertNoThrow(try CleanupPlan(bundleID: "com.pepebits.sayso", home: home, pid: 1, appPath: nil).validate())
    }

    func testScriptWaitsResetsPermissionsBeforeRemovingTheAppAndUsesTheTrash() {
        let script = CleanupPlan.script
        let wait = script.range(of: "while kill -0")!.lowerBound
        let reset = script.range(of: "tccutil reset All")!.lowerBound
        let remove = script.range(of: "rm -rf --")!.lowerBound
        let trash = script.range(of: ".Trash/")!.lowerBound
        // macOS solo deja quitar los permisos de una app que sigue en el disco.
        XCTAssertTrue(wait < reset && reset < remove && remove < trash)
        // Las rutas llegan como argumentos entre comillas, nunca pegadas al texto del guion.
        XCTAssertFalse(script.contains("/Users/"))
        XCTAssertTrue(script.contains("\"$path\""))
        // La app no se borra: se mueve a la Papelera.
        XCTAssertFalse(script.contains("rm -rf -- \"$app\""))
    }

    /// El guion, de verdad, contra una carpeta de usuario falsa en el directorio temporal.
    func testScriptRunsAgainstAFakeHome() throws {
        let fake = FileManager.default.temporaryDirectory.appendingPathComponent("sayso-limpieza-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: fake) }
        let plan = CleanupPlan(bundleID: "com.pepebits.sayso.prueba-\(UUID().uuidString.prefix(8).lowercased())",
                               home: fake, pid: 0, appPath: nil)
        try plan.validate()
        for url in plan.leftovers {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        let keep = fake.appendingPathComponent("Library/Application Support/OtraApp/datos.txt")
        try FileManager.default.createDirectory(at: keep.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("no tocar".utf8).write(to: keep)

        // Un pid que no existe: no hay nada que esperar.
        var arguments = plan.arguments
        arguments[3] = "999999"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()

        for url in plan.leftovers { XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), url.path) }
        XCTAssertEqual(try String(contentsOf: keep, encoding: .utf8), "no tocar")
    }

    func testPermissionResetReopensTheApp() {
        let arguments = PermissionReset.arguments(pid: 7, bundleID: "com.pepebits.sayso", appPath: "/Applications/SaySo.app")
        XCTAssertEqual(Array(arguments[2...]), ["sayso-reset", "7", "com.pepebits.sayso", "/Applications/SaySo.app"])
        XCTAssertTrue(PermissionReset.script.contains("tccutil reset All \"$bundle\""))
        XCTAssertTrue(PermissionReset.script.contains("open \"$app\""))
        XCTAssertThrowsError(try PermissionReset.launch(appPath: "/tmp/no-es-una-app"))
    }
}
