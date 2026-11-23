import XCTest
import SaySoCore
@testable import SaySoAgent

final class ProviderTests: XCTestCase {
    let tools = [ToolSpec(name: "echo", description: "d", inputSchema: .objectSchema(["text": .property("string", "t")]))]

    func testJSONValueRoundTrip() throws {
        let v = try JSONValue.parse(#"{"a":true,"b":3,"c":1.5,"d":null,"e":["x"]}"#)
        XCTAssertEqual(v["a"], .bool(true))
        XCTAssertEqual(v["b"]?.intValue, 3)
        XCTAssertEqual(v["c"], .number(1.5))
        XCTAssertEqual(v["d"], .null)
        XCTAssertEqual(v["e"]?[0], "x")
        XCTAssertEqual(JSONValue.object(["n": 1024]).jsonString(), #"{"n":1024}"#)
    }

    func testAnthropicRequestAndTextResponse() async throws {
        let transport = FakeTransport(json: """
        {"content":[{"type":"text","text":"Hola"}],"stop_reason":"end_turn"}
        """)
        let p = AnthropicProvider(apiKey: "k-1", fullModel: "m", fastModel: "f", transport: transport)
        let r = try await p.complete(ModelRequest(model: "m", system: "sys", messages: [.user("hi")], tools: tools, maxTokens: 100))
        XCTAssertEqual(r.text, "Hola")
        XCTAssertEqual(r.stopReason, .endTurn)

        let req = try XCTUnwrap(transport.requests.get().first)
        XCTAssertEqual(req.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(req.value(forHTTPHeaderField: "x-api-key"), "k-1")
        XCTAssertEqual(req.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        let body = try XCTUnwrap(transport.bodies().first)
        XCTAssertEqual(body["system"]?[0]?["text"], "sys")
        XCTAssertNil(body["system"]?[0]?["cache_control"])
        XCTAssertEqual(body["max_tokens"]?.intValue, 100)
        XCTAssertEqual(body["tools"]?[0]?["input_schema"]?["type"], "object")
        XCTAssertEqual(body["messages"]?[0]?["content"]?[0]?["text"], "hi")
    }

    func testAnthropicCachesStableSystemAndLastMessage() {
        let request = ModelRequest(model: "m", stableSystem: "fijo", system: "Fecha: hoy",
                                   messages: [.user("hola"), .assistant("¿sí?"), .user("busca")],
                                   tools: tools, maxTokens: 100)
        let body = AnthropicProvider.body(for: request)
        XCTAssertEqual(body["system"]?[0]?["text"], "fijo")
        XCTAssertEqual(body["system"]?[0]?["cache_control"]?["type"], "ephemeral")
        XCTAssertEqual(body["system"]?[1]?["text"], "Fecha: hoy")
        XCTAssertNil(body["system"]?[1]?["cache_control"])
        XCTAssertEqual(body["messages"]?[2]?["content"]?[0]?["cache_control"]?["type"], "ephemeral")
        XCTAssertNil(body["messages"]?[0]?["content"]?[0]?["cache_control"])
        // Sin herramientas (una pregunta suelta) no compensa marcar los mensajes.
        let plain = AnthropicProvider.body(for: ModelRequest(model: "m", system: "s", messages: [.user("x")]))
        XCTAssertNil(plain["messages"]?[0]?["content"]?[0]?["cache_control"])
        // Para OpenAI y compatibles, las dos partes juntas.
        XCTAssertEqual(request.fullSystem, "fijo\n\nFecha: hoy")
    }

    func testAnthropicCacheReadsCountAsContextButCostLess() throws {
        let json = try JSONValue.parse(Data("""
        {"content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn",
         "usage":{"input_tokens":100,"cache_read_input_tokens":10000,"cache_creation_input_tokens":400,"output_tokens":20}}
        """.utf8))
        let r = try AnthropicProvider.parse(json)
        XCTAssertEqual(r.inputTokens, 10_500)
        XCTAssertEqual(r.billedInputTokens, 100 + 1_000 + 500)
    }

    func testAnthropicToolUseParsingAndToolResultEncoding() throws {
        let json = try JSONValue.parse("""
        {"content":[{"type":"text","text":"Voy"},{"type":"tool_use","id":"tu_1","name":"echo","input":{"text":"x"}}],
         "stop_reason":"tool_use"}
        """)
        let r = try AnthropicProvider.parse(json)
        XCTAssertEqual(r.stopReason, .toolUse)
        XCTAssertEqual(r.toolCalls, [ToolCall(id: "tu_1", name: "echo", input: ["text": "x"])])

        let encoded = AnthropicProvider.encode(ModelMessage(role: .user, content: [
            .toolResult(toolUseID: "tu_1", content: "no", isError: true),
        ]))
        XCTAssertEqual(encoded["content"]?[0]?["type"], "tool_result")
        XCTAssertEqual(encoded["content"]?[0]?["tool_use_id"], "tu_1")
        XCTAssertEqual(encoded["content"]?[0]?["is_error"], true)
    }

    func testOpenAITextResponseWithoutKey() async throws {
        let transport = FakeTransport(json: """
        {"choices":[{"message":{"role":"assistant","content":"Buenas"},"finish_reason":"stop"}]}
        """)
        let p = OpenAICompatibleProvider(baseURL: URL(string: "http://localhost:11434/v1")!, apiKey: nil,
                                         fullModel: "llama", fastModel: "llama", transport: transport)
        let r = try await p.complete(ModelRequest(model: "llama", system: "sys", messages: [.user("hi")]))
        XCTAssertEqual(r.text, "Buenas")
        XCTAssertEqual(r.stopReason, .endTurn)
        let req = try XCTUnwrap(transport.requests.get().first)
        XCTAssertEqual(req.url?.absoluteString, "http://localhost:11434/v1/chat/completions")
        XCTAssertNil(req.value(forHTTPHeaderField: "Authorization"))
        let body = try XCTUnwrap(transport.bodies().first)
        XCTAssertEqual(body["messages"]?[0]?["role"], "system")
        XCTAssertNil(body["tools"])
    }

    func testOpenAIToolCallsParsingAndEncoding() async throws {
        let transport = FakeTransport(json: """
        {"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[
          {"id":"call_9","type":"function","function":{"name":"echo","arguments":"{\\"text\\":\\"hola\\"}"}}]},
          "finish_reason":"tool_calls"}]}
        """)
        let p = OpenAICompatibleProvider(baseURL: URL(string: "https://api.openai.com/v1")!, apiKey: "sk-1",
                                         fullModel: "g", fastModel: "g", transport: transport)
        let history: [ModelMessage] = [
            .user("hola"),
            ModelMessage(role: .assistant, content: [.toolUse(id: "call_1", name: "echo", input: ["text": "a"])]),
            ModelMessage(role: .user, content: [.toolResult(toolUseID: "call_1", content: "eco", isError: false)]),
        ]
        let r = try await p.complete(ModelRequest(model: "g", system: "", messages: history, tools: tools))
        XCTAssertEqual(r.stopReason, .toolUse)
        XCTAssertEqual(r.toolCalls, [ToolCall(id: "call_9", name: "echo", input: ["text": "hola"])])

        XCTAssertEqual(transport.requests.get().first?.value(forHTTPHeaderField: "Authorization"), "Bearer sk-1")
        let body = try XCTUnwrap(transport.bodies().first)
        let msgs = try XCTUnwrap(body["messages"]?.arrayValue)
        XCTAssertEqual(msgs.count, 3)
        XCTAssertEqual(msgs[1]["tool_calls"]?[0]?["function"]?["arguments"], #"{"text":"a"}"#)
        XCTAssertEqual(msgs[2]["role"], "tool")
        XCTAssertEqual(msgs[2]["tool_call_id"], "call_1")
        XCTAssertEqual(body["tools"]?[0]?["function"]?["name"], "echo")
    }

    func testHTTPErrorsAreReadable() async {
        let transport = FakeTransport(status: 401, json: #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#)
        let p = AnthropicProvider(apiKey: "bad", fullModel: "m", fastModel: "f", transport: transport)
        do {
            _ = try await p.complete(ModelRequest(model: "m", system: "", messages: [.user("x")]))
            XCTFail("debía fallar")
        } catch let error as ProviderError {
            XCTAssertEqual(error, .http(status: 401, message: "invalid x-api-key"))
            XCTAssertTrue(error.localizedDescription.contains("clave de API no es válida"))
        } catch { XCTFail("\(error)") }
        XCTAssertTrue(ProviderError.http(status: 429, message: "").localizedDescription.contains("Límite"))
    }

    func testFactoryReadsKeyFromVault() throws {
        struct Vault: SecretVault {
            func value(for name: String) throws -> String? { name == "provider.x" ? "k-123" : nil }
            func setValue(_ value: String, for name: String) throws {}
            func removeValue(for name: String) throws {}
        }
        let account = ProviderAccount(name: "Claude", kind: .anthropic, baseURL: URL(string: "https://api.anthropic.com")!,
                                      fullModel: "a", fastModel: "b", keychainKey: "provider.x")
        let p = try ProviderFactory.make(account: account, vault: Vault(), transport: FakeTransport(json: "{}"))
        XCTAssertTrue(p is AnthropicProvider)
        XCTAssertEqual(p.fastModel, "b")

        var missing = account
        missing.keychainKey = "otra"
        XCTAssertThrowsError(try ProviderFactory.make(account: missing, vault: Vault()))

        let local = ProviderAccount(name: "Ollama", kind: .openAICompatible, baseURL: URL(string: "http://localhost:11434/v1")!,
                                    fullModel: "l", fastModel: "l", keychainKey: nil)
        XCTAssertTrue(try ProviderFactory.make(account: local, vault: Vault()) is OpenAICompatibleProvider)
    }
}

final class SpeedTests: XCTestCase {
    private let request = ModelRequest(model: "m", system: "s", messages: [.user("hola")], tools: [], maxTokens: 10)

    func testDeepSeekThinkingIsDisabledAndOthersAreUntouched() {
        let deepseek = OpenAICompatibleProvider(baseURL: URL(string: "https://api.deepseek.com/v1")!, apiKey: "k",
                                                fullModel: "a", fastModel: "b")
        let openai = OpenAICompatibleProvider(baseURL: URL(string: "https://api.openai.com/v1")!, apiKey: "k",
                                              fullModel: "a", fastModel: "b")
        XCTAssertTrue(deepseek.disablesThinking)
        XCTAssertFalse(openai.disablesThinking)
        XCTAssertEqual(OpenAICompatibleProvider.body(for: request, disableThinking: true)["thinking"]?["type"]?.stringValue,
                       "disabled")
        XCTAssertNil(OpenAICompatibleProvider.body(for: request)["thinking"])
    }

    func testAutoSpeedSendsShortMessagesToTheFastModel() throws {
        let store = MemoryStore()
        XCTAssertTrue(AgentLoop.prefersFastModel(for: "¿qué hora es?", store: store), "activado si no hay ajuste")
        XCTAssertFalse(AgentLoop.prefersFastModel(for: String(repeating: "a", count: 241), store: store))
        try store.setSetting("0", for: SettingsKey.autoSpeed)
        XCTAssertFalse(AgentLoop.prefersFastModel(for: "¿qué hora es?", store: store))
    }

    func testRespondCanUseTheFastModelAndACap() async throws {
        let provider = FakeProvider([.text("vale")])
        let loop = AgentLoop(provider: provider, tools: [], store: MemoryStore())
        _ = try await loop.respond(to: "hola", chatID: "voz", useFastModel: true, instructions: AgentPrompts.voice,
                                   maxTokens: 600)
        let sent = provider.requests.get()[0]
        XCTAssertEqual(sent.model, "fast-model")
        XCTAssertEqual(sent.maxTokens, 600)
        XCTAssertTrue(sent.fullSystem.contains("una sola pregunta"))
    }
}

final class ImageTests: XCTestCase {
    /// Un PNG de 3000×2000 hecho al vuelo.
    static func bigPNG() -> Data {
        let ctx = CGContext(data: nil, width: 3000, height: 2000, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: 0.2, green: 0.6, blue: 0.4, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 3000, height: 2000))
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    func testImagesAreShrunkToJPEG() throws {
        let image = try ModelImage.prepared(from: Self.bigPNG())
        XCTAssertEqual(image.mediaType, "image/jpeg")
        XCTAssertEqual(max(image.width, image.height), ModelImage.maxSide)
        XCTAssertThrowsError(try ModelImage.prepared(from: Data("no soy una imagen".utf8)))
    }

    func testProvidersEncodeImages() {
        let message = ModelMessage(role: .user, content: [.toolResult(toolUseID: "t1", content: "ok", isError: false),
                                                          .image(mediaType: "image/jpeg", data: Data([1, 2, 3]))])
        let anthropic = AnthropicProvider.encode(message)
        XCTAssertEqual(anthropic["content"]?[1]?["source"]?["data"]?.stringValue, "AQID")
        let openai = OpenAICompatibleProvider.encode(message)
        XCTAssertEqual(openai.count, 2, "el resultado de la herramienta y, detrás, un mensaje del usuario con la imagen")
        XCTAssertEqual(openai[1]["content"]?[0]?["image_url"]?["url"]?.stringValue, "data:image/jpeg;base64,AQID")
    }

    func testOnlyVisionAccountsSeeImages() {
        let url = URL(string: "https://api.deepseek.com")!
        XCTAssertFalse(ProviderAccount(name: "DeepSeek", kind: .openAICompatible, baseURL: url, fullModel: "m", fastModel: "m",
                                       keychainKey: nil).seesImages)
        XCTAssertTrue(ProviderAccount(name: "Claude", kind: .anthropic, baseURL: URL(string: "https://api.anthropic.com")!,
                                      fullModel: "m", fastModel: "m", keychainKey: nil).seesImages)
        var local = ProviderAccount(name: "Ollama", kind: .openAICompatible, baseURL: URL(string: "http://localhost:11434/v1")!,
                                    fullModel: "llava", fastModel: "llava", keychainKey: nil)
        local.vision = true
        XCTAssertTrue(local.seesImages)
    }

    func testTheLoopAttachesImagesOnlyWhenTheModelSeesThem() async throws {
        struct Looker: ImageProducingTool {
            var name: String { "view_image" }
            var description: String { "" }
            var inputSchema: JSONValue { .objectSchema([:]) }
            func callWithImages(input: JSONValue, context: ToolContext) async throws -> (String, [ModelImage]) {
                ("Imagen adjunta.", [ModelImage(mediaType: "image/jpeg", data: Data([9]), width: 1, height: 1)])
            }
        }
        for sees in [true, false] {
            let provider = FakeProvider([.tool("view_image", [:]), .text("Un gato")])
            provider.supportsImages = sees
            _ = try await AgentLoop(provider: provider, tools: [Looker()], store: MemoryStore()).respond(to: "¿Qué hay?", chatID: "voz")
            let second = provider.requests.get()[1].messages.last?.content ?? []
            let hasImage = second.contains { if case .image = $0 { return true }; return false }
            XCTAssertEqual(hasImage, sees)
        }
        // Una foto que manda el usuario va en su mensaje.
        let provider = FakeProvider([.text("Es un gato")])
        provider.supportsImages = true
        _ = try await AgentLoop(provider: provider, tools: [], store: MemoryStore())
            .respond(to: "¿Qué es?", chatID: "voz", images: [ModelImage(mediaType: "image/jpeg", data: Data([7]), width: 1, height: 1)])
        XCTAssertTrue(provider.requests.get()[0].messages.last?.content.contains { if case .image = $0 { return true }; return false } ?? false)
    }
}

final class ResourceTests: XCTestCase {
    func testInsideTheLinuxMachineEachPartHasAName() {
        let du: [(path: String, bytes: UInt64)] = [
            ("/home/agent/.sayso-guard/models/protectai--deberta-v3-base-prompt-injection-v2", 740_000_000),
            ("/home/agent/.sayso-guard/models/meta-llama--Llama-Prompt-Guard-2-22M", 290_000_000),
            ("/home/agent/.sayso-guard/venv", 1_900_000_000),
            ("/home/agent/sayso", 12_000_000),
            ("/var/cache/apt", 0),
        ]
        let items = ResourceUsage.vmItems(du, used: 4_000_000_000,
                                          activeModelFolder: "protectai--deberta-v3-base-prompt-injection-v2")
        XCTAssertEqual(items.first?.id, "guard-python", "de mayor a menor")
        XCTAssertEqual(items.first { $0.id == "system" }?.bytes, 4_000_000_000 - 740_000_000 - 290_000_000 - 1_900_000_000 - 12_000_000,
                       "lo que no cae en ninguna parte es el sistema")
        let active = items.first { $0.title == "protectai/deberta-v3-base-prompt-injection-v2" }
        XCTAssertEqual(active?.detail, tr("detector de inyecciones, en uso"))
        XCTAssertEqual(items.first { $0.title == "meta-llama/Llama-Prompt-Guard-2-22M" }?.detail, tr("detector de inyecciones, sin usar"))
        XCTAssertNotNil(items.first { $0.id == "guard-python" })
        XCTAssertNil(items.first { $0.id == "apt" }, "lo que no ocupa nada no sale")
        XCTAssertTrue(ResourceUsage.vmQuery.contains("$HOME/.sayso-guard/models/*"))
    }

    func testAllocatedSizeOfAFolder() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sayso-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(repeating: 1, count: 100_000).write(to: dir.appendingPathComponent("a.bin"))
        XCTAssertGreaterThanOrEqual(DiskMeasure.allocated(dir), 100_000)
        XCTAssertGreaterThan(DiskMeasure.appMemory(), 0)
    }
}

final class TokenMeterTests: XCTestCase {
    func testTheLoopRecordsTokensPerModel() async throws {
        let store = MemoryStore()
        _ = try await AgentLoop(provider: FakeProvider([.text("Hola")]), tools: [], store: store).respond(to: "Hola", chatID: "voz")
        XCTAssertEqual(store.tokenRecords.get().first?.model, "full-model")
        XCTAssertEqual(store.tokenRecords.get().first?.estimated, true, "el proveedor falso no da cifras")
    }
}


final class OpenAITokenFieldTests: XCTestCase {
    func testOpenAIUsesMaxCompletionTokens() async throws {
        let request = ModelRequest(model: "m", system: "", messages: [ModelMessage(role: .user, content: [.text("hola")])], maxTokens: 100)
        let ok = #"{"choices":[{"message":{"content":"Hola"},"finish_reason":"stop"}]}"#
        for (base, field, other) in [("https://api.openai.com/v1", "max_completion_tokens", "max_tokens"),
                                     ("https://openrouter.ai/api/v1", "max_tokens", "max_completion_tokens")] {
            let t = FakeTransport(json: ok)
            let p = OpenAICompatibleProvider(baseURL: URL(string: base)!, apiKey: "k", fullModel: "m", fastModel: "f", transport: t)
            _ = try await p.complete(request)
            XCTAssertEqual(t.bodies().first?[field]?.intValue, 100)
            XCTAssertNil(t.bodies().first?[other])
        }
    }
}

final class ModelRetryTests: XCTestCase {
    override func setUp() { ModelRetry.scale = 0 }
    override func tearDown() { ModelRetry.scale = 1 }

    private let ok = #"{"content":[{"type":"text","text":"Hola"}],"stop_reason":"end_turn"}"#
    private func request() -> ModelRequest {
        ModelRequest(model: "m", system: "", messages: [ModelMessage(role: .user, content: [.text("hola")])], tools: [], maxTokens: 100)
    }

    func testOverloadedIsRetriedUntilItWorks() async throws {
        let calls = Locked(0)
        let ok = self.ok
        let transport = FakeTransport { _ in
            let n = calls.update { $0 += 1; return $0 }
            return n < 3 ? (529, Data(#"{"error":{"message":"Overloaded"}}"#.utf8)) : (200, Data(ok.utf8))
        }
        let p = AnthropicProvider(apiKey: "k", fullModel: "m", fastModel: "f", transport: transport)
        let response = try await p.complete(request())
        XCTAssertEqual(response.text, "Hola")
        XCTAssertEqual(transport.requests.get().count, 3)
    }

    func testNetworkDropIsRetried() async throws {
        let calls = Locked(0)
        let ok = self.ok
        let transport = FakeTransport { _ in
            if calls.update({ $0 += 1; return $0 }) == 1 { throw URLError(.networkConnectionLost) }
            return (200, Data(ok.utf8))
        }
        let p = AnthropicProvider(apiKey: "k", fullModel: "m", fastModel: "f", transport: transport)
        _ = try await p.complete(request())
        XCTAssertEqual(transport.requests.get().count, 2)
    }

    func testGivesUpAfterThreeRetriesAndKeepsTheError() async {
        let transport = FakeTransport(status: 503, json: #"{"error":{"message":"down"}}"#)
        let p = OpenAICompatibleProvider(baseURL: URL(string: "https://api.example.com/v1")!, apiKey: "k",
                                         fullModel: "m", fastModel: "f", transport: transport)
        do {
            _ = try await p.complete(request())
            XCTFail("debería fallar")
        } catch {
            XCTAssertEqual(error as? ProviderError, .http(status: 503, message: "down"))
        }
        XCTAssertEqual(transport.requests.get().count, 4)
    }

    func testClientErrorsAreNotRetried() async {
        let transport = FakeTransport(status: 400, json: #"{"error":{"message":"bad"}}"#)
        let p = AnthropicProvider(apiKey: "k", fullModel: "m", fastModel: "f", transport: transport)
        _ = try? await p.complete(request())
        XCTAssertEqual(transport.requests.get().count, 1)
    }
}
