import Foundation

// Contratos del motor de permisos.

/// Regla aplicada a una acción con efecto fuera de la VM.
public enum PermissionRule: String, Codable, CaseIterable, Sendable {
    case allow, ask, never
}

/// Identificador estable de una acción: `telegram.send`, `mac.volume`, `secret.use:GITHUB_TOKEN`…
public struct ActionID: Hashable, Codable, Sendable, RawRepresentable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }

    /// Ámbito: lo que hay antes del primer punto (`telegram`, `mac`, `secret`, `plugin`).
    public var scope: String { rawValue.split(separator: ".", maxSplits: 1).first.map(String.init) ?? rawValue }
}

/// Descripción de una acción para la interfaz y para su regla por defecto.
public struct ActionDescriptor: Identifiable, Hashable, Codable, Sendable {
    public var id: ActionID
    public var title: String
    public var detail: String
    public var defaultRule: PermissionRule

    public init(id: ActionID, title: String, detail: String = "", defaultRule: PermissionRule = .ask) {
        self.id = id
        self.title = title
        self.detail = detail
        self.defaultRule = defaultRule
    }
}

/// Petición concreta que llega al motor: la acción y sus parámetros reales.
public struct ActionRequest: Sendable, Hashable {
    public var action: ActionID
    /// Frase legible con la acción exacta («Enviar a Anna: "Llego en 5 min"»).
    public var summary: String
    /// Parámetros reales, mostrados en el diálogo de confirmación.
    public var parameters: [String: String]
    /// Tarea o chat que la originó.
    public var origin: String?
    /// El usuario la dejó autorizada de antemano (una tarea con «Enviar sin preguntar» hacia los
    /// destinatarios que él eligió). Se salta «Preguntar» y la revisión; «Nunca» sigue mandando.
    public var preapproved: Bool

    public init(action: ActionID, summary: String, parameters: [String: String] = [:], origin: String? = nil,
                preapproved: Bool = false) {
        self.action = action
        self.summary = summary
        self.parameters = parameters
        self.origin = origin
        self.preapproved = preapproved
    }
}

public enum ConfirmationResult: Sendable { case allowOnce, allowAlways, deny }

/// Muestra el diálogo «Preguntar» en el Mac. Nunca se confirma desde el chat.
public protocol ConfirmationPresenter: Sendable {
    func confirm(_ request: ActionRequest, descriptor: ActionDescriptor?) async -> ConfirmationResult
}

public enum ActivityOutcome: String, Codable, Sendable { case allowed, denied, failed }

/// Entrada del registro de actividad. Solo se añade.
public struct ActivityEntry: Identifiable, Hashable, Codable, Sendable {
    public var id: Int64?
    public var date: Date
    public var action: ActionID
    public var summary: String
    public var rule: PermissionRule
    public var outcome: ActivityOutcome
    public var origin: String?

    public init(id: Int64? = nil, date: Date = Date(), action: ActionID, summary: String,
                rule: PermissionRule, outcome: ActivityOutcome, origin: String? = nil) {
        self.id = id
        self.date = date
        self.action = action
        self.summary = summary
        self.rule = rule
        self.outcome = outcome
        self.origin = origin
    }
}

public enum PermissionError: Error, LocalizedError, Sendable, Equatable {
    case denied(ActionID, reason: String)

    public var errorDescription: String? {
        switch self {
        case let .denied(action, reason): return tr("Acción %@ denegada: %@", "\(action.rawValue)", "\(reason)")
        }
    }
}

/// Único punto de paso para toda acción con efecto fuera de la VM.
public protocol PermissionBrokering: Sendable {
    /// Aplica la regla, pregunta si hace falta, ejecuta y registra. Lanza `PermissionError.denied`.
    func run<T: Sendable>(_ request: ActionRequest, operation: @Sendable () async throws -> T) async throws -> T
}

// MARK: - Catálogo fijo de acciones

public enum TelegramAction {
    public static let listChats: ActionID = "telegram.listChats"
    public static let readMessages: ActionID = "telegram.readMessages"
    public static let sendMessages: ActionID = "telegram.sendMessages"
    public static let deleteMessages: ActionID = "telegram.deleteMessages"
    /// Contestar cuando el dueño menciona al bot en un chat donde el bot no está (Guest Mode).
    public static let guestReply: ActionID = "telegram.guestReply"
    public static let forward: ActionID = "telegram.forward"
    public static let edit: ActionID = "telegram.edit"
    public static let react: ActionID = "telegram.react"
    public static let markRead: ActionID = "telegram.markRead"
    public static let download: ActionID = "telegram.download"
    public static let pin: ActionID = "telegram.pin"
    public static let organize: ActionID = "telegram.organize"
    public static let contacts: ActionID = "telegram.contacts"
    public static let groups: ActionID = "telegram.groups"
    public static let vote: ActionID = "telegram.vote"
    public static let savedMessages: ActionID = "telegram.savedMessages"
    public static let watch: ActionID = "telegram.watch"

    public static let descriptors: [ActionDescriptor] = [
        .init(id: listChats, title: "Listar chats", defaultRule: .allow),
        .init(id: readMessages, title: "Leer mensajes", defaultRule: .allow),
        .init(id: sendMessages, title: "Enviar mensajes", defaultRule: .ask),
        .init(id: deleteMessages, title: "Eliminar mensajes", defaultRule: .ask),
        .init(id: forward, title: "Reenviar mensajes", detail: "Reenviar mensajes de un chat a otro.", defaultRule: .ask),
        .init(id: edit, title: "Editar mensajes", detail: "Cambiar el texto de un mensaje que enviaste.", defaultRule: .ask),
        .init(id: react, title: "Reaccionar a mensajes", detail: "Poner una reacción (👍, ❤️…) a un mensaje.", defaultRule: .allow),
        .init(id: markRead, title: "Marcar como leído", detail: "Dejar un chat sin mensajes pendientes.", defaultRule: .allow),
        .init(id: download, title: "Descargar archivos recibidos",
              detail: "Bajar a la máquina Linux una foto, audio o documento que te han enviado.", defaultRule: .allow),
        .init(id: pin, title: "Fijar mensajes", detail: "Fijar o desfijar un mensaje en un chat.", defaultRule: .ask),
        .init(id: organize, title: "Silenciar y archivar", detail: "Silenciar, archivar o recuperar un chat. Solo cambia lo que ves tú.",
              defaultRule: .allow),
        .init(id: contacts, title: "Contactos y bloqueos", detail: "Añadir a alguien a tus contactos, bloquearlo o desbloquearlo.",
              defaultRule: .ask),
        .init(id: groups, title: "Grupos", detail: "Crear grupos, añadir o quitar miembros, unirte por enlace o salir de un chat.",
              defaultRule: .ask),
        .init(id: vote, title: "Votar en encuestas", detail: "Responder a una encuesta de un chat.", defaultRule: .ask),
        .init(id: watch, title: "Avisos por mensajes",
              detail: "Crear avisos que se disparan cuando te escriben en un chat, y que pueden seguir una instrucción.",
              defaultRule: .ask),
        .init(id: savedMessages, title: "Mensajes guardados", detail: "Guardar notas en tus Mensajes guardados y leerlas.",
              defaultRule: .allow),
        // Apagado mientras no se elija otra cosa: la respuesta se publica en un chat ajeno.
        .init(id: "telegram.sendFile", title: "Enviarte archivos",
              detail: "Mandarte por el bot una imagen o un archivo del ordenador del agente.", defaultRule: .allow),
        .init(id: "telegram.sendWidget", title: "Enviarte widgets",
              detail: "Mandarte por el bot pequeñas páginas vivas: paneles, gráficos, tablas o calculadoras.", defaultRule: .allow),
        .init(id: guestReply, title: "Responder a menciones",
              detail: "Contestar cuando mencionas al bot en un chat donde no está. Sin memoria ni acceso a tus chats; puede buscar en la web y adjuntar una foto.",
              defaultRule: .never),
    ]
}

/// Lista cerrada de scripts del Mac. Añadir uno exige publicar una versión de la app.
public enum MacScript: String, CaseIterable, Codable, Sendable {
    case notification, volume, reminder, readReminders, changeReminder, note, readNotes, calendarToday, changeCalendar, openURL

    public var action: ActionID { ActionID("mac.\(rawValue)") }

    public var title: String {
        switch self {
        case .notification: return "Mostrar una notificación"
        case .volume: return "Cambiar el volumen"
        case .reminder: return "Añadir un recordatorio"
        case .readReminders: return "Leer los recordatorios"
        case .changeReminder: return "Completar o borrar recordatorios"
        case .note: return "Crear una nota"
        case .readNotes: return "Buscar y leer notas"
        case .calendarToday: return "Leer el calendario"
        case .changeCalendar: return "Crear, mover o borrar eventos"
        case .openURL: return "Abrir un enlace"
        }
    }

    public var descriptor: ActionDescriptor {
        // Leer el calendario y notificar no cambian nada: Permitir. El resto, Preguntar.
        let rule: PermissionRule = [.notification, .calendarToday, .readReminders].contains(self) ? .allow : .ask
        return ActionDescriptor(id: action, title: title, defaultRule: rule)
    }
}

/// Llamada a un script con parámetros ya validados por tipo.
public enum MacScriptCall: Sendable, Hashable {
    /// `sound`: con el sonido de aviso del sistema.
    case notification(title: String, body: String, sound: Bool = false)
    /// 0…100
    case volume(percent: Int)
    case reminder(title: String, due: Date?)
    case note(title: String, body: String)
    /// Eventos desde el inicio del día `start` durante `days` días.
    case calendar(start: Date, days: Int)
    /// Recordatorios pendientes (y, si se pide, también los completados).
    case reminders(includeCompleted: Bool)
    /// `id` es el que da la lista de recordatorios; `title`, para el diálogo de confirmación.
    case changeReminder(id: String, title: String, change: ReminderChange)
    /// Un evento nuevo en el calendario por defecto (o en el que se nombre).
    case createEvent(CalendarEventDraft)
    /// `id` es el que da la lista de eventos; `title`, para el diálogo de confirmación.
    case moveEvent(id: String, title: String, start: Date, end: Date)
    case deleteEvent(id: String, title: String)
    /// Notas cuyo título o texto contiene `query`.
    case searchNotes(query: String)
    /// El texto de una nota, por el id que da la búsqueda.
    case readNote(id: String)
    case openURL(URL)

    public var script: MacScript {
        switch self {
        case .notification: return .notification
        case .volume: return .volume
        case .reminder: return .reminder
        case .reminders: return .readReminders
        case .changeReminder: return .changeReminder
        case .createEvent, .moveEvent, .deleteEvent: return .changeCalendar
        case .searchNotes, .readNote: return .readNotes
        case .note: return .note
        case .calendar: return .calendarToday
        case .openURL: return .openURL
        }
    }
}

/// Lo que hace falta para crear un evento.
public struct CalendarEventDraft: Sendable, Hashable {
    public var title: String
    public var start: Date
    public var end: Date
    public var allDay: Bool
    public var location: String?
    /// Nombre del calendario; sin él, el de por defecto.
    public var calendar: String?

    public init(title: String, start: Date, end: Date, allDay: Bool = false, location: String? = nil, calendar: String? = nil) {
        self.title = title
        self.start = start
        self.end = end
        self.allDay = allDay
        self.location = location
        self.calendar = calendar
    }
}

/// Qué se le hace a un recordatorio.
public enum ReminderChange: String, Sendable, Hashable, CaseIterable {
    case complete, uncomplete, delete
}

/// Ejecuta scripts del Mac pasando siempre por el motor de permisos.
public protocol MacScriptRunning: Sendable {
    /// Devuelve un texto con el resultado para el agente.
    func run(_ call: MacScriptCall, origin: String?) async throws -> String
}
