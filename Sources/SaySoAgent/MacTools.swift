import Foundation
import SaySoCore

// Herramientas del Mac: una por caso de `MacScriptCall`. Validan y delegan en
// `MacScriptRunning`, que ya pasa por el motor de permisos.

public enum MacTools {
    /// Las herramientas del Mac.
    public static func all(runner: MacScriptRunning) -> [AgentTool] {
        [
            MacNotificationTool(runner: runner), MacVolumeTool(runner: runner), MacReminderTool(runner: runner),
            MacRemindersTool(runner: runner), MacChangeReminderTool(runner: runner),
            MacCalendarTool(runner: runner), MacCalendarEventTool(runner: runner),
            MacOpenURLTool(runner: runner),
        ] + notes(runner: runner)
    }

    /// Notas de Apple no tiene API: solo se llega con AppleScript, que la tienda no permite.
    private static func notes(runner: MacScriptRunning) -> [AgentTool] {
        #if APPSTORE
        []
        #else
        [MacNoteTool(runner: runner), MacNotesTool(runner: runner)]
        #endif
    }

    /// Fecha ISO 8601 con o sin zona; sin zona se toma la local.
    static func parseDate(_ text: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: text) { return d }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: text) { return d }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            f.dateFormat = format
            if let d = f.date(from: text) { return d }
        }
        return nil
    }
}

public struct MacNotificationTool: AgentTool {
    let runner: MacScriptRunning
    public init(runner: MacScriptRunning) { self.runner = runner }
    public var name: String { "mac_notification" }
    public var description: String { "Muestra una notificación en el Mac del usuario." }
    public var inputSchema: JSONValue {
        .objectSchema(["title": .property("string", "Título breve"), "body": .property("string", "Texto de la notificación")],
                      required: ["title", "body"])
    }
    public func call(input: JSONValue, context: ToolContext) async throws -> String {
        let title = try input.requiredString("title", maxLength: 200)
        let body = try input.requiredString("body", maxLength: 1000)
        return try await runner.run(.notification(title: title, body: body), origin: context.origin)
    }
}

public struct MacVolumeTool: AgentTool {
    let runner: MacScriptRunning
    public init(runner: MacScriptRunning) { self.runner = runner }
    public var name: String { "mac_volume" }
    public var description: String { "Cambia el volumen de salida del Mac (0 a 100)." }
    public var inputSchema: JSONValue {
        .objectSchema(["percent": ["type": "integer", "minimum": 0, "maximum": 100, "description": "Volumen en porcentaje"]],
                      required: ["percent"])
    }
    public func call(input: JSONValue, context: ToolContext) async throws -> String {
        guard let percent = input["percent"]?.intValue else { throw ToolInputError("«percent» debe ser un entero.") }
        guard (0...100).contains(percent) else { throw ToolInputError("«percent» debe estar entre 0 y 100.") }
        return try await runner.run(.volume(percent: percent), origin: context.origin)
    }
}

public struct MacReminderTool: AgentTool {
    let runner: MacScriptRunning
    public init(runner: MacScriptRunning) { self.runner = runner }
    public var name: String { "mac_reminder" }
    public var description: String {
        "Añade un recordatorio en la app Recordatorios del Mac (se sincroniza con el iPhone y avisa allí). " +
        "Úsala cuando el usuario quiere un recordatorio para sí mismo («recuérdame llamar a las cinco»). " +
        "Para algo que tengas que hacer tú a una hora usa schedule_task; para un mensaje a otra persona a una hora, " +
        "telegram_send_message con «send_at»."
    }
    public var inputSchema: JSONValue {
        .objectSchema([
            "title": .property("string", "Texto del recordatorio"),
            "due": .property("string", "Fecha y hora opcional en ISO 8601, p. ej. 2026-11-19T09:00:00"),
        ], required: ["title"])
    }
    public func call(input: JSONValue, context: ToolContext) async throws -> String {
        let title = try input.requiredString("title", maxLength: 500)
        var due: Date?
        if let raw = try input.optionalString("due", maxLength: 64) {
            guard let d = MacTools.parseDate(raw) else { throw ToolInputError("«due» no es una fecha ISO 8601 válida.") }
            due = d
        }
        return try await runner.run(.reminder(title: title, due: due), origin: context.origin)
    }
}

public struct MacRemindersTool: AgentTool {
    let runner: MacScriptRunning
    public init(runner: MacScriptRunning) { self.runner = runner }
    public var name: String { "mac_reminders" }
    public var description: String {
        "Lee los recordatorios de la app Recordatorios del Mac: pendientes por defecto, o también los hechos. " +
            "Cada uno lleva su id, que es el que pide mac_reminder_update para completarlo o borrarlo."
    }
    public var inputSchema: JSONValue {
        .objectSchema(["include_completed": ["type": "boolean", "description": "También los ya hechos (no por defecto)"]])
    }
    public func call(input: JSONValue, context: ToolContext) async throws -> String {
        try await runner.run(.reminders(includeCompleted: input["include_completed"]?.boolValue ?? false), origin: context.origin)
    }
}

public struct MacChangeReminderTool: AgentTool {
    let runner: MacScriptRunning
    public init(runner: MacScriptRunning) { self.runner = runner }
    public var name: String { "mac_reminder_update" }
    public var description: String {
        "Marca como hecho (complete), vuelve a dejar pendiente (uncomplete) o borra (delete) un recordatorio del Mac. " +
            "Necesita su id: léelo antes con mac_reminders. Pon en «title» su texto, para la confirmación."
    }
    public var inputSchema: JSONValue {
        .objectSchema([
            "id": .property("string", "El id que da mac_reminders"),
            "title": .property("string", "El texto del recordatorio"),
            "action": ["type": "string", "enum": ["complete", "uncomplete", "delete"]],
        ], required: ["id", "title", "action"])
    }
    public func call(input: JSONValue, context: ToolContext) async throws -> String {
        let id = try input.requiredString("id", maxLength: 200).trimmingCharacters(in: .whitespaces)
        let title = try input.requiredString("title", maxLength: 500)
        guard let change = input["action"]?.stringValue.flatMap(ReminderChange.init(rawValue:)) else {
            throw ToolInputError("«action» tiene que ser complete, uncomplete o delete.")
        }
        return try await runner.run(.changeReminder(id: id, title: title, change: change), origin: context.origin)
    }
}

public struct MacNoteTool: AgentTool {
    let runner: MacScriptRunning
    public init(runner: MacScriptRunning) { self.runner = runner }
    public var name: String { "mac_note" }
    public var description: String { "Crea una nota en la app Notas del Mac." }
    public var inputSchema: JSONValue {
        .objectSchema(["title": .property("string", "Título de la nota"), "body": .property("string", "Contenido")],
                      required: ["title", "body"])
    }
    public func call(input: JSONValue, context: ToolContext) async throws -> String {
        let title = try input.requiredString("title", maxLength: 200)
        let body = try input.requiredString("body", maxLength: 20000)
        return try await runner.run(.note(title: title, body: body), origin: context.origin)
    }
}

public struct MacNotesTool: AgentTool {
    let runner: MacScriptRunning
    public init(runner: MacScriptRunning) { self.runner = runner }
    public var name: String { "mac_notes" }
    public var description: String {
        "Busca en la app Notas del Mac (action «search» con «query»: notas cuyo título o texto lo contiene, con su id) " +
            "y lee una nota entera (action «read» con el «id» que da la búsqueda)."
    }
    public var inputSchema: JSONValue {
        .objectSchema([
            "action": ["type": "string", "enum": ["search", "read"]],
            "query": .property("string", "Para search: texto a buscar"),
            "id": .property("string", "Para read: el id de la nota"),
        ], required: ["action"])
    }
    public func call(input: JSONValue, context: ToolContext) async throws -> String {
        switch input["action"]?.stringValue {
        case "search":
            let query = try input.requiredString("query", maxLength: 200).trimmingCharacters(in: .whitespaces)
            guard query.count >= 2 else { throw ToolInputError("«query» necesita al menos dos caracteres.") }
            return try await runner.run(.searchNotes(query: query), origin: context.origin)
        case "read":
            let id = try input.requiredString("id", maxLength: 300).trimmingCharacters(in: .whitespaces)
            guard id.hasPrefix("x-coredata://") else { throw ToolInputError("«id» es el que da mac_notes con action search.") }
            return try await runner.run(.readNote(id: id), origin: context.origin)
        default:
            throw ToolInputError("«action» tiene que ser search o read.")
        }
    }
}

public struct MacCalendarTool: AgentTool {
    let runner: MacScriptRunning
    let now: @Sendable () -> Date
    public init(runner: MacScriptRunning, now: @escaping @Sendable () -> Date = { Date() }) {
        self.runner = runner
        self.now = now
    }
    public var name: String { "mac_calendar" }
    public var description: String {
        "Lee los eventos del calendario del Mac de cualquier día o rango: hoy (sin parámetros), un día concreto " +
            "(«date») o varios días seguidos («days», hasta 62). Para «mañana» o «el viernes» calcula la fecha con " +
            "la de hoy. Para «mi próximo evento», pide desde hoy con days=30 y quédate con el primero que aún no " +
            "haya pasado. También vale para días anteriores. Cada evento lleva su id, que es el que piden " +
            "mover y borrar en mac_calendar_event."
    }
    public var inputSchema: JSONValue {
        .objectSchema([
            "date": .property("string", "Primer día, AAAA-MM-DD. Vacío: hoy"),
            "days": .property("integer", "Cuántos días desde «date», de 1 a 62 (por defecto 1)"),
        ])
    }
    public func call(input: JSONValue, context: ToolContext) async throws -> String {
        var start = now()
        if let raw = try input.optionalString("date", maxLength: 32)?.trimmingCharacters(in: .whitespaces), !raw.isEmpty {
            guard let date = MacTools.parseDate(raw) else {
                throw ToolInputError("«date» debe tener el formato AAAA-MM-DD.")
            }
            start = date
        }
        let days = input["days"]?.intValue ?? 1
        guard (1...MacScriptRunnerLimits.maxCalendarDays).contains(days) else {
            throw ToolInputError("«days» va de 1 a \(MacScriptRunnerLimits.maxCalendarDays).")
        }
        return try await runner.run(.calendar(start: start, days: days), origin: context.origin)
    }
}

public struct MacCalendarEventTool: AgentTool {
    let runner: MacScriptRunning
    public init(runner: MacScriptRunning) { self.runner = runner }
    public var name: String { "mac_calendar_event" }
    public var description: String {
        "Cambia el calendario del Mac: «create» crea un evento (title, start, end; all_day para todo el día; " +
            "location y calendar opcionales); «move» le cambia la hora a uno (id, start, end); «delete» lo borra (id). " +
            "Los id salen de mac_calendar. Fechas en ISO 8601 con la hora local, p. ej. 2026-11-22T10:00. Si el " +
            "evento se repite, solo cambia esa vez."
    }
    public var inputSchema: JSONValue {
        .objectSchema([
            "action": ["type": "string", "enum": ["create", "move", "delete"]],
            "id": .property("string", "Para move y delete: el id que da mac_calendar"),
            "title": .property("string", "Para create"),
            "start": .property("string", "Inicio, ISO 8601"),
            "end": .property("string", "Fin, ISO 8601 (por defecto, una hora después del inicio)"),
            "all_day": ["type": "boolean", "description": "Evento de todo el día"],
            "location": .property("string", "Lugar (opcional)"),
            "calendar": .property("string", "Nombre del calendario (opcional)"),
        ], required: ["action"])
    }

    func dates(_ input: JSONValue) throws -> (Date, Date) {
        guard let raw = try input.optionalString("start", maxLength: 64), let start = MacTools.parseDate(raw) else {
            throw ToolInputError("Falta «start» como fecha ISO 8601, p. ej. 2026-11-22T10:00.")
        }
        var end = start.addingTimeInterval(3600)
        if let raw = try input.optionalString("end", maxLength: 64) {
            guard let parsed = MacTools.parseDate(raw) else { throw ToolInputError("«end» no es una fecha ISO 8601 válida.") }
            end = parsed
        }
        guard end > start else { throw ToolInputError("«end» tiene que ser después de «start».") }
        return (start, end)
    }

    public func call(input: JSONValue, context: ToolContext) async throws -> String {
        switch input["action"]?.stringValue {
        case "create":
            let title = try input.requiredString("title", maxLength: 300)
            let allDay = input["all_day"]?.boolValue ?? false
            let (start, end) = try dates(input)
            let draft = CalendarEventDraft(title: title, start: start, end: end, allDay: allDay,
                                           location: try input.optionalString("location", maxLength: 300),
                                           calendar: try input.optionalString("calendar", maxLength: 100))
            return try await runner.run(.createEvent(draft), origin: context.origin)
        case "move":
            let id = try input.requiredString("id", maxLength: 300)
            let (start, end) = try dates(input)
            return try await runner.run(.moveEvent(id: id, title: "", start: start, end: end), origin: context.origin)
        case "delete":
            let id = try input.requiredString("id", maxLength: 300)
            return try await runner.run(.deleteEvent(id: id, title: ""), origin: context.origin)
        default:
            throw ToolInputError("«action» tiene que ser create, move o delete.")
        }
    }
}

/// Límites del calendario, para la herramienta (el módulo del Mac no depende del agente).
enum MacScriptRunnerLimits {
    static let maxCalendarDays = 62
}

public struct MacOpenURLTool: AgentTool {
    let runner: MacScriptRunning
    public init(runner: MacScriptRunning) { self.runner = runner }
    public var name: String { "mac_open_url" }
    public var description: String { "Abre un enlace http(s) en el navegador del Mac." }
    public var inputSchema: JSONValue {
        .objectSchema(["url": .property("string", "Enlace http o https")], required: ["url"])
    }
    public func call(input: JSONValue, context: ToolContext) async throws -> String {
        let raw = try input.requiredString("url", maxLength: 4000)
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host?.isEmpty == false else {
            throw ToolInputError("«url» debe ser un enlace http o https válido.")
        }
        return try await runner.run(.openURL(url), origin: context.origin)
    }
}
