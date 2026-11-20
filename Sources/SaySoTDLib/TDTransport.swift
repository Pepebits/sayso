import Foundation
import SaySoAgent
import TDLibFramework

/// Canal de mensajes JSON con TDLib. Los tests usan uno falso.
public protocol TDTransport: Sendable {
    func send(_ request: JSONValue)
    /// Flujo de todo lo que llega: respuestas (con `@extra`) y actualizaciones.
    var incoming: AsyncStream<JSONValue> { get }
    func close()
}

/// Transporte real sobre la interfaz JSON de TDLib (`td_json_client`).
public final class TDLibTransport: TDTransport, @unchecked Sendable {
    private let clientID: Int32
    public let incoming: AsyncStream<JSONValue>
    private let continuation: AsyncStream<JSONValue>.Continuation

    public init() {
        Self.configureLoggingOnce()
        clientID = td_create_client_id()
        var captured: AsyncStream<JSONValue>.Continuation!
        incoming = AsyncStream(bufferingPolicy: .unbounded) { captured = $0 }
        continuation = captured
        Receiver.shared.register(clientID, continuation)
    }

    public func send(_ request: JSONValue) {
        guard let data = try? request.encoded(), let text = String(data: data, encoding: .utf8) else { return }
        Receiver.shared.markActive(clientID)
        td_send(clientID, text)
    }

    public func close() {
        Receiver.shared.unregister(clientID)
        continuation.finish()
    }

    /// Versión de la librería enlazada, leída sin red.
    public static var libraryVersion: String? {
        configureLoggingOnce()
        guard let raw = td_execute(#"{"@type":"getOption","name":"version"}"#) else { return nil }
        return (try? JSONValue.parse(String(cString: raw)))?["value"]?.stringValue
    }

    private static let logging: Void = {
        // TDLib escribe en stderr por defecto; solo errores graves.
        _ = td_execute(#"{"@type":"setLogVerbosityLevel","new_verbosity_level":0}"#)
    }()

    private static func configureLoggingOnce() { _ = logging }

    /// Para el hilo que escucha a TDLib y espera a que salga. Se llama al cerrar la app: si el
    /// proceso termina con ese hilo dentro de `td_receive`, TDLib falla al destruirse y macOS
    /// apunta un cierre inesperado.
    public static func stopReceiving(timeout: TimeInterval = 1.3) {
        Receiver.shared.stop(timeout: timeout)
    }

    /// `td_receive` es único para todo el proceso: un solo hilo reparte por cliente.
    private final class Receiver: @unchecked Sendable {
        static let shared = Receiver()
        private let lock = NSLock()
        private var clients: [Int32: AsyncStream<JSONValue>.Continuation] = [:]
        private var running = false
        private var stopping = false
        /// Clientes que ya han enviado algo: TDLib solo crea de verdad un cliente con su primera petición.
        private var active: Set<Int32> = []
        private var finished = DispatchSemaphore(value: 0)

        func register(_ id: Int32, _ continuation: AsyncStream<JSONValue>.Continuation) {
            lock.lock()
            clients[id] = continuation
            let start = !running
            running = true
            if start {
                stopping = false
                finished = DispatchSemaphore(value: 0)
            }
            lock.unlock()
            if start {
                let thread = Thread { [weak self] in self?.loop() }
                thread.name = "sayso.tdlib.receive"
                thread.start()
            }
        }

        func unregister(_ id: Int32) {
            lock.lock()
            clients[id] = nil
            lock.unlock()
        }

        func markActive(_ id: Int32) {
            lock.lock()
            active.insert(id)
            lock.unlock()
        }

        func stop(timeout: TimeInterval) {
            lock.lock()
            guard running else { lock.unlock(); return }
            stopping = true
            let done = finished
            // Solo se despierta a través de un cliente que ya exista en TDLib: enviarle algo a uno
            // sin estrenar lo crearía, y un cliente creado y sin cerrar hace abortar a TDLib al salir.
            let anyClient = clients.keys.first { active.contains($0) }
            lock.unlock()
            // El hilo está esperando dentro de `td_receive`: una consulta local cualquiera le hace
            // volver al momento, sin tener que agotar su espera.
            if let anyClient { td_send(anyClient, #"{"@type":"getOption","name":"version"}"#) }
            _ = done.wait(timeout: .now() + timeout)
        }

        /// Sale del bucle si se ha pedido parar; deja todo listo para volver a arrancar.
        private func shouldExit() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard stopping else { return false }
            running = false
            finished.signal()
            return true
        }

        private func loop() {
            while !shouldExit() {
                // Espera larga: mientras no llega nada, el hilo despierta una vez por segundo.
                guard let raw = td_receive(1.0) else { continue }
                guard let message = try? JSONValue.parse(String(cString: raw)),
                      let id = message["@client_id"]?.intValue else { continue }
                lock.lock()
                let target = clients[Int32(id)]
                lock.unlock()
                target?.yield(message)
            }
        }
    }
}
