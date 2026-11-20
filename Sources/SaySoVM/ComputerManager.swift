import Foundation
import SaySoCore
import Virtualization

/// Ciclo de vida de la máquina Linux del agente (ADR-0004): instalar, arrancar, pausar, apagar
/// y hablar con el agente invitado por vsock.
///
/// Requiere el entitlement `com.apple.security.virtualization` en la app firmada.
@MainActor
public final class ComputerManager: NSObject, VZVirtualMachineDelegate {
    public let files: VMFiles
    public let config: VMConfig
    private let onState: (ComputerState) -> Void

    public private(set) var state: ComputerState {
        didSet { if state != oldValue { onState(state) } }
    }

    private var machine: VZVirtualMachine?
    private var startTask: Task<Void, Error>?
    private let activity = ActivityClock()
    private var requestsInFlight = 0

    /// Segundos desde la última orden del agente o del usuario; 0 mientras haya alguna en curso.
    /// Las lecturas de recursos de la pantalla no cuentan.
    public var idleTime: TimeInterval {
        requestsInFlight > 0 ? 0 : Date().timeIntervalSince(activity.last)
    }

    public init(directory: URL, config: VMConfig = VMConfig(), onState: @escaping (ComputerState) -> Void) {
        self.files = VMFiles(directory: directory)
        self.config = config
        self.onState = onState
        self.state = files.isInstalled ? .stopped : .notInstalled
        super.init()
    }

    public var isInstalled: Bool { files.isInstalled }

    /// La máquina en marcha, para mostrar su pantalla (`VZVirtualMachineView`).
    public var virtualMachine: VZVirtualMachine? { machine }

    // MARK: - Ciclo de vida

    /// Instala la imagen si falta, arranca y espera a que el agente invitado responda.
    /// Varias llamadas a la vez comparten el mismo arranque.
    public func start() async throws {
        if state == .running { return }
        if state == .paused { return try await resume() }
        if let startTask { return try await startTask.value }
        let task = Task { try await self.performStart() }
        startTask = task
        defer { startTask = nil }
        do {
            try await task.value
        } catch {
            await tearDown()
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    private func performStart() async throws {
        if !files.isInstalled {
            state = .preparing("Descargando Debian", progress: 0)
            let files = self.files
            let config = self.config
            try await Task.detached {
                try await files.install(config: config) { text, fraction in
                    Task { @MainActor [weak self] in
                        guard let self, self.state.isBusy else { return }
                        self.state = .preparing(text, progress: fraction)
                    }
                }
            }.value
        }
        state = .starting
        let files = self.files
        try await Task.detached { try files.writeSeed() }.value

        let machine = VZVirtualMachine(configuration: try makeConfiguration())
        machine.delegate = self
        self.machine = machine
        try await machine.start()
        try await waitForGuest()
        activity.touch()
        state = .running
    }

    /// El primer arranque incluye cloud-init: puede tardar un par de minutos.
    private func waitForGuest(timeout: TimeInterval = 240) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard let machine, machine.state == .running else { throw GuestError.notRunning }
            if let response = try? await send(.ping, receiveTimeout: 5), response.ok {
                // Responder no basta: cuando cloud-init aplica una configuración nueva reinicia el
                // agente invitado al final y cortaría la primera orden. Se espera a que termine;
                // si el reinicio corta esta misma espera, se vuelve a intentar.
                let wait = GuestRequest.exec("cloud-init status --wait >/dev/null 2>&1; echo listo", timeout: 200)
                if let done = try? await send(wait, receiveTimeout: 210), done.stdout?.contains("listo") == true {
                    return
                }
            }
            try await Task.sleep(nanoseconds: 1_500_000_000)
        }
        throw GuestError.bootTimeout
    }

    public func pause() async throws {
        guard let machine, state == .running else { return }
        try await machine.pause()
        state = .paused
    }

    public func resume() async throws {
        guard let machine, state == .paused else { return }
        try await machine.resume()
        state = .running
    }

    /// Apagado ordenado: se lo pide al invitado y, si no obedece a tiempo, corta.
    public func shutdown(grace: TimeInterval = 15) async {
        startTask?.cancel()
        guard let machine else {
            if !state.isBusy { state = files.isInstalled ? .stopped : .notInstalled }
            return
        }
        if state == .paused { try? await machine.resume() }
        if machine.state == .running {
            _ = try? await send(.poweroff, receiveTimeout: 5)
            let deadline = Date().addingTimeInterval(grace)
            while self.machine != nil, machine.state == .running, Date() < deadline {
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
        await tearDown()
        state = files.isInstalled ? .stopped : .notInstalled
    }

    private func tearDown() async {
        guard let machine else { return }
        self.machine = nil
        machine.delegate = nil
        if machine.canStop { try? await machine.stop() }
    }

    /// Apaga y borra el disco. No se puede deshacer.
    public func delete() async throws {
        await shutdown(grace: 5)
        try files.delete()
        state = .notInstalled
    }

    // MARK: - Agente invitado

    /// Envía una orden al agente invitado. Arranca la máquina si está instalada y parada.
    public func request(_ request: GuestRequest, receiveTimeout: TimeInterval = 150) async throws -> GuestResponse {
        if state != .running {
            guard files.isInstalled else { throw GuestError.notRunning }
            try await start()
        }
        requestsInFlight += 1
        activity.touch()
        defer {
            requestsInFlight -= 1
            activity.touch()
        }
        let response = try await send(request, receiveTimeout: receiveTimeout)
        guard response.ok else { throw GuestError.guest(response.error ?? "Error desconocido en la máquina Linux.") }
        return response
    }

    /// Arranca un proceso que sigue vivo en la máquina y devuelve su entrada y salida.
    public func openProcess(_ command: String, env: [String: String]) async throws -> ProcessStream {
        if state != .running {
            guard files.isInstalled else { throw GuestError.notRunning }
            try await start()
        }
        guard let machine, machine.state == .running,
              let device = machine.socketDevices.first as? VZVirtioSocketDevice else { throw GuestError.notRunning }
        let connection = ConnectionBox(try await device.connect(toPort: guestAgentPort))
        let activity = self.activity
        activity.touch()
        return try await Task.detached {
            let fd = connection.value.fileDescriptor
            var limit = timeval(tv_sec: 30, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
            do {
                let response = try GuestFraming.roundTrip(.spawn(command, env: env), fd: fd)
                guard response.ok else { throw GuestError.guest(response.error ?? "No se pudo arrancar el proceso.") }
            } catch {
                connection.value.close()
                throw error
            }
            return VMProcessStream(connection: connection, activity: activity)
        }.value
    }

    public func stats() async -> ComputerStats? {
        guard state == .running else { return nil }
        return (try? await send(.stats, receiveTimeout: 5))?.stats
    }

    private func send(_ request: GuestRequest, receiveTimeout: TimeInterval) async throws -> GuestResponse {
        guard let machine, machine.state == .running,
              let device = machine.socketDevices.first as? VZVirtioSocketDevice else { throw GuestError.notRunning }
        let connection = ConnectionBox(try await device.connect(toPort: guestAgentPort))
        return try await Task.detached {
            defer { connection.value.close() }
            let fd = connection.value.fileDescriptor
            var limit = timeval(tv_sec: Int(receiveTimeout), tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
            return try GuestFraming.roundTrip(request, fd: fd)
        }.value
    }

    // MARK: - Configuración

    private func makeConfiguration() throws -> VZVirtualMachineConfiguration {
        let fm = FileManager.default
        let configuration = VZVirtualMachineConfiguration()

        let platform = VZGenericPlatformConfiguration()
        if let data = try? Data(contentsOf: files.machineID),
           let identifier = VZGenericMachineIdentifier(dataRepresentation: data) {
            platform.machineIdentifier = identifier
        } else {
            try platform.machineIdentifier.dataRepresentation.write(to: files.machineID)
        }
        configuration.platform = platform

        let bootLoader = VZEFIBootLoader()
        bootLoader.variableStore = fm.fileExists(atPath: files.efiVariables.path)
            ? VZEFIVariableStore(url: files.efiVariables)
            : try VZEFIVariableStore(creatingVariableStoreAt: files.efiVariables)
        configuration.bootLoader = bootLoader

        let maxCPU = VZVirtualMachineConfiguration.maximumAllowedCPUCount
        let minCPU = VZVirtualMachineConfiguration.minimumAllowedCPUCount
        configuration.cpuCount = min(max(config.cpuCount, minCPU), maxCPU)
        let maxMemory = VZVirtualMachineConfiguration.maximumAllowedMemorySize
        let minMemory = VZVirtualMachineConfiguration.minimumAllowedMemorySize
        configuration.memorySize = min(max(config.memoryBytes, minMemory), maxMemory)

        let disk = try VZDiskImageStorageDeviceAttachment(url: files.disk, readOnly: false)
        let seed = try VZDiskImageStorageDeviceAttachment(url: files.seed, readOnly: true)
        configuration.storageDevices = [
            VZVirtioBlockDeviceConfiguration(attachment: disk),
            VZVirtioBlockDeviceConfiguration(attachment: seed),
        ]

        // Red por NAT. No hay carpetas compartidas con el Mac.
        let network = VZVirtioNetworkDeviceConfiguration()
        network.attachment = VZNATNetworkDeviceAttachment()
        // Dirección MAC fija entre arranques: la misma interfaz y la misma concesión DHCP.
        if let saved = try? String(contentsOf: files.macAddress, encoding: .utf8),
           let address = VZMACAddress(string: saved.trimmingCharacters(in: .whitespacesAndNewlines)) {
            network.macAddress = address
        } else {
            let address = VZMACAddress.randomLocallyAdministered()
            try address.string.write(to: files.macAddress, atomically: true, encoding: .utf8)
            network.macAddress = address
        }
        configuration.networkDevices = [network]

        configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        configuration.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
        configuration.socketDevices = [VZVirtioSocketDeviceConfiguration()]

        // Pantalla, teclado y ratón: sin escritorio instalado muestran la consola de texto.
        let graphics = VZVirtioGraphicsDeviceConfiguration()
        graphics.scanouts = [VZVirtioGraphicsScanoutConfiguration(widthInPixels: 1280, heightInPixels: 800)]
        configuration.graphicsDevices = [graphics]
        configuration.keyboards = [VZUSBKeyboardConfiguration()]
        configuration.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]

        // Consola a un archivo, para diagnosticar arranques fallidos.
        let console = VZVirtioConsoleDeviceSerialPortConfiguration()
        console.attachment = try VZFileSerialPortAttachment(url: files.consoleLog, append: false)
        configuration.serialPorts = [console]

        try configuration.validate()
        return configuration
    }

    // MARK: - VZVirtualMachineDelegate

    public nonisolated func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        Task { @MainActor in self.machineStopped(virtualMachine, error: nil) }
    }

    public nonisolated func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        Task { @MainActor in self.machineStopped(virtualMachine, error: error) }
    }

    private func machineStopped(_ stopped: VZVirtualMachine, error: Error?) {
        guard stopped === machine else { return }
        machine = nil
        if let error {
            state = .failed(error.localizedDescription)
        } else if !state.isBusy {
            state = .stopped
        }
    }
}

/// `VZVirtioSocketConnection` solo se usa desde una tarea a la vez.
final class ConnectionBox: @unchecked Sendable {
    let value: VZVirtioSocketConnection
    init(_ value: VZVirtioSocketConnection) { self.value = value }
}

/// Momento de la última actividad, compartido con los procesos abiertos.
final class ActivityClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date()
    var last: Date { lock.lock(); defer { lock.unlock() }; return date }
    func touch() { lock.lock(); date = Date(); lock.unlock() }
}

/// Entrada y salida de un proceso de la VM sobre una conexión vsock.
final class VMProcessStream: ProcessStream, @unchecked Sendable {
    private let connection: ConnectionBox
    private let lock = NSLock()
    private var buffer = Data()
    private var closed = false

    private let activity: ActivityClock

    init(connection: ConnectionBox, activity: ActivityClock) {
        self.connection = connection
        self.activity = activity
    }

    deinit { close() }

    func write(_ data: Data) throws {
        activity.touch()
        try GuestFraming.writeAll(data, to: connection.value.fileDescriptor)
    }

    func readLine(timeout: TimeInterval) throws -> Data? {
        let fd = connection.value.fileDescriptor
        var limit = timeval(tv_sec: max(1, Int(timeout)), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer = Data(buffer[buffer.index(after: newline)...])
                return Data(line)
            }
            guard buffer.count <= GuestFraming.maxFrame else { throw GuestError.frameTooLarge(buffer.count) }
            let chunk = try GuestFraming.readSome(from: fd)
            activity.touch()
            if chunk.isEmpty { return nil }
            buffer.append(chunk)
        }
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        connection.value.close()
    }
}

/// `AgentComputer` sobre la VM. Cada acción pasa por el motor de permisos, que la registra.
public final class VMComputer: AgentComputer, @unchecked Sendable {
    private let manager: ComputerManager
    private let broker: PermissionBrokering
    private let observerLock = NSLock()
    private var observer: (@Sendable (String, String?, CommandResult?, String?) -> Void)?

    public init(manager: ComputerManager, broker: PermissionBrokering) {
        self.manager = manager
        self.broker = broker
    }

    /// Avisa de cada comando terminado (comando, origen, resultado o error), para enseñarlo en la consola.
    public func onCommand(_ handler: @escaping @Sendable (String, String?, CommandResult?, String?) -> Void) {
        observerLock.lock()
        observer = handler
        observerLock.unlock()
    }

    private func notify(_ command: String, _ origin: String?, _ result: CommandResult?, _ error: String?) {
        observerLock.lock()
        let handler = observer
        observerLock.unlock()
        handler?(command, origin, result, error)
    }

    public func run(_ command: String, cwd: String?, timeout: TimeInterval, env: [String: String],
                    origin: String?) async throws -> CommandResult {
        let request = ActionRequest(action: ComputerAction.run, summary: "$ " + Self.short(command),
                                    parameters: ["Comando": command, "Directorio": cwd ?? "~/sayso"], origin: origin)
        let manager = self.manager
        do {
            let result = try await broker.run(request) {
                let response = try await manager.request(.exec(command, cwd: cwd, timeout: timeout, env: env),
                                                         receiveTimeout: timeout + 30)
                guard let result = response.commandResult else { throw GuestError.guest("Respuesta incompleta.") }
                return result
            }
            notify(command, origin, result, nil)
            return result
        } catch {
            notify(command, origin, nil, error.localizedDescription)
            throw error
        }
    }

    public func openProcess(_ command: String, env: [String: String], origin: String?) async throws -> ProcessStream {
        let request = ActionRequest(action: ComputerAction.run, summary: "Proceso: " + Self.short(command),
                                    parameters: ["Comando": command], origin: origin)
        let manager = self.manager
        return try await broker.run(request) { try await manager.openProcess(command, env: env) }
    }

    public func readFile(_ path: String, origin: String?) async throws -> String {
        let request = ActionRequest(action: ComputerAction.readFile, summary: "Leer \(path)",
                                    parameters: ["Archivo": path], origin: origin)
        let manager = self.manager
        return try await broker.run(request) {
            let response = try await manager.request(.read(path))
            guard let data = response.data.flatMap({ Data(base64Encoded: $0) }) else {
                throw GuestError.guest("Respuesta incompleta.")
            }
            return String(decoding: data, as: UTF8.self)
        }
    }

    public func readData(_ path: String, origin: String?) async throws -> Data {
        let request = ActionRequest(action: ComputerAction.readFile, summary: "Leer \(path)",
                                    parameters: ["Archivo": path], origin: origin)
        let manager = self.manager
        return try await broker.run(request) {
            let response = try await manager.request(.read(path))
            guard let data = response.data.flatMap({ Data(base64Encoded: $0) }) else {
                throw GuestError.guest("Respuesta incompleta.")
            }
            return data
        }
    }

    public func writeFile(_ path: String, content: String, origin: String?) async throws {
        let request = ActionRequest(action: ComputerAction.writeFile, summary: "Escribir \(path)",
                                    parameters: ["Archivo": path], origin: origin)
        let manager = self.manager
        try await broker.run(request) {
            _ = try await manager.request(.write(path, content: Data(content.utf8)))
        }
    }

    public func writeData(_ path: String, data: Data, origin: String?) async throws {
        let request = ActionRequest(action: ComputerAction.writeFile, summary: "Escribir \(path) (\(data.count / 1024) KB)",
                                    parameters: ["Archivo": path], origin: origin)
        let manager = self.manager
        try await broker.run(request) {
            _ = try await manager.request(.write(path, content: data))
        }
    }

    private static func short(_ command: String) -> String {
        let line = command.replacingOccurrences(of: "\n", with: " ⏎ ")
        return line.count > 300 ? String(line.prefix(300)) + "…" : line
    }
}
