import XCTest

@testable import TractandaCore

final class SavedViewCapabilityTests: XCTestCase {
    private func definition() -> ItemValue {
        .object(["language": .text(SpotlightQuery.profile)])
    }

    private func revise(
        _ store: ItemStore, _ base: Revision, changes: [String: ItemValue] = [:], unset: [String] = []
    ) throws -> Revision {
        try store.commit(
            CommitRequest(
                action: .revise, itemID: base.itemID, expectedRevisionID: base.revisionID,
                changes: changes, unset: unset, operationID: Identifier.make())
        ).revision
    }

    func testViewDefinitionIsAnOptionalCapabilityAcrossItemClasses() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(Identifier.make())
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ItemStore(root: directory)

        let note = try store.commit(
            CommitRequest(classID: "Item", changes: ["subject": .text("Note")], operationID: "note")
        ).revision
        let plainNote = ItemTypes.makeItem(from: note)
        XCTAssertTrue(type(of: plainNote) == Item.self)
        XCTAssertNil(try plainNote.viewDefinition)

        let viewNote = try revise(store, note, changes: ["viewDefinition": definition()])
        let typedNote = ItemTypes.makeItem(from: viewNote)
        XCTAssertTrue(type(of: typedNote) == Item.self)
        XCTAssertEqual(typedNote.revision.itemID, note.itemID)
        XCTAssertEqual(typedNote.revision.classID, "Item")
        XCTAssertEqual(try typedNote.viewDefinition?.presentation.columns, ViewPresentation.defaultColumns)

        let restoredNote = try revise(store, viewNote, unset: ["viewDefinition"])
        XCTAssertEqual(restoredNote.itemID, note.itemID)
        XCTAssertEqual(restoredNote.classID, "Item")
        XCTAssertNil(try ItemTypes.makeItem(from: restoredNote).viewDefinition)

        let role = try store.commit(
            CommitRequest(
                classID: "RoleItem", changes: ["subject": .text("Role"), "viewDefinition": definition()],
                operationID: "role")
        ).revision
        XCTAssertTrue(ItemTypes.makeItem(from: role) is RoleItem)
        XCTAssertNotNil(try ItemTypes.makeItem(from: role).viewDefinition)

        let project = try store.commit(
            CommitRequest(
                classID: "org.example.ProjectItem",
                changes: ["project": .text("Tractanda"), "viewDefinition": definition()],
                operationID: "project")
        ).revision
        let genericProject = ItemTypes.makeItem(from: project)
        XCTAssertTrue(type(of: genericProject) == Item.self)
        XCTAssertEqual(genericProject.revision.classID, "org.example.ProjectItem")
        XCTAssertNotNil(try genericProject.viewDefinition)
    }

    func testLegacySavedViewItemRecordLoadsAsGenericItemAndStillExecutes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(Identifier.make())
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ItemStore(root: directory)
        let legacy = try store.commit(
            CommitRequest(
                classID: "SavedViewItem",
                changes: ["subject": .text("Legacy"), "viewDefinition": definition()],
                operationID: "legacy")
        ).revision

        let decoded = try RecordCodec.decode(RecordCodec.encode(legacy))
        let item = ItemTypes.makeItem(from: decoded)
        XCTAssertTrue(type(of: item) == Item.self)
        XCTAssertEqual(item.revision.classID, "SavedViewItem")
        XCTAssertNotNil(try item.viewDefinition)
        XCTAssertEqual(
            try Categories.savedView(store: store, id: legacy.itemID).map(\.itemID), [legacy.itemID])
    }
}
