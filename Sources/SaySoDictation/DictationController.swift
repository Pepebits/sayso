import Foundation
import SaySoCore

/// Une atajo, grabación, transcripción, corrección e inserción.
@MainActor
public final class DictationController {
    /// Tiempos del flujo; configurables para las pruebas.
    struct Timing {
        var minimumDuration: TimeInterval = 0.3
        var correctionTimeout: TimeInterval = 4
        var failureDisplay: TimeInterval = 3
        var noticeDisplay: TimeInterval = 1.8
        var minimumReplyDisplay: TimeInterval = 6
        var partialInterval: TimeInterval = 0.9
        /// En conversación: nivel a partir del cual se entiende que el usuario está hablando.
        var speechLevel: Float = 0.35
        /// En conversación: silencio tras hablar que da la frase por terminada.
        var silenceToFinish: TimeInterval = 1.5
        /// En conversación: tiempo escuchando sin oír nada que da la charla por acabada.
        var idleToEnd: TimeInterval = 12
        /// En conversación sin voz: cuánto se deja leer la respuesta antes de volver a escuchar.
        var replyPause: TimeInterval = 0.4
        /// Tope de una petición de voz al agente.
        var agentTimeout: TimeInterval = 180
    }

    public private(set) var settings: DictationSettings
    public private(set) var phase: DictationPhase = .idle

    private var corrector: TextCorrector?
    /// Lo que se dice con la tecla del agente se entrega aquí y devuelve su respuesta.
    public var agentHandler: ((String) async throws -> String)?
    /// Hay agente con el que hablar (cuenta de IA y agente en marcha). Si no, esa tecla dicta.
    public var agentAvailable: () -> Bool = { true }
    /// Por qué no hay agente (detenido, en pausa…), para no culpar siempre a la cuenta de IA.
    public var agentUnavailableReason: () -> String? = { nil }
    /// Texto reconocido hasta el momento (en vivo mientras se habla y definitivo al terminar).
    public var onPartial: ((String) -> Void)?
    /// Un dictado terminó en texto: el texto final, los segundos de audio y si iba para el agente.
    public var onDictated: ((String, TimeInterval, Bool) -> Void)?
    /// Un dictado manual (con el botón de la app) terminó en texto que no iba para el agente.
    /// No se escribe en el cursor: quien lo recibe decide qué hacer con él.
    public var onManualText: ((String) -> Void)?
    /// La grabación en curso se empezó con el botón, no con la tecla.
    public private(set) var manualRecording = false
    /// Conversación con el agente: después de cada respuesta vuelve a escuchar sola, y cada frase
    /// termina cuando el usuario se calla.
    public private(set) var conversing = false
    /// La conversación empieza o acaba (por el botón, por silencio o por un fallo).
    public var onConversation: ((Bool) -> Void)?
    /// Un turno de la conversación: `true` si lo dijo el usuario, `false` si es la respuesta.
    public var onConversationTurn: ((Bool, String) -> Void)?
    /// Espera a que la respuesta se haya leído en voz alta (si se lee) antes de volver a escuchar,
    /// para que el micrófono no recoja la voz del propio agente.
    public var waitForReply: ((String) async -> Void)?
    /// El usuario canceló con Esc una petición al agente o su respuesta: hay que callar la voz.
    public var onAgentCancelled: (() -> Void)?
    /// Petición al agente en curso, para poder cancelarla.
    private var agentTask: Task<String, Error>?
    private var agentGeneration = 0
    private var heardSpeech = false
    private var lastLoud = Date()
    private var listenStart = Date()
    private var recordingForAgent = false
    private var partialTask: Task<Void, Never>?
    private var recordingGeneration = 0
    private var replyGeneration = 0
    private let onPhase: (DictationPhase) -> Void
    private let onTranscriberStatus: (String?) -> Void
    private let hotkey: HotkeySource
    private let recorder: AudioRecording
    private let makeTranscriber: (TranscriberEngine) -> Transcriber
    private let microphoneAuthorized: () -> Bool
    private let timing: Timing

    private var transcribers: [TranscriberEngine: Transcriber] = [:]
    private var monitoring = false
    private var recording = false
    private var handsFree = false
    private var busy = false
    /// Cambia en cada fallo para no pisar una fase posterior al volver a reposo.
    private var failureGeneration = 0

    public convenience init(settings: DictationSettings, corrector: TextCorrector?,
                            onPhase: @escaping (DictationPhase) -> Void,
                            onTranscriberStatus: @escaping (String?) -> Void) {
        let statusSink = StatusSink()
        let monitor = HotkeyMonitor(side: settings.monitoredSide)
        monitor.shortcut = settings.shortcut
        self.init(
            settings: settings, corrector: corrector,
            hotkey: monitor, recorder: AudioRecorder(),
            makeTranscriber: { engine in
                switch engine {
                case .whisper: return WhisperTranscriber(onStatus: { statusSink.send($0) })
                case .apple: return AppleSpeechTranscriber()
                }
            },
            microphoneAuthorized: { SystemPermissions.status(.microphone) },
            onPhase: onPhase, onTranscriberStatus: onTranscriberStatus
        )
        statusSink.set { [weak self] status in
            Task { @MainActor in self?.reportWhisper(status) }
        }
    }

    init(settings: DictationSettings, corrector: TextCorrector?,
         hotkey: HotkeySource, recorder: AudioRecording,
         makeTranscriber: @escaping (TranscriberEngine) -> Transcriber,
         microphoneAuthorized: @escaping () -> Bool = { true },
         timing: Timing = Timing(),
         onPhase: @escaping (DictationPhase) -> Void,
         onTranscriberStatus: @escaping (String?) -> Void) {
        self.settings = settings
        self.corrector = corrector
        self.hotkey = hotkey
        self.recorder = recorder
        self.makeTranscriber = makeTranscriber
        self.microphoneAuthorized = microphoneAuthorized
        self.timing = timing
        self.onPhase = onPhase
        self.onTranscriberStatus = onTranscriberStatus
        hotkey.side = settings.monitoredSide
        hotkey.shortcut = settings.shortcut
        hotkey.onAction = { [weak self] action in
            MainActor.assumeIsolated { self?.handle(action) }
        }
        hotkey.onEscape = { [weak self] in
            MainActor.assumeIsolated { self?.cancelAgent() }
        }
        recorder.onLevel = { [weak self] level in
            MainActor.assumeIsolated { self?.levelChanged(level) }
        }
    }

    // MARK: - API pública

    /// Empieza a vigilar ⌥ si el dictado está activado. Lanza si falta Monitorización de entrada.
    public func start() throws {
        monitoring = true
        if settings.enabled { try hotkey.start() }
    }

    public func stop() {
        monitoring = false
        hotkey.stop()
        cancelRecording()
    }

    public func update(settings new: DictationSettings) {
        let old = settings
        settings = new
        if old.monitoredSide != new.monitoredSide { hotkey.side = new.monitoredSide }
        if old.shortcut != new.shortcut { hotkey.shortcut = new.shortcut }
        guard monitoring, old.enabled != new.enabled else { return }
        if new.enabled {
            do { try hotkey.start() } catch { fail(error) }
        } else {
            hotkey.stop()
            cancelRecording()
        }
    }

    /// Deja de vigilar el atajo un rato (mientras el usuario graba uno nuevo) y lo retoma después.
    public func suspendHotkey(_ suspended: Bool) {
        guard monitoring, settings.enabled else { return }
        if suspended {
            hotkey.stop()
            cancelRecording()
        } else {
            do { try hotkey.start() } catch { fail(error) }
        }
    }

    /// Transcribe audio que no viene del micrófono (notas de voz de Telegram), con el motor y el
    /// idioma del dictado.
    public func transcribe(samples: [Float]) async throws -> String {
        let text = try await transcriber(for: settings.engine)
            .transcribe(samples: samples, sampleRate: AudioMath.targetSampleRate, language: settings.spokenLanguage,
                        vocabulary: settings.vocabulary)
        return DictationVocabulary.apply(text, vocabulary: settings.vocabulary, replacements: settings.replacements)
    }

    public func setCorrector(_ corrector: TextCorrector?) {
        self.corrector = corrector
    }

    /// Carga por adelantado el modelo de Whisper si es el motor elegido.
    public func prewarm() {
        guard let whisper = transcriber(for: settings.engine) as? WhisperTranscriber else { return }
        Task { await whisper.prewarm() }
    }

    /// Dictado manual, sin tecla: la primera llamada empieza a grabar y la siguiente termina y
    /// transcribe. Funciona aunque falte Supervisión de entrada; solo necesita el micrófono.
    public func toggleManual(forAgent: Bool) {
        if recording {
            if manualRecording { finishRecording() }
            return
        }
        beginRecording(handsFree: true, manualForAgent: forAgent)
    }

    /// Descarta el dictado manual en curso.
    public func cancelManual() {
        if manualRecording { cancelRecording() }
    }

    /// Empieza una conversación con el agente: escucha, responde y vuelve a escuchar hasta que
    /// se llame a `endConversation()` o pase un rato sin que el usuario diga nada.
    public func startConversation() {
        guard !conversing, !recording, !busy else { return }
        guard agentHandler != nil, agentAvailable() else {
            fail(message: noAgentMessage)
            return
        }
        setConversing(true)
        beginRecording(handsFree: true, manualForAgent: true)
        if !recording { setConversing(false) }
    }

    /// Termina la conversación. Lo que se estuviera grabando se descarta.
    public func endConversation() {
        guard conversing else { return }
        setConversing(false)
        if recording, manualRecording { cancelRecording() }
        if case .agentReply = phase { replyGeneration += 1; setPhase(.idle) }
    }

    private func setConversing(_ value: Bool) {
        guard conversing != value else { return }
        conversing = value
        onConversation?(value)
    }

    // MARK: - Flujo

    func handle(_ action: HotkeyStateMachine.Action) {
        // Mientras se graba con el botón, la tecla no interrumpe.
        if recording, manualRecording { return }
        switch action {
        case .startListening: beginRecording(handsFree: false)
        case .enterHandsFree: beginRecording(handsFree: true)
        case .stopAndTranscribe: finishRecording()
        case .cancel: cancelRecording()
        }
    }

    private func beginRecording(handsFree: Bool, manualForAgent: Bool? = nil) {
        guard !recording else { return }
        guard !busy else { return hotkey.resetGesture() }
        guard microphoneAuthorized() else {
            hotkey.resetGesture()
            fail(message: "Falta el permiso de Micrófono.")
            return
        }
        // Con el atajo se le habla al agente: sin agente no hay a quién.
        guard manualForAgent != nil || isAgentGesture else {
            hotkey.resetGesture()
            fail(message: noAgentMessage)
            return
        }
        do {
            try recorder.start()
        } catch {
            hotkey.resetGesture()
            fail(error)
            return
        }
        recording = true
        self.handsFree = handsFree
        manualRecording = manualForAgent != nil
        if let manualForAgent {
            recordingForAgent = manualForAgent && agentHandler != nil && agentAvailable()
        } else {
            recordingForAgent = isAgentGesture
        }
        replyGeneration += 1 // una respuesta en pantalla deja paso a lo nuevo
        recordingGeneration += 1
        heardSpeech = false
        listenStart = Date()
        lastLoud = listenStart
        onPartial?("")
        setPhase(listeningPhase(level: 0))
        startPartials()
    }

    private var noAgentMessage: String {
        agentUnavailableReason() ?? tr("No hay agente con el que hablar: añade una cuenta de IA en Modelo.")
    }

    /// Hay agente que escuche lo que se dice con el atajo.
    private var isAgentGesture: Bool { agentHandler != nil && agentAvailable() }

    /// Mientras se habla, se transcribe lo grabado hasta el momento cada poco para mostrarlo.
    private func startPartials() {
        partialTask?.cancel()
        let generation = recordingGeneration
        let transcriber = transcriber(for: settings.engine)
        let language = settings.spokenLanguage
        let interval = timing.partialInterval
        partialTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard let self, !Task.isCancelled, self.recording, self.recordingGeneration == generation else { return }
                let samples = self.recorder.snapshot()
                let seconds = AudioMath.duration(of: samples.count)
                // Muy poco audio no da nada útil; mucho, repetirlo entero cada vez sale caro.
                guard seconds >= 0.8, seconds <= 30 else { continue }
                guard let text = try? await transcriber.transcribe(samples: samples, sampleRate: AudioMath.targetSampleRate,
                                                                   language: language) else { continue }
                guard !Task.isCancelled, self.recording, self.recordingGeneration == generation else { return }
                let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !clean.isEmpty { self.onPartial?(clean) }
            }
        }
    }

    private func listeningPhase(level: Float) -> DictationPhase {
        recordingForAgent ? .agentListening(level: level, handsFree: handsFree)
            : .listening(level: level, handsFree: handsFree)
    }

    private func levelChanged(_ level: Float) {
        guard recording else { return }
        setPhase(listeningPhase(level: level))
        guard conversing, manualRecording else { return }
        // En conversación nadie pulsa «Detener»: la frase acaba cuando el usuario se calla.
        let now = Date()
        if level >= timing.speechLevel {
            heardSpeech = true
            lastLoud = now
        } else if heardSpeech, now.timeIntervalSince(lastLoud) >= timing.silenceToFinish {
            finishRecording()
        } else if !heardSpeech, now.timeIntervalSince(listenStart) >= timing.idleToEnd {
            endConversation()
        }
    }

    private func cancelRecording() {
        guard recording else { return }
        recording = false
        manualRecording = false
        partialTask?.cancel()
        onPartial?("")
        recorder.cancel()
        setPhase(.idle)
    }

    private func finishRecording() {
        guard recording else { return }
        recording = false
        let manual = manualRecording
        manualRecording = false
        partialTask?.cancel()
        let samples = recorder.stop()
        guard AudioMath.duration(of: samples.count) >= timing.minimumDuration else {
            setConversing(false)
            setPhase(.idle)
            return
        }
        busy = true
        setPhase(.transcribing)
        let transcriber = transcriber(for: settings.engine)
        let language = settings.spokenLanguage
        let vocabulary = settings.vocabulary
        let replacements = settings.replacements
        let forAgent = recordingForAgent
        // Lo que va al agente no se corrige: él ya entiende una frase dictada.
        let corrector = settings.aiCorrection && !forAgent ? corrector : nil
        let timeout = timing.correctionTimeout
        let seconds = AudioMath.duration(of: samples.count)
        Task { [weak self] in
            do {
                var text = try await transcriber.transcribe(samples: samples, sampleRate: AudioMath.targetSampleRate,
                                                            language: language, vocabulary: vocabulary)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                text = DictationVocabulary.apply(text, vocabulary: vocabulary, replacements: replacements)
                self?.onPartial?(text)
                if !text.isEmpty, let corrector {
                    self?.setPhase(.correcting)
                    let original = text
                    let corrected = await Self.withTimeout(timeout) { try await corrector.correct(original) }
                    if let corrected = corrected?.trimmingCharacters(in: .whitespacesAndNewlines), !corrected.isEmpty {
                        text = DictationVocabulary.apply(corrected, vocabulary: vocabulary, replacements: replacements)
                        self?.onPartial?(text)
                    }
                }
                if !text.isEmpty { self?.onDictated?(text, seconds, forAgent) }
                if forAgent {
                    await self?.askAgent(text)
                } else {
                    self?.deliver(text, manual: manual)
                }
            } catch {
                self?.busy = false
                self?.setConversing(false)
                self?.fail(error)
            }
        }
    }

    private func deliver(_ text: String, manual: Bool = false) {
        busy = false
        guard !text.isEmpty else {
            // Se grabó, pero no se reconoció nada: mejor decirlo que volver a reposo sin más.
            notice(tr("No te he oído"))
            return
        }
        // Solo llega aquí el «Dictar texto» de la app: el texto va al portapapeles, nunca al cursor.
        if manual { onManualText?(text) }
        setPhase(.idle)
    }

    /// Esc mientras el agente piensa o enseña su respuesta: se deja de esperar, se cierra la
    /// respuesta y calla la voz. El dictado queda libre al momento.
    public func cancelAgent() {
        switch phase {
        case .agentThinking:
            agentGeneration += 1
            agentTask?.cancel()
            agentTask = nil
            busy = false
        case .agentReply:
            replyGeneration += 1
        default:
            return
        }
        setConversing(false)
        setPhase(.idle)
        onAgentCancelled?()
    }

    /// Entrega la frase al agente y muestra su respuesta un rato proporcional a su longitud.
    private func askAgent(_ text: String) async {
        guard !text.isEmpty, let agentHandler else {
            busy = false
            setConversing(false)
            if text.isEmpty { notice(tr("No te he oído")) } else { setPhase(.idle) }
            return
        }
        if conversing { onConversationTurn?(true, text) }
        setPhase(.agentThinking(text))
        agentGeneration += 1
        let request = agentGeneration
        let limit = timing.agentTimeout
        // Con tope: una petición colgada no puede dejar el dictado bloqueado. Al cancelar la tarea
        // se cancela también la petición.
        let task = Task { try await Self.withDeadline(limit) { try await agentHandler(text) } }
        agentTask = task
        do {
            let result = try await task.value
            // Cancelada con Esc: ya se ha vuelto a reposo y lo que llegue se descarta.
            guard agentGeneration == request else { return }
            agentTask = nil
            let answer = result.trimmingCharacters(in: .whitespacesAndNewlines)
            busy = false
            guard !answer.isEmpty else {
                setConversing(false)
                return setPhase(.idle)
            }
            replyGeneration += 1
            let generation = replyGeneration
            setPhase(.agentReply(answer))
            if conversing {
                onConversationTurn?(false, answer)
                if let waitForReply {
                    await waitForReply(answer)
                } else {
                    try? await Task.sleep(nanoseconds: UInt64(timing.replyPause * 1_000_000_000))
                }
                // Sigue la charla: vuelve a escuchar, salvo que se haya terminado o empezado otra cosa.
                if conversing, replyGeneration == generation, !recording, !busy {
                    beginRecording(handsFree: true, manualForAgent: true)
                    if !recording { setConversing(false) }
                }
                return
            }
            let seconds = min(45, max(timing.minimumReplyDisplay, Double(answer.count) / 12))
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.replyGeneration == generation, case .agentReply = self.phase else { return }
                    self.setPhase(.idle)
                }
            }
        } catch {
            guard agentGeneration == request else { return }
            agentTask = nil
            busy = false
            setConversing(false)
            fail(error)
        }
    }

    // MARK: - Auxiliares

    private func transcriber(for engine: TranscriberEngine) -> Transcriber {
        if let existing = transcribers[engine] { return existing }
        let created = makeTranscriber(engine)
        transcribers[engine] = created
        return created
    }

    private func reportWhisper(_ status: WhisperModelStatus) {
        onTranscriberStatus(status == .ready ? nil : status.label)
    }

    private func setPhase(_ new: DictationPhase) {
        guard new != phase else { return }
        phase = new
        onPhase(new)
    }

    private func fail(_ error: Error) {
        fail(message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
    }

    /// Aviso que no es un error, como «No te he oído»: se quita solo, igual que un fallo, pero
    /// no se apunta como error.
    private func notice(_ message: String) {
        failureGeneration += 1
        let generation = failureGeneration
        setPhase(.notice(message))
        DispatchQueue.main.asyncAfter(deadline: .now() + timing.noticeDisplay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.failureGeneration == generation, case .notice = self.phase else { return }
                self.setPhase(.idle)
            }
        }
    }

    private func fail(message: String) {
        failureGeneration += 1
        let generation = failureGeneration
        setPhase(.failed(message))
        DispatchQueue.main.asyncAfter(deadline: .now() + timing.failureDisplay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.failureGeneration == generation, case .failed = self.phase else { return }
                self.setPhase(.idle)
            }
        }
    }

    /// Ejecuta `operation` con límite de tiempo; `nil` si falla o se pasa del límite.
    /// No espera a que la operación termine tras el límite.
    /// Como `withTimeout`, pero los errores llegan al llamante y cancelar al llamante cancela la
    /// operación.
    nonisolated static func withDeadline<T: Sendable>(_ seconds: TimeInterval,
                                                       _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                throw AgentTimeout()
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CancellationError() }
            return first
        }
    }

    nonisolated static func withTimeout<T: Sendable>(_ seconds: TimeInterval,
                                                      _ operation: @escaping @Sendable () async throws -> T) async -> T? {
        let once = ResumeOnce()
        let box = TaskBox()
        return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let work = Task {
                let value = try? await operation()
                if once.claim() { continuation.resume(returning: value) }
            }
            box.set(work)
            Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                if once.claim() {
                    box.cancel()
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}

/// Referencia a una tarea para cancelarla desde otra.
private final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    func set(_ task: Task<Void, Never>) {
        lock.lock(); self.task = task; lock.unlock()
    }

    func cancel() {
        lock.lock(); let task = self.task; lock.unlock()
        task?.cancel()
    }
}

/// Destino del estado de Whisper, fijado tras crear el controlador.
private final class StatusSink: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (WhisperModelStatus) -> Void)?

    func set(_ handler: @escaping @Sendable (WhisperModelStatus) -> Void) {
        lock.lock(); self.handler = handler; lock.unlock()
    }

    func send(_ status: WhisperModelStatus) {
        lock.lock(); let handler = self.handler; lock.unlock()
        handler?(status)
    }
}

/// La petición de voz al agente pasó de su tope.
struct AgentTimeout: Error, LocalizedError {
    var errorDescription: String? { tr("El agente ha tardado demasiado en responder. Vuelve a intentarlo.") }
}
