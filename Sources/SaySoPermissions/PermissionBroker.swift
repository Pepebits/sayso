import Foundation
import SaySoCore

/// Motor de permisos (ADR-0007). Único punto de paso de las acciones con efecto fuera de la VM.
public final class PermissionBroker: PermissionBrokering, @unchecked Sendable {
    private let store: SaySoStoring
    private let presenter: ConfirmationPresenter
    private let redactor: SecretRedacting?
    private let lock = NSLock()
    private var descriptors: [ActionID: ActionDescriptor] = [:]
    /// Serializa los diálogos «Preguntar»: uno cada vez.
    private let dialogGate = AsyncGate()
    /// Revisa las acciones hacia fuera de los turnos que han leído contenido ajeno. Sin revisor, esas
    /// acciones se preguntan.
    private var _reviewer: ActionReviewing?
    public var reviewer: ActionReviewing? {
        get { lock.lock(); defer { lock.unlock() }; return _reviewer }
        set { lock.lock(); _reviewer = newValue; lock.unlock() }
    }

    public init(store: SaySoStoring, presenter: ConfirmationPresenter, descriptors: [ActionDescriptor],
                redactor: SecretRedacting? = nil) {
        self.store = store
        self.presenter = presenter
        self.redactor = redactor
        register(descriptors)
    }

    /// Añade o sustituye descriptores (p. ej. los de un plugin).
    public func register(_ descriptors: [ActionDescriptor]) {
        lock.lock()
        defer { lock.unlock() }
        for d in descriptors { self.descriptors[d.id] = d }
    }

    public func descriptor(for action: ActionID) -> ActionDescriptor? {
        lock.lock()
        defer { lock.unlock() }
        return descriptors[action]
    }

    /// Regla que se aplicaría ahora mismo, con el acceso total ya tenido en cuenta.
    public func effectiveRule(for action: ActionID) throws -> PermissionRule {
        let base = try store.rule(for: action) ?? descriptor(for: action)?.defaultRule ?? .ask
        if base == .ask, action.scope == "telegram", try store.setting(SettingsKey.telegramFullAccess) == "1" {
            return .allow
        }
        return base
    }

    public func run<T: Sendable>(_ request: ActionRequest, operation: @Sendable () async throws -> T) async throws -> T {
        let action = request.action

        // Interruptor general de Telegram.
        if action.scope == "telegram", try store.setting(SettingsKey.telegramEnabled) == "0" {
            let rule = (try? effectiveRule(for: action)) ?? .ask
            log(request, rule: rule, outcome: .denied)
            throw PermissionError.denied(action, reason: "Telegram está desactivado")
        }

        var rule = try effectiveRule(for: action)
        var request = request
        // Autorizada de antemano por el usuario: sin diálogo ni revisión, salvo que la regla sea Nunca.
        if request.preapproved, rule != .never {
            do {
                let value = try await operation()
                log(request, rule: .allow, outcome: .allowed)
                return value
            } catch {
                log(request, rule: .allow, outcome: .failed)
                throw error
            }
        }
        // Protección: una acción hacia fuera que se iba a permitir sola, en un turno que ha leído
        // contenido de terceros, pasa por el revisor; si algo no cuadra, se pregunta en el Mac.
        var forcedReason: String?
        if rule == .allow, GuardPolicy.isOutward(action), let context = GuardContext.current {
            forcedReason = await guardReason(request, context: context)
            if let forcedReason {
                rule = .ask
                request.parameters[GuardPolicy.reasonKey] = forcedReason
            }
        }
        switch rule {
        case .allow:
            break
        case .never:
            log(request, rule: rule, outcome: .denied)
            throw PermissionError.denied(action, reason: "la regla es Nunca")
        case .ask:
            await dialogGate.acquire()
            // Se reevalúa dentro del turno: un «Permitir siempre» anterior puede haberla cambiado.
            // Si se pregunta por la protección, la regla guardada ya era «Permitir»: se pregunta igual.
            let current: PermissionRule
            do { current = forcedReason != nil ? .ask : try effectiveRule(for: action) } catch {
                await dialogGate.release()
                throw error
            }
            switch current {
            case .allow:
                await dialogGate.release()
            case .never:
                await dialogGate.release()
                rule = .never
                log(request, rule: rule, outcome: .denied)
                throw PermissionError.denied(action, reason: "la regla es Nunca")
            case .ask:
                let answer = await presenter.confirm(request, descriptor: descriptor(for: action))
                if answer == .allowAlways, forcedReason == nil { try? store.setRule(.allow, for: action) }
                await dialogGate.release()
                if answer == .deny {
                    log(request, rule: rule, outcome: .denied)
                    throw PermissionError.denied(action, reason: "el usuario la ha denegado")
                }
            }
        }

        do {
            let value = try await operation()
            log(request, rule: rule, outcome: .allowed)
            return value
        } catch {
            log(request, rule: rule, outcome: .failed)
            throw error
        }
    }

    /// Motivo para preguntar una acción que la regla permitiría, o `nil` si puede seguir.
    private func guardReason(_ request: ActionRequest, context: GuardContext) async -> String? {
        // Con una posible inyección detectada, el revisor decide siempre (aunque su ajuste esté
        // apagado): el detector se equivoca con páginas normales y preguntar cada vez dejaba las
        // tareas paradas esperando en el Mac.
        if let flagged = context.injectionFlags.first {
            guard let reviewer else {
                return "El detector ha visto instrucciones para el agente dentro de \(flagged). Puede que no lo hayas pedido tú."
            }
            return await reviewer.reasonToAsk(request, context: context)
        }
        guard context.isTainted else { return nil }
        let sources = context.thirdPartySources.joined(separator: ", ")
        guard (try? store.setting(GuardSettings.review)) != "0" else { return nil }
        guard let reviewer else {
            return "En este turno el agente ha leído contenido de terceros (\(sources))."
        }
        return await reviewer.reasonToAsk(request, context: context)
    }

    /// Añade la entrada al registro. Un fallo del registro no bloquea la acción.
    private func log(_ request: ActionRequest, rule: PermissionRule, outcome: ActivityOutcome) {
        let summary = redactor?.redact(request.summary) ?? request.summary
        let entry = ActivityEntry(action: request.action, summary: summary, rule: rule,
                                  outcome: outcome, origin: request.origin)
        _ = try? store.appendActivity(entry)
    }
}

/// Cerrojo asíncrono FIFO: solo un poseedor a la vez.
actor AsyncGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            // El turno pasa directamente al siguiente; `busy` sigue a true.
            waiters.removeFirst().resume()
        }
    }
}
