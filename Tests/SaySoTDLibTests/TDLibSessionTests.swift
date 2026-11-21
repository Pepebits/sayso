import XCTest
import SaySoAgent
import SaySoCore
@testable import SaySoTDLib

final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.withLock { value } }
    @discardableResult func update<R>(_ body: (inout Value) -> R) -> R { lock.withLock { body(&value) } }
}

/// TDLib falso: guarda lo enviado y responde con lo que diga el test.
final class FakeTD: TDTransport, @unchecked Sendable {
    let incoming: AsyncStream<JSONValue>
    private let continuation: AsyncStream<JSONValue>.Continuation
    private let lock = NSLock()
    private var log: [JSONValue] = []
    var responder: (@Sendable (JSONValue) -> JSONValue?)?
    private(set) var closed = false

    init() {
        var captured: AsyncStream<JSONValue>.Continuation!
        incoming = AsyncStream { captured = $0 }
        continuation = captured
    }

    var sent: [JSONValue] { lock.lock(); defer { lock.unlock() }; return log }
    func sent(_ type: String) -> [JSONValue] { sent.filter { $0["@type"]?.stringValue == type } }

    func send(_ request: JSONValue) {
        lock.lock(); log.append(request); lock.unlock()
        guard var reply = responder?(request)?.objectValue else { return }
        if let extra = request["@extra"] { reply["@extra"] = extra }
        continuation.yield(.object(reply))
    }

    func push(_ update: JSONValue) { continuation.yield(update) }
    func auth(_ type: String, _ extra: [String: JSONValue] = [:]) {
        var state = extra
        state["@type"] = .string(type)
        push(["@type": "updateAuthorizationState", "authorization_state": .object(state)])
    }
    func close() { closed = true; continuation.finish() }
}

final class TDLibSessionTests: XCTestCase {
    private func makeSession(_ td: FakeTD, states: Locked<[TelegramUserState]>) -> TDLibSession {
        let config = TDLibConfig(apiID: 12345, apiHash: "hash", directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("sayso-td-\(UUID().uuidString)"), databaseKey: Data([1, 2, 3]))
        return TDLibSession(config: config, transport: td) { state in states.update { $0.append(state) } }
    }

    private func wait(_ condition: @escaping () async -> Bool) async {
        for _ in 0..<200 {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("la condición no llegó a cumplirse")
    }

    func testLoginFlow() async throws {
        let td = FakeTD()
        td.responder = { request in
            switch request["@type"]?.stringValue {
            case "getMe": return ["@type": "user", "id": 7, "first_name": "Daniel", "last_name": "P"]
            case "getOption": return nil
            default: return ["@type": "ok"]
            }
        }
        let states = Locked<[TelegramUserState]>([])
        let session = makeSession(td, states: states)
        await session.start()
        td.auth("authorizationStateWaitTdlibParameters")
        await wait { td.sent("setTdlibParameters").count == 1 }
        let parameters = td.sent("setTdlibParameters")[0]
        XCTAssertEqual(parameters["api_id"]?.intValue, 12345)
        XCTAssertEqual(parameters["api_hash"]?.stringValue, "hash")
        XCTAssertEqual(parameters["use_secret_chats"]?.boolValue, false)
        XCTAssertEqual(parameters["database_encryption_key"]?.stringValue, Data([1, 2, 3]).base64EncodedString())

        // Un segundo aviso no debe reenviar los parámetros: TDLib lo rechaza.
        td.auth("authorizationStateWaitTdlibParameters")
        td.auth("authorizationStateWaitPhoneNumber")
        await wait { await session.state == .waitingPhone }
        XCTAssertEqual(td.sent("setTdlibParameters").count, 1)
        try await session.submitPhone("+34600000000")
        XCTAssertEqual(td.sent("setAuthenticationPhoneNumber").first?["phone_number"]?.stringValue, "+34600000000")

        td.auth("authorizationStateWaitCode", ["code_info": ["type": ["@type": "authenticationCodeTypeSms"]]])
        await wait { await session.state == .waitingCode("Telegram te ha enviado el código por SMS.") }
        try await session.submitCode("12345")

        td.auth("authorizationStateWaitPassword", ["password_hint": "perro"])
        await wait { await session.state == .waitingPassword(hint: "perro") }
        try await session.submitPassword("secreto")
        XCTAssertEqual(td.sent("checkAuthenticationPassword").first?["password"]?.stringValue, "secreto")

        td.auth("authorizationStateReady")
        await wait { await session.state == .ready("Daniel P") }
        XCTAssertEqual(states.get().first, .connecting)
    }

    func testErrorsAreTranslatedAndDoNotChangeTheStep() async throws {
        let td = FakeTD()
        td.responder = { request in
            request["@type"]?.stringValue == "checkAuthenticationCode"
                ? ["@type": "error", "code": 400, "message": "PHONE_CODE_INVALID"] : nil
        }
        let session = makeSession(td, states: Locked([]))
        await session.start()
        td.auth("authorizationStateWaitCode")
        await wait { if case .waitingCode = await session.state { return true }; return false }
        do {
            try await session.submitCode("00000")
            XCTFail("debía fallar")
        } catch {
            XCTAssertEqual(error as? TDError, TDError(code: 400, message: "PHONE_CODE_INVALID"))
            XCTAssertEqual(error.localizedDescription, "El código no es correcto.")
        }
        let state = await session.state
        if case .waitingCode = state {} else { XCTFail("debe seguir pidiendo el código") }
    }

    func testUnsupportedStepAndClose() async throws {
        let td = FakeTD()
        let session = makeSession(td, states: Locked([]))
        await session.start()
        td.auth("authorizationStateWaitOtherDeviceConfirmation")
        await wait { if case .failed = await session.state { return true }; return false }
        td.auth("authorizationStateClosed")
        await wait { await session.state == .off }
        XCTAssertTrue(td.closed)
    }

    func testChatsAndMessagesAreConverted() async throws {
        let td = FakeTD()
        td.responder = { request in
            switch request["@type"]?.stringValue {
            case "getMe": return ["@type": "user", "id": 7, "first_name": "Yo"]
            case "loadChats": return ["@type": "error", "code": 404, "message": "Not Found"]
            case "getChats": return ["@type": "chats", "chat_ids": [10, 20, 30]]
            case "getChat":
                switch request["chat_id"]?.intValue {
                case 10: return ["@type": "chat", "id": 10, "title": "Anna", "type": ["@type": "chatTypePrivate"], "unread_count": 3,
                                 "last_message": ["content": ["@type": "messageText", "text": ["text": "hola"]]]]
                case 20: return ["@type": "chat", "id": 20, "title": "Canal", "type": ["@type": "chatTypeSupergroup", "is_channel": true]]
                default: return ["@type": "chat", "id": 30, "title": "Oculto", "type": ["@type": "chatTypeSecret"]]
                }
            case "getChatHistory":
                guard request["from_message_id"]?.intValue == 0 else { return ["@type": "messages", "messages": []] }
                return ["@type": "messages", "messages": [
                    ["id": 2, "chat_id": 10, "date": 120, "is_outgoing": true, "sender_id": ["@type": "messageSenderUser", "user_id": 7],
                     "content": ["@type": "messagePhoto", "caption": ["text": "mira"]]],
                    ["id": 1, "chat_id": 10, "date": 60, "is_outgoing": false, "sender_id": ["@type": "messageSenderUser", "user_id": 8],
                     "content": ["@type": "messageText", "text": ["text": "¿vienes?"]]],
                ]]
            case "getUser": return ["@type": "user", "id": 8, "first_name": "Anna"]
            default: return ["@type": "ok"]
            }
        }
        let session = makeSession(td, states: Locked([]))
        do {
            _ = try await session.chats(limit: 5)
            XCTFail("sin sesión iniciada no debe funcionar")
        } catch { XCTAssertEqual(error as? TelegramUserError, .notReady) }

        await session.start()
        td.auth("authorizationStateReady")
        await wait { await session.state == .ready("Yo") }

        let chats = try await session.chats(limit: 5)
        XCTAssertEqual(chats.map(\.kind), [.personal, .channel, .secret])
        XCTAssertEqual(chats[0].unread, 3)
        XCTAssertEqual(chats[0].lastMessage, "hola")

        let messages = try await session.messages(chatID: 10, limit: 10)
        XCTAssertEqual(messages.map(\.text), ["[foto] mira", "¿vienes?"])
        XCTAssertEqual(messages[1].sender, "Anna")
        XCTAssertTrue(messages[0].outgoing)

        try await session.send(chatID: 10, text: "Llego ya")
        let sent = td.sent("sendMessage")[0]
        XCTAssertEqual(sent["input_message_content"]?["text"]?["text"]?.stringValue, "Llego ya")
        try await session.delete(chatID: 10, messageIDs: [1, 2], forEveryone: true)
        XCTAssertEqual(td.sent("deleteMessages")[0]["revoke"]?.boolValue, true)
    }

    func testProfilePhotoIsDownloadedOnlyWhenThereIsOne() async throws {
        let td = FakeTD()
        let hasPhoto = Locked(true)
        td.responder = { request in
            switch request["@type"]?.stringValue {
            case "getMe":
                return hasPhoto.get()
                    ? ["@type": "user", "id": 7, "first_name": "Yo", "profile_photo": ["small": ["id": 42]]]
                    : ["@type": "user", "id": 7, "first_name": "Yo"]
            case "downloadFile":
                return ["@type": "file", "id": 42, "local": ["path": "/tmp/foto.jpg", "is_downloading_completed": true]]
            default: return ["@type": "ok"]
            }
        }
        let session = makeSession(td, states: Locked([]))
        let before = await session.profilePhoto()
        XCTAssertNil(before, "sin sesión iniciada no se pide nada")
        await session.start()
        td.auth("authorizationStateReady")
        await wait { await session.state == .ready("Yo") }

        let photo = await session.profilePhoto()
        XCTAssertEqual(photo?.path, "/tmp/foto.jpg")
        let download = td.sent("downloadFile")[0]
        XCTAssertEqual(download["file_id"]?.intValue, 42)
        XCTAssertEqual(download["synchronous"]?.boolValue, true)

        hasPhoto.update { $0 = false }
        let none = await session.profilePhoto()
        XCTAssertNil(none)
        XCTAssertEqual(td.sent("downloadFile").count, 1)
    }

    /// La librería real está enlazada y responde sin red.
    func testLinkedLibraryAnswers() {
        let version = TDLibTransport.libraryVersion
        XCTAssertEqual(version?.hasPrefix("1.8."), true, "versión: \(version ?? "nil")")
    }

    /// Con red: TDLib real llega a pedir el número de teléfono. No usa ninguna cuenta ni credenciales
    /// de app válidas (Telegram solo las comprueba al enviar el número).
    /// Se activa con SAYSO_TDLIB_LIVE=1.
    func testRealLibraryReachesThePhoneStep() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SAYSO_TDLIB_LIVE"] == "1")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sayso-td-live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = TDLibConfig(apiID: 1, apiHash: "sin-credenciales", directory: directory,
                                 databaseKey: Data(repeating: 7, count: 32))
        let session = TDLibSession(config: config, transport: TDLibTransport()) { _ in }
        await session.start()
        for _ in 0..<300 {
            if await session.state == .waitingPhone { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let state = await session.state
        XCTAssertEqual(state, .waitingPhone)
        await session.stop()
    }

    func testQuitWaitsUntilTDLibConfirmsItHasClosed() async throws {
        let td = FakeTD()
        let session = makeSession(td, states: Locked([]))
        await session.start()
        let finished = Locked(false)
        let quitting = Task {
            await session.stopAndWait(timeout: 5)
            finished.update { $0 = true }
        }
        await wait { !td.sent("close").isEmpty }
        // Pedido el cierre, pero TDLib aún no ha contestado: la app no debe seguir saliendo.
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertFalse(finished.get())
        td.auth("authorizationStateClosed")
        await quitting.value
        XCTAssertTrue(finished.get())
        XCTAssertTrue(td.closed)
        let state = await session.state
        XCTAssertEqual(state, .off)
    }

    func testQuitDoesNotHangIfTDLibNeverAnswers() async {
        let td = FakeTD()
        let session = makeSession(td, states: Locked([]))
        await session.start()
        let started = Date()
        await session.stopAndWait(timeout: 0.2)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertTrue(td.closed)
        // Una sesión ya parada no espera nada.
        let again = Date()
        await session.stopAndWait(timeout: 5)
        XCTAssertLessThan(Date().timeIntervalSince(again), 0.5)
    }

    func testFileMessagesUseTheNestedShapeThisTDLibExpects() {
        // Con el archivo directamente en «photo», TDLib respondía «InputFile is not specified».
        let photo = TDLibSession.fileContent(path: "/tmp/a.jpg", caption: "Hola", kind: .photo)
        XCTAssertEqual(photo["@type"]?.stringValue, "inputMessagePhoto")
        XCTAssertEqual(photo["photo"]?["@type"]?.stringValue, "inputPhoto")
        XCTAssertEqual(photo["photo"]?["photo"]?["@type"]?.stringValue, "inputFileLocal")
        XCTAssertEqual(photo["photo"]?["photo"]?["path"]?.stringValue, "/tmp/a.jpg")
        XCTAssertEqual(photo["caption"]?["text"]?.stringValue, "Hola")
        let shapes: [(TGMediaKind, String, String, String)] = [
            (.video, "inputMessageVideo", "video", "inputVideo"),
            (.animation, "inputMessageAnimation", "animation", "inputAnimation"),
            (.audio, "inputMessageAudio", "audio", "inputAudio"),
            (.voice, "inputMessageVoiceNote", "voice_note", "inputVoiceNote"),
            (.document, "inputMessageDocument", "document", "inputDocument"),
        ]
        for (kind, type, field, inner) in shapes {
            let content = TDLibSession.fileContent(path: "/tmp/x", caption: nil, kind: kind)
            XCTAssertEqual(content["@type"]?.stringValue, type)
            XCTAssertEqual(content[field]?["@type"]?.stringValue, inner)
            XCTAssertEqual(content[field]?[field]?["path"]?.stringValue, "/tmp/x")
            XCTAssertNil(content["caption"])
        }
    }

    func testChatsAreAlsoMatchedLocallyAndByResemblance() {
        let chats = [TGUserChat(id: 1, title: "Deleted Account", kind: .personal),
                     TGUserChat(id: 2, title: "Lucas Moreno", kind: .personal),
                     TGUserChat(id: 3, title: "Ofertas PC", kind: .channel)]
        XCTAssertEqual(TDLibSession.localMatches("deleted account", in: chats, fuzzy: true).map(\.id), [1])
        XCTAssertEqual(TDLibSession.localMatches("lucas", in: chats, fuzzy: true).map(\.id), [2])
        // Nombres mal oídos por el dictado.
        XCTAssertEqual(TDLibSession.localMatches("Lukas", in: chats, fuzzy: true).first?.id, 2)
        XCTAssertEqual(TDLibSession.localMatches("Delated account", in: chats, fuzzy: true).first?.id, 1)
        XCTAssertTrue(TDLibSession.localMatches("Marta", in: chats, fuzzy: true).isEmpty)
        XCTAssertTrue(TDLibSession.localMatches("Lukas", in: chats, fuzzy: false).isEmpty)
    }

    func testAliasesComeFromTheActiveUsernames() {
        XCTAssertEqual(TDLibSession.alias(fromUsernames: ["active_usernames": ["lucas_mor82", "otro"]]), "lucas_mor82")
        XCTAssertEqual(TDLibSession.alias(fromUsernames: ["active_usernames": [], "editable_username": "anna"]), "anna")
        XCTAssertNil(TDLibSession.alias(fromUsernames: ["active_usernames": [], "editable_username": ""]))
        XCTAssertNil(TDLibSession.alias(fromUsernames: nil))
        // También se encuentra a alguien por su alias.
        let chats = [TGUserChat(id: 1, title: "Lucas Moreno", kind: .personal, username: "lucas_mor82")]
        XCTAssertEqual(TDLibSession.localMatches("@lucas_mor", in: chats, fuzzy: false).map(\.id), [1])
        XCTAssertEqual(chats[0].displayName, "Lucas Moreno (@lucas_mor82)")
    }

    func testFilesAreFoundInEveryKindOfMessage() {
        let photo: JSONValue = ["id": 5, "content": ["@type": "messagePhoto", "photo": ["sizes": [
            ["photo": ["id": 1]], ["photo": ["id": 2]]]]]]
        XCTAssertEqual(TDLibSession.mediaFile(in: photo)?.file["id"]?.intValue, 2, "el tamaño mayor")
        XCTAssertEqual(TDLibSession.mediaFile(in: photo)?.name, "foto-5.jpg")
        let voice: JSONValue = ["id": 6, "content": ["@type": "messageVoiceNote", "voice_note": ["voice": ["id": 3]]]]
        XCTAssertEqual(TDLibSession.mediaFile(in: voice)?.kind, "nota de voz")
        let doc: JSONValue = ["id": 7, "content": ["@type": "messageDocument", "document": ["file_name": "factura.pdf", "document": ["id": 4]]]]
        XCTAssertEqual(TDLibSession.mediaFile(in: doc)?.name, "factura.pdf")
        XCTAssertNil(TDLibSession.mediaFile(in: ["id": 8, "content": ["@type": "messageText"]]))
    }

    func testPollsLocationsAndDiceAreReadable() {
        let poll: JSONValue = ["content": ["@type": "messagePoll", "poll": [
            "question": ["text": "¿Cena?"], "is_closed": false,
            "options": [["text": ["text": "Viernes"], "voter_count": 3, "is_chosen": true], ["text": ["text": "Sábado"], "voter_count": 0]],
        ]]]
        XCTAssertEqual(TDLibSession.text(of: poll), "[encuesta] ¿Cena? · 0) Viernes (3) ✓ tu voto · 1) Sábado")
        let place: JSONValue = ["content": ["@type": "messageLocation", "location": ["latitude": 42.88, "longitude": -8.54]]]
        XCTAssertEqual(TDLibSession.text(of: place), "[ubicación] 42.88000, -8.54000")
        let dice: JSONValue = ["content": ["@type": "messageDice", "emoji": "🎲", "value": 5]]
        XCTAssertEqual(TDLibSession.text(of: dice), "[dado 🎲 5]")
        let card: JSONValue = ["content": ["@type": "messageContact", "contact": ["first_name": "Lucas", "last_name": "Moreno"]]]
        XCTAssertEqual(TDLibSession.text(of: card), "[contacto] Lucas Moreno")
    }

    func testSpecialContentMatchesTheTDLibScheme() {
        let quiz = TDLibSession.specialContent(.poll(question: "2+2", options: ["3", "4"], anonymous: false,
                                                     multipleAnswers: false, correctOption: 1))
        XCTAssertEqual(quiz["@type"]?.stringValue, "inputMessagePoll")
        XCTAssertEqual(quiz["options"]?.arrayValue?.first?["@type"]?.stringValue, "inputPollOption")
        XCTAssertEqual(quiz["options"]?.arrayValue?.last?["text"]?["text"]?.stringValue, "4")
        XCTAssertEqual(quiz["type"]?["@type"]?.stringValue, "inputPollTypeQuiz")
        XCTAssertEqual(quiz["type"]?["correct_option_ids"]?.arrayValue?.first?.intValue, 1)
        let regular = TDLibSession.specialContent(.poll(question: "?", options: ["a", "b"], anonymous: true,
                                                        multipleAnswers: true, correctOption: nil))
        XCTAssertEqual(regular["type"]?["@type"]?.stringValue, "inputPollTypeRegular")
        XCTAssertEqual(regular["allows_multiple_answers"]?.boolValue, true)
        XCTAssertEqual(TDLibSession.specialContent(.location(latitude: 1, longitude: 2))["location"]?["@type"]?.stringValue, "location")
        XCTAssertEqual(TDLibSession.specialContent(.dice(emoji: "🎯"))["emoji"]?.stringValue, "🎯")
    }

    func testScheduledMessageIDsSurviveTheJSONRoundTrip() {
        // Los programados de Telegram llevan identificadores de unos 1,5·10^15 (visto contra la API).
        let raw: JSONValue = ["id": .number(1_513_184_422_789_164), "chat_id": .number(123_456_789)]
        XCTAssertEqual(raw["id"]?.intValue, 1_513_184_422_789_164)
        XCTAssertNil(JSONValue.number(1e17).intValue, "por encima de 2^53 ya no es exacto")
        XCTAssertNil(JSONValue.number(2.5).intValue)
    }

    func testNeverWritesToTheOwnBotChat() async throws {
        let session = makeSession(FakeTD(), states: Locked([]))
        await session.blockWrites { [777] }
        for attempt in 0..<3 {
            do {
                switch attempt {
                case 0: try await session.send(chatID: 777, text: "hola")
                case 1: try await session.forward(fromChatID: 1, messageIDs: [2], toChatID: 777)
                default: try await session.reply(chatID: 777, messageID: 1, text: "hola")
                }
                XCTFail("no debería escribir al propio bot")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("bot de SaySo"), "\(error)")
            }
        }
    }

}
