import Foundation

// Tareas programadas.

/// Cuándo se repite una tarea.
public enum TaskSchedule: Hashable, Codable, Sendable {
    /// Una sola vez.
    case once(Date)
    /// Cada día a una hora local. `weekdays` usa 1 = lunes … 7 = domingo; vacío significa todos.
    case daily(hour: Int, minute: Int, weekdays: [Int])
    /// Cada N minutos.
    case every(minutes: Int)

    public static let minimumInterval = 5

    /// Próxima ejecución estrictamente posterior a `date`; `nil` si ya no hay ninguna.
    public func next(after date: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case let .once(when):
            return when > date ? when : nil
        case let .every(minutes):
            return date.addingTimeInterval(TimeInterval(max(minutes, Self.minimumInterval) * 60))
        case let .daily(hour, minute, weekdays):
            var components = DateComponents()
            components.hour = hour
            components.minute = minute
            components.second = 0
            var cursor = date
            // Como mucho ocho saltos: una semana y el propio día.
            for _ in 0..<8 {
                guard let candidate = calendar.nextDate(after: cursor, matching: components,
                                                        matchingPolicy: .nextTime) else { return nil }
                if weekdays.isEmpty || weekdays.contains(Self.isoWeekday(candidate, calendar)) { return candidate }
                cursor = candidate
            }
            return nil
        }
    }

    /// 1 = lunes … 7 = domingo.
    static func isoWeekday(_ date: Date, _ calendar: Calendar) -> Int {
        (calendar.component(.weekday, from: date) + 5) % 7 + 1
    }

    /// Texto para la interfaz y para el agente: «Cada día a las 09:00».
    public func summary(calendar: Calendar = .current) -> String {
        switch self {
        case let .once(when):
            let f = DateFormatter()
            f.locale = L10n.locale
            f.timeZone = calendar.timeZone
            f.dateFormat = tr("d 'de' MMMM 'a las' HH:mm")
            return tr("Una vez, el %@", "\(f.string(from: when))")
        case let .every(minutes):
            if minutes % 60 == 0 { return minutes == 60 ? tr("Cada hora") : tr("Cada %@ horas", "\(minutes / 60)") }
            return tr("Cada %@ minutos", "\(minutes)")
        case let .daily(hour, minute, weekdays):
            let time = String(format: "%02d:%02d", hour, minute)
            let days = Set(weekdays)
            if days.isEmpty || days.count == 7 { return tr("Cada día a las %@", "\(time)") }
            if days == [1, 2, 3, 4, 5] { return tr("De lunes a viernes a las %@", "\(time)") }
            if days == [6, 7] { return tr("Sábados y domingos a las %@", "\(time)") }
            let names = ["lun", "mar", "mié", "jue", "vie", "sáb", "dom"].map { tr($0) }
            let list = days.sorted().filter { (1...7).contains($0) }.map { names[$0 - 1] }.joined(separator: ", ")
            return tr("Los %@ a las %@", "\(list)", "\(time)")
        }
    }
}

/// A quién va el resultado de una tarea cuando no es el propio usuario: una persona o un grupo de
/// su Telegram, al que se escribe desde su cuenta.
public struct TaskRecipient: Hashable, Codable, Sendable, Identifiable {
    public var id: Int64
    public var title: String
    /// «privado», «grupo» o «canal», como lo da Telegram.
    public var kind: String
    /// Alias público (sin @), si lo tiene.
    public var username: String?

    public init(id: Int64, title: String, kind: String = "privado", username: String? = nil) {
        self.id = id
        self.title = title
        self.kind = kind
        self.username = username
    }

    /// «Lucas Moreno (@lucas_mor82)».
    public var displayName: String { username.map { "\(title) (@\($0))" } ?? title }
}

public extension Array where Element == TaskRecipient {
    /// «Lucas Moreno y Anna», «Lucas, Anna y Equipo».
    var names: String {
        let titles = map { "«\($0.title)»" }
        guard titles.count > 1 else { return titles.first ?? "" }
        return titles.dropLast().joined(separator: ", ") + " " + tr("y") + " " + titles.last!
    }
}

public struct ScheduledTask: Identifiable, Hashable, Codable, Sendable {
    public var id: Int64?
    /// Lo que el agente debe hacer, con las palabras del usuario.
    public var instruction: String
    public var schedule: TaskSchedule
    public var enabled: Bool
    public var createdAt: Date
    public var nextRun: Date?
    public var lastRun: Date?
    /// Respuesta o error de la última ejecución.
    public var lastResult: String?
    /// Si los hay, el resultado se les envía a esas personas o grupos en vez de al usuario.
    public var recipients: [TaskRecipient]
    /// Lo que la tarea manda a sus destinatarios sale sin pedir confirmación en el Mac. Solo lo
    /// decide el usuario en la app; el agente no puede activarlo.
    public var sendWithoutAsking: Bool

    public init(id: Int64? = nil, instruction: String, schedule: TaskSchedule, enabled: Bool = true,
                createdAt: Date = Date(), nextRun: Date? = nil, lastRun: Date? = nil, lastResult: String? = nil,
                recipients: [TaskRecipient] = [], sendWithoutAsking: Bool = false) {
        self.recipients = recipients
        self.sendWithoutAsking = sendWithoutAsking
        self.id = id
        self.instruction = instruction
        self.schedule = schedule
        self.enabled = enabled
        self.createdAt = createdAt
        self.nextRun = nextRun
        self.lastRun = lastRun
        self.lastResult = lastResult
    }

    private enum CodingKeys: String, CodingKey {
        case id, instruction, schedule, enabled, createdAt, nextRun, lastRun, lastResult, recipients, sendWithoutAsking
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(Int64.self, forKey: .id)
        instruction = try c.decode(String.self, forKey: .instruction)
        schedule = try c.decode(TaskSchedule.self, forKey: .schedule)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        nextRun = try c.decodeIfPresent(Date.self, forKey: .nextRun)
        lastRun = try c.decodeIfPresent(Date.self, forKey: .lastRun)
        lastResult = try c.decodeIfPresent(String.self, forKey: .lastResult)
        recipients = try c.decodeIfPresent([TaskRecipient].self, forKey: .recipients) ?? []
        sendWithoutAsking = try c.decodeIfPresent(Bool.self, forKey: .sendWithoutAsking) ?? false
    }
}

/// Persistencia de las tareas programadas.
public protocol TaskStoring: Sendable {
    func tasks() throws -> [ScheduledTask]
    @discardableResult func addTask(_ task: ScheduledTask) throws -> ScheduledTask
    func updateTask(_ task: ScheduledTask) throws
    func deleteTask(id: Int64) throws
}

public enum TaskAction {
    public static let schedule: ActionID = "tasks.schedule"
    public static let cancel: ActionID = "tasks.cancel"
    public static let limit = 50

    public static let descriptors: [ActionDescriptor] = [
        .init(id: schedule, title: "Programar tareas",
              detail: "El agente crea tareas que se repiten sin que estés delante.", defaultRule: .allow),
        .init(id: cancel, title: "Cancelar tareas", defaultRule: .allow),
    ]
}


/// Un aviso por mensajes de Telegram: cuando llega algo a un chat (y, si se pide, con una palabra),
/// avisa al usuario por el bot o sigue una instrucción con lo que ha llegado.
public struct MessageWatch: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var chatID: Int64
    public var chatTitle: String
    /// Solo los mensajes que la contienen (sin distinguir mayúsculas ni tildes).
    public var keyword: String?
    /// Qué hacer con lo nuevo («resúmelo», «si piden algo, dímelo»). Sin ella, solo se avisa.
    public var instruction: String?
    public var enabled: Bool
    public var createdAt: Date
    public var lastFired: Date?

    public init(id: String = String(UUID().uuidString.prefix(8)).lowercased(), chatID: Int64, chatTitle: String,
                keyword: String? = nil, instruction: String? = nil, enabled: Bool = true, createdAt: Date = Date(),
                lastFired: Date? = nil) {
        self.id = id
        self.chatID = chatID
        self.chatTitle = chatTitle
        self.keyword = keyword
        self.instruction = instruction
        self.enabled = enabled
        self.createdAt = createdAt
        self.lastFired = lastFired
    }

    /// Si un mensaje de ese chat le interesa.
    public func matches(chatID: Int64, text: String) -> Bool {
        guard enabled, chatID == self.chatID else { return false }
        guard let keyword, !keyword.isEmpty else { return true }
        return text.range(of: keyword, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    /// Avisos activos a la vez, como mucho.
    public static let maxWatches = 20
    /// Segundos que se juntan los mensajes antes de avisar, para no avisar de uno en uno.
    public static let batchSeconds: TimeInterval = 60

    public static func load(_ store: SaySoStoring) -> [MessageWatch] {
        ((try? store.codableSetting(SettingsKey.messageWatches)) ?? nil) ?? []
    }

    public static func save(_ watches: [MessageWatch], _ store: SaySoStoring) {
        try? store.setCodableSetting(watches, for: SettingsKey.messageWatches)
    }
}

public extension SettingsKey {
    static let messageWatches = "telegram.watches"
    /// Leer en voz alta los avisos y las notificaciones de SaySo.
    static let speakAlerts = "alerts.speak"
    /// Cómo se avisa en el Mac (`AlertStyle`).
    static let alertStyle = "alerts.style"
    /// Tope de tokens (`TokenLimits` en JSON).
    static let tokenLimits = "budget.tokens"
    /// Último aviso o bloqueo por el tope, para no repetirlo: «warn-day-2026-11-21».
    static let budgetNotified = "budget.notified"
    /// «1»: las preguntas de permiso salen también por el bot, con botones.
    static let approveFromBot = "telegram.approveFromBot"
    /// «1»: tareas programadas y avisos por mensajes en pausa (/pause del bot).
    static let tasksPaused = "tasks.paused"
}


/// Cómo avisa SaySo en el Mac de los avisos de mensajes y de los trabajos terminados.
public enum AlertStyle: String, CaseIterable, Codable, Sendable {
    /// Notificación con el sonido del sistema.
    case sound
    /// Solo la notificación, en silencio.
    case silent
    /// Nada en pantalla: el aviso sigue llegando al bot y queda en Registros.
    case none
}
