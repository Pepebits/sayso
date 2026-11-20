import Foundation

// Contratos del ordenador Linux del agente.

/// Estado de la máquina virtual.
public enum ComputerState: Hashable, Sendable {
    /// Aún no se ha descargado la imagen.
    case notInstalled
    /// Descargando o preparando el disco. `progress` entre 0 y 1 cuando se conoce.
    case preparing(String, progress: Double?)
    case starting
    case running
    case paused
    case stopped
    case failed(String)

    public var isRunning: Bool { self == .running }

    /// Hay una operación en curso que impide arrancar o borrar.
    public var isBusy: Bool {
        switch self {
        case .preparing, .starting: return true
        default: return false
        }
    }
}

/// Escritorio gráfico de la máquina (Xfce con navegador). Es opcional y se instala aparte.
public enum DesktopState: Hashable, Sendable {
    case notInstalled
    case installing
    case installed
    case failed(String)
}

public enum DesktopSetup {
    public static let settingKey = "desktopInstalled"

    /// Instala Xfce, LightDM con inicio de sesión automático del usuario del agente y Firefox.
    /// No lo deja encendido: el escritorio arranca al abrir su ventana y se para al cerrarla.
    /// Es idempotente: se puede repetir tras un fallo.
    public static let installScript = #"""
    set -e
    export DEBIAN_FRONTEND=noninteractive
    sudo -E apt-get -o Acquire::Retries=5 update -qq
    sudo -E apt-get -o Acquire::Retries=5 install -y -qq --no-install-recommends \
      xserver-xorg xfce4 xfce4-terminal lightdm lightdm-gtk-greeter dbus-x11 \
      adwaita-icon-theme fonts-dejavu-core fonts-noto-color-emoji firefox-esr scrot
    sudo apt-get clean
    sudo mkdir -p /etc/lightdm/lightdm.conf.d /etc/X11/xorg.conf.d
    printf '[Seat:*]\nautologin-user=agent\nautologin-user-timeout=0\nuser-session=xfce\n' \
      | sudo tee /etc/lightdm/lightdm.conf.d/50-sayso.conf >/dev/null
    printf 'Section "ServerFlags"\n  Option "BlankTime" "0"\n  Option "StandbyTime" "0"\n  Option "SuspendTime" "0"\n  Option "OffTime" "0"\nEndSection\n' \
      | sudo tee /etc/X11/xorg.conf.d/10-sayso.conf >/dev/null
    sudo systemctl set-default multi-user.target >/dev/null 2>&1
    sudo systemctl stop lightdm >/dev/null 2>&1 || true
    [ -x /usr/sbin/lightdm ] && [ -x /usr/bin/startxfce4 ] && echo desktop-ok
    """#

    /// Enciende la sesión gráfica y espera a que el servidor X responda.
    public static let startScript = #"""
    sudo systemctl start lightdm
    for i in $(seq 1 30); do [ -S /tmp/.X11-unix/X0 ] && break; sleep 1; done
    [ -S /tmp/.X11-unix/X0 ] && echo desktop-up
    """#

    public static let stopScript = "sudo systemctl stop lightdm"
}

/// Uso de recursos medido dentro de la VM.
public struct ComputerStats: Hashable, Sendable {
    public var cpuPercent: Double
    public var cpuCount: Int
    public var memoryUsed: UInt64
    public var memoryTotal: UInt64
    public var diskUsed: UInt64
    public var diskTotal: UInt64

    public init(cpuPercent: Double, cpuCount: Int, memoryUsed: UInt64, memoryTotal: UInt64,
                diskUsed: UInt64, diskTotal: UInt64) {
        self.cpuPercent = cpuPercent
        self.cpuCount = cpuCount
        self.memoryUsed = memoryUsed
        self.memoryTotal = memoryTotal
        self.diskUsed = diskUsed
        self.diskTotal = diskTotal
    }
}

/// Resultado de un comando ejecutado en la VM.
public struct CommandResult: Hashable, Sendable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool

    public init(exitCode: Int32, stdout: String, stderr: String, timedOut: Bool = false) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
    }
}

/// Una entrada de la consola del ordenador: un comando, de quién es y lo que ha devuelto.
public struct TerminalEntry: Identifiable, Hashable, Sendable {
    public enum Author: String, Sendable { case user, agent }

    public var id: UUID
    public var command: String
    public var author: Author
    /// Carpeta en la que se lanzó, tal como la enseña el indicador («~/sayso»).
    public var directory: String
    /// Salida recibida hasta el momento.
    public var output: String
    /// `nil` mientras se ejecuta.
    public var exitCode: Int32?
    public var error: String?

    public init(id: UUID = UUID(), command: String, author: Author = .user, directory: String = "~/sayso",
                output: String = "", exitCode: Int32? = nil, error: String? = nil) {
        self.id = id
        self.command = command
        self.author = author
        self.directory = directory
        self.output = output
        self.exitCode = exitCode
        self.error = error
    }

    public var isRunning: Bool { exitCode == nil && error == nil }
}

/// Texto de consola sin secuencias de control (colores, movimientos de cursor) ni retornos de carro.
public enum ConsoleText {
    public static func clean(_ text: String) -> String {
        // Secuencias CSI (colores, cursor) y OSC (título de ventana).
        var out = text.replacingOccurrences(of: #"\x1B\[[0-9;?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: #"\x1B\][^\x07]*\x07"#, with: "", options: .regularExpression)
        // Una barra de progreso que se reescribe con \r deja solo su último estado.
        if let last = out.split(separator: "\r", omittingEmptySubsequences: false).last { out = String(last) }
        return out
    }

    /// «/home/agent/sayso/x» → «~/sayso/x».
    public static func shortDirectory(_ path: String, home: String = "/home/agent") -> String {
        path == home ? "~" : (path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path)
    }
}

/// Lo que el agente puede hacer en su ordenador Linux. Las rutas relativas parten de `~/sayso`.
public protocol AgentComputer: Sendable {
    /// `env` añade variables de entorno solo a ese comando (p. ej. un secreto que necesita un CLI).
    func run(_ command: String, cwd: String?, timeout: TimeInterval, env: [String: String],
             origin: String?) async throws -> CommandResult
    /// Arranca un proceso que sigue vivo y devuelve su entrada y salida estándar (servidores MCP).
    func openProcess(_ command: String, env: [String: String], origin: String?) async throws -> ProcessStream
    func readFile(_ path: String, origin: String?) async throws -> String
    /// El archivo tal cual, sin interpretarlo como texto (imágenes, PDF…).
    func readData(_ path: String, origin: String?) async throws -> Data
    func writeFile(_ path: String, content: String, origin: String?) async throws
    /// Escribe bytes tal cual (imágenes, audios…).
    func writeData(_ path: String, data: Data, origin: String?) async throws
}

public extension AgentComputer {
    func run(_ command: String, cwd: String?, timeout: TimeInterval, origin: String?) async throws -> CommandResult {
        try await run(command, cwd: cwd, timeout: timeout, env: [:], origin: origin)
    }

    /// Por defecto, a partir del texto: basta para quien no maneja archivos binarios.
    func readData(_ path: String, origin: String?) async throws -> Data {
        Data(try await readFile(path, origin: origin).utf8)
    }

    func writeData(_ path: String, data: Data, origin: String?) async throws {
        try await writeFile(path, content: String(decoding: data, as: UTF8.self), origin: origin)
    }
}

/// Entrada y salida de un proceso en marcha. Las lecturas bloquean: úsalo fuera del hilo principal.
public protocol ProcessStream: Sendable {
    func write(_ data: Data) throws
    /// Siguiente línea de la salida, sin el salto final; `nil` si el proceso ha terminado.
    func readLine(timeout: TimeInterval) throws -> Data?
    func close()
}

/// Acciones dentro de la VM. Se permiten por defecto: es el ordenador del agente y está aislado
/// del Mac. Pasan por el motor de permisos para quedar en el registro y poder ponerse en «Nunca».
public enum ComputerAction {
    public static let run: ActionID = "vm.run"
    public static let readFile: ActionID = "vm.readFile"
    public static let writeFile: ActionID = "vm.writeFile"
    /// Pasar a un comando una clave guardada en Secretos. Pregunta por defecto: con la clave en la
    /// mano, un comando puede mandarla a cualquier sitio.
    public static let useSecrets: ActionID = "vm.useSecrets"

    public static let descriptors: [ActionDescriptor] = [
        .init(id: run, title: "Ejecutar comandos", detail: "Dentro de la máquina Linux.", defaultRule: .allow),
        .init(id: readFile, title: "Leer archivos", detail: "Solo archivos de la máquina Linux.", defaultRule: .allow),
        .init(id: writeFile, title: "Escribir archivos", detail: "Solo archivos de la máquina Linux.", defaultRule: .allow),
        .init(id: useSecrets, title: "Usar secretos en comandos",
              detail: "Pasar una clave guardada en Secretos a un comando de la máquina Linux. El agente no ve su valor.",
              defaultRule: .ask),
    ]
}
