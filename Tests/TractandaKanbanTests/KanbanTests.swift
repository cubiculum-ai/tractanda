import Foundation
import TractandaCore
import XCTest

@testable import TractandaKanban

final class KanbanTests: XCTestCase {
    private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "category-board-" + Identifier.make())
        let store: ItemStore
        let client: ItemClient
        init() throws {
            store = try ItemStore(root: root)
            let service = ItemService(store: store)
            let uid = store.ownerUID
            client = ItemClient(transport: { service.handle($0, peerUID: uid) })
        }
        deinit { try? FileManager.default.removeItem(at: root) }
        func item(_ name: String, type: String = "Item", fields: [String: ItemValue] = [:]) throws
            -> Revision
        {
            try client.commit(
                CommitRequest(
                    classID: type, changes: fields.merging(["subject": .text(name)]) { _, b in b },
                    operationID: Identifier.make())
            ).revision
        }
        func category(_ name: String, parents: [Revision] = []) throws -> Revision {
            try item(
                name,
                fields: [
                    "selection": .object([
                        "language": .text(SpotlightQuery.profile), "expression": .text("itemID == \"\""),
                    ]), "categoryParents": .list(parents.map { .reference(ItemReference($0.itemID)) }),
                ])
        }
        func view(_ project: Revision, _ status: Revision, _ columns: [Revision]) throws -> Revision {
            try item(
                "A category view",
                fields: [
                    "viewDefinition": .object([
                        "language": .text(SpotlightQuery.profile),
                        "categoryPath": .list(
                            [project, status].map { .reference(ItemReference($0.itemID)) }),
                        "presentation": .object([
                            "profile": .text(ViewPresentation.profile),
                            "sections": .list(columns.map { .reference(ItemReference($0.itemID)) }),
                        ]),
                    ])
                ])
        }
        func assigned(
            _ name: String, type: String = "Item", categories: [Revision],
            extra: [String: ItemValue] = [:]
        ) throws -> Revision {
            try item(
                name, type: type,
                fields: extra.merging([
                    "categoryOverrides": .object(
                        Dictionary(uniqueKeysWithValues: categories.map { ($0.itemID, .text("include")) }))
                ]) { _, b in b })
        }
    }

    func testViewUsesCategoriesAndAcceptsEveryItemTypeWithoutKanbanMetadata() throws {
        let f = try Fixture()
        let project = try f.category("Project")
        let status = try f.category("Status")
        let ready = try f.category("Ready", parents: [status])
        let completed = try f.category("Completed", parents: [status])
        let view = try f.view(project, status, [ready, completed])
        let email = try f.assigned("An email", type: "EmailMessageItem", categories: [project, ready])
        let note = try f.assigned("A note", categories: [project, completed])
        _ = try f.assigned("Outside project", categories: [ready])
        _ = try f.assigned("Without status", categories: [project])
        let state = f.store.state
        let snapshot = try KanbanRepository(client: f.client).snapshot(for: view.itemID)
        let tasks = try XCTUnwrap(snapshot["tasks"]?.arrayValue)
        XCTAssertEqual(
            Set(tasks.compactMap { $0.objectValue?["id"]?.stringValue }), [email.itemID, note.itemID])
        XCTAssertEqual(
            tasks.first { $0.objectValue?["id"] == .string(email.itemID) }?.objectValue?["categoryIDs"],
            .array([.string(ready.itemID)]))
        XCTAssertEqual(f.store.state, state)
        XCTAssertNil(email.fields["status"])
        XCTAssertNil(note.fields["status"])
    }

    func testMultipleColumnMembershipAndUnassignedRowsArePreserved() throws {
        let f = try Fixture()
        let project = try f.category("Project")
        let status = try f.category("Status")
        let a = try f.category("One", parents: [status])
        let b = try f.category("Two", parents: [status])
        let view = try f.view(project, status, [a, b])
        let shared = try f.assigned("Both", categories: [project, a, b])
        let rootOnly = try f.assigned("Status but no displayed child", categories: [project, status])
        let snapshot = try KanbanRepository(client: f.client).snapshot(for: view.itemID)
        let tasks = snapshot["tasks"]!.arrayValue!.compactMap(\.objectValue)
        XCTAssertEqual(
            tasks.first { $0["id"] == .string(shared.itemID) }?["categoryIDs"],
            .array([.string(a.itemID), .string(b.itemID)]))
        XCTAssertEqual(tasks.first { $0["id"] == .string(rootOnly.itemID) }?["categoryIDs"], .array([]))
    }

    func testRenameRebuildAndVersionedCategoryMoveKeepIdentityAndOtherDimensions() throws {
        let f = try Fixture()
        let project = try f.category("Project")
        let status = try f.category("Status")
        let person = try f.category("Person")
        let a = try f.category("One", parents: [status])
        let b = try f.category("Two", parents: [status])
        let view = try f.view(project, status, [a, b])
        let original = try f.assigned(
            "Tracked note", categories: [project, a, person],
            extra: [
                "referenceLabels": .list([
                    .object(["scope": .reference(ItemReference(project.itemID)), "label": .text("TEST-42")])
                ]), "foreign": .bytes(Data([1, 2, 3])),
            ])
        var assignments = original.fields["categoryOverrides"]!.map!
        assignments[a.itemID] = .text("exclude")
        assignments[b.itemID] = .text("include")
        let moved = try f.client.commit(
            CommitRequest(
                action: .revise, itemID: original.itemID, expectedRevisionID: original.revisionID,
                changes: ["categoryOverrides": .object(assignments)], operationID: "move-category"))
        _ = try f.client.commit(
            CommitRequest(
                action: .revise, itemID: b.itemID, expectedRevisionID: b.revisionID,
                changes: ["subject": .text("Renamed")], operationID: "rename-category"))
        let repository = KanbanRepository(client: f.client)
        let before = try repository.snapshot(for: view.itemID)
        _ = try f.client.call("TractandaStore/rebuild")
        var after = try repository.snapshot(for: view.itemID)
        var comparison = before
        after.removeValue(forKey: "serverState")
        comparison.removeValue(forKey: "serverState")
        after.removeValue(forKey: "updatedAt")
        comparison.removeValue(forKey: "updatedAt")
        XCTAssertEqual(after, comparison)
        XCTAssertEqual(moved.revision.itemID, original.itemID)
        XCTAssertEqual(moved.revision.fields["foreign"], original.fields["foreign"])
        XCTAssertEqual(moved.revision.fields["categoryOverrides"]?.map?[person.itemID], .text("include"))
        XCTAssertEqual(try f.store.history(original.itemID).count, 2)
        XCTAssertEqual(before["tasks"]?.arrayValue?.first?.objectValue?["reference"], .string("TEST-42"))
        XCTAssertEqual(before["columns"]?.arrayValue?.last?.objectValue?["name"], .string("Renamed"))
    }

    func testOrdinaryViewNeedsSectionsAndDoesNotRequireASpecialClass() throws {
        let f = try Fixture()
        let plain = try f.item("Plain")
        XCTAssertThrowsError(try KanbanRepository(client: f.client).snapshot(for: plain.itemID))
        let empty = try f.item(
            "Empty view", fields: ["viewDefinition": .object(["language": .text(SpotlightQuery.profile)])])
        XCTAssertThrowsError(try KanbanRepository(client: f.client).snapshot(for: empty.itemID))
    }

    func testSeparateProjectViewsKeepTheirOwnColumnsAndCaptureDefaults() throws {
        let f = try Fixture()
        let alpha = try f.category("Alpha")
        let beta = try f.category("Beta")
        let status = try f.category("Status")
        let ready = try f.category("Ready", parents: [status])
        let review = try f.category("Review", parents: [status])
        let alphaView = try f.item(
            "Alpha board",
            fields: [
                "viewDefinition": .object([
                    "language": .text(SpotlightQuery.profile),
                    "categoryPath": .list([.reference(ItemReference(alpha.itemID))]),
                    "presentation": .object([
                        "profile": .text(ViewPresentation.profile),
                        "sections": .list([.reference(ItemReference(ready.itemID))]),
                    ]),
                ]),
                "captureCategories": .list([.reference(ItemReference(alpha.itemID))]),
                "defaultCategory": .reference(ItemReference(ready.itemID)),
            ])
        let betaView = try f.item(
            "Beta board",
            fields: [
                "viewDefinition": .object([
                    "language": .text(SpotlightQuery.profile),
                    "categoryPath": .list([.reference(ItemReference(beta.itemID))]),
                    "presentation": .object([
                        "profile": .text(ViewPresentation.profile),
                        "sections": .list([.reference(ItemReference(review.itemID))]),
                    ]),
                ]),
                "captureCategories": .list([.reference(ItemReference(beta.itemID))]),
                "defaultCategory": .reference(ItemReference(review.itemID)),
            ])
        let shared = try f.assigned("Shared status", categories: [alpha, beta, ready, review])
        let repository = KanbanRepository(client: f.client)
        let alphaSnapshot = try repository.snapshot(for: alphaView.itemID)
        let betaSnapshot = try repository.snapshot(for: betaView.itemID)
        XCTAssertEqual(alphaSnapshot["columns"]?.arrayValue?.first?.objectValue?["id"], .string(ready.itemID))
        XCTAssertEqual(betaSnapshot["columns"]?.arrayValue?.first?.objectValue?["id"], .string(review.itemID))
        XCTAssertEqual(alphaSnapshot["captureCategoryIDs"], .array([.string(alpha.itemID)]))
        XCTAssertEqual(betaSnapshot["captureCategoryIDs"], .array([.string(beta.itemID)]))
        XCTAssertEqual(alphaSnapshot["defaultCategoryID"], .string(ready.itemID))
        XCTAssertEqual(betaSnapshot["defaultCategoryID"], .string(review.itemID))
        XCTAssertEqual(alphaSnapshot["tasks"]?.arrayValue?.first?.objectValue?["id"], .string(shared.itemID))
        XCTAssertEqual(betaSnapshot["tasks"]?.arrayValue?.first?.objectValue?["id"], .string(shared.itemID))
    }

    func testProjectBoardUsesOrdinaryProjectAndStatusCategoriesWithoutAnySavedView() throws {
        let f = try Fixture()
        let projects = try f.category("Projects")
        let alpha = try f.category("Alpha", parents: [projects])
        let beta = try f.category("Beta", parents: [projects])
        let status = try f.category("Status")
        let ready = try f.category("Ready", parents: [status])
        let done = try f.category("Done", parents: [status])
        let workstream = try f.category("Workstream")
        let alphaReady = try f.assigned("Alpha ready", categories: [alpha, status, ready, workstream])
        let alphaDone = try f.assigned("Alpha done", categories: [alpha, status, done])
        let betaReady = try f.assigned("Beta ready", categories: [beta, status, ready])
        let rootOnly = try f.assigned("Status root only", categories: [alpha, status])
        _ = try f.assigned("No status", categories: [alpha])
        _ = try f.client.commit(
            CommitRequest(
                action: .revise, itemID: alpha.itemID, expectedRevisionID: alpha.revisionID,
                changes: ["filterCategories": .list([.reference(ItemReference(workstream.itemID))])],
                operationID: "alpha-filter"))
        let snapshot = try KanbanRepository(client: f.client).projectSnapshot(
            projectID: alpha.itemID, projectRootID: projects.itemID, statusRootID: status.itemID)
        let tasks = snapshot["tasks"]!.arrayValue!.compactMap(\.objectValue)
        XCTAssertEqual(
            Set(tasks.compactMap { $0["id"]?.stringValue }),
            [alphaReady.itemID, alphaDone.itemID, rootOnly.itemID])
        XCTAssertFalse(tasks.contains { $0["id"] == .string(betaReady.itemID) })
        XCTAssertEqual(
            snapshot["columns"]?.arrayValue?.compactMap { $0.objectValue?["id"]?.stringValue },
            [done.itemID, ready.itemID])
        XCTAssertEqual(snapshot["filters"]?.arrayValue?.first?.objectValue?["id"], .string(workstream.itemID))
        XCTAssertEqual(
            tasks.first { $0["id"] == .string(alphaReady.itemID) }?["filterCategoryIDs"],
            .array([.string(workstream.itemID)]))
        XCTAssertEqual(tasks.first { $0["id"] == .string(rootOnly.itemID) }?["categoryIDs"], .array([]))
    }

    func testProjectCatalogKeepsAllProjectsAndReadableDescendantPathsStableAcrossRebuild() throws {
        let f = try Fixture()
        let projects = try f.category("Projects")
        let client = try f.category("Client", parents: [projects])
        let alpha = try f.category("Alpha", parents: [client])
        let repository = KanbanRepository(client: f.client)
        let before = try repository.projects(projectRootID: projects.itemID)
        XCTAssertEqual(before.map { $0["id"]?.stringValue }, [projects.itemID, client.itemID, alpha.itemID])
        XCTAssertEqual(before.first?["name"], .string("All projects"))
        XCTAssertEqual(before.last?["name"], .string("Projects / Client / Alpha"))
        _ = try f.client.call("TractandaStore/rebuild")
        XCTAssertEqual(try repository.projects(projectRootID: projects.itemID), before)
    }

    func testProjectSpecificStatusDefaultsOverrideStatusRootAndAreValidated() throws {
        let f = try Fixture()
        let projects = try f.category("Projects")
        let alpha = try f.category("Alpha", parents: [projects])
        let status = try f.category("Status")
        let ready = try f.category("Ready", parents: [status])
        let done = try f.category("Done", parents: [status])
        let invalid = try f.category("Other")
        _ = try f.client.commit(
            CommitRequest(
                action: .revise, itemID: status.itemID, expectedRevisionID: status.revisionID,
                changes: [
                    "defaultCategory": .reference(ItemReference(ready.itemID)),
                    "completionCategory": .reference(ItemReference(done.itemID)),
                ],
                operationID: "status-defaults"))
        let alphaCurrent = try f.client.revision(for: alpha.itemID)
        _ = try f.client.commit(
            CommitRequest(
                action: .revise, itemID: alpha.itemID, expectedRevisionID: alphaCurrent.revisionID,
                changes: [
                    "defaultCategory": .reference(ItemReference(done.itemID)),
                    "completionCategory": .reference(ItemReference(invalid.itemID)),
                ],
                operationID: "project-defaults"))
        let snapshot = try KanbanRepository(client: f.client).projectSnapshot(
            projectID: alpha.itemID, projectRootID: projects.itemID, statusRootID: status.itemID)
        XCTAssertEqual(snapshot["defaultCategoryID"], .string(done.itemID))
        XCTAssertEqual(snapshot["completionCategoryID"], .string(done.itemID))
        XCTAssertEqual(snapshot["captureCategoryIDs"], .array([.string(alpha.itemID)]))
    }
}
