import SaySoCore
import AppKit
import Virtualization

/// Ventana con la pantalla de la máquina Linux. El teclado y el ratón del Mac pasan a
/// la máquina mientras la ventana tiene el foco.
@MainActor
final class DesktopWindow: NSObject, NSWindowDelegate {
    /// Se llama cuando la ventana se cierra, por el usuario o por la app.
    var onClose: (() -> Void)?
    private var window: NSWindow?
    private var view: VZVirtualMachineView?

    func show(_ machine: VZVirtualMachine?) {
        if window == nil {
            let view = VZVirtualMachineView()
            view.capturesSystemKeys = true
            // Resolución fija de 1280×800, ampliada a la ventana. Si la pantalla del invitado siguiera
            // a la ventana, en un Mac Retina trabajaría a 2560×1600 y todo saldría diminuto.
            view.automaticallyReconfiguresDisplay = false
            view.setAccessibilityLabel(tr("Pantalla de la máquina Linux del agente"))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = tr("SaySo · Escritorio de Linux")
            window.isReleasedWhenClosed = false
            window.contentMinSize = NSSize(width: 640, height: 400)
            window.contentView = view
            window.delegate = self
            window.center()
            self.window = window
            self.view = view
        }
        view?.virtualMachine = machine
        window?.makeKeyAndOrderFront(nil)
        if let view { window?.makeFirstResponder(view) }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Cambia la máquina mostrada sin abrir la ventana (tras un reinicio o un apagado).
    func bind(_ machine: VZVirtualMachine?) {
        guard let view, view.virtualMachine !== machine else { return }
        view.virtualMachine = machine
    }

    func close() {
        guard window?.isVisible == true else { return }
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        view?.virtualMachine = nil
        onClose?()
    }

    var isVisible: Bool { window?.isVisible ?? false }
    var contentView: NSView? { view }
}
