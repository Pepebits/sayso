import AVFoundation
import AppKit
import IOKit.pwr_mgt
import SaySoCore
import SaySoUI
import ServiceManagement
import SwiftUI

/// Panel flotante de la píldora de dictado. No roba el foco a la app de destino.
@MainActor
final class DictationHUD {
    private var panel: NSPanel?
    private let state = DictationHUDState()

    /// El atajo que se dibuja en la píldora.
    var keySymbol: String {
        get { state.keySymbol }
        set { state.keySymbol = newValue }
    }

    /// Qué hace el agente mientras piensa; se borra al cambiar de fase.
    var step: String? {
        get { state.step }
        set { state.step = newValue }
    }

    /// Descarga o carga del modelo de voz; `nil` cuando está listo.
    var modelStatus: String? {
        get { state.modelStatus }
        set { state.modelStatus = newValue }
    }

    /// Lo que enseña ahora, con el nivel del micrófono.
    var phase: DictationPhase { state.phase }

    func show(_ phase: DictationPhase, transcript: String = "") {
        if case .idle = phase { return hide() }
        if case .agentThinking = phase {} else { state.step = nil }
        if phase.withoutLevel != state.phase.withoutLevel { announce(phase) }
        state.phase = phase
        state.transcript = transcript
        let panel = self.panel ?? makePanel()
        self.panel = panel
        // Solo se coloca al aparecer, en la pantalla donde está el puntero; mientras está a la
        // vista no se mueve ni cambia de tamaño.
        if !panel.isVisible {
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
            if let frame = screen?.visibleFrame {
                panel.setFrameOrigin(NSPoint(x: frame.midX - DictationHUDStage.size.width / 2, y: frame.minY + 48))
            }
            panel.orderFrontRegardless()
        }
    }

    /// VoiceOver no lee la píldora por sí solo (el panel no toma el foco): cada fase nueva se anuncia.
    private func announce(_ phase: DictationPhase) {
        let text = DictationHUDView.accessibilityText(phase: phase, step: state.step, modelStatus: state.modelStatus)
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    func hide() {
        panel?.orderOut(nil)
        state.phase = .idle
        state.transcript = ""
        state.step = nil
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: DictationHUDStage.size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let host = NSHostingView(rootView: DictationHUDStage(state: state).appLanguage())
        host.frame = NSRect(origin: .zero, size: DictationHUDStage.size)
        panel.contentView = host
        return panel
    }
}

/// Voz del agente: lee sus respuestas con la síntesis de macOS, sin red.
@MainActor
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var speaking = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Vuelve cuando termina (o se corta) lo que se esté leyendo; enseguida si no se lee nada.
    func waitUntilFinished() async {
        guard speaking else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func finished() {
        speaking = false
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finished() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finished() }
    }

    func speak(_ text: String, language: String?) {
        stop()
        speaking = true
        let utterance = AVSpeechUtterance(string: text)
        // La voz sigue el idioma del dictado; sin él, el de la app.
        let code = language ?? L10n.speechCode
        utterance.voice = AVSpeechSynthesisVoice(language: code)
        synthesizer.speak(utterance)
    }

    func stop() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        if speaking { finished() }
    }
}

/// Diálogo «Preguntar» del motor de permisos. Siempre en el Mac.
/// Pregunta un permiso por otra vía (el bot) a la vez que la ventana del Mac.
protocol RemoteConfirming: Sendable {
    /// `nil`: no se pudo preguntar, caducó o se contestó en el Mac.
    func ask(id: String, request: ActionRequest, descriptor: ActionDescriptor?) async -> ConfirmationResult?
    /// La pregunta se contestó en el Mac.
    func withdraw(id: String, allowed: Bool) async
}

final class ConfirmationWindowPresenter: ConfirmationPresenter, @unchecked Sendable {
    /// Tras este tiempo sin respuesta, la pregunta se da por denegada.
    static let timeout: TimeInterval = 600
    private let lock = NSLock()
    private var _remote: RemoteConfirming?
    /// Si está puesto, la pregunta sale también por el bot y vale la primera respuesta.
    var remote: RemoteConfirming? {
        get { lock.withLock { _remote } }
        set { lock.withLock { _remote = newValue } }
    }

    func confirm(_ request: ActionRequest, descriptor: ActionDescriptor?) async -> ConfirmationResult {
        let remote = self.remote
        let id = UUID().uuidString.prefix(8).lowercased()
        return await withCheckedContinuation { continuation in
            Task { @MainActor in
                var window: NSWindow?
                var answered = false
                let finish: (ConfirmationResult, Bool) -> Void = { result, fromMac in
                    guard !answered else { return }
                    answered = true
                    window?.orderOut(nil)
                    window = nil
                    continuation.resume(returning: result)
                    if fromMac, let remote {
                        Task { await remote.withdraw(id: String(id), allowed: result != .deny) }
                    }
                }
                let view = ConfirmationView(request: request, descriptor: descriptor, onResult: { finish($0, true) })
                let host = NSHostingController(rootView: view.appLanguage())
                let win = NSWindow(contentViewController: host)
                win.title = tr("SaySo necesita tu permiso")
                win.styleMask = [.titled]
                win.level = .modalPanel
                win.isReleasedWhenClosed = false
                win.center()
                window = win
                NSApp.activate(ignoringOtherApps: true)
                win.makeKeyAndOrderFront(nil)
                if let remote {
                    Task {
                        if let result = await remote.ask(id: String(id), request: request, descriptor: descriptor) {
                            await MainActor.run { finish(result, false) }
                        }
                    }
                }
                // Sin respuesta en un rato, se deniega: si no, el chat del bot o las tareas se quedan
                // esperando para siempre detrás de esta pregunta.
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(Self.timeout * 1_000_000_000))
                    finish(.deny, false)
                }
            }
        }
    }
}

/// «Mantener el Mac activo»: evita el reposo del sistema; la pantalla puede apagarse.
@MainActor
final class KeepAwake {
    private var assertion: IOPMAssertionID = 0
    private var active = false

    func set(_ enabled: Bool) {
        guard enabled != active else { return }
        if enabled {
            let ok = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                                 IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 "SaySo mantiene el Mac activo para el agente" as CFString,
                                                 &assertion)
            active = ok == kIOReturnSuccess
        } else {
            IOPMAssertionRelease(assertion)
            active = false
        }
    }
}

/// «Abrir al iniciar sesión». Solo funciona desde el paquete .app firmado.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}
