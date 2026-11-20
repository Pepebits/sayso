import Foundation
import SaySoCore

// Cliente del Model Context Protocol: JSON-RPC 2.0 sobre HTTP o sobre la entrada y
// salida de un proceso. Solo la parte de herramientas: initialize, tools/list y tools/call.

public enum MCPError: Error, LocalizedError, Equatable, Sendable {
    case http(Int, String)
    case rpc(Int, String)
    case invalidResponse(String)
    case closed
    case unauthorized

    public var errorDescription: String? {
        switch self {
        case let .http(code, body): return tr("El servidor respondió %@", "\(code)") + (body.isEmpty ? "" : ": \(body)")
        case let .rpc(code, message): return tr("Error del plugin (%@): %@", "\(code)", "\(message)")
        case let .invalidResponse(reason): return tr("Respuesta no válida del plugin: %@", "\(reason)")
        case .closed: return tr("El plugin cerró la conexión.")
        case .unauthorized: return tr("El servidor rechazó la credencial o exige iniciar sesión.")
        }
    }
}

/// Canal por el que viajan los mensajes JSON-RPC.
public protocol MCPConnection: Sendable {
    func request(_ method: String, params: JSONValue?) async throws -> JSONValue
    func notify(_ method: String, params: JSONValue?) async throws
    func close() async
}

enum MCPMessage {
    static func request(id: Int, method: String, params: JSONValue?) -> JSONValue {
        var object: [String: JSONValue] = ["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method)]
        if let params { object["params"] = params }
        return .object(object)
    }

    static func notification(method: String, params: JSONValue?) -> JSONValue {
        var object: [String: JSONValue] = ["jsonrpc": "2.0", "method": .string(method)]
        if let params { object["params"] = params }
        return .object(object)
    }

    /// Resultado de la respuesta con ese `id`, o `nil` si el mensaje es otra cosa.
    static func result(of message: JSONValue, id: Int) throws -> JSONValue? {
        guard message["id"]?.intValue == id, message["method"] == nil else { return nil }
        if let error = message["error"] {
            throw MCPError.rpc(error["code"]?.intValue ?? 0, error["message"]?.stringValue ?? "sin detalle")
        }
        guard let result = message["result"] else { throw MCPError.invalidResponse("falta «result»") }
        return result
    }

    /// Cuerpos `data:` de un flujo de eventos (SSE).
    static func sseData(_ text: String) -> [String] {
        var events: [String] = []
        var current: [String] = []
        for raw in text.components(separatedBy: "\n") {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            if line.isEmpty {
                if !current.isEmpty { events.append(current.joined(separator: "\n")); current = [] }
            } else if line.hasPrefix("data:") {
                var value = line.dropFirst(5)
                if value.hasPrefix(" ") { value = value.dropFirst() }
                current.append(String(value))
            }
        }
        if !current.isEmpty { events.append(current.joined(separator: "\n")) }
        return events
    }
}

/// Transporte «Streamable HTTP»: cada mensaje es un POST; la respuesta llega como JSON o como SSE.
public actor MCPHTTPConnection: MCPConnection {
    private let url: URL
    private let token: String?
    private let transport: HTTPTransport
    private var sessionID: String?
    private var protocolVersion: String?
    private var nextID = 1

    public init(url: URL, token: String?, transport: HTTPTransport = URLSessionTransport()) {
        self.url = url
        self.token = token
        self.transport = transport
    }

    public func request(_ method: String, params: JSONValue?) async throws -> JSONValue {
        let id = nextID
        nextID += 1
        let (data, http) = try await post(MCPMessage.request(id: id, method: method, params: params))
        if method == "initialize", let session = http.value(forHTTPHeaderField: "Mcp-Session-Id") { sessionID = session }
        let type = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        let bodies = type.contains("text/event-stream")
            ? MCPMessage.sseData(String(decoding: data, as: UTF8.self)) : [String(decoding: data, as: UTF8.self)]
        for body in bodies {
            guard let message = try? JSONValue.parse(body) else { continue }
            if let result = try MCPMessage.result(of: message, id: id) {
                if method == "initialize" { protocolVersion = result["protocolVersion"]?.stringValue }
                return result
            }
        }
        throw MCPError.invalidResponse("no llegó la respuesta a «\(method)»")
    }

    public func notify(_ method: String, params: JSONValue?) async throws {
        _ = try await post(MCPMessage.notification(method: method, params: params))
    }

    public func close() async {
        guard let sessionID else { return }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "DELETE"
        request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        _ = try? await transport.send(request)
        self.sessionID = nil
    }

    private func post(_ message: JSONValue) async throws -> (Data, HTTPURLResponse) {
        var headers = ["Accept": "application/json, text/event-stream"]
        if let token, !token.isEmpty { headers["Authorization"] = "Bearer \(token)" }
        if let sessionID { headers["Mcp-Session-Id"] = sessionID }
        if let protocolVersion { headers["MCP-Protocol-Version"] = protocolVersion }
        let (data, http) = try await transport.send(try .postJSON(url, body: message, headers: headers, timeout: 120))
        if http.statusCode == 401 || http.statusCode == 403 { throw MCPError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            throw MCPError.http(http.statusCode, String(String(decoding: data, as: UTF8.self).prefix(200)))
        }
        return (data, http)
    }
}

/// Transporte stdio: un mensaje JSON por línea sobre la entrada y salida de un proceso.
public actor MCPStdioConnection: MCPConnection {
    private let stream: ProcessStream
    private var nextID = 1
    private var closed = false

    public init(stream: ProcessStream) { self.stream = stream }

    public func request(_ method: String, params: JSONValue?) async throws -> JSONValue {
        guard !closed else { throw MCPError.closed }
        let id = nextID
        nextID += 1
        let stream = self.stream
        let line = try MCPMessage.request(id: id, method: method, params: params).encoded() + Data([0x0A])
        // E/S bloqueante: fuera del actor para no retener un hilo del sistema cooperativo.
        return try await Task.detached {
            try stream.write(line)
            let deadline = Date().addingTimeInterval(180)
            while Date() < deadline {
                guard let data = try stream.readLine(timeout: 180) else { throw MCPError.closed }
                guard let message = try? JSONValue.parse(data) else { continue } // ruido que no es JSON
                if let result = try MCPMessage.result(of: message, id: id) { return result }
                // Petición del servidor al cliente (ping, sampling…): se contesta que no se admite.
                if let serverID = message["id"], message["method"] != nil {
                    let reply: JSONValue = ["jsonrpc": "2.0", "id": serverID,
                                            "error": ["code": -32601, "message": "Method not found"]]
                    try stream.write(try reply.encoded() + Data([0x0A]))
                }
            }
            throw MCPError.invalidResponse("no llegó la respuesta a «\(method)»")
        }.value
    }

    public func notify(_ method: String, params: JSONValue?) async throws {
        guard !closed else { throw MCPError.closed }
        try stream.write(try MCPMessage.notification(method: method, params: params).encoded() + Data([0x0A]))
    }

    public func close() async {
        closed = true
        stream.close()
    }
}

/// Herramienta anunciada por un servidor MCP.
public struct MCPToolInfo: Hashable, Sendable {
    public var name: String
    public var description: String
    public var inputSchema: JSONValue
}

/// Sesión con un servidor MCP.
public struct MCPClient: Sendable {
    public static let protocolVersion = "2025-06-18"
    let connection: MCPConnection

    public init(connection: MCPConnection) { self.connection = connection }

    public func initialize() async throws {
        _ = try await connection.request("initialize", params: [
            "protocolVersion": .string(Self.protocolVersion),
            "capabilities": [:],
            "clientInfo": ["name": "SaySo", "version": "0.1"],
        ])
        try await connection.notify("notifications/initialized", params: nil)
    }

    /// Todas las herramientas, siguiendo la paginación (con un tope de páginas).
    public func listTools() async throws -> [MCPToolInfo] {
        var tools: [MCPToolInfo] = []
        var cursor: String?
        for _ in 0..<20 {
            let result = try await connection.request("tools/list", params: cursor.map { ["cursor": .string($0)] })
            for item in result["tools"]?.arrayValue ?? [] {
                guard let name = item["name"]?.stringValue else { continue }
                tools.append(MCPToolInfo(name: name, description: item["description"]?.stringValue ?? "",
                                         inputSchema: item["inputSchema"] ?? .objectSchema([:])))
            }
            cursor = result["nextCursor"]?.stringValue
            if cursor == nil { break }
        }
        return tools
    }

    /// Llama a una herramienta y devuelve su texto. Lanza si el servidor marca error.
    public func callTool(_ name: String, arguments: JSONValue) async throws -> String {
        let result = try await connection.request("tools/call", params: ["name": .string(name), "arguments": arguments])
        var parts: [String] = []
        for item in result["content"]?.arrayValue ?? [] {
            switch item["type"]?.stringValue {
            case "text": if let text = item["text"]?.stringValue { parts.append(text) }
            case "resource": if let text = item["resource"]?["text"]?.stringValue { parts.append(text) }
            case let other?: parts.append("[contenido de tipo \(other) omitido]")
            case nil: break
            }
        }
        if parts.isEmpty, let structured = result["structuredContent"] { parts.append(structured.jsonString()) }
        let text = parts.joined(separator: "\n")
        if result["isError"]?.boolValue == true { throw MCPError.rpc(0, text.isEmpty ? "la herramienta falló" : text) }
        return text.isEmpty ? "(sin contenido)" : text
    }

    public func close() async { await connection.close() }
}

/// Herramienta de un plugin tal como la ve el agente. Cada llamada pasa por el motor de permisos.
public struct MCPTool: AgentTool {
    let plugin: PluginConfig
    let info: MCPToolInfo
    let client: MCPClient
    let broker: PermissionBrokering

    public var name: String { Self.exposedName(plugin: plugin.id, tool: info.name) }
    public var description: String {
        let text = info.description.trimmingCharacters(in: .whitespacesAndNewlines)
        return "[\(plugin.name)] " + (text.count > 1000 ? String(text.prefix(1000)) + "…" : text)
    }
    public var inputSchema: JSONValue {
        info.inputSchema["type"]?.stringValue == "object" ? info.inputSchema : .objectSchema([:])
    }

    /// Nombre válido para los proveedores: `[a-zA-Z0-9_-]`, 64 caracteres como mucho.
    static func exposedName(plugin: String, tool: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        let clean = String(tool.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return String("\(plugin)__\(clean)".prefix(64))
    }

    public func call(input: JSONValue, context: ToolContext) async throws -> String {
        let arguments: JSONValue = input.objectValue == nil ? [:] : input
        let shown = arguments.jsonString()
        let request = ActionRequest(
            action: plugin.action,
            summary: "\(plugin.name): \(info.name) \(shown.count > 200 ? String(shown.prefix(200)) + "…" : shown)",
            parameters: ["Plugin": plugin.name, "Herramienta": info.name, "Parámetros": String(shown.prefix(2000))],
            origin: context.origin)
        let client = self.client
        let toolName = info.name
        let text = try await broker.run(request) { try await client.callTool(toolName, arguments: arguments) }
        let limit = 60_000
        return text.count > limit ? String(text.prefix(limit)) + "\n[… resultado recortado …]" : text
    }
}
