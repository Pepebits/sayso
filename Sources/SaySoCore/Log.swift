import Foundation

// Registro de la app: qué ha ido pasando y qué ha fallado. Se guarda en un archivo de texto de
// este Mac. No lleva lo que se dicta ni el contenido de los mensajes: solo sucesos y errores.

public enum LogLevel: String, Codable, CaseIterable, Sendable {
    case info, warning, error

    /// Para ordenar y filtrar «de avisos para arriba».
    public var rank: Int {
        switch self {
        case .info: return 0
        case .warning: return 1
        case .error: return 2
        }
    }
}

/// Áreas de la app que escriben en el registro. El texto es la clave en español.
public enum LogCategory {
    public static let app = "app"
    public static let dictation = "dictado"
    public static let telegram = "telegram"
    public static let computer = "ordenador"
    public static let plugins = "plugins"
    public static let voice = "voz"

    public static let all = [app, dictation, telegram, computer, plugins, voice]
}

public struct LogEntry: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var date: Date
    public var level: LogLevel
    public var category: String
    public var message: String

    public init(id: UUID = UUID(), date: Date = Date(), level: LogLevel, category: String, message: String) {
        self.id = id
        self.date = date
        self.level = level
        self.category = category
        self.message = message
    }
}

/// Archivo del registro: una línea por entrada, con tabuladores entre fecha, nivel, área y mensaje.
/// Cuando pasa de `maxBytes` se queda con la mitad más reciente.
public final class AppLogFile: @unchecked Sendable {
    public let url: URL
    private let maxBytes: Int
    private let lock = NSLock()

    public init(url: URL, maxBytes: Int = 1_000_000) {
        self.url = url
        self.maxBytes = maxBytes
    }

    private static func formatter() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }

    /// Una entrada en una sola línea: los saltos y tabuladores del mensaje pasan a espacios.
    public static func line(for entry: LogEntry) -> String {
        let clean: (String) -> String = { text in
            text.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\t", with: " ")
        }
        return [formatter().string(from: entry.date), entry.level.rawValue.uppercased(),
                clean(entry.category), clean(entry.message)].joined(separator: "\t")
    }

    public static func entry(fromLine line: String) -> LogEntry? {
        let parts = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4, let date = formatter().date(from: parts[0]),
              let level = LogLevel(rawValue: parts[1].lowercased()) else { return nil }
        return LogEntry(date: date, level: level, category: parts[2], message: parts[3])
    }

    public func append(_ entry: LogEntry) {
        lock.lock()
        defer { lock.unlock() }
        let data = Data((Self.line(for: entry) + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            let size = (try? handle.offset()) ?? 0
            try? handle.close()
            if size > UInt64(maxBytes) { trim() }
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Se queda con las líneas más recientes que caben en la mitad del límite.
    private func trim() {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        var kept: [Substring] = []
        var bytes = 0
        for line in text.split(separator: "\n").reversed() {
            bytes += line.utf8.count + 1
            if bytes > maxBytes / 2 { break }
            kept.append(line)
        }
        try? Data((kept.reversed().joined(separator: "\n") + "\n").utf8).write(to: url, options: .atomic)
    }

    /// Las últimas `limit` entradas, de la más antigua a la más reciente.
    public func entries(limit: Int) -> [LogEntry] {
        lock.lock()
        defer { lock.unlock() }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").suffix(max(limit, 0)).compactMap { Self.entry(fromLine: String($0)) }
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - Exportación

public enum ExportFormat: String, CaseIterable, Sendable {
    case text, csv, json

    public var fileExtension: String {
        switch self {
        case .text: return "log"
        case .csv: return "csv"
        case .json: return "json"
        }
    }
}

public enum Export {
    /// Campo de CSV: entre comillas si lleva coma, comillas o salto de línea.
    static func csvField(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func csv(_ rows: [[String]]) -> String {
        rows.map { $0.map(csvField).joined(separator: ",") }.joined(separator: "\n") + "\n"
    }

    private static func json(_ value: some Encodable) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) + "\n" } ?? "[]\n"
    }

    private static func day(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    // Registro

    private struct LogRow: Encodable {
        var date: Date
        var level: String
        var category: String
        var message: String
    }

    /// El registro en el formato pedido, en el orden recibido.
    public static func log(_ entries: [LogEntry], as format: ExportFormat) -> String {
        switch format {
        case .text:
            return entries.map(AppLogFile.line(for:)).joined(separator: "\n") + (entries.isEmpty ? "" : "\n")
        case .csv:
            let stamp = ISO8601DateFormatter()
            return csv([["date", "level", "category", "message"]] + entries.map {
                [stamp.string(from: $0.date), $0.level.rawValue, $0.category, $0.message]
            })
        case .json:
            return json(entries.map { LogRow(date: $0.date, level: $0.level.rawValue, category: $0.category, message: $0.message) })
        }
    }

    // Estadísticas

    private struct DayRow: Encodable {
        var day: String
        var requests: Int
        var dictations: Int
        var words: Int
        var seconds: Double
    }

    private struct ActionRow: Encodable {
        var day: String
        var action: String
        var outcome: String
        var count: Int
    }

    private struct StatsDocument: Encodable {
        var days: [DayRow]
        var actions: [ActionRow]
    }

    /// El uso por día de un periodo. En CSV, una fila por día; en JSON van además las acciones.
    public static func stats(days: [DayUsage], actions: [ActionBucket], as format: ExportFormat) -> String {
        let dayRows = days.map {
            DayRow(day: day($0.day), requests: $0.totals.requests, dictations: $0.totals.dictations,
                   words: $0.totals.words, seconds: ($0.totals.seconds * 10).rounded() / 10)
        }
        let actionRows = actions
            .sorted { ($0.day, $0.action.rawValue, $0.outcome.rawValue) < ($1.day, $1.action.rawValue, $1.outcome.rawValue) }
            .map { ActionRow(day: day($0.day), action: $0.action.rawValue, outcome: $0.outcome.rawValue, count: $0.count) }
        switch format {
        case .json:
            return json(StatsDocument(days: dayRows, actions: actionRows))
        case .csv, .text:
            return csv([["day", "requests", "dictations", "words", "seconds"]] + dayRows.map {
                [$0.day, "\($0.requests)", "\($0.dictations)", "\($0.words)", String(format: "%.1f", $0.seconds)]
            })
        }
    }
}
