import Foundation
import Observation
import SaySoCore

/// Estado que pintan las pantallas. Lo actualiza el controlador de la app (SaySoApp);
/// las vistas no lo modifican directamente: llaman a `actions`.
@MainActor
@Observable
public final class AppModel {
    public init() {}

    /// La guía de inicio ocupa la ventana (primer arranque o al repetirla).
    public var showOnboarding = false

    // Inicio
    public var agentRunning = false
    public var telegramStatus: ConnectionStatus = .disconnected { didSet { logTelegramBot(from: oldValue) } }
    public var requestsToday = 0
    /// Solicitudes de los últimos siete días, del más antiguo a hoy.
    public var requestsWeek: [Int] = []
    public var openAtLogin = false
    /// Uso de los últimos 90 días y totales, para la pantalla Estadísticas.
    public var stats = UsageStats()
    public var keepAwake = false
    /// El agente deja de atender mientras el Mac está bloqueado.
    public var pauseWhenLocked = false
    /// Protección: revisar acciones tras leer contenido ajeno, y qué detector de inyecciones se usa.
    public var guardReview = true
    public var guardDetector: GuardSettings.Detector = .fast
    public var localDetector: LocalDetectorState = .notInstalled
    /// Repositorio del modelo local elegido.
    public var localModel = LocalGuardModel.recommended.repo
    /// Ahora mismo está en pausa por eso.
    public var lockPaused = false
    public var appearance: AppearanceChoice = .system
    public var language: LanguageChoice = .system
    /// Carpeta donde la app guarda sus datos, para enseñarla en Ajustes.
    public var dataFolder = ""

    // Dictado
    public var dictation = DictationSettings()
    public var dictationPhase: DictationPhase = .idle { didSet { logDictation(from: oldValue) } }
    /// Conversaciones del agente y el contexto que ocupan.
    public var contexts: [ConversationContext] = []
    /// Hay una conversación hablada con el agente en curso.
    public var conversing = false
    /// Lo dicho en la conversación en curso (o en la última), en orden.
    public var conversationLines: [ConversationLine] = []
    /// Hay un dictado manual (con el botón) en curso.
    public var manualDictation = false
    /// Lo reconocido hasta el momento en el dictado manual, y el texto final al terminar.
    public var manualTranscript = ""
    /// Permisos de macOS concedidos.
    public var systemPermissions: [SystemPermissionKind: Bool] = [:]
    /// Estado del modelo de transcripción («Descargando 40 %», «Listo»…); `nil` si no aplica.
    public var transcriberStatus: String?

    // Modelo
    public var accounts: [ProviderAccount] = []
    public var activeAccountID: UUID?
    public var autoSpeed = true

    // Ordenador
    /// Lo que ocupa SaySo en disco y memoria; `nil` hasta que se mide.
    public var resources: ResourceUsage?
    public var computerState: ComputerState = .notInstalled { didSet { logComputer(from: oldValue) } }
    public var computerStats: ComputerStats?
    public var computerActivity: [ActivityEntry] = []
    public var desktopState: DesktopState = .notInstalled { didSet { logDesktop(from: oldValue) } }
    /// Comandos lanzados a mano desde la pantalla, del más antiguo al más reciente.
    public var terminal: [TerminalEntry] = []
    /// Carpeta actual de la sesión de consola.
    public var consoleDirectory = "~/sayso"
    /// Hay un comando del usuario en curso.
    public var consoleBusy = false

    // Plugins
    public var plugins: [PluginRow] = [] { didSet { logPlugins(from: oldValue) } }
    public var pluginActivity: [ActivityEntry] = []

    // Tareas programadas
    public var tasks: [ScheduledTask] = []

    // Permisos · Telegram
    public var telegramEnabled = true
    public var telegramFullAccess = false
    public var rules: [ActionID: PermissionRule] = [:]
    public var telegramActivity: [ActivityEntry] = []
    /// Entradas totales de cada ámbito del registro de actividad («telegram», «mac», «vm», «plugin»),
    /// para saber si hay más de las que se enseñan.
    public var activityTotals: [String: Int] = [:]
    /// Días que se conserva la actividad y las conversaciones; 0 es para siempre.
    public var retentionDays = 90
    /// Sesión de usuario (TDLib) para que el agente lea y escriba en los chats del usuario.
    public var telegramUser: TelegramUserState = .off { didSet { logTelegramUser(from: oldValue) } }
    /// Foto de perfil de esa cuenta, ya descargada en este Mac; `nil` si no tiene.
    public var telegramUserPhoto: URL?
    /// Código de un solo uso para emparejar el bot con el usuario; `nil` si ya está emparejado.
    public var pairingCode: String?

    // Permisos · Mac
    public var macLastUse: [MacScript: Date] = [:]
    public var macActivity: [ActivityEntry] = []

    // Permisos · Secretos
    public var secrets: [SecretMeta] = []

    // Memoria
    public var rememberNew = true
    public var notes: [MemoryNote] = []

    /// Último error para mostrar al usuario.
    public var lastError: String? {
        didSet { if let lastError, lastError != oldValue { log(.error, LogCategory.app, lastError) } }
    }

    // Registros
    /// Entradas del registro de la app, de la más antigua a la más reciente.
    public var logEntries: [LogEntry] = []
    /// Dónde se guarda cada entrada nueva (el archivo del registro); `nil` en previsualizaciones.
    @ObservationIgnored public var logSink: ((LogEntry) -> Void)?
    static let logLimit = 1000
    /// Ya se ha apuntado que la tecla del dictado responde en este arranque.
    @ObservationIgnored public var loggedFirstListen = false

    public weak var actions: AppActions?

    public var activeAccount: ProviderAccount? { accounts.first { $0.id == activeAccountID } }

    /// Permisos de macOS sin los que el dictado no puede funcionar. Vacío si el dictado está
    /// desactivado o si aún no se ha comprobado ningún permiso.
    public var missingDictationPermissions: [SystemPermissionKind] {
        guard dictation.enabled, !systemPermissions.isEmpty else { return [] }
        return [.inputMonitoring, .microphone].filter { systemPermissions[$0] != true }
    }

    public func rule(for descriptor: ActionDescriptor) -> PermissionRule {
        rules[descriptor.id] ?? descriptor.defaultRule
    }
}

/// Lo que las pantallas pueden pedir. Lo implementa el controlador de la app.
@MainActor
public protocol AppActions: AnyObject {
    // Guía de inicio
    func showOnboarding()
    /// Cierra la guía y recuerda que ya se ha visto.
    func finishOnboarding()

    // Inicio
    func setAgentRunning(_ running: Bool)
    func setOpenAtLogin(_ enabled: Bool)
    func setKeepAwake(_ enabled: Bool)
    func setPauseWhenLocked(_ enabled: Bool)
    func setGuardReview(_ enabled: Bool)
    func setGuardDetector(_ choice: GuardSettings.Detector)
    func installLocalDetector()
    func setLocalModel(_ repo: String)
    func setAppearance(_ choice: AppearanceChoice)
    func setLanguage(_ choice: LanguageChoice)
    /// Enseña en el Finder la carpeta de datos de la app.
    func revealDataFolder()

    // Dictado
    func updateDictation(_ settings: DictationSettings)
    /// Se está grabando un atajo nuevo: el actual deja de escuchar mientras tanto.
    func setShortcutRecording(_ active: Bool)
    /// Dictado manual con el botón: la primera vez empieza a grabar, la segunda termina.
    func toggleManualDictation(forAgent: Bool)
    /// Descarta el dictado manual en curso.
    func cancelManualDictation()
    /// Empieza o termina una conversación hablada con el agente.
    func toggleConversation()
    /// Copia un texto al portapapeles.
    func copyToClipboard(_ text: String)
    /// Abre el diálogo del sistema o el panel de Ajustes del Sistema correspondiente.
    func requestSystemPermission(_ kind: SystemPermissionKind)
    /// Cierra la app y la vuelve a abrir: algunos permisos de macOS solo se aplican al arrancar.
    func relaunch()
    /// Enseña la app en el Finder, para arrastrarla a una lista de Ajustes del Sistema.
    func revealApp()
    /// Quita a la app sus permisos de macOS y la reinicia para pedirlos de cero.
    func resetSystemPermissions()
    /// Borra del Mac todo lo que la app ha guardado y la cierra. No se puede deshacer.
    func eraseEverything(removeApp: Bool)

    // Modelo
    func addAccount(_ account: ProviderAccount, apiKey: String?)
    func removeAccount(id: UUID)
    func selectAccount(id: UUID)
    func setAutoSpeed(_ enabled: Bool)

    // Ordenador
    /// Descarga la imagen si falta y arranca la máquina.
    func startComputer()
    func stopComputer()
    func runComputerCommand(_ command: String)
    /// Cierra la sesión de consola (mata lo que esté corriendo) y vuelve a ~/sayso.
    func resetConsole()
    func clearConsole()
    /// Apaga la máquina y borra su disco.
    func deleteComputer()
    /// Abre la ventana con la pantalla de la máquina (arranca la máquina si hace falta).
    func openDesktop()
    /// Instala el escritorio gráfico y el navegador dentro de la máquina.
    func installDesktop()

    // Plugins
    /// Añade un plugin del catálogo o un servidor propio y lo conecta o instala.
    func addPlugin(_ config: PluginConfig)
    func removePlugin(id: String)
    func setPluginEnabled(_ enabled: Bool, id: String)
    /// Vuelve a intentar la conexión (p. ej. tras guardar el secreto que faltaba).
    func reconnectPlugin(id: String)

    // Tareas programadas
    func addTask(instruction: String, schedule: TaskSchedule, recipients: [TaskRecipient], sendWithoutAsking: Bool)
    /// Cambia una tarea programada: qué hace, cuándo y para quién.
    func updateTask(id: Int64, instruction: String, schedule: TaskSchedule, recipients: [TaskRecipient],
                    sendWithoutAsking: Bool)
    /// Foto de perfil de un chat de Telegram, descargada en este Mac.
    func chatPhoto(_ chatID: Int64) async -> URL?
    /// Personas y grupos de la cuenta de Telegram del usuario que coinciden con lo escrito.
    func searchRecipients(_ query: String) async -> [TaskRecipient]
    func setTaskEnabled(_ enabled: Bool, id: Int64)
    func deleteTask(id: Int64)
    func runTaskNow(id: Int64)

    // Telegram
    /// Guarda el token del bot en el Llavero y conecta.
    func connectTelegram(botToken: String)
    func disconnectTelegram()
    /// Guarda las credenciales de app de my.telegram.org y empieza el inicio de sesión.
    func connectTelegramUser(apiID: String, apiHash: String)
    func submitTelegramUserPhone(_ phone: String)
    func submitTelegramUserCode(_ code: String)
    func submitTelegramUserPassword(_ password: String)
    /// Cierra la sesión en Telegram y borra los datos locales.
    func disconnectTelegramUser()
    func setTelegramEnabled(_ enabled: Bool)
    func setTelegramFullAccess(_ enabled: Bool)
    func setRule(_ rule: PermissionRule, for action: ActionID)
    func clearActivity(scope: String)
    /// Carga más entradas antiguas de un ámbito del registro de actividad.
    func showMoreActivity(scope: String)
    func setRetentionDays(_ days: Int)

    // Secretos
    func storeSecret(name: String, value: String, reason: String)
    func forgetSecret(name: String)

    // Memoria
    func setRememberNew(_ enabled: Bool)
    func addNote(_ text: String, kind: MemoryNote.Kind)
    func setNoteKind(_ kind: MemoryNote.Kind, id: Int64)
    /// Cambia el texto y el tipo de una nota.
    func updateNote(id: Int64, text: String, kind: MemoryNote.Kind)
    func forgetNote(id: Int64)
    /// Borra el historial de una conversación del agente para empezar de cero.
    func newConversation(chatID: String)
    /// Vuelve a medir lo que ocupa SaySo (sección Recursos de Estadísticas).
    func refreshResources()
    /// Borra los archivos descargados de Telegram que no se estén usando.
    func cleanTelegramFiles()

    // Registros
    /// Borra el registro de la app, también el archivo.
    func clearLog()
    /// Enseña el archivo del registro en el Finder.
    func revealLog()
}

/// Una frase de la conversación hablada con el agente.
public struct ConversationLine: Identifiable, Hashable, Sendable {
    public let id: Int
    public var fromUser: Bool
    public var text: String

    public init(id: Int, fromUser: Bool, text: String) {
        self.id = id
        self.fromUser = fromUser
        self.text = text
    }
}
