import Foundation
import XCTest

@testable import TractandaCore

final class ReferenceLabelTests: XCTestCase {
    func testAdHocAndScopedLabelsSurviveRetypingAndRebuild() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(Identifier.make())
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ItemStore(root: root)
        let scope = try store.commit(
            CommitRequest(classID: "Item", changes: ["subject": .text("Project")], operationID: "scope")
        ).revision
        let labels = ItemValue.list([
            .object(["label": .text("A freely chosen label")]),
            .object([
                "scope": .reference(ItemReference(scope.itemID)), "label": .text("TRAC-040"),
                "future": .text("retain"),
            ]),
        ])
        let item = try store.commit(
            CommitRequest(classID: "Item", changes: ["referenceLabels": labels], operationID: "labels")
        ).revision
        XCTAssertEqual(ItemReferenceLabel.display(in: item), "A freely chosen label")
        XCTAssertEqual(ItemReferenceLabel.display(in: item, preferredScopes: [scope.itemID]), "TRAC-040")
        let changed = try store.commit(
            CommitRequest(
                action: .retype, itemID: item.itemID, expectedRevisionID: item.revisionID,
                classID: "EmailMessageItem", operationID: "retype")
        ).revision
        XCTAssertEqual(changed.itemID, item.itemID)
        XCTAssertEqual(changed.fields["referenceLabels"], labels)
        try store.rebuildIndex()
        XCTAssertEqual(try store.get(item.itemID).fields["referenceLabels"], labels)
    }
}
