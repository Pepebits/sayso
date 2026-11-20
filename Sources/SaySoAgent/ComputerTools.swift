import Foundation
import SaySoCore

// Herramientas del ordenador Linux del agente. Delegan en `AgentComputer`,
// que ya pasa por el motor de permisos y deja registro.

/// Lo que hace falta para pasar claves de Secretos a los comandos: dónde están y quién da permiso.
public struct ComputerSecrets: Sendable {
    let vault: SecretVault
    let store: SaySoStoring
    let broker: PermissionBrokering

    public init(vault: SecretVault, store: SaySoStoring, broker: PermissionBrokering) {
        self.vault = vault
        self.store = store
        self.broker = broker
    }
}

public enum ComputerTools {
    /// Sin `secrets` (el modo invitado), los comandos no pueden usar claves.
    /// `vision`: el modelo ve imágenes, así que puede mirar las de la máquina.
    public static func all(computer: AgentComputer, secrets: ComputerSecrets? = nil, vision: Bool = false) -> [AgentTool] {
        [ComputerRunTool(computer: computer, secrets: secrets), ComputerReadFileTool(computer: computer),
         ComputerWriteFileTool(computer: computer)] + (vision ? [ViewImageTool(computer: computer)] : [])
    }

    /// Texto que recibe el modelo tras un comando.
    static func render(_ result: CommandResult) -> String {
        var parts = [result.timedOut ? "Tiempo agotado: el comando se ha cortado." : "Código de salida: \(result.exitCode)"]
        let out = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let err = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !out.isEmpty { parts.append("stdout:\n\(out)") }
        if !err.isEmpty { parts.append("stderr:\n\(err)") }
        if out.isEmpty, err.isEmpty { parts.append("(sin salida)") }
        return parts.joined(separator: "\n\n")
    }
}

public struct ComputerRunTool: AgentTool {
    let computer: AgentComputer
    var secrets: ComputerSecrets?
    public init(computer: AgentComputer, secrets: ComputerSecrets? = nil) {
        self.computer = computer
        self.secrets = secrets
    }
    public var name: String { "computer_run" }
    public var description: String {
        var text = """
        Ejecuta un comando de bash en tu propio ordenador Linux (Debian, arm64), una máquina virtual aislada \
        del Mac del usuario. Tienes sudo y conexión a internet; puedes instalar paquetes con apt, clonar \
        repositorios y ejecutar código. El directorio de trabajo es ~/sayso y lo que dejes ahí se conserva. \
        Los archivos del Mac no están en esta máquina. Cada llamada es un shell nuevo y no interactivo.
        """
        if secrets != nil {
            text += """
             Para usar una clave que el usuario guardó en Secretos (p. ej. GITHUB_TOKEN), pon su nombre en \
            «secrets»: llega al comando como variable de entorno ($GITHUB_TOKEN). Tú nunca ves su valor; no \
            la imprimas ni la escribas en archivos. Si no está guardada, pídela con request_secret.
            """
        }
        return text
    }
    public var inputSchema: JSONValue {
        var properties: [String: JSONValue] = [
            "command": .property("string", "Comando de bash"),
            "cwd": .property("string", "Directorio opcional; relativo a ~/sayso"),
            "timeout_seconds": ["type": "integer", "minimum": 1, "maximum": 1800,
                                "description": "Límite en segundos (120 por defecto)"],
        ]
        if secrets != nil {
            properties["secrets"] = ["type": "array", "items": ["type": "string"],
                                     "description": "Nombres de claves de Secretos que el comando necesita (hasta 5)"]
        }
        return .objectSchema(properties, required: ["command"])
    }

    /// Hasta este número de claves en un comando.
    static let maxSecrets = 5

    public func call(input: JSONValue, context: ToolContext) async throws -> String {
        let command = try input.requiredString("command", maxLength: 20000)
        let cwd = try input.optionalString("cwd", maxLength: 1000)
        let timeout = input["timeout_seconds"]?.intValue ?? 120
        guard (1...1800).contains(timeout) else { throw ToolInputError("«timeout_seconds» debe estar entre 1 y 1800.") }
        let names = Array(Set((input["secrets"]?.arrayValue ?? []).compactMap(\.stringValue))).sorted()
        guard !names.isEmpty else {
            let result = try await computer.run(command, cwd: cwd, timeout: TimeInterval(timeout), origin: context.origin)
            return ComputerTools.render(result)
        }
        guard let secrets else { throw ToolInputError("Aquí no se pueden usar secretos.") }
        guard names.count <= Self.maxSecrets else { throw ToolInputError("Como mucho \(Self.maxSecrets) secretos por comando.") }
        var env: [String: String] = [:]
        var missing: [String] = []
        for name in names {
            guard RequestSecretTool.isValidName(name) else {
                throw ToolInputError("«\(name)» no es un nombre de secreto válido (MAYÚSCULAS_CON_GUIONES_BAJOS).")
            }
            if let value = try secrets.vault.value(for: KeychainName.workSecret(name)), !value.isEmpty {
                env[name] = value
            } else {
                missing.append(name)
            }
        }
        guard missing.isEmpty else {
            return "Falta guardar en SaySo → Secretos: \(missing.joined(separator: ", ")). Pídelo con request_secret; " +
                "el usuario no debe pegarlo en el chat."
        }
        let computer = self.computer
        let origin = context.origin
        let values = env
        let result = try await secrets.broker.run(ActionRequest(
            action: ComputerAction.useSecrets,
            summary: "Usar \(names.joined(separator: ", ")) en un comando: \(String(command.prefix(300)))",
            parameters: ["Secretos": names.joined(separator: ", "), "Comando": String(command.prefix(2000))],
            origin: origin)) {
            try await computer.run(command, cwd: cwd, timeout: TimeInterval(timeout), env: values, origin: origin)
        }
        // Que en Secretos se vea cuándo se usó cada una.
        let now = Date()
        for var meta in (try? secrets.store.secrets()) ?? [] where names.contains(meta.name) {
            meta.lastUsed = now
            try? secrets.store.upsertSecret(meta)
        }
        return ComputerTools.render(result)
    }
}

public struct ComputerReadFileTool: AgentTool {
    let computer: AgentComputer
    public init(computer: AgentComputer) { self.computer = computer }
    public var name: String { "computer_read_file" }
    public var description: String { "Lee un archivo de texto de tu ordenador Linux (máximo 8 MB)." }
    public var inputSchema: JSONValue {
        .objectSchema(["path": .property("string", "Ruta; relativa a ~/sayso")], required: ["path"])
    }
    public func call(input: JSONValue, context: ToolContext) async throws -> String {
        let path = try input.requiredString("path", maxLength: 1000)
        let text = try await computer.readFile(path, origin: context.origin)
        let limit = 100_000
        return text.count > limit ? String(text.prefix(limit)) + "\n[… archivo recortado …]" : text
    }
}

public struct ComputerWriteFileTool: AgentTool {
    let computer: AgentComputer
    public init(computer: AgentComputer) { self.computer = computer }
    public var name: String { "computer_write_file" }
    public var description: String {
        "Crea o sobrescribe un archivo de texto en tu ordenador Linux. Crea las carpetas que falten."
    }
    public var inputSchema: JSONValue {
        .objectSchema([
            "path": .property("string", "Ruta; relativa a ~/sayso"),
            "content": .property("string", "Contenido completo del archivo"),
        ], required: ["path", "content"])
    }
    public func call(input: JSONValue, context: ToolContext) async throws -> String {
        let path = try input.requiredString("path", maxLength: 1000)
        guard let content = input["content"]?.stringValue else { throw ToolInputError("Falta el parámetro «content» (texto).") }
        guard content.utf8.count <= 2_000_000 else { throw ToolInputError("«content» supera 2 MB.") }
        try await computer.writeFile(path, content: content, origin: context.origin)
        return "Archivo escrito: \(path)"
    }
}
