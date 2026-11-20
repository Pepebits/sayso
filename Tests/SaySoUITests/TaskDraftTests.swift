import SaySoCore
@testable import SaySoUI
import XCTest

final class TaskDraftTests: XCTestCase {
    func testEditingATaskKeepsItsScheduleAndRecipients() {
        let anna = TaskRecipient(id: 4, title: "Anna", username: "anna_design")
        let cases: [TaskSchedule] = [
            .daily(hour: 8, minute: 30, weekdays: []),
            .daily(hour: 17, minute: 0, weekdays: [1, 2, 3, 4, 5]),
            .daily(hour: 7, minute: 15, weekdays: [2, 4, 6]),
            .every(minutes: 60),
            .every(minutes: 45), // un intervalo que el agente puso y no está entre los botones
            .once(Date(timeIntervalSince1970: 1_900_000_000)),
        ]
        for schedule in cases {
            let task = ScheduledTask(id: 1, instruction: "  Resume el día  ", schedule: schedule, recipients: [anna])
            let draft = TaskDraft(task)
            XCTAssertEqual(draft.schedule, schedule, "sin tocar nada, el horario es el mismo")
            XCTAssertEqual(draft.recipients, [anna])
            XCTAssertEqual(draft.trimmed, "Resume el día")
            XCTAssertTrue(draft.changes(task), "la instrucción se guarda sin los espacios")
            var same = TaskDraft(ScheduledTask(id: 1, instruction: "Resume el día", schedule: schedule, recipients: [anna]))
            XCTAssertFalse(same.changes(ScheduledTask(id: 1, instruction: "Resume el día", schedule: schedule, recipients: [anna])))
            same.recipients = []
            XCTAssertTrue(same.changes(ScheduledTask(id: 1, instruction: "Resume el día", schedule: schedule, recipients: [anna])))
        }
        XCTAssertEqual(TaskDraft(ScheduledTask(instruction: "x", schedule: .daily(hour: 7, minute: 15, weekdays: [2, 4, 6]))).days,
                       .custom)
    }

    func testProblemsBlockSaving() {
        var draft = TaskDraft()
        XCTAssertNotNil(draft.problem, "sin instrucción")
        draft.instruction = "Hola"
        XCTAssertNil(draft.problem)
        draft.days = .custom
        draft.customDays = []
        XCTAssertNotNil(draft.problem, "días a elegir sin ninguno")
        draft.days = .all
        draft.kind = .once
        draft.onceDate = Date().addingTimeInterval(-60)
        XCTAssertNotNil(draft.problem, "una vez, en el pasado")
        draft.onceDate = Date().addingTimeInterval(3600)
        XCTAssertNil(draft.problem)
    }
}
