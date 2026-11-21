import XCTest
import SaySoCore
@testable import SaySoAgent

private final class FakeCommands: BotCommandHandling, @unchecked Sendable {
    let paused = Locked<Bool?>(nil)
    func status() async -> String { "estado ok" }
    func tasks() async -> String { "tareas ok" }
    func setTasksPaused(_ value: Bool) async -> String { paused.set(value); return value ? "pausa" : "marcha" }
}

final class BotCommandTests: XCTestCase {
    private let helper = TelegramTests()

    func testCommandsAnswerWithoutTheModel() async throws {
        let store = MemoryStore()
        store.settings[SettingsKey.telegramOwnerID] = String(TelegramTests.owner)
        let t = helper.botTransport()
        let provider = FakeProvider([])
        let service = helper.makeService(store: store, transport: t, provider: provider)
        let commands = FakeCommands()
        await service.setCommandHandler(commands)

        for (command, expected) in [("/status", "estado ok"), ("/tasks", "tareas ok"), ("/pause", "pausa")] {
            await service.process(try helper.privateText(from: TelegramTests.owner, command))
            XCTAssertEqual(helper.calls(t, "sendMessage").last?["text"]?.stringValue, expected)
        }
        XCTAssertEqual(commands.paused.get(), true)
        await service.process(try helper.privateText(from: TelegramTests.owner, "/resume"))
        XCTAssertEqual(commands.paused.get(), false)
        await service.process(try helper.privateText(from: TelegramTests.owner, "/help"))
        XCTAssertTrue(helper.calls(t, "sendMessage").last?["text"]?.stringValue?.contains("/status") ?? false)
        XCTAssertTrue(provider.requests.get().isEmpty)

        // Nadie más puede usarlos.
        let before = helper.calls(t, "sendMessage").count
        await service.process(try helper.privateText(from: TelegramTests.stranger, "/pause"))
        XCTAssertEqual(helper.calls(t, "sendMessage").count, before)
        XCTAssertEqual(commands.paused.get(), false)
    }

    func testMenuIsPublishedForPrivateChats() async throws {
        let t = helper.botTransport()
        let service = helper.makeService(store: MemoryStore(), transport: t, provider: FakeProvider([]))
        await service.start()
        for _ in 0..<100 where helper.calls(t, "setMyCommands").isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await service.stop()
        let body = try XCTUnwrap(helper.calls(t, "setMyCommands").first)
        XCTAssertEqual(body["scope"]?["type"]?.stringValue, "all_private_chats")
        let names = body["commands"]?.arrayValue?.compactMap { $0["command"]?.stringValue }
        XCTAssertEqual(names, ["status", "tasks", "pause", "resume", "new", "help"])
    }
}
