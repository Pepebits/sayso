import Foundation

/// Modificadores de un atajo con tecla. Los valores coinciden con los de `CGEventFlags` y
/// `NSEvent.ModifierFlags`, así que se comparan directamente con los de un evento.
public struct ShortcutModifiers: OptionSet, Hashable, Codable, Sendable {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }

    public static let shift = ShortcutModifiers(rawValue: 0x20000)
    public static let control = ShortcutModifiers(rawValue: 0x40000)
    public static let option = ShortcutModifiers(rawValue: 0x80000)
    public static let command = ShortcutModifiers(rawValue: 0x100000)
    public static let all: ShortcutModifiers = [.shift, .control, .option, .command]

    /// Solo los cuatro modificadores de un valor de flags de evento.
    public init(eventFlags: UInt64) { self.init(rawValue: eventFlags & ShortcutModifiers.all.rawValue) }

    /// En el orden de macOS: ⌃⌥⇧⌘.
    public var symbols: [String] {
        var out: [String] = []
        if contains(.control) { out.append("⌃") }
        if contains(.option) { out.append("⌥") }
        if contains(.shift) { out.append("⇧") }
        if contains(.command) { out.append("⌘") }
        return out
    }
}

/// Atajo del dictado: la tecla ⌥ (con su lado), otra tecla modificadora sola (fn, ⌘ derecha…)
/// o una combinación con tecla (⌃⌥Espacio, F5…). Se mantiene para hablar y se pulsa dos veces
/// para manos libres, sea cual sea.
public struct DictationShortcut: Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// ⌥, con el lado y el modo «una tecla para cada cosa» de siempre.
        case option
        /// Una tecla modificadora sola, distinta de ⌥.
        case modifier
        /// Una tecla normal con modificadores, o una tecla de función sola.
        case combo
    }

    public var kind: Kind
    /// Código de la tecla: la modificadora o la tecla principal de la combinación.
    public var keyCode: UInt16
    /// Modificadores de la combinación (vacío en los otros tipos).
    public var modifiers: ShortcutModifiers
    /// Cómo se llama la tecla principal en el teclado del usuario («K», «Espacio», «F5»).
    public var keyLabel: String

    public init(kind: Kind, keyCode: UInt16, modifiers: ShortcutModifiers = [], keyLabel: String = "") {
        self.kind = kind
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = keyLabel
    }

    /// El de siempre.
    public static let option = DictationShortcut(kind: .option, keyCode: 58, keyLabel: "⌥")

    // MARK: Teclas modificadoras

    /// Teclas modificadoras que pueden ser atajo por sí solas, con su máscara de dispositivo
    /// (la que distingue la izquierda de la derecha en los flags del evento).
    public struct ModifierKey: Hashable, Sendable {
        public let keyCode: UInt16
        public let symbol: String
        public let sideName: String?
        public let deviceMask: UInt64
        /// Modificador general al que pertenece (el que no cuenta como «otro» al pulsarla).
        public let family: UInt64
    }

    public static let fnFlag: UInt64 = 0x800000

    public static let modifierKeys: [ModifierKey] = [
        ModifierKey(keyCode: 63, symbol: "fn", sideName: nil, deviceMask: fnFlag, family: fnFlag),
        ModifierKey(keyCode: 55, symbol: "⌘", sideName: "izquierda", deviceMask: 0x08, family: ShortcutModifiers.command.rawValue),
        ModifierKey(keyCode: 54, symbol: "⌘", sideName: "derecha", deviceMask: 0x10, family: ShortcutModifiers.command.rawValue),
        ModifierKey(keyCode: 59, symbol: "⌃", sideName: "izquierda", deviceMask: 0x01, family: ShortcutModifiers.control.rawValue),
        ModifierKey(keyCode: 62, symbol: "⌃", sideName: "derecha", deviceMask: 0x2000, family: ShortcutModifiers.control.rawValue),
        ModifierKey(keyCode: 56, symbol: "⇧", sideName: "izquierda", deviceMask: 0x02, family: ShortcutModifiers.shift.rawValue),
        ModifierKey(keyCode: 60, symbol: "⇧", sideName: "derecha", deviceMask: 0x04, family: ShortcutModifiers.shift.rawValue),
    ]

    /// Teclas ⌥ izquierda y derecha.
    public static let optionKeyCodes: Set<UInt16> = [58, 61]

    public var modifierKey: ModifierKey? {
        kind == .modifier ? Self.modifierKeys.first { $0.keyCode == keyCode } : nil
    }

    // MARK: Cómo se enseña

    /// Las teclas por separado, para dibujarlas: ["⌃", "⌥", "Espacio"].
    public var keys: [String] {
        switch kind {
        case .option: return ["⌥"]
        case .modifier: return [modifierKey?.symbol ?? "?"]
        case .combo: return modifiers.symbols + [keyLabel]
        }
    }

    /// En una línea: «⌥», «fn», «⌘ derecha», «⌃⌥Espacio».
    public var symbol: String {
        switch kind {
        case .option: return "⌥"
        case .modifier:
            guard let key = modifierKey else { return "?" }
            return key.sideName.map { "\(key.symbol) \(tr($0))" } ?? key.symbol
        case .combo:
            let label = keyLabel.count > 1 ? " " + keyLabel : keyLabel
            return modifiers.symbols.joined() + label
        }
    }

    // MARK: Qué se puede usar

    /// Códigos de las teclas de función F1–F20.
    public static let functionKeys: [UInt16: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9",
        109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17",
        79: "F18", 80: "F19", 90: "F20",
    ]

    /// Nombres de las teclas que no escriben un carácter visible.
    public static func specialLabel(_ keyCode: UInt16) -> String? {
        if let f = functionKeys[keyCode] { return f }
        switch keyCode {
        case 49: return tr("Espacio")
        case 36: return "↩"
        case 48: return "⇥"
        case 51: return "⌫"
        case 117: return "⌦"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        case 115: return "↖"
        case 119: return "↘"
        case 116: return "⇞"
        case 121: return "⇟"
        default: return nil
        }
    }

    /// Combinaciones que macOS o las apps ya usan para algo importante.
    static let reserved: [(ShortcutModifiers, UInt16, String)] = [
        (.command, 12, "⌘Q cierra la app activa."),
        (.command, 13, "⌘W cierra la ventana activa."),
        (.command, 48, "⌘⇥ cambia de app."),
        (.command, 49, "⌘Espacio abre Spotlight."),
        (.command, 4, "⌘H oculta la app activa."),
        (.command, 46, "⌘M minimiza la ventana."),
        (.command, 0, "⌘A selecciona todo."),
        (.command, 8, "⌘C copia."),
        (.command, 9, "⌘V pega, y SaySo lo usa para escribir el texto."),
        (.command, 7, "⌘X corta."),
        (.command, 6, "⌘Z deshace."),
        (.control, 49, "⌃Espacio cambia la fuente de entrada."),
    ]

    /// Por qué no vale una combinación, o `nil` si vale.
    public static func problem(keyCode: UInt16, modifiers: ShortcutModifiers) -> String? {
        if keyCode == 53 { return "Esc se usa para cancelar el dictado." }
        let isFunction = functionKeys[keyCode] != nil
        // Sin ⌃, ⌥ ni ⌘ la tecla se usaría al escribir (⇧ solo hace mayúsculas).
        if !isFunction, modifiers.intersection([.control, .option, .command]).isEmpty {
            return "Combínala con ⌃, ⌥ o ⌘: sola, o solo con ⇧, se usa al escribir."
        }
        if let hit = reserved.first(where: { $0.0 == modifiers && $0.1 == keyCode }) { return hit.2 }
        return nil
    }
}

/// Lee el atajo que el usuario pulsa al grabarlo. Lógica pura: los eventos llegan con su código
/// de tecla y sus flags, sin AppKit.
public struct ShortcutCapture: Sendable {
    public enum Result: Equatable, Sendable {
        case done(DictationShortcut)
        case rejected(String)
        case cancelled
    }

    /// Tecla modificadora pulsada sola, esperando a ver si se suelta sin más.
    private var pendingModifier: UInt16?
    /// Se ha pulsado más de un modificador a la vez: no es una tecla sola.
    private var mixed = false

    public init() {}

    /// Cambio de modificadores. Devuelve un resultado al soltar una modificadora pulsada sola.
    public mutating func flagsChanged(keyCode: UInt16, flags: UInt64) -> Result? {
        let isOption = DictationShortcut.optionKeyCodes.contains(keyCode)
        let key = DictationShortcut.modifierKeys.first { $0.keyCode == keyCode }
        guard isOption || key != nil else { return nil }
        let mask: UInt64 = isOption ? (keyCode == 58 ? 0x20 : 0x40) : key!.deviceMask
        let down = flags & mask != 0
        let held = ShortcutModifiers(eventFlags: flags).rawValue | (flags & DictationShortcut.fnFlag)
        if down {
            if pendingModifier == nil, !mixed {
                pendingModifier = keyCode
            } else if pendingModifier != keyCode {
                mixed = true
            }
            return nil
        }
        // Al soltar: si era la única pulsada y no queda ninguna otra, ese es el atajo.
        defer { if held == 0 { pendingModifier = nil; mixed = false } }
        guard pendingModifier == keyCode, !mixed, held == 0 else { return nil }
        if isOption { return .done(.option) }
        return .done(DictationShortcut(kind: .modifier, keyCode: keyCode))
    }

    /// Pulsación de una tecla normal. `characters` es lo que escribe sin modificadores.
    public mutating func keyDown(keyCode: UInt16, flags: UInt64, characters: String?) -> Result {
        pendingModifier = nil
        mixed = false
        let modifiers = ShortcutModifiers(eventFlags: flags)
        if keyCode == 53, modifiers.isEmpty { return .cancelled }
        if let problem = DictationShortcut.problem(keyCode: keyCode, modifiers: modifiers) {
            return .rejected(problem)
        }
        let label = DictationShortcut.specialLabel(keyCode)
            ?? characters.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
                .flatMap { $0.isEmpty ? nil : $0 }
            ?? "#\(keyCode)"
        return .done(DictationShortcut(kind: .combo, keyCode: keyCode, modifiers: modifiers, keyLabel: label))
    }
}
