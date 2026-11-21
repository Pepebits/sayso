import Foundation
import SaySoCore

/// Herramientas con las que el agente programa tareas.
public enum TaskTools {
    public static func all(tasks: TaskStoring, broker: PermissionBrokering, userAPI: TelegramUserAPI? = nil,
                           now: @escaping @Sendable () -> Date = { Date() }) -> [AgentTool] {
        [ScheduleTaskTool(tasks: tasks, broker: broker, userAPI: userAPI, now: now), ListTasksTool(tasks: tasks),
         CancelTaskTool(tasks: tasks, broker: broker)]
    }

    static func line(_ task: ScheduledTask) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_ES")
        f.dateFormat = "d MMM HH:mm"
        let next = task.enabled ? (task.nextRun.map { "próxima: \(f.string(from: $0))" } ?? "sin próxima ejecución") : "en pausa"
        let to = task.recipients.isEmpty ? "" : " · para " + task.recipients.names
        return "#\(task.id ?? 0) · \(task.schedule.summary()) · \(next)\(to) · \(task.instruction)"
    }

    /// Interpreta los parámetros de `schedule_task`.
    static func schedule(from input: JSONValue, now: Date, calendar: Calendar = .current) throws -> TaskSchedule {
        func time() throws -> (Int, Int) {
            let raw = try input.requiredString("time", maxLength: 5)
            let parts = raw.split(separator: ":").compactMap { Int($0) }
            guard parts.count == 2, (0...23).contains(parts[0]), (0...59).contains(parts[1]) else {
                throw ToolInputError("«time» debe tener el formato HH:MM en 24 horas.")
            }
            return (parts[0], parts[1])
        }
        switch try input.requiredString("kind", maxLength: 20) {
        case "daily":
            let (hour, minute) = try time()
            let days = (input["weekdays"]?.arrayValue ?? []).compactMap(\.intValue)
            guard days.allSatisfy({ (1...7).contains($0) }) else {
                throw ToolInputError("«weekdays» usa números del 1 (lunes) al 7 (domingo).")
            }
            return .daily(hour: hour, minute: minute, weekdays: Array(Set(days)).sorted())
        case "interval":
            guard let minutes = input["every_minutes"]?.intValue,
                  (TaskSchedule.minimumInterval...10080).contains(minutes) else {
                throw ToolInputError("«every_minutes» debe estar entre \(TaskSchedule.minimumInterval) y 10080.")
            }
            return .every(minutes: minutes)
        case "once":
            let (hour, minute) = try time()
            let day = try input.requiredString("date", maxLength: 10).split(separator: "-").compactMap { Int($0) }
            guard day.count == 3 else { throw ToolInputError("«date» debe tener el formato AAAA-MM-DD.") }
            var components = DateComponents()
            (components.year, components.month, components.day) = (day[0], day[1], day[2])
            (components.hour, components.minute) = (hour, minute)
            guard let date = calendar.date(from: components) else { throw ToolInputError("Fecha no válida.") }
            guard date > now else { throw ToolInputError("Esa fecha ya ha pasado.") }
            return .once(date)
        default:
            throw ToolInputError("«kind» debe ser daily, interval u once.")
        }
    }
}

public struct ScheduleTaskTool: AgentTool {
    let tasks: TaskStoring
    let broker: PermissionBrokering
    var userAPI: TelegramUserAPI?
    let now: @Sendable () -> Date

    public var name: String { "schedule_task" }
    public var description: String {
        """
        Programa una tarea que ejecutarás tú mismo más adelante, sin el usuario delante, y cuyo resultado se le \
        envía por Telegram. Úsala para recordatorios y encargos periódicos («envíame el calendario cada mañana a \
        las 9»). Si el resultado es para otras personas o grupos («dale los buenos días a Lucas y a Anna cada \
        lunes»), pon sus nombres o @alias en «recipients»: cada vez se les enviará el mismo mensaje desde la \
        cuenta del usuario y a él le llegará un aviso. Las horas son locales del Mac. Solo se ejecuta con el Mac despierto.
        """
    }
    public var inputSchema: JSONValue {
        .objectSchema([
            "instruction": .property("string", "Qué hacer en cada ejecución, redactado para ti mismo y con todo el contexto"),
            "kind": ["type": "string", "enum": ["daily", "interval", "once"],
                     "description": "daily: a una hora cada día; interval: cada N minutos; once: una sola vez"],
            "time": .property("string", "HH:MM en 24 horas (daily y once)"),
            "date": .property("string", "AAAA-MM-DD (solo once)"),
            "weekdays": ["type": "array", "items": ["type": "integer", "minimum": 1, "maximum": 7],
                         "description": "Días para daily: 1 lunes … 7 domingo. Vacío: todos"],
            "every_minutes": ["type": "integer", "minimum": .number(Double(TaskSchedule.minimumInterval)),
                              "description": "Minutos entre ejecuciones (interval)"],
            "recipients": ["type": "array", "items": ["type": "string"], "maxItems": 10,
                           "description": "Opcional: personas o grupos que reciben el resultado (nombre o @alias). Vacío: el usuario."],
        ], required: ["instruction", "kind"])
    }

    public func call(input: JSONValue, context: ToolContext) async throws -> String {
        let instruction = try input.requiredString("instruction", maxLength: 2000)
        let schedule = try TaskTools.schedule(from: input, now: now())
        // «recipients» (lista) o «recipient» (uno, como lo pedía antes la herramienta).
        var names = (input["recipients"]?.arrayValue ?? []).compactMap(\.stringValue)
        if let one = input["recipient"]?.stringValue { names.append(one) }
        names = names.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard names.count <= 10 else { throw ToolInputError("Como mucho 10 destinatarios por tarea.") }
        var recipients: [TaskRecipient] = []
        if !names.isEmpty {
            guard let userAPI else {
                throw ToolInputError("Para enviar el resultado a otra persona hace falta la cuenta de Telegram del " +
                    "usuario conectada (SaySo → Telegram).")
            }
            for name in names {
                let chat = try await TelegramUserTools.resolveChat(["chat": .string(name)], api: userAPI)
                if !recipients.contains(where: { $0.id == chat.id }) {
                    recipients.append(TaskRecipient(id: chat.id, title: chat.title, kind: chat.kind.rawValue,
                                                    username: chat.username))
                }
            }
        }
        guard try tasks.tasks().count < TaskAction.limit else {
            return "No se ha creado: ya hay \(TaskAction.limit) tareas programadas. Cancela alguna antes."
        }
        let request = ActionRequest(action: TaskAction.schedule,
                                    summary: "Programar: \(schedule.summary()) · \(String(instruction.prefix(160)))",
                                    parameters: ["Cuándo": schedule.summary(), "Tarea": instruction,
                                                 "Para": recipients.isEmpty ? "ti" : recipients.map(\.displayName).joined(separator: ", ")],
                                    origin: context.origin)
        let tasks = self.tasks
        let date = now()
        let to = recipients
        let saved = try await broker.run(request) {
            try tasks.addTask(ScheduledTask(instruction: instruction, schedule: schedule, createdAt: date,
                                            nextRun: schedule.next(after: date), recipients: to))
        }
        return "Tarea creada. " + TaskTools.line(saved)
    }
}

public struct ListTasksTool: AgentTool {
    let tasks: TaskStoring
    public var name: String { "list_tasks" }
    public var description: String { "Lista las tareas programadas con su número, cuándo se repiten y la próxima ejecución." }
    public var inputSchema: JSONValue { .objectSchema([:]) }

    public func call(input: JSONValue, context: ToolContext) async throws -> String {
        let all = try tasks.tasks()
        return all.isEmpty ? "No hay tareas programadas." : all.map(TaskTools.line).joined(separator: "\n")
    }
}

public struct CancelTaskTool: AgentTool {
    let tasks: TaskStoring
    let broker: PermissionBrokering
    public var name: String { "cancel_task" }
    public var description: String { "Elimina una tarea programada por su número (el de list_tasks)." }
    public var inputSchema: JSONValue {
        .objectSchema(["id": ["type": "integer", "description": "Número de la tarea"]], required: ["id"])
    }

    public func call(input: JSONValue, context: ToolContext) async throws -> String {
        guard let id = input["id"]?.intValue else { throw ToolInputError("Falta el parámetro «id» (número).") }
        guard let task = try tasks.tasks().first(where: { $0.id == Int64(id) }) else {
            return "No existe la tarea #\(id)."
        }
        let request = ActionRequest(action: TaskAction.cancel,
                                    summary: "Cancelar tarea #\(id): \(String(task.instruction.prefix(160)))",
                                    parameters: ["Tarea": task.instruction], origin: context.origin)
        let tasks = self.tasks
        try await broker.run(request) { try tasks.deleteTask(id: Int64(id)) }
        return "Tarea #\(id) eliminada."
    }
}

/// Dispara las tareas programadas. Las ejecuciones perdidas (Mac dormido, app cerrada) no se
/// acumulan: una tarea atrasada se ejecuta una vez y se reprograma desde ahora.
public actor TaskScheduler {
    public typealias LoopProvider = @Sendable () async throws -> AgentLoop

    private let tasks: TaskStoring
    private let makeLoop: LoopProvider
    private let deliver: @Sendable (ScheduledTask, String) async -> Void
    private let now: @Sendable () -> Date
    private var running = false
    /// Tareas en marcha ahora: «Ejecutar ahora» y el reloj no ejecutan la misma dos veces a la vez.
    private var executing: Set<Int64> = []

    public init(tasks: TaskStoring, makeLoop: @escaping LoopProvider,
                deliver: @escaping @Sendable (ScheduledTask, String) async -> Void,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.tasks = tasks
        self.makeLoop = makeLoop
        self.deliver = deliver
        self.now = now
    }

    /// Ejecuta, una tras otra, las tareas cuya hora ya ha llegado.
    public func tick() async {
        guard !running else { return }
        running = true
        defer { running = false }
        guard let all = try? tasks.tasks() else { return }
        for listed in all where listed.enabled {
            // Mientras se ejecuta otra (minutos), esta puede haberse borrado, desactivado o cambiado:
            // se vuelve a leer justo antes.
            guard var task = (try? tasks.tasks())?.first(where: { $0.id == listed.id }), task.enabled else { continue }
            guard let due = task.nextRun else {
                task.nextRun = task.schedule.next(after: now())
                if task.nextRun == nil { task.enabled = false }
                try? tasks.updateTask(task)
                continue
            }
            if due <= now() { await execute(task) }
        }
    }

    /// Lo que se le pide al agente en cada ejecución.
    static func prompt(for task: ScheduledTask) -> String {
        var memory = " Antes de hacerlo, mira la memoria del usuario: si alguna de sus instrucciones cambia cómo " +
            "hacer este encargo, aplícala aunque el encargo diga otra cosa o en ejecuciones anteriores lo hicieras distinto." +
            " Cada ejecución empieza de cero: haz el encargo entero con tus herramientas, sin dar nada por hecho." +
            " Si para no repetirte necesitas llevar la cuenta de lo ya hecho, apúntalo en el archivo " +
            "~/sayso/registro/tarea-\(task.id ?? 0).txt de tu ordenador Linux y léelo al empezar; no lo guardes en la memoria."
        // Solo lo último que salió, para no repetirlo; el historial completo no se manda.
        if let last = task.lastResult?.trimmingCharacters(in: .whitespacesAndNewlines), !last.isEmpty, last != "-",
           let when = task.lastRun {
            let f = DateFormatter()
            f.locale = Locale(identifier: "es_ES")
            f.dateFormat = "d MMM HH:mm"
            memory += " Lo que salió en la ejecución anterior (\(f.string(from: when))), por si el encargo pide no " +
                "repetir: «\(String(last.prefix(400)))»."
        }
        guard !task.recipients.isEmpty else {
            return "Tarea programada (\(task.schedule.summary())). El usuario no está delante; haz lo que pide y " +
                "responde con el resultado.\(memory)\n\nEncargo: \(task.instruction)"
        }
        return "Tarea programada (\(task.schedule.summary())). El usuario no está delante. Tu respuesta final se " +
            "enviará tal cual a \(task.recipients.names) desde la cuenta de Telegram del usuario, como si la escribiera " +
            "él (el mismo mensaje a cada uno). Haz lo que haga falta (buscar, leer…) y responde SOLO con el texto del " +
            "mensaje: sin " +
            "comentarios para el usuario, sin «aquí tienes» y sin mencionar que es una tarea. No lo envíes tú con " +
            "telegram_send_message: lo envía el sistema. Si el encargo es una foto, un vídeo o un archivo, " +
            "descárgalo al ordenador, comprueba con «file» que es lo que debe ser y llama a send_file sin «chat»: " +
            "en esta tarea se envía a esos destinatarios, no al usuario. Pon el texto que lo acompaña en «caption» " +
            "y termina respondiendo solo «-»: así no se manda otro mensaje aparte.\(memory)\n\nEncargo: \(task.instruction)"
    }

    /// Ejecuta una tarea ahora, sin tocar su calendario si aún no le tocaba.
    public func runNow(id: Int64) async {
        guard let task = try? tasks.tasks().first(where: { $0.id == id }) else { return }
        await execute(task, reschedule: false)
    }

    private func execute(_ task: ScheduledTask, reschedule: Bool = true) async {
        if let id = task.id {
            guard !executing.contains(id) else { return }
            executing.insert(id)
        }
        defer { if let id = task.id { executing.remove(id) } }
        var task = task
        // El encargo menciona la ejecución anterior: se toma antes de apuntar esta.
        let previous = task
        let started = now()
        // Se reprograma antes de ejecutar: si la app se cierra a medias, no se repite al volver.
        if reschedule {
            task.nextRun = task.schedule.next(after: started)
            if task.nextRun == nil { task.enabled = false }
        }
        task.lastRun = started
        try? tasks.updateTask(task)

        var text: String
        var failed = false
        do {
            let loop = try await makeLoop()
            let id = task.id ?? 0
            text = try await loop.respond(to: TaskScheduler.prompt(for: previous), chatID: "tarea-\(id)", origin: "tarea:\(id)",
                                          recipients: task.recipients, recipientsPreapproved: task.sendWithoutAsking,
                                          useHistory: false)
            failed = AgentLoop.isIncomplete(text)
        } catch {
            text = "No se pudo ejecutar la tarea: \(error.localizedDescription)"
            failed = true
        }
        // Otra parte de la app puede haberla cambiado o borrado mientras se ejecutaba.
        if var current = try? tasks.tasks().first(where: { $0.id == task.id }) {
            current.lastResult = String(text.prefix(4000))
            current.lastRun = started
            try? tasks.updateTask(current)
        }
        guard !task.recipients.isEmpty else { return await deliver(task, text) }
        // Para otras personas sale desde la cuenta del usuario: un error, una respuesta a medias o
        // un aviso interno no se les manda nunca; le llega solo al usuario por su bot.
        if failed {
            var ownerOnly = task
            ownerOnly.recipients = []
            return await deliver(ownerOnly, tr("No se ha enviado nada a %@: %@", task.recipients.names, text))
        }
        await deliver(task, AgentLoop.stripWarning(text).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
