import Foundation

// Plugins (ADR-0009): todo plugin acaba exponiendo herramientas MCP al agente.

public enum PluginKind: String, Codable, Sendable, CaseIterable {
    /// Servidor MCP remoto, por HTTP.
    case service
    /// Programa dentro de la máquina Linux del agente.
    case addon
}

/// Un plugin tal como lo guarda la app.
public struct PluginConfig: Identifiable, Hashable, Codable, Sendable {
    /// Identificador corto (`[a-z0-9_]`); prefijo de sus herramientas y de su acción de permisos.
    public var id: String
    public var name: String
    public var detail: String
    public var kind: PluginKind
    public var icon: String
    /// Servicios: dirección del servidor MCP.
    public var url: URL?
    /// Nombre del secreto (pantalla Secretos) que se envía como credencial; `nil` si no hace falta.
    public var secretName: String?
    /// Complementos: script de bash que lo instala en la VM. Se ejecuta una vez.
    public var install: String?
    /// Complementos: comando que arranca su servidor MCP por stdio dentro de la VM.
    public var command: String?
    /// Complementos con herramienta propia en vez de servidor MCP (`claude_code`).
    public var builtin: String?
    public var enabled: Bool

    public init(id: String, name: String, detail: String, kind: PluginKind, icon: String, url: URL? = nil,
                secretName: String? = nil, install: String? = nil, command: String? = nil,
                builtin: String? = nil, enabled: Bool = true) {
        self.id = id
        self.name = name
        self.detail = detail
        self.kind = kind
        self.icon = icon
        self.url = url
        self.secretName = secretName
        self.install = install
        self.command = command
        self.builtin = builtin
        self.enabled = enabled
    }

    /// Acción del motor de permisos que cubre todas las herramientas del plugin.
    public var action: ActionID { ActionID("plugin.\(id)") }

    /// Los servicios envían datos fuera del Mac: Preguntar. Los complementos viven en la VM: Permitir.
    public var descriptor: ActionDescriptor {
        ActionDescriptor(id: action, title: tr("Usar %@", tr(name)),
                         detail: kind == .service ? "Llama a un servicio en línea." : "Se ejecuta en la máquina Linux.",
                         defaultRule: kind == .service ? .ask : .allow)
    }

    /// Convierte un nombre libre en identificador válido.
    public static func slug(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        var out = ""
        for scalar in folded.unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                out.unicodeScalars.append(scalar)
            } else if !out.hasSuffix("_") {
                out.append("_")
            }
        }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return String(out.prefix(24))
    }
}

public enum PluginState: Hashable, Sendable {
    case idle
    case installing
    case connecting
    /// Conectado, con los nombres de sus herramientas.
    case ready([String])
    case failed(String)
}

/// Catálogo cerrado que trae la app. Además se puede añadir un servidor propio.
public enum PluginCatalog {
    public static let claudeCodeBuiltin = "claude_code"

    public static let all: [PluginConfig] = [
        PluginConfig(id: "context7", name: "Context7",
                     detail: "Documentación actualizada de librerías y frameworks. No necesita cuenta.",
                     kind: .service, icon: "books.vertical", url: URL(string: "https://mcp.context7.com/mcp")),
        PluginConfig(id: "github", name: "GitHub",
                     detail: "Repositorios, issues y pull requests. Necesita el secreto GITHUB_TOKEN.",
                     kind: .service, icon: "chevron.left.forwardslash.chevron.right",
                     url: URL(string: "https://api.githubcopilot.com/mcp/"), secretName: "GITHUB_TOKEN"),
        PluginConfig(id: "linear", name: "Linear",
                     detail: "Incidencias y proyectos. Necesita el secreto LINEAR_API_KEY.",
                     kind: .service, icon: "list.bullet.rectangle",
                     url: URL(string: "https://mcp.linear.app/mcp"), secretName: "LINEAR_API_KEY"),
        PluginConfig(id: "fetch", name: "Leer páginas web",
                     detail: "Descarga una página y la convierte en texto, desde la máquina Linux.",
                     kind: .addon, icon: "globe",
                     install: "sudo apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq pipx && pipx install mcp-server-fetch && sudo apt-get clean",
                     command: "$HOME/.local/bin/mcp-server-fetch"),
        PluginConfig(id: "browser", name: "Navegador",
                     detail: "Un navegador sin pantalla en la máquina Linux: abre páginas, pulsa, rellena formularios y lee el resultado. Descarga unos 400 MB.",
                     kind: .addon, icon: "safari",
                     install: "sudo apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nodejs npm && sudo npm install -g --silent @playwright/mcp && cd \"$(npm root -g)/@playwright/mcp\" && sudo npx --yes playwright install-deps chromium && npx --yes playwright install chromium && sudo apt-get clean",
                     command: "playwright-mcp --headless --browser chromium --isolated"),
        PluginConfig(id: "claude_code", name: "Claude Code",
                     detail: "El agente le delega tareas de programación dentro de la máquina Linux. Necesita el secreto ANTHROPIC_API_KEY.",
                     kind: .addon, icon: "hammer", secretName: "ANTHROPIC_API_KEY",
                     install: "curl -fsSL https://claude.ai/install.sh | bash",
                     builtin: claudeCodeBuiltin),
    ]
}

/// Fila de la pantalla Plugins: un plugin y su estado.
public struct PluginRow: Identifiable, Hashable, Sendable {
    public var id: String { config.id }
    public var config: PluginConfig
    /// El usuario lo ha añadido (conectado o instalado).
    public var added: Bool
    public var state: PluginState

    public init(config: PluginConfig, added: Bool, state: PluginState = .idle) {
        self.config = config
        self.added = added
        self.state = state
    }
}

public extension SettingsKey {
    static let plugins = "plugins"                     // [PluginConfig]
    static let installedAddons = "installedAddons"     // [String]: complementos ya instalados en la VM
}
