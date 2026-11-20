import AppKit
import EventKit
import Foundation
import SaySoCore
import UserNotifications

public enum MacScriptError: Error, LocalizedError, Sendable, Equatable {
    case invalidURL(String)
    case accessDenied(String)
    case scriptFailed(String)
    case notAvailable(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidURL(url): return tr("Solo se pueden abrir enlaces http o https: %@", "\(url)")
        case let .accessDenied(what): return tr("SaySo no tiene acceso a %@. Actívalo en Ajustes del Sistema → Privacidad y seguridad.", "\(what)")
        case let .scriptFailed(message): return tr("El script del Mac ha fallado: %@", "\(message)")
        case let .notAvailable(message): return message
        }
    }
}

/// Ejecuta la lista cerrada de scripts del Mac. Cada llamada pasa por el motor de permisos.
/// No admite AppleScript ni shell arbitrarios: los textos del usuario van siempre como argumentos.
public final class MacScriptRunner: MacScriptRunning {
    private let broker: PermissionBrokering

    public init(broker: PermissionBrokering) {
        self.broker = broker
    }

    public func run(_ call: MacScriptCall, origin: String?) async throws -> String {
        // Valida y normaliza antes de preguntar: el diálogo muestra los valores reales.
        var call = try Self.validated(call)
        // El diálogo enseña el texto real del recordatorio, no el que diga el modelo.
        if case let .changeReminder(id, _, change) = call {
            call = .changeReminder(id: id, title: try await Self.reminderTitle(id: id), change: change)
        }
        if case let .moveEvent(id, _, start, end) = call {
            call = .moveEvent(id: id, title: try await Self.event(id: id).title ?? "Sin título", start: start, end: end)
        }
        if case let .deleteEvent(id, _) = call {
            call = .deleteEvent(id: id, title: try await Self.event(id: id).title ?? "Sin título")
        }
        let checked = call
        let request = Self.request(for: checked, origin: origin)
        return try await broker.run(request) {
            try await Self.perform(checked)
        }
    }

    // MARK: - Validación y resumen

    /// Acota el volumen a 0…100 y rechaza enlaces que no sean http/https.
    static func validated(_ call: MacScriptCall) throws -> MacScriptCall {
        switch call {
        case let .volume(percent):
            return .volume(percent: min(100, max(0, percent)))
        case let .createEvent(draft):
            guard draft.end > draft.start || draft.allDay else { throw MacScriptError.scriptFailed("el evento tiene que terminar después de empezar") }
            return call
        case let .moveEvent(_, _, start, end):
            guard end > start else { throw MacScriptError.scriptFailed("el evento tiene que terminar después de empezar") }
            return call
        case let .openURL(url):
            guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  url.host?.isEmpty == false else {
                throw MacScriptError.invalidURL(url.absoluteString)
            }
            return call
        default:
            return call
        }
    }

    static func request(for call: MacScriptCall, origin: String?) -> ActionRequest {
        let summary: String
        var params: [String: String] = [:]
        switch call {
        case let .notification(title, body):
            summary = tr("Mostrar la notificación «%@»: %@", "\(title)", "\(body)")
            params = ["título": title, "texto": body]
        case let .volume(percent):
            summary = tr("Poner el volumen al %@ %%", "\(percent)")
            params = ["volumen": "\(percent)"]
        case let .reminder(title, due):
            if let due {
                let when = due.formatted(date: .abbreviated, time: .shortened)
                summary = tr("Añadir el recordatorio «%@» para %@", "\(title)", "\(when)")
                params = ["título": title, "fecha": when]
            } else {
                summary = tr("Añadir el recordatorio «%@»", "\(title)")
                params = ["título": title]
            }
        case let .note(title, body):
            summary = tr("Crear la nota «%@»: %@", "\(title)", "\(body)")
            params = ["título": title, "texto": body]
        case let .calendar(start, days):
            summary = Self.calendarRange(start: start, days: days)
        case let .createEvent(draft):
            summary = tr("Crear el evento «%@» el %@", draft.title, Self.when(draft.start, draft.end, allDay: draft.allDay))
            params = ["título": draft.title, "cuándo": Self.when(draft.start, draft.end, allDay: draft.allDay)]
            if let place = draft.location, !place.isEmpty { params["lugar"] = place }
            if let name = draft.calendar, !name.isEmpty { params["calendario"] = name }
        case let .moveEvent(_, title, start, end):
            summary = tr("Mover el evento «%@» al %@", title, Self.when(start, end, allDay: false))
            params = ["título": title, "cuándo": Self.when(start, end, allDay: false)]
        case let .deleteEvent(_, title):
            summary = tr("Borrar el evento «%@»", title)
            params = ["título": title]
        case let .reminders(includeCompleted):
            summary = includeCompleted ? tr("Leer los recordatorios, también los completados") : tr("Leer los recordatorios pendientes")
        case let .changeReminder(_, title, change):
            switch change {
            case .complete: summary = tr("Marcar como hecho el recordatorio «%@»", "\(title)")
            case .uncomplete: summary = tr("Volver a dejar pendiente el recordatorio «%@»", "\(title)")
            case .delete: summary = tr("Borrar el recordatorio «%@»", "\(title)")
            }
            params = ["título": title]
        case let .openURL(url):
            summary = tr("Abrir %@", "\(url.absoluteString)")
            params = ["enlace": url.absoluteString]
        }
        return ActionRequest(action: call.script.action, summary: summary, parameters: params, origin: origin)
    }

    // MARK: - Ejecución

    private static func perform(_ call: MacScriptCall) async throws -> String {
        switch call {
        case let .notification(title, body):
            try await notify(title: title, body: body)
            return "Notificación mostrada."
        case let .volume(percent):
            try await osascript(["on run argv", "set volume output volume ((item 1 of argv) as integer)", "end run"],
                                arguments: ["\(percent)"])
            return "Volumen al \(percent) %."
        case let .reminder(title, due):
            return try await addReminder(title: title, due: due)
        case let .note(title, body):
            // AppleScript fijo; título y cuerpo llegan como argumentos. Notas espera HTML en el cuerpo.
            try await osascript([
                "on run argv",
                "tell application \"Notes\" to make new note with properties {name:(item 1 of argv), body:(item 2 of argv)}",
                "end run",
            ], arguments: [title, "<h1>\(html(title))</h1><div>\(html(body))</div>"])
            return "Nota «\(title)» creada en Notas."
        case let .calendar(start, days):
            return try await calendarEvents(start: start, days: days)
        case let .reminders(includeCompleted):
            return try await listReminders(includeCompleted: includeCompleted)
        case let .createEvent(draft):
            return try await createEvent(draft)
        case let .moveEvent(id, _, start, end):
            return try await moveEvent(id: id, start: start, end: end)
        case let .deleteEvent(id, _):
            return try await deleteEvent(id: id)
        case let .changeReminder(id, _, change):
            return try await changeReminder(id: id, change: change)
        case let .openURL(url):
            let opened = await MainActor.run { NSWorkspace.shared.open(url) }
            guard opened else { throw MacScriptError.scriptFailed("no se pudo abrir \(url.absoluteString)") }
            return "Abierto \(url.absoluteString)."
        }
    }

    private static func html(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\n", with: "<br>")
    }

    private static func notify(title: String, body: String) async throws {
        guard Bundle.main.bundleIdentifier != nil else {
            // Sin paquete .app (`swift run`) UserNotifications no funciona: se usa osascript.
            try await osascript(["on run argv", "display notification (item 2 of argv) with title (item 1 of argv)", "end run"],
                                arguments: [title, body])
            return
        }
        let center = UNUserNotificationCenter.current()
        let granted = try await center.requestAuthorization(options: [.alert, .sound])
        guard granted else { throw MacScriptError.accessDenied("las notificaciones") }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        try await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    private static func addReminder(title: String, due: Date?) async throws -> String {
        let store = EKEventStore()
        guard try await store.requestFullAccessToReminders() else {
            throw MacScriptError.accessDenied("Recordatorios")
        }
        guard let list = store.defaultCalendarForNewReminders() else {
            throw MacScriptError.notAvailable("No hay una lista de recordatorios por defecto.")
        }
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.calendar = list
        if let due {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: due)
            reminder.addAlarm(EKAlarm(absoluteDate: due))
        }
        try store.save(reminder, commit: true)
        return "Recordatorio «\(title)» añadido a «\(list.title)»."
    }

    private static func remindersStore() async throws -> EKEventStore {
        let store = EKEventStore()
        guard try await store.requestFullAccessToReminders() else { throw MacScriptError.accessDenied("Recordatorios") }
        return store
    }

    /// Como mucho se enseñan estos recordatorios de golpe.
    static let maxReminders = 100

    private static func listReminders(includeCompleted: Bool) async throws -> String {
        let store = try await remindersStore()
        let predicate = includeCompleted ? store.predicateForReminders(in: nil)
            : store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        let found: [EKReminder] = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { continuation.resume(returning: $0 ?? []) }
        }
        let items = found.map { reminder in
            ReminderLine(id: reminder.calendarItemIdentifier, title: reminder.title ?? "Sin título",
                         due: reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) },
                         list: reminder.calendar?.title ?? "", done: reminder.isCompleted)
        }
        return format(reminders: items)
    }

    struct ReminderLine: Sendable {
        var id: String
        var title: String
        var due: Date?
        var list: String
        var done: Bool
    }

    /// Una línea por recordatorio, con el identificador que piden las demás acciones. Los que tienen
    /// fecha primero, por fecha.
    static func format(reminders: [ReminderLine]) -> String {
        guard !reminders.isEmpty else { return "No hay recordatorios." }
        let sorted = reminders.sorted {
            switch ($0.due, $1.due) {
            case let (a?, b?): return a < b
            case (_?, nil): return true
            case (nil, _?): return false
            default: return $0.title.localizedCompare($1.title) == .orderedAscending
            }
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_ES")
        f.dateFormat = "EEE d MMM HH:mm"
        var lines = sorted.prefix(maxReminders).map { item in
            var line = "id \(item.id) · \(item.done ? "✓ " : "")\(item.title)"
            if let due = item.due { line += " · \(f.string(from: due))" }
            if !item.list.isEmpty { line += " · lista «\(item.list)»" }
            return line
        }
        if sorted.count > maxReminders { lines.append("(y \(sorted.count - maxReminders) más)") }
        return lines.joined(separator: "\n")
    }

    private static func reminderTitle(id: String) async throws -> String {
        let store = try await remindersStore()
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
            throw MacScriptError.notAvailable("No hay ningún recordatorio con ese id: vuelve a leer la lista.")
        }
        return reminder.title ?? "Sin título"
    }

    private static func changeReminder(id: String, change: ReminderChange) async throws -> String {
        let store = try await remindersStore()
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
            throw MacScriptError.notAvailable("No hay ningún recordatorio con ese id: vuelve a leer la lista.")
        }
        let title = reminder.title ?? "Sin título"
        switch change {
        case .complete, .uncomplete:
            reminder.isCompleted = change == .complete
            try store.save(reminder, commit: true)
            return change == .complete ? "Recordatorio «\(title)» marcado como hecho." : "Recordatorio «\(title)» pendiente otra vez."
        case .delete:
            try store.remove(reminder, commit: true)
            return "Recordatorio «\(title)» borrado."
        }
    }

    // MARK: - Cambiar el calendario

    /// «sáb 22 nov, 10:00–11:00» o «sáb 22 nov (todo el día)».
    static func when(_ start: Date, _ end: Date, allDay: Bool) -> String {
        let day = start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(L10n.locale))
        if allDay { return tr("%@ (todo el día)", day) }
        return "\(day), \(start.formatted(date: .omitted, time: .shortened))–\(end.formatted(date: .omitted, time: .shortened))"
    }

    private static func eventsStore() async throws -> EKEventStore {
        let store = EKEventStore()
        guard try await store.requestFullAccessToEvents() else { throw MacScriptError.accessDenied("Calendario") }
        return store
    }

    private static func event(id: String, in given: EKEventStore? = nil) async throws -> EKEvent {
        let store: EKEventStore
        if let given { store = given } else { store = try await eventsStore() }
        guard let event = store.event(withIdentifier: id) else {
            throw MacScriptError.notAvailable("No hay ningún evento con ese id: vuelve a leer el calendario.")
        }
        return event
    }

    private static func createEvent(_ draft: CalendarEventDraft) async throws -> String {
        let store = try await eventsStore()
        let writable = store.calendars(for: .event).filter(\.allowsContentModifications)
        let calendar: EKCalendar?
        if let name = draft.calendar, !name.isEmpty {
            guard let named = writable.first(where: { $0.title.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
                throw MacScriptError.notAvailable("No hay ningún calendario «\(name)» en el que se pueda escribir. Hay: \(writable.map(\.title).joined(separator: ", ")).")
            }
            calendar = named
        } else {
            calendar = store.defaultCalendarForNewEvents
        }
        guard let calendar else { throw MacScriptError.notAvailable("No hay un calendario por defecto.") }
        let event = EKEvent(eventStore: store)
        event.title = draft.title
        event.isAllDay = draft.allDay
        event.startDate = draft.allDay ? Calendar.current.startOfDay(for: draft.start) : draft.start
        event.endDate = draft.allDay ? (Calendar.current.date(byAdding: .day, value: 1, to: event.startDate) ?? draft.end) : draft.end
        event.location = draft.location
        event.calendar = calendar
        try store.save(event, span: .thisEvent, commit: true)
        return "Evento «\(draft.title)» creado en «\(calendar.title)» (id \(event.eventIdentifier ?? "-"))."
    }

    private static func moveEvent(id: String, start: Date, end: Date) async throws -> String {
        let store = try await eventsStore()
        let event = try await event(id: id, in: store)
        event.startDate = start
        event.endDate = end
        // Solo esta vez si se repite: mover toda la serie sería otra cosa.
        try store.save(event, span: .thisEvent, commit: true)
        return "Evento «\(event.title ?? "Sin título")» movido al \(when(start, end, allDay: false))."
    }

    private static func deleteEvent(id: String) async throws -> String {
        let store = try await eventsStore()
        let event = try await event(id: id, in: store)
        let title = event.title ?? "Sin título"
        try store.remove(event, span: .thisEvent, commit: true)
        return "Evento «\(title)» borrado."
    }

    /// Como mucho se leen dos meses de golpe.
    public static let maxCalendarDays = 62

    private static func calendarEvents(start: Date, days: Int) async throws -> String {
        let store = EKEventStore()
        guard try await store.requestFullAccessToEvents() else {
            throw MacScriptError.accessDenied("Calendario")
        }
        let cal = Calendar.current
        let from = cal.startOfDay(for: start)
        let count = min(max(days, 1), maxCalendarDays)
        guard let end = cal.date(byAdding: .day, value: count, to: from) else { return "Fecha no válida." }
        let events = store.events(matching: store.predicateForEvents(withStart: from, end: end, calendars: nil))
            .sorted { $0.startDate < $1.startDate }
        return format(events: events.map { ($0.title ?? "Sin título", $0.startDate, $0.endDate, $0.isAllDay, $0.location) },
                      start: from, days: count, ids: events.map { $0.eventIdentifier ?? "" })
    }

    /// «Leer el calendario de hoy», «… del 21/11», «… del 21/11 al 27/11».
    static func calendarRange(start: Date, days: Int, now: Date = Date()) -> String {
        let cal = Calendar.current
        let day = start.formatted(.dateTime.day().month(.abbreviated))
        if days <= 1 {
            if cal.isDate(start, inSameDayAs: now) { return tr("Leer los eventos de hoy del calendario") }
            return tr("Leer los eventos del calendario del %@", day)
        }
        let last = (cal.date(byAdding: .day, value: days - 1, to: start) ?? start).formatted(.dateTime.day().month(.abbreviated))
        return tr("Leer los eventos del calendario del %@ al %@", day, last)
    }

    /// Lista legible: una línea por evento, con el día delante si se ha pedido más de uno.
    static func format(events: [(title: String, start: Date, end: Date, allDay: Bool, location: String?)],
                       start: Date = Calendar.current.startOfDay(for: Date()), days: Int = 1,
                       now: Date = Date(), ids: [String] = []) -> String {
        let cal = Calendar.current
        let today = days <= 1 && cal.isDate(start, inSameDayAs: now)
        let dayName: (Date) -> String = { $0.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(Locale(identifier: "es_ES"))) }
        let range = days <= 1 ? dayName(start)
            : "\(dayName(start)) – \(dayName(cal.date(byAdding: .day, value: days - 1, to: start) ?? start))"
        guard !events.isEmpty else { return today ? "No hay eventos hoy." : "No hay eventos (\(range))." }
        let lines = events.enumerated().map { index, e -> String in
            let when = e.allDay ? "Todo el día"
                : "\(e.start.formatted(date: .omitted, time: .shortened))–\(e.end.formatted(date: .omitted, time: .shortened))"
            let place = e.location.flatMap { $0.isEmpty ? nil : " (\($0))" } ?? ""
            let prefix = days > 1 ? "\(dayName(e.start)), " : ""
            // El id es el que piden mover y borrar.
            let id = index < ids.count && !ids[index].isEmpty ? " · id \(ids[index])" : ""
            return "- \(prefix)\(when): \(e.title)\(place)\(id)"
        }
        return (today ? "Eventos de hoy:\n" : "Eventos (\(range)):\n") + lines.joined(separator: "\n")
    }

    // MARK: - osascript

    /// Ejecuta un AppleScript fijo; `arguments` llegan a `on run argv` sin interpolarse en el código.
    private static func osascript(_ lines: [String], arguments: [String]) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        // `--` separa opciones de argumentos: un texto que empiece por «-» no se toma como opción.
        process.arguments = lines.flatMap { ["-e", $0] } + ["--"] + arguments
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = FileHandle.nullDevice

        let status: Int32 = try await withCheckedThrowingContinuation { cont in
            process.terminationHandler = { cont.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch {
                process.terminationHandler = nil
                cont.resume(throwing: error)
            }
        }
        guard status == 0 else {
            let data = errPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw MacScriptError.scriptFailed(message.isEmpty ? "código \(status)" : message)
        }
    }
}
