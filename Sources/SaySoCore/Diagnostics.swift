import Foundation

// Informe de errores para abrir un issue: versión, estado, avisos y errores recientes y los cierres
// inesperados. Se escribe en inglés, como los issues del repositorio, y se limpia de datos
// personales antes de guardarlo. El usuario lo revisa antes de compartirlo: nada sale solo del Mac.

/// Resumen de un informe de cierre de macOS (`~/Library/Logs/DiagnosticReports/SaySo-*.ips`).
public struct CrashSummary: Equatable, Sendable {
    public var date: Date?
    public var appVersion: String
    public var osVersion: String
    /// «EXC_CRASH (SIGABRT)».
    public var exception: String
    /// Motivo que da el sistema, p. ej. «abort() called».
    public var reasons: [String]
    /// Pila del hilo que falló: «SaySo  td::Scheduler::clear()».
    public var frames: [String]

    public static let maxFrames = 20

    public init(date: Date?, appVersion: String, osVersion: String, exception: String, reasons: [String], frames: [String]) {
        self.date = date
        self.appVersion = appVersion
        self.osVersion = osVersion
        self.exception = exception
        self.reasons = reasons
        self.frames = frames
    }

    /// `nil` si el archivo no es un informe de cierre que se entienda.
    public static func parse(_ ips: String) -> CrashSummary? {
        guard let newline = ips.firstIndex(of: "\n"),
              let header = json(String(ips[..<newline])),
              let body = json(String(ips[ips.index(after: newline)...])) else { return nil }
        let exception = body["exception"] as? [String: Any] ?? [:]
        var kind = exception["type"] as? String ?? "?"
        if let signal = exception["signal"] as? String { kind += " (\(signal))" }
        var reasons: [String] = []
        if let asi = body["asi"] as? [String: [String]] {
            reasons += asi.keys.sorted().flatMap { asi[$0] ?? [] }
        }
        if let indicator = (body["termination"] as? [String: Any])?["indicator"] as? String { reasons.append(indicator) }

        var frames: [String] = []
        let images = body["usedImages"] as? [[String: Any]] ?? []
        if let threads = body["threads"] as? [[String: Any]], let faulting = body["faultingThread"] as? Int,
           threads.indices.contains(faulting) {
            for frame in (threads[faulting]["frames"] as? [[String: Any]] ?? []).prefix(maxFrames) {
                let index = frame["imageIndex"] as? Int ?? -1
                let image = images.indices.contains(index) ? images[index]["name"] as? String ?? "?" : "?"
                let symbol = frame["symbol"] as? String ?? String(format: "+0x%llx", (frame["imageOffset"] as? Int).map(Int64.init) ?? 0)
                frames.append("\(image)  \(symbol)")
            }
        }
        let stamp = header["timestamp"] as? String
        return CrashSummary(date: stamp.flatMap(parseDate), appVersion: header["app_version"] as? String ?? "?",
                            osVersion: header["os_version"] as? String ?? "?", exception: kind,
                            reasons: reasons, frames: frames)
    }

    private static func json(_ text: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }

    /// «2026-11-19 02:26:10.00 +0100».
    private static func parseDate(_ text: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd HH:mm:ss.SS Z", "yyyy-MM-dd HH:mm:ss Z"] {
            f.dateFormat = format
            if let date = f.date(from: text) { return date }
        }
        return nil
    }
}

public enum DiagnosticsReport {
    /// Avisos y errores de los últimos días que entran en el informe.
    public static let logDays = 7
    public static let maxLogEntries = 150

    /// Quita lo que identifica a alguien: la carpeta de usuario, correos, @usuarios, teléfonos,
    /// números largos (IDs de Telegram, de chats, de mensajes) y lo que va entre comillas «…»
    /// (nombres de chats, de contactos, de archivos).
    public static func scrub(_ text: String, home: String = NSHomeDirectory()) -> String {
        var out = text
        if !home.isEmpty && home != "/" { out = out.replacingOccurrences(of: home, with: "~") }
        let rules: [(String, String)] = [
            (#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, "<email>"),
            (#"\+\d[\d \-]{7,}\d"#, "<phone>"),
            (#"(?<![\w.])@[A-Za-z][A-Za-z0-9_]{3,}"#, "@<user>"),
            (#"-?\d{6,}"#, "<number>"),
            (#"«[^»\n]*»"#, "«…»"),
            (#"/Users/[^/\s]+"#, "~"),
        ]
        for (pattern, replacement) in rules {
            out = out.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return out
    }

    /// Texto del informe en Markdown, ya limpio. `redact` quita además los valores de los secretos.
    public static func make(appVersion: String, osVersion: String, machine: String, state: [(String, String)],
                            logs: [LogEntry], crashes: [CrashSummary], now: Date = Date(),
                            home: String = NSHomeDirectory(), redact: (String) -> String = { $0 }) -> String {
        let iso = ISO8601DateFormatter()
        let keep = "\u{1}"
        var lines = [
            "## SaySo diagnostics",
            "",
            "Generated \(iso.string(from: now)). Review it before sharing: names, numbers and addresses are hidden, but check anything else you would rather not publish.",
            "",
            "- SaySo: \(appVersion)",
            "- macOS: \(osVersion)",
            "- Mac: \(machine)",
        ]
        lines += state.map { "- \($0.0): \($0.1)" }

        lines += ["", "### Unexpected quits (\(crashes.count))"]
        if crashes.isEmpty { lines.append("None in the last 30 days.") }
        for crash in crashes {
            lines += ["", "**\(crash.date.map(iso.string(from:)) ?? "?")**, SaySo \(crash.appVersion), \(crash.osVersion): \(crash.exception)"]
            if !crash.reasons.isEmpty { lines.append("Reason: " + crash.reasons.joined(separator: "; ")) }
            // Los símbolos de la pila son del código, no del usuario: solo se oculta la carpeta de usuario
            // (con @<user> se estropearían atributos como «@escaping»). Se marcan para no limpiarlos dos veces.
            if !crash.frames.isEmpty {
                lines += ["```"] + crash.frames.map { keep + $0.replacingOccurrences(of: home, with: "~") } + ["```"]
            }
        }

        let since = now.addingTimeInterval(-Double(logDays) * 86_400)
        let recent = logs.filter { $0.level.rank >= LogLevel.warning.rank && $0.date >= since }
            .sorted { $0.date < $1.date }.suffix(maxLogEntries)
        lines += ["", "### Warnings and errors, last \(logDays) days (\(recent.count))"]
        if recent.isEmpty {
            lines.append("None.")
        } else {
            lines.append("```")
            lines += recent.map { "\(iso.string(from: $0.date)) \($0.level.rawValue) [\($0.category)] \($0.message)" }
            lines.append("```")
        }
        return lines.map { line in
            line.hasPrefix(keep) ? String(line.dropFirst(keep.count)) : scrub(redact(line), home: home)
        }.joined(separator: "\n") + "\n"
    }
}
