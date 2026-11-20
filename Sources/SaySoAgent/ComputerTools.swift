import Foundation
import SaySoCore

// Herramientas del ordenador Linux del agente (ADR-0004). Delegan en `AgentComputer`,
// que ya pasa por el motor de permisos y deja registro.

public enum ComputerTools {
    public static func all(computer: AgentComputer) -> [AgentTool] {
        [ComputerRunTool(computer: computer), ComputerReadFileTool(computer: computer),
         ComputerWriteFileTool(computer: computer)]
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
    public init(computer: AgentComputer) { self.computer = computer }
    public var name: String { "computer_run" }
    public var description: String {
        """
        Ejecuta un comando de bash en tu propio ordenador Linux (Debian, arm64), una máquina virtual aislada \
        del Mac del usuario. Tienes sudo y conexión a internet; puedes instalar paquetes con apt, clonar \
        repositorios y ejecutar código. El directorio de trabajo es ~/sayso y lo que dejes ahí se conserva. \
        Los archivos del Mac no están en esta máquina. Cada llamada es un shell nuevo y no interactivo.
        """
    }
    public var inputSchema: JSONValue {
        .objectSchema([
            "command": .property("string", "Comando de bash"),
            "cwd": .property("string", "Directorio opcional; relativo a ~/sayso"),
            "timeout_seconds": ["type": "integer", "minimum": 1, "maximum": 1800,
                                "description": "Límite en segundos (120 por defecto)"],
        ], required: ["command"])
    }
    public func call(input: JSONValue, context: ToolContext) async throws -> String {
        let command = try input.requiredString("command", maxLength: 20000)
        let cwd = try input.optionalString("cwd", maxLength: 1000)
        let timeout = input["timeout_seconds"]?.intValue ?? 120
        guard (1...1800).contains(timeout) else { throw ToolInputError("«timeout_seconds» debe estar entre 1 y 1800.") }
        let result = try await computer.run(command, cwd: cwd, timeout: TimeInterval(timeout), origin: context.origin)
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
