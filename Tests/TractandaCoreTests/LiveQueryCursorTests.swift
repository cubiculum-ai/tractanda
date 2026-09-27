import XCTest

@testable import TractandaCore

final class LiveQueryCursorTests: XCTestCase {
    func testCursorTokenIsEncryptedAuthenticatedAndVersioned() throws {
        let cursor = LiveQueryCursor(
            domain: LiveQueryCursor.tokenDomain, version: 1,
            storeID: "uuidv1:/private/path/store", actorUID: 42, queryDigest: "query",
            state: "visible-state", orderField: "modifiedAt", boundary: 123.5,
            boundaryID: "00000000-0000-1000-8000-000000000001", position: 8,
            totalReference: "server-total-reference", previous: false,
            evaluatedAt: "2026-09-27T12:34:56.123456Z", timeZone: "Europe/Vienna")
        let token = try LiveQueryCursor.encode(cursor)
        XCTAssertFalse(token.contains("private"))
        let decoded = try LiveQueryCursor.decode(token)
        XCTAssertEqual(decoded.storeID, cursor.storeID)
        XCTAssertEqual(decoded.actorUID, cursor.actorUID)
        XCTAssertEqual(decoded.boundary, cursor.boundary)
        XCTAssertEqual(decoded.position, cursor.position)
        XCTAssertEqual(decoded.evaluatedAt, cursor.evaluatedAt)
        let tampered = String(token.dropLast()) + (token.last == "A" ? "B" : "A")
        XCTAssertThrowsError(try LiveQueryCursor.decode(tampered))
        XCTAssertThrowsError(try LiveQueryCursor.decode(String(repeating: "A", count: 8_193))) { error in
            XCTAssertEqual((error as? TractandaError)?.code, "invalidCursor")
        }
        let unsupported = LiveQueryCursor(
            domain: cursor.domain, version: 2, storeID: cursor.storeID, actorUID: cursor.actorUID,
            queryDigest: cursor.queryDigest, state: cursor.state,
            orderField: cursor.orderField, boundary: cursor.boundary,
            boundaryID: cursor.boundaryID, position: cursor.position,
            totalReference: cursor.totalReference, previous: cursor.previous,
            evaluatedAt: cursor.evaluatedAt, timeZone: cursor.timeZone)
        XCTAssertThrowsError(try LiveQueryCursor.decode(LiveQueryCursor.encode(unsupported)))
    }

    func testExactTotalReferencesAreBoundedAndScoped() {
        let storeID = "store-instance"
        let first = LiveQueryCursor.retainTotal(
            total: 7, storeID: storeID, actorUID: 42, queryDigest: "query", state: "state")
        XCTAssertEqual(
            LiveQueryCursor.exactTotal(
                reference: first, storeID: storeID, actorUID: 42, queryDigest: "query", state: "state"),
            7)
        XCTAssertNil(
            LiveQueryCursor.exactTotal(
                reference: first, storeID: storeID, actorUID: 43, queryDigest: "query", state: "state"))
        for index in 0..<256 {
            _ = LiveQueryCursor.retainTotal(
                total: index, storeID: storeID, actorUID: 42,
                queryDigest: "query-\(index)", state: "state")
        }
        XCTAssertNil(
            LiveQueryCursor.exactTotal(
                reference: first, storeID: storeID, actorUID: 42, queryDigest: "query", state: "state"))
    }
}
