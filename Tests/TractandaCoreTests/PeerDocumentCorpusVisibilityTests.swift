import XCTest

@testable import TractandaCore

final class PeerDocumentCorpusVisibilityTests: XCTestCase {
    private typealias Fixture = PeerIntakeStoreTests.Fixture

    private func attach(_ f: Fixture) throws -> (Revision, AttachmentDescriptor) {
        try f.capacity()
        let bytes = Data("%PDF-1.4\ntiny visibility fixture\n".utf8)
        let result = try f.source.withAccess(forUID: f.sourceAccounts.alice) {
            let upload = try f.source.beginAttachment(
                .init(
                    itemID: f.base.itemID, expectedRevisionID: f.base.revisionID,
                    operationID: Fixture.id(), filename: "visibility.pdf", mediaType: "application/pdf",
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
        repeat {
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
        while let object = pending.popLast() {
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

    func testIncrementalDocumentTextIsInvisibleUntilAcceptedAndSearchRespectsCurrentReadACL() throws {
        let f = try Fixture()
        // Bootstrap before creating the document: acceptance must incrementally populate the corpus.
        try f.bootstrap()
        XCTAssertEqual(try f.receiver.get(f.base.itemID), f.base)
        let (attached, descriptor) = try attach(f)
        let phrase = "incremental corpus visibility"
        let saved = try save(
            f, attached: attached, descriptor: descriptor, text: phrase, actor: f.sourceAccounts.alice)
        XCTAssertEqual(try f.source.candidates(text: phrase).map(\.itemID), [saved.itemID])
        let manifest = try transfer(f, revision: saved)
        try f.receiver.withAccess(forUID: f.receiverAccounts.alice) {
            XCTAssertEqual(try f.receiver.get(saved.itemID), f.base)
            XCTAssertTrue(try f.receiver.candidates(text: phrase).isEmpty)
            XCTAssertEqual(try f.receiver.candidates(text: "base").map(\.itemID), [saved.itemID])
        }
        XCTAssertGreaterThan(try commit(f, manifest: manifest).accepted, 0)
        try f.receiver.withAccess(forUID: f.receiverAccounts.alice) {
            XCTAssertEqual(try f.receiver.get(saved.itemID), saved)
            XCTAssertEqual(try f.receiver.candidates(text: phrase).map(\.itemID), [saved.itemID])
        }
        try f.receiver.withAccess(forUID: f.receiverAccounts.bob) {
            XCTAssertEqual(try f.receiver.candidates(text: phrase).map(\.itemID), [saved.itemID])
        }
        f.receiverAccounts.bobHasGroup = false
        try f.receiver.withAccess(forUID: f.receiverAccounts.bob) {
            XCTAssertTrue(try f.receiver.candidates(text: phrase).isEmpty)
            XCTAssertThrowsError(try f.receiver.capturePageCorpus(itemID: saved.itemID)) {
                XCTAssertEqual(($0 as? TractandaError)?.code, "forbidden")
            }
        }
        try f.capacity()
    }

    func testMembershipHeldDocumentTextDoesNotJoinAnExistingReadableItem() throws {
        let f = try Fixture()
        let (attached, descriptor) = try acceptedOriginal(f)
        let phrase = "membership held corpus"
        let saved = try save(
            f, attached: attached, descriptor: descriptor, text: phrase, actor: f.sourceAccounts.bob)
        XCTAssertEqual(try f.source.candidates(text: phrase).map(\.itemID), [saved.itemID])
        f.receiverAccounts.bobHasGroup = false
        let manifest = try transfer(f, revision: saved)
        let result = try commit(f, manifest: manifest)
        try assertHeld(f, revision: saved)
        XCTAssertEqual(result.held, 1)
        try f.receiver.withAccess(forUID: f.receiverAccounts.alice) {
            XCTAssertEqual(try f.receiver.get(saved.itemID), attached)
            XCTAssertEqual(try f.receiver.candidates(text: "base").map(\.itemID), [saved.itemID])
            XCTAssertTrue(try f.receiver.candidates(text: phrase).isEmpty)
            XCTAssertFalse(
                try f.receiver.history(saved.itemID).contains { $0.revisionID == saved.revisionID })
        }
        // A disposable index rebuild must preserve the same accepted-head visibility fence.
        try f.receiver.rebuildIndex()
        try assertHeld(f, revision: saved)
        try f.receiver.withAccess(forUID: f.receiverAccounts.alice) {
            XCTAssertEqual(try f.receiver.get(saved.itemID), attached)
            XCTAssertTrue(try f.receiver.candidates(text: phrase).isEmpty)
        }
        try f.capacity()
    }

    func testWriteRevokedAfterStagingKeepsIncomingTextHiddenFromStillReadableCurrentItem() throws {
        let f = try Fixture()
        let (attached, descriptor) = try acceptedOriginal(f)
        let phrase = "revoked writer corpus"
        let saved = try save(
            f, attached: attached, descriptor: descriptor, text: phrase, actor: f.sourceAccounts.bob)
        let manifest = try transfer(f, revision: saved)
        var permissions = try XCTUnwrap(attached.fields["permissions"]?.map)
        permissions["mode"] = .integer(0o640)
        let current = try f.receiver.withAccess(forUID: f.receiverAccounts.alice) {
            try f.receiver.commit(
                .init(
                    action: .revise, itemID: attached.itemID, expectedRevisionID: attached.revisionID,
                    changes: ["permissions": .object(permissions)], operationID: Fixture.id())
            ).revision
        }
        // Bob remains a reader of this exact existing item but no longer has current write authority.
        try f.receiver.withAccess(forUID: f.receiverAccounts.bob) {
            XCTAssertEqual(try f.receiver.get(saved.itemID), current)
            XCTAssertEqual(try f.receiver.candidates(text: "base").map(\.itemID), [saved.itemID])
            XCTAssertTrue(try f.receiver.candidates(text: phrase).isEmpty)
        }
        let result = try commit(f, manifest: manifest)
        try assertHeld(f, revision: saved)
        XCTAssertEqual(result.held, 1)
        for uid in [f.receiverAccounts.alice, f.receiverAccounts.bob] {
            try f.receiver.withAccess(forUID: uid) {
                XCTAssertEqual(try f.receiver.get(saved.itemID), current)
                XCTAssertTrue(try f.receiver.candidates(text: phrase).isEmpty)
                XCTAssertFalse(
                    try f.receiver.history(saved.itemID).contains { $0.revisionID == saved.revisionID })
            }
        }
        try f.capacity()
    }
}
