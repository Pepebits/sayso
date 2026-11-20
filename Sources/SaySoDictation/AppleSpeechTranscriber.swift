import AVFoundation
import Foundation
import SaySoCore
import Speech

public enum AppleSpeechError: Error, LocalizedError {
    case notAuthorized
    case unavailable(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notAuthorized: return tr("Falta el permiso de Reconocimiento de voz.")
        case let .unavailable(locale): return tr("El reconocimiento de voz no está disponible para «%@».", "\(locale)")
        case let .failed(message): return tr("El reconocimiento de voz falló: %@", "\(message)")
        }
    }
}

/// Transcripción con `SFSpeechRecognizer`, en el dispositivo cuando se admite.
public final class AppleSpeechTranscriber: Transcriber {
    public init() {}

    public func transcribe(samples: [Float], sampleRate: Double, language: String?) async throws -> String {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else { throw AppleSpeechError.notAuthorized }
        let locale = language.map { Locale(identifier: $0) } ?? Locale.current
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw AppleSpeechError.unavailable(locale.identifier)
        }
        guard !samples.isEmpty, sampleRate > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                         channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { return "" }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        request.append(buffer)
        request.endAudio()

        let once = ResumeOnce()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                once.task = recognizer.recognitionTask(with: request) { result, error in
                    if let result, result.isFinal {
                        if once.claim() { continuation.resume(returning: result.bestTranscription.formattedString) }
                    } else if let error {
                        if once.claim() { continuation.resume(throwing: AppleSpeechError.failed(error.localizedDescription)) }
                    }
                }
            }
        } onCancel: {
            once.cancelTask()
        }
    }
}

/// Garantiza que una continuación se reanuda una sola vez.
final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private var _task: SFSpeechRecognitionTask?

    var task: SFSpeechRecognitionTask? {
        get { lock.lock(); defer { lock.unlock() }; return _task }
        set { lock.lock(); _task = newValue; lock.unlock() }
    }

    func cancelTask() { task?.cancel() }

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
