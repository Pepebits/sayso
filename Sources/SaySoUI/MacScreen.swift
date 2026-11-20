import SaySoCore
import SwiftUI

/// Pantalla Mac: la lista cerrada de acciones que el agente puede pedir fuera de su Linux.
struct MacScreen: View {
    let model: AppModel

    private struct ScriptItem: Identifiable {
        var script: MacScript
        var id: String { script.rawValue }
    }

    private var summaryTag: String {
        let free = MacScript.allCases.filter { model.rule(for: $0.descriptor) == .allow }.count
        return tr("%@ acciones · %@ sin preguntar", "\(MacScript.allCases.count)", "\(free)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            ScreenHeader(icon: "laptopcomputer", title: "Mac",
                         subtitle: "Lo único que el agente puede hacer fuera de su Linux: una lista cerrada de acciones.",
                         tag: summaryTag)

            Panel(padding: Theme.Space.m) {
                HStack(alignment: .center, spacing: Theme.Space.m) {
                    IconTile("lock.shield", size: 26)
                    Text(tr("El agente no ejecuta código propio en tu Mac. Solo puede pedir estas acciones, y tú decides cada una."))
                        .font(Theme.bodyStrong)
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityElement(children: .combine)
            }

            VStack(alignment: .leading, spacing: Theme.Space.s) {
                SectionBar("Acciones del Mac")
                TileGrid(MacScript.allCases.map(ScriptItem.init), columns: 3, minTileWidth: 226) { scriptTile($0.script) }
                Text(tr("La lista es cerrada: añadir un script exige una nueva versión de SaySo."))
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }

            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack {
                    SectionLabel("Registro de actividad")
                    Spacer()
                    BlockButton("Vaciar", kind: .destructive, compact: true) {
                        model.actions?.clearActivity(scope: "mac")
                    }
                    .disabled(model.macActivity.isEmpty)
                    .accessibilityLabel("Vaciar el registro del Mac")
                }
                ActivityList(model: model, scope: "mac", entries: model.macActivity,
                             emptyDetail: "Aquí verás cada script que el agente ejecute en tu Mac.")
            }
        }
    }

    private func scriptTile(_ script: MacScript) -> some View {
        let rule = model.rule(for: script.descriptor)
        return Panel(padding: Theme.Space.m, fill: true) {
            HStack(alignment: .top) {
                IconTile(script.icon, size: 28)
                Spacer(minLength: 4)
                MonoTag(text: lastUse(script))
            }
            Text(tr(script.title))
                .font(Theme.bodyStrong)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            RuleSegmented(script.title,
                          rule: Binding(get: { rule }, set: { model.actions?.setRule($0, for: script.action) }))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(tr(script.title))
    }

    private func lastUse(_ script: MacScript) -> String {
        guard let date = model.macLastUse[script] else { return tr("Nunca usado") }
        return RelativeDate.string(date)
    }
}
