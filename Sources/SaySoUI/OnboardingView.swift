import SaySoCore
import SwiftUI

/// Pasos de la guía de inicio. Todos se pueden saltar: nada es obligatorio para abrir la app.
enum OnboardingStep: Int, CaseIterable, Identifiable {
    case welcome, permissions, account, telegram, computer, done

    var id: Int { rawValue }

    /// Pasos que se cuentan en «Paso N de M» (sin la bienvenida ni el resumen).
    static let counted: [OnboardingStep] = [.permissions, .account, .telegram, .computer]

    var title: String {
        switch self {
        case .welcome: return "Bienvenido a SaySo"
        case .permissions: return "Permisos de macOS"
        case .account: return "Cuenta de IA"
        case .telegram: return "Telegram"
        case .computer: return "El ordenador del agente"
        case .done: return "Todo listo"
        }
    }

    var subtitle: String {
        switch self {
        case .welcome: return "Dictado en cualquier app y un agente que trabaja por ti desde Telegram."
        case .permissions: return "Para hablarle al agente, SaySo necesita oírte y detectar la tecla ⌥."
        case .account: return "El agente piensa con el modelo que tú elijas. La clave se guarda en el Llavero."
        case .telegram: return "Un bot propio para hablar con el agente y, si quieres, tu cuenta para que pueda leer tus chats."
        case .computer: return "Una máquina Linux aislada de tu Mac donde el agente ejecuta código y navega."
        case .done: return "Puedes cambiar cualquier cosa después desde la barra lateral."
        }
    }

    /// Permisos que pide el dictado con el motor elegido.
    @MainActor static func neededPermissions(_ model: AppModel) -> [SystemPermissionKind] {
        SystemPermissionKind.needed(engine: model.dictation.engine)
    }

    /// Hay algo hecho en el paso, aunque no esté completo: el botón dice «Continuar», no «Ahora no».
    /// En Telegram basta con la cuenta conectada; que falte el bot lo recuerda el resumen.
    @MainActor func hasProgress(_ model: AppModel) -> Bool {
        if isComplete(model) { return true }
        return self == .telegram && (model.telegramUser.isReady || model.telegramStatus.isLinked)
    }

    /// El paso ya está resuelto con lo que hay configurado.
    @MainActor func isComplete(_ model: AppModel) -> Bool {
        switch self {
        case .welcome, .done: return true
        case .permissions: return Self.neededPermissions(model).allSatisfy { model.systemPermissions[$0] == true }
        case .account: return model.activeAccount != nil
        case .telegram:
            if case .connected = model.telegramStatus { return model.pairingCode == nil }
            return false
        case .computer: return model.computerState != .notInstalled && !model.computerState.isBusy
        }
    }
}

/// Guía de inicio: ocupa la ventana entera la primera vez y se puede repetir desde Inicio.
struct OnboardingView: View {
    let model: AppModel
    @State private var step: OnboardingStep
    @State private var addingAccount = false
    @State private var token = ""
    @AccessibilityFocusState private var titleFocused: Bool

    init(model: AppModel, initialStep: OnboardingStep = .welcome) {
        self.model = model
        _step = State(initialValue: initialStep)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.xl) {
                    header
                    content
                }
                .frame(maxWidth: 620, alignment: .leading)
                .padding(.horizontal, Theme.Space.xxl)
                .padding(.vertical, Theme.Space.xxl)
                .frame(maxWidth: .infinity)
            }
            Rectangle().fill(Theme.border).frame(height: 1)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.paper)
        .sheet(isPresented: $addingAccount) {
            AddAccountSheet { account, key in model.actions?.addAccount(account, apiKey: key) }
        }
        .onChange(of: step) { titleFocused = true }
    }

    // MARK: Cabecera y pie

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            if step == .welcome {
                AppIconView(size: 64)
            } else if let index = OnboardingStep.counted.firstIndex(of: step) {
                HStack(spacing: Theme.Space.s) {
                    HStack(spacing: 4) {
                        ForEach(OnboardingStep.counted) { item in
                            Rectangle()
                                .fill(item.rawValue <= step.rawValue ? Theme.ink : Theme.controlBorder.opacity(0.45))
                                .frame(width: 28, height: 6)
                        }
                    }
                    .accessibilityHidden(true)
                    Text(tr("Paso %@ de %@", "\(index + 1)", "\(OnboardingStep.counted.count)"))
                        .font(Theme.sectionLabel)
                        .tracking(0.8)
                        .foregroundStyle(Theme.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: headline)
                    .font(Theme.display(30))
                    .tracking(-0.9)
                    .foregroundStyle(Theme.ink)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($titleFocused)
                Text(tr(step.subtitle))
                    .font(Theme.text(14))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// El resumen no dice «todo listo» si quedan pasos sin hacer.
    private var headline: String {
        guard step == .done else { return tr(step.title) }
        let pending = OnboardingStep.counted.filter { !$0.isComplete(model) }.count
        switch pending {
        case 0: return tr(step.title)
        case 1: return tr("Queda un paso pendiente")
        default: return tr("Quedan %@ pasos pendientes", "\(pending)")
        }
    }

    private var footer: some View {
        HStack(spacing: Theme.Space.s) {
            if step != .welcome {
                BlockButton("Atrás", systemImage: "chevron.left") { move(-1) }
            }
            Spacer()
            switch step {
            case .welcome:
                BlockButton("Saltar la guía") { model.actions?.finishOnboarding() }
                BlockButton("Empezar", kind: .primary) { move(1) }
                    .keyboardShortcut(.defaultAction)
            case .done:
                BlockButton("Abrir SaySo", kind: .primary) { model.actions?.finishOnboarding() }
                    .keyboardShortcut(.defaultAction)
            default:
                // El botón dice la verdad: sin nada hecho en el paso, continuar es dejarlo para luego.
                BlockButton(step.hasProgress(model) ? "Continuar" : "Ahora no",
                            kind: step.hasProgress(model) ? .primary : .secondary) { move(1) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, Theme.Space.xxl)
        .padding(.vertical, Theme.Space.l)
        .background(Theme.surface)
    }

    private func move(_ delta: Int) {
        if let next = OnboardingStep(rawValue: step.rawValue + delta) { step = next }
    }

    // MARK: Pasos

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome: welcome
        case .permissions: permissions
        case .account: account
        case .telegram: telegram
        case .computer: computer
        case .done: summary
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            SettingsCard {
                SettingRow(icon: "mic", title: "Háblale desde cualquier app",
                           detail: "Mantén la tecla ⌥, pídele algo y suelta. Lo hace y te responde.")
                CardDivider()
                SettingRow(icon: "paperplane", title: "Pídele cosas por Telegram",
                           detail: "Recordatorios, resúmenes, código, tareas a su hora. Te responde en tu bot.")
                CardDivider()
                SettingRow(icon: "terminal", title: "Trabaja en su propio ordenador",
                           detail: "Una máquina Linux separada de tus archivos. Lo que toca tu Mac pasa por reglas que tú decides.")
            }
            InlineNote("La guía tiene cuatro pasos y puedes saltarte cualquiera. Las claves se guardan en el Llavero de este Mac.",
                       systemImage: "lock")
                .padding(.horizontal, 2)
        }
    }

    private var permissions: some View {
        SettingsSection("Para el dictado",
                        footer: "macOS abre Ajustes del Sistema para algunos permisos. Si SaySo no los detecta al volver, ciérralo y ábrelo de nuevo.") {
            SettingsCard {
                let kinds = OnboardingStep.neededPermissions(model)
                ForEach(Array(kinds.enumerated()), id: \.element) { index, kind in
                    if index > 0 { CardDivider() }
                    SettingRow(icon: kind.icon, title: kind.title, detail: kind.detail) {
                        if model.systemPermissions[kind] == true {
                            StatusTag("Concedido", kind: .active)
                        } else {
                            BlockButton("Conceder", kind: .primary, compact: true) {
                                model.actions?.requestSystemPermission(kind)
                            }
                            .accessibilityLabel(tr("Conceder %@", tr(kind.title)))
                        }
                    }
                }
            }
        }
    }

    private var account: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            SettingsCard {
                if let active = model.activeAccount {
                    SettingRow(icon: "square.stack.3d.up", title: active.name,
                               detail: active.fullModel.isEmpty ? active.kind.title : active.fullModel) {
                        StatusTag("Lista", kind: .active)
                    }
                } else {
                    SettingRow(icon: "square.stack.3d.up", title: "Añade una cuenta",
                               detail: "Claude, OpenAI, OpenRouter, Grok, o un modelo local con Ollama o LM Studio.") {
                        BlockButton("Añadir cuenta", systemImage: "plus", kind: .primary) { addingAccount = true }
                    }
                }
            }
            InlineNote("Sin cuenta, el dictado funciona igual; solo faltan el agente y «Corregir con IA».",
                       systemImage: "info.circle")
                .padding(.horizontal, 2)
        }
    }

    private var telegram: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            SettingsSection("Tu bot",
                            footer: "Es por donde hablas con el agente, también desde el móvil. Sin bot no puede recibir tus mensajes.") {
                telegramBot
            }
            // La misma sección que la pantalla Telegram: iniciar sesión aquí o allí es lo mismo.
            TelegramUserSection(model: model)
        }
    }

    @ViewBuilder
    private var telegramBot: some View {
        if model.telegramStatus.isLinked {
            SettingsCard {
                SettingRow(icon: "paperplane", title: telegramTitle, detail: telegramDetail) {
                    StatusTag(model.pairingCode == nil && isConnected ? "Emparejado" : "Conectado",
                              kind: isConnected ? .active : .connecting)
                }
                if let code = model.pairingCode {
                    CardDivider()
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        Text(tr("Abre tu bot en Telegram y envíale este código"))
                            .font(Theme.bodyStrong)
                            .foregroundStyle(Theme.ink)
                        Text(code)
                            .font(Theme.mono(26, weight: .bold))
                            .tracking(4)
                            .foregroundStyle(Theme.ink)
                            .textSelection(.enabled)
                            .accessibilityLabel(tr("Código de emparejamiento %@", code.map(String.init).joined(separator: " ")))
                        Text(tr("Así el bot sabrá que eres tú y no atenderá a nadie más."))
                            .font(Theme.caption)
                            .foregroundStyle(Theme.secondary)
                    }
                    .padding(Theme.Space.l)
                }
            }
        } else {
            SettingsCard {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    if case let .failed(message) = model.telegramStatus {
                        Text(tr(message)).font(Theme.caption).foregroundStyle(Theme.destructive)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    numbered(1, "Abre @BotFather en Telegram y envía /newbot.")
                    numbered(2, "Elige un nombre y un usuario que acabe en «bot».")
                    numbered(3, "Copia el token que te da y pégalo aquí.")
                    HStack(spacing: Theme.Space.s) {
                        BlockField("123456789:AA…", text: $token, secure: true, mono: true, label: "Token del bot")
                            .onSubmit(connectBot)
                        BlockButton("Conectar", kind: .primary, action: connectBot)
                            .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    Text(tr("El token se guarda en el Llavero de este Mac. Los mensajes al bot pasan por los servidores de Telegram."))
                        .font(Theme.caption)
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(Theme.Space.l)
            }
        }
    }

    private var isConnected: Bool {
        if case .connected = model.telegramStatus { return true }
        return false
    }

    private var telegramTitle: String {
        if case let .connected(name) = model.telegramStatus { return name }
        return "Conectando con Telegram"
    }

    private var telegramDetail: String {
        if !isConnected { return "Comprobando el token…" }
        return model.pairingCode == nil ? "Tu bot ya te reconoce." : "Falta emparejarlo contigo."
    }

    private func connectBot() {
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        model.actions?.connectTelegram(botToken: value)
        token = ""
    }

    private func numbered(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Text(verbatim: "\(number)")
                .font(Theme.mono(11, weight: .bold))
                .foregroundStyle(Theme.paper)
                .frame(width: 18, height: 18)
                .background(Theme.ink)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .accessibilityHidden(true)
            Text(tr(text)).font(Theme.body).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tr("Paso %@: %@", "\(number)", tr(text)))
    }

    private var computer: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            SettingsCard {
                switch model.computerState {
                case .notInstalled:
                    SettingRow(icon: "shippingbox", title: "Debian 13 para el agente",
                               detail: "Descarga unos 300 MB, verificados por hash. Puedes instalarla más tarde desde Ordenador.") {
                        BlockButton("Instalar", systemImage: "arrow.down", kind: .primary) { model.actions?.startComputer() }
                    }
                case let .preparing(text, progress):
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        HStack {
                            Text(tr(text)).font(Theme.bodyStrong).foregroundStyle(Theme.ink)
                            Spacer()
                            if let progress {
                                Text(verbatim: "\(Int(progress * 100)) %").font(Theme.mono(12)).foregroundStyle(Theme.secondary)
                            }
                        }
                        if let progress { BlockProgress(value: progress, label: text) } else { ProgressView().controlSize(.small) }
                    }
                    .padding(Theme.Space.l)
                case .starting:
                    SettingRow(icon: "power", title: "Arrancando Linux", detail: "La primera vez tarda uno o dos minutos.") {
                        ProgressView().controlSize(.small)
                    }
                case let .failed(message):
                    SettingRow(icon: "exclamationmark.triangle", title: "No se pudo arrancar", detail: message) {
                        BlockButton("Reintentar", systemImage: "arrow.clockwise", kind: .primary) { model.actions?.startComputer() }
                    }
                case .running, .paused, .stopped:
                    SettingRow(icon: "shippingbox", title: "Debian 13 · arm64",
                               detail: "Instalada. Arranca sola cuando el agente la necesita y se apaga tras 10 minutos sin uso.") {
                        StatusTag("Lista", kind: .active)
                    }
                }
            }
            InlineNote("Sin la máquina, el agente conversa, usa plugins en línea y las acciones del Mac, pero no ejecuta código.",
                       systemImage: "info.circle")
                .padding(.horizontal, 2)
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            SettingsCard {
                ForEach(Array(OnboardingStep.counted.enumerated()), id: \.element) { index, item in
                    if index > 0 { CardDivider() }
                    let complete = item.isComplete(model)
                    SettingRow(title: item.title, detail: complete ? nil : pendingHint(item)) {
                        HStack(spacing: Theme.Space.s) {
                            StatusTag(complete ? "Listo" : "Pendiente", kind: complete ? .active : .pending)
                            if !complete {
                                BlockButton("Ir al paso", compact: true) { step = item }
                                    .accessibilityLabel(tr("Ir al paso %@", tr(item.title)))
                            }
                        }
                    }
                }
            }
            SettingsCard {
                HStack(spacing: Theme.Space.m) {
                    KeyCap(symbol: "⌥", size: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tr("Prueba el dictado")).font(Theme.bodyStrong).foregroundStyle(Theme.ink)
                        Text(tr("Abre Notas, mantén ⌥ y di algo. Pulsa ⌥ dos veces para hablar sin mantenerla."))
                            .font(Theme.caption)
                            .foregroundStyle(Theme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(Theme.Space.l)
            }
        }
    }

    private func pendingHint(_ item: OnboardingStep) -> String {
        switch item {
        case .permissions: return "El dictado no funcionará hasta concederlos. Están en Dictado."
        case .account: return "El agente no puede responder sin una. Está en Modelo."
        case .telegram:
            return model.telegramUser.isReady
                ? "Tu cuenta ya está conectada. Falta el bot, que es por donde hablas con el agente. Está en Telegram."
                : "Sin bot no hay forma de hablar con el agente. Está en Telegram."
        case .computer: return "Opcional. Está en Ordenador."
        default: return ""
        }
    }
}
