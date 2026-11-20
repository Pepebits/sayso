import Foundation

// Estadísticas de uso. Todo sale de la base de datos de este Mac.

/// Sumas de un periodo.
public struct UsageTotals: Hashable, Sendable {
    /// Llamadas al modelo de IA (agente y corrección del dictado).
    public var requests: Int
    /// Dictados que terminaron en texto.
    public var dictations: Int
    public var words: Int
    /// Segundos de audio dictado.
    public var seconds: Double

    public init(requests: Int = 0, dictations: Int = 0, words: Int = 0, seconds: Double = 0) {
        self.requests = requests
        self.dictations = dictations
        self.words = words
        self.seconds = seconds
    }

    public static func + (a: UsageTotals, b: UsageTotals) -> UsageTotals {
        UsageTotals(requests: a.requests + b.requests, dictations: a.dictations + b.dictations,
                    words: a.words + b.words, seconds: a.seconds + b.seconds)
    }
}

/// Uso de un día natural (zona horaria local).
public struct DayUsage: Hashable, Sendable, Identifiable {
    /// Medianoche del día.
    public var day: Date
    public var totals: UsageTotals
    public var id: Date { day }

    public init(day: Date, totals: UsageTotals = UsageTotals()) {
        self.day = day
        self.totals = totals
    }
}

/// Acciones del registro de actividad agrupadas por día, acción y resultado.
public struct ActionBucket: Hashable, Sendable {
    public var day: Date
    public var action: ActionID
    public var outcome: ActivityOutcome
    public var count: Int

    public init(day: Date, action: ActionID, outcome: ActivityOutcome, count: Int) {
        self.day = day
        self.action = action
        self.outcome = outcome
        self.count = count
    }
}

public struct UsageStats: Hashable, Sendable {
    /// Días seguidos, del más antiguo a hoy, con ceros donde no hubo uso.
    public var days: [DayUsage]
    /// Desde el primer día registrado.
    public var allTime: UsageTotals
    /// Primer día con algún dato; `nil` si aún no hay ninguno.
    public var firstDay: Date?
    /// Lo que queda en el registro de actividad dentro de `days`.
    public var actions: [ActionBucket]

    public init(days: [DayUsage] = [], allTime: UsageTotals = UsageTotals(), firstDay: Date? = nil,
                actions: [ActionBucket] = []) {
        self.days = days
        self.allTime = allTime
        self.firstDay = firstDay
        self.actions = actions
    }

    /// Los últimos `count` días (o los que haya).
    public func lastDays(_ count: Int) -> [DayUsage] { Array(days.suffix(max(count, 0))) }

    public func totals(lastDays count: Int) -> UsageTotals {
        lastDays(count).reduce(UsageTotals()) { $0 + $1.totals }
    }

    /// Acciones registradas en los últimos `count` días.
    public func actions(lastDays count: Int) -> [ActionBucket] {
        guard let first = lastDays(count).first?.day else { return [] }
        return actions.filter { $0.day >= first }
    }

    /// Palabras de un texto dictado: trozos separados por espacios o saltos de línea.
    public static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }
}
