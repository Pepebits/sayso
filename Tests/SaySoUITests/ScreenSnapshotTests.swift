import AppKit
import SaySoCore
@testable import SaySoUI
import SwiftUI
import XCTest

/// Ayuda de desarrollo: con SAYSO_SCREENSHOTS=<carpeta> dibuja cada pantalla de ajustes con datos
/// de ejemplo, en claro y en oscuro, sin abrir la app. Sin la variable no hace nada.
@MainActor
final class ScreenSnapshotTests: XCTestCase {
    func testRenderEveryScreen() throws {
        guard let folder = ProcessInfo.processInfo.environment["SAYSO_SCREENSHOTS"] else {
            throw XCTSkip("Solo se ejecuta con SAYSO_SCREENSHOTS=<carpeta>")
        }
        let width = ProcessInfo.processInfo.environment["SAYSO_SCREENSHOTS_WIDTH"].flatMap(Double.init) ?? 1040
        let url = URL(fileURLWithPath: folder)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        _ = NSApplication.shared
        // SAYSO_SCREENSHOTS_LANG=<código> dibuja con ese idioma. Solo cambian los textos que pasan por
        // `tr()`; los que traduce SwiftUI por su cuenta necesitan el bundle de la app.
        if let code = ProcessInfo.processInfo.environment["SAYSO_SCREENSHOTS_LANG"] {
            let previous = L10n.bundle
            L10n.bundle = Bundle(path: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources").path) ?? previous
            L10n.forcedLanguage = code
            addTeardownBlock { L10n.forcedLanguage = nil; L10n.bundle = previous }
        }
        for (suffix, appearance) in [("", NSAppearance.Name.aqua), ("-oscuro", .darkAqua)] {
            // Cada pantalla, y una más con una búsqueda escrita para ver la lista de resultados.
            let shots = SettingsScreen.allCases.map { ($0.rawValue, $0, "") } + [("busqueda", SettingsScreen.ajustes, "to")]
            for (name, screen, query) in shots {
                let size = NSSize(width: width, height: 1500)
                let view = NSHostingView(rootView: SettingsRootView(model: PreviewData.fullModel(), initialScreen: screen,
                                                                    query: query)
                    .frame(width: size.width, height: size.height))
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                                      backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: appearance)
                window.contentView = view
                view.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                try rep.representation(using: .png, properties: [:])?
                    .write(to: url.appendingPathComponent("\(name)\(suffix).png"))
                window.close()
            }
        }
    }

    /// La hoja de editar una tarea, con la de muestra que va a dos destinatarios.
    func testRenderEditTaskSheet() throws {
        guard let folder = ProcessInfo.processInfo.environment["SAYSO_SCREENSHOTS"] else {
            throw XCTSkip("Solo se ejecuta con SAYSO_SCREENSHOTS=<carpeta>")
        }
        _ = NSApplication.shared
        let model = PreviewData.fullModel()
        model.telegramUser = .ready("Demo")
        let task = try XCTUnwrap(model.tasks.first { !$0.recipients.isEmpty })
        let view = NSHostingView(rootView: EditTaskSheet(model: model, task: task))
        view.layoutSubtreeIfNeeded()
        let size = view.fittingSize
        view.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: folder).appendingPathComponent("tarea-editar.png"))
        window.close()
    }
}
