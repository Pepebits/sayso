import AppKit
import SaySoCore
import SwiftUI

/// Lista del registro de actividad de un ámbito. Enseña las más recientes y carga más al pedirlo.
struct ActivityList: View {
    let model: AppModel
    let scope: String
    let entries: [ActivityEntry]
    let emptyDetail: String

    private var total: Int { max(model.activityTotals[scope] ?? entries.count, entries.count) }

    var body: some View {
        SettingsCard {
            if entries.isEmpty {
                EmptyState(systemImage: "list.bullet.rectangle", title: "Sin actividad", detail: emptyDetail)
            } else {
                // Perezosa: solo se crean las filas que caben en pantalla.
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                        if index > 0 { CardDivider() }
                        row(entry)
                    }
                }
                if total > entries.count {
                    CardDivider()
                    HStack(spacing: Theme.Space.m) {
                        Text(tr("Se muestran %@ de %@", entries.count.formatted(), total.formatted()))
                            .font(Theme.caption)
                            .foregroundStyle(Theme.secondary)
                        Spacer(minLength: Theme.Space.s)
                        BlockButton("Mostrar más", compact: true) { model.actions?.showMoreActivity(scope: scope) }
                            .accessibilityLabel("Mostrar más entradas antiguas")
                    }
                    .padding(.horizontal, Theme.Space.l)
                    .padding(.vertical, Theme.Space.s + 2)
                }
            }
        }
    }

    private func row(_ entry: ActivityEntry) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.summary)
                    .font(Theme.body)
                    .foregroundStyle(Theme.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text(RelativeDate.string(entry.date))
                    Text(verbatim: "·")
                    Text(entry.action.rawValue).font(Theme.mono(11))
                    if let origin = entry.origin, !origin.isEmpty {
                        Text(verbatim: "·")
                        Text(origin).lineLimit(1).truncationMode(.tail)
                    }
                }
                .font(Theme.caption)
                .foregroundStyle(Theme.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            StatusTag(entry.outcome.title, kind: entry.outcome == .allowed ? .neutral : .error)
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.m)
        .accessibilityElement(children: .combine)
    }
}

/// Pantalla Telegram: bot, emparejamiento, reglas y registro.
struct TelegramScreen: View {
    enum Tab: Hashable { case permissions, activity }

    let model: AppModel
    @State private var tab: Tab = .permissions
    @State private var token = ""

    /// Bot emparejado y cuenta con sesión: los dos caben como paneles gemelos.
    private var compactConnection: Bool {
        model.telegramStatus.isLinked && model.pairingCode == nil && model.telegramUser.isReady
    }

    private var channelTag: String {
        let bot = model.telegramStatus.isLinked
        switch (bot, model.telegramUser.isReady) {
        case (true, true): return tr("bot + cuenta")
        case (true, false): return tr("bot")
        case (false, true): return tr("cuenta · falta el bot")
        case (false, false): return tr("Sin conectar")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            ScreenHeader(icon: "paperplane", title: "Telegram",
                         subtitle: "Habla con el agente desde tu bot y decide qué puede hacer en tus chats.",
                         tag: channelTag)

            if compactConnection {
                HStack(alignment: .top, spacing: Theme.Space.m) {
                    botPanel
                    TelegramUserSection(model: model, asPanel: true)
                }
                .fixedSize(horizontal: false, vertical: true)
            } else {
                if model.telegramStatus.isLinked {
                    connectedCard
                } else {
                    setupCard
                }
                TelegramUserSection(model: model)
            }

            BlockSegmented("Sección de Telegram", selection: $tab,
                           options: [(Tab.permissions, "Permisos"), (.activity, "Registro de actividad")])
                .frame(maxWidth: 360)
                .frame(maxWidth: .infinity, alignment: .center)

            switch tab {
            case .permissions: permissions
            case .activity: activity
            }
        }
    }

    private var botPanel: some View {
        Panel(fill: true) {
            HStack(alignment: .top) {
                PanelLabel("Tu bot")
                Spacer(minLength: 4)
                if case .connecting = model.telegramStatus {
                    StatusTag("Conectando", kind: .connecting)
                } else {
                    StatusTag("Conectado", kind: .active)
                }
            }
            HStack(spacing: Theme.Space.m) {
                IconTile("paperplane", size: 36)
                Text(verbatim: botName)
                    .font(Theme.mono(15, weight: .bold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Text(tr("Emparejado contigo. Es el canal por el que hablas con el agente y por el que te pide confirmación."))
                .font(Theme.caption)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            CardDivider()
            HStack {
                MonoTag(text: tr("canal de conversación"))
                Spacer(minLength: 0)
                BlockButton("Desconectar", kind: .destructive, compact: true) { model.actions?.disconnectTelegram() }
                    .accessibilityLabel(tr("Desconectar el bot"))
            }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: Conexión

    private var setupCard: some View {
        SettingsSection("Conectar tu bot") {
            SettingsCard {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    if case let .failed(message) = model.telegramStatus {
                        HStack(spacing: Theme.Space.s) {
                            StatusTag("Error", kind: .error)
                            Text(tr(message))
                                .font(Theme.caption)
                                .foregroundStyle(Theme.ink)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    step(1, "Abre @BotFather en Telegram y envía /newbot.")
                    step(2, "Elige un nombre y un usuario que acabe en «bot».")
                    step(3, "Copia el token que te da y pégalo aquí.")
                    HStack(spacing: Theme.Space.s) {
                        BlockField("123456789:AA…", text: $token, secure: true, mono: true, label: "Token del bot")
                            .onSubmit(connect)
                        BlockButton("Conectar", kind: .primary, action: connect)
                            .disabled(trimmedToken.isEmpty)
                    }
                    Text(tr("El token se guarda en el Llavero de este Mac."))
                        .font(Theme.caption)
                        .foregroundStyle(Theme.secondary)
                }
                .padding(Theme.Space.l)
            }
        }
    }

    private var trimmedToken: String { token.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func connect() {
        guard !trimmedToken.isEmpty else { return }
        model.actions?.connectTelegram(botToken: trimmedToken)
        token = ""
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            StepBadge(number: number)
            Text(tr(text))
                .font(Theme.body)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tr("Paso %@: %@", "\(number)", tr(text)))
    }

    private var connectedCard: some View {
        SettingsSection("Bot") {
            SettingsCard {
                HStack(spacing: Theme.Space.m) {
                    IconTile("paperplane")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(botName)
                            .font(Theme.mono(13, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Text(tr(model.pairingCode == nil ? "Emparejado contigo" : "Falta emparejar"))
                            .font(Theme.caption)
                            .foregroundStyle(Theme.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if case .connecting = model.telegramStatus {
                        StatusTag("Conectando", kind: .connecting)
                    } else {
                        StatusTag("Conectado", kind: .active)
                    }
                    BlockButton("Desconectar", kind: .destructive, compact: true) {
                        model.actions?.disconnectTelegram()
                    }
                }
                .padding(.horizontal, Theme.Space.l)
                .padding(.vertical, Theme.Space.m)

                if let code = model.pairingCode {
                    CardDivider()
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        Text(tr("Envía este código a tu bot para emparejarlo contigo. Solo funciona una vez."))
                            .font(Theme.body)
                            .foregroundStyle(Theme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: Theme.Space.s) {
                            Text(code)
                                .font(Theme.mono(20, weight: .bold))
                                .tracking(2)
                                .foregroundStyle(Theme.ink)
                                .textSelection(.enabled)
                                .padding(.horizontal, Theme.Space.m)
                                .padding(.vertical, 6)
                                .background(Theme.paper)
                                .overlay(RoundedRectangle(cornerRadius: Theme.radius)
                                    .strokeBorder(Theme.border, lineWidth: 1))
                                .accessibilityLabel(tr("Código de emparejamiento %@", code))
                            BlockButton("Copiar", systemImage: "doc.on.doc", compact: true) {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(code, forType: .string)
                            }
                            .accessibilityLabel("Copiar código")
                        }
                    }
                    .padding(Theme.Space.l)
                }
            }
        }
    }

    private var botName: String {
        if case let .connected(name) = model.telegramStatus { return name }
        return "Conectando…"
    }

    // MARK: Permisos

    private struct ActionItem: Identifiable {
        var descriptor: ActionDescriptor
        var id: String { descriptor.id.rawValue }
    }

    private func actionIcon(_ id: ActionID) -> String {
        switch id {
        case TelegramAction.listChats: return "list.bullet"
        case TelegramAction.readMessages: return "eye"
        case TelegramAction.sendMessages: return "paperplane"
        case TelegramAction.deleteMessages: return "trash"
        case TelegramAction.guestReply: return "at"
        case "telegram.sendFile": return "paperclip"
        case "telegram.sendWidget": return "rectangle.on.rectangle"
        case TelegramAction.forward: return "arrowshape.turn.up.right"
        case TelegramAction.edit: return "pencil"
        case TelegramAction.react: return "face.smiling"
        case TelegramAction.markRead: return "checkmark.circle"
        case TelegramAction.download: return "arrow.down.circle"
        case TelegramAction.pin: return "pin"
        case TelegramAction.organize: return "archivebox"
        case TelegramAction.contacts: return "person.crop.circle.badge.plus"
        case TelegramAction.groups: return "person.3"
        case TelegramAction.vote: return "chart.bar"
        case TelegramAction.savedMessages: return "bookmark"
        default: return "gearshape"
        }
    }

    private func actionDetail(_ descriptor: ActionDescriptor) -> String {
        if let detail = ruleDetail(descriptor) { return detail }
        switch descriptor.id {
        case TelegramAction.listChats: return "Ver qué conversaciones tienes."
        case TelegramAction.readMessages: return "Leer y buscar en un chat."
        case TelegramAction.sendMessages: return "Escribir desde tu cuenta."
        case TelegramAction.deleteMessages: return "Borrar mensajes de un chat."
        default: return ""
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                SectionBar("Interruptores generales")
                SettingsCard {
                    HStack(alignment: .top, spacing: 0) {
                        generalSwitch("Permitir acciones en Telegram",
                                      "Si lo apagas, el agente no hará nada en Telegram salvo responderte.",
                                      warn: false,
                                      isOn: Binding(get: { model.telegramEnabled },
                                                    set: { model.actions?.setTelegramEnabled($0) }))
                        Rectangle().fill(Theme.border).frame(width: 1)
                        generalSwitch("Acceso total",
                                      "Lo que está en Preguntar se hará sin preguntar. Nunca sigue siendo Nunca.",
                                      warn: true,
                                      isOn: Binding(get: { model.telegramFullAccess },
                                                    set: { model.actions?.setTelegramFullAccess($0) }))
                            .disabled(!model.telegramEnabled)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    if model.telegramFullAccess && model.telegramEnabled {
                        CardDivider()
                        InlineNote("Con acceso total, un mensaje o una página con instrucciones ocultas podría hacer que el agente actúe sin tu confirmación.",
                                   systemImage: "exclamationmark.triangle", emphasis: true)
                            .padding(.horizontal, Theme.Space.l)
                            .padding(.vertical, Theme.Space.m)
                    }
                }
            }

            VStack(alignment: .leading, spacing: Theme.Space.s) {
                SectionBar("Acciones en tus chats")
                TileGrid(TelegramAction.descriptors.map(ActionItem.init), columns: 2, minTileWidth: 250) { item in
                    actionTile(item.descriptor)
                }
                .disabled(!model.telegramEnabled)
                Text(tr("Se aplican a lo que el agente hace en tus chats cuando has iniciado sesión con tu cuenta. Responderte por el bot no pasa por estas reglas."))
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }

            InlineNote("Los chats secretos y los códigos de acceso nunca están disponibles.", systemImage: "lock")
                .padding(.horizontal, 2)
        }
    }

    private func generalSwitch(_ title: String, _ detail: String, warn: Bool, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .center, spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: Theme.Space.s) {
                    Text(tr(title)).font(Theme.bodyStrong).foregroundStyle(Theme.ink)
                    if warn { StatusTag("Cuidado", kind: .pending) }
                }
                Text(tr(detail))
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            BlockToggle(isOn: isOn, label: title)
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func actionTile(_ descriptor: ActionDescriptor) -> some View {
        Panel(padding: Theme.Space.m, fill: true) {
            HStack(alignment: .top, spacing: Theme.Space.s + 2) {
                IconTile(actionIcon(descriptor.id), size: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr(descriptor.title)).font(Theme.bodyStrong).foregroundStyle(Theme.ink)
                    Text(tr(actionDetail(descriptor)))
                        .font(Theme.caption)
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            BlockSegmented(tr("Regla para %@", tr(descriptor.title)),
                           selection: Binding(get: { model.rule(for: descriptor) },
                                              set: { model.actions?.setRule($0, for: descriptor.id) }),
                           options: PermissionRule.allCases.map { ($0, $0.title) })
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(tr(descriptor.title))
    }

    private func ruleDetail(_ descriptor: ActionDescriptor) -> String? {
        if model.telegramFullAccess && model.rule(for: descriptor) == .ask {
            return "Se permite sin preguntar por el acceso total."
        }
        return descriptor.detail.isEmpty ? nil : descriptor.detail
    }

    // MARK: Registro

    private var activity: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack {
                SectionLabel("Registro de actividad")
                Spacer()
                BlockButton("Vaciar", kind: .destructive, compact: true) {
                    model.actions?.clearActivity(scope: "telegram")
                }
                .disabled(model.telegramActivity.isEmpty)
                .accessibilityLabel("Vaciar el registro de Telegram")
            }
            ActivityList(model: model, scope: "telegram", entries: model.telegramActivity,
                         emptyDetail: "Aquí verás cada acción del agente en Telegram y si se permitió.")
        }
    }
}
