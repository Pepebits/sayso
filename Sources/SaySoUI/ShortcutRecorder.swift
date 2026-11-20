import AppKit
import SaySoCore
import SwiftUI

/// El atajo del dictado dibujado como teclas, con un botón para cambiarlo pulsando el nuevo.
struct ShortcutRecorder: View {
    let model: AppModel
    let shortcut: DictationShortcut
    let onChange: (DictationShortcut) -> Void

    @State private var recording = false
    @State private var problem: String?
    @State private var capture = ShortcutCapture()
    @State private var monitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.m) {
                HStack(spacing: 4) {
                    ForEach(Array(shortcut.keys.enumerated()), id: \.offset) { _, key in
                        KeyCap(symbol: key, size: 34)
                    }
                }
                .opacity(recording ? 0.35 : 1)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(tr("Atajo: %@", shortcut.symbol))
                VStack(alignment: .leading, spacing: 2) {
                    Text(recording ? tr("Pulsa la tecla o la combinación…") : tr("Mantén para hablar"))
                        .font(Theme.bodyStrong).foregroundStyle(Theme.ink)
                    Text(recording ? tr("Una modificadora sola (fn, ⌘ derecha…) o una combinación como ⌃⌥Espacio. Esc cancela.")
                         : tr("Pulsa dos veces para manos libres."))
                        .font(Theme.caption)
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: Theme.Space.s) {
                if recording {
                    BlockButton("Cancelar", compact: true) { finish(nil) }
                } else {
                    BlockButton("Cambiar atajo", systemImage: "keyboard", compact: true) { begin() }
                    if shortcut != .option {
                        BlockButton("Volver a ⌥", compact: true) { onChange(.option) }
                    }
                }
            }
            if let problem {
                Text(tr(problem))
                    .font(Theme.caption)
                    .foregroundStyle(Theme.destructive)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onDisappear { if recording { finish(nil) } }
    }

    private func begin() {
        problem = nil
        capture = ShortcutCapture()
        recording = true
        // Mientras se graba, el atajo de ahora no puede ponerse a escuchar.
        model.actions?.setShortcutRecording(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            let flags = UInt64(event.modifierFlags.rawValue)
            let result: ShortcutCapture.Result?
            if event.type == .keyDown {
                result = capture.keyDown(keyCode: event.keyCode, flags: flags,
                                         characters: event.charactersIgnoringModifiers)
            } else {
                result = capture.flagsChanged(keyCode: event.keyCode, flags: flags)
            }
            switch result {
            case let .done(new): finish(new)
            case .cancelled: finish(nil)
            case let .rejected(reason): problem = reason
            case nil: break
            }
            // La pulsación es para grabar el atajo: no llega a la ventana.
            return nil
        }
    }

    private func finish(_ new: DictationShortcut?) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        if new != nil { problem = nil }
        model.actions?.setShortcutRecording(false)
        if let new, new != shortcut { onChange(new) }
    }
}
