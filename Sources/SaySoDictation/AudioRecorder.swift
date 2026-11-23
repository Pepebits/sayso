import SaySoCore
import AVFoundation
import Foundation

public enum AudioRecorderError: Error, LocalizedError {
    case noInput
    case engine(String)

    public var errorDescription: String? {
        switch self {
        case .noInput: return tr("No hay ningún micrófono disponible.")
        case let .engine(message): return tr("No se pudo iniciar el micrófono: %@", "\(message)")
        }
    }
}

/// Grabadora; permite sustituir la real en pruebas.
public protocol AudioRecording: AnyObject {
    /// Nivel 0…1, en el hilo principal.
    var onLevel: ((Float) -> Void)? { get set }
    func start() throws
    /// Lo grabado hasta ahora, a 16 kHz mono, sin detener la grabación.
    func snapshot() -> [Float]
    /// Los últimos `seconds` segundos, a 16 kHz mono, sin copiar ni remuestrear el resto.
    func snapshot(lastSeconds seconds: Double) -> [Float]
    /// Segundos grabados hasta ahora.
    var recordedSeconds: Double { get }
    /// Detiene y devuelve las muestras a 16 kHz mono.
    func stop() -> [Float]
    func cancel()
}

public extension AudioRecording {
    func snapshot(lastSeconds seconds: Double) -> [Float] {
        Array(snapshot().suffix(Int(seconds * AudioMath.targetSampleRate)))
    }

    var recordedSeconds: Double { AudioMath.duration(of: snapshot().count) }
}

/// Captura con `AVAudioEngine`. Acumula a la frecuencia nativa y remuestrea a 16 kHz al parar.
public final class AudioRecorder: AudioRecording, @unchecked Sendable {
    public var onLevel: ((Float) -> Void)?

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var buffer: [Float] = []
    private var sourceRate: Double = AudioMath.targetSampleRate
    private var running = false

    public init() {}

    public func start() throws {
        guard !running else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw AudioRecorderError.noInput }
        lock.lock()
        buffer.removeAll(keepingCapacity: true)
        buffer.reserveCapacity(Int(format.sampleRate) * 30)
        sourceRate = format.sampleRate
        lock.unlock()

        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] pcm, _ in
            self?.append(pcm)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw AudioRecorderError.engine(error.localizedDescription)
        }
        running = true
    }

    public func stop() -> [Float] {
        halt()
        lock.lock()
        let raw = buffer
        let rate = sourceRate
        buffer = []
        lock.unlock()
        return AudioMath.resample(raw, from: rate)
    }

    public func snapshot() -> [Float] {
        lock.lock()
        let raw = buffer
        let rate = sourceRate
        lock.unlock()
        return AudioMath.resample(raw, from: rate)
    }

    public func snapshot(lastSeconds seconds: Double) -> [Float] {
        lock.lock()
        let rate = sourceRate
        let raw = Array(buffer.suffix(Int(seconds * rate)))
        lock.unlock()
        return AudioMath.resample(raw, from: rate)
    }

    public var recordedSeconds: Double {
        lock.lock()
        defer { lock.unlock() }
        return rate(buffer.count)
    }

    private func rate(_ count: Int) -> Double { sourceRate > 0 ? Double(count) / sourceRate : 0 }

    public func cancel() {
        halt()
        lock.lock()
        buffer = []
        lock.unlock()
    }

    private func halt() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
    }

    /// Hilo de audio: mezcla a mono, acumula y publica el nivel.
    private func append(_ pcm: AVAudioPCMBuffer) {
        guard let data = pcm.floatChannelData else { return }
        let frames = Int(pcm.frameLength)
        let channels = Int(pcm.format.channelCount)
        guard frames > 0 else { return }
        var mono: [Float]
        if pcm.format.isInterleaved {
            let ptr = data[0]
            mono = [Float](repeating: 0, count: frames)
            for f in 0..<frames {
                var sum: Float = 0
                for c in 0..<channels { sum += ptr[f * channels + c] }
                mono[f] = sum / Float(channels)
            }
        } else {
            let all = (0..<channels).map { Array(UnsafeBufferPointer(start: data[$0], count: frames)) }
            mono = AudioMath.downmix(all)
        }
        let level = AudioMath.level(mono)
        lock.lock()
        buffer.append(contentsOf: mono)
        lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.onLevel?(level) }
    }
}
