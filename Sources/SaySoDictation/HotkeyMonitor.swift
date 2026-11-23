import Carbon.HIToolbox
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
    /// Esc pulsada sin gesto en curso: sirve para cancelar una petición al agente o su respuesta.
    var onEscape: (() -> Void)? { get set }
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

/// Event tap sobre `flagsChanged`, `keyDown` y `keyUp`. Se configura desde el hilo principal y las
/// acciones llegan en él, pero el tap escucha en un hilo propio: si el hilo principal se atasca, el
/// teclado del Mac no espera a SaySo y macOS no desactiva el tap.
public final class HotkeyMonitor: HotkeySource, @unchecked Sendable {
    public var onAction: ((HotkeyStateMachine.Action) -> Void)?
    public var onEscape: (() -> Void)?
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
            tapLock.withLock {
                tapShortcut = shortcut
                swallowing = false
            }
            // Una combinación con tecla necesita un tap que pueda quedarse el evento: se rehace.
            if tap != nil, (shortcut.kind == .combo) != (oldValue.kind == .combo) || hotKey != nil {
                stop()
                try? start()
            }
        }
    }
    // Lo que lee el hilo del tap, protegido por `tapLock`.
    private let tapLock = NSLock()
    /// Se está quedando la tecla de la combinación, para que no llegue también a la app activa.
    private var swallowing = false
    private var tapShortcut: DictationShortcut = .option
    private var tapHotKeyActive = false
    /// Bucle del hilo del tap, para pararlo.
    private var tapRunLoop: CFRunLoop?

    private var machine: HotkeyStateMachine
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var timer: DispatchWorkItem?
    /// Atajo del sistema (Carbon) para la combinación en la versión de la tienda: se queda la tecla
    /// sin Accesibilidad. Mientras existe, el tap no cuenta la tecla de la combinación.
    private var hotKey: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?

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
        // Quitarle la combinación a la app activa necesita Accesibilidad, que el sandbox de la tienda
        // no da: allí solo se escucha.
        let swallow = shortcut.kind == .combo && !BuildFlavor.isAppStore
        guard let tap = (swallow ? make(.defaultTap) : nil) ?? make(.listenOnly) else {
            throw HotkeyMonitorError.tapUnavailable
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        tapLock.withLock { tapShortcut = shortcut; swallowing = false }
        let box = RunLoopBox()
        let thread = Thread {
            let loop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(loop, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            box.loop = loop
            box.ready.signal()
            CFRunLoopRun()
        }
        thread.name = "SaySo hotkey"
        thread.qualityOfService = .userInteractive
        thread.start()
        box.ready.wait()
        self.tap = tap
        self.source = source
        self.tapRunLoop = box.loop
        if shortcut.kind == .combo, BuildFlavor.isAppStore { registerHotKey() }
    }

    /// Modificadores de Carbon de una combinación; `nil` si lleva fn, que Carbon no admite.
    static func carbonModifiers(_ shortcut: DictationShortcut) -> UInt32? {
        let m = shortcut.modifiers
        guard m.rawValue & DictationShortcut.fnFlag == 0 else { return nil }
        var out: UInt32 = 0
        if m.contains(.command) { out |= UInt32(cmdKey) }
        if m.contains(.option) { out |= UInt32(optionKey) }
        if m.contains(.control) { out |= UInt32(controlKey) }
        if m.contains(.shift) { out |= UInt32(shiftKey) }
        return out
    }

    private func registerHotKey() {
        guard hotKey == nil, let modifiers = Self.carbonModifiers(shortcut) else { return }
        var types = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        var handler: EventHandlerRef?
        let installed = InstallEventHandler(GetApplicationEventTarget(), hotKeyCallback, types.count, &types,
                                            Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard installed == noErr else { return }
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x5361_5953), id: 1) // «SaYS»
        guard RegisterEventHotKey(UInt32(shortcut.keyCode), modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr,
              let ref else {
            // Ya la usa otra app: se sigue escuchando sin quedársela.
            if let handler { RemoveEventHandler(handler) }
            return
        }
        hotKey = ref
        hotKeyHandler = handler
        tapLock.withLock { tapHotKeyActive = true }
    }

    private func unregisterHotKey() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let hotKeyHandler { RemoveEventHandler(hotKeyHandler) }
        hotKey = nil
        hotKeyHandler = nil
        tapLock.withLock { tapHotKeyActive = false }
    }

    fileprivate func hotKeyEvent(pressed: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        feed(pressed ? .optionDown(.left, at: now, alone: true) : .optionUp(.left, at: now))
    }

    public func stop() {
        timer?.cancel()
        timer = nil
        unregisterHotKey()
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source, let tapRunLoop {
            CFRunLoopRemoveSource(tapRunLoop, source, .commonModes)
            CFRunLoopStop(tapRunLoop)
        }
        tap = nil
        source = nil
        tapRunLoop = nil
        machine.reset()
    }

    public func resetGesture() {
        machine.reset()
        timer?.cancel()
        timer = nil
    }

    /// En el hilo del tap. Devuelve `true` si el evento es del atajo y no debe llegar a la app
    /// activa; la entrada para la máquina de estados se pasa al hilo principal.
    fileprivate func handle(type: CGEventType, event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // El sistema desactivó el tap: se reactiva. Mientras estuvo apagado pudo perderse el
            // soltar la tecla, y la grabación se quedaría abierta: se comprueba en el principal.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            DispatchQueue.main.async { [weak self] in self?.tapWasReenabled() }
            return false
        default:
            break
        }
        let now = ProcessInfo.processInfo.systemUptime
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let (shortcut, consume): (DictationShortcut, Bool) = tapLock.withLock {
            let shortcut = tapShortcut
            // La tecla de la combinación la cuenta el atajo del sistema.
            if tapHotKeyActive, keyCode == Int64(shortcut.keyCode), type == .keyDown || type == .keyUp {
                return (shortcut, false)
            }
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
            return (shortcut, consume)
        }
        if tapLock.withLock({ tapHotKeyActive }), keyCode == Int64(shortcut.keyCode), type == .keyDown || type == .keyUp {
            return false // la cuenta el atajo del sistema
        }
        if let input = Self.input(type: type, keyCode: keyCode, flags: event.flags, isRepeat: isRepeat,
                                  shortcut: shortcut, at: now) {
            DispatchQueue.main.async { [weak self] in self?.feed(input) }
        }
        return consume
    }

    /// Tras reactivar el tap: si el gesto sigue abierto pero la tecla ya no está pulsada, se da por
    /// soltada (si no, la grabación seguiría hasta la siguiente pulsación).
    private func tapWasReenabled() {
        switch machine.state {
        case .pressed, .holding, .awaitingRelease:
            guard !Self.isHeld(shortcut) else { return }
            feed(.optionUp(machine.activeSide ?? .left, at: ProcessInfo.processInfo.systemUptime))
        default:
            break
        }
    }

    /// La tecla del atajo está pulsada ahora mismo.
    static func isHeld(_ shortcut: DictationShortcut) -> Bool {
        let flags = CGEventSource.flagsState(.combinedSessionState).rawValue
        switch shortcut.kind {
        case .option: return flags & (leftOptionMask | rightOptionMask) != 0
        case .modifier: return shortcut.modifierKey.map { flags & $0.deviceMask != 0 } ?? false
        case .combo: return CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(shortcut.keyCode))
        }
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
        let wasIdle = machine.state == .idle
        let action = machine.handle(input)
        scheduleTick()
        if let action { onAction?(action) }
        if case .escape = input, action == nil, wasIdle { onEscape?() }
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

/// El bucle del hilo del tap, que se pasa al hilo que lo crea.
private final class RunLoopBox: @unchecked Sendable {
    var loop: CFRunLoop?
    let ready = DispatchSemaphore(value: 0)
}

private func hotkeyTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                               userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if let userInfo, Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue().handle(type: type, event: event) {
        return nil
    }
    return Unmanaged.passUnretained(event)
}

/// Recibe el atajo del sistema (pulsado y soltado) y lo pasa al monitor.
private func hotKeyCallback(_ next: EventHandlerCallRef?, _ event: EventRef?, _ user: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let user else { return OSStatus(eventNotHandledErr) }
    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(user).takeUnretainedValue()
    let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
    monitor.hotKeyEvent(pressed: pressed)
    return noErr
}
