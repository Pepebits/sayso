import AppKit
import SaySoCore
import SwiftUI

/// Guía de permisos del dictado: los tres, en orden, con lo que hay que hacer en cada uno y su
/// estado al momento. macOS no deja que una app se conceda permisos: solo puede pedirlos y llevar
/// al usuario al sitio.
struct PermissionGuideSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    private static let order: [SystemPermissionKind] = [.microphone, .inputMonitoring]

    private func granted(_ kind: SystemPermissionKind) -> Bool { model.systemPermissions[kind] == true }
    private var current: SystemPermissionKind? { Self.order.first { !granted($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(tr("Permisos del dictado"))
                        .font(Theme.display(20))
                        .foregroundStyle(Theme.ink)
                        .accessibilityAddTraits(.isHeader)
                    Text(tr("SaySo necesita dos permisos de macOS: oírte y ver el atajo del dictado."))
                        .font(Theme.caption)
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Theme.Space.m)
                BlockButton("Cerrar") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            VStack(spacing: Theme.Space.s) {
                ForEach(Array(Self.order.enumerated()), id: \.element) { index, kind in
                    step(index + 1, kind)
                }
            }

            if current == nil {
                Panel {
                    HStack(spacing: Theme.Space.m) {
                        StateLine(text: "Todo concedido", on: true)
                        Spacer(minLength: Theme.Space.s)
                        Text(tr("Mantén ⌥ y habla para probarlo."))
                            .font(Theme.caption)
                            .foregroundStyle(Theme.secondary)
                    }
                }
            } else {
                Panel {
                    HStack(alignment: .center, spacing: Theme.Space.m) {
                        Text(tr("macOS aplica Accesibilidad y Supervisión de entrada al arrancar la app. Si ya los has activado en Ajustes del Sistema y siguen como pendientes, reinicia SaySo."))
                            .font(Theme.caption)
                            .foregroundStyle(Theme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        BlockButton("Reiniciar SaySo", systemImage: "arrow.clockwise", compact: true) {
                            model.actions?.relaunch()
                        }
                    }
                }
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 620)
        .background(Theme.paper)
        .appLanguage()
    }

    private func step(_ number: Int, _ kind: SystemPermissionKind) -> some View {
        let done = granted(kind)
        let active = kind == current
        return VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(alignment: .center, spacing: Theme.Space.m) {
                StepBadge(number: number)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr(kind.title)).font(Theme.bodyStrong).foregroundStyle(Theme.ink)
                    Text(tr(kind.detail))
                        .font(Theme.caption)
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if done { StateLine(text: "Concedido", on: true) } else { StatusTag("Pendiente", kind: .pending) }
            }
            if active { instructions(kind) }
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface)
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius)
            .strokeBorder(active ? Theme.ink : Theme.border, lineWidth: active ? 2 : 1))
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: "\(tr("Paso %@ de %@", "\(number)", "\(Self.order.count)")): \(tr(kind.title)), \(tr(done ? "Concedido" : "Pendiente"))"))
    }

    @ViewBuilder
    private func instructions(_ kind: SystemPermissionKind) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if kind == .microphone {
                line("Pulsa «Pedir permiso» y acepta el aviso de macOS.")
                BlockButton("Pedir permiso", kind: .primary, compact: true) { model.actions?.requestSystemPermission(kind) }
            } else {
                line("1. Pulsa «Abrir Ajustes del Sistema».")
                line("2. Enciende SaySo en la lista. macOS te pedirá la contraseña.")
                line("3. Si SaySo no aparece, pulsa + y elígela. «Mostrar SaySo en Finder» te la enseña para arrastrarla a la lista.")
                if kind == .inputMonitoring {
                    line("En algunas versiones de macOS este panel se llama «Control de dispositivos y acceso a datos».")
                }
                HStack(spacing: Theme.Space.s) {
                    BlockButton("Abrir Ajustes del Sistema", kind: .primary, compact: true) {
                        model.actions?.requestSystemPermission(kind)
                    }
                    BlockButton("Mostrar SaySo en Finder", systemImage: "folder", compact: true) { model.actions?.revealApp() }
                }
            }
        }
        .padding(.leading, 18 + Theme.Space.m)
    }

    private func line(_ text: String) -> some View {
        Text(tr(text))
            .font(Theme.caption)
            .foregroundStyle(Theme.ink)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Confirmación del borrado total: qué se va, una casilla de «lo entiendo» y el botón.
struct EraseSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var understood = false
    @State private var removeApp = true

    private static let items: [(String, String)] = [
        ("paperplane", "La sesión de tu cuenta de Telegram, que también se cierra en Telegram, y el token del bot."),
        ("terminal", "La máquina Linux del agente con todo lo que haya dentro."),
        ("cylinder", "La base de datos: memoria, tareas, reglas, actividad, estadísticas y conversaciones."),
        ("waveform", "Los modelos de voz descargados y el registro de la app."),
        ("key", "Todas las claves y secretos guardados en el Llavero."),
        ("lock", "Los permisos de macOS y el arranque al iniciar sesión."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            VStack(alignment: .leading, spacing: 3) {
                Text(tr("Borrar SaySo de este Mac"))
                    .font(Theme.display(20))
                    .foregroundStyle(Theme.ink)
                    .accessibilityAddTraits(.isHeader)
                Text(tr("Se borra todo lo que SaySo ha guardado en este Mac. No se puede deshacer."))
                    .font(Theme.body)
                    .foregroundStyle(Theme.destructive)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SettingsCard {
                ForEach(Array(Self.items.enumerated()), id: \.offset) { index, item in
                    if index > 0 { CardDivider() }
                    HStack(alignment: .center, spacing: Theme.Space.m) {
                        IconTile(item.0, size: 22)
                        Text(tr(item.1))
                            .font(Theme.caption)
                            .foregroundStyle(Theme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, Theme.Space.m)
                    .padding(.vertical, Theme.Space.s)
                }
            }

            VStack(alignment: .leading, spacing: Theme.Space.s) {
                check("Mover también la app a la Papelera", isOn: $removeApp)
                check("Entiendo que no se puede deshacer", isOn: $understood)
            }

            HStack {
                BlockButton("Cancelar") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                BlockButton("Borrar todo y salir", kind: .destructive) {
                    model.actions?.eraseEverything(removeApp: removeApp)
                }
                .disabled(!understood)
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 560)
        .background(Theme.paper)
        .appLanguage()
    }

    private func check(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: Theme.Space.m) {
            BlockToggle(isOn: isOn, label: title)
            Text(tr(title)).font(Theme.body).foregroundStyle(Theme.ink)
        }
    }
}
