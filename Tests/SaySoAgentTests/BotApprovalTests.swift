import XCTest
import SaySoCore
@testable import SaySoAgent

final class BotApprovalTests: XCTestCase {
    private let helper = TelegramTests()

    private func service(_ t: FakeTransport) -> TelegramBotService {
        let store = MemoryStore()
        store.settings[SettingsKey.telegramOwnerID] = String(TelegramTests.owner)
        return helper.makeService(store: store, transport: t, provider: FakeProvider([]))
    }

    private func press(_ service: TelegramBotService, from user: Int64, data: String, chat: Int64) async throws {
        await service.process(try helper.update(#"""
        {"update_id":9,"callback_query":{"id":"Q","from":{"id":\#(user),"first_name":"U"},"chat_instance":"1",
         "data":"\#(data)","message":{"message_id":7,"chat":{"id":\#(chat),"type":"private"},"date":1}}}
        """#))
    }

    /// Espera a que el mensaje con los botones haya salido.
    private func waitForQuestion(_ t: FakeTransport) async throws -> String {
        for _ in 0..<100 {
            if let data = helper.calls(t, "sendMessage").first?["reply_markup"]?["inline_keyboard"]?[0]?[0]?["callback_data"]?.stringValue {
                return data
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw XCTSkip("no salió la pregunta")
    }

    func testOwnerAllowsOnceFromTheBot() async throws {
        let t = helper.botTransport()
        let service = service(t)
        async let answer = service.askApproval(id: "abc", title: "Enviar mensajes", detail: "Enviar a Anna: hola")
        let data = try await waitForQuestion(t)
        XCTAssertEqual(data, "perm:abc:allow")
        let text = helper.calls(t, "sendMessage").first?["text"]?.stringValue ?? ""
        XCTAssertTrue(text.contains("Enviar a Anna: hola"))
        // Un ajeno no cuenta.
        try await press(service, from: TelegramTests.stranger, data: data, chat: TelegramTests.stranger)
        try await press(service, from: TelegramTests.owner, data: data, chat: TelegramTests.owner)
        let result = await answer
        XCTAssertEqual(result, .allowOnce)
        XCTAssertFalse(helper.calls(t, "editMessageText").isEmpty)
    }

    func testDenyAndExpiry() async throws {
        let t = helper.botTransport()
        let service = service(t)
        async let denied = service.askApproval(id: "d1", title: "T", detail: "D")
        _ = try await waitForQuestion(t)
        try await press(service, from: TelegramTests.owner, data: "perm:d1:deny", chat: TelegramTests.owner)
        let first = await denied
        XCTAssertEqual(first, .deny)

        let expired = await service.askApproval(id: "e1", title: "T", detail: "D", timeout: 0.05)
        XCTAssertNil(expired)
        // Pulsar después de caducar no hace nada.
        try await press(service, from: TelegramTests.owner, data: "perm:e1:allow", chat: TelegramTests.owner)
    }

    func testWithdrawnWhenAnsweredOnTheMac() async throws {
        let t = helper.botTransport()
        let service = service(t)
        async let answer = service.askApproval(id: "m1", title: "T", detail: "D")
        _ = try await waitForQuestion(t)
        await service.withdrawApproval(id: "m1", allowed: true)
        let result = await answer
        XCTAssertNil(result)
        let edited = helper.calls(t, "editMessageText").last?["text"]?.stringValue ?? ""
        XCTAssertTrue(edited.contains("Permitido en el Mac"))
    }

    func testWithoutOwnerNothingIsAsked() async {
        let t = helper.botTransport()
        let service = helper.makeService(store: MemoryStore(), transport: t, provider: FakeProvider([]))
        let result = await service.askApproval(id: "x", title: "T", detail: "D")
        XCTAssertNil(result)
        XCTAssertTrue(helper.calls(t, "sendMessage").isEmpty)
    }
}
