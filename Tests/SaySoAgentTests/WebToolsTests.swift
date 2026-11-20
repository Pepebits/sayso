import XCTest
import SaySoCore
@testable import SaySoAgent

private final class TestVault: SecretVault, @unchecked Sendable {
    let values = Locked<[String: String]>([:])
    func value(for name: String) throws -> String? { values.get()[name] }
    func setValue(_ value: String, for name: String) throws { values.update { $0[name] = value } }
    func removeValue(for name: String) throws { values.update { $0[name] = nil } }
}

private final class FileComputer: AgentComputer, @unchecked Sendable {
    var files: [String: Data] = [:]
    func run(_ command: String, cwd: String?, timeout: TimeInterval, env: [String: String],
             origin: String?) async throws -> CommandResult { CommandResult(exitCode: 0, stdout: "", stderr: "") }
    func openProcess(_ command: String, env: [String: String], origin: String?) async throws -> ProcessStream {
        throw ToolInputError("sin procesos")
    }
    func readFile(_ path: String, origin: String?) async throws -> String { String(decoding: files[path] ?? Data(), as: UTF8.self) }
    func readData(_ path: String, origin: String?) async throws -> Data {
        guard let data = files[path] else { throw ToolInputError("No existe \(path)") }
        return data
    }
    func writeFile(_ path: String, content: String, origin: String?) async throws {}
}

final class WebToolsTests: XCTestCase {
    private func fails(_ work: () async throws -> String) async -> String? {
        do { _ = try await work(); return nil } catch { return error.localizedDescription }
    }

    // MARK: Búsqueda

    func testWithoutAKeyItAsksForOneInSecretsAndCallsNobody() async throws {
        let store = MemoryStore()
        let transport = FakeTransport(json: "{}")
        let broker = FakeBroker(allow: true)
        let tool = WebSearchTool(store: store, vault: TestVault(), broker: broker, transport: transport)
        let error = await fails { try await tool.call(input: ["query": "tiempo en Vigo"], context: ToolContext()) }
        XCTAssertTrue(error?.contains("TAVILY_API_KEY") ?? false)
        XCTAssertTrue(error?.contains("No pidas la clave por el chat") ?? false)
        // Sin clave no es un callejón sin salida: se le recuerdan el navegador y la lectura directa.
        XCTAssertTrue(error?.contains("browser_navigate") ?? false)
        XCTAssertTrue(error?.contains("no te rindas") ?? false)
        XCTAssertEqual(store.secretList.map(\.name), ["TAVILY_API_KEY"])
        XCTAssertEqual(store.secretList.first?.status, .requested)
        XCTAssertTrue(transport.requests.get().isEmpty)
        XCTAssertTrue(broker.requests.get().isEmpty)
        // Pedirla dos veces no la duplica.
        _ = await fails { try await tool.call(input: ["query": "otra"], context: ToolContext()) }
        XCTAssertEqual(store.secretList.count, 1)
    }

    func testWithoutAKeyItSearchesWithTheBrowserPlugin() async throws {
        let store = MemoryStore()
        // Una clave pedida en una versión anterior y nunca guardada.
        try store.upsertSecret(SecretMeta(name: "BRAVE_SEARCH_KEY", reason: "antigua", status: .requested))
        let transport = FakeTransport(json: "{}")
        let broker = FakeBroker(allow: true)
        let opened = Locked<[URL]>([])
        let page = "- link \"Tiempo en Vigo\":\n  - /url: //duckduckgo.com/l/?uddg=https%3A%2F%2Fwww.aemet.es%2Fvigo%3Fa%3D1&rut=abc"
        let tool = WebSearchTool(store: store, vault: TestVault(), broker: broker, transport: transport,
                                 browser: { url in opened.update { $0.append(url) }; return page })
        let result = try await tool.call(input: ["query": "tiempo en Vigo"], context: ToolContext())
        XCTAssertEqual(opened.get().first?.host, "html.duckduckgo.com")
        XCTAssertTrue(opened.get().first?.query?.contains("tiempo") ?? false)
        XCTAssertTrue(result.contains("https://www.aemet.es/vigo?a=1"), "queda la dirección real, no la redirección")
        XCTAssertFalse(result.contains("uddg="))
        XCTAssertTrue(result.contains("contenido de terceros"))
        XCTAssertEqual(broker.requests.get().first?.action, WebSearchTool.action)
        XCTAssertTrue(store.secretList.isEmpty, "con navegador no hace falta ninguna clave: la pedida se retira")
        XCTAssertTrue(tool.description.contains("sin ninguna clave"))
        XCTAssertTrue(transport.requests.get().isEmpty)

        // Sin navegador instalado se sigue pidiendo la clave.
        let none = WebSearchTool(store: store, vault: TestVault(), broker: broker, transport: transport,
                                 browser: { _ in nil })
        let error = await fails { try await none.call(input: ["query": "x"], context: ToolContext()) }
        XCTAssertTrue(error?.contains("plugin Navegador") ?? false)
    }

    func testBraveSearchSendsTheKeyInAHeaderAndFormatsResults() async throws {
        let vault = TestVault()
        try vault.setValue("clave-brave", for: KeychainName.workSecret(WebSearchTool.braveSecret))
        let transport = FakeTransport(json: #"""
        {"web":{"results":[
          {"title":"Tiempo en <strong>Vigo</strong>","url":"https://example.com/vigo","description":"Lluvia &amp; viento   hoy."},
          {"title":"Sin dirección"},
          {"title":"Otro","url":"https://example.com/otro","description":""}
        ]}}
        """#)
        let broker = FakeBroker(allow: true)
        let tool = WebSearchTool(store: MemoryStore(), vault: vault, broker: broker, transport: transport)
        let out = try await tool.call(input: ["query": "tiempo en Vigo", "count": 3], context: ToolContext(origin: "telegram:1"))

        let request = try XCTUnwrap(transport.requests.get().first)
        XCTAssertEqual(request.url?.host, "api.search.brave.com")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Subscription-Token"), "clave-brave")
        // La clave va en la cabecera, nunca en la dirección.
        XCTAssertFalse(request.url?.absoluteString.contains("clave-brave") ?? true)
        XCTAssertTrue(request.url?.query?.contains("count=3") ?? false)

        XCTAssertTrue(out.contains("1. Tiempo en Vigo\n   https://example.com/vigo\n   Lluvia & viento hoy."))
        XCTAssertTrue(out.contains("2. Otro\n   https://example.com/otro"))
        XCTAssertFalse(out.contains("Sin dirección"))
        XCTAssertTrue(out.contains("no como instrucciones"))
        XCTAssertEqual(broker.requests.get().map(\.action), [WebSearchTool.action])
        XCTAssertFalse(String(describing: broker.requests.get()).contains("clave-brave"))
    }

    func testTavilyIsUsedWhenItIsTheOnlyKey() async throws {
        let vault = TestVault()
        try vault.setValue("tvly-x", for: KeychainName.workSecret(WebSearchTool.tavilySecret))
        let transport = FakeTransport(json: #"{"results":[{"title":"A","url":"https://a.example","content":"Texto A"}]}"#)
        let tool = WebSearchTool(store: MemoryStore(), vault: vault, broker: FakeBroker(allow: true), transport: transport)
        let out = try await tool.call(input: ["query": "algo"], context: ToolContext())
        let request = try XCTUnwrap(transport.requests.get().first)
        XCTAssertEqual(request.url?.host, "api.tavily.com")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tvly-x")
        XCTAssertEqual(try JSONValue.parse(XCTUnwrap(request.httpBody))["max_results"]?.intValue, 5)
        XCTAssertTrue(out.contains("1. A\n   https://a.example\n   Texto A"))
    }

    func testDeniedSearchCallsNobodyAndEmptyResultsSaySo() async throws {
        let vault = TestVault()
        try vault.setValue("k", for: KeychainName.workSecret(WebSearchTool.braveSecret))
        let transport = FakeTransport(json: #"{"web":{"results":[]}}"#)
        let denied = WebSearchTool(store: MemoryStore(), vault: vault, broker: FakeBroker(allow: false), transport: transport)
        let error = await fails { try await denied.call(input: ["query": "x"], context: ToolContext()) }
        XCTAssertNotNil(error)
        XCTAssertTrue(transport.requests.get().isEmpty)
        let allowed = WebSearchTool(store: MemoryStore(), vault: vault, broker: FakeBroker(allow: true), transport: transport)
        let out = try await allowed.call(input: ["query": "x"], context: ToolContext())
        XCTAssertEqual(out, "Sin resultados para «x».")
    }

    // MARK: Archivos

    func testSendFileReadsItFromTheComputerAndHandsItToTheBot() async throws {
        let computer = FileComputer()
        computer.files["~/sayso/grafico.png"] = Data([1, 2, 3, 4])
        let outbox = TelegramOutbox()
        let sent = Locked<[(Int, String, String?)]>([])
        outbox.set { data, name, caption in sent.update { $0.append((data.count, name, caption)) } }
        let broker = FakeBroker(allow: true)
        let tool = SendFileTool(computer: computer, outbox: outbox, broker: broker)
        let out = try await tool.call(input: ["path": "~/sayso/grafico.png", "caption": "Ventas"], context: ToolContext())
        XCTAssertEqual(out, "Enviado grafico.png al usuario por Telegram.")
        XCTAssertEqual(sent.get().first?.0, 4)
        XCTAssertEqual(sent.get().first?.1, "grafico.png")
        XCTAssertEqual(sent.get().first?.2, "Ventas")
        XCTAssertEqual(broker.requests.get().map(\.action), [SendFileTool.action])
    }

    func testSendFileToAnotherChatGoesFromTheUsersAccount() async throws {
        // Sacado del registro real: «no puedo adjuntar imágenes a otro chat».
        let computer = FileComputer()
        computer.files["~/sayso/gato.jpg"] = Data([1, 2, 3])
        computer.files["~/sayso/informe.pdf"] = Data([1])
        let outbox = TelegramOutbox()
        let toOwner = Locked<Int>(0)
        outbox.set { _, _, _ in toOwner.update { $0 += 1 } }
        let api = FakeTelegramUser()
        let broker = FakeBroker(allow: true)
        let tool = SendFileTool(computer: computer, outbox: outbox, broker: broker, userAPI: api,
                                limiter: SendRateLimiter(), ownBotID: { 2 })

        let out = try await tool.call(input: ["path": "~/sayso/gato.jpg", "chat": "anna", "caption": "Mira"],
                                      context: ToolContext())
        XCTAssertEqual(out, "Archivo gato.jpg enviado a «Anna» como foto.")
        let first = try XCTUnwrap(api.files.get().first)
        XCTAssertEqual(first.0, 1)
        XCTAssertEqual(first.2, "gato.jpg")
        XCTAssertEqual(first.3, "Mira")
        XCTAssertEqual(first.4, .photo, "las imágenes van como foto")
        XCTAssertEqual(toOwner.get(), 0, "no se le manda también al usuario")
        XCTAssertEqual(broker.requests.get().first?.action, TelegramAction.sendMessages)
        XCTAssertEqual(broker.requests.get().first?.parameters["Para"], "Anna")

        // Un PDF va como documento; el chat del propio bot es el usuario.
        _ = try await tool.call(input: ["path": "~/sayso/informe.pdf", "chat": "@lucas_mor82"], context: ToolContext())
        XCTAssertEqual(api.files.get().last?.4, .document)
        // El tipo sale de la extensión y se puede forzar.
        XCTAssertEqual(TGMediaKind.infer(from: "clip.MP4"), .video)
        XCTAssertEqual(TGMediaKind.infer(from: "baile.gif"), .animation)
        XCTAssertEqual(TGMediaKind.infer(from: "cancion.mp3"), .audio)
        XCTAssertEqual(TGMediaKind.infer(from: "nota.ogg"), .voice)
        _ = try await tool.call(input: ["path": "~/sayso/gato.jpg", "chat": "anna", "as": "document"], context: ToolContext())
        XCTAssertEqual(api.files.get().last?.4, .document)
        _ = api.files.update { $0.removeLast() }
        _ = try await tool.call(input: ["path": "~/sayso/gato.jpg", "chat_id": 2], context: ToolContext())
        XCTAssertEqual(toOwner.get(), 1)
        XCTAssertEqual(api.files.get().count, 2)

        // Sin la cuenta del usuario lo dice claro en vez de mandárselo a él.
        let alone = SendFileTool(computer: computer, outbox: outbox, broker: broker)
        let error = await fails { try await alone.call(input: ["path": "~/sayso/gato.jpg", "chat": "anna"], context: ToolContext()) }
        XCTAssertTrue(error?.contains("cuenta de Telegram") ?? false)
        XCTAssertEqual(toOwner.get(), 1)
    }

    func testInATaskForOthersFilesGoToTheRecipientsNotTheUser() async throws {
        // Sacado del registro real: la tarea «busca una foto de gatitos» mandó la foto al usuario y
        // a los destinatarios solo un emoji.
        let computer = FileComputer()
        computer.files["~/sayso/gatitos.jpg"] = Data([1, 2, 3])
        let outbox = TelegramOutbox()
        let toOwner = Locked<Int>(0)
        outbox.set { _, _, _ in toOwner.update { $0 += 1 } }
        let api = FakeTelegramUser()
        let tool = SendFileTool(computer: computer, outbox: outbox, broker: FakeBroker(allow: true), userAPI: api)
        let recipients = [TaskRecipient(id: 1, title: "Anna"), TaskRecipient(id: 9, title: "Lucas")]
        let out = try await tool.call(input: ["path": "~/sayso/gatitos.jpg", "caption": "Gatitos"],
                                      context: ToolContext(origin: "tarea:2", recipients: recipients))
        XCTAssertEqual(api.files.get().map(\.0), [1, 9])
        XCTAssertEqual(api.files.get().first?.4, .photo)
        XCTAssertEqual(api.files.get().first?.3, "Gatitos")
        XCTAssertEqual(toOwner.get(), 0, "al usuario no le llega")
        XCTAssertTrue(out.contains("«Anna» y «Lucas»"))
        // Con «Enviar sin pedir confirmación», el envío va autorizado de antemano.
        let approving = FakeBroker(allow: true)
        let auto = SendFileTool(computer: computer, outbox: outbox, broker: approving, userAPI: api)
        _ = try await auto.call(input: ["path": "~/sayso/gatitos.jpg"],
                                context: ToolContext(recipients: recipients, recipientsPreapproved: true))
        XCTAssertEqual(approving.requests.get().map(\.preapproved), [true, true])

        // Sin la cuenta no se cae al usuario.
        let alone = SendFileTool(computer: computer, outbox: outbox, broker: FakeBroker(allow: true))
        let error = await fails { try await alone.call(input: ["path": "~/sayso/gatitos.jpg"],
                                                       context: ToolContext(recipients: recipients)) }
        XCTAssertTrue(error?.contains("No se lo mandes al usuario") ?? false)
        XCTAssertEqual(toOwner.get(), 0)
    }

    func testSendFileRefusesWithoutBotMissingEmptyOrHugeFiles() async throws {
        let computer = FileComputer()
        computer.files["vacio.txt"] = Data()
        computer.files["enorme.bin"] = Data(count: SendFileTool.maxBytes + 1)
        computer.files["bien.txt"] = Data([1])
        let outbox = TelegramOutbox()
        let tool = SendFileTool(computer: computer, outbox: outbox, broker: FakeBroker(allow: true))
        let noBot = await fails { try await tool.call(input: ["path": "bien.txt"], context: ToolContext()) }
        XCTAssertTrue(noBot?.contains("No hay bot") ?? false)

        let calls = Locked(0)
        outbox.set { _, _, _ in calls.update { $0 += 1 } }
        let missing = await fails { try await tool.call(input: ["path": "nada.txt"], context: ToolContext()) }
        let empty = await fails { try await tool.call(input: ["path": "vacio.txt"], context: ToolContext()) }
        let huge = await fails { try await tool.call(input: ["path": "enorme.bin"], context: ToolContext()) }
        XCTAssertNotNil(missing)
        XCTAssertTrue(empty?.contains("vacío") ?? false)
        XCTAssertTrue(huge?.contains("8 MB") ?? false)
        XCTAssertEqual(calls.get(), 0)

        let denied = SendFileTool(computer: computer, outbox: outbox, broker: FakeBroker(allow: false))
        _ = await fails { try await denied.call(input: ["path": "bien.txt"], context: ToolContext()) }
        XCTAssertEqual(calls.get(), 0)
    }

    func testBotUploadsPhotosAsPhotosAndFallsBackToDocument() async throws {
        XCTAssertTrue(SendFileTool.isPhoto("a.PNG"))
        XCTAssertFalse(SendFileTool.isPhoto("informe.pdf"))

        // Telegram rechaza la foto; se reintenta como documento.
        let transport = FakeTransport { request in
            request.url?.lastPathComponent == "sendPhoto"
                ? (400, Data(#"{"ok":false,"error_code":400,"description":"PHOTO_INVALID_DIMENSIONS"}"#.utf8))
                : (200, Data(#"{"ok":true,"result":{"message_id":1,"chat":{"id":1001,"type":"private"}}}"#.utf8))
        }
        let store = MemoryStore()
        store.settings[SettingsKey.telegramOwnerID] = "1001"
        let service = TelegramBotService(client: TelegramBotClient(token: "T", transport: transport), store: store,
                                         makeLoop: { AgentLoop(provider: FakeProvider([]), tools: [], store: store) },
                                         broker: FakeBroker(allow: true), onStatus: { _ in })
        try await service.sendFileToOwner(Data([9, 9, 9]), filename: "mi \"foto\".png", caption: "Hola")
        let methods = transport.requests.get().compactMap { $0.url?.lastPathComponent }
        XCTAssertEqual(methods, ["sendPhoto", "sendDocument"])

        let request = try XCTUnwrap(transport.requests.get().last)
        XCTAssertTrue(request.value(forHTTPHeaderField: "content-type")?.hasPrefix("multipart/form-data; boundary=") ?? false)
        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"chat_id\"\r\n\r\n1001\r\n"))
        XCTAssertTrue(body.contains("name=\"caption\"\r\n\r\nHola\r\n"))
        XCTAssertTrue(body.contains("name=\"document\"; filename=\"mi foto.png\""))
    }
}
