import SaySoCore

/// Ideas de tareas para empezar. Al elegir una, rellena el formulario de «Nueva tarea»: el usuario
/// la revisa y la programa él. Solo usan lo que el agente ya sabe hacer con los permisos que tiene.
struct TaskTemplate: Identifiable {
    let id: String
    let icon: String
    let title: String
    /// Instrucción en español; se traduce al rellenar el formulario.
    let instruction: String
    let schedule: TaskSchedule

    var task: ScheduledTask { ScheduledTask(instruction: tr(instruction), schedule: schedule) }

    static let all: [TaskTemplate] = [
        TaskTemplate(id: "morning", icon: "sun.max", title: "Resumen de la mañana",
                     instruction: "Envíame un resumen de mi día: los eventos de hoy en el calendario, los recordatorios pendientes y los mensajes importantes de Telegram que no he leído.",
                     schedule: .daily(hour: 8, minute: 30, weekdays: [1, 2, 3, 4, 5])),
        TaskTemplate(id: "unread", icon: "bubble.left.and.bubble.right", title: "Chats sin leer",
                     instruction: "Resume los chats de Telegram con mensajes sin leer y dime cuáles esperan una respuesta mía.",
                     schedule: .daily(hour: 20, minute: 0, weekdays: [])),
        TaskTemplate(id: "week", icon: "calendar", title: "Plan de la semana",
                     instruction: "Envíame los eventos del calendario de esta semana y los recordatorios que vencen en los próximos siete días.",
                     schedule: .daily(hour: 9, minute: 0, weekdays: [1])),
        TaskTemplate(id: "overdue", icon: "checklist", title: "Recordatorios vencidos",
                     instruction: "Mira mis recordatorios vencidos y pregúntame cuáles marco como hechos y cuáles muevo a otro día.",
                     schedule: .daily(hour: 18, minute: 0, weekdays: [1, 2, 3, 4, 5])),
        TaskTemplate(id: "cleanup", icon: "externaldrive", title: "Limpiar la máquina Linux",
                     instruction: "En la máquina Linux, borra las cachés y los archivos temporales que ya no hagan falta y dime cuánto espacio se ha liberado.",
                     schedule: .daily(hour: 10, minute: 0, weekdays: [7])),
    ]

    /// Las que aún no están programadas con el mismo texto.
    static func unused(given tasks: [ScheduledTask]) -> [TaskTemplate] {
        let existing = Set(tasks.map(\.instruction))
        return all.filter { !existing.contains(tr($0.instruction)) && !existing.contains($0.instruction) }
    }
}
