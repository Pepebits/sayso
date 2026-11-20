import Foundation
import SaySoCore

/// Sesión de consola persistente en la máquina Linux: un único bash que sigue vivo entre
/// comandos, así `cd`, las variables y los entornos activados se conservan (ADR-0004).
///
/// No es un terminal completo: no hay pseudoterminal, así que los programas de pantalla completa
/// (vim, top) no funcionan. Los comandos no reciben entrada de teclado.
public actor ConsoleSession {
    public struct Finished: Sendable, Equatable {
        public var exitCode: Int32
        public var directory: String
    }

    public enum Failure: Error, LocalizedError {
        case closed
        public var errorDescription: String? { tr("La sesión de consola se cerró. El siguiente comando abre una nueva.") }
    }

    private let computer: AgentComputer
    private var stream: ProcessStream?
    public private(set) var directory = "~/sayso"

    public init(computer: AgentComputer) { self.computer = computer }

    /// Marca que separa el final de un comando; lleva un valor al azar para que la salida no la imite.
    static func endMarker(_ nonce: String) -> String { "__SAYSO_FIN_\(nonce)__" }

    /// Lo que se escribe en bash: el comando sin entrada de teclado y, después, la marca con el
    /// código de salida y la carpeta actual.
    static func script(for command: String, nonce: String) -> String {
        "{ \(command)\n} </dev/null\nprintf '\\n%s %s %s\\n' \(endMarker(nonce)) \"$?\" \"$PWD\"\n"
    }

    /// Interpreta la línea de la marca: código de salida y carpeta.
    static func parseEnd(_ line: String, nonce: String) -> Finished? {
        let marker = endMarker(nonce) + " "
        guard line.hasPrefix(marker) else { return nil }
        let rest = line.dropFirst(marker.count)
        guard let space = rest.firstIndex(of: " "), let code = Int32(rest[..<space]) else { return nil }
        return Finished(exitCode: code, directory: ConsoleText.shortDirectory(String(rest[rest.index(after: space)...])))
    }

    /// Ejecuta un comando en la sesión y entrega su salida línea a línea según llega.
    public func run(_ command: String, onLine: @escaping @Sendable (String) -> Void) async throws -> Finished {
        let stream = try await openIfNeeded()
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let script = Self.script(for: command, nonce: nonce)
        do {
            let finished = try await Task.detached { () throws -> Finished in
                try stream.write(Data(script.utf8))
                var pendingBlank = false
                while true {
                    guard let data = try stream.readLine(timeout: 3600) else { throw Failure.closed }
                    let line = ConsoleText.clean(String(decoding: data, as: UTF8.self))
                    if let end = Self.parseEnd(line, nonce: nonce) { return end }
                    // La línea en blanco que precede a la marca no es salida del comando.
                    if pendingBlank { onLine("") }
                    pendingBlank = line.isEmpty
                    if !line.isEmpty { onLine(line) }
                }
            }.value
            directory = finished.directory
            return finished
        } catch {
            close()
            throw error
        }
    }

    private func openIfNeeded() async throws -> ProcessStream {
        if let stream { return stream }
        // Bash de inicio de sesión (para tener ~/.local/bin en el PATH), con los errores por la misma salida.
        let opened = try await computer.openProcess("cd ~/sayso 2>/dev/null; exec bash -l 2>&1",
                                                    env: ["TERM": "dumb", "NO_COLOR": "1"], origin: "consola")
        stream = opened
        directory = "~/sayso"
        return opened
    }

    /// Cierra la sesión (mata lo que esté corriendo). La siguiente orden abre otra desde ~/sayso.
    public func close() {
        stream?.close()
        stream = nil
        directory = "~/sayso"
    }
}
