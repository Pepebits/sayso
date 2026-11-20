import SaySoCore
@testable import SaySoUI
import XCTest

@MainActor
final class ModelLogTests: XCTestCase {
    func testStateChangesAreLoggedOnce() {
        let model = AppModel()
        var saved: [LogEntry] = []
        model.logSink = { saved.append($0) }

        model.telegramStatus = .connecting
        model.telegramStatus = .connected("@bot")
        model.telegramStatus = .connected("@bot")
        model.telegramStatus = .failed("sin red")
        model.computerState = .preparing("Descargando", progress: 0.4)
        model.computerState = .starting
        model.computerState = .running
        model.computerState = .stopped
        model.dictationPhase = .listening(level: 0.2, handsFree: false)
        model.dictationPhase = .agentThinking("texto dictado que no debe quedar")
        model.dictationPhase = .failed("No se oye nada")
        model.lastError = "No se pudo guardar"
        model.lastError = "No se pudo guardar"
        model.lastError = nil
        model.telegramUser = .ready("Nombre Apellido")

        // La primera vez que la tecla responde también se apunta, una sola vez por arranque.
        XCTAssertEqual(model.logEntries.map(\.level), [.info, .error, .info, .info, .info, .error, .error, .info])
        XCTAssertEqual(model.logEntries.map(\.category),
                       ["telegram", "telegram", "ordenador", "ordenador", "dictado", "dictado", "app", "telegram"])
        model.dictationPhase = .idle
        model.dictationPhase = .listening(level: 0.1, handsFree: false)
        XCTAssertEqual(model.logEntries.filter { $0.category == "dictado" }.count, 2)
        XCTAssertEqual(saved, model.logEntries)
        // Ni nombres de cuenta ni lo dictado acaban en el registro.
        let all = model.logEntries.map(\.message).joined(separator: " ")
        XCTAssertFalse(all.contains("@bot"))
        XCTAssertFalse(all.contains("Nombre Apellido"))
        XCTAssertFalse(all.contains("texto dictado"))
    }

    func testPluginFailuresAreLoggedWhenTheyAppear() throws {
        let model = AppModel()
        let config = try XCTUnwrap(PluginCatalog.all.first)
        model.plugins = [PluginRow(config: config, added: true, state: .connecting)]
        model.plugins = [PluginRow(config: config, added: true, state: .failed("Falta el secreto"))]
        model.plugins = [PluginRow(config: config, added: true, state: .failed("Falta el secreto"))]
        XCTAssertEqual(model.logEntries.map(\.message), ["\(config.name): Falta el secreto"])
    }

    func testLogKeepsOnlyTheMostRecentEntries() {
        let model = AppModel()
        for i in 0..<(AppModel.logLimit + 20) { model.log(.info, LogCategory.app, "\(i)") }
        XCTAssertEqual(model.logEntries.count, AppModel.logLimit)
        XCTAssertEqual(model.logEntries.first?.message, "20")
    }

    func testMissingDictationPermissionsDriveTheWarning() {
        let model = AppModel()
        // Antes de comprobar ningún permiso no se avisa de nada.
        XCTAssertEqual(model.missingDictationPermissions, [])
        model.systemPermissions = [.microphone: true, .accessibility: false, .inputMonitoring: false, .speechRecognition: false]
        XCTAssertEqual(model.missingDictationPermissions, [.inputMonitoring], "Accesibilidad ya no hace falta")
        XCTAssertEqual(model.sidebarBadge(for: .dictado), .text("!", spoken: "faltan permisos"))
        // Reconocimiento de voz solo lo usa el motor de Apple: no bloquea la tecla.
        model.systemPermissions = [.microphone: true, .accessibility: true, .inputMonitoring: true, .speechRecognition: false]
        XCTAssertEqual(model.missingDictationPermissions, [])
        XCTAssertEqual(model.sidebarBadge(for: .dictado), .text("⌥", spoken: "atajo Opción"))
        // Con el dictado apagado no hay nada que avisar.
        model.systemPermissions[.microphone] = false
        model.dictation.enabled = false
        XCTAssertEqual(model.missingDictationPermissions, [])
    }
}
