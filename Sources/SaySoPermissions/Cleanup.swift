import Foundation
import Security
import SaySoCore

// Restablecer los permisos de macOS y borrar todo rastro de la app.
//
// Lo que no se puede hacer con la app abierta (quitarle sus propios permisos, borrar sus carpetas,
// mandarla a la Papelera) lo hace un guion de shell suelto que espera a que la app termine.

extension KeychainVault {
    /// Borra todas las claves que la app guarda en el Llavero.
    public func removeAll() throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: AppPaths.bundleID]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}

public struct CleanupError: Error, LocalizedError, Sendable, Equatable {
    public var message: String
    public var errorDescription: String? { message }
}

/// Qué se borra al quitar la app del Mac y el guion que lo hace.
public struct CleanupPlan: Sendable, Equatable {
    public var bundleID: String
    public var home: URL
    /// Proceso al que hay que esperar antes de tocar nada.
    public var pid: Int32
    /// Ruta de la app, para mandarla a la Papelera; `nil` la deja donde está.
    public var appPath: String?

    public init(bundleID: String = AppPaths.bundleID, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                pid: Int32 = ProcessInfo.processInfo.processIdentifier, appPath: String? = nil) {
        self.bundleID = bundleID
        self.home = home
        self.pid = pid
        self.appPath = appPath
    }

    /// Todo lo que la app deja en la carpeta del usuario.
    public var leftovers: [URL] {
        let library = home.appendingPathComponent("Library")
        return [
            library.appendingPathComponent("Application Support/SaySo"),
            library.appendingPathComponent("Preferences/\(bundleID).plist"),
            library.appendingPathComponent("Caches/\(bundleID)"),
            library.appendingPathComponent("Saved Application State/\(bundleID).savedState"),
            library.appendingPathComponent("HTTPStorages/\(bundleID)"),
            library.appendingPathComponent("WebKit/\(bundleID)"),
        ]
    }

    /// Un `rm -rf` no admite despistes: cada ruta tiene que estar dentro de la Biblioteca del
    /// usuario, a suficiente profundidad y ser claramente de esta app.
    public func validate() throws {
        guard bundleID.split(separator: ".").count >= 3, !bundleID.contains("/"), !bundleID.contains(" ") else {
            throw CleanupError(message: "Identificador de app no válido: \(bundleID)")
        }
        let library = home.appendingPathComponent("Library").standardizedFileURL.path
        guard home.pathComponents.count >= 3 else { throw CleanupError(message: "Carpeta de usuario no válida.") }
        for url in leftovers {
            let path = url.standardizedFileURL.path
            let own = path.hasSuffix("/Application Support/SaySo") || path.contains(bundleID)
            guard path.hasPrefix(library + "/"), url.pathComponents.count >= home.pathComponents.count + 3, own else {
                throw CleanupError(message: "Ruta fuera de lugar, no se borra: \(path)")
            }
        }
        if let appPath {
            guard appPath.hasSuffix(".app"), appPath.hasPrefix("/"), appPath.split(separator: "/").count >= 2 else {
                throw CleanupError(message: "Ruta de la app no válida: \(appPath)")
            }
        }
    }

    /// Primero los permisos, que solo se pueden quitar mientras la app sigue en el disco; después
    /// las carpetas; al final, la app a la Papelera, de donde se puede recuperar.
    public static let script = """
    pid="$1"; bundle="$2"; app="$3"; shift 3
    while kill -0 "$pid" 2>/dev/null; do sleep 0.3; done
    /usr/bin/tccutil reset All "$bundle" >/dev/null 2>&1
    for path in "$@"; do /bin/rm -rf -- "$path"; done
    /usr/bin/defaults delete "$bundle" >/dev/null 2>&1
    if [ -n "$app" ] && [ -d "$app" ]; then
      name="$(basename "$app" .app)"
      /bin/mv -f -- "$app" "$HOME/.Trash/$name $(date +%H%M%S).app" 2>/dev/null
    fi
    """

    public var arguments: [String] {
        ["-c", Self.script, "sayso-cleanup", "\(pid)", bundleID, appPath ?? ""] + leftovers.map(\.path)
    }

    /// Lanza el guion suelto. La app tiene que cerrarse a continuación.
    public func launch() throws {
        try validate()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = arguments
        try process.run()
    }
}

/// Quitar a la app sus permisos de macOS y volver a abrirla para pedirlos de cero.
public enum PermissionReset {
    public static let script = """
    pid="$1"; bundle="$2"; app="$3"
    while kill -0 "$pid" 2>/dev/null; do sleep 0.3; done
    /usr/bin/tccutil reset All "$bundle" >/dev/null 2>&1
    /usr/bin/open "$app"
    """

    public static func arguments(pid: Int32, bundleID: String, appPath: String) -> [String] {
        ["-c", script, "sayso-reset", "\(pid)", bundleID, appPath]
    }

    public static func launch(pid: Int32 = ProcessInfo.processInfo.processIdentifier,
                              bundleID: String = AppPaths.bundleID, appPath: String) throws {
        guard appPath.hasSuffix(".app") else { throw CleanupError(message: "Ruta de la app no válida: \(appPath)") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = arguments(pid: pid, bundleID: bundleID, appPath: appPath)
        try process.run()
    }
}
