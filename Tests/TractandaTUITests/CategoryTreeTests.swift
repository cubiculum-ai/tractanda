import Foundation
import TractandaCore
import XCTest

@testable import TractandaTUI

final class CategoryTreeTests: XCTestCase {
    private func category(_ number: Int, name: String? = nil, parents: [Revision] = []) throws -> Revision {
        try Revision(fields: [
            "itemID": .text(String(format: "%08x-0000-1000-8000-010000000001", number)),
            "revisionID": .text(String(format: "%08x-0000-1000-8001-010000000001", number)),
            "classID": .text("Item"), "schemaVersion": .integer(1),
            "actor": .text("fixture"), "operationID": .text("fixture-\(number)"),
            "requestIdentity": .text("fixture"), "createdAt": .date("2026-09-11T00:00:00Z"),
            "modifiedAt": .date("2026-09-11T00:00:00Z"),
            "subject": .text(name ?? String(format: "Category %06d", number)),
            "selection": .object(["expression": .text("itemID == *")]),
            "categoryParents": .list(parents.map { .reference(ItemReference($0.itemID)) }),
        ])
    }

    func testBroadRootListCanSeekBeyondFormerPlacementLimit() throws {
        let items = try (1...10_050).map { try category($0) }
        let tree = try CategoryTree(items.reversed())
        let rows = tree.rows(filter: "", expanded: tree.initialExpansion)
        XCTAssertEqual(rows.count, items.count)
        for index in [0, 63, 64, 9_999, 10_000, 10_049] {
            XCTAssertEqual(rows[index].path.map(\.itemID), [items[index].itemID])
            XCTAssertEqual(rows.index(ofPath: [items[index].itemID]), index)
        }
        XCTAssertEqual(rows.suffix(20).map(\.item), Array(items.suffix(20)))
        let matches = tree.rows(filter: "010050", expanded: [])
        XCTAssertEqual(matches.map(\.item), [items.last!])
    }

    func testDenseGraphDoesNotEnumerateBillionsOfPathsAndSearchReachesEveryNode() throws {
        let root = try category(1)
        var items = [root]
        var parents = [root]
        var path = [root.itemID]
        // 63 nodes; eagerly expanding every route would produce 2^32 - 1 placements.
        for _ in 1..<32 {
            let pair = try (1...2).map { try category(items.count + $0, parents: parents) }
            items += pair
            parents = pair
            path.append(pair.last!.itemID)
        }
        let tree = try CategoryTree(items)
        let initial = tree.rows(filter: "", expanded: tree.initialExpansion)
        XCTAssertEqual(initial.count, 3)
        XCTAssertFalse(initial[1].isExpanded)
        var expanded = tree.initialExpansion
        for depth in 2..<path.count {
            expanded.insert(path.prefix(depth).joined(separator: "/"))
        }
        let opened = tree.rows(filter: "", expanded: expanded)
        XCTAssertEqual(opened.count, 63)
        XCTAssertEqual(opened.last?.path.map(\.itemID), path)
        XCTAssertEqual(opened.index(ofPath: path), 62)
        let allMatches = tree.rows(filter: "Category", expanded: [])
        XCTAssertEqual(allMatches.count, items.count)
        XCTAssertEqual(Set(allMatches.map { $0.item.itemID }), Set(items.map(\.itemID)))
        let last = tree.rows(filter: "000063", expanded: [])
        XCTAssertEqual(last.last?.item.itemID, items.last?.itemID)
        XCTAssertEqual(last.count, 32)
        XCTAssertTrue(tree.rows(filter: "absent", expanded: []).isEmpty)
    }

    func testExpansionIsPerPlacementAndSearchUsesPreferredReadablePath() throws {
        let a = try category(1, name: "A")
        let b = try category(2, name: "B")
        let shared = try category(3, name: "Shared", parents: [a, b])
        let leaf = try category(4, name: "Leaf", parents: [shared])
        let path = [b, shared].map(\.itemID)
        let tree = try CategoryTree([leaf, shared, b, a], preferredPath: path)
        var expanded = tree.initialExpansion
        expanded.insert(path.joined(separator: "/"))
        let rows = tree.rows(filter: "", expanded: expanded)
        XCTAssertEqual(rows.count, 5)
        XCTAssertFalse(rows[1].isExpanded)
        XCTAssertTrue(rows[3].isExpanded)
        XCTAssertEqual(rows[4].path.map(\.itemID), path + [leaf.itemID])
        let result = tree.rows(filter: "Leaf", expanded: [])
        XCTAssertEqual(result.map(\.item), [b, shared, leaf])
        XCTAssertNil(result.index(ofPath: [a.itemID, shared.itemID]))
        expanded.remove(b.itemID)
        XCTAssertEqual(tree.rows(filter: "", expanded: expanded).count, 3)
    }

    func testHiddenAndDeletedParentsDoNotHideReadableDescendants() throws {
        let hidden = try category(1, name: "Private parent")
        let removed = try category(2, name: "Deleted parent")
        let deleted = try Revision(
            fields: removed.fields.merging(["isDeleted": .boolean(true)]) { _, b in b })
        let child = try category(3, name: "Accessible", parents: [hidden, removed])
        let tree = try CategoryTree([child, deleted], preferredPath: [hidden.itemID, child.itemID])
        let rows = tree.rows(filter: "Accessible", expanded: [])
        XCTAssertEqual(rows.map(\.item), [child])
        XCTAssertEqual(rows[0].path.map(\.itemID), [child.itemID])
        XCTAssertTrue(tree.rows(filter: "Private", expanded: []).isEmpty)
        XCTAssertTrue(tree.rows(filter: "Deleted", expanded: []).isEmpty)
    }

    func testCycleStillFailsBeforeProjection() throws {
        let a = try category(1)
        let b = try category(2, parents: [a])
        let cyclic = try Revision(
            fields: a.fields.merging([
                "categoryParents": .list([.reference(ItemReference(b.itemID))])
            ]) { _, b in b })
        XCTAssertThrowsError(try CategoryTree([cyclic, b])) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "categoryCycle")
        }
    }
}
