import SaySoCore
@testable import SaySoDictation
import XCTest

// MARK: - Dobles de prueba

final class FakeHotkey: HotkeySource {
    var onAction: ((HotkeyStateMachine.Action) -> Void)?
    var onEscape: (() -> Void)?
    var side: OptionKeySide = .any
    var shortcut: DictationShortcut = .option
    var activeSide: OptionKeyPhysicalSide? = .left
    var started = 0
    var stopped = 0
    var startError: Error?

    func start() throws {
        if let startError { throw startError }
        started += 1
    }

    func stop() { stopped += 1 }
    var resets = 0
    func resetGesture() { resets += 1 }
    func send(_ action: HotkeyStateMachine.Action) { onAction?(action) }
    func escape() { onEscape?() }
}

final class FakeRecorder: AudioRecording {
    var onLevel: ((Float) -> Void)?
    var samples: [Float] = []
    var startError: Error?
    var startCount = 0
    var cancelCount = 0

    func start() throws {
        if let startError { throw startError }
        startCount += 1
    }

    func snapshot() -> [Float] { samples }
    func stop() -> [Float] { samples }
    func cancel() { cancelCount += 1 }
}

/// Recoge lo que llega al agente por el atajo (antes, lo que se escribía en el cursor).
@MainActor
final class FakeInserter {
    var inserted: [String] = []
    var error: Error?

    func insert(_ text: String) throws {
        if let error { throw error }
        inserted.append(text)
    }
}

final class FakeTranscriber: Transcriber, @unchecked Sendable {
    let text: String
    let error: Error?
    private let lock = NSLock()
    private var _calls: [(count: Int, language: String?)] = []
    var calls: [(count: Int, language: String?)] { lock.withLock { _calls } }
    private var _vocabulary: [[String]] = []
    var vocabularies: [[String]] { lock.withLock { _vocabulary } }

    init(text: String, error: Error? = nil) {
        self.text = text
        self.error = error
    }

    func transcribe(samples: [Float], sampleRate: Double, language: String?, vocabulary: [String]) async throws -> String {
        lock.withLock { _calls.append((samples.count, language)); _vocabulary.append(vocabulary) }
        if let error { throw error }
        return text
    }
}

struct FakeCorrector: TextCorrector {
    var delay: TimeInterval = 0
    var fails = false

    func correct(_ text: String) async throws -> String {
        if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        if fails { throw URLError(.timedOut) }
        return text.uppercased()
    }
}

struct TestError: LocalizedError {
    var errorDescription: String? { "falló la prueba" }
}

// MARK: - Pruebas

@MainActor
final class DictationControllerTests: XCTestCase {
    var hotkey: FakeHotkey!
    var recorder: FakeRecorder!
    var inserter: FakeInserter!
    var phases: [DictationPhase] = []
    var engines: [TranscriberEngine] = []
    /// Referencia fuerte: el atajo solo guarda una débil.
    var current: DictationController?

    override func setUp() async throws {
        hotkey = FakeHotkey()
        recorder = FakeRecorder()
        recorder.samples = [Float](repeating: 0.1, count: 16_000) // 1 s
        inserter = FakeInserter()
        phases = []
        engines = []
        current = nil
    }

    private func makeController(settings: DictationSettings = DictationSettings(),
                                corrector: TextCorrector? = nil,
                                transcriber: Transcriber = FakeTranscriber(text: "hola mundo"),
                                micAuthorized: Bool = true,
                                correctionTimeout: TimeInterval = 4) -> DictationController {
        var timing = DictationController.Timing()
        timing.correctionTimeout = correctionTimeout
        timing.failureDisplay = 0.05
        let controller = DictationController(
            settings: settings, corrector: corrector,
            hotkey: hotkey, recorder: recorder,
            makeTranscriber: { [unowned self] engine in
                self.engines.append(engine)
                return transcriber
            },
            microphoneAuthorized: { micAuthorized },
            timing: timing,
            onPhase: { [unowned self] in self.phases.append($0) },
            onTranscriberStatus: { _ in }
        )
        // Lo dicho con el atajo va al agente; aquí lo recoge el falso «inserter».
        let sink = inserter!
        controller.agentHandler = { text in try sink.insert(text); return "" }
        current = controller
        return controller
    }

    /// Espera a que la última fase cumpla la condición.
    private func waitFor(_ timeout: TimeInterval = 2, _ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private var finishedIdle: Bool {
        phases.count > 1 && phases.last == .idle
    }

    // MARK: Hablar con el agente

    func testAgentKeySendsSpeechToTheAgentInsteadOfTyping() async throws {
        // Modo por defecto: cualquiera de las dos teclas habla con el agente.
        XCTAssertEqual(DictationSettings().voiceMode, .agent)
        let controller = makeController(corrector: FakeCorrector(), transcriber: FakeTranscriber(text: "manda un mensaje a Anna"))
        var heard: [String] = []
        var partials: [String] = []
        controller.agentHandler = { text in heard.append(text); return "¿Qué le digo a Anna?" }
        controller.onPartial = { partials.append($0) }
        try controller.start()

        hotkey.activeSide = .left
        hotkey.send(.startListening)
        XCTAssertEqual(phases.last, .agentListening(level: 0, handsFree: false))
        hotkey.send(.stopAndTranscribe)
        await waitFor { self.phases.last == .agentReply("¿Qué le digo a Anna?") }

        XCTAssertEqual(heard, ["manda un mensaje a Anna"])
        XCTAssertTrue(inserter.inserted.isEmpty, "lo que va al agente no se escribe en el cursor")
        XCTAssertTrue(phases.contains(.agentThinking("manda un mensaje a Anna")))
        XCTAssertFalse(phases.contains(.correcting), "lo que va al agente no se corrige")
        XCTAssertEqual(partials.last, "manda un mensaje a Anna")

        // Contestar a su pregunta: mismo gesto, la respuesta anterior deja paso.
        hotkey.send(.startListening)
        XCTAssertEqual(phases.last, .agentListening(level: 0, handsFree: false))
    }

    func testOldCursorModesNowTalkToTheAgent() async throws {
        // «Escribir en el cursor» y «una tecla para cada cosa» se quitaron: lo dicho va al agente.
        for mode in [VoiceMode.dictation, .split] {
            inserter.inserted = []
            let controller = makeController(settings: DictationSettings(side: .right, voiceMode: mode))
            XCTAssertEqual(hotkey.side, .right, "el lado elegido se respeta")
            try controller.start()
            hotkey.activeSide = .left
            hotkey.send(.startListening)
            XCTAssertEqual(phases.last, .agentListening(level: 0, handsFree: false))
            hotkey.send(.stopAndTranscribe)
            await waitFor { self.inserter.inserted == ["hola mundo"] }
            XCTAssertEqual(inserter.inserted, ["hola mundo"])
            controller.stop()
        }
    }

    func testWithoutAnAgentTheKeySaysSoInsteadOfRecording() async throws {
        let unavailable = makeController()
        unavailable.agentAvailable = { false }
        try unavailable.start()
        hotkey.send(.startListening)
        XCTAssertEqual(phases.last, .failed("No hay agente con el que hablar: añade una cuenta de IA en Modelo."))
        XCTAssertEqual(recorder.startCount, 0, "no se graba nada que no vaya a ninguna parte")
    }

    func testWithoutAnAgentTheKeySaysWhy() async throws {
        let stopped = makeController()
        stopped.agentAvailable = { false }
        stopped.agentUnavailableReason = { "El agente está detenido. Reanúdalo en Inicio." }
        try stopped.start()
        hotkey.send(.startListening)
        XCTAssertEqual(phases.last, .failed("El agente está detenido. Reanúdalo en Inicio."))
    }

    func testEscapeCancelsAWaitingAgentRequest() async throws {
        let controller = makeController()
        let finished = expectation(description: "la petición se cancela")
        controller.agentHandler = { _ in
            do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { finished.fulfill(); throw error }
            return "tarde"
        }
        var cancelled = 0
        controller.onAgentCancelled = { cancelled += 1 }
        try controller.start()
        hotkey.send(.startListening)
        hotkey.send(.stopAndTranscribe)
        await waitFor { if case .agentThinking = self.phases.last { return true }; return false }
        hotkey.escape()
        XCTAssertEqual(phases.last, .idle)
        XCTAssertEqual(cancelled, 1)
        await fulfillment(of: [finished], timeout: 2)
        // El dictado queda libre al momento.
        hotkey.send(.startListening)
        XCTAssertEqual(phases.last, .agentListening(level: 0, handsFree: false))
        hotkey.send(.cancel)
        // Esc sin nada en curso no hace nada.
        hotkey.escape()
        XCTAssertEqual(cancelled, 1)
    }

    func testEscapeClosesTheReply() async throws {
        let controller = makeController()
        controller.agentHandler = { _ in "Las cinco." }
        var cancelled = 0
        controller.onAgentCancelled = { cancelled += 1 }
        try controller.start()
        hotkey.send(.startListening)
        hotkey.send(.stopAndTranscribe)
        await waitFor { self.phases.last == .agentReply("Las cinco.") }
        hotkey.escape()
        XCTAssertEqual(phases.last, .idle)
        XCTAssertEqual(cancelled, 1, "calla la voz")
    }

    func testAgentRequestHasATimeLimit() async throws {
        var timing = DictationController.Timing()
        timing.agentTimeout = 0.1
        timing.failureDisplay = 0.05
        let controller = DictationController(
            settings: DictationSettings(), corrector: nil, hotkey: hotkey, recorder: recorder,
            makeTranscriber: { _ in FakeTranscriber(text: "hola") }, timing: timing,
            onPhase: { [unowned self] in self.phases.append($0) }, onTranscriberStatus: { _ in })
        controller.agentHandler = { _ in try await Task.sleep(nanoseconds: 10_000_000_000); return "tarde" }
        current = controller
        try controller.start()
        hotkey.send(.startListening)
        hotkey.send(.stopAndTranscribe)
        await waitFor { self.phases.contains { if case .failed = $0 { return true }; return false } }
        XCTAssertTrue(phases.contains(.failed(AgentTimeout().localizedDescription)))
    }

    func testLiveTranscriptWhileSpeaking() async throws {
        var timing = DictationController.Timing()
        timing.partialInterval = 0.02
        var partials: [String] = []
        let controller = DictationController(
            settings: DictationSettings(), corrector: nil,
            hotkey: hotkey, recorder: recorder,
            makeTranscriber: { _ in FakeTranscriber(text: "hola mundo") },
            timing: timing, onPhase: { [unowned self] in self.phases.append($0) }, onTranscriberStatus: { _ in })
        controller.agentHandler = { _ in "" }
        controller.onPartial = { partials.append($0) }
        current = controller
        try controller.start()
        hotkey.send(.startListening)
        XCTAssertEqual(partials, [""], "al empezar se limpia el texto anterior")
        await waitFor { partials.contains("hola mundo") }
        XCTAssertTrue(partials.contains("hola mundo"), "el texto aparece mientras aún se graba")
        XCTAssertEqual(phases.last, .agentListening(level: 0, handsFree: false))
        hotkey.send(.cancel)
        XCTAssertEqual(partials.last, "")
    }

    func testAgentErrorsAreShownAndRecovered() async throws {
        struct Boom: LocalizedError { var errorDescription: String? { "sin cuenta" } }
        let controller = makeController()
        controller.agentHandler = { _ in throw Boom() }
        try controller.start()
        hotkey.activeSide = .right
        hotkey.send(.startListening)
        hotkey.send(.stopAndTranscribe)
        await waitFor { self.phases.contains(.failed("sin cuenta")) && self.phases.last == .idle }
        XCTAssertTrue(phases.contains(.failed("sin cuenta")))
        XCTAssertEqual(phases.last, .idle)
    }

    func testSidesAndOldSettings() throws {
        // Por defecto las dos teclas hacen lo mismo: hablar con el agente.
        XCTAssertEqual(DictationSettings().target(leftKey: true), .agent)
        XCTAssertEqual(DictationSettings().target(leftKey: false), .agent)
        XCTAssertEqual(DictationSettings().monitoredSide, .any)
        // Los modos antiguos se leen, pero lo dicho siempre va al agente.
        let split = DictationSettings(voiceMode: .split)
        XCTAssertEqual(split.target(leftKey: true), .agent)
        XCTAssertEqual(DictationSettings(voiceMode: .dictation).target(leftKey: false), .agent)
        let off = Data(#"{"enabled":true,"side":"any","aiCorrection":false,"engine":"whisper","voiceAgent":false}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(DictationSettings.self, from: off).effectiveVoiceMode, .agent)
        let roundTrip = try JSONDecoder().decode(DictationSettings.self, from: JSONEncoder().encode(split))
        XCTAssertEqual(roundTrip, split)
        // Ajustes guardados antes de existir el modo agente.
        let old = Data(#"{"enabled":true,"side":"left","aiCorrection":true,"engine":"apple","language":"en-US"}"#.utf8)
        let decoded = try JSONDecoder().decode(DictationSettings.self, from: old)
        XCTAssertEqual(decoded.side, .left)
        XCTAssertEqual(decoded.engine, .apple)
        XCTAssertTrue(decoded.aiCorrection)
        XCTAssertEqual(decoded.voiceMode, .agent)
        XCTAssertTrue(decoded.speakReplies)
    }

    func testHoldFlowSendsTextToTheAgent() async throws {
        let transcriber = FakeTranscriber(text: "  hola mundo ")
        let controller = makeController(transcriber: transcriber)
        try controller.start()
        XCTAssertEqual(hotkey.started, 1)

        hotkey.send(.startListening)
        XCTAssertEqual(phases.last, .agentListening(level: 0, handsFree: false))
        recorder.onLevel?(0.7)
        XCTAssertEqual(phases.last, .agentListening(level: 0.7, handsFree: false))

        hotkey.send(.stopAndTranscribe)
        XCTAssertEqual(phases.last, .transcribing)
        await waitFor { self.finishedIdle }

        XCTAssertEqual(inserter.inserted, ["hola mundo"])
        XCTAssertEqual(phases, [.agentListening(level: 0, handsFree: false), .agentListening(level: 0.7, handsFree: false),
                                .transcribing, .agentThinking("hola mundo"), .idle])
        XCTAssertEqual(transcriber.calls.first?.count, 16_000)
        XCTAssertEqual(transcriber.calls.first?.language, "es-ES")
        XCTAssertEqual(engines, [.whisper])
    }

    func testManualDictationWorksWithoutTheKeyAndDoesNotTypeAnywhere() async throws {
        let controller = makeController(transcriber: FakeTranscriber(text: " hola manual "))
        var manual: [String] = []
        controller.onManualText = { manual.append($0) }

        controller.toggleManual(forAgent: false)
        XCTAssertTrue(controller.manualRecording)
        XCTAssertEqual(phases.last, .listening(level: 0, handsFree: true))
        // La tecla no corta lo que se graba con el botón.
        hotkey.send(.stopAndTranscribe)
        hotkey.send(.cancel)
        XCTAssertTrue(controller.manualRecording)

        controller.toggleManual(forAgent: false)
        XCTAssertEqual(phases.last, .transcribing)
        await waitFor { self.finishedIdle }
        XCTAssertEqual(manual, ["hola manual"])
        XCTAssertTrue(inserter.inserted.isEmpty, "el foco está en la propia app: no se pega nada")

        // Cancelar descarta la grabación.
        controller.toggleManual(forAgent: false)
        controller.cancelManual()
        XCTAssertEqual(phases.last, .idle)
        XCTAssertEqual(manual.count, 1)
    }

    func testConversationListensAnswersAndListensAgainUntilEnded() async throws {
        var timing = DictationController.Timing()
        timing.silenceToFinish = 0.05
        timing.replyPause = 0.01
        timing.failureDisplay = 0.05
        let controller = DictationController(
            settings: DictationSettings(), corrector: nil, hotkey: hotkey, recorder: recorder,
            makeTranscriber: { _ in FakeTranscriber(text: "qué hora es") }, microphoneAuthorized: { true },
            timing: timing, onPhase: { [unowned self] in self.phases.append($0) }, onTranscriberStatus: { _ in })
        var asked: [String] = []
        controller.agentHandler = { text in asked.append(text); return "Las cinco." }
        var turns: [String] = []
        controller.onConversationTurn = { fromUser, text in turns.append((fromUser ? "tú: " : "agente: ") + text) }
        var states: [Bool] = []
        controller.onConversation = { states.append($0) }
        recorder.samples = [Float](repeating: 0.1, count: 16_000)

        controller.startConversation()
        XCTAssertTrue(controller.conversing)
        XCTAssertEqual(phases.last, .agentListening(level: 0, handsFree: true))
        XCTAssertEqual(recorder.startCount, 1)

        // Habla y se calla: la frase termina sola, sin pulsar nada.
        recorder.onLevel?(0.8)
        try await Task.sleep(nanoseconds: 80_000_000)
        recorder.onLevel?(0.05)
        await waitFor { self.recorder.startCount == 2 }
        XCTAssertEqual(asked, ["qué hora es"])
        XCTAssertEqual(turns, ["tú: qué hora es", "agente: Las cinco."])
        XCTAssertTrue(controller.conversing, "tras responder vuelve a escuchar")
        XCTAssertTrue(phases.contains(.agentReply("Las cinco.")))
        XCTAssertTrue(inserter.inserted.isEmpty)

        // Segunda vuelta y fin con el botón.
        recorder.onLevel?(0.8)
        try await Task.sleep(nanoseconds: 80_000_000)
        recorder.onLevel?(0.05)
        await waitFor { self.recorder.startCount == 3 }
        XCTAssertEqual(asked.count, 2)
        controller.endConversation()
        XCTAssertFalse(controller.conversing)
        XCTAssertEqual(phases.last, .idle)
        XCTAssertEqual(states, [true, false])
    }

    func testConversationEndsByItselfWhenNobodySpeaks() async throws {
        var timing = DictationController.Timing()
        timing.idleToEnd = 0.05
        let controller = DictationController(
            settings: DictationSettings(), corrector: nil, hotkey: hotkey, recorder: recorder,
            makeTranscriber: { _ in FakeTranscriber(text: "x") }, microphoneAuthorized: { true },
            timing: timing, onPhase: { [unowned self] in self.phases.append($0) }, onTranscriberStatus: { _ in })
        controller.agentHandler = { _ in "ok" }
        controller.startConversation()
        try await Task.sleep(nanoseconds: 80_000_000)
        recorder.onLevel?(0.02)
        XCTAssertFalse(controller.conversing)
        XCTAssertEqual(phases.last, .idle)

        // Sin agente no hay conversación.
        controller.agentHandler = nil
        controller.startConversation()
        XCTAssertFalse(controller.conversing)
    }

    func testReportsEachDictationThatEndsInText() async throws {
        var reported: [(String, TimeInterval, Bool)] = []
        let controller = makeController(transcriber: FakeTranscriber(text: " hola mundo "))
        controller.onDictated = { reported.append(($0, $1, $2)) }
        try controller.start()
        hotkey.send(.startListening)
        hotkey.send(.stopAndTranscribe)
        await waitFor { self.finishedIdle }
        XCTAssertEqual(reported.map(\.0), ["hola mundo"])
        XCTAssertEqual(reported.first?.1 ?? 0, 1, accuracy: 0.01)
        XCTAssertEqual(reported.first?.2, true, "con el atajo, la frase es para el agente")
    }

    func testEmptyDictationIsNotReported() async throws {
        var reported = 0
        let controller = makeController(transcriber: FakeTranscriber(text: "   "))
        controller.onDictated = { _, _, _ in reported += 1 }
        try controller.start()
        hotkey.send(.startListening)
        hotkey.send(.stopAndTranscribe)
        await waitFor { self.finishedIdle }
        XCTAssertEqual(reported, 0)
    }

    func testHandsFreeFlow() async {
        let controller = makeController()
        hotkey.send(.enterHandsFree)
        XCTAssertEqual(controller.phase, .agentListening(level: 0, handsFree: true))
        hotkey.send(.stopAndTranscribe)
        await waitFor { self.finishedIdle }
        XCTAssertEqual(inserter.inserted, ["hola mundo"])
    }

    func testCancelDiscardsAudio() {
        let transcriber = FakeTranscriber(text: "x")
        let controller = makeController(transcriber: transcriber)
        hotkey.send(.startListening)
        hotkey.send(.cancel)
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(recorder.cancelCount, 1)
        hotkey.send(.stopAndTranscribe)
        XCTAssertTrue(transcriber.calls.isEmpty)
        XCTAssertTrue(inserter.inserted.isEmpty)
    }

    func testShortRecordingInsertsNothing() {
        recorder.samples = [Float](repeating: 0, count: 3_000) // < 0,3 s
        let transcriber = FakeTranscriber(text: "x")
        let controller = makeController(transcriber: transcriber)
        hotkey.send(.startListening)
        hotkey.send(.stopAndTranscribe)
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertFalse(phases.contains(.transcribing))
        XCTAssertTrue(transcriber.calls.isEmpty)
    }

    func testEmptyTextInsertsNothing() async {
        _ = makeController(transcriber: FakeTranscriber(text: "   "))
        hotkey.send(.startListening)
        hotkey.send(.stopAndTranscribe)
        await waitFor { self.finishedIdle }
        XCTAssertTrue(inserter.inserted.isEmpty)
        XCTAssertEqual(phases.last, .idle)
    }

    // «Corregir con IA» solo toca el «Dictar texto» de la app: lo que va al agente no se corrige.

    /// Dicta con el botón de la app; el texto final queda en `inserter.inserted`.
    private func dictateManually(_ controller: DictationController) {
        controller.onManualText = { [unowned self] in self.inserter.inserted.append($0) }
        controller.toggleManual(forAgent: false)
        controller.toggleManual(forAgent: false)
    }

    func testAICorrectionApplied() async {
        var settings = DictationSettings()
        settings.aiCorrection = true
        let controller = makeController(settings: settings, corrector: FakeCorrector())
        dictateManually(controller)
        await waitFor { self.finishedIdle }
        XCTAssertEqual(inserter.inserted, ["HOLA MUNDO"])

        // Lo que se le dice al agente llega tal cual.
        inserter.inserted = []
        hotkey.send(.startListening)
        hotkey.send(.stopAndTranscribe)
        await waitFor { self.inserter.inserted == ["hola mundo"] }
        XCTAssertEqual(inserter.inserted, ["hola mundo"])
    }

    func testCorrectorIgnoredWhenSettingOff() async {
        let controller = makeController(corrector: FakeCorrector())
        dictateManually(controller)
        await waitFor { self.finishedIdle }
        XCTAssertEqual(inserter.inserted, ["hola mundo"])
    }

    func testCorrectorFailureFallsBackToRawText() async {
        var settings = DictationSettings()
        settings.aiCorrection = true
        let controller = makeController(settings: settings, corrector: FakeCorrector(fails: true))
        dictateManually(controller)
        await waitFor { self.finishedIdle }
        XCTAssertEqual(inserter.inserted, ["hola mundo"])
    }

    func testSlowCorrectorTimesOut() async {
        var settings = DictationSettings()
        settings.aiCorrection = true
        let controller = makeController(settings: settings, corrector: FakeCorrector(delay: 5), correctionTimeout: 0.1)
        let start = Date()
        dictateManually(controller)
        await waitFor(3) { self.finishedIdle }
        XCTAssertEqual(inserter.inserted, ["hola mundo"])
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testSetCorrectorLater() async {
        var settings = DictationSettings()
        settings.aiCorrection = true
        let controller = makeController(settings: settings)
        controller.setCorrector(FakeCorrector())
        dictateManually(controller)
        await waitFor { self.finishedIdle }
        XCTAssertEqual(inserter.inserted, ["HOLA MUNDO"])
    }

    func testTranscriptionErrorFailsThenReturnsToIdle() async {
        _ = makeController(transcriber: FakeTranscriber(text: "", error: TestError()))
        hotkey.send(.startListening)
        hotkey.send(.stopAndTranscribe)
        await waitFor { self.phases.contains(.failed("falló la prueba")) && self.phases.last == .idle }
        XCTAssertEqual(phases.suffix(3), [.transcribing, .failed("falló la prueba"), .idle])
    }

    func testAgentErrorFails() async {
        struct Down: LocalizedError { var errorDescription: String? { "sin conexión" } }
        inserter.error = Down()
        _ = makeController()
        hotkey.send(.startListening)
        hotkey.send(.stopAndTranscribe)
        await waitFor { self.phases.contains(.failed("sin conexión")) }
        XCTAssertTrue(phases.contains(.failed("sin conexión")))
    }

    func testMissingMicrophoneFails() {
        let controller = makeController(micAuthorized: false)
        hotkey.send(.startListening)
        XCTAssertEqual(controller.phase, .failed("Falta el permiso de Micrófono."))
        XCTAssertEqual(recorder.startCount, 0)
        XCTAssertEqual(hotkey.resets, 1, "el atajo no se queda en manos libres")
    }

    func testRecorderErrorFails() {
        recorder.startError = AudioRecorderError.noInput
        let controller = makeController()
        hotkey.send(.enterHandsFree)
        XCTAssertEqual(controller.phase, .failed("No hay ningún micrófono disponible."))
        XCTAssertEqual(hotkey.resets, 1, "la siguiente pulsación vuelve a empezar")
    }

    func testIgnoresNewRecordingWhileTranscribing() async {
        _ = makeController()
        hotkey.send(.startListening)
        hotkey.send(.stopAndTranscribe)
        hotkey.send(.startListening)
        XCTAssertEqual(recorder.startCount, 1)
        await waitFor { self.finishedIdle }
    }

    func testEngineSelectionAndLanguage() async {
        var settings = DictationSettings()
        settings.engine = .apple
        settings.language = nil
        let transcriber = FakeTranscriber(text: "hola")
        _ = makeController(settings: settings, transcriber: transcriber)
        hotkey.send(.startListening)
        hotkey.send(.stopAndTranscribe)
        await waitFor { self.finishedIdle }
        XCTAssertEqual(engines, [.apple])
        XCTAssertEqual(transcriber.calls.count, 1)
        if let call = transcriber.calls.first { XCTAssertNil(call.language) }
    }

    func testUpdateSettings() throws {
        let controller = makeController()
        try controller.start()
        var settings = controller.settings
        settings.side = .right
        controller.update(settings: settings)
        XCTAssertEqual(hotkey.side, .right)
        settings.shortcut = DictationShortcut(kind: .modifier, keyCode: 63)
        controller.update(settings: settings)
        XCTAssertEqual(hotkey.side, .any, "con otro atajo el lado de ⌥ no cuenta")
        XCTAssertEqual(hotkey.shortcut.keyCode, 63)

        hotkey.send(.startListening)
        settings.enabled = false
        controller.update(settings: settings)
        XCTAssertEqual(hotkey.stopped, 1)
        XCTAssertEqual(recorder.cancelCount, 1)
        XCTAssertEqual(controller.phase, .idle)

        settings.enabled = true
        controller.update(settings: settings)
        XCTAssertEqual(hotkey.started, 2)
    }

    func testStartWhenDisabledDoesNotInstallMonitor() throws {
        var settings = DictationSettings()
        settings.enabled = false
        let controller = makeController(settings: settings)
        try controller.start()
        XCTAssertEqual(hotkey.started, 0)
        controller.stop()
        XCTAssertEqual(hotkey.stopped, 1)
    }

    func testStartPropagatesMonitorError() {
        hotkey.startError = HotkeyMonitorError.tapUnavailable
        let controller = makeController()
        XCTAssertThrowsError(try controller.start())
    }

    func testWithTimeout() async {
        let fast = await DictationController.withTimeout(1) { 42 }
        XCTAssertEqual(fast, 42)
        let slow = await DictationController.withTimeout(0.05) { () async throws -> Int in
            try await Task.sleep(nanoseconds: 2_000_000_000)
            return 1
        }
        XCTAssertNil(slow)
        let failing = await DictationController.withTimeout(1) { () async throws -> Int in throw TestError() }
        XCTAssertNil(failing)
    }
}
