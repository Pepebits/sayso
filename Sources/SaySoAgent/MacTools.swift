import Foundation
import SaySoCore

// Herramientas del Mac: una por caso de `MacScriptCall`. Validan y delegan en
// `MacScriptRunning`, que ya pasa por el motor de permisos (ADR-0007).

public enum MacTools {
    /// Las seis herramientas del Mac.
    public static func all(runner: MacScriptRunning) -> [AgentTool] {
        [
            MacNotificationTool(runner: runner), MacVolumeTool(runner: runner), MacReminderTool(runner: runner),
            MacNoteTool(runner: runner), MacCalendarTool(runner: runner), MacOpenURLTool(runner: runner),
        ]
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
    public var description: String { "Añade un recordatorio en la app Recordatorios del Mac." }
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
            "haya pasado. También vale para días anteriores."
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
