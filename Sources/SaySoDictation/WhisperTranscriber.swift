import Foundation
import SaySoCore
import WhisperKit

/// Estado del modelo de Whisper, para mostrarlo en la interfaz.
public enum WhisperModelStatus: Hashable, Sendable {
    /// `progress` 0…1 si se conoce.
    case downloading(progress: Double?)
    case loading
    case ready
    case failed(String)

    /// Texto breve en español.
    public var label: String {
        switch self {
        case let .downloading(progress):
            if let progress { return tr("Descargando modelo… %@ %%", "\(Int((progress * 100).rounded()))") }
            return tr("Descargando modelo…")
        case .loading: return tr("Cargando modelo…")
        case .ready: return "Listo"
        case let .failed(message): return tr("Error: %@", "\(message)")
        }
    }
}

/// Transcripción local con WhisperKit. El modelo se descarga y carga la primera vez que se usa.
public actor WhisperTranscriber: Transcriber {
    /// Pequeño, multilingüe y con buena calidad en español (~480 MB).
    public static let defaultModel = "openai_whisper-small"
    static let repo = "argmaxinc/whisperkit-coreml"

    public nonisolated let modelName: String
    private let downloadBase: URL?
    private let onStatus: @Sendable (WhisperModelStatus) -> Void
    private var kit: LoadedKit?
    private var loading: Task<LoadedKit, Error>?

    /// `downloadBase`: carpeta de modelos; por defecto `Application Support/SaySo/Models`.
    public init(modelName: String = WhisperTranscriber.defaultModel, downloadBase: URL? = nil,
                onStatus: @escaping @Sendable (WhisperModelStatus) -> Void = { _ in }) {
        self.modelName = modelName
        self.downloadBase = downloadBase
        self.onStatus = onStatus
    }

    /// Descarga y carga el modelo por adelantado. Los errores se notifican por `onStatus`.
    public func prewarm() async {
        _ = try? await loadedKit()
    }

    public func transcribe(samples: [Float], sampleRate: Double, language: String?,
                           vocabulary: [String]) async throws -> String {
        let kit = try await loadedKit().kit
        let audio = AudioMath.resample(samples, from: sampleRate)
        guard !audio.isEmpty else { return "" }
        let lang = Self.whisperLanguage(language)
        var options = DecodingOptions(
            task: .transcribe,
            language: lang,
            temperatureFallbackCount: 3,
            usePrefillPrompt: true,
            detectLanguage: lang == nil,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            chunkingStrategy: .vad
        )
        // El diccionario va como texto previo: Whisper tiende a escribir las palabras que ya ha «visto».
        let words = DictationVocabulary.clean(vocabulary)
        if !words.isEmpty, let tokenizer = kit.tokenizer {
            let prompt = tokenizer.encode(text: " " + words.joined(separator: ", ") + ".")
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
            // Whisper admite como mucho 224 fichas de contexto; con más se ignora el resto.
            options.promptTokens = Array(prompt.suffix(200))
        }
        let results = try await kit.transcribe(audioArray: audio, decodeOptions: options)
        return Self.clean(results.map(\.text).joined(separator: " "))
    }

    private func loadedKit() async throws -> LoadedKit {
        if let kit { return kit }
        if let loading { return try await loading.value }
        let task = Task { [modelName, downloadBase, onStatus] in
            try await Self.load(model: modelName, downloadBase: downloadBase, onStatus: onStatus)
        }
        loading = task
        do {
            let loaded = try await task.value
            kit = loaded
            loading = nil
            return loaded
        } catch {
            loading = nil
            onStatus(.failed(error.localizedDescription))
            throw error
        }
    }

    private static func load(model: String, downloadBase: URL?,
                             onStatus: @escaping @Sendable (WhisperModelStatus) -> Void) async throws -> LoadedKit {
        let base = try downloadBase ?? AppPaths.supportDirectory().appendingPathComponent("Models", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        var folder = base.appendingPathComponent("models/\(repo)/\(model)", isDirectory: true)
        if !isModelFolder(folder) {
            onStatus(.downloading(progress: nil))
            folder = try await WhisperKit.download(variant: model, downloadBase: base, from: repo) { progress in
                onStatus(.downloading(progress: progress.fractionCompleted))
            }
        }
        onStatus(.loading)
        let config = WhisperKitConfig(
            model: model,
            downloadBase: base,
            modelRepo: repo,
            modelFolder: folder.path,
            tokenizerFolder: base,
            verbose: false,
            logLevel: .none,
            load: true,
            download: false
        )
        let kit = try await WhisperKit(config)
        onStatus(.ready)
        return LoadedKit(kit: kit)
    }

    /// Comprueba si la carpeta ya contiene los modelos Core ML.
    static func isModelFolder(_ url: URL) -> Bool {
        let fm = FileManager.default
        return ["MelSpectrogram", "AudioEncoder", "TextDecoder"].allSatisfy { name in
            fm.fileExists(atPath: url.appendingPathComponent("\(name).mlmodelc").path)
                || fm.fileExists(atPath: url.appendingPathComponent("\(name).mlpackage").path)
        }
    }

    /// «es-ES» → «es». `nil` o vacío: detección automática.
    static func whisperLanguage(_ code: String?) -> String? {
        guard let code, !code.isEmpty else { return nil }
        let base = code.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? code
        return base.lowercased()
    }

    /// Quita marcas como «[BLANK_AUDIO]» o «(música)» y espacios sobrantes.
    static func clean(_ text: String) -> String {
        var result = text
        for pattern in [#"\[[^\]]*\]"#, #"\([^)]*\)"#, #"<\|[^|]*\|>"#] {
            result = result.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        result = result.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// WhisperKit no es `Sendable`; solo se usa desde el actor `WhisperTranscriber`.
final class LoadedKit: @unchecked Sendable {
    let kit: WhisperKit
    init(kit: WhisperKit) { self.kit = kit }
}
