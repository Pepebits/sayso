import SaySoCore
import AppKit
import SaySoUI
import SwiftUI

@main
struct SaySoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var controller = AppController()

    var body: some Scene {
        Window("SaySo", id: "settings") {
            SettingsRootView(model: controller.model)
                .task { controller.start() }
        }
        .windowResizability(.contentMinSize)

        MenuBarExtra("SaySo", systemImage: "quote.opening") {
            MenuContent(controller: controller)
                .id(controller.model.language)
                .appLanguage()
        }
    }
}

private struct MenuContent: View {
    let controller: AppController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Abrir SaySo") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "settings")
        }
        Button(tr(controller.model.agentRunning ? "Detener el agente" : "Reanudar el agente")) {
            controller.setAgentRunning(!controller.model.agentRunning)
        }
        Divider()
        Button("Salir de SaySo") { NSApp.terminate(nil) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        // Ayuda de desarrollo: SAYSO_APPEARANCE=dark|light fuerza el modo para las capturas.
        switch ProcessInfo.processInfo.environment["SAYSO_APPEARANCE"] {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark-hc": NSApp.appearance = NSAppearance(named: .accessibilityHighContrastDarkAqua)
        case "light-hc": NSApp.appearance = NSAppearance(named: .accessibilityHighContrastAqua)
        default: break
        }
        MainActor.assumeIsolated { hudSnapshotsIfRequested() }
        snapshotIfRequested()
    }

    /// Ayuda de desarrollo: SAYSO_HUD_SNAPSHOT=<carpeta> dibuja la píldora en sus fases y sale.
    @MainActor private func hudSnapshotsIfRequested() {
        guard let folder = ProcessInfo.processInfo.environment["SAYSO_HUD_SNAPSHOT"] else { return }
        let said = "recuérdame enviarle a anna la nueva compilación a las 5 y eh reservar una mesa para el viernes"
        let cases: [(String, DictationPhase, String)] = [
            ("1-escuchando", .agentListening(level: 0.6, handsFree: false), "recuérdame enviarle a anna la nueva"),
            ("2-pensando", .agentThinking(said), said),
            ("3-respuesta", .agentReply("El chat que aparece es un canal «lukin», no un tal Lucas. ¿Me pasas su alias o el nombre completo con el que aparece en Telegram?"), ""),
            ("5-respuesta-larga", .agentReply(String(repeating: "He revisado el grupo y hay tres temas abiertos que conviene que mires hoy mismo. ", count: 6)), ""),
            ("4-corrigiendo", .correcting, said),
        ]
        for (name, phase, transcript) in cases {
            // Igual que el panel real: la vista ocupa exactamente el tamaño medido.
            let size = DictationHUDView.fittingSize(phase: phase, transcript: transcript)
            let renderer = ImageRenderer(content: DictationHUDView(phase: phase, transcript: transcript)
                .frame(width: size.width, height: size.height))
            renderer.scale = 2
            guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { continue }
            try? png.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
        }
        exit(0)
    }

    /// Ayuda de desarrollo: con SAYSO_SNAPSHOT=<ruta.png> guarda una imagen de la ventana de ajustes.
    private func snapshotIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["SAYSO_SNAPSHOT"] else { return }
        let delay = ProcessInfo.processInfo.environment["SAYSO_SNAPSHOT_DELAY"].flatMap(Double.init) ?? 2.5
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard let view = NSApp.windows.first(where: { $0.contentView != nil && $0.isVisible })?.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }

    /// Apaga la máquina Linux con orden antes de salir, para no cortar escrituras en su disco.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let controller = AppController.shared else { return .terminateNow }
        Task { @MainActor in
            await controller.stopTelegramUserForQuit()
            if controller.computerNeedsShutdown { await controller.shutdownComputer() }
            controller.stopTDLib()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    // Cerrar la ventana no detiene el agente ni el dictado: siguen en la barra de menús.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
