import CoreGraphics
import SaySoCore
@testable import SaySoDictation
import XCTest

final class HotkeyStateMachineTests: XCTestCase {
    private func machine(_ side: OptionKeySide = .any) -> HotkeyStateMachine {
        HotkeyStateMachine(side: side, holdThreshold: 0.2, doubleTapWindow: 0.4)
    }

    func testHoldStartsAndReleaseTranscribes() {
        var m = machine()
        XCTAssertNil(m.handle(.optionDown(.left, at: 0)))
        XCTAssertEqual(m.nextDeadline, 0.2)
        XCTAssertNil(m.handle(.tick(at: 0.1)))
        XCTAssertEqual(m.handle(.tick(at: 0.2)), .startListening)
        XCTAssertTrue(m.isListening)
        XCTAssertNil(m.nextDeadline)
        XCTAssertEqual(m.handle(.optionUp(.left, at: 1.5)), .stopAndTranscribe)
        XCTAssertEqual(m.state, .idle)
    }

    func testShortTapDoesNothing() {
        var m = machine()
        m.handle(.optionDown(.left, at: 0))
        XCTAssertNil(m.handle(.optionUp(.left, at: 0.1)))
        XCTAssertEqual(m.state, .idle)
        XCTAssertNil(m.handle(.tick(at: 1)))
    }

    func testOnlyConfiguredSideCounts() {
        var left = machine(.left)
        XCTAssertNil(left.handle(.optionDown(.right, at: 0)))
        XCTAssertNil(left.handle(.tick(at: 1)))
        XCTAssertEqual(left.state, .idle)
        left.handle(.optionUp(.right, at: 1.1))
        left.handle(.optionDown(.left, at: 2))
        XCTAssertEqual(left.handle(.tick(at: 2.3)), .startListening)

        var right = machine(.right)
        right.handle(.optionDown(.left, at: 0))
        XCTAssertNil(right.handle(.tick(at: 1)))
        right.handle(.optionUp(.left, at: 1.1))
        right.handle(.optionDown(.right, at: 2))
        XCTAssertEqual(right.handle(.tick(at: 2.25)), .startListening)
        XCTAssertNil(right.handle(.optionUp(.left, at: 2.5)), "Soltar la otra ⌥ no termina")
        XCTAssertEqual(right.handle(.optionUp(.right, at: 3)), .stopAndTranscribe)
    }

    func testAnySideAcceptsBoth() {
        var m = machine(.any)
        m.handle(.optionDown(.right, at: 0))
        XCTAssertEqual(m.handle(.tick(at: 0.2)), .startListening)
        XCTAssertEqual(m.handle(.optionUp(.right, at: 1)), .stopAndTranscribe)
    }

    func testOtherOptionWhileHoldingCancelsWhenSideIsSpecific() {
        var m = machine(.left)
        m.handle(.optionDown(.left, at: 0))
        m.handle(.tick(at: 0.3))
        XCTAssertEqual(m.handle(.optionDown(.right, at: 0.5)), .cancel)
    }

    func testOtherKeyBeforeThresholdCancelsSilently() {
        var m = machine()
        m.handle(.optionDown(.left, at: 0))
        XCTAssertNil(m.handle(.otherKey(at: 0.05)), "⌥+ñ no debe producir nada")
        XCTAssertNil(m.nextDeadline)
        XCTAssertNil(m.handle(.tick(at: 0.5)), "Ya no empieza a escuchar aunque siga pulsada")
        XCTAssertNil(m.handle(.optionUp(.left, at: 0.6)))
        XCTAssertEqual(m.state, .idle)
    }

    func testOptionWithModifierAlreadyHeldDoesNotStart() {
        var m = machine()
        XCTAssertNil(m.handle(.optionDown(.left, at: 0, alone: false)))
        XCTAssertNil(m.handle(.tick(at: 1)))
        XCTAssertNil(m.handle(.optionUp(.left, at: 1.2)))
        XCTAssertEqual(m.state, .idle)
    }

    func testOtherKeyWhileListeningCancels() {
        var m = machine()
        m.handle(.optionDown(.left, at: 0))
        XCTAssertEqual(m.handle(.tick(at: 0.25)), .startListening)
        XCTAssertEqual(m.handle(.otherKey(at: 0.8)), .cancel)
        XCTAssertNil(m.handle(.optionUp(.left, at: 1)), "Soltar tras cancelar no transcribe")
        XCTAssertEqual(m.state, .idle)
    }

    func testEscapeWhileHoldingCancels() {
        var m = machine()
        m.handle(.optionDown(.left, at: 0))
        m.handle(.tick(at: 0.2))
        XCTAssertEqual(m.handle(.escape(at: 0.5)), .cancel)
        XCTAssertNil(m.handle(.optionUp(.left, at: 0.7)))
    }

    func testDoubleTapEntersHandsFreeAndNextPressEnds() {
        var m = machine()
        m.handle(.optionDown(.left, at: 0))
        XCTAssertNil(m.handle(.optionUp(.left, at: 0.1)))
        XCTAssertNil(m.handle(.optionDown(.left, at: 0.3)))
        XCTAssertEqual(m.handle(.optionUp(.left, at: 0.4)), .enterHandsFree)
        XCTAssertEqual(m.state, .handsFree)
        XCTAssertTrue(m.isListening)
        XCTAssertNil(m.handle(.tick(at: 5)))
        XCTAssertNil(m.handle(.otherKey(at: 6)), "Con ⌥ suelta, otras teclas no cancelan")
        XCTAssertEqual(m.handle(.optionDown(.right, at: 10)), .stopAndTranscribe)
        XCTAssertNil(m.handle(.optionUp(.right, at: 10.1)), "Esa pulsación no cuenta como toque")
        XCTAssertEqual(m.state, .idle)
        // Un toque justo después no activa manos libres por sí solo.
        m.handle(.optionDown(.left, at: 10.3))
        XCTAssertNil(m.handle(.optionUp(.left, at: 10.4)))
        XCTAssertEqual(m.state, .idle)
    }

    func testEscapeCancelsHandsFree() {
        var m = machine()
        m.handle(.optionDown(.left, at: 0)); m.handle(.optionUp(.left, at: 0.1))
        m.handle(.optionDown(.left, at: 0.2)); m.handle(.optionUp(.left, at: 0.3))
        XCTAssertEqual(m.state, .handsFree)
        XCTAssertEqual(m.handle(.escape(at: 2)), .cancel)
        XCTAssertEqual(m.state, .idle)
    }

    func testTapsTooFarApartDoNotEnterHandsFree() {
        var m = machine()
        m.handle(.optionDown(.left, at: 0)); m.handle(.optionUp(.left, at: 0.1))
        m.handle(.optionDown(.left, at: 0.6))
        XCTAssertNil(m.handle(.optionUp(.left, at: 0.7)))
        XCTAssertEqual(m.state, .idle)
    }

    func testTapExpiredByTickDoesNotEnterHandsFree() {
        var m = machine()
        m.handle(.optionDown(.left, at: 0)); m.handle(.optionUp(.left, at: 0.1))
        m.handle(.tick(at: 0.6))
        m.handle(.optionDown(.left, at: 0.6))
        XCTAssertNil(m.handle(.optionUp(.left, at: 0.65)))
    }

    func testSecondPressHeldIsNormalHold() {
        var m = machine()
        m.handle(.optionDown(.left, at: 0)); m.handle(.optionUp(.left, at: 0.1))
        m.handle(.optionDown(.left, at: 0.3))
        XCTAssertEqual(m.handle(.tick(at: 0.5)), .startListening)
        XCTAssertEqual(m.handle(.optionUp(.left, at: 1)), .stopAndTranscribe)
    }

    func testLongFirstPressDoesNotCountAsTap() {
        var m = machine()
        m.handle(.optionDown(.left, at: 0))
        m.handle(.tick(at: 0.2))
        m.handle(.optionUp(.left, at: 0.5))
        m.handle(.optionDown(.left, at: 0.6))
        XCTAssertNil(m.handle(.optionUp(.left, at: 0.7)))
        XCTAssertEqual(m.state, .idle)
    }

    func testOtherKeyBetweenTapsBreaksDoubleTap() {
        var m = machine()
        m.handle(.optionDown(.left, at: 0)); m.handle(.optionUp(.left, at: 0.1))
        m.handle(.otherKey(at: 0.15))
        m.handle(.optionDown(.left, at: 0.2))
        XCTAssertNil(m.handle(.optionUp(.left, at: 0.3)))
        XCTAssertEqual(m.state, .idle)
    }

    func testReleaseAfterThresholdWithoutTickDoesNothing() {
        var m = machine()
        m.handle(.optionDown(.left, at: 0))
        XCTAssertNil(m.handle(.optionUp(.left, at: 0.5)))
        XCTAssertEqual(m.state, .idle)
    }

    func testRepeatedOptionDownIsIgnored() {
        var m = machine()
        m.handle(.optionDown(.left, at: 0))
        XCTAssertNil(m.handle(.optionDown(.left, at: 0.1)))
        XCTAssertEqual(m.handle(.tick(at: 0.2)), .startListening, "El umbral cuenta desde la primera")
    }

    func testCustomThresholds() {
        var m = HotkeyStateMachine(side: .any, holdThreshold: 0.5, doubleTapWindow: 1)
        m.handle(.optionDown(.left, at: 0))
        XCTAssertNil(m.handle(.tick(at: 0.3)))
        XCTAssertNil(m.handle(.optionUp(.left, at: 0.4)))
        m.handle(.optionDown(.left, at: 1.2))
        XCTAssertEqual(m.handle(.optionUp(.left, at: 1.6)), .enterHandsFree)
    }

    // MARK: - Traducción de eventos del monitor

    func testMonitorEventTranslation() {
        let leftDown = HotkeyMonitor.input(type: .flagsChanged, keyCode: 58,
                                           flags: CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x20),
                                           isRepeat: false, at: 1)
        XCTAssertEqual(leftDown, .optionDown(.left, at: 1, alone: true))
        let rightUp = HotkeyMonitor.input(type: .flagsChanged, keyCode: 61, flags: [], isRepeat: false, at: 2)
        XCTAssertEqual(rightUp, .optionUp(.right, at: 2))
        let withCommand = HotkeyMonitor.input(type: .flagsChanged, keyCode: 61,
                                              flags: CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x40
                                                  | CGEventFlags.maskCommand.rawValue),
                                              isRepeat: false, at: 3)
        XCTAssertEqual(withCommand, .optionDown(.right, at: 3, alone: false))
        XCTAssertEqual(HotkeyMonitor.input(type: .keyDown, keyCode: 53, flags: [], isRepeat: false, at: 4), .escape(at: 4))
        XCTAssertEqual(HotkeyMonitor.input(type: .keyDown, keyCode: 41, flags: [], isRepeat: false, at: 5), .otherKey(at: 5))
        XCTAssertNil(HotkeyMonitor.input(type: .keyDown, keyCode: 41, flags: [], isRepeat: true, at: 5))
        XCTAssertEqual(HotkeyMonitor.input(type: .flagsChanged, keyCode: 56, flags: .maskShift, isRepeat: false, at: 6),
                       .otherKey(at: 6))
        XCTAssertNil(HotkeyMonitor.input(type: .flagsChanged, keyCode: 56, flags: [], isRepeat: false, at: 7))
    }

    func testActiveSideFollowsTheKeyThatStartedTheGesture() {
        var machine = HotkeyStateMachine(side: .any)
        XCTAssertNil(machine.activeSide)
        machine.handle(.optionDown(.right, at: 0))
        XCTAssertEqual(machine.activeSide, .right)
        XCTAssertEqual(machine.handle(.tick(at: 0.25)), .startListening)
        machine.handle(.optionDown(.left, at: 0.3)) // la otra tecla a mitad no cambia el gesto
        XCTAssertEqual(machine.activeSide, .right)
        XCTAssertEqual(machine.handle(.optionUp(.right, at: 1)), .stopAndTranscribe)
        machine.handle(.optionDown(.left, at: 2))
        XCTAssertEqual(machine.activeSide, .left)
    }

    func testHandsFreeNeedsBothTapsOnTheSameKey() {
        var machine = HotkeyStateMachine(side: .any)
        machine.handle(.optionDown(.left, at: 0))
        XCTAssertNil(machine.handle(.optionUp(.left, at: 0.05)))
        machine.handle(.optionDown(.right, at: 0.2))
        XCTAssertNil(machine.handle(.optionUp(.right, at: 0.25)), "izquierda y luego derecha no es doble pulsación")
        machine.handle(.optionDown(.right, at: 0.4))
        XCTAssertEqual(machine.handle(.optionUp(.right, at: 0.45)), .enterHandsFree)
    }

    // MARK: Atajo configurable

    func testCapturingAShortcut() {
        var capture = ShortcutCapture()
        // Una modificadora pulsada y soltada sola.
        XCTAssertNil(capture.flagsChanged(keyCode: 54, flags: 0x100000 | 0x10))
        XCTAssertEqual(capture.flagsChanged(keyCode: 54, flags: 0),
                       .done(DictationShortcut(kind: .modifier, keyCode: 54)))
        // fn, y la ⌥ vuelve a ser el atajo de siempre.
        XCTAssertNil(capture.flagsChanged(keyCode: 63, flags: 0x800000))
        XCTAssertEqual(capture.flagsChanged(keyCode: 63, flags: 0), .done(DictationShortcut(kind: .modifier, keyCode: 63)))
        XCTAssertNil(capture.flagsChanged(keyCode: 61, flags: 0x80000 | 0x40))
        XCTAssertEqual(capture.flagsChanged(keyCode: 61, flags: 0), .done(.option))
        // Dos modificadoras a la vez no son una tecla sola: se espera a la tecla.
        XCTAssertNil(capture.flagsChanged(keyCode: 59, flags: 0x40000 | 0x01))
        XCTAssertNil(capture.flagsChanged(keyCode: 58, flags: 0x40000 | 0x01 | 0x80000 | 0x20))
        let combo = capture.keyDown(keyCode: 49, flags: 0x40000 | 0x80000, characters: " ")
        XCTAssertEqual(combo, .done(DictationShortcut(kind: .combo, keyCode: 49, modifiers: [.control, .option],
                                                      keyLabel: "Espacio")))
        if case let .done(shortcut) = combo {
            XCTAssertEqual(shortcut.keys, ["⌃", "⌥", "Espacio"])
            XCTAssertEqual(shortcut.symbol, "⌃⌥ Espacio")
        }
        // Una tecla de función sola vale; una letra sola, o solo con ⇧, no.
        XCTAssertEqual(capture.keyDown(keyCode: 96, flags: 0, characters: nil),
                       .done(DictationShortcut(kind: .combo, keyCode: 96, keyLabel: "F5")))
        XCTAssertNotNil(rejection(capture.keyDown(keyCode: 40, flags: 0, characters: "k")))
        XCTAssertNotNil(rejection(capture.keyDown(keyCode: 40, flags: 0x20000, characters: "k")))
        // Las que ya usa macOS o SaySo, tampoco.
        XCTAssertTrue(rejection(capture.keyDown(keyCode: 9, flags: 0x100000, characters: "v"))?.contains("pega") ?? false)
        XCTAssertEqual(capture.keyDown(keyCode: 40, flags: 0x100000 | 0x80000, characters: "k"),
                       .done(DictationShortcut(kind: .combo, keyCode: 40, modifiers: [.option, .command], keyLabel: "K")))
        XCTAssertEqual(capture.keyDown(keyCode: 53, flags: 0, characters: nil), .cancelled)
    }

    private func rejection(_ result: ShortcutCapture.Result) -> String? {
        if case let .rejected(reason) = result { return reason }
        return nil
    }

    func testAModifierShortcutBehavesLikeTheOptionKey() {
        let rightCommand = DictationShortcut(kind: .modifier, keyCode: 54)
        func input(_ type: CGEventType, _ key: Int64, _ flags: UInt64, at t: TimeInterval) -> HotkeyStateMachine.Input? {
            HotkeyMonitor.input(type: type, keyCode: key, flags: CGEventFlags(rawValue: flags), isRepeat: false,
                                shortcut: rightCommand, at: t)
        }
        XCTAssertEqual(input(.flagsChanged, 54, 0x100000 | 0x10, at: 1), .optionDown(.left, at: 1, alone: true))
        XCTAssertEqual(input(.flagsChanged, 54, 0, at: 2), .optionUp(.left, at: 2))
        // Con ⇧ ya pulsada no está sola; la ⌥ es ahora una tecla más.
        XCTAssertEqual(input(.flagsChanged, 54, 0x100000 | 0x10 | 0x20000, at: 3), .optionDown(.left, at: 3, alone: false))
        XCTAssertEqual(input(.flagsChanged, 58, 0x80000 | 0x20, at: 4), .otherKey(at: 4))
        // El ⌘ izquierdo no es el atajo.
        XCTAssertEqual(input(.flagsChanged, 55, 0x100000 | 0x08, at: 5), .otherKey(at: 5))

        var machine = HotkeyStateMachine()
        XCTAssertNil(machine.handle(input(.flagsChanged, 54, 0x100000 | 0x10, at: 10)!))
        XCTAssertEqual(machine.handle(.tick(at: 10.3)), .startListening)
        XCTAssertEqual(machine.handle(input(.flagsChanged, 54, 0, at: 11)!), .stopAndTranscribe)
    }

    func testAComboShortcutIsHeldWithItsKey() {
        let combo = DictationShortcut(kind: .combo, keyCode: 49, modifiers: [.control, .option], keyLabel: "Espacio")
        let flags: UInt64 = 0x40000 | 0x80000
        func input(_ type: CGEventType, _ key: Int64, _ flags: UInt64, repeating: Bool = false, at t: TimeInterval) -> HotkeyStateMachine.Input? {
            HotkeyMonitor.input(type: type, keyCode: key, flags: CGEventFlags(rawValue: flags), isRepeat: repeating,
                                shortcut: combo, at: t)
        }
        XCTAssertEqual(input(.keyDown, 49, flags, at: 1), .optionDown(.left, at: 1, alone: true))
        XCTAssertNil(input(.keyDown, 49, flags, repeating: true, at: 1.1), "la repetición no cuenta")
        XCTAssertEqual(input(.keyUp, 49, 0, at: 2), .optionUp(.left, at: 2))
        // Espacio sin los modificadores, u otra tecla, no es el atajo.
        XCTAssertEqual(input(.keyDown, 49, 0, at: 3), .otherKey(at: 3))
        XCTAssertEqual(input(.keyDown, 49, 0x40000, at: 4), .otherKey(at: 4))
        XCTAssertEqual(input(.keyDown, 53, 0, at: 5), .escape(at: 5))
        XCTAssertNil(input(.flagsChanged, 59, 0, at: 6), "soltar un modificador antes que la tecla no corta nada")
        XCTAssertTrue(HotkeyMonitor.matches(combo, flags: CGEventFlags(rawValue: flags | 0x01 | 0x20)),
                      "las máscaras de lado no cuentan")
        XCTAssertFalse(HotkeyMonitor.matches(combo, flags: CGEventFlags(rawValue: flags | 0x100000)))

        // Doble pulsación: manos libres, igual que con ⌥.
        var machine = HotkeyStateMachine()
        _ = machine.handle(input(.keyDown, 49, flags, at: 10)!)
        _ = machine.handle(input(.keyUp, 49, flags, at: 10.05)!)
        _ = machine.handle(input(.keyDown, 49, flags, at: 10.2)!)
        XCTAssertEqual(machine.handle(input(.keyUp, 49, flags, at: 10.25)!), .enterHandsFree)
    }

    func testShortcutSettingsAreSavedAndOldOnesStillLoad() throws {
        let old = #"{"enabled":true,"side":"left","aiCorrection":false,"engine":"whisper","voiceMode":"split","speakReplies":true}"#
        let loaded = try JSONDecoder().decode(DictationSettings.self, from: Data(old.utf8))
        XCTAssertEqual(loaded.shortcut, .option)
        XCTAssertEqual(loaded.effectiveVoiceMode, .agent, "los modos antiguos van al agente")
        var custom = loaded
        custom.shortcut = DictationShortcut(kind: .modifier, keyCode: 63)
        let again = try JSONDecoder().decode(DictationSettings.self, from: JSONEncoder().encode(custom))
        XCTAssertEqual(again.shortcut, custom.shortcut)
        XCTAssertEqual(again.shortcut.symbol, "fn")
        // Con otro atajo no hay dos ⌥: «una tecla para cada cosa» habla con el agente.
        XCTAssertEqual(again.effectiveVoiceMode, .agent)
        XCTAssertEqual(again.target(leftKey: true), .agent)
        XCTAssertEqual(again.monitoredSide, .any)
    }
}
