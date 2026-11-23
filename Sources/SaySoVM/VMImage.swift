import SaySoCore
import CryptoKit
import Foundation

/// Recursos de la máquina. Valores por defecto.
public struct VMConfig: Hashable, Sendable {
    public var cpuCount: Int
    public var memoryBytes: UInt64
    public var diskBytes: UInt64

    public init(cpuCount: Int = 2, memoryBytes: UInt64 = 4 << 30, diskBytes: UInt64 = 16 << 30) {
        self.cpuCount = cpuCount
        self.memoryBytes = memoryBytes
        self.diskBytes = diskBytes
    }
}

/// Imagen base: una compilación concreta de Debian, fijada por su hash.
public struct VMBaseImage: Hashable, Sendable {
    public var url: URL
    public var sha512: String
    /// Tamaño de la descarga, para el progreso cuando el servidor no lo indica.
    public var size: Int64

    /// Debian 13 «generic» para arm64, compilación 20261116-2664 (imagen oficial de cloud.debian.org).
    public static let debian13 = VMBaseImage(
        url: URL(string: "https://cloud.debian.org/images/cloud/trixie/20261116-2664/debian-13-generic-arm64-20261116-2664.tar.xz")!,
        sha512: "2f47555037f3b1e977e6a8f04d7bc21ae92da53b94d6a0529760fba628c0ab0b2c48f6e3f1aa3e8f01c6f054ff1c62b0ac219b39149b08a166b280db4b183f25",
        size: 300_020_608)
}

public enum VMImageError: Error, LocalizedError, Equatable {
    case download(String)
    /// Descarga parada a petición del usuario; lo bajado se conserva para seguir después.
    case cancelled
    case hashMismatch
    case tool(String, Int32, String)
    case missingDisk

    public var errorDescription: String? {
        switch self {
        case let .download(reason): return tr("No se pudo descargar la imagen de Linux: %@", "\(reason)")
        case .cancelled: return tr("Descarga cancelada. Al volver a instalar, sigue donde se quedó.")
        case .hashMismatch: return tr("La imagen descargada no coincide con el hash esperado y se ha descartado.")
        case let .tool(name, code, output): return tr("%@ falló (%@): %@", "\(name)", "\(code)", "\(output)")
        case .missingDisk: return tr("El archivo descargado no contenía un disco.")
        }
    }
}

/// Archivos de la VM en disco y su preparación (descarga, verificación, disco y semilla de cloud-init).
public struct VMFiles: Sendable {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    public var disk: URL { directory.appendingPathComponent("disk.raw") }
    public var seed: URL { directory.appendingPathComponent("seed.iso") }
    public var efiVariables: URL { directory.appendingPathComponent("efi-vars") }
    public var machineID: URL { directory.appendingPathComponent("machine-id") }
    public var macAddress: URL { directory.appendingPathComponent("mac-address") }
    public var consoleLog: URL { directory.appendingPathComponent("console.log") }

    public var isInstalled: Bool { FileManager.default.fileExists(atPath: disk.path) }
    /// Lo necesario para seguir una descarga cortada (`URLSession` la reanuda desde ahí).
    var resumeData: URL { directory.appendingPathComponent("download.resume") }
    /// Hay una descarga a medias que se puede seguir.
    public var hasPartialDownload: Bool { FileManager.default.fileExists(atPath: resumeData.path) }

    /// Descarga y prepara el disco si falta. `progress` recibe un texto y una fracción opcional.
    public func install(image: VMBaseImage = .debian13, config: VMConfig,
                        progress: @escaping @Sendable (String, Double?) -> Void) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        guard !isInstalled else { return }

        let archive = directory.appendingPathComponent("base.tar.xz")
        defer { try? fm.removeItem(at: archive) }
        try? fm.removeItem(at: archive)

        progress("Descargando Debian", 0)
        let resume = try? Data(contentsOf: resumeData)
        do {
            try await Downloader.download(image.url, resumeData: resume, to: archive, expectedSize: image.size) { fraction in
                progress("Descargando Debian", fraction)
            }
            try? fm.removeItem(at: resumeData)
        } catch let failure as DownloadFailure {
            // Se guarda lo bajado: la próxima vez sigue donde se quedó en vez de empezar de cero.
            if let data = failure.resumeData { try? data.write(to: resumeData) } else { try? fm.removeItem(at: resumeData) }
            throw failure.error
        }

        progress("Verificando la descarga", nil)
        guard try Self.sha512(of: archive) == image.sha512 else { throw VMImageError.hashMismatch }

        progress("Preparando el disco", nil)
        let staging = directory.appendingPathComponent("staging", isDirectory: true)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        try Self.runTool("/usr/bin/tar", ["-xJf", archive.path, "-C", staging.path])
        let extracted = staging.appendingPathComponent("disk.raw")
        guard fm.fileExists(atPath: extracted.path) else { throw VMImageError.missingDisk }

        // Disco disperso: se amplía el archivo y cloud-init extiende la partición en el primer arranque.
        let handle = try FileHandle(forWritingTo: extracted)
        let current = try handle.seekToEnd()
        if current < config.diskBytes { try handle.truncate(atOffset: config.diskBytes) }
        try handle.close()

        try fm.moveItem(at: extracted, to: disk)
    }

    /// Tamaño del archivo del disco (el máximo de la máquina, no lo que ocupa).
    public var diskSize: UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: disk.path)[.size] as? NSNumber)?.uint64Value
    }

    /// Agranda el disco hasta `bytes` si es más pequeño. Devuelve si ha crecido. Nunca lo reduce.
    public func growDisk(to bytes: UInt64) throws -> Bool {
        guard let current = diskSize, current < bytes else { return false }
        let handle = try FileHandle(forWritingTo: disk)
        defer { try? handle.close() }
        try handle.truncate(atOffset: bytes)
        return true
    }

    /// Regenera la semilla de cloud-init con la versión actual del agente invitado.
    public func writeSeed() throws {
        let fm = FileManager.default
        let source = directory.appendingPathComponent("seed-src", isDirectory: true)
        try? fm.removeItem(at: source)
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: source) }
        try Data(GuestAgent.userData.utf8).write(to: source.appendingPathComponent("user-data"))
        try Data(GuestAgent.metaData.utf8).write(to: source.appendingPathComponent("meta-data"))
        try Data(GuestAgent.networkConfig.utf8).write(to: source.appendingPathComponent("network-config"))
        try? fm.removeItem(at: seed)
        try Self.runTool("/usr/bin/hdiutil", ["makehybrid", "-quiet", "-o", seed.path, source.path,
                                              "-iso", "-joliet", "-default-volume-name", "cidata"])
    }

    /// Borra la máquina entera: disco, semilla y estado de arranque.
    public func delete() throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    // MARK: Utilidades

    static func sha512(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA512()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func runTool(_ path: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let text = String(decoding: output.suffix(600), as: UTF8.self)
            throw VMImageError.tool(URL(fileURLWithPath: path).lastPathComponent, process.terminationStatus,
                                    text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

/// Una descarga fallida o cancelada, con lo necesario para reanudarla.
struct DownloadFailure: Error {
    let error: VMImageError
    let resumeData: Data?
}

extension VMImageError {
    /// Un error de red en palabras claras, en vez del texto técnico de `URLError`.
    static func download(_ error: URLError) -> VMImageError {
        switch error.code {
        case .cancelled: return .cancelled
        case .notConnectedToInternet: return .download(tr("no hay conexión a internet. Al volver a instalar, sigue donde se quedó."))
        case .networkConnectionLost, .timedOut:
            return .download(tr("se cortó la conexión. Al volver a instalar, sigue donde se quedó."))
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return .download(tr("no se puede llegar a debian.org. Revisa la conexión o inténtalo más tarde."))
        default: return .download(error.localizedDescription)
        }
    }
}

/// Descarga a disco con progreso; se puede reanudar y cancelar guardando lo bajado.
private final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let expectedSize: Int64
    private let onProgress: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var moveError: Error?
    private var lastReported = -1

    private init(destination: URL, expectedSize: Int64, onProgress: @escaping @Sendable (Double) -> Void) {
        self.destination = destination
        self.expectedSize = expectedSize
        self.onProgress = onProgress
    }

    static func download(_ url: URL, resumeData: Data?, to destination: URL, expectedSize: Int64,
                         onProgress: @escaping @Sendable (Double) -> Void) async throws {
        let delegate = Downloader(destination: destination, expectedSize: expectedSize, onProgress: onProgress)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = resumeData.map { session.downloadTask(withResumeData: $0) } ?? session.downloadTask(with: url)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                delegate.continuation = continuation
                task.resume()
            }
        } onCancel: {
            // Cancelar guarda lo bajado: llega a `didCompleteWithError` con los datos para reanudar.
            task.cancel(byProducingResumeData: { _ in })
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expectedSize
        guard total > 0 else { return }
        let percent = Int(Double(totalBytesWritten) / Double(total) * 100)
        guard percent != lastReported else { return }
        lastReported = percent
        onProgress(min(Double(percent) / 100, 1))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            moveError = VMImageError.download(tr("el servidor respondió %@", "\(http.statusCode)"))
            return
        }
        do { try FileManager.default.moveItem(at: location, to: destination) } catch { moveError = error }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let continuation = self.continuation
        self.continuation = nil
        if let error {
            let urlError = error as? URLError
            let resume = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
            let reason = urlError.map(VMImageError.download) ?? .download(error.localizedDescription)
            continuation?.resume(throwing: DownloadFailure(error: reason, resumeData: resume))
        } else if let moveError {
            continuation?.resume(throwing: moveError)
        } else {
            continuation?.resume()
        }
    }
}
