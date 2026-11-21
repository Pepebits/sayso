#if DEBUG
import SaySoCore
import SwiftUI

// Datos de ejemplo solo para #Preview.

@MainActor
final class PreviewActions: AppActions {
    let model: AppModel
    init(model: AppModel) { self.model = model }

    func showOnboarding() { model.showOnboarding = true }
    func finishOnboarding() { model.showOnboarding = false }
    func setAgentRunning(_ running: Bool) { model.agentRunning = running }
    func setOpenAtLogin(_ enabled: Bool) { model.openAtLogin = enabled }
    func setKeepAwake(_ enabled: Bool) { model.keepAwake = enabled }
    func setSpeakAlerts(_ enabled: Bool) { model.speakAlerts = enabled }
    func setAlertStyle(_ style: AlertStyle) { model.alertStyle = style }
    func exportBackup() {}
    func checkForUpdates() {}
    func setTokenLimits(_ limits: TokenLimits) { model.tokenLimits = limits }
    func setApproveFromBot(_ enabled: Bool) { model.approveFromBot = enabled }
    func setTasksPaused(_ paused: Bool) { model.tasksPaused = paused }
    func createDiagnostics() {}
    func openIssues() {}
    func setAutomaticUpdates(_ enabled: Bool) { model.updates = .ready(automatic: enabled, lastCheck: nil) }
    func importBackup() {}
    func updateDictation(_ settings: DictationSettings) { model.dictation = settings }
    func requestSystemPermission(_ kind: SystemPermissionKind) { model.systemPermissions[kind] = true }
    func addAccount(_ account: ProviderAccount, apiKey: String?) {
        model.accounts.append(account)
        if model.activeAccountID == nil { model.activeAccountID = account.id }
    }
    func removeAccount(id: UUID) { model.accounts.removeAll { $0.id == id } }
    func selectAccount(id: UUID) { model.activeAccountID = id }
    func setAccountVision(id: UUID, _ enabled: Bool) {
        if let i = model.accounts.firstIndex(where: { $0.id == id }) { model.accounts[i].vision = enabled }
    }
    func setAutoSpeed(_ enabled: Bool) { model.autoSpeed = enabled }
    func startComputer() { model.computerState = .running }
    func stopComputer() { model.computerState = .stopped }
    func runComputerCommand(_ command: String) {
        model.terminal.append(TerminalEntry(command: command, output: "ok", exitCode: 0))
    }
    func deleteComputer() { model.computerState = .notInstalled }
    func resetConsole() { model.consoleDirectory = "~/sayso" }
    func clearConsole() { model.terminal = [] }
    func openDesktop() {}
    func installDesktop() { model.desktopState = .installed }
    func addPlugin(_ config: PluginConfig) {
        if let i = model.plugins.firstIndex(where: { $0.id == config.id }) {
            model.plugins[i].added = true
            model.plugins[i].state = .ready(["buscar"])
        } else {
            model.plugins.append(PluginRow(config: config, added: true, state: .ready(["buscar"])))
        }
    }
    func removePlugin(id: String) {
        if let i = model.plugins.firstIndex(where: { $0.id == id }) { model.plugins[i].added = false; model.plugins[i].state = .idle }
    }
    func setPluginEnabled(_ enabled: Bool, id: String) {
        if let i = model.plugins.firstIndex(where: { $0.id == id }) { model.plugins[i].config.enabled = enabled }
    }
    func reconnectPlugin(id: String) {}
    func addTask(instruction: String, schedule: TaskSchedule, recipients: [TaskRecipient], sendWithoutAsking: Bool) {
        model.tasks.append(ScheduledTask(id: Int64(model.tasks.count + 1), instruction: instruction, schedule: schedule,
                                         nextRun: schedule.next(after: Date()), recipients: recipients,
                                         sendWithoutAsking: sendWithoutAsking))
    }
    func updateTask(id: Int64, instruction: String, schedule: TaskSchedule, recipients: [TaskRecipient],
                    sendWithoutAsking: Bool) {
        guard let i = model.tasks.firstIndex(where: { $0.id == id }) else { return }
        model.tasks[i].sendWithoutAsking = sendWithoutAsking
        model.tasks[i].instruction = instruction
        model.tasks[i].schedule = schedule
        model.tasks[i].recipients = recipients
    }
    func chatPhoto(_ chatID: Int64) async -> URL? { nil }
    func searchRecipients(_ query: String) async -> [TaskRecipient] {
        [TaskRecipient(id: 1, title: "Lucas Moreno", username: "lucas_mor82"), TaskRecipient(id: 2, title: "Equipo diseño", kind: "grupo")]
            .filter { $0.title.localizedCaseInsensitiveContains(query) }
    }
    func setTaskEnabled(_ enabled: Bool, id: Int64) {
        if let i = model.tasks.firstIndex(where: { $0.id == id }) { model.tasks[i].enabled = enabled }
    }
    func deleteTask(id: Int64) { model.tasks.removeAll { $0.id == id } }
    func runTaskNow(id: Int64) {}
    func connectTelegram(botToken: String) { model.telegramStatus = .connected("@sayso_demo_bot"); model.pairingCode = "482913" }
    func disconnectTelegram() { model.telegramStatus = .disconnected; model.pairingCode = nil }
    func connectTelegramUser(apiID: String, apiHash: String) { model.telegramUser = .waitingPhone }
    func submitTelegramUserPhone(_ phone: String) { model.telegramUser = .waitingCode("Telegram te ha enviado un código.") }
    func submitTelegramUserCode(_ code: String) { model.telegramUser = .ready("Demo") }
    func submitTelegramUserPassword(_ password: String) { model.telegramUser = .ready("Demo") }
    func disconnectTelegramUser() { model.telegramUser = .off }
    func setTelegramEnabled(_ enabled: Bool) { model.telegramEnabled = enabled }
    func setTelegramFullAccess(_ enabled: Bool) { model.telegramFullAccess = enabled }
    func setRule(_ rule: PermissionRule, for action: ActionID) { model.rules[action] = rule }
    func clearActivity(scope: String) {
        if scope == "telegram" { model.telegramActivity = [] } else { model.macActivity = [] }
    }
    func storeSecret(name: String, value: String, reason: String) {
        model.secrets.removeAll { $0.name == name }
        model.secrets.append(SecretMeta(name: name, reason: reason, status: .stored))
    }
    func forgetSecret(name: String) { model.secrets.removeAll { $0.name == name } }
    func setRememberNew(_ enabled: Bool) { model.rememberNew = enabled }
    func addNote(_ text: String, kind: MemoryNote.Kind) {
        model.notes.insert(MemoryNote(id: Int64(model.notes.count + 100), text: text, kind: kind), at: 0)
    }
    func updateNote(id: Int64, text: String, kind: MemoryNote.Kind) {
        if let i = model.notes.firstIndex(where: { $0.id == id }) { model.notes[i].text = text; model.notes[i].kind = kind }
    }
    func setNoteKind(_ kind: MemoryNote.Kind, id: Int64) {
        if let i = model.notes.firstIndex(where: { $0.id == id }) { model.notes[i].kind = kind }
    }
    func forgetNote(id: Int64) { model.notes.removeAll { $0.id == id } }
    func newConversation(chatID: String) { model.contexts.removeAll { $0.chatID == chatID } }
    func refreshResources() {}
    func deleteWatch(id: String) { model.watches.removeAll { $0.id == id } }
    func cleanTelegramFiles() {}
    func freeComputerSpace() {}
    func setComputerResources(_ resources: ComputerResources) { model.computerResources = resources }
    func removeGuardModel(folder: String) {}
    func clearLog() { model.logEntries = [] }
    func relaunch() {}
    func setGuardReview(_ enabled: Bool) { model.guardReview = enabled }
    func setGuardDetector(_ choice: GuardSettings.Detector) { model.guardDetector = choice }
    func installLocalDetector() { model.localDetector = .installing }
    func setLocalModel(_ repo: String) { model.localModel = repo; model.localDetector = .notInstalled }
    func toggleManualDictation(forAgent: Bool) {}
    func cancelManualDictation() {}
    func toggleConversation() {}
    func setShortcutRecording(_ active: Bool) {}
    func copyToClipboard(_ text: String) {}
    func revealApp() {}
    func resetSystemPermissions() {}
    func eraseEverything(removeApp: Bool) {}
    func setPauseWhenLocked(_ enabled: Bool) { model.pauseWhenLocked = enabled }
    func showMoreActivity(scope: String) {}
    func setRetentionDays(_ days: Int) { model.retentionDays = days }
    func setAppearance(_ choice: AppearanceChoice) { model.appearance = choice }
    func setLanguage(_ choice: LanguageChoice) { model.language = choice }
    func revealDataFolder() {}
    func revealLog() {}
}

@MainActor
enum PreviewData {
    /// Retiene las acciones (la referencia del modelo es débil).
    static var retained: [PreviewActions] = []

    static func model() -> AppModel {
        let m = AppModel()
        m.agentRunning = true
        m.telegramStatus = .connected("@sayso_demo_bot")
        m.pairingCode = "482913"
        m.requestsToday = 122
        m.openAtLogin = true
        m.systemPermissions = [.microphone: true, .accessibility: true, .inputMonitoring: true]
        m.transcriberStatus = "Descargando 40 %"
        let claude = ProviderAccount(name: "Claude", kind: .anthropic,
                                     baseURL: URL(string: "https://api.anthropic.com")!,
                                     fullModel: "claude-opus-5-5", fastModel: "claude-haiku-5-5",
                                     keychainKey: "provider.demo")
        let ollama = ProviderAccount(name: "Ollama", kind: .openAICompatible,
                                     baseURL: URL(string: "http://localhost:11434/v1")!,
                                     fullModel: "qwen3:32b", fastModel: "qwen3:4b", keychainKey: nil)
        m.accounts = [ollama, claude]
        m.activeAccountID = ollama.id
        m.rules = [TelegramAction.sendMessages: .ask, MacScript.volume.action: .allow]
        m.telegramActivity = [
            ActivityEntry(id: 1, date: Date().addingTimeInterval(-300), action: TelegramAction.sendMessages,
                          summary: "Enviar a Anna: «Llego en 5 min»", rule: .ask, outcome: .allowed, origin: "Chat con el bot"),
            ActivityEntry(id: 2, date: Date().addingTimeInterval(-7200), action: TelegramAction.deleteMessages,
                          summary: "Eliminar 3 mensajes en «Familia»", rule: .ask, outcome: .denied),
        ]
        m.macLastUse = [.volume: Date().addingTimeInterval(-3600), .calendarToday: Date().addingTimeInterval(-86400)]
        m.macActivity = [
            ActivityEntry(id: 3, date: Date().addingTimeInterval(-3600), action: MacScript.volume.action,
                          summary: "Bajar el volumen al 30 %", rule: .allow, outcome: .allowed),
        ]
        m.secrets = [
            SecretMeta(name: "FIGMA_TOKEN", reason: "Exportar los iconos del archivo de diseño", status: .requested),
            SecretMeta(name: "GITHUB_TOKEN", reason: "Abrir pull requests en tus repositorios", status: .stored,
                       lastUsed: Date().addingTimeInterval(-1800)),
        ]
        m.notes = [
            MemoryNote(id: 1, text: "Respóndeme con frases cortas y en español.", source: "usuario", kind: .instruction),
            MemoryNote(id: 2, text: "Trabaja en el repositorio dictator con Swift.", source: "agente",
                       createdAt: Date().addingTimeInterval(-86400 * 3)),
        ]
        let actions = PreviewActions(model: m)
        retained.append(actions)
        m.actions = actions
        return m
    }

    /// Noventa días de uso inventado pero estable, con fines de semana flojos y algún día en blanco.
    static func sampleStats(now: Date = Date()) -> UsageStats {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        var all = UsageTotals()
        let days: [DayUsage] = (0..<90).reversed().map { ago in
            let day = calendar.date(byAdding: .day, value: -ago, to: today) ?? today
            let seed = (ago * 37 + 11) % 23
            let weekend = calendar.isDateInWeekend(day)
            let dictations = seed % 7 == 0 ? 0 : (weekend ? seed / 4 : 6 + seed)
            let requests = seed % 7 == 0 ? 0 : (weekend ? 8 + seed : 40 + seed * 4)
            let totals = UsageTotals(requests: requests,
                                     dictations: dictations, words: dictations * (18 + seed % 9),
                                     seconds: Double(dictations * (9 + seed % 6)),
                                     inputTokens: requests * 5_800, outputTokens: requests * 240)
            all = all + totals
            return DayUsage(day: day, totals: totals)
        }
        func bucket(_ ago: Int, _ action: ActionID, _ outcome: ActivityOutcome, _ count: Int) -> ActionBucket {
            ActionBucket(day: calendar.date(byAdding: .day, value: -ago, to: today) ?? today,
                         action: action, outcome: outcome, count: count)
        }
        let tokens = days.flatMap { day -> [TokenBucket] in
            let r = day.totals.requests
            return [TokenBucket(day: day.day, model: "qwen3:32b", input: r * 4_600, output: r * 190, requests: r * 3 / 4, estimated: true),
                    TokenBucket(day: day.day, model: "qwen3:4b", input: r * 1_200, output: r * 50, requests: r / 4, estimated: true)]
        }
        return UsageStats(days: days, allTime: all, firstDay: days.first?.day, actions: [
            bucket(1, TelegramAction.readMessages, .allowed, 41), bucket(3, TelegramAction.sendMessages, .allowed, 17),
            bucket(4, TelegramAction.deleteMessages, .denied, 3), bucket(2, ComputerAction.run, .allowed, 96),
            bucket(9, ComputerAction.writeFile, .allowed, 22), bucket(12, ComputerAction.run, .failed, 5),
            bucket(5, MacScript.calendarToday.action, .allowed, 14), bucket(20, MacScript.volume.action, .allowed, 6),
            bucket(40, MacScript.note.action, .denied, 2), bucket(6, ActionID("plugin.context7"), .allowed, 9),
        ], tokens: tokens)
    }

    /// Todo conectado y con datos en cada pantalla, para revisar el diseño completo.
    static func fullModel() -> AppModel {
        let m = model()
        m.pairingCode = nil
        m.telegramUser = .ready("Ana García")
        m.transcriberStatus = "Listo"
        m.requestsWeek = [40, 62, 31, 88, 70, 95, 122]
        m.stats = sampleStats()
        m.resources = ResourceUsage(disk: [
            .init(id: "vm", title: "Máquina Linux", bytes: 6_400_000_000, detail: "disco de 17,2 GB como mucho"),
            .init(id: "models", title: "Modelos de dictado", bytes: 490_000_000),
            .init(id: "telegram", title: "Telegram", bytes: 6_200_000, detail: "fotos, audios y archivos descargados, y la base de datos de TDLib"),
            .init(id: "database", title: "Base de datos", bytes: 340_000, detail: "memoria, conversaciones, tareas y actividad"),
            .init(id: "logs", title: "Registros", bytes: 160_000),
        ], appMemory: 182_000_000, vmMemory: 4_294_967_296, vmRunning: true, measuredAt: Date().addingTimeInterval(-60))
        m.watches = [MessageWatch(id: "a1b2c3d4", chatID: 2, chatTitle: "Equipo diseño", instruction: "Resúmeme lo que se decida"),
                     MessageWatch(id: "e5f6a7b8", chatID: 1, chatTitle: "Anna", keyword: "cena")]
        m.contexts = [
            ConversationContext(chatID: "voz", turnsInWindow: 14, windowLimit: 30,
                                lastActivity: Date().addingTimeInterval(-300),
                                usage: ContextUsage(date: Date().addingTimeInterval(-300), inputTokens: 6240,
                                                    outputTokens: 180, measured: true, turns: 14, notes: 5,
                                                    tools: 22, model: "qwen3:32b")),
            ConversationContext(chatID: "418000000", turnsInWindow: 0, windowLimit: 30,
                                lastActivity: nil, usage: nil),
        ]
        m.activityTotals = ["telegram": 84, "mac": 1]
        m.dataFolder = "~/Library/Application Support/SaySo"
        let ago: (TimeInterval) -> Date = { Date().addingTimeInterval(-$0) }
        m.logEntries = [
            LogEntry(date: ago(86_400 + 5200), level: .info, category: LogCategory.app, message: "SaySo 0.2.0 iniciada"),
            LogEntry(date: ago(86_400 + 5100), level: .info, category: LogCategory.telegram, message: "Bot conectado"),
            LogEntry(date: ago(86_400 + 900), level: .error, category: LogCategory.computer,
                     message: "Máquina Linux: no se pudo descargar la imagen. Comprueba la conexión."),
            LogEntry(date: ago(9200), level: .info, category: LogCategory.app, message: "SaySo 0.2.0 iniciada"),
            LogEntry(date: ago(9100), level: .info, category: LogCategory.computer, message: "Máquina Linux en marcha"),
            LogEntry(date: ago(7300), level: .info, category: LogCategory.voice, message: "Respuesta en 1,3 s"),
            LogEntry(date: ago(5400), level: .warning, category: LogCategory.voice, message: "Respuesta lenta: 19,9 s esperando al modelo"),
            LogEntry(date: ago(2100), level: .error, category: LogCategory.plugins, message: "GitHub: Falta el secreto GITHUB_TOKEN."),
            LogEntry(date: ago(720), level: .error, category: LogCategory.dictation,
                     message: "No se ha podido transcribir: el modelo de voz aún se está descargando."),
            LogEntry(date: ago(60), level: .info, category: LogCategory.telegram, message: "Cuenta de Telegram conectada"),
        ]
        m.computerState = .running
        m.computerStats = ComputerStats(cpuPercent: 21, cpuCount: 2, memoryUsed: 2_300_000_000, memoryTotal: 4_000_000_000,
                                        diskUsed: 3_600_000_000, diskTotal: 16_000_000_000)
        m.terminal = [
            TerminalEntry(command: "git clone weather", author: .agent, output: "Cloning into 'weather'… done", exitCode: 0),
            TerminalEntry(command: "npm test", author: .agent, directory: "~/sayso/weather", output: "42 tests passed in 3.1s", exitCode: 0),
            TerminalEntry(command: "ls nada", directory: "~/sayso/weather", output: "ls: nada: No such file or directory", exitCode: 2),
        ]
        m.consoleDirectory = "~/sayso/weather"
        m.plugins = PluginCatalog.all.enumerated().map { index, config in
            switch index {
            case 0: return PluginRow(config: config, added: true, state: .ready(["resolve-library-id", "get-library-docs"]))
            case 1: return PluginRow(config: config, added: true, state: .failed("Falta el secreto GITHUB_TOKEN."))
            case 3: return PluginRow(config: config, added: true, state: .idle)
            default: return PluginRow(config: config, added: false)
            }
        }
        let now = Date()
        m.tasks = [
            ScheduledTask(id: 1, instruction: "Envíame mi calendario de hoy", schedule: .daily(hour: 9, minute: 0, weekdays: []),
                          nextRun: now.addingTimeInterval(7200), lastRun: now.addingTimeInterval(-79_000),
                          lastResult: "3 eventos hoy: Daily 10:00, comida con Anna 14:00 y revisión de diseño 17:30."),
            ScheduledTask(id: 2, instruction: "Resume lo que me perdí en el grupo Equipo",
                          schedule: .daily(hour: 17, minute: 0, weekdays: [1, 2, 3, 4, 5]),
                          nextRun: now.addingTimeInterval(20_000), lastRun: now.addingTimeInterval(-66_000), recipients: [TaskRecipient(id: 2, title: "Equipo diseño", kind: "grupo"), TaskRecipient(id: 4, title: "Anna", username: "anna_design")]),
            ScheduledTask(id: 3, instruction: "Comprueba si hay incidencias nuevas en Linear", schedule: .every(minutes: 180),
                          enabled: false, lastRun: now.addingTimeInterval(-170_000),
                          lastResult: "Sin incidencias críticas nuevas."),
        ]
        m.notes += [
            MemoryNote(id: 3, text: "Su zona horaria es Europa/Madrid.", source: "agente", createdAt: now.addingTimeInterval(-250_000)),
            MemoryNote(id: 4, text: "Los viernes no quiere reuniones después de las 15:00.", source: "agente",
                       createdAt: now.addingTimeInterval(-430_000)),
            MemoryNote(id: 5, text: "Anna es su compañera de equipo en diseño.", source: "usuario", createdAt: now.addingTimeInterval(-86_400)),
        ]
        m.secrets += [
            SecretMeta(name: "DEEPSEEK_API_KEY", reason: "Cuenta de IA principal", status: .stored,
                       lastUsed: now.addingTimeInterval(-7200)),
            SecretMeta(name: "ANTHROPIC_API_KEY", reason: "Claude Code", status: .stored),
        ]
        return m
    }
}

#Preview("Ajustes") {
    SettingsRootView(model: PreviewData.model())
        .frame(width: 1040, height: 720)
}

#Preview("Ajustes vacío, con error") {
    let m = AppModel()
    m.lastError = "No se pudo conectar con Telegram: el token no es válido."
    return SettingsRootView(model: m)
        .frame(width: 960, height: 660)
}

#Preview("Componentes") {
    @Previewable @State var on = true
    @Previewable @State var side = OptionKeySide.any
    @Previewable @State var rule = PermissionRule.ask
    VStack(alignment: .leading, spacing: 16) {
        HStack(spacing: 12) {
            AppIconView(size: 56)
            Bit()
            IconTile("mic")
            StatusTag("En marcha", kind: .active)
            StatusTag("Pendiente", kind: .pending)
            StatusTag("Conectando", kind: .connecting)
            StatusTag("Error", kind: .error)
        }
        HStack(spacing: 12) {
            BlockToggle(isOn: $on, label: "Ejemplo")
            BlockButton("Primario", kind: .primary) {}
            BlockButton("Secundario") {}
            BlockButton("Olvidar", kind: .destructive) {}
        }
        BlockSegmented("Lado", selection: $side, options: OptionKeySide.allCases.map { ($0, $0.title) })
        RuleSegmented("Enviar mensajes", rule: $rule)
        BlockProgress(value: 0.4)
        SettingsCard {
            SettingRow(icon: "paperplane", title: "Una fila con un título largo que tiene que partirse en varias líneas sin cortarse",
                       detail: "Descripción secundaria.") { BlockToggle(isOn: $on, label: "Fila") }
        }
        ErrorBand("No se pudo guardar la clave en el Llavero.")
    }
    .padding(24)
    .frame(width: 620)
    .background(Theme.paper)
}

#Preview("Píldora de dictado") {
    VStack(spacing: 12) {
        DictationHUDView(phase: .listening(level: 0.7, handsFree: false))
        DictationHUDView(phase: .listening(level: 0.3, handsFree: true))
        DictationHUDView(phase: .transcribing)
        DictationHUDView(phase: .failed("No hay permiso de micrófono"))
    }
    .padding(24)
}

#Preview("Confirmación") {
    ConfirmationView(
        request: ActionRequest(action: TelegramAction.sendMessages,
                               summary: "Enviar a Anna: «Llego en 5 min»",
                               parameters: ["chat": "Anna", "texto": "Llego en 5 min"],
                               origin: "Chat con el bot"),
        descriptor: TelegramAction.descriptors.first { $0.id == TelegramAction.sendMessages }
    ) { _ in }
}
#endif
