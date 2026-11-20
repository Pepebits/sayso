import SaySoCore
@testable import SaySoUI
import XCTest

@MainActor
final class OnboardingTests: XCTestCase {
    func testNothingIsCompleteOnAFreshInstall() {
        let model = AppModel()
        for step in OnboardingStep.counted { XCTAssertFalse(step.isComplete(model), step.title) }
        XCTAssertTrue(OnboardingStep.welcome.isComplete(model))
    }

    func testPermissionsDependOnTheEngine() {
        let model = AppModel()
        XCTAssertEqual(OnboardingStep.neededPermissions(model), [.microphone, .inputMonitoring],
                       "sin escribir en el cursor no se pide Accesibilidad")
        for kind in [SystemPermissionKind.microphone, .inputMonitoring] { model.systemPermissions[kind] = true }
        XCTAssertTrue(OnboardingStep.permissions.isComplete(model))
        model.dictation.engine = .apple
        XCTAssertFalse(OnboardingStep.permissions.isComplete(model), "el motor de Apple pide un permiso más")
        model.systemPermissions[.speechRecognition] = true
        XCTAssertTrue(OnboardingStep.permissions.isComplete(model))
    }

    func testTelegramNeedsPairingNotJustAToken() {
        let model = AppModel()
        model.telegramStatus = .connected("@bot")
        model.pairingCode = "123456"
        XCTAssertFalse(OnboardingStep.telegram.isComplete(model))
        model.pairingCode = nil
        XCTAssertTrue(OnboardingStep.telegram.isComplete(model))
        model.telegramStatus = .connecting
        XCTAssertFalse(OnboardingStep.telegram.isComplete(model))
    }

    func testAccountAndComputer() {
        let model = AppModel()
        let account = ProviderAccount(name: "Claude", kind: .anthropic, baseURL: URL(string: "https://api.anthropic.com")!,
                                      fullModel: "m", fastModel: "f", keychainKey: nil)
        model.accounts = [account]
        model.activeAccountID = account.id
        XCTAssertTrue(OnboardingStep.account.isComplete(model))
        model.computerState = .preparing("Descargando", progress: 0.5)
        XCTAssertFalse(OnboardingStep.computer.isComplete(model))
        model.computerState = .stopped
        XCTAssertTrue(OnboardingStep.computer.isComplete(model))
    }

    func testStepsAreCountedWithoutWelcomeAndSummary() {
        XCTAssertEqual(OnboardingStep.counted.count, 4)
        XCTAssertFalse(OnboardingStep.counted.contains(.welcome))
        XCTAssertFalse(OnboardingStep.counted.contains(.done))
    }
}

extension OnboardingTests {
    /// La cuenta de usuario no sustituye al bot: el bot es el canal para hablar con el agente.
    func testAccountAloneDoesNotCompleteTheTelegramStep() {
        let model = AppModel()
        model.telegramUser = .ready("Daniel")
        XCTAssertFalse(OnboardingStep.telegram.isComplete(model))
        model.telegramStatus = .connected("@bot")
        XCTAssertTrue(OnboardingStep.telegram.isComplete(model))
    }
}

extension OnboardingTests {
    /// Con la cuenta conectada el estado no puede decir «sin conectar».
    func testTelegramSummaryReflectsBotAndAccount() {
        let model = AppModel()
        XCTAssertEqual(model.telegramSummary, "Sin conectar")
        model.telegramUser = .ready("Daniel")
        XCTAssertEqual(model.telegramSummary, "Cuenta conectada · falta el bot")
        model.telegramStatus = .connected("@mi_bot")
        XCTAssertEqual(model.telegramSummary, "@mi_bot y tu cuenta")
        model.telegramUser = .off
        XCTAssertEqual(model.telegramSummary, "@mi_bot")
    }
}

extension OnboardingTests {
    func testConnectedAccountCountsAsProgressInTheTelegramStep() {
        let model = AppModel()
        XCTAssertFalse(OnboardingStep.telegram.hasProgress(model))
        model.telegramUser = .ready("Daniel")
        XCTAssertTrue(OnboardingStep.telegram.hasProgress(model))
        XCTAssertFalse(OnboardingStep.telegram.isComplete(model), "el resumen sigue pidiendo el bot")
        XCTAssertFalse(OnboardingStep.account.hasProgress(model))
    }
}
