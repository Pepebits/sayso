import Foundation
import SaySoCore

/// Plugins del usuario (ADR-0009): guarda la lista, instala complementos en la VM, mantiene las
/// sesiones MCP y entrega al agente las herramientas de los que están activos.
public actor PluginManager {
    /// Tope de herramientas por plugin, para no llenar el contexto del modelo.
    public static let maxToolsPerPlugin = 40

    private struct Session {
        var client: MCPClient
        var tools: [MCPToolInfo]
        var checked: Date
    }

    private let store: SaySoStoring
    private let vault: SecretVault
    private let computer: AgentComputer
    private let computerInstalled: @Sendable () -> Bool
    private let broker: PermissionBrokering
    private let transport: HTTPTransport
    private let onChange: @Sendable ([PluginRow]) -> Void
    private var sessions: [String: Session] = [:]
    private var states: [String: PluginState] = [:]

    public init(store: SaySoStoring, vault: SecretVault, computer: AgentComputer,
                computerInstalled: @escaping @Sendable () -> Bool, broker: PermissionBrokering,
                transport: HTTPTransport = URLSessionTransport(),
                onChange: @escaping @Sendable ([PluginRow]) -> Void = { _ in }) {
        self.store = store
        self.vault = vault
        self.computer = computer
        self.computerInstalled = computerInstalled
        self.broker = broker
        self.transport = transport
        self.onChange = onChange
    }

    // MARK: Lista

    public func configs() -> [PluginConfig] {
        ((try? store.codableSetting(SettingsKey.plugins, as: [PluginConfig].self)) ?? nil) ?? []
    }

    private func save(_ configs: [PluginConfig]) throws {
        try store.setCodableSetting(configs, for: SettingsKey.plugins)
    }

    private var installedAddons: Set<String> {
        Set(((try? store.codableSetting(SettingsKey.installedAddons, as: [String].self)) ?? nil) ?? [])
    }

    /// Catálogo más los servidores propios, con su estado.
    public func rows() -> [PluginRow] {
        let added = configs()
        var rows = PluginCatalog.all.map { entry -> PluginRow in
            let mine = added.first { $0.id == entry.id }
            return PluginRow(config: mine ?? entry, added: mine != nil, state: states[entry.id] ?? .idle)
        }
        for config in added where !PluginCatalog.all.contains(where: { $0.id == config.id }) {
            rows.append(PluginRow(config: config, added: true, state: states[config.id] ?? .idle))
        }
        return rows
    }

    private func setState(_ state: PluginState, for id: String) {
        states[id] = state
        onChange(rows())
    }

    /// Añade un plugin (del catálogo o propio) y lo conecta o instala.
    public func add(_ config: PluginConfig) async throws {
        var config = config
        config.enabled = true
        guard !config.id.isEmpty else { throw MCPError.invalidResponse("el plugin necesita un nombre") }
        var list = configs().filter { $0.id != config.id }
        list.append(config)
        try save(list)
        await connect(config.id)
    }

    public func remove(_ id: String) async throws {
        try save(configs().filter { $0.id != id })
        try? store.setRule(nil, for: ActionID("plugin.\(id)"))
        await drop(id)
        states[id] = nil
        onChange(rows())
    }

    public func setEnabled(_ enabled: Bool, id: String) async throws {
        var list = configs()
        guard let index = list.firstIndex(where: { $0.id == id }) else { return }
        list[index].enabled = enabled
        try save(list)
        if enabled {
            await connect(id)
        } else {
            await drop(id)
            setState(.idle, for: id)
        }
    }

    private func drop(_ id: String) async {
        if let session = sessions.removeValue(forKey: id) { await session.client.close() }
    }

    // MARK: Conexión

    /// Instala (si es un complemento y falta) y abre la sesión. El resultado queda en el estado.
    public func connect(_ id: String) async {
        guard let config = configs().first(where: { $0.id == id }) else { return }
        await drop(id)
        do {
            var token: String?
            if let secret = config.secretName {
                token = try vault.value(for: KeychainName.workSecret(secret))
                if token == nil || token?.isEmpty == true {
                    if (try? store.secrets().contains { $0.name == secret }) != true {
                        try? store.upsertSecret(SecretMeta(name: secret, reason: "Para el plugin \(config.name)",
                                                           status: .requested))
                    }
                    throw PluginError.missingSecret(secret)
                }
            }
            switch config.kind {
            case .service:
                guard let url = config.url, url.scheme == "https" || url.host == "localhost" || url.host == "127.0.0.1" else {
                    throw PluginError.badURL
                }
                setState(.connecting, for: id)
                try await open(config, connection: MCPHTTPConnection(url: url, token: token, transport: transport))
            case .addon:
                guard computerInstalled() else { throw PluginError.noComputer }
                if let install = config.install, !installedAddons.contains(id) {
                    setState(.installing, for: id)
                    let result = try await computer.run(install, cwd: nil, timeout: 900, origin: "plugins")
                    guard result.exitCode == 0, !result.timedOut else {
                        let tail = (result.stderr.isEmpty ? result.stdout : result.stderr)
                            .trimmingCharacters(in: .whitespacesAndNewlines).suffix(300)
                        throw PluginError.installFailed(String(tail))
                    }
                    try store.setCodableSetting(Array(installedAddons.union([id])).sorted(),
                                                for: SettingsKey.installedAddons)
                }
                if config.builtin != nil {
                    setState(.ready([config.builtin ?? ""]), for: id)
                } else if let command = config.command {
                    setState(.connecting, for: id)
                    let stream = try await computer.openProcess(command, env: [:], origin: "plugins")
                    try await open(config, connection: MCPStdioConnection(stream: stream))
                } else {
                    throw PluginError.badURL
                }
            }
        } catch {
            await drop(id)
            setState(.failed(error.localizedDescription), for: id)
        }
    }

    private func open(_ config: PluginConfig, connection: MCPConnection) async throws {
        let client = MCPClient(connection: connection)
        do {
            try await client.initialize()
            let tools = try await client.listTools()
            sessions[config.id] = Session(client: client, tools: tools, checked: Date())
            setState(.ready(tools.map(\.name)), for: config.id)
        } catch {
            await client.close()
            throw error
        }
    }

    /// Complementos instalados dejan de estarlo cuando se borra la máquina.
    public func computerWasDeleted() async {
        try? store.setSetting(nil, for: SettingsKey.installedAddons)
        for config in configs() where config.kind == .addon {
            await drop(config.id)
            states[config.id] = .idle
        }
        onChange(rows())
    }

    /// Cierra todas las sesiones (al salir o al detener el agente).
    public func closeAll() async {
        for id in Array(sessions.keys) { await drop(id) }
    }

    // MARK: Navegador para la búsqueda web

    /// Abre una dirección con el plugin Navegador y devuelve lo que se ve en la página.
    /// `nil` si el navegador no está añadido, activado e instalado: no se instala nada por sorpresa.
    public func browse(_ url: URL) async throws -> String? {
        let id = "browser"
        guard configs().contains(where: { $0.id == id && $0.enabled }),
              installedAddons.contains(id), computerInstalled() else { return nil }
        if sessions[id] == nil { await connect(id) }
        guard let session = sessions[id] else { return nil }
        do {
            return try await session.client.callTool("browser_navigate", arguments: ["url": .string(url.absoluteString)])
        } catch {
            // Una sesión caída se reabre una vez; si vuelve a fallar, el error sube.
            await connect(id)
            guard let retry = sessions[id] else { throw error }
            return try await retry.client.callTool("browser_navigate", arguments: ["url": .string(url.absoluteString)])
        }
    }

    // MARK: Herramientas para el agente

    /// Herramientas de los plugins activos. Reabre las sesiones caídas; un plugin que falla no
    /// impide usar los demás. Con `connect: false` solo entrega las de sesiones ya abiertas: no
    /// espera a conectar nada ni arranca la máquina Linux (para la voz, donde manda la rapidez).
    public func tools(connect shouldConnect: Bool = true) async -> [AgentTool] {
        var out: [AgentTool] = []
        for config in configs() where config.enabled {
            if !shouldConnect {
                if config.builtin == nil, let session = sessions[config.id] {
                    for info in session.tools.prefix(Self.maxToolsPerPlugin) {
                        out.append(MCPTool(plugin: config, info: info, client: session.client, broker: broker))
                    }
                }
                continue
            }
            if config.builtin == PluginCatalog.claudeCodeBuiltin {
                if installedAddons.contains(config.id), computerInstalled() {
                    out.append(ClaudeCodeTool(plugin: config, computer: computer, vault: vault, store: store, broker: broker))
                }
                continue
            }
            if var session = sessions[config.id], Date().timeIntervalSince(session.checked) > 60 {
                if (try? await session.client.connection.request("ping", params: nil)) != nil {
                    session.checked = Date()
                    sessions[config.id] = session
                } else {
                    await drop(config.id)
                }
            }
            if sessions[config.id] == nil {
                // No se instala nada por sorpresa: solo se reconecta lo que ya estaba instalado.
                if config.kind == .addon, !installedAddons.contains(config.id) || !computerInstalled() { continue }
                await connect(config.id)
            }
            guard let session = sessions[config.id] else { continue }
            for info in session.tools.prefix(Self.maxToolsPerPlugin) {
                out.append(MCPTool(plugin: config, info: info, client: session.client, broker: broker))
            }
        }
        return out
    }
}

public enum PluginError: Error, LocalizedError, Equatable, Sendable {
    case missingSecret(String)
    case badURL
    case noComputer
    case installFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .missingSecret(name): return tr("Falta el secreto %@. Guárdalo en Secretos y vuelve a conectar.", "\(name)")
        case .badURL: return tr("La dirección del servidor no es válida: tiene que empezar por https://.")
        case .noComputer: return tr("Este complemento vive en la máquina Linux. Instálala antes en Ordenador.")
        case let .installFailed(output): return tr("La instalación falló: %@", "\(output)")
        }
    }
}

/// Complemento Claude Code: el agente le delega una tarea de programación dentro de la VM.
public struct ClaudeCodeTool: AgentTool {
    let plugin: PluginConfig
    let computer: AgentComputer
    let vault: SecretVault
    let store: SaySoStoring
    let broker: PermissionBrokering

    public var name: String { "claude_code" }
    public var description: String {
        """
        Delega una tarea de programación en Claude Code, que trabaja dentro de tu ordenador Linux: lee y \
        edita el código de un directorio, ejecuta comandos y tests, y devuelve un informe. Úsalo para tareas \
        largas de código; para un comando suelto usa computer_run. Puede tardar varios minutos.
        """
    }
    public var inputSchema: JSONValue {
        .objectSchema([
            "task": .property("string", "Qué debe hacer, con todo el contexto necesario"),
            "directory": .property("string", "Directorio del proyecto; relativo a ~/sayso"),
        ], required: ["task"])
    }

    public func call(input: JSONValue, context: ToolContext) async throws -> String {
        let task = try input.requiredString("task", maxLength: 20000)
        let directory = try input.optionalString("directory", maxLength: 1000)
        let secret = plugin.secretName ?? "ANTHROPIC_API_KEY"
        guard let key = try vault.value(for: KeychainName.workSecret(secret)), !key.isEmpty else {
            if (try? store.secrets().contains { $0.name == secret }) != true {
                try? store.upsertSecret(SecretMeta(name: secret, reason: "Para Claude Code", status: .requested))
            }
            return "Falta el secreto \(secret). El usuario debe guardarlo en SaySo → Secretos; no lo pidas por el chat."
        }
        let request = ActionRequest(action: plugin.action,
                                    summary: "Claude Code: " + String(task.prefix(200)),
                                    parameters: ["Tarea": String(task.prefix(2000)), "Directorio": directory ?? "~/sayso"],
                                    origin: context.origin)
        let computer = self.computer
        let origin = context.origin
        let result = try await broker.run(request) {
            try await computer.run(
                "\"$HOME/.local/bin/claude\" -p \"$SAYSO_TASK\" --output-format text --dangerously-skip-permissions",
                cwd: directory, timeout: 1800, env: ["ANTHROPIC_API_KEY": key, "SAYSO_TASK": task], origin: origin)
        }
        return ComputerTools.render(result)
    }
}
