import SaySoCore
import SwiftUI

/// Pantalla Modelo: la cuenta de IA en uso, las demás y las plantillas para añadir otra.
struct ModelScreen: View {
    let model: AppModel
    /// Plantilla con la que se abre la hoja; `nil` si está cerrada.
    @State private var adding: ProviderPreset?
    @State private var removing: UUID?

    private var accountsTag: String {
        switch model.accounts.count {
        case 0: return tr("Sin cuentas")
        case 1: return tr("1 cuenta")
        default: return tr("%@ cuentas", "\(model.accounts.count)")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            ScreenHeader(icon: "square.stack.3d.up", title: "Modelo",
                         subtitle: "La cuenta de IA con la que piensa el agente. Las claves se quedan en el Llavero.",
                         tag: accountsTag) {
                BlockButton("Añadir cuenta", systemImage: "plus", kind: .primary) { adding = ProviderPreset.all[0] }
            }

            if let active = model.activeAccount {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    SectionBar("Cuenta activa", note: model.autoSpeed ? tr("Elige el modelo sola") : tr("Siempre el completo"))
                    activePanel(active)
                }
            }

            VStack(alignment: .leading, spacing: Theme.Space.s) {
                SectionBar("Cuentas", note: model.accounts.isEmpty ? nil : accountsTag)
                if model.accounts.isEmpty {
                    SettingsCard {
                        EmptyState(systemImage: "square.stack.3d.up",
                                   title: "Sin cuentas de IA",
                                   detail: "Añade Claude, OpenAI, OpenRouter, Grok o un modelo local con Ollama o LM Studio.")
                    }
                } else {
                    TileGrid(model.accounts, columns: 3, minTileWidth: 180) { accountCard($0) }
                }
            }

            VStack(alignment: .leading, spacing: Theme.Space.s) {
                SectionBar("Plantillas", note: tr("Rellenan la dirección y los modelos"))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: Theme.Space.s)],
                          alignment: .leading, spacing: Theme.Space.s) {
                    ForEach(ProviderPreset.all) { preset in
                        Button { adding = preset } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "plus").font(.system(size: 10, weight: .bold)).accessibilityHidden(true)
                                Text(verbatim: preset.name)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(BlockButtonStyle(.secondary))
                        .accessibilityLabel(tr("Añadir cuenta de %@", preset.name))
                    }
                }
                InlineNote("Las claves de API se guardan en el Llavero de este Mac, nunca en los ajustes.", systemImage: "lock")
                    .padding(.horizontal, 2)
                    .padding(.top, 2)
            }
        }
        .sheet(item: $adding) { preset in
            AddAccountSheet(initial: preset) { account, key in
                model.actions?.addAccount(account, apiKey: key)
            }
        }
    }

    // MARK: Cuenta activa

    private func host(_ account: ProviderAccount) -> String {
        account.baseURL.host ?? account.baseURL.absoluteString
    }

    private func activePanel(_ active: ProviderAccount) -> some View {
        SettingsCard {
            HStack(alignment: .center, spacing: Theme.Space.l) {
                HStack(spacing: Theme.Space.m) {
                    IconTile(active.keychainKey == nil ? "desktopcomputer" : "bolt", size: 34)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: Theme.Space.s) {
                            Text(verbatim: active.name)
                                .font(Theme.display(18))
                                .tracking(-0.3)
                                .foregroundStyle(Theme.ink)
                                .lineLimit(1)
                            AccountCheckTag(check: model.accountChecks[active.id])
                        }
                        Text(verbatim: host(active))
                            .font(Theme.mono(11.5))
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(spacing: Theme.Space.s) {
                    modelLine("Completo", active.fullModel, "tareas con herramientas")
                    modelLine("Rápido", active.fastModel, "voz y mensajes cortos")
                }
                .frame(maxWidth: .infinity)
            }
            .padding(Theme.Space.l)
            if case let .failed(message) = model.accountChecks[active.id] {
                CardDivider()
                InlineNote(tr("No responde: %@", message), systemImage: "exclamationmark.triangle")
                    .padding(Theme.Space.m)
            }
            CardDivider()
            SettingRow(title: "Probar la cuenta",
                       detail: "Una petición mínima comprueba la clave, la dirección y el modelo rápido. Se hace sola al añadir la cuenta.") {
                BlockButton("Probar", systemImage: "checkmark.circle", compact: true) {
                    model.actions?.testAccount(id: active.id)
                }
                .disabled(model.accountChecks[active.id] == .checking)
            }
            CardDivider()
            SettingRow(title: "Velocidad automática",
                       detail: "Usa el modelo rápido para los mensajes cortos y el completo para los largos. La voz usa siempre el rápido.") {
                BlockToggle(isOn: Binding(get: { model.autoSpeed }, set: { model.actions?.setAutoSpeed($0) }),
                            label: "Velocidad automática")
            }
            CardDivider()
            SettingRow(title: "Ve imágenes",
                       detail: active.vision == nil
                           ? (active.defaultVision ? "Este proveedor ve imágenes: el agente puede mirar fotos de Telegram y de la máquina Linux."
                              : "No consta que este modelo vea imágenes. Actívalo si sabes que sí (por ejemplo, un modelo local con visión).")
                           : "Cambiado a mano. Si el modelo no las ve, el proveedor devolverá un error al mandarle una foto.") {
                BlockToggle(isOn: Binding(get: { active.seesImages },
                                          set: { model.actions?.setAccountVision(id: active.id, $0) }),
                            label: "Ve imágenes")
            }
        }
    }

    /// «COMPLETO  nombre-del-modelo — para qué se usa».
    private func modelLine(_ role: String, _ name: String, _ use: String) -> some View {
        HStack(spacing: Theme.Space.s) {
            Text(tr(role).uppercased())
                .font(Theme.mono(11, weight: .bold))
                .foregroundStyle(Theme.paper)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Theme.ink)
                .clipShape(RoundedRectangle(cornerRadius: Theme.innerRadius))
            Text(verbatim: name.isEmpty ? tr("Sin definir") : name)
                .font(Theme.mono(12, weight: .semibold))
                .foregroundStyle(name.isEmpty ? Theme.tertiary : Theme.ink)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .layoutPriority(1)
            Text(verbatim: "— " + tr(use))
                .font(Theme.caption)
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.s + 2)
        .frame(minHeight: 32)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.paper)
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
        .help(tr(use))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(tr("Modelo")) \(tr(role).lowercased()): \(name.isEmpty ? tr("Sin definir") : name). \(tr(use))"))
    }

    // MARK: Cuentas

    private func accountCard(_ account: ProviderAccount) -> some View {
        let isActive = account.id == model.activeAccountID
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.Space.s + 2) {
                HStack(alignment: .top) {
                    IconTile(account.keychainKey == nil ? "desktopcomputer" : "key", size: 28)
                    Spacer(minLength: 4)
                    if isActive { MonoTag(text: tr("En uso"), marked: true) }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: account.name).font(Theme.bodyStrong).foregroundStyle(Theme.ink).lineLimit(1)
                    Text(verbatim: host(account))
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(tr(account.keychainKey == nil ? "Modelo local, sin clave" : "Clave guardada"))
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondary)
            }
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            CardDivider()
            HStack(spacing: Theme.Space.s) {
                if !isActive {
                    BlockButton("Usar", compact: true) { model.actions?.selectAccount(id: account.id) }
                        .accessibilityLabel(tr("Usar %@", account.name))
                }
                Spacer(minLength: 0)
                BlockButton("Quitar", kind: .destructive, compact: true) { removing = account.id }
                    .accessibilityLabel(tr("Quitar %@", account.name))
                    .confirmRemoval(isPresented: Binding(get: { removing == account.id }, set: { if !$0 { removing = nil } }),
                                    title: tr("¿Quitar la cuenta «%@»?", account.name),
                                    message: tr("Su clave se borra del Llavero. Para volver a usarla tendrás que pegarla otra vez."),
                                    button: tr("Quitar")) { model.actions?.removeAccount(id: account.id) }
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, Theme.Space.s)
        }
        .background(Theme.surface)
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius)
            .strokeBorder(isActive ? Theme.ink : Theme.border, lineWidth: isActive ? 2 : 1))
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: isActive ? "\(account.name), \(tr("En uso"))" : account.name))
    }
}

/// Hoja «Añadir cuenta» a partir de las plantillas.
struct AddAccountSheet: View {
    let onAdd: (ProviderAccount, String?) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var preset: ProviderPreset
    @State private var name: String
    @State private var baseURL: String
    @State private var fullModel: String
    @State private var fastModel: String
    @State private var apiKey = ""
    /// Permiso explícito para enviar datos a un proveedor de fuera del Mac (lo exige la App Store y
    /// el usuario debe saberlo en cualquier caso).
    @State private var consented = false

    init(initial: ProviderPreset = ProviderPreset.all[0], onAdd: @escaping (ProviderAccount, String?) -> Void) {
        self.onAdd = onAdd
        _preset = State(initialValue: initial)
        _name = State(initialValue: initial.name)
        _baseURL = State(initialValue: initial.baseURL.absoluteString)
        _fullModel = State(initialValue: initial.fullModel)
        _fastModel = State(initialValue: initial.fastModel)
    }

    private var parsedURL: URL? {
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespaces)),
              let scheme = url.scheme, ["http", "https"].contains(scheme), url.host != nil else { return nil }
        return url
    }

    /// El modelo corre en este Mac o en la red local: los datos no salen a un tercero.
    static func isLocal(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        return ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host) || host.hasSuffix(".local")
    }

    private var needsConsent: Bool { parsedURL.map { !Self.isLocal($0) } ?? false }

    private var canAdd: Bool {
        (!needsConsent || consented)
            && parsedURL != nil
            && !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !fullModel.trimmingCharacters(in: .whitespaces).isEmpty
            && (!preset.needsKey || !apiKey.isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Text(tr("Añadir cuenta de IA"))
                .font(Theme.display(20))
                .tracking(-0.4)
                .foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)

            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text(tr("Plantilla")).font(Theme.text(12, weight: .semibold)).foregroundStyle(Theme.ink)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                    ForEach(ProviderPreset.all) { p in
                        Button { apply(p) } label: {
                            Text(p.name)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(BlockButtonStyle(p == preset ? .primary : .secondary))
                        .accessibilityAddTraits(p == preset ? [.isSelected] : [])
                    }
                }
            }

            LabeledField("Nombre", text: $name)
            LabeledField("URL base", placeholder: "https://…", text: $baseURL, mono: true,
                         hint: parsedURL == nil ? "Escribe una URL válida que empiece por http:// o https://." : nil)
            HStack(alignment: .top, spacing: Theme.Space.m) {
                LabeledField("Modelo completo", placeholder: "nombre-del-modelo", text: $fullModel, mono: true)
                LabeledField("Modelo rápido", placeholder: "opcional", text: $fastModel, mono: true)
            }
            LabeledField("Clave de API", placeholder: preset.needsKey ? "Pega la clave" : "No hace falta en local",
                         text: $apiKey, secure: true, mono: true,
                         hint: "Se guarda en el Llavero de este Mac.")

            if needsConsent, let host = parsedURL?.host {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Text(tr("Qué se envía a %@", host))
                        .font(Theme.text(12, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    Text(tr("Para responder, SaySo envía a este servicio lo que le pides y lo que el agente lee para hacerlo: tus mensajes, notas de memoria y, si se lo pides, mensajes de Telegram, el calendario, recordatorios o páginas web. Lo trata según sus condiciones. Pepebits no tiene servidores y no lo ve."))
                        .font(Theme.text(12))
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Toggle(tr("Acepto que SaySo envíe estos datos a %@", host), isOn: $consented)
                        .toggleStyle(.checkbox)
                        .font(Theme.text(12))
                }
                .padding(Theme.Space.m)
                .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.controlBorder, lineWidth: 1))
            }

            HStack {
                Spacer()
                Button("Cancelar") { dismiss() }
                    .buttonStyle(BlockButtonStyle(.secondary))
                    .keyboardShortcut(.cancelAction)
                Button("Añadir") { add() }
                    .buttonStyle(BlockButtonStyle(.primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAdd)
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 480)
        .background(Theme.paper)
        // Aceptar un servicio no vale para otro.
        .onChange(of: parsedURL?.host) { consented = false }
    }

    private func apply(_ p: ProviderPreset) {
        preset = p
        name = p.name
        baseURL = p.baseURL.absoluteString
        fullModel = p.fullModel
        fastModel = p.fastModel
    }

    private func add() {
        guard let url = parsedURL else { return }
        let id = UUID()
        let key = apiKey.isEmpty ? nil : apiKey
        let full = fullModel.trimmingCharacters(in: .whitespaces)
        let fast = fastModel.trimmingCharacters(in: .whitespaces)
        let account = ProviderAccount(
            id: id,
            name: name.trimmingCharacters(in: .whitespaces),
            kind: preset.kind,
            baseURL: url,
            fullModel: full,
            fastModel: fast.isEmpty ? full : fast,
            keychainKey: key == nil ? nil : KeychainName.providerKey(id)
        )
        onAdd(account, key)
        apiKey = ""
        dismiss()
    }
}

/// Estado de una cuenta de IA: «Activa» solo cuando ha respondido a la prueba.
struct AccountCheckTag: View {
    var check: AccountCheck?

    var body: some View {
        switch check {
        case .ok: StatusTag("Funciona", kind: .active)
        case .checking: StatusTag("Probando…", kind: .connecting)
        case .failed: StatusTag("No responde", kind: .error)
        case nil: StatusTag("Sin probar", kind: .neutral)
        }
    }
}
