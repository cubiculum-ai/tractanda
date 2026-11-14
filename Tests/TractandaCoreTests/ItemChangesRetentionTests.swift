import XCTest

@testable import TractandaCore

final class ItemChangesRetentionTests: XCTestCase {
    private func fixture(_ body: (ItemIndex, String) throws -> Void) throws {
        let index = try ItemIndex(path: ":memory:", create: true)
        defer { index.close() }
        index.personalContentProjectionMode = true
        try body(index, index.reconcileItemChanges(projection: true).epoch)
    }
    private func token(_ id: String, epoch: String, at: Double, plan: String? = nil) -> ItemIndex.ChangeToken
    {
        .init(
            token: id, epoch: epoch, sequence: 0, scope: "fixture", users: [:], groups: [:],
            planID: plan, position: 0, issuedAt: at)
    }
    private func code(_ expected: String, _ body: () throws -> Void) {
        XCTAssertThrowsError(try body()) { XCTAssertEqual(($0 as? TractandaError)?.code, expected, "\($0)") }
    }
    func testTokenCountEvictionRetainsJustSavedOldestState() throws {
        try fixture { index, epoch in
            index.itemChangeTokenRowsLimitForTesting = 2
            try index.saveItemChangeToken(token("older", epoch: epoch, at: 2))
            try index.saveItemChangeToken(token("newer", epoch: epoch, at: 3))
            try index.saveItemChangeToken(token("saved-oldest", epoch: epoch, at: 1))
            XCTAssertNotNil(try index.itemChangeToken("saved-oldest"))
            XCTAssertNotNil(try index.itemChangeToken("newer"))
            XCTAssertNil(try index.itemChangeToken("older"))
        }
    }
    func testTokenByteEvictionRetainsJustSavedOldestState() throws {
        try fixture { index, epoch in
            let older = token("older", epoch: epoch, at: 2)
            let newer = token("newer", epoch: epoch, at: 3)
            let saved = token("saved-oldest", epoch: epoch, at: 1)
            index.itemChangeTokenBytesLimitForTesting =
                try JSON.encode(newer).count + JSON.encode(saved).count
            try index.saveItemChangeToken(older)
            try index.saveItemChangeToken(newer)
            try index.saveItemChangeToken(saved)
            XCTAssertNotNil(try index.itemChangeToken(saved.token))
            XCTAssertNotNil(try index.itemChangeToken(newer.token))
            XCTAssertNil(try index.itemChangeToken(older.token))
        }
    }
    func testIntermediateSaveProtectsRequiredTargetOrFailsAtomically() throws {
        try fixture { index, epoch in
            index.itemChangeTokenRowsLimitForTesting = 2
            try index.saveItemChangeToken(token("target", epoch: epoch, at: 1))
            try index.saveItemChangeToken(token("source", epoch: epoch, at: 2))
            try index.saveItemChangeToken(
                token("intermediate", epoch: epoch, at: 3, plan: "plan"), protecting: ["target"])
            XCTAssertNotNil(try index.itemChangeToken("target"))
            XCTAssertNotNil(try index.itemChangeToken("intermediate"))
            XCTAssertNil(try index.itemChangeToken("source"))
            code("cannotCalculateChanges") {
                try index.saveItemChangeToken(
                    token("impossible", epoch: epoch, at: 4), protecting: ["target", "intermediate"])
            }
            XCTAssertNil(try index.itemChangeToken("impossible"))
            XCTAssertNotNil(try index.itemChangeToken("target"))
            XCTAssertNotNil(try index.itemChangeToken("intermediate"))
        }
    }
    func testPlanCountAndByteEvictionRetainJustSavedOldestPlan() throws {
        for byteLimit in [false, true] {
            try fixture { index, epoch in
                let item = Identifier.make()
                let entry = ItemIndex.ChangePlanEntry(itemID: item, kind: "created")
                func save(_ id: String, at: Double) throws {
                    try index.saveItemChangePlan(
                        .init(
                            id: id, epoch: epoch, scope: "fixture", base: 0, target: 0,
                            targetToken: "target", count: 1, issuedAt: at), entries: [entry])
                }
                if byteLimit {
                    index.itemChangePlanBytesLimitForTesting =
                        2 * (256 + item.utf8.count + "created".utf8.count + 64)
                } else {
                    index.itemChangePlanRowsLimitForTesting = 2
                }
                try save("older", at: 2)
                try save("newer", at: 3)
                try save("saved-oldest", at: 1)
                XCTAssertNotNil(try index.itemChangePlan("saved-oldest"))
                XCTAssertNotNil(try index.itemChangePlan("newer"))
                XCTAssertNil(try index.itemChangePlan("older"))
            }
        }
    }
    func testMalformedPlanKindCannotSilentlyAdvancePastIdentifier() throws {
        try fixture { index, epoch in
            let plan = ItemIndex.ChangePlan(
                id: "plan", epoch: epoch, scope: "fixture", base: 0, target: 0,
                targetToken: "target", count: 1, issuedAt: 1)
            try index.saveItemChangePlan(plan, entries: [.init(itemID: Identifier.make(), kind: "unknown")])
            code("cannotCalculateChanges") { _ = try index.itemChangePlanPage(plan, position: 0, limit: 1) }
        }
    }
}
