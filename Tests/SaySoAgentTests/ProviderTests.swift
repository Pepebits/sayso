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
        XCTAssertEqual(body["system"], "sys")
        XCTAssertEqual(body["max_tokens"]?.intValue, 100)
        XCTAssertEqual(body["tools"]?[0]?["input_schema"]?["type"], "object")
        XCTAssertEqual(body["messages"]?[0]?["content"]?[0]?["text"], "hi")
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
        XCTAssertTrue(sent.system.contains("una sola pregunta"))
    }
}
