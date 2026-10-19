import Foundation
import XCTest

@testable import TractandaCore

final class PeerDocumentLocalReviewTests: XCTestCase {
    private typealias Fixture = PeerIntakeStoreTests.Fixture

    private func attach(_ f: Fixture) throws -> (Revision, AttachmentDescriptor) {
        try f.capacity()
        let bytes = Data("%PDF-1.4\ntiny local review fixture\n".utf8)
        let result = try f.source.withAccess(forUID: f.sourceAccounts.alice) {
            let upload = try f.source.beginAttachment(
                .init(
                    itemID: f.base.itemID, expectedRevisionID: f.base.revisionID,
                    operationID: Fixture.id(), filename: "review.pdf", mediaType: "application/pdf",
                    byteCount: Int64(bytes.count), sha256: AuthorityRecordCodec.sha256(bytes)))
            let uploadID = try XCTUnwrap(upload.uploadID)
            _ = try f.source.appendAttachment(uploadID: uploadID, offset: 0, data: bytes)
            return (try f.source.finishAttachment(uploadID: uploadID).revision, upload.attachment)
        }
        try f.capacity()
        return result
    }

    private func save(
        _ f: Fixture, attached: Revision, descriptor: AttachmentDescriptor, text: String,
        actor: UInt32
    ) throws -> Revision {
        try f.capacity()
        let receipt = try f.source.withAccess(forUID: actor) {
            guard
                case .prepared(let snapshot) = try f.source.prepareAttachmentDocument(
                    itemID: attached.itemID, expectedRevisionID: attached.revisionID,
                    attachmentID: descriptor.attachmentID, operationID: Fixture.id(), identity: .init())
            else { throw TractandaError("fixture", "Expected new document preparation.") }
            let writer = try DocumentContentStore(
                root: f.sourceRoot, ownerUID: getuid(),
                minimumFreeBytes: AttachmentFixtureCapacity.reserveBytes
            ).begin(source: snapshot.source, identity: .init(), maximumWriteBytes: 1024 * 1024)
            let geometry = try DocumentPageGeometry(
                sourceWidth: 512, sourceHeight: 256, sourceUnit: "pdfPoint", displayWidth: 512,
                displayHeight: 256, canvasWidth: 2048, canvasHeight: 1024, contentLeft: 0, contentTop: 0,
                contentWidth: 2048, contentHeight: 1024)
            let parsed = try DoclingDocTagsParser.parse(
                Data(("<doctag><text>" + text + "</text></doctag>").utf8))
            try writer.append(
                DocumentStoredPage(
                    pageNumber: 1, sourceSHA256: snapshot.source.sha256,
                    page: AttachmentDocumentPage(
                        pageNumber: 1, geometry: geometry, rasterSHA256: String(repeating: "b", count: 64),
                        parsed: parsed, generatedTokens: 32, stopReason: "stop")))
            try f.capacity()
            try writer.append(
                DocumentStoredPage(
                    pageNumber: 2, sourceSHA256: snapshot.source.sha256,
                    status: "failed", failureCode: "fixture"))
            let prepared = try writer.preparePublication()
            let corpus = try f.source.prepareAttachmentDocumentCorpus(snapshot, prepared: prepared)
            return try f.source.finishAttachmentDocument(snapshot, prepared: prepared, corpus: corpus)
        }
        try f.capacity()
        return try f.source.get(receipt.itemID)
    }

    private func export(_ f: Fixture, revision: Revision) throws -> (
        PeerExportPlan.Handle, PeerPackage.Manifest
    ) {
        try f.source.configurePeerIntake(peers: [f.context])
        let boundary = try f.source.capturePeerInventory(context: f.context)
        let handle = try f.source.beginPeerExport(
            context: f.context, planID: Fixture.id(), packageID: Fixture.id(), boundary: boundary)
        var cursor: PeerInventory.Cursor?
        var selected: PeerInventory.Entry?
        var inventoryCalls = 0
        repeat {
            inventoryCalls += 1
            guard inventoryCalls <= 256 else {
                throw TractandaError("fixture", "Tiny export inventory did not advance.")
            }
            let page = try f.source.peerInventoryPage(
                context: f.context, boundary: boundary, cursor: cursor)
            selected = selected ?? page.entries.first { $0.descriptor.id == revision.revisionID }
            cursor = page.nextCursor
            try f.capacity()
        } while cursor != nil
        _ = try f.source.selectPeerExport(
            context: f.context, handle: handle, entries: [XCTUnwrap(selected)], finish: true)
        for _ in 0..<1024 {
            try f.capacity()
            let status = try f.source.stepPeerExport(
                context: f.context, handle: handle, window: .init(maximumUnits: 3, maximumEdges: 2))
            XCTAssertEqual(status.missing, 0)
            XCTAssertEqual(status.unsupported, 0)
            if let manifest = status.manifest { return (handle, manifest) }
        }
        throw TractandaError("fixture", "Tiny document export did not seal.")
    }

    /// Exercises real descriptors/chunks and bounded document-part discovery without committing.
    private func transfer(_ f: Fixture, revision: Revision) throws -> PeerPackage.Manifest {
        let (handle, manifest) = try export(f, revision: revision)
        _ = try f.receiver.beginPeerIntake(context: f.context, manifestBytes: JSON.encode(manifest))
        var pending = [manifest.root]
        var seen: Set<String> = []
        var objectCalls = 0
        while let object = pending.popLast() {
            objectCalls += 1
            guard objectCalls <= 256 else {
                throw TractandaError("fixture", "Tiny metadata transfer exceeded its bound.")
            }
            if !seen.insert(object.id).inserted { continue }
            var indexBytes = Data()
            for offset in stride(from: 0, to: object.length, by: object.chunkBytes) {
                try f.capacity()
                let chunk = try f.source.readPeerExport(
                    context: f.context, handle: handle, object: object, offset: offset)
                _ = try f.receiver.appendPeerObject(
                    context: f.context, packageID: manifest.packageID, object: object, offset: offset,
                    bytes: chunk.bytes)
                if object.kind == .index { indexBytes.append(chunk.bytes) }
            }
            if object.kind == .index {
                let page = try PeerPackage.decode(PeerPackage.Page.self, indexBytes)
                pending += page.objects + page.children
            }
        }
        var cursor: PeerPackage.ResumeCursor?
        var calls = 0
        repeat {
            calls += 1
            guard calls < 256 else {
                throw TractandaError("fixture", "Tiny document resume did not advance.")
            }
            let page = try f.receiver.resumePeerIntake(
                context: f.context, packageID: manifest.packageID, cursor: cursor, limit: 2)
            cursor = page.nextCursor
            for value in page.objects where value.descriptor.kind == .document && !value.verifiedComplete {
                let object = value.descriptor
                for offset in stride(from: value.nextOffset, to: object.length, by: object.chunkBytes) {
                    try f.capacity()
                    let chunk = try f.source.readPeerExport(
                        context: f.context, handle: handle, object: object, offset: offset)
                    _ = try f.receiver.appendPeerObject(
                        context: f.context, packageID: manifest.packageID, object: object, offset: offset,
                        bytes: chunk.bytes)
                }
            }
        } while cursor != nil
        try f.capacity()
        return manifest
    }

    private func commit(_ f: Fixture, manifest: PeerPackage.Manifest) throws -> AuthorityStore.Result {
        try f.capacity()
        let result = try f.receiver.commitPeerIntake(
            context: f.context, packageID: manifest.packageID,
            expectedContextToken: f.receiver.peerIntakeContextToken())
        try f.capacity()
        return result
    }

    private func acceptedOriginal(_ f: Fixture) throws -> (Revision, AttachmentDescriptor) {
        try f.bootstrap()
        let (attached, descriptor) = try attach(f)
        let manifest = try transfer(f, revision: attached)
        XCTAssertGreaterThan(try commit(f, manifest: manifest).accepted, 0)
        XCTAssertEqual(try f.receiver.get(attached.itemID), attached)
        return (attached, descriptor)
    }

    private func assertHeld(_ f: Fixture, revision: Revision) throws {
        let boundary = try f.receiver.capturePeerInventory(context: f.context)
        var cursor: PeerInventory.Cursor?
        var matches = 0
        var calls = 0
        repeat {
            calls += 1
            guard calls < 256 else {
                throw TractandaError("fixture", "Tiny disposition inventory did not advance.")
            }
            let page = try f.receiver.peerInventoryPage(
                context: f.context, boundary: boundary, cursor: cursor, limit: 2)
            for entry in page.entries
            where entry.descriptor.kind == .item && entry.descriptor.id == revision.revisionID {
                matches += 1
                XCTAssertEqual(entry.disposition, .held)
            }
            cursor = page.nextCursor
            try f.capacity()
        } while cursor != nil
        XCTAssertGreaterThan(matches, 0, "The exact incoming revision must retain a held disposition.")
    }

    private func heldDocument() throws -> (Fixture, Revision, Revision, AuthorityBinding, String) {
        let f = try Fixture()
        let (attached, descriptor) = try acceptedOriginal(f)
        let phrase = "bounded local review corpus"
        let saved = try save(
            f, attached: attached, descriptor: descriptor, text: phrase, actor: f.sourceAccounts.bob)
        let objects = try f.source.peerMetadataObjects(revisionID: saved.revisionID)
        let witness = try XCTUnwrap(objects.first { Fixture.isEvidence($0, for: saved.revisionID) })
        let evidence = try AuthorityBinding(recordID: witness.0.id, sha256: witness.0.sha256)
        f.receiverAccounts.bobHasGroup = false
        let manifest = try transfer(f, revision: saved)
        XCTAssertEqual(try commit(f, manifest: manifest).held, 1)
        try assertHeld(f, revision: saved)
        XCTAssertEqual(try f.receiver.get(saved.itemID), attached)
        XCTAssertTrue(try f.receiver.candidates(text: phrase).isEmpty)
        return (f, attached, saved, evidence, phrase)
    }

    private func snapshot(_ f: Fixture, held: Revision, evidence: AuthorityBinding) throws
        -> AuthorityStore.ReviewState
    {
        var handle: String?
        for _ in 0..<128 {
            try f.capacity()
            let status = try f.receiver.preflightAuthorityReview(
                itemID: held.itemID, revisionID: held.revisionID, evidence: evidence)
            if let handle { XCTAssertEqual(status.handle, handle) }
            handle = status.handle
            if status.ready {
                return try f.receiver.prepareAuthorityReview(
                    itemID: held.itemID, revisionID: held.revisionID, evidence: evidence)
            }
        }
        throw TractandaError("fixture", "Tiny held-document preflight did not finish.")
    }

    private func request(
        held: Revision, state: AuthorityStore.ReviewState, operation: String,
        subject: String = "explicit reviewed document", token: String? = nil
    ) throws -> AuthorityStore.ReviewRequest {
        let provenance = try XCTUnwrap(held.provenance)
        // Select actual authored fields one by one; attachmentDocument is an explicit
        // reviewed choice, and every omitted authored field remains an error in Store.
        var changes: [String: ItemValue] = [:]
        for key in provenance.writtenFields {
            changes[key] = try XCTUnwrap(held.fields[key])
        }
        changes["subject"] = .text(subject)
        XCTAssertNotNil(changes["attachmentDocument"])
        var request = AuthorityStore.ReviewRequest(
            itemID: held.itemID, revisionID: held.revisionID, evidence: state.evidence,
            expectedStateToken: token ?? state.stateToken, reviewedFrontier: state.decisionFrontier,
            reviewedControlHolds: state.controlHolds, changes: changes,
            unset: provenance.unsetFields.sorted(),
            operationID: operation)
        request.reviewedRetirements = state.retirements
        return request
    }

    private func finishPreflight(_ f: Fixture, request: AuthorityStore.ReviewRequest) throws -> String {
        var handle: String?
        for _ in 0..<128 {
            try f.capacity()
            let status = try f.receiver.preflightAuthorityReviewResolution(request)
            if let handle { XCTAssertEqual(status.handle, handle) }
            handle = status.handle
            if status.ready { return status.handle }
        }
        throw TractandaError("fixture", "Tiny exact-request preflight did not finish.")
    }

    private func canonicalBytes(_ f: Fixture) throws -> [String: String] {
        try f.capacity()
        let entries = try XCTUnwrap(
            FileManager.default.enumerator(at: f.receiverRoot, includingPropertiesForKeys: nil))
        var hashes: [String: String] = [:]
        for case let url as URL in entries {
            let path = String(url.path.dropFirst(f.receiverRoot.path.count + 1))
            guard
                url.pathExtension == "authority" || url.pathExtension == "tractanda"
                    || path.hasPrefix("documents/content/") || path.hasPrefix("attachments/payloads/")
            else { continue }
            guard try FileMetadata.read(at: url).type == .regular else { continue }
            hashes[path] = AuthorityRecordCodec.sha256(try Data(contentsOf: url))
        }
        return hashes
    }

    private func identities(_ f: Fixture) throws -> [String] {
        let directory = f.receiverRoot.appendingPathComponent("authority/local-review-identities")
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    private func retainedWork(_ f: Fixture) throws -> [String] {
        let index = try ItemIndex(
            path: f.receiverRoot.appendingPathComponent("index/items.sqlite").path, create: false)
        let page = try index.retainedCorpusWorkPage(limit: 64)
        XCTAssertLessThan(page.count, 64, "Tiny fixture must fit one bounded ledger page.")
        return page.map(\.workID).sorted()
    }

    private func expireAndCollectHeldCorpus(
        _ f: Fixture, held: Revision, evidence: AuthorityBinding
    ) throws {
        // Applied peer intake retires its own pins. Create genuine LOCAL preparation
        // ownership, then lose only that derived work through the real idle/GC APIs.
        _ = try snapshot(f, held: held, evidence: evidence)
        let document = try XCTUnwrap(
            AttachmentDocumentRepresentation.representations(in: held.fields).first)
        try f.capacity()
        f.receiver = nil
        do {
            let index = try ItemIndex(
                path: f.receiverRoot.appendingPathComponent("index/items.sqlite").path, create: false)
            let page = try index.retainedCorpusWorkPage(limit: 64)
            XCTAssertLessThan(page.count, 64)
            var expired = 0
            for work in page where try index.peerDocumentCorpusOwner(work.workID) != nil {
                expired += try index.expirePeerDocumentCorpus(
                    work.workID, now: Date().addingTimeInterval(7200)
                ).count
            }
            XCTAssertGreaterThan(expired, 0, "Real held-document cache ownership must exist before expiry.")
            for _ in 0..<128 {
                try f.capacity()
                if try index.cleanupCorpus(limit: 1) == 0 { break }
            }
            XCTAssertFalse(try index.peerDocumentCorpusReady(document))
        }
        f.receiver = try Fixture.open(f.receiverRoot, f.receiverAccounts)
        try f.receiver.rebuildIndex()
        try f.capacity()
    }

    private func assertCode(
        _ code: String, file: StaticString = #filePath, line: UInt = #line, _ body: () throws -> Void
    ) {
        XCTAssertThrowsError(try body(), file: file, line: line) {
            XCTAssertEqual(($0 as? TractandaError)?.code, code, file: file, line: line)
        }
    }

    func testHeldDocumentRecoversAfterIdleGCAndRebuildThenReviewPublishesTextAndReplaysExactly() throws {
        let (f, attached, held, evidence, phrase) = try heldDocument()
        let preserved = try canonicalBytes(f)
        let oldHistory = try f.receiver.history(held.itemID)
        try expireAndCollectHeldCorpus(f, held: held, evidence: evidence)
        let recovered = try canonicalBytes(f)
        for (path, hash) in preserved { XCTAssertEqual(recovered[path], hash, path) }
        XCTAssertEqual(try f.receiver.history(held.itemID), oldHistory)
        XCTAssertEqual(try f.receiver.get(held.itemID), attached)
        XCTAssertTrue(try f.receiver.candidates(text: phrase).isEmpty)
        // Cold recovery may already reconstruct this tiny ready corpus from canonical
        // pages. A complete snapshot is the legitimate fast path after that rebuild.
        let rebuilt = try f.receiver.prepareAuthorityReview(
            itemID: held.itemID, revisionID: held.revisionID, evidence: evidence)
        XCTAssertEqual(rebuilt.original.revisionID, held.revisionID)
        XCTAssertTrue(try identities(f).isEmpty)
        let state = try snapshot(f, held: held, evidence: evidence)
        let request = try request(held: held, state: state, operation: Fixture.id())
        _ = try finishPreflight(f, request: request)
        XCTAssertTrue(try identities(f).isEmpty, "Storage preparation must not mint publication identities.")
        XCTAssertEqual(try canonicalBytes(f), recovered)
        XCTAssertEqual(try f.receiver.get(held.itemID), attached)
        XCTAssertTrue(try f.receiver.candidates(text: phrase).isEmpty)
        let result = try f.receiver.resolveAuthorityReview(request)
        XCTAssertFalse(result.wasReplayed)
        XCTAssertEqual(result.disposition, .approved)
        XCTAssertEqual(result.revision.fields["attachmentDocument"], held.fields["attachmentDocument"])
        XCTAssertEqual(result.revision.fields["subject"], .text("explicit reviewed document"))
        XCTAssertEqual(try f.receiver.get(held.itemID, revisionID: held.revisionID), held)
        try f.receiver.withAccess(forUID: f.receiverAccounts.alice) {
            XCTAssertEqual(try f.receiver.get(held.itemID), result.revision)
            XCTAssertEqual(try f.receiver.candidates(text: phrase).map(\.itemID), [held.itemID])
        }
        let committed = try canonicalBytes(f)
        XCTAssertEqual(try identities(f).count, 1)
        f.receiver = nil
        f.receiver = try Fixture.open(f.receiverRoot, f.receiverAccounts)
        try f.receiver.rebuildIndex()
        let beforeReplay = try canonicalBytes(f)
        let replay = try f.receiver.resolveAuthorityReview(request)
        XCTAssertTrue(replay.wasReplayed)
        XCTAssertEqual(replay.revision, result.revision)
        XCTAssertEqual(replay.decision, result.decision)
        XCTAssertEqual(try canonicalBytes(f), beforeReplay)
        for (path, hash) in committed { XCTAssertEqual(beforeReplay[path], hash, path) }
        let changed = try self.request(
            held: held, state: state, operation: request.operationID, subject: "changed intent")
        assertCode("operationMismatch") { _ = try f.receiver.resolveAuthorityReview(changed) }
        XCTAssertEqual(try canonicalBytes(f), beforeReplay)
        XCTAssertEqual(try identities(f).count, 1)
        try f.capacity()
    }

    func testStaleTokenAndChangedHeadCannotUsePreparedDocumentReviewOrMintIdentity() throws {
        let (f, attached, held, evidence, phrase) = try heldDocument()
        try expireAndCollectHeldCorpus(f, held: held, evidence: evidence)
        let state = try snapshot(f, held: held, evidence: evidence)
        let invalid = try request(
            held: held, state: state, operation: Fixture.id(), token: String(repeating: "0", count: 64))
        let unchanged = try canonicalBytes(f)
        assertCode("stateConflict") { _ = try f.receiver.preflightAuthorityReviewResolution(invalid) }
        assertCode("stateConflict") { _ = try f.receiver.resolveAuthorityReview(invalid) }
        XCTAssertEqual(try canonicalBytes(f), unchanged)
        XCTAssertTrue(try identities(f).isEmpty)
        let request = try request(held: held, state: state, operation: Fixture.id())
        var incomplete = AuthorityStore.ReviewRequest(
            itemID: held.itemID, revisionID: held.revisionID, evidence: evidence,
            expectedStateToken: state.stateToken, reviewedFrontier: state.decisionFrontier,
            reviewedControlHolds: state.controlHolds,
            changes: request.changes.filter { $0.key != "attachmentDocument" },
            unset: request.unset, operationID: try Fixture.id())
        incomplete.reviewedRetirements = state.retirements
        assertCode("invalidArguments") { _ = try f.receiver.preflightAuthorityReviewResolution(incomplete) }
        assertCode("invalidArguments") { _ = try f.receiver.resolveAuthorityReview(incomplete) }
        XCTAssertTrue(try identities(f).isEmpty)
        _ = try finishPreflight(f, request: request)
        let current = try f.receiver.withAccess(forUID: f.receiverAccounts.alice) {
            try f.receiver.commit(
                .init(
                    action: .revise, itemID: attached.itemID, expectedRevisionID: attached.revisionID,
                    changes: ["subject": .text("new accepted head")], operationID: Fixture.id())
            ).revision
        }
        let afterEdit = try canonicalBytes(f)
        assertCode("stateConflict") { _ = try f.receiver.preflightAuthorityReviewResolution(request) }
        assertCode("stateConflict") { _ = try f.receiver.resolveAuthorityReview(request) }
        XCTAssertEqual(try canonicalBytes(f), afterEdit)
        XCTAssertTrue(try identities(f).isEmpty)
        XCTAssertEqual(try f.receiver.get(held.itemID), current)
        XCTAssertTrue(try f.receiver.candidates(text: phrase).isEmpty)
        try assertHeld(f, revision: held)
        try f.capacity()
    }

    func testNonAdministratorCannotStartOrCompletePrivateDocumentReviewPreparation() throws {
        let (f, _, held, evidence, phrase) = try heldDocument()
        try expireAndCollectHeldCorpus(f, held: held, evidence: evidence)
        let before = try canonicalBytes(f)
        let beforeWork = try retainedWork(f)
        assertCode("forbidden") {
            _ = try f.receiver.preflightAuthorityReview(
                itemID: held.itemID, revisionID: held.revisionID, evidence: evidence,
                actorUID: f.receiverAccounts.alice)
        }
        assertCode("forbidden") {
            _ = try f.receiver.prepareAuthorityReview(
                itemID: held.itemID, revisionID: held.revisionID, evidence: evidence,
                actorUID: f.receiverAccounts.alice)
        }
        XCTAssertEqual(try retainedWork(f), beforeWork)
        XCTAssertEqual(try canonicalBytes(f), before)
        XCTAssertTrue(try identities(f).isEmpty)
        let state = try snapshot(f, held: held, evidence: evidence)
        let request = try request(held: held, state: state, operation: Fixture.id())
        let preparedWork = try retainedWork(f)
        assertCode("forbidden") {
            _ = try f.receiver.preflightAuthorityReviewResolution(request, actorUID: f.receiverAccounts.alice)
        }
        assertCode("forbidden") {
            _ = try f.receiver.resolveAuthorityReview(request, actorUID: f.receiverAccounts.alice)
        }
        XCTAssertEqual(try retainedWork(f), preparedWork)
        XCTAssertEqual(try canonicalBytes(f), before)
        XCTAssertTrue(try identities(f).isEmpty)
        XCTAssertTrue(try f.receiver.candidates(text: phrase).isEmpty)
        try f.capacity()
    }
}
