import Foundation
import SaySoCore

/// El tope de tokens se ha alcanzado: no se hacen más peticiones a modelos de pago hasta mañana
/// (o el mes que viene), salvo que el usuario lo suba.
public struct BudgetReachedError: Error, LocalizedError, Equatable, Sendable {
    public let period: BudgetPeriod
    public let limit: Int

    public init(period: BudgetPeriod, limit: Int) {
        self.period = period
        self.limit = limit
    }

    public var errorDescription: String? {
        period == .day
            ? tr("Has llegado al límite diario de %@ tokens. El agente vuelve mañana, o súbelo en Estadísticas → Límite de gasto.", TokenLimits.short(limit))
            : tr("Has llegado al límite mensual de %@ tokens. El agente vuelve el mes que viene, o súbelo en Estadísticas → Límite de gasto.", TokenLimits.short(limit))
    }
}

/// Qué pasa con el tope tras una petición.
public enum BudgetEvent: Equatable, Sendable {
    /// Pasó del 80 % del tope de ese periodo.
    case nearing(BudgetPeriod, used: Int, limit: Int)
    /// Llegó al tope: las siguientes peticiones se rechazan.
    case reached(BudgetPeriod, limit: Int)
}

/// Proveedor con tope de tokens: antes de cada petición mira lo gastado hoy y este mes, y después
/// avisa una sola vez por periodo al pasar del 80 % y al llegar al tope.
public struct BudgetedProvider: ModelProvider {
    let base: ModelProvider
    let store: SaySoStoring
    /// Modelos que no cuentan (los de cuentas locales).
    let excluded: Set<String>
    let onEvent: @Sendable (BudgetEvent) -> Void
    let now: @Sendable () -> Date

    public init(base: ModelProvider, store: SaySoStoring, excluded: Set<String> = [],
                now: @escaping @Sendable () -> Date = Date.init,
                onEvent: @escaping @Sendable (BudgetEvent) -> Void = { _ in }) {
        self.base = base
        self.store = store
        self.excluded = excluded
        self.now = now
        self.onEvent = onEvent
    }

    public var fullModel: String { base.fullModel }
    public var fastModel: String { base.fastModel }
    public var supportsImages: Bool { base.supportsImages }

    private var limits: TokenLimits {
        ((try? store.codableSetting(SettingsKey.tokenLimits)) ?? nil) ?? TokenLimits()
    }

    public func complete(_ request: ModelRequest) async throws -> ModelResponse {
        let limits = self.limits
        guard !limits.isEmpty else { return try await base.complete(request) }
        let date = now()
        let before = (try? store.tokenSpend(now: date, excluding: excluded)) ?? TokenSpend()
        if let period = before.reached(limits) {
            let limit = (period == .day ? limits.daily : limits.monthly) ?? 0
            notifyOnce(.reached(period, limit: limit), date: date)
            throw BudgetReachedError(period: period, limit: limit)
        }
        let response = try await base.complete(request)
        // TokenMeter apunta el gasto de esta petición en quien la hizo; aquí se cuenta aparte por
        // si aún no se ha guardado.
        var after = (try? store.tokenSpend(now: date, excluding: excluded)) ?? before
        if after == before {
            let used = (response.inputTokens ?? TokenMeter.estimate(request)) + (response.outputTokens ?? 0)
            after.today += used
            after.month += used
        }
        if let period = after.reached(limits) {
            notifyOnce(.reached(period, limit: (period == .day ? limits.daily : limits.monthly) ?? 0), date: date)
        } else if let period = after.nearing(limits) {
            let limit = (period == .day ? limits.daily : limits.monthly) ?? 0
            notifyOnce(.nearing(period, used: period == .day ? after.today : after.month, limit: limit), date: date)
        }
        return response
    }

    /// Un aviso de cada tipo por día o por mes.
    private func notifyOnce(_ event: BudgetEvent, date: Date) {
        let key = Self.notificationKey(event, date: date)
        // Los últimos avisos dados, separados por comas: así no se repiten aunque se alternen el
        // del día y el del mes.
        let given = (((try? store.setting(SettingsKey.budgetNotified)) ?? nil) ?? "").split(separator: ",").map(String.init)
        guard !given.contains(key) else { return }
        try? store.setSetting((given.suffix(7) + [key]).joined(separator: ","), for: SettingsKey.budgetNotified)
        onEvent(event)
    }

    static func notificationKey(_ event: BudgetEvent, date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        let month = String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
        switch event {
        case let .nearing(period, _, _):
            return "warn-\(period.rawValue)-" + (period == .day ? month + String(format: "-%02d", c.day ?? 0) : month)
        case let .reached(period, _):
            return "stop-\(period.rawValue)-" + (period == .day ? month + String(format: "-%02d", c.day ?? 0) : month)
        }
    }
}
