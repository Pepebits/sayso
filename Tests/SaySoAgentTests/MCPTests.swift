import XCTest
import SaySoCore
@testable import SaySoAgent

/// Servidor MCP falso sobre HTTP: responde según el método JSON-RPC.
final class FakeMCPServer: HTTPTransport, @unchecked Sendable {
    let requests = Locked<[URLRequest]>([])
    var sse = false
    var status = 200
    var tools: [JSONValue] = [["name": "search", "description": "Busca", "inputSchema": ["type": "object"]]]
    var callResult: JSONValue = ["content": [["type": "text", "text": "resultado"]]]

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.update { $0.append(request) }
        func response(_ body: Data, type: String, extra: [String: String] = [:]) -> (Data, HTTPURLResponse) {
            var headers = ["Content-Type": type]
            headers.merge(extra) { $1 }
            return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
        }
        guard status == 200, let body = request.httpBody, let message = try? JSONValue.parse(body) else {
            return response(Data("no".utf8), type: "text/plain")
        }
        guard let id = message["id"] else { return response(Data(), type: "application/json") } // notificación
        let result: JSONValue
        switch message["method"]?.stringValue {
        case "initialize": result = ["protocolVersion": "2025-06-18", "capabilities": [:]]
        case "tools/list": result = ["tools": .array(tools)]
        case "tools/call": result = callResult
        case "ping": result = [:]
        default:
            let error: JSONValue = ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "no existe"]]
            return response(try error.encoded(), type: "application/json")
        }
        let reply: JSONValue = ["jsonrpc": "2.0", "id": id, "result": result]
        if sse {
            let text = "event: message\ndata: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\"}\n\n"
                + "event: message\ndata: \(reply.jsonString())\n\n"
            return response(Data(text.utf8), type: "text/event-stream", extra: ["Mcp-Session-Id": "s1"])
        }
        return response(try reply.encoded(), type: "application/json", extra: ["Mcp-Session-Id": "s1"])
    }

    func methods() -> [String] {
        requests.get().compactMap { $0.httpBody.flatMap { try? JSONValue.parse($0) }?["method"]?.stringValue }
    }
}

/// Proceso falso: responde por líneas como un servidor MCP por stdio.
final class FakeProcess: ProcessStream, @unchecked Sendable {
    let written = Locked<[JSONValue]>([])
    private let pending = Locked<[Data]>([])
    let closed = Locked(false)

    func write(_ data: Data) throws {
        guard let message = try? JSONValue.parse(data) else { return }
        written.update { $0.append(message) }
        guard let id = message["id"], let method = message["method"]?.stringValue else { return }
        let result: JSONValue = method == "tools/list"
            ? ["tools": [["name": "fetch", "description": "Descarga", "inputSchema": ["type": "object"]]]]
            : ["content": [["type": "text", "text": "hola"]]]
        let reply: JSONValue = ["jsonrpc": "2.0", "id": id, "result": result]
        pending.update {
            $0.append(Data("ruido que no es JSON".utf8))
            $0.append(Data(#"{"jsonrpc":"2.0","id":99,"method":"roots/list"}"#.utf8))
            $0.append((try? reply.encoded()) ?? Data())
        }
    }

    func readLine(timeout: TimeInterval) throws -> Data? {
        pending.update { $0.isEmpty ? nil : $0.removeFirst() }
    }

    func close() { closed.set(true) }
}

struct FakeVault: SecretVault {
    var values: [String: String] = [:]
    func value(for name: String) throws -> String? { values[name] }
    func setValue(_ value: String, for name: String) throws {}
    func removeValue(for name: String) throws {}
}

final class FakeComputer: AgentComputer, @unchecked Sendable {
    let commands = Locked<[(String, [String: String])]>([])
    var exitCode: Int32 = 0
    let process = FakeProcess()

    func run(_ command: String, cwd: String?, timeout: TimeInterval, env: [String: String],
             origin: String?) async throws -> CommandResult {
        commands.update { $0.append((command, env)) }
        return CommandResult(exitCode: exitCode, stdout: "hecho", stderr: exitCode == 0 ? "" : "fallo")
    }
    func openProcess(_ command: String, env: [String: String], origin: String?) async throws -> ProcessStream { process }
    func readFile(_ path: String, origin: String?) async throws -> String { "" }
    func writeFile(_ path: String, content: String, origin: String?) async throws {}
}

final class MCPTests: XCTestCase {
    private let url = URL(string: "https://mcp.example.com/mcp")!

    func testSSEDataJoinsLinesAndSplitsEvents() {
        let events = MCPMessage.sseData("event: a\r\ndata: {\"a\":\r\ndata: 1}\r\n\r\n: comentario\ndata:x\n\n")
        XCTAssertEqual(events, ["{\"a\":\n1}", "x"])
    }

    func testHTTPHandshakeListAndCall() async throws {
        let server = FakeMCPServer()
        let client = MCPClient(connection: MCPHTTPConnection(url: url, token: "tok", transport: server))
        try await client.initialize()
        let tools = try await client.listTools()
        XCTAssertEqual(tools.map(\.name), ["search"])
        let text = try await client.callTool("search", arguments: ["q": "swift"])
        XCTAssertEqual(text, "resultado")
        XCTAssertEqual(server.methods(), ["initialize", "notifications/initialized", "tools/list", "tools/call"])

        let requests = server.requests.get()
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "Mcp-Session-Id"))
        XCTAssertEqual(requests[2].value(forHTTPHeaderField: "Mcp-Session-Id"), "s1")
        XCTAssertEqual(requests[2].value(forHTTPHeaderField: "MCP-Protocol-Version"), "2025-06-18")
        XCTAssertTrue(requests[2].value(forHTTPHeaderField: "Accept")?.contains("text/event-stream") == true)
    }

    func testHTTPAcceptsEventStreamResponses() async throws {
        let server = FakeMCPServer()
        server.sse = true
        let client = MCPClient(connection: MCPHTTPConnection(url: url, token: nil, transport: server))
        try await client.initialize()
        let tools = try await client.listTools()
        XCTAssertEqual(tools.first?.description, "Busca")
        XCTAssertNil(server.requests.get()[0].value(forHTTPHeaderField: "Authorization"))
    }

    func testUnauthorizedAndRPCErrors() async throws {
        let server = FakeMCPServer()
        server.status = 401
        let connection = MCPHTTPConnection(url: url, token: nil, transport: server)
        do {
            _ = try await connection.request("initialize", params: nil)
            XCTFail("debía fallar")
        } catch { XCTAssertEqual(error as? MCPError, .unauthorized) }

        server.status = 200
        do {
            _ = try await connection.request("nope", params: nil)
            XCTFail("debía fallar")
        } catch { XCTAssertEqual(error as? MCPError, .rpc(-32601, "no existe")) }
    }

    func testToolErrorIsThrown() async throws {
        let server = FakeMCPServer()
        server.callResult = ["isError": true, "content": [["type": "text", "text": "sin permiso"]]]
        let client = MCPClient(connection: MCPHTTPConnection(url: url, token: nil, transport: server))
        do {
            _ = try await client.callTool("search", arguments: [:])
            XCTFail("debía fallar")
        } catch { XCTAssertEqual(error as? MCPError, .rpc(0, "sin permiso")) }
    }

    func testStdioSkipsNoiseAndAnswersServerRequests() async throws {
        let process = FakeProcess()
        let client = MCPClient(connection: MCPStdioConnection(stream: process))
        try await client.initialize()
        let tools = try await client.listTools()
        XCTAssertEqual(tools.map(\.name), ["fetch"])
        // La petición del servidor (id 99) recibe un «method not found».
        let refusals = process.written.get().filter { $0["id"]?.intValue == 99 }
        XCTAssertEqual(refusals.first?["error"]?["code"]?.intValue, -32601)
        await client.close()
        XCTAssertTrue(process.closed.get())
    }

    func testExposedNameIsSafeAndBounded() {
        XCTAssertEqual(MCPTool.exposedName(plugin: "github", tool: "repos/list.all"), "github__repos_list_all")
        XCTAssertEqual(MCPTool.exposedName(plugin: "x", tool: String(repeating: "a", count: 100)).count, 64)
    }

    func testPluginToolGoesThroughTheBroker() async throws {
        let server = FakeMCPServer()
        let client = MCPClient(connection: MCPHTTPConnection(url: url, token: nil, transport: server))
        let plugin = PluginCatalog.all.first { $0.id == "context7" }!
        let info = MCPToolInfo(name: "search", description: "Busca", inputSchema: ["type": "object"])

        let allowed = FakeBroker(allow: true)
        let tool = MCPTool(plugin: plugin, info: info, client: client, broker: allowed)
        XCTAssertEqual(tool.name, "context7__search")
        let text = try await tool.call(input: ["q": "a"], context: ToolContext(origin: "telegram:1"))
        XCTAssertEqual(text, "resultado")
        XCTAssertEqual(allowed.requests.get().first?.action, "plugin.context7")
        XCTAssertEqual(allowed.requests.get().first?.origin, "telegram:1")

        let denied = MCPTool(plugin: plugin, info: info, client: client, broker: FakeBroker(allow: false))
        let before = server.requests.get().count
        do {
            _ = try await denied.call(input: [:], context: ToolContext())
            XCTFail("debía denegarse")
        } catch is PermissionError {}
        XCTAssertEqual(server.requests.get().count, before, "una acción denegada no llega al servidor")
    }

    func testDefaultRules() {
        XCTAssertEqual(PluginCatalog.all.first { $0.kind == .service }?.descriptor.defaultRule, .ask)
        XCTAssertEqual(PluginCatalog.all.first { $0.kind == .addon }?.descriptor.defaultRule, .allow)
        XCTAssertEqual(PluginConfig.slug("Mi Servidor (ñ) 2"), "mi_servidor_n_2")
        XCTAssertEqual(Set(PluginCatalog.all.map(\.id)).count, PluginCatalog.all.count)
        // Todo complemento del catálogo sabe instalarse y, salvo Claude Code, arrancar su servidor.
        for addon in PluginCatalog.all where addon.kind == .addon {
            XCTAssertNotNil(addon.install, addon.id)
            XCTAssertTrue(addon.command != nil || addon.builtin != nil, addon.id)
        }
        XCTAssertEqual(PluginCatalog.all.first { $0.id == "browser" }?.command?.hasPrefix("playwright-mcp --headless"), true)
    }
}

final class PluginManagerTests: XCTestCase {
    private func manager(store: MemoryStore, vault: FakeVault = FakeVault(), computer: FakeComputer = FakeComputer(),
                         installed: Bool = true, server: FakeMCPServer = FakeMCPServer()) -> PluginManager {
        PluginManager(store: store, vault: vault, computer: computer, computerInstalled: { installed },
                      broker: FakeBroker(allow: true), transport: server)
    }

    private func entry(_ id: String) -> PluginConfig { PluginCatalog.all.first { $0.id == id }! }

    func testServiceConnectsAndExposesTools() async throws {
        let store = MemoryStore()
        let plugins = manager(store: store)
        try await plugins.add(entry("context7"))
        let row = await plugins.rows().first { $0.id == "context7" }
        XCTAssertEqual(row?.added, true)
        XCTAssertEqual(row?.state, .ready(["search"]))
        let tools = await plugins.tools()
        XCTAssertEqual(tools.map(\.name), ["context7__search"])

        try await plugins.setEnabled(false, id: "context7")
        let none = await plugins.tools()
        XCTAssertTrue(none.isEmpty)
        try await plugins.remove("context7")
        let removed = await plugins.rows().first { $0.id == "context7" }
        XCTAssertEqual(removed?.added, false)
    }

    func testMissingSecretIsRequestedNotSent() async throws {
        let store = MemoryStore()
        let server = FakeMCPServer()
        let plugins = manager(store: store, server: server)
        try await plugins.add(entry("github"))
        let row = await plugins.rows().first { $0.id == "github" }
        guard case let .failed(message)? = row?.state else { return XCTFail("debía fallar") }
        XCTAssertTrue(message.contains("GITHUB_TOKEN"))
        XCTAssertEqual(try store.secrets().first?.name, "GITHUB_TOKEN")
        XCTAssertEqual(try store.secrets().first?.status, .requested)
        XCTAssertTrue(server.requests.get().isEmpty)
    }

    func testSecretIsSentAsBearer() async throws {
        let server = FakeMCPServer()
        let plugins = manager(store: MemoryStore(), vault: FakeVault(values: ["secret.GITHUB_TOKEN": "ghp_x"]), server: server)
        try await plugins.add(entry("github"))
        XCTAssertEqual(server.requests.get().first?.value(forHTTPHeaderField: "Authorization"), "Bearer ghp_x")
    }

    func testAddonInstallsOnceAndUsesStdio() async throws {
        let store = MemoryStore()
        let computer = FakeComputer()
        let plugins = manager(store: store, computer: computer)
        try await plugins.add(entry("fetch"))
        let row = await plugins.rows().first { $0.id == "fetch" }
        XCTAssertEqual(row?.state, .ready(["fetch"]))
        XCTAssertEqual(computer.commands.get().count, 1)
        await plugins.connect("fetch")
        XCTAssertEqual(computer.commands.get().count, 1, "no se reinstala")
        let tools = await plugins.tools()
        XCTAssertEqual(tools.map(\.name), ["fetch__fetch"])

        await plugins.computerWasDeleted()
        await plugins.connect("fetch")
        XCTAssertEqual(computer.commands.get().count, 2, "tras borrar la máquina hay que instalar otra vez")
    }

    func testAddonNeedsTheComputerAndReportsInstallFailures() async throws {
        let without = manager(store: MemoryStore(), installed: false)
        try await without.add(entry("fetch"))
        let row = await without.rows().first { $0.id == "fetch" }
        XCTAssertEqual(row?.state, .failed(PluginError.noComputer.localizedDescription))

        let computer = FakeComputer()
        computer.exitCode = 1
        let failing = manager(store: MemoryStore(), computer: computer)
        try await failing.add(entry("fetch"))
        let failed = await failing.rows().first { $0.id == "fetch" }
        XCTAssertEqual(failed?.state, .failed(PluginError.installFailed("fallo").localizedDescription))
    }

    func testClaudeCodePassesTheKeyOnlyInTheEnvironment() async throws {
        let store = MemoryStore()
        let computer = FakeComputer()
        let broker = FakeBroker(allow: true)
        let plugin = entry("claude_code")
        let noKey = ClaudeCodeTool(plugin: plugin, computer: computer, vault: FakeVault(), store: store, broker: broker)
        let asked = try await noKey.call(input: ["task": "arregla el test"], context: ToolContext())
        XCTAssertTrue(asked.contains("ANTHROPIC_API_KEY"))
        XCTAssertTrue(computer.commands.get().isEmpty)
        XCTAssertEqual(try store.secrets().first?.status, .requested)

        let tool = ClaudeCodeTool(plugin: plugin, computer: computer,
                                  vault: FakeVault(values: ["secret.ANTHROPIC_API_KEY": "sk-ant-x"]), store: store, broker: broker)
        _ = try await tool.call(input: ["task": "arregla el test"], context: ToolContext())
        let (command, env) = computer.commands.get()[0]
        XCTAssertFalse(command.contains("sk-ant-x"))
        XCTAssertFalse(command.contains("arregla"))
        XCTAssertEqual(env["ANTHROPIC_API_KEY"], "sk-ant-x")
        XCTAssertEqual(env["SAYSO_TASK"], "arregla el test")
        XCTAssertFalse(broker.requests.get().contains { $0.summary.contains("sk-ant-x") })
    }
}
