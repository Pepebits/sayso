import Foundation
import Security
import SaySoCore

// MARK: - Llavero

public struct KeychainError: Error, LocalizedError, Sendable, Equatable {
    public let status: OSStatus

    public var errorDescription: String? {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? tr("código %@", "\(status)")
        return tr("Error del Llavero: %@", "\(message)")
    }
}

/// Contraseñas genéricas del Llavero: servicio `AppPaths.bundleID`, cuenta = nombre.
public final class KeychainVault: SecretVault {
    private let service: String

    public init(service: String = AppPaths.bundleID) {
        self.service = service
    }

    private func baseQuery(_ name: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name,
        ]
    }

    public func value(for name: String) throws -> String? {
        var query = baseQuery(name)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        guard let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func setValue(_ value: String, for name: String) throws {
        let data = Data(value.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery(name) as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw KeychainError(status: status) }

        var add = baseQuery(name)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
    }

    public func removeValue(for name: String) throws {
        let status = SecItemDelete(baseQuery(name) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}

/// Almacén en memoria para tests y vistas previas.
public final class InMemoryVault: SecretVault, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String]

    public init(_ values: [String: String] = [:]) {
        self.values = values
    }

    public func value(for name: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return values[name]
    }

    public func setValue(_ value: String, for name: String) throws {
        lock.lock(); defer { lock.unlock() }
        values[name] = value
    }

    public func removeValue(for name: String) throws {
        lock.lock(); defer { lock.unlock() }
        values[name] = nil
    }

    /// Copia de todos los valores (útil para alimentar un `SecretRedactor`).
    public func allValues() -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        return values
    }
}

// MARK: - Redacción

/// Sustituye valores secretos (literal, base64 y URL) por `[NOMBRE]`.
public final class SecretRedactor: SecretRedacting {
    /// Por debajo de esta longitud no se redacta: habría demasiados falsos positivos.
    public static let minimumLength = 6

    private let values: @Sendable () -> [String: String]

    /// `values` devuelve nombre → valor; se consulta en cada llamada.
    public init(values: @escaping @Sendable () -> [String: String]) {
        self.values = values
    }

    public func redact(_ text: String) -> String {
        var patterns: [(needle: String, name: String)] = []
        var seen = Set<String>()
        // Orden estable por nombre para que el resultado sea determinista.
        for (name, value) in values().sorted(by: { $0.key < $1.key }) where value.count >= Self.minimumLength {
            for form in Self.encodings(of: value) where !form.isEmpty && seen.insert(form).inserted {
                patterns.append((form, name))
            }
        }
        // Los más largos primero, para que un secreto contenido en otro no rompa el mayor.
        patterns.sort { $0.needle.count > $1.needle.count }

        var out = text
        for p in patterns where out.contains(p.needle) {
            out = out.replacingOccurrences(of: p.needle, with: "[\(p.name)]")
        }
        return out
    }

    /// Formas habituales de un valor: literal, base64 (con y sin relleno, y variante URL) y codificado para URL.
    static func encodings(of value: String) -> [String] {
        var forms = [value]
        let b64 = Data(value.utf8).base64EncodedString()
        let b64NoPad = b64.trimmingCharacters(in: CharacterSet(charactersIn: "="))
        let b64URL = b64NoPad.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        forms += [b64, b64NoPad, b64URL]

        // Caracteres no reservados de RFC 3986, solo ASCII.
        let unreserved = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        if let strict = value.addingPercentEncoding(withAllowedCharacters: unreserved) {
            forms.append(strict)
            forms.append(strict.replacingOccurrences(of: "%20", with: "+"))
        }
        if let query = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            forms.append(query)
        }
        return forms
    }
}
