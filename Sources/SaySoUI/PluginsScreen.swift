import SaySoCore
import SwiftUI

/// Pantalla Plugins: servicios en línea y complementos de la máquina Linux.
struct PluginsScreen: View {
    enum Filter: Hashable { case all, services, addons }

    let model: AppModel
    @State private var addingCustom = false
    @State private var removing: PluginRow?
    @State private var filter: Filter = .all

    private func rows(_ kind: PluginKind) -> [PluginRow] { model.plugins.filter { $0.config.kind == kind } }

    private var summaryTag: String {
        let active = model.plugins.filter { $0.added && $0.config.enabled }.count
        return tr("%@ activos / %@ disponibles", "\(active)", "\(model.plugins.count)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            ScreenHeader(icon: "puzzlepiece.extension", title: "Plugins",
                         subtitle: "Herramientas extra para el agente, con las mismas reglas de permisos.",
                         tag: summaryTag) {
                BlockButton("Añadir servidor", systemImage: "plus") { addingCustom = true }
            }

            BlockSegmented("Qué plugins se muestran", selection: $filter,
                           options: [(Filter.all, "Todos"), (.services, "Servicios"), (.addons, "Complementos")],
                           compact: true)

            if filter != .addons {
                section("Servicios", kind: .service,
                        note: "Servidores MCP en línea. Lo que el agente les envía sale de tu Mac, así que por defecto pregunta antes de cada uso.")
            }
            if filter != .services {
                section("Complementos", kind: .addon,
                        note: "Se instalan y se ejecutan dentro de la máquina Linux del agente, no en tu Mac.")
            }

            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack {
                    SectionLabel("Actividad")
                    Spacer()
                    BlockButton("Vaciar", kind: .destructive, compact: true) {
                        model.actions?.clearActivity(scope: "plugin")
                    }
                    .disabled(model.pluginActivity.isEmpty)
                    .accessibilityLabel("Vaciar la actividad de los plugins")
                }
                ActivityList(model: model, scope: "plugin", entries: model.pluginActivity,
                             emptyDetail: "Aquí verás cada llamada del agente a un plugin.")
            }

            InlineNote("Los servicios que solo admiten iniciar sesión en el navegador (OAuth), como Notion, aún no se pueden conectar. El puente con Xcode tampoco está todavía.",
                       systemImage: "clock")
                .padding(.horizontal, 2)
        }
        .sheet(isPresented: $addingCustom) {
            CustomPluginSheet(existing: Set(model.plugins.map(\.id))) { model.actions?.addPlugin($0) }
        }
        .confirmationDialog(tr("¿Quitar %@?", removing.map { tr($0.config.name) } ?? tr("el plugin")),
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Quitar", role: .destructive) {
                if let removing { model.actions?.removePlugin(id: removing.id) }
                removing = nil
            }
            Button("Cancelar", role: .cancel) { removing = nil }
        } message: {
            Text(tr("El agente dejará de ver sus herramientas. Puedes volver a añadirlo cuando quieras."))
        }
    }

    private func section(_ title: String, kind: PluginKind, note: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionLabel(title)
            Text(tr(note))
                .font(Theme.caption)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 2)
            TileGrid(rows(kind), columns: 2, minTileWidth: 344) { pluginCard($0) }
        }
    }

    /// Tarjeta de plugin: qué es arriba, y abajo la regla de uso con su interruptor, o el botón
    /// para añadirlo.
    private func pluginCard(_ row: PluginRow) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.Space.s + 2) {
                HStack(alignment: .top) {
                    IconTile(row.config.icon, size: 28)
                    Spacer(minLength: 4)
                    if row.added { StatusTag(statusTitle(row), kind: statusKind(row)) }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr(row.config.name)).font(Theme.bodyStrong).foregroundStyle(Theme.ink)
                    Text(tr(row.config.detail))
                        .font(Theme.caption)
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                infoLine(row)
            }
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            CardDivider()
            HStack(spacing: Theme.Space.s) {
                if row.added {
                    RuleSegmented(tr(row.config.name), rule: Binding(
                        get: { model.rule(for: row.config.descriptor) },
                        set: { model.actions?.setRule($0, for: row.config.action) }))
                    Spacer(minLength: 0)
                    BlockButton("Quitar", kind: .destructive, compact: true) { removing = row }
                        .disabled(isBusy(row))
                        .accessibilityLabel(tr("Quitar %@", tr(row.config.name)))
                    BlockToggle(isOn: Binding(get: { row.config.enabled },
                                              set: { model.actions?.setPluginEnabled($0, id: row.id) }),
                                label: tr("Usar %@", tr(row.config.name)))
                        .disabled(isBusy(row))
                } else {
                    Button { model.actions?.addPlugin(row.config) } label: {
                        Text(tr(row.config.kind == .service ? "Conectar" : "Instalar")).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(BlockButtonStyle(.primary, compact: true))
                    .accessibilityLabel(Text(verbatim: "\(row.config.kind == .service ? tr("Conectar") : tr("Instalar")) \(tr(row.config.name))"))
                }
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, Theme.Space.s)
        }
        .background(Theme.surface)
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(tr(row.config.name))
    }

    /// Lo que más importa saber del plugin ahora: el error, sus herramientas o la clave que pide.
    @ViewBuilder
    private func infoLine(_ row: PluginRow) -> some View {
        if row.added, case let .failed(message) = row.state {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .accessibilityHidden(true)
                    Text(tr(message))
                        .font(Theme.caption)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .foregroundStyle(Theme.destructive)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(tr("Error: %@", tr(message)))
                BlockButton("Reintentar", systemImage: "arrow.clockwise", compact: true) {
                    model.actions?.reconnectPlugin(id: row.id)
                }
                .accessibilityLabel(tr("Reintentar la conexión de %@", tr(row.config.name)))
            }
        } else if row.added, case let .ready(tools) = row.state, !tools.isEmpty, row.config.builtin == nil {
            Text(verbatim: toolsLine(tools))
                .font(Theme.mono(11))
                .foregroundStyle(Theme.secondary)
                .lineLimit(2)
        }
    }

    private func isBusy(_ row: PluginRow) -> Bool {
        row.state == .installing || row.state == .connecting
    }

    private func toolsLine(_ tools: [String]) -> String {
        let shown = tools.prefix(4).joined(separator: ", ")
        let count = tools.count == 1 ? tr("1 herramienta") : tr("%@ herramientas", "\(tools.count)")
        return "\(count): \(shown)\(tools.count > 4 ? "…" : "")"
    }

    private func statusTitle(_ row: PluginRow) -> String {
        if !row.config.enabled { return "En pausa" }
        switch row.state {
        case .idle: return row.config.kind == .addon ? "En reposo" : "Sin conectar"
        case .installing: return "Instalando"
        case .connecting: return "Conectando"
        case .ready: return "Listo"
        case .failed: return "Error"
        }
    }

    private func statusKind(_ row: PluginRow) -> StatusTag.Kind {
        if !row.config.enabled { return .neutral }
        switch row.state {
        case .idle: return .neutral
        case .installing, .connecting: return .connecting
        case .ready: return .active
        case .failed: return .error
        }
    }
}

/// Hoja para añadir un servidor MCP propio.
struct CustomPluginSheet: View {
    var existing: Set<String>
    var onAdd: (PluginConfig) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var kind: PluginKind = .service
    @State private var name = ""
    @State private var url = ""
    @State private var secret = ""
    @State private var install = ""
    @State private var command = ""

    private var id: String { PluginConfig.slug(name) }
    private var parsedURL: URL? {
        guard let value = URL(string: url.trimmingCharacters(in: .whitespaces)), value.scheme == "https",
              value.host != nil else { return nil }
        return value
    }
    private var secretName: String? {
        let value = secret.trimmingCharacters(in: .whitespaces).uppercased()
        return value.isEmpty ? nil : value
    }
    private var problem: String? {
        if id.isEmpty { return nil }
        if existing.contains(id) { return "Ya hay un plugin con ese nombre." }
        if kind == .service, !url.isEmpty, parsedURL == nil { return "La dirección tiene que empezar por https://." }
        return nil
    }
    private var canAdd: Bool {
        guard !id.isEmpty, problem == nil else { return false }
        return kind == .service ? parsedURL != nil : !command.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Text(tr("Añadir servidor MCP"))
                .font(Theme.display(20))
                .tracking(-0.4)
                .foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)

            BlockSegmented("Tipo de plugin", selection: $kind,
                           options: [(.service, "Servicio en línea"), (.addon, "Complemento en Linux")])
            LabeledField("Nombre", placeholder: "Mi servidor", text: $name)
            if kind == .service {
                LabeledField("Dirección", placeholder: "https://ejemplo.com/mcp", text: $url, mono: true)
                LabeledField("Secreto con la credencial (opcional)", placeholder: "MI_TOKEN", text: $secret, mono: true,
                             hint: "Nombre de un secreto de la pantalla Secretos. Se envía como «Authorization: Bearer».")
            } else {
                LabeledField("Instalación (opcional)", placeholder: "pipx install mi-servidor", text: $install, mono: true,
                             hint: "Comando de bash que se ejecuta una vez en la máquina Linux.")
                LabeledField("Comando", placeholder: "$HOME/.local/bin/mi-servidor", text: $command, mono: true,
                             hint: "Arranca el servidor MCP por la entrada y salida estándar.")
            }
            if let problem {
                Text(tr(problem)).font(Theme.caption).foregroundStyle(Theme.destructive)
            }
            InlineNote("Añade solo servidores en los que confíes: lo que devuelven llega al agente.",
                       systemImage: "exclamationmark.triangle")

            HStack {
                Spacer()
                Button("Cancelar") { dismiss() }
                    .buttonStyle(BlockButtonStyle(.secondary))
                    .keyboardShortcut(.cancelAction)
                Button("Añadir") {
                    let trimmedInstall = install.trimmingCharacters(in: .whitespacesAndNewlines)
                    onAdd(PluginConfig(
                        id: id, name: name.trimmingCharacters(in: .whitespaces),
                        detail: kind == .service ? (parsedURL?.host ?? "") : command.trimmingCharacters(in: .whitespaces),
                        kind: kind, icon: kind == .service ? "cloud" : "shippingbox",
                        url: kind == .service ? parsedURL : nil, secretName: kind == .service ? secretName : nil,
                        install: kind == .addon && !trimmedInstall.isEmpty ? trimmedInstall : nil,
                        command: kind == .addon ? command.trimmingCharacters(in: .whitespacesAndNewlines) : nil))
                    dismiss()
                }
                .buttonStyle(BlockButtonStyle(.primary))
                .keyboardShortcut(.defaultAction)
                .disabled(!canAdd)
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 460)
        .background(Theme.paper)
    }
}
