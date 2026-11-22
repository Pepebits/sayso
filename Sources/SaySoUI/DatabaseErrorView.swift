import SaySoCore
import SwiftUI

/// Lo que enseña la ventana cuando la base de datos no se abre al arrancar: sin ella no funciona
/// nada, así que en vez de pantallas vacías se dice qué pasa y qué se puede hacer.
struct DatabaseErrorView: View {
    let model: AppModel
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack(spacing: Theme.Space.m) {
                IconTile("externaldrive.badge.exclamationmark", size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("SaySo no puede abrir sus datos"))
                        .font(Theme.display(22))
                        .foregroundStyle(Theme.ink)
                        .accessibilityAddTraits(.isHeader)
                    Text(tr("Sin ellos no funciona: ni el agente, ni las tareas, ni los ajustes."))
                        .font(Theme.caption)
                        .foregroundStyle(Theme.secondary)
                }
            }
            Text(verbatim: message)
                .font(Theme.mono(12))
                .foregroundStyle(Theme.ink)
                .textSelection(.enabled)
                .padding(Theme.Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface)
                .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.border, lineWidth: 1))
            InlineNote("Suele pasar si el disco está lleno o la carpeta de datos no tiene permisos. Libera espacio o revisa la carpeta y reintenta. No se ha borrado nada.",
                       systemImage: "info.circle")
            HStack(spacing: Theme.Space.s) {
                BlockButton("Reintentar", systemImage: "arrow.clockwise", kind: .primary) { model.actions?.relaunch() }
                BlockButton("Mostrar carpeta", systemImage: "folder") { model.actions?.revealDataFolder() }
                BlockButton("Crear informe", systemImage: "doc.text") { model.actions?.createDiagnostics() }
            }
        }
        .padding(Theme.Space.xl)
        .frame(maxWidth: 620)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
