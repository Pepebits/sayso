import Foundation
@testable import SaySoTDLib
import XCTest

final class TDTransportTests: XCTestCase {
    /// Al cerrar la app el hilo que escucha a TDLib tiene que salir enseguida, y poder volver a
    /// arrancar si se crea otro transporte.
    func testReceiverStopsQuicklyAndCanStartAgain() {
        for _ in 0..<2 {
            let transport = TDLibTransport()
            let started = Date()
            TDLibTransport.stopReceiving(timeout: 3)
            XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
            transport.close()
        }
        // Sin hilo en marcha no espera nada.
        let started = Date()
        TDLibTransport.stopReceiving(timeout: 3)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.2)
    }

    func testUnusedUpdatesAreSkippedBeforeParsing() {
        XCTAssertEqual(TDUpdateFilter.leadingType(#"{"@type":"updateChatReadInbox","chat_id":1,"@client_id":1}"#), "updateChatReadInbox")
        XCTAssertFalse(TDUpdateFilter.isWanted("updateChatReadInbox"))
        XCTAssertFalse(TDUpdateFilter.isWanted("updateUserStatus"))
        XCTAssertTrue(TDUpdateFilter.isWanted("updateNewMessage"))
        XCTAssertTrue(TDUpdateFilter.isWanted("chats"), "las respuestas pasan siempre")
        XCTAssertTrue(TDUpdateFilter.isWanted("error"))
        XCTAssertNil(TDUpdateFilter.leadingType(#"{"chat_id":1,"@type":"x"}"#), "si no va primero, se analiza entero")
    }
}
