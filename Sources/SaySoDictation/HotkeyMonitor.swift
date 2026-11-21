import CoreGraphics
import Foundation
import SaySoCore

public enum HotkeyMonitorError: Error, LocalizedError, Equatable {
    /// No se pudo crear el event tap (falta Monitorización de entrada).
    case tapUnavailable

    public var errorDescription: String? {
        tr("No se puede vigilar el atajo del dictado: falta el permiso de Supervisión de entrada.")
    }
}

/// Fuente de acciones del atajo; permite sustituir el monitor real en pruebas.
public protocol HotkeySource: AnyObject {
    var onAction: ((HotkeyStateMachine.Action) -> Void)? { get set }
    var side: OptionKeySide { get set }
    /// Tecla o combinación que se vigila.
    var shortcut: DictationShortcut { get set }
    /// Tecla física del gesto en curso.
    var activeSide: OptionKeyPhysicalSide? { get }
    func start() throws
    func stop()
    /// Olvida el gesto en curso (p. ej. «manos libres») cuando la grabación no ha podido empezar:
    /// si no, la siguiente pulsación se toma por «parar» y se pierde.
    func resetGesture()
}

/// Event tap de solo escucha sobre `flagsChanged` y `keyDown`. Usar desde el hilo principal.
public final class HotkeyMonitor: HotkeySource {
    public var onAction: ((HotkeyStateMachine.Action) -> Void)?
    public var side: OptionKeySide {
        get { machine.side }
        set { machine.side = newValue; machine.reset(); timer?.cancel() }
    }

    public var activeSide: OptionKeyPhysicalSide? { machine.activeSide }

    public var shortcut: DictationShortcut = .option {
        didSet {
            guard shortcut != oldValue else { return }
            machine.reset()
            timer?.cancel()
            swallowing = false
            // Una combinación con tecla necesita un tap que pueda quedarse el evento: se rehace.
            if tap != nil, (shortcut.kind == .combo) != (oldValue.kind == .combo) {
                stop()
                try? start()
            }
        }
    }
    /// Se está quedando la tecla de la combinación, para que no llegue también a la app activa.
    private var swallowing = false

    private var machine: HotkeyStateMachine
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var timer: DispatchWorkItem?

    // Códigos de tecla.
    static let leftOption: Int64 = 58
    static let rightOption: Int64 = 61
    static let escape: Int64 = 53
    // Máscaras de dispositivo (NX_DEVICELALTKEYMASK / NX_DEVICERALTKEYMASK).
    static let leftOptionMask: UInt64 = 0x20
    static let rightOptionMask: UInt64 = 0x40

    public init(side: OptionKeySide = .any, holdThreshold: TimeInterval = 0.2, doubleTapWindow: TimeInterval = 0.4) {
        machine = HotkeyStateMachine(side: side, holdThreshold: holdThreshold, doubleTapWindow: doubleTapWindow)
    }

    deinit { stop() }

    public func start() throws {
        guard tap == nil else { return }
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
        func make(_ options: CGEventTapOptions) -> CFMachPort? {
            CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: options,
                              eventsOfInterest: CGEventMask(mask), callback: hotkeyTapCallback,
                              userInfo: Unmanaged.passUnretained(self).toOpaque())
        }
        // Con una combinación, el tap se queda la tecla (necesita Accesibilidad). Si no se puede,
        // se escucha sin quedársela: funciona igual, pero la tecla llega también a la app activa.
        guard let tap = (shortcut.kind == .combo ? make(.defaultTap) : nil) ?? make(.listenOnly) else {
            throw HotkeyMonitorError.tapUnavailable
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
    }

    public func stop() {
        timer?.cancel()
        timer = nil
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        tap = nil
        source = nil
        machine.reset()
    }

    public func resetGesture() {
        machine.reset()
        timer?.cancel()
        timer = nil
    }

    /// Devuelve `true` si el evento es del atajo y no debe llegar a la app activa.
    fileprivate func handle(type: CGEventType, event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // El sistema desactivó el tap: se reactiva.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        default:
            break
        }
        let now = ProcessInfo.processInfo.systemUptime
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        var consume = false
        if shortcut.kind == .combo, keyCode == Int64(shortcut.keyCode) {
            switch type {
            case .keyDown:
                if !isRepeat { swallowing = Self.matches(shortcut, flags: event.flags) }
                consume = swallowing
            case .keyUp:
                consume = swallowing
                swallowing = false
            default:
                break
            }
        }
        if let input = Self.input(type: type, keyCode: keyCode, flags: event.flags, isRepeat: isRepeat,
                                  shortcut: shortcut, at: now) {
            feed(input)
        }
        return consume
    }

    /// La pulsación lleva exactamente los modificadores de la combinación.
    static func matches(_ shortcut: DictationShortcut, flags: CGEventFlags) -> Bool {
        ShortcutModifiers(eventFlags: flags.rawValue) == shortcut.modifiers
    }

    /// Traduce un evento a una entrada de la máquina de estados.
    static func input(type: CGEventType, keyCode: Int64, flags: CGEventFlags, isRepeat: Bool,
                      shortcut: DictationShortcut = .option, at now: TimeInterval) -> HotkeyStateMachine.Input? {
        switch shortcut.kind {
        case .option: return optionInput(type: type, keyCode: keyCode, flags: flags, isRepeat: isRepeat, at: now)
        case .modifier: return modifierInput(type: type, keyCode: keyCode, flags: flags, isRepeat: isRepeat,
                                             shortcut: shortcut, at: now)
        case .combo: return comboInput(type: type, keyCode: keyCode, flags: flags, isRepeat: isRepeat,
                                       shortcut: shortcut, at: now)
        }
    }

    /// Una modificadora sola (fn, ⌘ derecha…). Se trata como la ⌥ izquierda de siempre.
    private static func modifierInput(type: CGEventType, keyCode: Int64, flags: CGEventFlags, isRepeat: Bool,
                                      shortcut: DictationShortcut, at now: TimeInterval) -> HotkeyStateMachine.Input? {
        guard let key = shortcut.modifierKey else { return nil }
        switch type {
        case .keyDown:
            if isRepeat { return nil }
            return keyCode == escape ? .escape(at: now) : .otherKey(at: now)
        case .flagsChanged:
            if keyCode == Int64(key.keyCode) {
                guard flags.rawValue & key.deviceMask != 0 else { return .optionUp(.left, at: now) }
                // Sola: ningún otro modificador, aparte del propio.
                let others = (ShortcutModifiers.all.rawValue | DictationShortcut.fnFlag) & ~key.family
                return .optionDown(.left, at: now, alone: flags.rawValue & others == 0)
            }
            return modifierPressed(keyCode: keyCode, flags: flags) ? .otherKey(at: now) : nil
        default:
            return nil
        }
    }

    /// Una combinación con tecla: mantenerla es mantener el atajo.
    private static func comboInput(type: CGEventType, keyCode: Int64, flags: CGEventFlags, isRepeat: Bool,
                                   shortcut: DictationShortcut, at now: TimeInterval) -> HotkeyStateMachine.Input? {
        let isKey = keyCode == Int64(shortcut.keyCode)
        switch type {
        case .keyDown:
            if isRepeat { return nil }
            if isKey, matches(shortcut, flags: flags) { return .optionDown(.left, at: now, alone: true) }
            return keyCode == escape ? .escape(at: now) : .otherKey(at: now)
        case .keyUp:
            return isKey ? .optionUp(.left, at: now) : nil
        default:
            // Soltar un modificador antes que la tecla no corta nada: manda la tecla.
            return nil
        }
    }

    private static func modifierPressed(keyCode: Int64, flags: CGEventFlags) -> Bool {
        switch keyCode {
        case 54, 55: return flags.contains(.maskCommand)
        case 56, 60: return flags.contains(.maskShift)
        case 59, 62: return flags.contains(.maskControl)
        case 58, 61: return flags.contains(.maskAlternate)
        case 63: return flags.contains(.maskSecondaryFn)
        case 57: return true // Bloq Mayús
        default: return false
        }
    }

    private static func optionInput(type: CGEventType, keyCode: Int64, flags: CGEventFlags, isRepeat: Bool,
                                    at now: TimeInterval) -> HotkeyStateMachine.Input? {
        let raw = flags.rawValue
        switch type {
        case .keyDown:
            if isRepeat { return nil }
            return keyCode == escape ? .escape(at: now) : .otherKey(at: now)
        case .flagsChanged:
            if keyCode == leftOption || keyCode == rightOption {
                let physical: OptionKeyPhysicalSide = keyCode == leftOption ? .left : .right
                let mask = physical == .left ? leftOptionMask : rightOptionMask
                if raw & mask != 0 {
                    let others: CGEventFlags = [.maskCommand, .maskControl, .maskShift]
                    return .optionDown(physical, at: now, alone: flags.intersection(others).isEmpty)
                }
                return .optionUp(physical, at: now)
            }
            // Otro modificador: solo cuenta al pulsarse.
            let pressed: Bool
            switch keyCode {
            case 54, 55: pressed = flags.contains(.maskCommand)
            case 56, 60: pressed = flags.contains(.maskShift)
            case 59, 62: pressed = flags.contains(.maskControl)
            case 63: pressed = flags.contains(.maskSecondaryFn)
            case 57: pressed = true // Bloq Mayús
            default: pressed = false
            }
            return pressed ? .otherKey(at: now) : nil
        default:
            return nil
        }
    }

    private func feed(_ input: HotkeyStateMachine.Input) {
        let action = machine.handle(input)
        scheduleTick()
        if let action { onAction?(action) }
    }

    private func scheduleTick() {
        timer?.cancel()
        timer = nil
        guard let deadline = machine.nextDeadline else { return }
        let item = DispatchWorkItem { [weak self] in
            self?.feed(.tick(at: max(ProcessInfo.processInfo.systemUptime, deadline)))
        }
        timer = item
        let delay = max(0, deadline - ProcessInfo.processInfo.systemUptime)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }
}

private func hotkeyTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                               userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if let userInfo, Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue().handle(type: type, event: event) {
        return nil
    }
    return Unmanaged.passUnretained(event)
}
