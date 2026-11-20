import Foundation

/// Traducción de textos visibles. El español del código es la clave; el inglés vive en
/// `Resources/en.lproj/Localizable.strings`, dentro de la app. Sin traducción se devuelve la clave.
public enum L10n {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var source: Bundle = .main
    nonisolated(unsafe) private static var missing: Set<String> = []

    /// Bundle del que salen las traducciones. Los tests lo cambian.
    public static var bundle: Bundle {
        get { lock.lock(); defer { lock.unlock() }; return source }
        set { lock.lock(); source = newValue; lock.unlock() }
    }

    nonisolated(unsafe) private static var forced: (code: String, bundle: Bundle)?

    /// Idioma elegido en Ajustes («es» o «en»); `nil` sigue al del sistema. Si la app no lleva ese
    /// idioma empaquetado, se queda como estaba.
    public static var forcedLanguage: String? {
        get { lock.lock(); defer { lock.unlock() }; return forced?.code }
        set {
            lock.lock()
            defer { lock.unlock() }
            guard let code = newValue else { forced = nil; return }
            forced = source.path(forResource: code, ofType: "lproj").flatMap(Bundle.init(path:)).map { (code, $0) }
        }
    }

    private static var lookupBundle: Bundle {
        lock.lock()
        defer { lock.unlock() }
        return forced?.bundle ?? source
    }

    /// Idioma en el que se está mostrando la app («es» o «en»), para fechas y similares.
    /// Sin traducciones empaquetadas (tests, `swift run`) es español.
    public static var languageCode: String {
        if let forcedLanguage { return forcedLanguage }
        let current = bundle
        // Solo cuenta un bundle que lleve nuestra tabla en inglés (el de los tests de Xcode no).
        guard current.path(forResource: "Localizable", ofType: "strings", inDirectory: nil,
                           forLocalization: "en") != nil else { return "es" }
        return current.preferredLocalizations.first ?? "es"
    }

    /// Idiomas de la interfaz y la región que se usa para fechas y números en cada uno.
    public static let regions: [String: String] = [
        "es": "es_ES", "en": "en_GB", "gl": "gl_ES", "fr": "fr_FR", "pt": "pt_PT",
    ]

    public static var locale: Locale { Locale(identifier: regions[languageCode] ?? "es_ES") }

    /// Código de voz para leer en alto en el idioma de la app («fr-FR»). macOS no trae voz en
    /// gallego: se usa la española, que es la más cercana.
    public static var speechCode: String {
        let code = languageCode == "gl" ? "es" : languageCode
        return (regions[code] ?? "es_ES").replacingOccurrences(of: "_", with: "-")
    }

    /// Ayuda de desarrollo: SAYSO_L10N_AUDIT=<archivo> apunta ahí las claves sin traducción.
    private static let auditFile = ProcessInfo.processInfo.environment["SAYSO_L10N_AUDIT"]

    static func lookup(_ key: String) -> String {
        guard !key.isEmpty else { return key }
        let value = lookupBundle.localizedString(forKey: key, value: nil, table: nil)
        if let auditFile, value == key, key.rangeOfCharacter(from: .letters) != nil { record(key, to: auditFile) }
        return value
    }

    private static func record(_ key: String, to path: String) {
        lock.lock()
        let isNew = missing.insert(key).inserted
        let all = missing.sorted()
        lock.unlock()
        if isNew { try? all.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8) }
    }
}

/// Traduce un texto fijo.
public func tr(_ key: String) -> String { L10n.lookup(key) }

/// Traduce un texto con huecos (`%@`). Los huecos se pasan ya como texto.
public func tr(_ key: String, _ arguments: String...) -> String {
    String(format: L10n.lookup(key), arguments: arguments.map { $0 as CVarArg })
}
