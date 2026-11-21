import Foundation
@testable import SaySoAgent
import SaySoCore
import XCTest

/// Gasto que devuelve `MemoryStore` en estas pruebas.
enum TestSpend {
    static let value = Locked(TokenSpend())
}

extension MemoryStore {
    func tokenSpend(now: Date, excluding models: Set<String>) throws -> TokenSpend { TestSpend.value.get() }
}

final class BudgetTests: XCTestCase {
    private let reply = ModelResponse(content: [.text("ok")], stopReason: .endTurn, inputTokens: 100, outputTokens: 50)
    private let request = ModelRequest(model: "m", system: "", messages: [.user("hola")])

    override func tearDown() { TestSpend.value.set(TokenSpend()) }

    private func provider(_ store: MemoryStore, events: Locked<[BudgetEvent]>) -> BudgetedProvider {
        BudgetedProvider(base: FakeProvider([], fallback: reply), store: store) { event in events.update { $0.append(event) } }
    }

    func testWithoutLimitsEverythingPasses() async throws {
        let store = MemoryStore()
        TestSpend.value.set(TokenSpend(today: 10_000_000, month: 10_000_000))
        let events = Locked<[BudgetEvent]>([])
        _ = try await provider(store, events: events).complete(request)
        XCTAssertEqual(events.get(), [])
    }

    func testRefusesOnceTheDailyLimitIsReachedAndNotifiesOnce() async throws {
        let store = MemoryStore()
        try store.setCodableSetting(TokenLimits(daily: 1000), for: SettingsKey.tokenLimits)
        TestSpend.value.set(TokenSpend(today: 1000, month: 1000))
        let events = Locked<[BudgetEvent]>([])
        let p = provider(store, events: events)
        for _ in 0..<2 {
            do {
                _ = try await p.complete(request)
                XCTFail("debería rechazar")
            } catch let error as BudgetReachedError {
                XCTAssertEqual(error, BudgetReachedError(period: .day, limit: 1000))
            }
        }
        XCTAssertEqual(events.get(), [.reached(.day, limit: 1000)])
    }

    func testWarnsAtEightyPercentOnce() async throws {
        let store = MemoryStore()
        try store.setCodableSetting(TokenLimits(daily: 1000, monthly: 100_000), for: SettingsKey.tokenLimits)
        TestSpend.value.set(TokenSpend(today: 850, month: 850))
        let events = Locked<[BudgetEvent]>([])
        let p = provider(store, events: events)
        _ = try await p.complete(request)
        _ = try await p.complete(request)
        // La petición suma 150 (100 + 50): 1000, llega al tope.
        XCTAssertEqual(events.get(), [.reached(.day, limit: 1000)])

        TestSpend.value.set(TokenSpend(today: 700, month: 700))
        try store.setSetting(nil, for: SettingsKey.budgetNotified)
        events.set([])
        _ = try await p.complete(request)
        _ = try await p.complete(request)
        XCTAssertEqual(events.get(), [.nearing(.day, used: 850, limit: 1000)])
    }

    func testSpendHelpers() {
        let limits = TokenLimits(daily: 100, monthly: 1000)
        XCTAssertEqual(TokenSpend(today: 100, month: 100).reached(limits), .day)
        XCTAssertEqual(TokenSpend(today: 10, month: 1000).reached(limits), .month)
        XCTAssertNil(TokenSpend(today: 79, month: 0).nearing(limits))
        XCTAssertEqual(TokenSpend(today: 80, month: 0).nearing(limits), .day)
        XCTAssertEqual(TokenLimits.short(500_000), "500 k")
        XCTAssertEqual(TokenLimits.short(2_000_000), "2 M")
    }
}
