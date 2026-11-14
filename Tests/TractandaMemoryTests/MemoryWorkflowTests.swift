import CTractandaPlatform
import Foundation
import XCTest

@testable import TractandaCore
@testable import TractandaMemory

final class MemoryWorkflowTests: XCTestCase {
    func testRecallSkipsIncompleteImportsAndRejectsIncompleteProfile() throws {
        let fixture = try MemoryImportFixture()
        func create(_ fields: [String: ItemValue]) throws -> Revision {
            try fixture.store.commit(.init(classID: "Item", changes: fields, operationID: Identifier.make()))
                .revision
        }
        let profile = try create(["subject": .text("profile")])
        let checkpoint = try create(["subject": .text("checkpoint")])
        let complete = try create([
            "subject": .text("complete import"), "importSchema": .text(ImportFields.schema),
            "importState": .text("complete"), "importSourceID": .text("source-a"),
        ])
        let incomplete = try create([
            "subject": .text("incomplete import"), "importSchema": .text(ImportFields.schema),
            "importState": .text("incomplete"),
        ])
        let unrelated = try create([
            "subject": .text("ordinary item"), "importState": .text("incomplete"),
        ])
        let selected = try CoreImportTransport(client: fixture.client, endpoint: "peer").binding()
        let binding = MemoryWorkflowBinding(
            storeID: selected.storeID, profileItemID: profile.itemID, checkpointItemID: checkpoint.itemID)
        let workflow = MemoryWorkflow(client: fixture.client, endpoint: "peer")
        for fields in [["subject"], ["subject", "importSourceID"]] {
            let recall = try workflow.recall(binding, fields: fields)
            let ids = Set(recall.memories.map(\.id))
            XCTAssertTrue(ids.contains(complete.itemID))
            XCTAssertTrue(ids.contains(unrelated.itemID))
            XCTAssertFalse(ids.contains(incomplete.itemID))
            XCTAssertEqual(recall.skippedIncompleteImports, 1)
            XCTAssertTrue(recall.truncated)
        }
        let normal = try workflow.recall(binding)
        XCTAssertEqual(
            normal.memories.first { $0.id == complete.itemID }?.fields?["importSourceID"], .text("source-a"))
        let incompleteProfile = MemoryWorkflowBinding(
            storeID: selected.storeID, profileItemID: incomplete.itemID, checkpointItemID: checkpoint.itemID)
        XCTAssertThrowsError(try workflow.recall(incompleteProfile, fields: ["subject"]))
    }

    func testRecallRetainsOKFFreshnessClaimsAndLinksWithoutRawMetadata() throws {
        let fixture = try MemoryImportFixture()
        func create(_ fields: [String: ItemValue]) throws -> Revision {
            try fixture.store.commit(.init(classID: "Item", changes: fields, operationID: Identifier.make()))
                .revision
        }
        let profile = try create(["subject": .text("collaborator")])
        let checkpoint = try create(["subject": .text("checkpoint")])
        let category = try create([
            "subject": .text("OKF selection"),
            "selection": .object([
                "language": .text(SpotlightQuery.profile),
                "expression": .text("subject == \"OKF fixture memory\""),
            ]),
        ])
        let claims: [String: ItemValue] = [
            "okfType": .text("fact"), "okfStatus": .text("stable"),
            "okfStaleAfter": .date("2027-01-01T00:00:00Z"),
            "okfDescription": .text("Description of the source claim"),
            "okfSources": .list([.object(["title": .text("A source")])]),
            "okfGeneratedClaim": .object(["by": .text("unverified author")]),
            "okfVerifiedClaims": .list([.object(["by": .text("asserted reviewer")])]),
            "okfUsageWindow": .object(["from": .text("2026-01-01T00:00:00Z")]),
            "importLinks": .list([.object(["target": .reference(ItemReference(checkpoint.itemID))])]),
            "okfExecutionSupported": .boolean(false), "okfExecuted": .boolean(false),
            "okfAttestation": .text("absent"), "originalCreatedAt": .date("2026-01-01T00:00:00Z"),
            "originalModifiedAt": .date("2026-01-02T00:00:00Z"),
        ]
        var fields = claims
        fields["subject"] = .text("OKF fixture memory")
        fields["body"] = .text("Source content")
        fields["importMetadata"] = .object(["raw": .text("not included in default recall")])
        let memory = try create(fields)
        let selected = try CoreImportTransport(client: fixture.client, endpoint: "peer").binding()
        let binding = MemoryWorkflowBinding(
            storeID: selected.storeID, profileItemID: profile.itemID, checkpointItemID: checkpoint.itemID,
            categoryPath: [category.itemID])
        let result = try MemoryWorkflow(client: fixture.client, endpoint: "peer").recall(binding)
        let recalled = try XCTUnwrap(result.memories.first { $0.id == memory.itemID })
        for (key, expected) in claims { XCTAssertEqual(recalled.fields?[key], expected, key) }
        XCTAssertNil(recalled.fields?["importMetadata"])
        XCTAssertNil(recalled.fields?["requestIdentity"])
        XCTAssertFalse(result.truncated)
    }

    func testFreshClientsRecallAndExactRetry() throws {
        let fixture = try MemoryImportFixture()
        let root = fixture.root
        let store = fixture.store
        let service = fixture.service
        func create(_ subject: String) throws -> Revision {
            try store.commit(
                .init(classID: "Item", changes: ["subject": .text(subject)], operationID: Identifier.make())
            ).revision
        }
        let profile = try create("global collaborator")
        let checkpoint = try create("handoff")
        func category(_ subject: String) throws -> Revision {
            try store.commit(
                .init(
                    classID: "Item",
                    changes: [
                        "subject": .text(subject),
                        "selection": .object([
                            "language": .text(SpotlightQuery.profile),
                            "expression": .text("classID == \"Item\""),
                        ]),
                    ],
                    operationID: Identifier.make())
            ).revision
        }
        let excluded = try category("explicit exclusion")
        let included = try category("capture default")
        let first = ItemClient(transport: { service.handle($0, peerUID: tractanda_uid()) })
        let destination = try CoreImportTransport(client: first, endpoint: "test-peer").binding()
        let binding = MemoryWorkflowBinding(
            storeID: destination.storeID, profileItemID: profile.itemID,
            checkpointItemID: checkpoint.itemID,
            captureCategoryIDs: [excluded.itemID, included.itemID])
        let checkpointJournalPath = root.appendingPathComponent("workflow-journal-" + Identifier.make())
        defer { try? FileManager.default.removeItem(at: checkpointJournalPath) }
        do {
            let journal = try MemoryIntentJournal(directory: checkpointJournalPath, create: true)
            let receipt = try MemoryWorkflow(client: first, endpoint: "test-peer").checkpoint(
                binding, expectedRevisionID: checkpoint.revisionID,
                fields: ["body": .text("checkpoint context")], journal: journal)
            XCTAssertEqual(receipt.itemID, checkpoint.itemID)
        }
        let second = ItemClient(transport: { service.handle($0, peerUID: tractanda_uid()) })
        let recalled = try MemoryWorkflow(client: second, endpoint: "test-peer").recall(binding, limit: 1)
        XCTAssertEqual(recalled.profile.id, profile.itemID)
        XCTAssertEqual(recalled.checkpoint.fields?["body"], .text("checkpoint context"))
        XCTAssertTrue(recalled.truncated)
        XCTAssertNil(recalled.checkpoint.fields?["requestIdentity"])

        let journalPath = root.appendingPathComponent("workflow-journal-" + Identifier.make())
        defer { try? FileManager.default.removeItem(at: journalPath) }
        var drop = true
        let unreliable = ItemClient(transport: { request in
            let response = service.handle(request, peerUID: tractanda_uid())
            if drop && String(decoding: request, as: UTF8.self).contains("TractandaItem/commit") {
                drop = false
                throw TractandaError("simulatedLostReply", "acknowledgement lost")
            }
            return response
        })
        do {
            let journal = try MemoryIntentJournal(directory: journalPath, create: true)
            XCTAssertThrowsError(
                try MemoryWorkflow(client: unreliable, endpoint: "test-peer").remember(
                    binding,
                    fields: [
                        "subject": .text("unique-workflow-memory"),
                        "categoryOverrides": .object([excluded.itemID: .text("exclude")]),
                    ],
                    journal: journal))
            XCTAssertNil(try journal.receipt())
        }
        do {
            let journal = try MemoryIntentJournal(directory: journalPath)
            let receipt = try MemoryWorkflow(client: second, endpoint: "test-peer").resume(journal: journal)
            XCTAssertTrue(receipt.wasReplayed)
            let stored = try store.get(receipt.itemID)
            XCTAssertEqual(stored.fields["collaborator"], .reference(ItemReference(profile.itemID)))
            XCTAssertEqual(stored.fields["categoryOverrides"]?.map?[excluded.itemID], .text("exclude"))
            XCTAssertEqual(stored.fields["categoryOverrides"]?.map?[included.itemID], .text("include"))
            XCTAssertTrue(
                try Categories.query(store: store, categoryPath: [included.itemID]).contains {
                    $0.itemID == stored.itemID
                })
            XCTAssertFalse(
                try Categories.query(store: store, categoryPath: [excluded.itemID]).contains {
                    $0.itemID == stored.itemID
                })
            XCTAssertEqual(
                try store.candidates().filter { $0.fields["subject"]?.string == "unique-workflow-memory" }
                    .count, 1)
        }
    }
    func testBindingRejectsAmbiguousScopeAndJournalIntentTampering() throws {
        let binding = MemoryWorkflowBinding(
            storeID: "store", profileItemID: Identifier.make(),
            checkpointItemID: Identifier.make(), categoryPath: [], viewID: Identifier.make())
        XCTAssertThrowsError(try binding.validate())
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(
            "workflow-journal-" + Identifier.make())
        defer { try? FileManager.default.removeItem(at: path) }
        let journal = try MemoryIntentJournal(directory: path, create: true)
        let request = CommitRequest(
            classID: "Item", changes: ["subject": .text("note")], operationID: Identifier.make())
        let intent = try MemoryIntent(
            binding: ImportBinding(storeID: "store", principal: "person", endpoint: "peer"), request: request)
        try journal.create(intent)
        XCTAssertThrowsError(try journal.create(intent))
        XCTAssertEqual(try journal.intent().request, request)
    }
    func testStaleCheckpointAndMismatchedJournalBindingFailClosed() throws {
        let fixture = try MemoryImportFixture()
        func item(_ subject: String) throws -> Revision {
            try fixture.store.commit(
                .init(
                    classID: "Item", changes: ["subject": .text(subject)],
                    operationID: Identifier.make())
            ).revision
        }
        let profile = try item("profile")
        let checkpoint = try item("checkpoint")
        let selected = try CoreImportTransport(client: fixture.client, endpoint: "peer").binding()
        let binding = MemoryWorkflowBinding(
            storeID: selected.storeID, profileItemID: profile.itemID,
            checkpointItemID: checkpoint.itemID)
        _ = try fixture.revise(checkpoint.itemID, ["body": .text("newer")])
        let stale = try MemoryIntentJournal(
            directory: fixture.root.appendingPathComponent("stale"), create: true)
        XCTAssertThrowsError(
            try MemoryWorkflow(client: fixture.client, endpoint: "peer").checkpoint(
                binding, expectedRevisionID: checkpoint.revisionID, fields: ["body": .text("older")],
                journal: stale))
        XCTAssertNil(try stale.receipt())
        XCTAssertEqual(try fixture.store.get(checkpoint.itemID).fields["body"], .text("newer"))
        let wrongStore = MemoryWorkflowBinding(
            storeID: "different-store", profileItemID: profile.itemID,
            checkpointItemID: checkpoint.itemID)
        XCTAssertThrowsError(try MemoryWorkflow(client: fixture.client, endpoint: "peer").recall(wrongStore))
        for (number, mismatch) in [
            ImportBinding(
                storeID: "another-store", principal: selected.principal, endpoint: selected.endpoint),
            ImportBinding(
                storeID: selected.storeID, principal: "another-principal", endpoint: selected.endpoint),
            ImportBinding(storeID: selected.storeID, principal: selected.principal, endpoint: "another-peer"),
        ].enumerated() {
            let journal = try MemoryIntentJournal(
                directory: fixture.root.appendingPathComponent("wrong-\(number)"), create: true)
            let request = CommitRequest(
                classID: "Item", changes: ["subject": .text("never committed")],
                operationID: Identifier.make())
            try journal.create(MemoryIntent(binding: mismatch, request: request))
            XCTAssertThrowsError(
                try MemoryWorkflow(client: fixture.client, endpoint: "peer").resume(journal: journal))
            XCTAssertNil(try journal.receipt())
        }
        XCTAssertTrue(
            try fixture.store.candidates().filter { $0.fields["subject"]?.string == "never committed" }
                .isEmpty)
    }

    func testRecallRejectsMissingOversizedUnresolvedAndChangedProfileOrCheckpoint() throws {
        let fixture = try MemoryImportFixture()
        func item(_ title: String) throws -> Revision {
            try fixture.store.commit(
                .init(
                    classID: "Item", changes: ["subject": .text(title)],
                    operationID: Identifier.make())
            ).revision
        }
        let profile = try item("profile")
        let checkpoint = try item("checkpoint")
        let selected = try CoreImportTransport(client: fixture.client, endpoint: "peer").binding()
        let binding = MemoryWorkflowBinding(
            storeID: selected.storeID, profileItemID: profile.itemID,
            checkpointItemID: checkpoint.itemID)
        for target in [profile.itemID, checkpoint.itemID] {
            for fault in ["missing", "oversized", "unresolved", "changed"] {
                let service = fixture.service
                let client = ItemClient(transport: { request in
                    let response = service.handle(request, peerUID: tractanda_uid())
                    guard String(decoding: request, as: UTF8.self).contains("TractandaItem/getBounded") else {
                        return response
                    }
                    var envelope = try XCTUnwrap(
                        JSONSerialization.jsonObject(with: response) as? [String: Any])
                    var calls = try XCTUnwrap(envelope["methodResponses"] as? [[Any]])
                    var payload = try XCTUnwrap(calls[0][1] as? [String: Any])
                    var list = try XCTUnwrap(payload["list"] as? [[String: Any]])
                    let index = try XCTUnwrap(list.firstIndex { $0["id"] as? String == target })
                    switch fault {
                    case "missing":
                        list.remove(at: index)
                        payload["notFound"] = [target]
                    case "oversized":
                        list.remove(at: index)
                        payload["oversizedIDs"] = [target]
                    case "unresolved":
                        list[index] = [
                            "id": target,
                            "resolution": [
                                "itemID": target, "stateToken": "test",
                                "status": "conflicted", "detailsComplete": false,
                            ],
                        ]
                    default: payload["state"] = "different-state"
                    }
                    payload["list"] = list
                    calls[0][1] = payload
                    envelope["methodResponses"] = calls
                    return try JSONSerialization.data(withJSONObject: envelope)
                })
                XCTAssertThrowsError(
                    try MemoryWorkflow(client: client, endpoint: "peer").recall(binding, limit: 0),
                    "\(target) \(fault)")
            }
        }
    }

    func testMissingCaptureCategoryFailsWithoutCreatingMemory() throws {
        let fixture = try MemoryImportFixture()
        let profile = try fixture.store.commit(
            .init(classID: "Item", changes: ["subject": .text("profile")], operationID: Identifier.make())
        ).revision
        let checkpoint = try fixture.store.commit(
            .init(classID: "Item", changes: ["subject": .text("checkpoint")], operationID: Identifier.make())
        ).revision
        let selected = try CoreImportTransport(client: fixture.client, endpoint: "peer").binding()
        let binding = MemoryWorkflowBinding(
            storeID: selected.storeID, profileItemID: profile.itemID,
            checkpointItemID: checkpoint.itemID, captureCategoryIDs: [Identifier.make()])
        let journal = try MemoryIntentJournal(
            directory: fixture.root.appendingPathComponent("category"), create: true)
        XCTAssertThrowsError(
            try MemoryWorkflow(client: fixture.client, endpoint: "peer").remember(
                binding, fields: ["subject": .text("no memory created")], journal: journal))
        XCTAssertTrue(
            try fixture.store.candidates().filter { $0.fields["subject"]?.string == "no memory created" }
                .isEmpty)
        let category = try fixture.store.commit(
            .init(
                classID: "Item",
                changes: [
                    "subject": .text("deleted category"),
                    "selection": .object([
                        "language": .text(SpotlightQuery.profile),
                        "expression": .text("classID == \"Item\""),
                    ]),
                ], operationID: Identifier.make())
        ).revision
        _ = try fixture.revise(category.itemID, ["isDeleted": .boolean(true)])
        let deletedBinding = MemoryWorkflowBinding(
            storeID: selected.storeID, profileItemID: profile.itemID,
            checkpointItemID: checkpoint.itemID, captureCategoryIDs: [category.itemID])
        let deletedJournal = try MemoryIntentJournal(
            directory: fixture.root.appendingPathComponent("deleted-category"), create: true)
        XCTAssertThrowsError(
            try MemoryWorkflow(client: fixture.client, endpoint: "peer").remember(
                deletedBinding, fields: ["subject": .text("not created")], journal: deletedJournal))
    }

    func testReadbackMismatchRetainsIntentAndAllowsExactResume() throws {
        let fixture = try MemoryImportFixture()
        let profile = try fixture.store.commit(
            .init(classID: "Item", changes: ["subject": .text("profile")], operationID: Identifier.make())
        ).revision
        let checkpoint = try fixture.store.commit(
            .init(classID: "Item", changes: ["subject": .text("checkpoint")], operationID: Identifier.make())
        ).revision
        let selected = try CoreImportTransport(client: fixture.client, endpoint: "peer").binding()
        let binding = MemoryWorkflowBinding(
            storeID: selected.storeID, profileItemID: profile.itemID, checkpointItemID: checkpoint.itemID)
        let service = fixture.service
        let altered = ItemClient(transport: { request in
            let response = service.handle(request, peerUID: tractanda_uid())
            guard String(decoding: request, as: UTF8.self).contains("TractandaRevision/get") else {
                return response
            }
            var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: response) as? [String: Any])
            var calls = try XCTUnwrap(envelope["methodResponses"] as? [[Any]])
            var payload = try XCTUnwrap(calls[0][1] as? [String: Any])
            var list = try XCTUnwrap(payload["list"] as? [[String: Any]])
            var fields = try XCTUnwrap(list[0]["fields"] as? [String: Any])
            fields["body"] = ["type": "text", "value": "altered"]
            list[0]["fields"] = fields
            payload["list"] = list
            calls[0][1] = payload
            envelope["methodResponses"] = calls
            return try JSONSerialization.data(withJSONObject: envelope)
        })
        let journal = try MemoryIntentJournal(
            directory: fixture.root.appendingPathComponent("readback"), create: true)
        XCTAssertThrowsError(
            try MemoryWorkflow(client: altered, endpoint: "peer").checkpoint(
                binding, expectedRevisionID: checkpoint.revisionID, fields: ["body": .text("correct")],
                journal: journal))
        XCTAssertNil(try journal.receipt())
        let receipt = try MemoryWorkflow(client: fixture.client, endpoint: "peer").resume(journal: journal)
        XCTAssertTrue(receipt.wasReplayed)
        XCTAssertEqual(try fixture.store.get(checkpoint.itemID).fields["body"], .text("correct"))
    }

}
