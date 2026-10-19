import XCTest

@testable import TractandaCore

final class PeerInventoryStoreTests: XCTestCase {
    typealias Fixture = PeerIntakeStoreTests.Fixture
    private func code(_ expected: String, _ body: () throws -> Void) {
        XCTAssertThrowsError(try body()) { XCTAssertEqual(($0 as? TractandaError)?.code, expected) }
    }
    private func all(
        _ store: ItemStore, context: PeerPackage.Context,
        boundary: PeerInventory.Boundary, limit: Int = 128
    ) throws -> [PeerInventory.Entry] {
        var result: [PeerInventory.Entry] = []
        var cursor: PeerInventory.Cursor?
        var calls = 0
        repeat {
            let page = try store.peerInventoryPage(
                context: context, boundary: boundary, cursor: cursor, limit: limit)
            result += page.entries
            cursor = page.nextCursor
            calls += 1
            XCTAssertLessThan(calls, 256)
        } while cursor != nil
        return result
    }
    private func completed(
        _ store: ItemStore, context: PeerPackage.Context,
        boundary: PeerInventory.Boundary, limit: Int = 128
    ) throws -> (entries: [PeerInventory.Entry], checkpoint: PeerInventory.CompletionCheckpoint) {
        var result: [PeerInventory.Entry] = []
        var cursor: PeerInventory.Cursor?
        var checkpoint: PeerInventory.CompletionCheckpoint?
        var calls = 0
        repeat {
            let page = try store.peerInventoryPage(
                context: context, boundary: boundary, cursor: cursor, limit: limit)
            result += page.entries
            if page.nextCursor != nil { XCTAssertNil(page.completionCheckpoint) }
            checkpoint = page.completionCheckpoint
            cursor = page.nextCursor
            calls += 1
            XCTAssertLessThan(calls, 256)
        } while cursor != nil
        return (result, try XCTUnwrap(checkpoint, "A complete finite scan must return its checkpoint."))
    }
    private func canonicalFiles(_ root: URL) throws -> Set<String> {
        var paths: Set<String> = []
        for relative in ["items", "authority/records"] {
            let folder = root.appendingPathComponent(relative)
            guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
            else { continue }
            for case let file as URL in enumerator
            where file.pathExtension == "tractanda" || file.pathExtension == "authority" {
                paths.insert(file.path)
            }
        }
        return paths
    }
    func testCapturedInventoryFinishesWhileEveryPageAddsNewLocalPublications() throws {
        let f = try Fixture()
        try f.source.configurePeerIntake(peers: [f.context])
        let boundary = try f.source.capturePeerInventory(context: f.context)
        var cursor: PeerInventory.Cursor?
        var oldEntries: [PeerInventory.Entry] = []
        var appended: Set<String> = []
        var calls = 0
        repeat {
            let before = try canonicalFiles(f.sourceRoot)
            let page = try f.source.peerInventoryPage(
                context: f.context, boundary: boundary, cursor: cursor, limit: 1)
            XCTAssertEqual(
                try canonicalFiles(f.sourceRoot), before, "Enumeration must not publish acknowledgements.")
            oldEntries += page.entries
            cursor = page.nextCursor
            let next = try f.edit(subject: "after finite capture \(calls)")
            appended.insert(next.revisionID)
            calls += 1
            XCTAssertLessThan(calls, 64)
            try f.capacity()
        } while cursor != nil
        XCTAssertGreaterThan(calls, 1)
        XCTAssertTrue(oldEntries.contains { $0.descriptor.id == f.base.revisionID })
        XCTAssertTrue(oldEntries.contains { $0.descriptor.kind == .authority })
        XCTAssertTrue(oldEntries.allSatisfy { !appended.contains($0.descriptor.id) })
        let nextPass = try all(
            f.source, context: f.context, boundary: f.source.capturePeerInventory(context: f.context))
        XCTAssertTrue(appended.isSubset(of: Set(nextPass.map { $0.descriptor.id })))
        XCTAssertEqual(Set(oldEntries.map(\.sequence)).count, oldEntries.count)
    }
    func testHeldKnownOriginAndDuplicateReceiptsAreListedWhileUnknownRowsAdvanceEmptyPages() throws {
        let f = try Fixture()
        try f.bootstrap()
        let held = try f.edit(uid: f.sourceAccounts.bob)
        f.receiverAccounts.bobHasGroup = false
        let originals = try f.source.peerMetadataObjects(revisionID: held.revisionID)
        XCTAssertEqual(try f.send(f.packet(originals)).held, 1)
        var fields = held.fields
        let unknownID = try Fixture.id()
        fields["revisionID"] = .text(unknownID)
        let provenance = try XCTUnwrap(held.provenance)
        fields["revisionAncestry"] = try RevisionProvenance(
            kind: .authored, originReplicaID: Fixture.id(), parents: provenance.parents,
            writtenFields: provenance.writtenFields, unsetFields: provenance.unsetFields, frontier: []
        ).itemValue
        let unknown = try RecordCodec.encode(Revision(fields: fields, formatVersion: 2))
        _ = try f.send(
            f.packet([
                (
                    .init(
                        kind: .item, id: unknownID, length: unknown.count,
                        sha256: AuthorityRecordCodec.sha256(unknown)), unknown
                )
            ]))
        // A later permitted receipt keeps the filtered unknown row away from the final cutoff.
        XCTAssertEqual(try f.send(f.packet(originals)).held, 1)
        let boundary = try f.receiver.capturePeerInventory(context: f.context)
        var cursor: PeerInventory.Cursor?
        var entries: [PeerInventory.Entry] = []
        var sawFilteredProgress = false
        var calls = 0
        repeat {
            let page = try f.receiver.peerInventoryPage(
                context: f.context, boundary: boundary, cursor: cursor, limit: 1)
            if page.entries.isEmpty, page.scannedCount > 0, page.nextCursor != nil {
                sawFilteredProgress = true
            }
            entries += page.entries
            cursor = page.nextCursor
            calls += 1
            XCTAssertLessThan(calls, 128)
        } while cursor != nil
        let rows = entries.filter { $0.descriptor.id == held.revisionID }
        XCTAssertGreaterThanOrEqual(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy { $0.disposition == .held && $0.proof == .configuredOrigin })
        XCTAssertFalse(entries.contains { $0.descriptor.id == unknownID })
        XCTAssertTrue(sawFilteredProgress)
        XCTAssertEqual(try f.receiver.get(f.base.itemID).revisionID, f.base.revisionID)
        XCTAssertFalse(try f.receiver.history(held.itemID).contains { $0.revisionID == held.revisionID })
        try f.capacity()
    }
    func testLegacyDiscoveryRequiresExactCurrentReviewedBootstrapProof() throws {
        let f = try Fixture()
        func legacy() throws -> (PeerPackage.Object, Data) {
            var fields = f.base.fields
            fields.removeValue(forKey: "revisionAncestry")
            fields["itemID"] = .text(try Fixture.id())
            let id = try Fixture.id()
            fields["revisionID"] = .text(id)
            fields["actor"] = .text("user:retired")
            let bytes = try RecordCodec.encode(Revision(fields: fields, formatVersion: 1))
            return (
                .init(kind: .item, id: id, length: bytes.count, sha256: AuthorityRecordCodec.sha256(bytes)),
                bytes
            )
        }
        let pinned = try legacy()
        try f.bootstrap(extra: [pinned])
        let unreviewed = try legacy()
        _ = try f.send(f.packet([unreviewed]))
        let entries = try all(
            f.receiver, context: f.context, boundary: f.receiver.capturePeerInventory(context: f.context),
            limit: 3)
        XCTAssertTrue(entries.contains { $0.descriptor == pinned.0 && $0.proof == .pinnedLegacy })
        XCTAssertFalse(entries.contains { $0.descriptor.id == unreviewed.0.id })
        // The derived witness alone is insufficient if the current private initial pin differs.
        let files = DocumentContentFiles(
            root: f.receiverRoot, ownerUID: f.receiver.ownerUID, minimumFreeBytes: 10 * 1024 * 1024 * 1024)
        try AuthorityStore.writeConfiguration(
            .init(
                profile: "tractanda.peer-configuration.v1", peers: [f.context],
                bootstrap: .init(
                    recordID: Fixture.id(), sha256: AuthorityRecordCodec.sha256(Data("other pin".utf8)),
                    actor: "admin")),
            root: f.receiverRoot, files: files)
        let changed = try all(
            f.receiver, context: f.context, boundary: f.receiver.capturePeerInventory(context: f.context))
        XCTAssertFalse(changed.contains { $0.descriptor.id == pinned.0.id })
        try f.capacity()
    }
    func testLocalHeldHistoryAndExactReviewDecisionRemainDiscoverableWithoutNewEffects() throws {
        let reviewed = try AuthorityReviewStoreTests.ReviewedFixture()
        let f = reviewed.base
        let beforeApproval = try all(
            f.receiver, context: f.context, boundary: f.receiver.capturePeerInventory(context: f.context),
            limit: 4)
        XCTAssertTrue(
            beforeApproval.contains {
                $0.descriptor.id == reviewed.held.revisionID && $0.disposition == .held
                    && $0.proof == .configuredOrigin
            })
        let result = try f.receiver.resolveAuthorityReview(reviewed.request())
        let before = try canonicalFiles(f.receiverRoot)
        let inventory = try all(
            f.receiver, context: f.context, boundary: f.receiver.capturePeerInventory(context: f.context),
            limit: 4)
        XCTAssertTrue(
            inventory.contains {
                $0.descriptor.id == result.decision.recordID && $0.descriptor.kind == .authority
                    && $0.descriptor.sha256 == result.decision.sha256 && $0.proof == .configuredOrigin
            })
        XCTAssertTrue(inventory.contains { $0.descriptor.id == result.revision.revisionID })
        XCTAssertEqual(try canonicalFiles(f.receiverRoot), before)
        XCTAssertEqual(try f.receiver.get(reviewed.held.itemID).revisionID, result.revision.revisionID)
        try f.capacity()
    }
    func testContextBoundsCancellationWarmReopenAndRebuildEpoch() throws {
        let f = try Fixture()
        func stage<T>(_ label: String, _ body: () throws -> T) throws -> T {
            do { return try body() } catch {
                throw TractandaError(
                    (error as? TractandaError)?.code ?? "testFailure",
                    "\(error) [inventoryStage:\(label),base:\(f.base.revisionID),config:\(f.configuration.revisionID)]"
                )
            }
        }
        try stage("bootstrap") { try f.bootstrap() }
        let boundary = try f.receiver.capturePeerInventory(context: f.context)
        let first = try f.receiver.peerInventoryPage(context: f.context, boundary: boundary, limit: 1)
        let cursor = try XCTUnwrap(first.nextCursor)
        let before = try canonicalFiles(f.receiverRoot)
        f.receiver = nil
        f.receiver = try stage("warm-open") { try Fixture.open(f.receiverRoot, f.receiverAccounts) }
        _ = try f.receiver.peerInventoryPage(context: f.context, boundary: boundary, cursor: cursor, limit: 1)
        XCTAssertEqual(try canonicalFiles(f.receiverRoot), before)
        var tiny = PeerInventory.Limits()
        tiny.maximumReadBytes = 1
        code("resourceLimit") {
            _ = try f.receiver.peerInventoryPage(context: f.context, boundary: boundary, limits: tiny)
        }
        tiny = .init()
        tiny.maximumResultBytes = 1
        code("resourceLimit") {
            _ = try f.receiver.peerInventoryPage(context: f.context, boundary: boundary, limits: tiny)
        }
        code("resourceLimit") {
            _ = try f.receiver.peerInventoryPage(context: f.context, boundary: boundary, limit: 129)
        }
        code("cancelled") {
            _ = try f.receiver.peerInventoryPage(
                context: f.context, boundary: boundary,
                progress: { throw TractandaError("cancelled", "native inventory checkpoint") })
        }
        // Epoch invalidation is tested under unchanged, fully validated trust proof.
        try stage("full-rebuild-unchanged-context") { try f.receiver.rebuildIndex() }
        code("peerInventoryChanged") {
            _ = try f.receiver.peerInventoryPage(context: f.context, boundary: boundary)
        }
        let afterRebuild = try f.receiver.capturePeerInventory(context: f.context)
        _ = try f.receiver.peerInventoryPage(context: f.context, boundary: afterRebuild)

        // Managed rotation changes session/cursor identity while preserving exact historical receipts.
        let old = f.context!
        let updated = try PeerPackage.Context(
            peerID: old.peerID, storeID: old.storeID,
            configurationDigest: AuthorityRecordCodec.sha256(Data("rotated inventory config".utf8)),
            permittedOrigins: old.permittedOrigins)
        try stage("rotate-config") {
            try f.receiver.rotatePeerIntakeCredential(
                peerID: updated.peerID, replacement: updated, operationID: Fixture.id())
        }
        code("peerConfigurationChanged") {
            _ = try f.receiver.peerInventoryPage(context: old, boundary: afterRebuild)
        }
        code("invalidPeerCursor") {
            _ = try f.receiver.peerInventoryPage(context: updated, boundary: afterRebuild)
        }
        let beforeInventory = try canonicalFiles(f.receiverRoot)
        let replacementPass = try all(
            f.receiver, context: updated, boundary: f.receiver.capturePeerInventory(context: updated))
        XCTAssertTrue(replacementPass.contains { $0.descriptor.id == f.base.revisionID })
        XCTAssertTrue(replacementPass.contains { $0.descriptor.id == f.configuration.revisionID })
        XCTAssertEqual(try canonicalFiles(f.receiverRoot), beforeInventory)
        try f.capacity()
    }

    func testCompletedCheckpointContinuesAfterPriorMaximumAndSupportsEmptyPass() throws {
        let f = try Fixture()
        try f.source.configurePeerIntake(peers: [f.context])
        let initialBoundary = try f.source.capturePeerInventory(context: f.context)
        let partial = try f.source.peerInventoryPage(
            context: f.context, boundary: initialBoundary, limit: 1)
        XCTAssertNotNil(partial.nextCursor)
        XCTAssertNil(partial.completionCheckpoint)

        let initial = try completed(
            f.source, context: f.context, boundary: initialBoundary, limit: 1)
        XCTAssertFalse(initial.entries.isEmpty)
        let priorIDs = Set(initial.entries.map { $0.descriptor.id })
        let priorMaximum = try XCTUnwrap(initial.entries.map(\.sequence).max())

        let sameMaximumBoundary = try f.source.capturePeerInventory(
            context: f.context, after: initial.checkpoint)
        let emptyPass = try f.source.peerInventoryPage(
            context: f.context, boundary: sameMaximumBoundary)
        XCTAssertTrue(emptyPass.entries.isEmpty)
        XCTAssertNil(emptyPass.nextCursor)
        let emptyCheckpoint = try XCTUnwrap(emptyPass.completionCheckpoint)

        let appended = try f.edit(subject: "incremental inventory append")
        let continuation = try f.source.capturePeerInventory(
            context: f.context, after: emptyCheckpoint)
        let nextPass = try completed(
            f.source, context: f.context, boundary: continuation, limit: 1)
        XCTAssertTrue(nextPass.entries.contains { $0.descriptor.id == appended.revisionID })
        XCTAssertTrue(nextPass.entries.allSatisfy { $0.sequence > priorMaximum })
        XCTAssertTrue(Set(nextPass.entries.map { $0.descriptor.id }).isDisjoint(with: priorIDs))
        try f.capacity()
    }

    func testOldCursorCannotCrossExtendedBoundaryAndPartialPassYieldsNoCheckpoint() throws {
        let f = try Fixture()
        try f.source.configurePeerIntake(peers: [f.context])
        let boundary = try f.source.capturePeerInventory(context: f.context)
        let partial = try f.source.peerInventoryPage(context: f.context, boundary: boundary, limit: 1)
        let oldCursor = try XCTUnwrap(partial.nextCursor)
        XCTAssertNil(partial.completionCheckpoint)
        let completedBoundary = try completed(f.source, context: f.context, boundary: boundary, limit: 1)

        _ = try f.edit(subject: "advance receipt inventory")
        let extended = try f.source.capturePeerInventory(
            context: f.context, after: completedBoundary.checkpoint)
        code("invalidPeerCursor") {
            _ = try f.source.peerInventoryPage(
                context: f.context, boundary: extended, cursor: oldCursor, limit: 1)
        }
        try f.capacity()
    }

    func testCheckpointRejectsRebuildContextAndCrossStoreReuse() throws {
        let rebuilt = try Fixture()
        try rebuilt.source.configurePeerIntake(peers: [rebuilt.context])
        let beforeRebuild = try completed(
            rebuilt.source, context: rebuilt.context,
            boundary: rebuilt.source.capturePeerInventory(context: rebuilt.context))
        try rebuilt.source.rebuildIndex()
        code("peerInventoryChanged") {
            _ = try rebuilt.source.capturePeerInventory(
                context: rebuilt.context, after: beforeRebuild.checkpoint)
        }

        let changed = try Fixture()
        try changed.source.configurePeerIntake(peers: [changed.context])
        let oldContext = changed.context!
        let oldCheckpoint = try completed(
            changed.source, context: oldContext,
            boundary: changed.source.capturePeerInventory(context: oldContext)
        ).checkpoint
        let updated = try PeerPackage.Context(
            peerID: oldContext.peerID, storeID: oldContext.storeID,
            configurationDigest: AuthorityRecordCodec.sha256(Data("updated inventory config".utf8)),
            permittedOrigins: oldContext.permittedOrigins)
        try changed.source.rotatePeerIntakeCredential(
            peerID: updated.peerID, replacement: updated, operationID: Fixture.id())
        code("peerConfigurationChanged") {
            _ = try changed.source.capturePeerInventory(context: oldContext, after: oldCheckpoint)
        }
        code("peerInventoryChanged") {
            _ = try changed.source.capturePeerInventory(context: updated, after: oldCheckpoint)
        }

        let otherStore = try Fixture()
        try otherStore.source.configurePeerIntake(peers: [otherStore.context])
        code("peerInventoryChanged") {
            _ = try otherStore.source.capturePeerInventory(
                context: otherStore.context, after: oldCheckpoint)
        }
        try rebuilt.capacity()
        try changed.capacity()
        try otherStore.capacity()
    }
}
