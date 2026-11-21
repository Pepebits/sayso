import Foundation

/// Sustitución fija del dictado: «arroba» → «@».
public struct TextReplacement: Hashable, Codable, Sendable, Identifiable {
    public var from: String
    public var to: String
    public var id: String { from.lowercased() }

    public init(from: String, to: String) {
        self.from = from
        self.to = to
    }
}

/// Diccionario personal del dictado: palabras que se escriben de una forma concreta y sustituciones.
public enum DictationVocabulary {
    public static let maxWords = 100
    public static let maxReplacements = 50

    /// Aplica las sustituciones y escribe cada palabra del diccionario como está en él
    /// («pepebits» → «Pepebits»). Solo cambia palabras enteras, sin distinguir mayúsculas.
    public static func apply(_ text: String, vocabulary: [String], replacements: [TextReplacement]) -> String {
        var out = text
        for replacement in replacements where !replacement.from.trimmingCharacters(in: .whitespaces).isEmpty {
            out = replaceWhole(replacement.from, with: replacement.to, in: out)
        }
        for word in vocabulary where !word.trimmingCharacters(in: .whitespaces).isEmpty {
            out = replaceWhole(word, with: word, in: out)
        }
        return out
    }

    /// Pista para el modelo de corrección: «Escribe así estos nombres: …».
    public static func correctionHint(_ vocabulary: [String]) -> String? {
        let words = clean(vocabulary)
        guard !words.isEmpty else { return nil }
        return "Escribe exactamente así estos nombres y palabras cuando aparezcan: " + words.joined(separator: ", ") + "."
    }

    /// Sin vacíos ni repetidos (sin distinguir mayúsculas), en el orden en que se añadieron.
    public static func clean(_ vocabulary: [String]) -> [String] {
        var seen = Set<String>()
        return vocabulary.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
            .prefix(maxWords).map { $0 }
    }

    private static func replaceWhole(_ needle: String, with replacement: String, in text: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: needle.trimmingCharacters(in: .whitespaces))
        guard let regex = try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}])\(escaped)(?![\\p{L}\\p{N}])",
                                                   options: [.caseInsensitive]) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range,
                                              withTemplate: NSRegularExpression.escapedTemplate(for: replacement))
    }
}
