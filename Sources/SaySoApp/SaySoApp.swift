import SaySoCore
import AppKit
import SaySoUI
import SwiftUI

@main
struct SaySoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private var controller: AppController { delegate.controller }

    var body: some Scene {
        Window("SaySo", id: "settings") {
            SettingsRootView(model: controller.model)
                .task { controller.start() }
        }
        .windowResizability(.contentMinSize)
        // Al abrirse con la sesión, SaySo se queda en la barra de menús sin abrir la ventana.
        .defaultLaunchBehavior(AppDelegate.launchedAtLogin ? .suppressed : .automatic)
        .commands { NavigationCommands(model: controller.model) }

        MenuBarExtra {
            MenuContent(controller: controller)
                .id(controller.model.language)
                .appLanguage()
        } label: {
            Image(systemName: MenuStatus(model: controller.model).symbol)
                .accessibilityLabel(MenuStatus(model: controller.model).summary)
        }
    }
}

/// Estado de SaySo para la barra de menús: un icono por estado y una línea que lo explica.
@MainActor
struct MenuStatus {
    let model: AppModel

    var symbol: String {
        switch model.dictationPhase {
        case .listening, .agentListening: return "waveform"
        case .transcribing, .correcting, .agentThinking: return "ellipsis.bubble"
        case .failed: return "exclamationmark.bubble"
        default: break
        }
        if model.databaseError != nil { return "exclamationmark.triangle" }
        if !model.agentRunning { return "pause.circle" }
        return "quote.opening"
    }

    var summary: String {
        if model.databaseError != nil { return tr("SaySo no puede abrir sus datos") }
        switch model.dictationPhase {
        case .listening, .agentListening: return tr("Te escucha")
        case .transcribing, .correcting: return tr("Transcribiendo…")
        case .agentThinking: return tr("El agente está en ello…")
        default: break
        }
        if !model.agentRunning { return tr("Agente detenido") }
        if model.conversing { return tr("Conversación en marcha") }
        if !model.missingDictationPermissions.isEmpty { return tr("Faltan permisos para el atajo") }
        return tr("Listo: mantén %@ para hablar", model.dictation.shortcut.symbol)
    }
}

/// Menú «Ir»: ⌘1…⌘9 abren las nueve primeras pantallas, y ⇧⌘N empieza una conversación nueva.
private struct NavigationCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu(tr("Ir")) {
            ForEach(Array(SettingsScreen.allCases.prefix(9).enumerated()), id: \.element) { index, screen in
                Button(tr(screen.title)) { show(screen) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
            Divider()
            Button(tr("Nueva conversación")) { model.actions?.newConversation(chatID: "voz") }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }
    }

    private func show(_ screen: SettingsScreen) {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "settings")
        model.requestedScreen = screen
    }
}

private struct MenuContent: View {
    let controller: AppController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let model = controller.model
        Text(verbatim: MenuStatus(model: model).summary)
        Divider()
        Button("Abrir SaySo") { open(nil) }
        if model.agentRunning, model.activeAccount != nil {
            Button(tr(model.conversing ? "Terminar la conversación" : "Conversar con el agente")) {
                controller.toggleConversation()
            }
            Button(tr("Nueva conversación")) { controller.newConversation(chatID: "voz") }
        }
        Button(tr(model.agentRunning ? "Detener el agente" : "Reanudar el agente")) {
            controller.setAgentRunning(!model.agentRunning)
        }
        if !model.missingDictationPermissions.isEmpty {
            Button(tr("Revisar permisos…")) { open(.dictado) }
        }
        if case .ready = controller.model.updates {
            Button("Buscar actualizaciones…") { controller.checkForUpdates() }
        }
        Divider()
        Button("Salir de SaySo") { NSApp.terminate(nil) }
    }

    private func open(_ screen: SettingsScreen?) {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "settings")
        if let screen { controller.model.requestedScreen = screen }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// El controlador vive aquí y no en la ventana: arranca aunque la ventana no se abra (al
    /// iniciar sesión). Antes todo arrancaba con la ventana.
    @MainActor lazy var controller = AppController()

    /// macOS ha abierto SaySo como ítem de inicio de sesión.
    @MainActor static var launchedAtLogin = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        let event = NSAppleEventManager.shared().currentAppleEvent
        Self.launchedAtLogin = event?.eventID == AEEventID(kAEOpenApplication)
            && event?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        controller.start()
        if Self.launchedAtLogin {
            // Por si la escena ya había abierto la ventana antes de saberlo.
            DispatchQueue.main.async {
                for window in NSApp.windows where window.identifier?.rawValue.hasPrefix("settings") == true { window.close() }
            }
        }
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
