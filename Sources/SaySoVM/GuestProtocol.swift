import Foundation
import SaySoCore

// Protocolo host ↔ agente invitado por vsock (ADR-0004).
// Cada mensaje es una trama: 4 bytes de longitud (big endian) + un objeto JSON.

/// Puerto vsock en el que escucha el agente invitado.
public let guestAgentPort: UInt32 = 7300

public struct GuestRequest: Codable, Hashable, Sendable {
    public var op: String
    public var command: String?
    public var cwd: String?
    public var timeout: Double?
    public var path: String?
    /// Contenido en base64 (op `write`).
    public var data: String?
    /// Variables de entorno añadidas al proceso (ops `exec` y `spawn`).
    public var env: [String: String]?

    public static let ping = GuestRequest(op: "ping")
    public static let stats = GuestRequest(op: "stats")
    public static let poweroff = GuestRequest(op: "poweroff")

    public static func exec(_ command: String, cwd: String? = nil, timeout: Double,
                            env: [String: String] = [:]) -> GuestRequest {
        var request = GuestRequest(op: "exec", command: command, cwd: cwd, timeout: timeout)
        if !env.isEmpty { request.env = env }
        return request
    }

    /// Proceso que sigue vivo; tras la respuesta la conexión transporta su entrada y su salida.
    public static func spawn(_ command: String, env: [String: String] = [:]) -> GuestRequest {
        var request = GuestRequest(op: "spawn", command: command)
        if !env.isEmpty { request.env = env }
        return request
    }

    public static func read(_ path: String) -> GuestRequest { GuestRequest(op: "read", path: path) }

    public static func write(_ path: String, content: Data) -> GuestRequest {
        GuestRequest(op: "write", path: path, data: content.base64EncodedString())
    }
}

public struct GuestResponse: Codable, Hashable, Sendable {
    public var ok: Bool
    public var error: String?
    public var exit: Int32?
    public var stdout: String?
    public var stderr: String?
    public var timedOut: Bool?
    public var data: String?
    public var cpu: Double?
    public var cpus: Int?
    public var memTotal: UInt64?
    public var memUsed: UInt64?
    public var diskTotal: UInt64?
    public var diskUsed: UInt64?

    enum CodingKeys: String, CodingKey {
        case ok, error, exit, stdout, stderr, data, cpu, cpus
        case timedOut = "timed_out"
        case memTotal = "mem_total"
        case memUsed = "mem_used"
        case diskTotal = "disk_total"
        case diskUsed = "disk_used"
    }

    public var commandResult: CommandResult? {
        guard let exit else { return nil }
        return CommandResult(exitCode: exit, stdout: stdout ?? "", stderr: stderr ?? "", timedOut: timedOut ?? false)
    }

    public var stats: ComputerStats? {
        guard let cpu, let cpus, let memTotal, let memUsed, let diskTotal, let diskUsed else { return nil }
        return ComputerStats(cpuPercent: cpu, cpuCount: cpus, memoryUsed: memUsed, memoryTotal: memTotal,
                             diskUsed: diskUsed, diskTotal: diskTotal)
    }
}

public enum GuestError: Error, LocalizedError, Equatable, Sendable {
    case notRunning
    case connectionClosed
    case frameTooLarge(Int)
    case io(Int32)
    case guest(String)
    case bootTimeout
    case timeout

    public var errorDescription: String? {
        switch self {
        case .notRunning: return tr("La máquina Linux no está en marcha.")
        case .connectionClosed: return tr("La máquina Linux cerró la conexión.")
        case let .frameTooLarge(size): return tr("Respuesta demasiado grande de la máquina Linux (%@ bytes).", "\(size)")
        case let .io(code): return tr("Error de comunicación con la máquina Linux (errno %@).", "\(code)")
        case let .guest(message): return message
        case .timeout: return tr("La máquina Linux no respondió a tiempo.")
        case .bootTimeout: return tr("La máquina Linux no respondió tras arrancar. Mira vm/console.log para ver el motivo.")
        }
    }
}

public enum GuestFraming {
    /// Tope de una trama: 64 MB.
    public static let maxFrame = 64 * 1024 * 1024

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let body = try JSONEncoder().encode(value)
        guard body.count <= maxFrame else { throw GuestError.frameTooLarge(body.count) }
        var length = UInt32(body.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(body)
        return frame
    }

    /// Longitud del cuerpo a partir de la cabecera de 4 bytes.
    public static func bodyLength(header: Data) throws -> Int {
        guard header.count == 4 else { throw GuestError.connectionClosed }
        let length = header.reduce(0) { ($0 << 8) | Int($1) }
        guard length <= maxFrame else { throw GuestError.frameTooLarge(length) }
        return length
    }

    // MARK: E/S bloqueante sobre un descriptor

    static func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < buffer.count {
                let n = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw GuestError.io(errno)
                }
                offset += n
            }
        }
    }

    static func readExactly(_ count: Int, from fd: Int32) throws -> Data {
        var data = Data(count: count)
        var offset = 0
        try data.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
            while offset < count {
                let n = Darwin.read(fd, buffer.baseAddress! + offset, count - offset)
                if n == 0 { throw GuestError.connectionClosed }
                if n < 0 {
                    if errno == EINTR { continue }
                    throw GuestError.io(errno)
                }
                offset += n
            }
        }
        return data
    }

    /// Lee lo que haya disponible (hasta `max` bytes). Devuelve vacío si el otro lado cerró.
    static func readSome(from fd: Int32, max: Int = 65536) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: max)
        while true {
            let n = Darwin.read(fd, &buffer, max)
            if n >= 0 { return Data(buffer[0..<n]) }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { throw GuestError.timeout }
            throw GuestError.io(errno)
        }
    }

    /// Envía una petición y espera su respuesta por el descriptor.
    static func roundTrip(_ request: GuestRequest, fd: Int32) throws -> GuestResponse {
        try writeAll(try encode(request), to: fd)
        let length = try bodyLength(header: try readExactly(4, from: fd))
        return try JSONDecoder().decode(GuestResponse.self, from: try readExactly(length, from: fd))
    }
}
