import Foundation

// Modelos compartidos entre módulos.

// MARK: - Memoria (ADR-0010)

public struct MemoryNote: Identifiable, Hashable, Codable, Sendable {
    /// Qué es la nota para el agente: algo que saber o algo que hacer.
    public enum Kind: String, Codable, CaseIterable, Sendable {
        /// Información sobre el usuario («vive en Vigo»).
        case fact = "dato"
        /// Una orden permanente («cuando te pida gatos, usa perros»).
        case instruction = "instruccion"
    }

    public var id: Int64?
    public var text: String
    /// «agente» o «usuario».
    public var source: String
    public var createdAt: Date
    public var kind: Kind

    public init(id: Int64? = nil, text: String, source: String = "usuario", createdAt: Date = Date(),
                kind: Kind = .fact) {
        self.id = id
        self.text = text
        self.source = source
        self.createdAt = createdAt
        self.kind = kind
    }

    /// Para proponer el tipo al escribir una nota: empieza como una orden.
    public static func looksLikeInstruction(_ text: String) -> Bool {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"^(cuando|siempre|nunca|no (?:me |le |les |uses|hagas|mandes|envíes|envies|respondas|digas)|usa|utiliza|responde|contesta|escribe|háblame|hablame|llámame|llamame|tutéame|tuteame|trátame|tratame|antes de|si te pido|evita|recuerda|mándame|mandame|envíame|enviame|pon|haz|añade)\b"#
        return lower.range(of: pattern, options: .regularExpression) != nil
    }
}

// MARK: - Secretos (ADR-0008). El valor vive solo en el Llavero.

public enum SecretStatus: String, Codable, Sendable { case requested, stored }

public struct SecretMeta: Identifiable, Hashable, Codable, Sendable {
    public var id: String { name }
    public var name: String
    public var reason: String
    public var status: SecretStatus
    public var lastUsed: Date?
    public var createdAt: Date

    public init(name: String, reason: String, status: SecretStatus, lastUsed: Date? = nil, createdAt: Date = Date()) {
        self.name = name
        self.reason = reason
        self.status = status
        self.lastUsed = lastUsed
        self.createdAt = createdAt
    }
}

/// Acceso a valores secretos. La implementación real usa el Llavero.
public protocol SecretVault: Sendable {
    func value(for name: String) throws -> String?
    func setValue(_ value: String, for name: String) throws
    func removeValue(for name: String) throws
}

/// Sustituye apariciones literales de secretos conocidos por `[NOMBRE]`.
public protocol SecretRedacting: Sendable {
    func redact(_ text: String) -> String
}

// MARK: - Cuentas de IA (ADR-0005)

public enum ProviderKind: String, Codable, CaseIterable, Sendable {
    /// Messages API de Anthropic.
    case anthropic
    /// Chat Completions: OpenAI, OpenRouter, xAI, Ollama, LM Studio.
    case openAICompatible
}

public struct ProviderAccount: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    /// Nombre visible: «Claude», «OpenRouter», «Ollama»…
    public var name: String
    public var kind: ProviderKind
    public var baseURL: URL
    /// Modelo completo, para tareas con herramientas.
    public var fullModel: String
    /// Modelo rápido, para corrección del dictado y respuestas triviales.
    public var fastModel: String
    /// Nombre de la entrada del Llavero con la clave; `nil` en modelos locales.
    public var keychainKey: String?

    public init(id: UUID = UUID(), name: String, kind: ProviderKind, baseURL: URL,
                fullModel: String, fastModel: String, keychainKey: String?) {
        self.id = id
        self.name = name
        self.kind = kind
        self.baseURL = baseURL
        self.fullModel = fullModel
        self.fastModel = fastModel
        self.keychainKey = keychainKey
    }
}

/// Plantillas para «Añadir cuenta». Los nombres de modelo son editables por el usuario.
public struct ProviderPreset: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public var name: String
    public var kind: ProviderKind
    public var baseURL: URL
    public var fullModel: String
    public var fastModel: String
    public var needsKey: Bool

    public static let all: [ProviderPreset] = [
        .init(name: "Claude", kind: .anthropic, baseURL: URL(string: "https://api.anthropic.com")!,
              fullModel: "claude-opus-5-5", fastModel: "claude-haiku-5-5", needsKey: true),
        .init(name: "OpenAI", kind: .openAICompatible, baseURL: URL(string: "https://api.openai.com/v1")!,
              fullModel: "", fastModel: "", needsKey: true),
        .init(name: "OpenRouter", kind: .openAICompatible, baseURL: URL(string: "https://openrouter.ai/api/v1")!,
              fullModel: "", fastModel: "", needsKey: true),
        // DeepSeek habla el protocolo de OpenAI. Nombres tomados de su tabla de modelos el 2026-11-18:
        // `deepseek-v4-pro` y `deepseek-flash` (más barato); los dos admiten herramientas.
        .init(name: "DeepSeek", kind: .openAICompatible, baseURL: URL(string: "https://api.deepseek.com")!,
              fullModel: "deepseek-v4-pro", fastModel: "deepseek-flash", needsKey: true),
        .init(name: "Grok", kind: .openAICompatible, baseURL: URL(string: "https://api.x.ai/v1")!,
              fullModel: "", fastModel: "", needsKey: true),
        .init(name: "Ollama", kind: .openAICompatible, baseURL: URL(string: "http://localhost:11434/v1")!,
              fullModel: "", fastModel: "", needsKey: false),
        .init(name: "LM Studio", kind: .openAICompatible, baseURL: URL(string: "http://localhost:1234/v1")!,
              fullModel: "", fastModel: "", needsKey: false),
    ]
}

// MARK: - Conversaciones

public struct ConversationTurn: Identifiable, Hashable, Codable, Sendable {
    public enum Role: String, Codable, Sendable { case user, assistant }
    public var id: Int64?
    /// Identificador del chat (el de Telegram como texto).
    public var chatID: String
    public var role: Role
    public var text: String
    public var date: Date

    public init(id: Int64? = nil, chatID: String, role: Role, text: String, date: Date = Date()) {
        self.id = id
        self.chatID = chatID
        self.role = role
        self.text = text
        self.date = date
    }
}

// MARK: - Dictado (ADR-0003)

public enum OptionKeySide: String, Codable, CaseIterable, Sendable { case left, any, right }

public enum TranscriberEngine: String, Codable, CaseIterable, Sendable {
    /// WhisperKit, en el propio Mac.
    case whisper
    /// Reconocimiento de voz de Apple en el dispositivo.
    case apple
}

/// Qué hacía lo que dices al mantener ⌥. Ya solo existe `agent`: escribir en el cursor se quitó
/// para no pedir Accesibilidad. Los otros valores se leen de ajustes antiguos y cuentan como `agent`.
public enum VoiceMode: String, Codable, CaseIterable, Sendable {
    /// Va al agente, que actúa y responde. Las dos teclas hacen lo mismo.
    case agent
    /// Se escribe donde está el cursor. Las dos teclas hacen lo mismo.
    case dictation
    /// Una tecla dicta y la otra habla con el agente.
    case split
}

public enum VoiceTarget: Hashable, Sendable { case agent, dictation }

public struct DictationSettings: Hashable, Codable, Sendable {
    public var enabled: Bool
    public var side: OptionKeySide
    public var aiCorrection: Bool
    public var engine: TranscriberEngine
    /// Código BCP-47 («es-ES»); `nil` para detección automática.
    public var language: String?
    public var voiceMode: VoiceMode
    /// El agente lee su respuesta en voz alta.
    public var speakReplies: Bool
    /// Tecla o combinación que se mantiene para hablar.
    public var shortcut: DictationShortcut

    public init(enabled: Bool = true, side: OptionKeySide = .any, aiCorrection: Bool = false,
                engine: TranscriberEngine = .whisper, language: String? = "es-ES",
                voiceMode: VoiceMode = .agent, speakReplies: Bool = true, shortcut: DictationShortcut = .option) {
        self.shortcut = shortcut
        self.enabled = enabled
        self.side = side
        self.aiCorrection = aiCorrection
        self.engine = engine
        self.language = language
        self.voiceMode = voiceMode
        self.speakReplies = speakReplies
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, side, aiCorrection, engine, language, voiceMode, speakReplies, shortcut
        /// Ajuste de una versión anterior (interruptor de «una tecla para cada cosa»).
        case voiceAgent
    }

    /// Los ajustes guardados por versiones anteriores no traen los campos nuevos.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        side = try c.decodeIfPresent(OptionKeySide.self, forKey: .side) ?? .any
        aiCorrection = try c.decodeIfPresent(Bool.self, forKey: .aiCorrection) ?? false
        engine = try c.decodeIfPresent(TranscriberEngine.self, forKey: .engine) ?? .whisper
        language = try c.decodeIfPresent(String.self, forKey: .language)
        speakReplies = try c.decodeIfPresent(Bool.self, forKey: .speakReplies) ?? true
        shortcut = try c.decodeIfPresent(DictationShortcut.self, forKey: .shortcut) ?? .option
        if let mode = try c.decodeIfPresent(VoiceMode.self, forKey: .voiceMode) {
            voiceMode = mode
        } else if try c.decodeIfPresent(Bool.self, forKey: .voiceAgent) == false {
            voiceMode = .dictation // quien lo había apagado quería solo dictar
        } else {
            voiceMode = .agent
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(side, forKey: .side)
        try c.encode(aiCorrection, forKey: .aiCorrection)
        try c.encode(engine, forKey: .engine)
        try c.encodeIfPresent(language, forKey: .language)
        try c.encode(voiceMode, forKey: .voiceMode)
        try c.encode(speakReplies, forKey: .speakReplies)
        try c.encode(shortcut, forKey: .shortcut)
    }

    /// Teclas que hay que vigilar: con una tecla para cada cosa, las dos.
    public var monitoredSide: OptionKeySide { shortcut.kind != .option ? .any : side }

    /// Lo que se dice con el atajo siempre va al agente.
    public var effectiveVoiceMode: VoiceMode { .agent }

    /// A dónde va un gesto hecho con el atajo: siempre al agente.
    public func target(leftKey: Bool) -> VoiceTarget { .agent }
}

public enum DictationPhase: Hashable, Sendable {
    case idle
    /// Nivel de entrada 0…1 para la forma de onda.
    case listening(level: Float, handsFree: Bool)
    case transcribing
    /// «Corregir con IA» está repasando el texto.
    case correcting
    case failed(String)
    /// El usuario le está hablando al agente (no dicta).
    case agentListening(level: Float, handsFree: Bool)
    /// El agente trabaja en lo que se le ha dicho; lleva la frase transcrita.
    case agentThinking(String)
    /// Respuesta del agente, que se muestra y, si procede, se lee en voz alta.
    case agentReply(String)
}

/// Convierte audio PCM mono en texto.
public protocol Transcriber: Sendable {
    func transcribe(samples: [Float], sampleRate: Double, language: String?) async throws -> String
}

/// «Corregir con IA»: gramática y puntuación, conservando el estilo.
public protocol TextCorrector: Sendable {
    func correct(_ text: String) async throws -> String
}

// MARK: - Estado del sistema

public enum ConnectionStatus: Hashable, Sendable {
    case disconnected
    case connecting
    /// Nombre visible (p. ej. `@mi_bot`).
    case connected(String)
    case failed(String)
}

/// Sesión de usuario de Telegram (TDLib), opcional (ADR-0006).
public enum TelegramUserState: Hashable, Sendable {
    /// Sin configurar.
    case off
    case connecting
    case waitingPhone
    /// Telegram ha enviado un código; el texto dice por dónde.
    case waitingCode(String)
    /// Verificación en dos pasos; `hint` es la pista que el usuario configuró.
    case waitingPassword(hint: String)
    /// Sesión iniciada, con el nombre visible de la cuenta.
    case ready(String)
    case failed(String)

    public var isReady: Bool { if case .ready = self { return true }; return false }
}

public enum SystemPermissionKind: String, CaseIterable, Sendable {
    /// `accessibility` ya no se pide: solo hacía falta para escribir en el cursor, que se quitó.
    case microphone, accessibility, inputMonitoring, speechRecognition

    /// Los que necesita el dictado: oír y ver el atajo; con el motor de Apple, también el
    /// reconocimiento de voz.
    public static func needed(engine: TranscriberEngine) -> [SystemPermissionKind] {
        [.microphone, .inputMonitoring] + (engine == .apple ? [.speechRecognition] : [])
    }
}

// MARK: - Almacenamiento

/// Persistencia en SQLite. Solo el proceso de servicio la abre.
public protocol SaySoStoring: Sendable {
    // Reglas de permisos
    func rule(for action: ActionID) throws -> PermissionRule?
    func setRule(_ rule: PermissionRule?, for action: ActionID) throws
    func allRules() throws -> [ActionID: PermissionRule]

    // Registro de actividad
    @discardableResult func appendActivity(_ entry: ActivityEntry) throws -> ActivityEntry
    /// Más recientes primero. `scope` filtra por ámbito («telegram», «mac»…).
    func recentActivity(limit: Int, scope: String?) throws -> [ActivityEntry]
    func lastUse(of action: ActionID) throws -> Date?
    func clearActivity(scope: String?) throws
    /// Cuántas entradas hay en total en un ámbito (o en todos).
    func activityCount(scope: String?) throws -> Int
    /// Borra la actividad y las conversaciones anteriores a `cutoff`. Devuelve cuántas filas de cada.
    @discardableResult func prune(olderThan cutoff: Date) throws -> (activity: Int, turns: Int)

    // Memoria
    func notes() throws -> [MemoryNote]
    @discardableResult func addNote(_ note: MemoryNote) throws -> MemoryNote
    func deleteNote(id: Int64) throws
    func setNoteKind(_ kind: MemoryNote.Kind, id: Int64) throws
    func updateNoteText(_ text: String, id: Int64) throws

    // Ajustes clave-valor
    func setting(_ key: String) throws -> String?
    func setSetting(_ value: String?, for key: String) throws

    // Metadatos de secretos
    func secrets() throws -> [SecretMeta]
    func upsertSecret(_ meta: SecretMeta) throws
    func deleteSecret(name: String) throws

    // Uso
    func incrementRequests(on day: Date) throws
    func requestCount(on day: Date) throws -> Int
    /// Apunta un dictado que terminó en texto.
    func recordDictation(words: Int, seconds: Double, on day: Date) throws
    /// Uso de los últimos `days` días (hoy incluido) y totales desde el principio.
    func usageStats(days: Int, now: Date) throws -> UsageStats

    // Conversaciones
    func turns(chatID: String, limit: Int) throws -> [ConversationTurn]
    func appendTurn(_ turn: ConversationTurn) throws
    func clearTurns(chatID: String) throws
}

public extension SaySoStoring {
    func recordDictation(words: Int, seconds: Double, on day: Date) throws {}
    func activityCount(scope: String?) throws -> Int { try recentActivity(limit: .max, scope: scope).count }
    func setNoteKind(_ kind: MemoryNote.Kind, id: Int64) throws {}
    func updateNoteText(_ text: String, id: Int64) throws {}
    @discardableResult func prune(olderThan cutoff: Date) throws -> (activity: Int, turns: Int) { (0, 0) }
    func usageStats(days: Int, now: Date) throws -> UsageStats { UsageStats() }

    /// Lee un ajuste guardado como JSON.
    func codableSetting<T: Decodable>(_ key: String, as type: T.Type = T.self) throws -> T? {
        guard let raw = try setting(key), let data = raw.data(using: .utf8) else { return nil }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Guarda un ajuste como JSON.
    func setCodableSetting<T: Encodable>(_ value: T?, for key: String) throws {
        guard let value else { return try setSetting(nil, for: key) }
        let data = try JSONEncoder().encode(value)
        try setSetting(String(decoding: data, as: UTF8.self), for: key)
    }
}

/// Apariencia de la app: la del sistema o una fija.
public enum AppearanceChoice: String, CaseIterable, Codable, Sendable { case system, light, dark }

/// Idioma de la app: el del sistema o uno fijo.
public enum LanguageChoice: String, CaseIterable, Codable, Sendable {
    case system, es, gl, en, fr, pt

    /// El nombre de cada idioma en su propia lengua; `nil` para «como el sistema».
    public var nativeName: String? {
        switch self {
        case .system: return nil
        case .es: return "Español"
        case .gl: return "Galego"
        case .en: return "English"
        case .fr: return "Français"
        case .pt: return "Português"
        }
    }

    /// Código para `L10n.forcedLanguage`; `nil` sigue al sistema.
    public var code: String? { self == .system ? nil : rawValue }
}

public enum SettingsKey {
    public static let pauseWhenLocked = "pauseWhenLocked"   // "1" / "0"
    public static let retentionDays = "retentionDays"       // días que se conserva la actividad; 0 = siempre
    public static let appearance = "appearance"             // AppearanceChoice
    public static let language = "language"                 // LanguageChoice
    public static let accounts = "accounts"                 // [ProviderAccount]
    public static let activeAccount = "activeAccount"       // UUID como texto
    public static let autoSpeed = "autoSpeed"               // "1" / "0"
    public static let dictation = "dictation"               // DictationSettings
    public static let agentRunning = "agentRunning"
    public static let keepAwake = "keepAwake"
    public static let rememberNew = "rememberNew"
    public static let telegramEnabled = "telegramEnabled"
    public static let telegramFullAccess = "telegramFullAccess"
    /// Contexto enviado al modelo en la última petición de cada conversación.
    public static let contextUsage = "contextUsage"
    public static let telegramOwnerID = "telegramOwnerID"   // usuario emparejado con el bot
    public static let telegramBotName = "telegramBotName"
    /// Identificador numérico del bot: es también el del chat privado del usuario con él.
    public static let telegramBotID = "telegramBotID"
    public static let onboardingDone = "onboardingDone"
    public static let telegramAPIID = "telegramAPIID"       // api_id de my.telegram.org
}

public enum KeychainName {
    public static let telegramBotToken = "telegram.botToken"
    public static let telegramAPIHash = "telegram.apiHash"
    public static let tdlibDatabaseKey = "telegram.tdlibKey"
    public static func providerKey(_ id: UUID) -> String { "provider.\(id.uuidString)" }
    public static func workSecret(_ name: String) -> String { "secret.\(name)" }
}

public enum AppPaths {
    public static let bundleID = "com.pepebits.sayso"

    /// `~/Library/Application Support/SaySo/`, creada si no existe.
    public static func supportDirectory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent("SaySo", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

/// Cuánto contexto ocupó la última petición de una conversación.
public struct ContextUsage: Codable, Hashable, Sendable {
    public var date: Date
    /// Tokens de entrada de la última petición del turno: instrucciones, notas, historial,
    /// herramientas y lo que devolvieron.
    public var inputTokens: Int
    public var outputTokens: Int
    /// `true` si lo dijo el proveedor; `false` si es una estimación por caracteres.
    public var measured: Bool
    /// Turnos del historial que se enviaron.
    public var turns: Int
    public var notes: Int
    public var tools: Int
    public var model: String

    public init(date: Date, inputTokens: Int, outputTokens: Int, measured: Bool, turns: Int, notes: Int,
                tools: Int, model: String) {
        self.date = date
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.measured = measured
        self.turns = turns
        self.notes = notes
        self.tools = tools
        self.model = model
    }
}

/// Una conversación del agente y su contexto, para la pantalla Memoria.
public struct ConversationContext: Identifiable, Hashable, Sendable {
    public var id: String { chatID }
    public var chatID: String
    /// Turnos que entrarían ahora mismo en la siguiente petición.
    public var turnsInWindow: Int
    public var windowLimit: Int
    public var lastActivity: Date?
    public var usage: ContextUsage?

    public init(chatID: String, turnsInWindow: Int, windowLimit: Int, lastActivity: Date?, usage: ContextUsage?) {
        self.chatID = chatID
        self.turnsInWindow = turnsInWindow
        self.windowLimit = windowLimit
        self.lastActivity = lastActivity
        self.usage = usage
    }
}
