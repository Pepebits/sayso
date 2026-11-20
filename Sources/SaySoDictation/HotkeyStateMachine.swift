import Foundation
import SaySoCore

/// Lado físico de una tecla ⌥.
public enum OptionKeyPhysicalSide: Hashable, Sendable {
    case left, right
}

/// Lógica pura del atajo ⌥: no usa APIs del sistema; el tiempo llega en las entradas.
public struct HotkeyStateMachine: Sendable {
    public enum Input: Hashable, Sendable {
        /// ⌥ pulsada. `alone` es falso si ya había otro modificador pulsado.
        case optionDown(OptionKeyPhysicalSide, at: TimeInterval, alone: Bool = true)
        case optionUp(OptionKeyPhysicalSide, at: TimeInterval)
        /// Otra tecla o modificador pulsado.
        case otherKey(at: TimeInterval)
        case escape(at: TimeInterval)
        /// Paso del tiempo (lo envía el temporizador del monitor).
        case tick(at: TimeInterval)
    }

    public enum Action: Hashable, Sendable {
        case startListening
        case stopAndTranscribe
        case cancel
        case enterHandsFree
    }

    public enum State: Hashable, Sendable {
        case idle
        /// ⌥ pulsada, aún sin superar el umbral. `secondTap`: puede ser la segunda pulsación corta.
        case pressed(since: TimeInterval, secondTap: Bool)
        /// Escuchando mientras se mantiene ⌥.
        case holding
        /// Escuchando en manos libres (⌥ ya soltada).
        case handsFree
        /// Esperando a que se suelte ⌥ sin hacer nada más.
        case awaitingRelease
    }

    public var side: OptionKeySide
    public let holdThreshold: TimeInterval
    public let doubleTapWindow: TimeInterval
    public private(set) var state: State = .idle
    /// Instante en que se soltó la última pulsación corta.
    private var lastTapRelease: TimeInterval?
    /// Tecla física con la que empezó el gesto actual (o el último).
    public private(set) var activeSide: OptionKeyPhysicalSide?

    public init(side: OptionKeySide = .any, holdThreshold: TimeInterval = 0.2, doubleTapWindow: TimeInterval = 0.4) {
        self.side = side
        self.holdThreshold = holdThreshold
        self.doubleTapWindow = doubleTapWindow
    }

    /// Indica si se está escuchando (manteniendo o en manos libres).
    public var isListening: Bool { state == .holding || state == .handsFree }

    /// Instante en el que el monitor debe enviar un `tick`, si hace falta.
    public var nextDeadline: TimeInterval? {
        if case let .pressed(since, _) = state { return since + holdThreshold }
        return nil
    }

    /// Vuelve al reposo sin emitir nada (p. ej. al cambiar ajustes).
    public mutating func reset() {
        state = .idle
        lastTapRelease = nil
    }

    @discardableResult
    public mutating func handle(_ input: Input) -> Action? {
        switch input {
        case let .optionDown(physical, t, alone):
            return optionDown(physical, at: t, alone: alone)
        case let .optionUp(physical, t):
            return optionUp(physical, at: t)
        case .otherKey:
            return otherKey()
        case .escape:
            return escape()
        case let .tick(t):
            return tick(at: t)
        }
    }

    private mutating func optionDown(_ physical: OptionKeyPhysicalSide, at t: TimeInterval, alone: Bool) -> Action? {
        guard OptionKeySide.PhysicalMatch(physical).matches(side) else {
            // ⌥ del otro lado: se comporta como otro modificador mientras se usa el atajo.
            return state == .idle || state == .handsFree ? nil : otherKey()
        }
        switch state {
        case .idle:
            guard alone else {
                lastTapRelease = nil
                state = .awaitingRelease
                return nil
            }
            // La segunda pulsación del manos libres tiene que ser con la misma tecla.
            let second = (lastTapRelease.map { t - $0 <= doubleTapWindow } ?? false) && activeSide == physical
            lastTapRelease = nil
            activeSide = physical
            state = .pressed(since: t, secondTap: second)
            return nil
        case .handsFree:
            // La siguiente pulsación termina el manos libres.
            state = .awaitingRelease
            return .stopAndTranscribe
        case .pressed, .holding, .awaitingRelease:
            // Repetición de flagsChanged o la otra ⌥ con «cualquiera»: se ignora.
            return nil
        }
    }

    private mutating func optionUp(_ physical: OptionKeyPhysicalSide, at t: TimeInterval) -> Action? {
        guard OptionKeySide.PhysicalMatch(physical).matches(side) else { return nil }
        switch state {
        case let .pressed(since, secondTap):
            state = .idle
            guard t - since < holdThreshold else {
                // Superó el umbral sin tick: demasiado corta para grabar nada.
                return nil
            }
            if secondTap {
                state = .handsFree
                return .enterHandsFree
            }
            lastTapRelease = t
            return nil
        case .holding:
            state = .idle
            return .stopAndTranscribe
        case .awaitingRelease:
            state = .idle
            return nil
        case .idle, .handsFree:
            return nil
        }
    }

    private mutating func otherKey() -> Action? {
        lastTapRelease = nil
        switch state {
        case .pressed:
            // Combinación ⌥+tecla (⌥+ñ, ⌥+2…): no se hace nada.
            state = .awaitingRelease
            return nil
        case .holding:
            state = .awaitingRelease
            return .cancel
        case .idle, .handsFree, .awaitingRelease:
            return nil
        }
    }

    private mutating func escape() -> Action? {
        switch state {
        case .handsFree:
            state = .idle
            lastTapRelease = nil
            return .cancel
        default:
            return otherKey()
        }
    }

    private mutating func tick(at t: TimeInterval) -> Action? {
        if case let .pressed(since, _) = state, t - since >= holdThreshold {
            state = .holding
            return .startListening
        }
        if let last = lastTapRelease, t - last > doubleTapWindow {
            lastTapRelease = nil
        }
        return nil
    }
}

extension OptionKeySide {
    /// Adaptador del lado físico al ajuste configurado.
    struct PhysicalMatch {
        let physical: OptionKeyPhysicalSide
        init(_ physical: OptionKeyPhysicalSide) { self.physical = physical }

        func matches(_ side: OptionKeySide) -> Bool {
            switch side {
            case .any: return true
            case .left: return physical == .left
            case .right: return physical == .right
            }
        }
    }
}
