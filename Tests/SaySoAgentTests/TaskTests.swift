import XCTest
import SaySoCore
@testable import SaySoAgent

final class MemoryTasks: TaskStoring, @unchecked Sendable {
    let items = Locked<[ScheduledTask]>([])
    private let nextID = Locked<Int64>(1)

    func tasks() throws -> [ScheduledTask] { items.get() }
    func addTask(_ task: ScheduledTask) throws -> ScheduledTask {
        var saved = task
        saved.id = nextID.update { id in defer { id += 1 }; return id }
        items.update { $0.append(saved) }
        return saved
    }
    func updateTask(_ task: ScheduledTask) throws {
        items.update { list in if let i = list.firstIndex(where: { $0.id == task.id }) { list[i] = task } }
    }
    func deleteTask(id: Int64) throws { items.update { $0.removeAll { $0.id == id } } }
}

final class TaskTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Madrid")!
        return c
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    func testDailyNextRun() {
        let nine = TaskSchedule.daily(hour: 9, minute: 0, weekdays: [])
        // Miércoles 18 de noviembre de 2026.
        XCTAssertEqual(nine.next(after: date(2026, 11, 18, 8, 0), calendar: calendar), date(2026, 11, 18, 9, 0))
        XCTAssertEqual(nine.next(after: date(2026, 11, 18, 9, 0), calendar: calendar), date(2026, 11, 19, 9, 0))
        let weekdays = TaskSchedule.daily(hour: 9, minute: 0, weekdays: [1, 2, 3, 4, 5])
        // Viernes 20 a las 10:00 → lunes 23.
        XCTAssertEqual(weekdays.next(after: date(2026, 11, 20, 10, 0), calendar: calendar), date(2026, 11, 23, 9, 0))
        let sunday = TaskSchedule.daily(hour: 20, minute: 30, weekdays: [7])
        XCTAssertEqual(sunday.next(after: date(2026, 11, 18, 8, 0), calendar: calendar), date(2026, 11, 22, 20, 30))
    }

    func testOnceAndInterval() {
        let when = date(2026, 12, 1, 17, 0)
        XCTAssertEqual(TaskSchedule.once(when).next(after: date(2026, 11, 18, 8, 0), calendar: calendar), when)
        XCTAssertNil(TaskSchedule.once(when).next(after: when, calendar: calendar))
        let start = date(2026, 11, 18, 8, 0)
        XCTAssertEqual(TaskSchedule.every(minutes: 30).next(after: start), start.addingTimeInterval(1800))
        XCTAssertEqual(TaskSchedule.every(minutes: 1).next(after: start), start.addingTimeInterval(300), "mínimo 5 minutos")
    }

    func testSummaries() {
        XCTAssertEqual(TaskSchedule.daily(hour: 9, minute: 5, weekdays: []).summary(), "Cada día a las 09:05")
        XCTAssertEqual(TaskSchedule.daily(hour: 9, minute: 0, weekdays: [5, 4, 3, 2, 1]).summary(), "De lunes a viernes a las 09:00")
        XCTAssertEqual(TaskSchedule.daily(hour: 9, minute: 0, weekdays: [1, 3]).summary(), "Los lun, mié a las 09:00")
        XCTAssertEqual(TaskSchedule.every(minutes: 120).summary(), "Cada 2 horas")
        XCTAssertEqual(TaskSchedule.every(minutes: 15).summary(), "Cada 15 minutos")
    }

    func testScheduleIsCodable() throws {
        for schedule in [TaskSchedule.daily(hour: 9, minute: 0, weekdays: [1]), .every(minutes: 15), .once(date(2026, 12, 1, 9, 0))] {
            let data = try JSONEncoder().encode(schedule)
            XCTAssertEqual(try JSONDecoder().decode(TaskSchedule.self, from: data), schedule)
        }
    }

    func testParsingToolInput() throws {
        let now = date(2026, 11, 18, 8, 0)
        XCTAssertEqual(try TaskTools.schedule(from: ["kind": "daily", "time": "09:00", "weekdays": [1, 5, 5]], now: now),
                       .daily(hour: 9, minute: 0, weekdays: [1, 5]))
        XCTAssertEqual(try TaskTools.schedule(from: ["kind": "interval", "every_minutes": 30], now: now), .every(minutes: 30))
        XCTAssertThrowsError(try TaskTools.schedule(from: ["kind": "interval", "every_minutes": 1], now: now))
        XCTAssertThrowsError(try TaskTools.schedule(from: ["kind": "daily", "time": "25:00"], now: now))
        XCTAssertThrowsError(try TaskTools.schedule(from: ["kind": "daily", "time": "09:00", "weekdays": [8]], now: now))
        XCTAssertThrowsError(try TaskTools.schedule(from: ["kind": "once", "time": "09:00", "date": "2020-01-01"], now: now))
        XCTAssertThrowsError(try TaskTools.schedule(from: ["kind": "weekly"], now: now))
    }

    func testToolsCreateListAndCancel() async throws {
        let tasks = MemoryTasks()
        let broker = FakeBroker(allow: true)
        let now = date(2026, 11, 18, 8, 0)
        let tools = TaskTools.all(tasks: tasks, broker: broker, now: { now })
        let created = try await tools[0].call(input: ["instruction": "Envíame el calendario", "kind": "daily", "time": "09:00"],
                                              context: ToolContext(origin: "telegram:1"))
        XCTAssertTrue(created.contains("#1"))
        XCTAssertEqual(tasks.items.get().first?.nextRun, TaskSchedule.daily(hour: 9, minute: 0, weekdays: []).next(after: now))
        XCTAssertEqual(broker.requests.get().first?.action, TaskAction.schedule)
        let listed = try await tools[1].call(input: [:], context: ToolContext())
        XCTAssertTrue(listed.contains("Envíame el calendario"))
        let missing = try await tools[2].call(input: ["id": 9], context: ToolContext())
        XCTAssertTrue(missing.contains("No existe"))
        _ = try await tools[2].call(input: ["id": 1], context: ToolContext())
        XCTAssertTrue(tasks.items.get().isEmpty)

        let denied = TaskTools.all(tasks: tasks, broker: FakeBroker(allow: false), now: { now })
        do {
            _ = try await denied[0].call(input: ["instruction": "x", "kind": "interval", "every_minutes": 10], context: ToolContext())
            XCTFail("debía denegarse")
        } catch is PermissionError {}
        XCTAssertTrue(tasks.items.get().isEmpty)
    }

    func testSchedulerRunsDueTasksOnceAndReschedules() async throws {
        // El programador usa el calendario del equipo; las fechas del test, también (CI va en UTC).
        func local(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
            Calendar.current.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
        }
        let tasks = MemoryTasks()
        let store = MemoryStore()
        let clock = Locked(local(2026, 11, 18, 12, 0))
        let schedule = TaskSchedule.daily(hour: 9, minute: 0, weekdays: [])
        // Atrasada tres días: debe ejecutarse una sola vez.
        try tasks.addTask(ScheduledTask(instruction: "Calendario", schedule: schedule, nextRun: local(2026, 11, 15, 9, 0)))
        try tasks.addTask(ScheduledTask(instruction: "Futura", schedule: schedule, nextRun: local(2026, 11, 19, 9, 0)))
        try tasks.addTask(ScheduledTask(instruction: "Pausada", schedule: schedule, enabled: false, nextRun: local(2026, 11, 15, 9, 0)))
        try tasks.addTask(ScheduledTask(instruction: "Una vez", schedule: .once(local(2026, 11, 18, 11, 0)),
                                        nextRun: local(2026, 11, 18, 11, 0)))
        let provider = FakeProvider([], fallback: .text("Hoy no hay nada"))
        let delivered = Locked<[String]>([])
        let scheduler = TaskScheduler(
            tasks: tasks, makeLoop: { AgentLoop(provider: provider, tools: [], store: store) },
            deliver: { task, text in delivered.update { $0.append("\(task.instruction): \(text)") } },
            now: { clock.get() })

        await scheduler.tick()
        XCTAssertEqual(delivered.get(), ["Calendario: Hoy no hay nada", "Una vez: Hoy no hay nada"])
        let after = tasks.items.get()
        XCTAssertEqual(after[0].nextRun, local(2026, 11, 19, 9, 0))
        XCTAssertEqual(after[0].lastResult, "Hoy no hay nada")
        XCTAssertEqual(after[0].lastRun, clock.get())
        XCTAssertFalse(after[3].enabled, "una tarea de una sola vez se desactiva")
        XCTAssertNil(after[3].nextRun)
        XCTAssertTrue(provider.requests.get().first?.messages.last?.content.description.contains("Calendario") == true)

        await scheduler.tick()
        XCTAssertEqual(delivered.get().count, 2, "no se repite hasta su próxima hora")

        await scheduler.runNow(id: 2)
        XCTAssertEqual(delivered.get().count, 3)
        XCTAssertEqual(tasks.items.get()[1].nextRun, local(2026, 11, 19, 9, 0), "ejecutar ahora no mueve el calendario")
    }

    func testSchedulerReportsFailures() async throws {
        let tasks = MemoryTasks()
        try tasks.addTask(ScheduledTask(instruction: "x", schedule: .every(minutes: 10), nextRun: Date(timeIntervalSince1970: 0)))
        struct Boom: LocalizedError { var errorDescription: String? { "sin cuenta" } }
        let delivered = Locked<[String]>([])
        let scheduler = TaskScheduler(tasks: tasks, makeLoop: { throw Boom() },
                                      deliver: { _, text in delivered.update { $0.append(text) } })
        await scheduler.tick()
        XCTAssertEqual(delivered.get(), ["No se pudo ejecutar la tarea: sin cuenta"])
        XCTAssertNotNil(tasks.items.get()[0].nextRun)
    }

    func testFailuresNeverReachTheRecipients() async throws {
        let tasks = MemoryTasks()
        try tasks.addTask(ScheduledTask(instruction: "x", schedule: .every(minutes: 10), nextRun: Date(timeIntervalSince1970: 0),
                                        recipients: [TaskRecipient(id: 1, title: "Anna")], sendWithoutAsking: true))
        struct Boom: LocalizedError { var errorDescription: String? { "límite diario" } }
        let delivered = Locked<[(Int, String)]>([])
        let scheduler = TaskScheduler(tasks: tasks, makeLoop: { throw Boom() },
                                      deliver: { task, text in delivered.update { $0.append((task.recipients.count, text)) } })
        await scheduler.tick()
        let sent = try XCTUnwrap(delivered.get().first)
        XCTAssertEqual(sent.0, 0, "va solo al usuario")
        XCTAssertTrue(sent.1.contains("Anna") && sent.1.contains("límite diario"))
        XCTAssertTrue(AgentLoop.isIncomplete("He alcanzado el límite de pasos sin terminar la tarea."))
        XCTAssertTrue(AgentLoop.isIncomplete("(Sin respuesta del modelo.)"))
        XCTAssertFalse(AgentLoop.isIncomplete("Buenos días, Anna"))
    }

    func testATaskCanBeForSomeoneElse() async throws {
        let tasks = MemoryTasks()
        let broker = FakeBroker(allow: true)
        let now = date(2026, 11, 18, 8, 0)
        let api = FakeTelegramUser()
        let tool = TaskTools.all(tasks: tasks, broker: broker, userAPI: api, now: { now })[0]
        let out = try await tool.call(input: ["instruction": "Dale los buenos días con el tiempo de Vigo", "kind": "daily",
                                              "time": "08:30", "recipients": ["anna", "@lucas_mor82", "Anna"]],
                                      context: ToolContext())
        XCTAssertTrue(out.contains("para «Anna» y «Lucas»"))
        XCTAssertEqual(tasks.items.get().first?.recipients.map(\.id), [1, 9], "sin repetir a nadie")
        XCTAssertEqual(broker.requests.get().first?.parameters["Para"], "Anna, Lucas", "la confirmación dice para quién es")

        // Lo que se le pide al agente: solo el mensaje, que lo envía el sistema.
        let prompt = TaskScheduler.prompt(for: try XCTUnwrap(tasks.items.get().first))
        XCTAssertTrue(prompt.contains("«Anna» y «Lucas»"))
        XCTAssertTrue(prompt.contains("SOLO con el texto del mensaje"))
        XCTAssertTrue(prompt.contains("send_file sin «chat»"), "las fotos van a los destinatarios")
        XCTAssertFalse(TaskScheduler.prompt(for: ScheduledTask(instruction: "x", schedule: .every(minutes: 60)))
            .contains("SOLO"))

        // Sin la cuenta de Telegram no se puede elegir a otro.
        let alone = TaskTools.all(tasks: tasks, broker: broker, now: { now })[0]
        do {
            _ = try await alone.call(input: ["instruction": "x", "kind": "interval", "every_minutes": 60, "recipients": ["anna"]],
                                     context: ToolContext())
            XCTFail("tenía que pedir la cuenta")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("cuenta de Telegram"))
        }
        XCTAssertEqual(tasks.items.get().count, 1)
    }

    func testTasksStartFromScratchAndOnlySeeTheLastResult() async throws {
        // Sacado del registro real: con quince ejecuciones delante, la tarea acabó respondiendo «-»
        // sin hacer nada, o «🐶 Aquí tienes un gatito» sin mandar ninguna foto.
        let tasks = MemoryTasks()
        let store = MemoryStore()
        for n in 0..<6 {
            try store.appendTurn(ConversationTurn(chatID: "tarea-1", role: n % 2 == 0 ? .user : .assistant,
                                                  text: n % 2 == 0 ? "encargo" : "-", date: Date().addingTimeInterval(Double(n - 10))))
        }
        var task = try tasks.addTask(ScheduledTask(instruction: "Manda una foto de un gatito nueva", schedule: .every(minutes: 15),
                                                   nextRun: Date().addingTimeInterval(-1)))
        task.lastResult = "Foto de un gato naranja"
        task.lastRun = Date().addingTimeInterval(-900)
        try tasks.updateTask(task)
        let provider = FakeProvider([.text("Hecho el encargo con su resultado")])
        let scheduler = TaskScheduler(tasks: tasks, makeLoop: { AgentLoop(provider: provider, tools: [], store: store) },
                                      deliver: { _, _ in })
        await scheduler.tick()
        let request = try XCTUnwrap(provider.requests.get().first)
        XCTAssertEqual(request.messages.count, 1, "sin el historial de ejecuciones anteriores")
        let prompt = request.messages.first?.content.description ?? ""
        XCTAssertTrue(prompt.contains("Foto de un gato naranja"), "sí lo último que salió, para no repetirlo")
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_ES")
        f.dateFormat = "d MMM HH:mm"
        XCTAssertTrue(prompt.contains(f.string(from: Date().addingTimeInterval(-900))), "con la hora de la ejecución anterior, no la de esta")
        XCTAssertTrue(prompt.contains("Cada ejecución empieza de cero"))

        XCTAssertTrue(AgentLoop.isPlaceholder("-\n[acciones realizadas: ninguna]"))
        XCTAssertTrue(AgentLoop.isPlaceholder("  "))
        XCTAssertFalse(AgentLoop.isPlaceholder("Hoy no hay mensajes nuevos."))
        XCTAssertTrue(AgentLoop.claimsAction("🐶 Aquí tienes un gatito. 😸"))
    }
}
