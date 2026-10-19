import XCTest

@testable import TractandaCore

final class PeerOriginalStreamTests: XCTestCase {
    typealias Fixture = PeerIntakeStoreTests.Fixture
    private func upload(
        _ f: Fixture, bytes: Data, revision: Revision? = nil, media: String = "application/octet-stream"
    ) throws -> (Revision, AttachmentDescriptor) {
        let base = revision ?? f.base!
        return try f.source.withAccess(forUID: f.sourceAccounts.alice) {
            let upload = try f.source.beginAttachment(
                .init(
                    itemID: base.itemID, expectedRevisionID: base.revisionID, operationID: Fixture.id(),
                    filename: "original.bin", mediaType: media, byteCount: Int64(bytes.count),
                    sha256: AuthorityRecordCodec.sha256(bytes)))
            let id = try XCTUnwrap(upload.uploadID)
            for offset in stride(from: 0, to: bytes.count, by: PeerPackage.maximumPayloadChunkBytes) {
                _ = try f.source.appendAttachment(
                    uploadID: id, offset: Int64(offset),
                    data: Data(
                        bytes[offset..<min(bytes.count, offset + PeerPackage.maximumPayloadChunkBytes)]))
            }
            return (try f.source.finishAttachment(uploadID: id).revision, upload.attachment)
        }
    }
    private func original(_ descriptor: AttachmentDescriptor) -> PeerPackage.Object {
        .init(
            kind: .attachment, id: descriptor.attachmentID, length: Int(descriptor.byteCount),
            sha256: descriptor.sha256)
    }
    private func content(_ store: ItemStore, revision: Revision, descriptor: AttachmentDescriptor) throws
        -> Data
    {
        var bytes = Data()
        repeat {
            let chunk = try store.attachmentContent(
                itemID: revision.itemID, revisionID: revision.revisionID,
                attachmentID: descriptor.attachmentID, offset: Int64(bytes.count),
                limit: PeerPackage.maximumPayloadChunkBytes)
            bytes.append(chunk.data)
            if chunk.isComplete { break }
            XCTAssertFalse(chunk.data.isEmpty)
        } while bytes.count < descriptor.byteCount
        return bytes
    }
    private func export(_ f: Fixture, source: ItemStore, revision: Revision) throws -> (
        PeerExportPlan.Handle, PeerPackage.Manifest
    ) {
        try source.configurePeerIntake(peers: [f.context])
        let boundary = try source.capturePeerInventory(context: f.context)
        let handle = try source.beginPeerExport(
            context: f.context, planID: Fixture.id(), packageID: Fixture.id(), boundary: boundary)
        var cursor: PeerInventory.Cursor?
        var selected: PeerInventory.Entry?
        repeat {
            let page = try source.peerInventoryPage(context: f.context, boundary: boundary, cursor: cursor)
            selected = selected ?? page.entries.first { $0.descriptor.id == revision.revisionID }
            cursor = page.nextCursor
        } while cursor != nil
        _ = try source.selectPeerExport(
            context: f.context, handle: handle, entries: [XCTUnwrap(selected)], finish: true)
        for _ in 0..<1024 {
            try f.capacity()
            let status = try source.stepPeerExport(
                context: f.context, handle: handle, window: .init(maximumUnits: 3, maximumEdges: 2))
            XCTAssertEqual(status.missing, 0)
            XCTAssertEqual(status.unsupported, 0)
            if let manifest = status.manifest { return (handle, manifest) }
        }
        throw TractandaError("testTimeout", "Tiny original export did not seal")
    }
    private func transfer(
        _ f: Fixture, source: ItemStore, target: ItemStore, handle: PeerExportPlan.Handle,
        manifest: PeerPackage.Manifest
    ) throws -> [PeerPackage.Object] {
        _ = try target.beginPeerIntake(context: f.context, manifestBytes: JSON.encode(manifest))
        var pending = [manifest.root]
        var seen: Set<String> = []
        var descriptors: [PeerPackage.Object] = []
        while let object = pending.popLast() {
            if !seen.insert(object.id).inserted { continue }
            descriptors.append(object)
            var indexBytes = Data()
            for offset in stride(from: 0, to: object.length, by: object.chunkBytes) {
                let chunk = try source.readPeerExport(
                    context: f.context, handle: handle, object: object, offset: offset)
                XCTAssertLessThanOrEqual(chunk.bytes.count, object.chunkBytes)
                _ = try target.appendPeerObject(
                    context: f.context, packageID: manifest.packageID, object: object, offset: offset,
                    bytes: chunk.bytes)
                if object.kind == .index { indexBytes.append(chunk.bytes) }
                try f.capacity()
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
            guard calls < 256 else { throw TractandaError("fixture", "Document resume did not advance") }
            let page = try target.resumePeerIntake(
                context: f.context, packageID: manifest.packageID, cursor: cursor, limit: 2)
            cursor = page.nextCursor
            for value in page.objects where value.descriptor.kind == .document && !value.verifiedComplete {
                let object = value.descriptor
                if !descriptors.contains(where: { $0.key == object.key }) { descriptors.append(object) }
                for offset in stride(from: value.nextOffset, to: object.length, by: object.chunkBytes) {
                    let chunk = try source.readPeerExport(
                        context: f.context, handle: handle, object: object, offset: offset)
                    _ = try target.appendPeerObject(
                        context: f.context, packageID: manifest.packageID,
                        object: object, offset: offset, bytes: chunk.bytes)
                    try f.capacity()
                }
            }
        } while cursor != nil
        return descriptors
    }
    func testFirstOriginalAndEmptyOriginalBootstrapIntoGenuinelyEmptyReplica() throws {
        let f = try Fixture()
        XCTAssertTrue(try f.receiver.exportCatalogueForVerification().isEmpty)
        let bytes = Data((0..<(2 * PeerPackage.maximumPayloadChunkBytes + 17)).map { UInt8($0 % 251) })
        let (attached, descriptor) = try upload(f, bytes: bytes)
        let (empty, zero) = try upload(f, bytes: Data(), revision: attached)
        // Real begin establishes canonical format before any private stage; no anchor item.
        try f.bootstrap(extra: [(original(descriptor), bytes), (original(zero), Data())])
        XCTAssertEqual(try f.receiver.get(empty.itemID), empty)
        XCTAssertEqual(try content(f.receiver, revision: empty, descriptor: descriptor), bytes)
        XCTAssertEqual(try content(f.receiver, revision: empty, descriptor: zero), Data())
        f.receiver = nil
        f.receiver = try Fixture.open(f.receiverRoot, f.receiverAccounts)
        XCTAssertEqual(try content(f.receiver, revision: empty, descriptor: descriptor), bytes)
        try f.capacity()
    }
    func testLocalTextActualExportIntakeIdempotencyAndRelayPreserveOriginalBytes() throws {
        let f = try Fixture()
        try f.bootstrap()
        XCTAssertEqual(try f.receiver.get(f.base.itemID), f.base, "Bootstrap baseline")
        let bytes = Data("UTF8 original\nwith saved text".utf8)
        let (attached, descriptor) = try upload(f, bytes: bytes, media: "text/plain")
        let savedResult = try f.source.withAccess(forUID: f.sourceAccounts.alice) {
            try f.source.extractAttachmentText(
                itemID: attached.itemID, expectedRevisionID: attached.revisionID,
                attachmentID: descriptor.attachmentID, operationID: Fixture.id()
            )
        }
        let saved = try f.source.get(savedResult.itemID)
        let (handle, manifest) = try export(f, source: f.source, revision: saved)
        let objects = try transfer(
            f, source: f.source, target: f.receiver, handle: handle, manifest: manifest)
        XCTAssertTrue(objects.contains(original(descriptor)))
        XCTAssertTrue(objects.contains { $0.id == attached.revisionID })
        let result: AuthorityStore.Result
        do {
            result = try f.receiver.commitPeerIntake(
                context: f.context, packageID: manifest.packageID,
                expectedContextToken: f.receiver.peerIntakeContextToken())
        } catch { throw TractandaError("testFirstIntake", String(describing: error)) }
        XCTAssertGreaterThan(result.accepted, 0)
        XCTAssertEqual(try f.receiver.get(saved.itemID).revisionID, saved.revisionID)
        XCTAssertEqual(try content(f.receiver, revision: saved, descriptor: descriptor), bytes)
        do {
            _ = try f.receiver.commitPeerIntake(
                context: f.context, packageID: manifest.packageID,
                expectedContextToken: f.receiver.peerIntakeContextToken())
        } catch { throw TractandaError("testIdempotentIntake", String(describing: error)) }
        // Relay back through a fresh v2 plan uses retained source evidence, not local authorship.
        let (relay, relayed) = try export(f, source: f.receiver, revision: saved)
        _ = try transfer(f, source: f.receiver, target: f.source, handle: relay, manifest: relayed)
        do {
            _ = try f.source.commitPeerIntake(
                context: f.context, packageID: relayed.packageID,
                expectedContextToken: f.source.peerIntakeContextToken())
        } catch { throw TractandaError("testRelayedIntake", String(describing: error)) }
        XCTAssertEqual(try f.source.get(saved.itemID), saved)
        f.receiverAccounts.bobHasGroup = false
        XCTAssertThrowsError(
            try f.receiver.withAccess(forUID: f.receiverAccounts.bob) {
                try content(f.receiver, revision: saved, descriptor: descriptor)
            }
        ) { XCTAssertEqual(($0 as? TractandaError)?.code, "forbidden") }
        f.receiver = nil
        f.receiver = try Fixture.open(f.receiverRoot, f.receiverAccounts)
        XCTAssertEqual(try content(f.receiver, revision: saved, descriptor: descriptor), bytes)
        try f.capacity()
    }
    func testMissingOriginalDescriptorCannotSealOrCreateCanonicalReference() throws {
        let f = try Fixture()
        try f.bootstrap()
        XCTAssertEqual(try f.receiver.get(f.base.itemID), f.base, "Bootstrap baseline")
        let (attached, _) = try upload(f, bytes: Data("missing original".utf8))
        let packet = try f.packet(f.source.peerMetadataObjects(revisionID: attached.revisionID))
        XCTAssertThrowsError(try f.send(packet)) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "missingDependencies")
        }
        XCTAssertEqual(try f.receiver.get(f.base.itemID), f.base)
        XCTAssertThrowsError(try f.receiver.get(attached.itemID, revisionID: attached.revisionID))
        try f.capacity()
    }
    func testSavedPartialDocumentBootstrapsEmptyReceiverWithExactBytesAndCurrentACL() throws {
        let f = try Fixture()
        XCTAssertTrue(try f.receiver.exportCatalogueForVerification().isEmpty)
        let (attached, descriptor) = try upload(
            f, bytes: Data("%PDF-1.4\nsynthetic\n".utf8), media: "application/pdf")
        let saved = try f.source.withAccess(forUID: f.sourceAccounts.alice) {
            guard
                case .prepared(let snapshot) = try f.source.prepareAttachmentDocument(
                    itemID: attached.itemID, expectedRevisionID: attached.revisionID,
                    attachmentID: descriptor.attachmentID, operationID: Fixture.id(), identity: .init())
            else { throw TractandaError("fixture", "Expected document preparation") }
            let writer = try DocumentContentStore(
                root: f.sourceRoot, ownerUID: getuid(),
                minimumFreeBytes: AttachmentFixtureCapacity.reserveBytes
            ).begin(source: snapshot.source, identity: .init(), maximumWriteBytes: 1024 * 1024)
            let parsed = try DoclingDocTagsParser.parse(
                Data("<doctag><text>saved local page</text></doctag>".utf8))
            let geometry = try DocumentPageGeometry(
                sourceWidth: 512, sourceHeight: 256, sourceUnit: "pdfPoint", displayWidth: 512,
                displayHeight: 256, canvasWidth: 2048, canvasHeight: 1024, contentLeft: 0, contentTop: 0,
                contentWidth: 2048, contentHeight: 1024)
            try writer.append(
                DocumentStoredPage(
                    pageNumber: 1, sourceSHA256: snapshot.source.sha256,
                    page: AttachmentDocumentPage(
                        pageNumber: 1, geometry: geometry, rasterSHA256: String(repeating: "b", count: 64),
                        parsed: parsed, generatedTokens: 512, stopReason: "stop")))
            try writer.append(
                DocumentStoredPage(
                    pageNumber: 2, sourceSHA256: snapshot.source.sha256,
                    status: "failed", failureCode: "fixture"))
            try writer.append(
                DocumentStoredPage(
                    pageNumber: 3, sourceSHA256: snapshot.source.sha256,
                    status: "timeout", failureCode: "fixture"))
            let prepared = try writer.preparePublication()
            let corpus = try f.source.prepareAttachmentDocumentCorpus(snapshot, prepared: prepared)
            return try f.source.finishAttachmentDocument(snapshot, prepared: prepared, corpus: corpus)
        }
        let revision = try f.source.get(saved.itemID)
        XCTAssertNotNil(revision.fields["attachmentDocument"])
        try f.source.rebuildIndex()
        XCTAssertEqual(try f.source.get(saved.itemID), revision)
        try f.source.configurePeerIntake(peers: [f.context])
        let boundary = try f.source.capturePeerInventory(context: f.context)
        let handle = try f.source.beginPeerExport(
            context: f.context, planID: Fixture.id(), packageID: Fixture.id(), boundary: boundary)
        var cursor: PeerInventory.Cursor?
        var selected: PeerInventory.Entry?
        repeat {
            let page = try f.source.peerInventoryPage(context: f.context, boundary: boundary, cursor: cursor)
            selected = selected ?? page.entries.first { $0.descriptor.id == revision.revisionID }
            cursor = page.nextCursor
        } while cursor != nil
        _ = try f.source.selectPeerExport(
            context: f.context, handle: handle, entries: [XCTUnwrap(selected)], finish: true)
        var status = try f.source.inspectPeerExport(context: f.context, handle: handle)
        for _ in 0..<512 {
            status = try f.source.stepPeerExport(context: f.context, handle: handle)
            if status.pending == 0 { break }
        }
        XCTAssertEqual(status.unsupported, 0)
        let manifest = try XCTUnwrap(status.manifest)
        let transferred = try transfer(
            f, source: f.source, target: f.receiver, handle: handle, manifest: manifest)
        _ = try f.receiver.commitPeerIntake(
            context: f.context, packageID: manifest.packageID,
            expectedContextToken: f.receiver.peerIntakeContextToken())
        let document = try XCTUnwrap(
            AttachmentDocumentRepresentation.representations(in: revision.fields).first)
        let reference = try XCTUnwrap(document.content)
        let sourceContents = DocumentContentStore(
            root: f.sourceRoot, ownerUID: getuid(),
            minimumFreeBytes: AttachmentFixtureCapacity.reserveBytes)
        let manifestObject = try sourceContents.peerManifestDescriptor(reference)
        let rawManifest = try sourceContents.peerManifestBytes(reference, budget: .init())
        // The explicit initial authority pin completes the genuine empty-replica bootstrap.
        // Its metadata-only manifest reuses the exact tree already durably transferred above.
        try f.bootstrap(extra: [
            (original(descriptor), Data("%PDF-1.4\nsynthetic\n".utf8)), (manifestObject, rawManifest),
        ])
        XCTAssertEqual(try f.receiver.get(saved.itemID), revision)
        let receiverContents = DocumentContentStore(
            root: f.receiverRoot, ownerUID: getuid(),
            minimumFreeBytes: AttachmentFixtureCapacity.reserveBytes)
        for object in transferred where object.kind == .document {
            let part = try XCTUnwrap(object.part)
            let sourcePath = try sourceContents.directory(object.id) + part.relativePath
            let receiverPath = try receiverContents.directory(object.id) + part.relativePath
            XCTAssertEqual(
                try Data(contentsOf: sourcePath.reduce(f.sourceRoot) { $0.appendingPathComponent($1) }),
                try Data(contentsOf: receiverPath.reduce(f.receiverRoot) { $0.appendingPathComponent($1) }))
        }
        XCTAssertEqual(try receiverContents.readPage(reference, pageNumber: 2).status, "failed")
        XCTAssertEqual(try receiverContents.readPage(reference, pageNumber: 3).status, "timeout")
        f.receiverAccounts.bobHasGroup = false
        XCTAssertThrowsError(
            try f.receiver.withAccess(forUID: f.receiverAccounts.bob) {
                try f.receiver.documentContentPart(
                    itemID: saved.itemID, attachmentID: descriptor.attachmentID, kind: "manifest")
            }
        ) { XCTAssertEqual(($0 as? TractandaError)?.code, "forbidden") }
        f.receiver = nil
        f.receiver = try Fixture.open(f.receiverRoot, f.receiverAccounts)
        XCTAssertEqual(try f.receiver.get(saved.itemID), revision)
        try f.capacity()
    }
    func testPublishedOriginalPrecedesAnyCanonicalReferenceAndSealedCrashRecovers() throws {
        let f = try Fixture()
        try f.bootstrap()
        let bytes = Data(repeating: 0x87, count: 2 * PeerPackage.maximumPayloadChunkBytes + 3)
        let (attached, descriptor) = try upload(f, bytes: bytes)
        let (handle, manifest) = try export(f, source: f.source, revision: attached)
        _ = try transfer(f, source: f.source, target: f.receiver, handle: handle, manifest: manifest)
        var observed = false
        f.receiver.peerIntakeOriginalPublicationForTesting = {
            let payloads = try AttachmentPayloadStore(
                root: f.receiverRoot, ownerUID: getuid(), reserveBytes: 0)
            try payloads.validate(descriptor: descriptor)
            XCTAssertEqual(
                try payloads.read(
                    descriptor: descriptor, offset: 0, limit: PeerPackage.maximumPayloadChunkBytes,
                    requireVerified: true), Data(bytes.prefix(PeerPackage.maximumPayloadChunkBytes)))
            observed = true
            throw TractandaError("injectedPublicationCrash", "Original verified before canonical metadata")
        }
        XCTAssertThrowsError(
            try f.receiver.commitPeerIntake(
                context: f.context, packageID: manifest.packageID,
                expectedContextToken: f.receiver.peerIntakeContextToken())
        ) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "injectedPublicationCrash")
        }
        XCTAssertTrue(observed)
        f.receiver = nil
        f.receiver = try Fixture.open(f.receiverRoot, f.receiverAccounts)
        XCTAssertEqual(
            try f.receiver.inspectPeerIntake(context: f.context, packageID: manifest.packageID).phase,
            .applied)
        XCTAssertEqual(try f.receiver.get(attached.itemID).revisionID, attached.revisionID)
        XCTAssertEqual(try content(f.receiver, revision: attached, descriptor: descriptor), bytes)
        try f.capacity()
    }

    func testMissingCanonicalOriginalLeavesExplicitExportDependencyAndCannotSeal() throws {
        let f = try Fixture()
        let (attached, descriptor) = try upload(f, bytes: Data("missing export original".utf8))
        let payloads = try AttachmentPayloadStore(root: f.sourceRoot, ownerUID: getuid(), reserveBytes: 0)
        let path = try XCTUnwrap(payloads.resolvedPayloadPath(descriptor.attachmentID))
        try FileManager.default.removeItem(at: f.sourceRoot.appendingPathComponent(path))
        try f.source.configurePeerIntake(peers: [f.context])
        let boundary = try f.source.capturePeerInventory(context: f.context)
        let handle = try f.source.beginPeerExport(
            context: f.context, planID: Fixture.id(), packageID: Fixture.id(), boundary: boundary)
        var cursor: PeerInventory.Cursor?
        var entry: PeerInventory.Entry?
        repeat {
            let page = try f.source.peerInventoryPage(context: f.context, boundary: boundary, cursor: cursor)
            entry = entry ?? page.entries.first { $0.descriptor.id == attached.revisionID }
            cursor = page.nextCursor
        } while cursor != nil
        _ = try f.source.selectPeerExport(
            context: f.context, handle: handle, entries: [XCTUnwrap(entry)], finish: true)
        var status = try f.source.inspectPeerExport(context: f.context, handle: handle)
        for _ in 0..<512 {
            status = try f.source.stepPeerExport(context: f.context, handle: handle)
            if status.missing > 0 { break }
        }
        XCTAssertGreaterThan(status.missing, 0)
        XCTAssertNil(status.manifest)
        XCTAssertNil(try f.source.peerExportManifest(context: f.context, handle: handle))
        try f.capacity()
    }

    func testRetiredIncomingProfileOnEmptyReplicaCannotCreateCanonicalGateOrStage() throws {
        let f = try Fixture()
        XCTAssertTrue(try f.receiver.exportCatalogueForVerification().isEmpty)
        let before = try CanonicalReaderRequirement.load(root: f.receiverRoot, ownerUID: getuid())
        let replica = f.receiver.replicaID
        let root = PeerPackage.Object(
            kind: .index, id: try Fixture.id(), length: 2,
            sha256: AuthorityRecordCodec.sha256(Data("{}".utf8)))
        let manifest = PeerPackage.Manifest(
            packageID: try Fixture.id(), storeID: f.storeID, root: root,
            profile: PeerPackage.retainedMetadataProfile)
        XCTAssertThrowsError(
            try f.receiver.beginPeerIntake(context: f.context, manifestBytes: JSON.encode(manifest))
        ) { XCTAssertEqual(($0 as? TractandaError)?.code, "invalidPeerPackage") }
        XCTAssertEqual(try CanonicalReaderRequirement.load(root: f.receiverRoot, ownerUID: getuid()), before)
        XCTAssertEqual(f.receiver.replicaID, replica)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: f.receiverRoot.appendingPathComponent("authority/intake/" + manifest.packageID).path))
        try f.capacity()
    }

}
