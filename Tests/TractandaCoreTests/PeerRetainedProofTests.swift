import CTractandaPlatform
import Foundation
import XCTest

@testable import TractandaCore

final class PeerRetainedProofTests: XCTestCase {
    private typealias Fixture = PeerIntakeStoreTests.Fixture
    private typealias ObjectBytes = (PeerPackage.Object, Data)

    /// Frozen historical disk state, never submitted through the current intake writer.
    private struct FrozenPackage {
        let manifest: PeerPackage.Manifest
        let context: PeerPackage.Context
        let objects: [ObjectBytes]
        let publication: PeerIntakeJournal.Publication
        let files: [String: Data]
    }

    private func code(_ expected: String, _ body: () throws -> Void) {
        XCTAssertThrowsError(try body()) { XCTAssertEqual(($0 as? TractandaError)?.code, expected) }
    }

    private func frozen(
        _ values: [ObjectBytes], context: PeerPackage.Context, contextToken: String,
        phase: PeerPackage.IntakePhase, packageID: String? = nil,
        profile: String = PeerPackage.retainedMetadataProfile
    ) throws -> FrozenPackage {
        let pageBytes = try JSON.encode(PeerPackage.Page(objects: values.map(\.0), children: []))
        let root = PeerPackage.Object(
            kind: .index, id: try Fixture.id(), length: pageBytes.count,
            sha256: AuthorityRecordCodec.sha256(pageBytes))
        let manifest = PeerPackage.Manifest(
            packageID: try packageID ?? Fixture.id(), storeID: context.storeID, root: root,
            profile: profile)
        let publication = PeerIntakeJournal.Publication(
            packageID: manifest.packageID,
            manifestDigest: AuthorityRecordCodec.sha256(try JSON.encode(manifest)),
            context: context, contextToken: contextToken, arrivalMinute: "2026/10/16/12/34")
        let base = "authority/intake/" + manifest.packageID + "/"
        var files = [
            base + "begin.json": try JSON.encode(
                PeerIntakeJournal.Begin(manifest: manifest, context: context))
        ]
        let objects = [(root, pageBytes)] + values
        for (object, bytes) in objects {
            let path = base + "objects/" + object.id + "/"
            files[path + "descriptor.json"] = try JSON.encode(object)
            for offset in stride(from: 0, to: bytes.count, by: PeerPackage.maximumChunkBytes) {
                let chunk = Data(bytes[offset..<min(bytes.count, offset + PeerPackage.maximumChunkBytes)])
                files[path + String(offset)] = chunk
                files[path + String(offset) + ".proof.json"] = try JSON.encode(
                    PeerIntakeJournal.ChunkProof(
                        object: object, offset: offset, length: chunk.count,
                        sha256: AuthorityRecordCodec.sha256(chunk)))
            }
        }
        let phaseBytes = try JSON.encode(publication)
        if phase != .staged { files[base + "prepared.json"] = phaseBytes }
        if phase == .sealed || phase == .applied { files[base + "sealed.json"] = phaseBytes }
        if phase == .applied { files[base + "applied.json"] = phaseBytes }
        guard files.values.reduce(0, { $0 + $1.count }) <= 1024 * 1024 else {
            throw TractandaError("resourceLimit", "Retained proof fixture exceeds its 1 MiB estimate.")
        }
        return .init(
            manifest: manifest, context: context, objects: objects, publication: publication, files: files)
    }

    private func seed(_ files: [String: Data], root: URL, fixture: Fixture) throws {
        // Callers close the relevant Store first; these are immutable pre-upgrade fixture bytes.
        let io = DocumentContentFiles(
            root: root, ownerUID: tractanda_uid(), minimumFreeBytes: AttachmentFixtureCapacity.reserveBytes)
        for path in files.keys.sorted() {
            try fixture.capacity()
            try io.writeImmutable(
                try XCTUnwrap(files[path]), path: path.split(separator: "/").map(String.init),
                maximumBytes: PeerPackage.maximumChunkBytes)
        }
        try fixture.capacity()
    }

    private func assertPreserved(
        _ files: [String: Data], root: URL, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        for (path, bytes) in files {
            let retained = try Data(contentsOf: root.appendingPathComponent(path))
            XCTAssertEqual(
                AuthorityRecordCodec.sha256(retained), AuthorityRecordCodec.sha256(bytes), file: file,
                line: line)
            XCTAssertEqual(
                retained, bytes,
                "Retained original changed: \(path)", file: file, line: line)
        }
    }

    private func assertPublishedPreserved(_ package: FrozenPackage, root: URL) throws -> [String: Data] {
        let base = "authority/intake/" + package.manifest.packageID + "/objects/"
        let index = base + package.manifest.root.id + "/"
        // Publication consumes item/authority staging duplicates. Begin, phase records and the
        // index descriptor/chunks/proofs remain immutable historical framing.
        try assertPreserved(
            package.files.filter { !$0.key.hasPrefix(base) || $0.key.hasPrefix(index) }, root: root)
        let journal = PeerIntakeJournal(root: root, ownerUID: tractanda_uid())
        var locators: [String: Data] = [:]
        for (object, original) in package.objects where object.kind != .index {
            let locatorPath = try journal.canonicalPath(object, publication: package.publication)
            let locator = try journal.files.read(path: locatorPath, maximumBytes: 512)
            let relative = try XCTUnwrap(String(data: locator, encoding: .utf8))
            // retainedBytes validates the exact original ID, digest, length and safe locator,
            // including held originals that cannot be fetched through the accepted-head API.
            XCTAssertEqual(try journal.retainedBytes(object, publication: package.publication), original)
            let canonical = try Data(contentsOf: root.appendingPathComponent(relative))
            XCTAssertEqual(canonical, original)
            XCTAssertEqual(canonical.count, object.length)
            XCTAssertEqual(AuthorityRecordCodec.sha256(canonical), object.sha256)
            locators[locatorPath.joined(separator: "/")] = locator
        }
        return locators
    }

    private func recoverSealed(held: Bool, profile: String = PeerPackage.retainedMetadataProfile) throws {
        let f = try Fixture()
        try f.bootstrap()
        let version = profile == PeerPackage.retainedMetadataProfile ? "v1" : "v2"
        let next = try f.edit(
            uid: held ? f.sourceAccounts.bob : f.sourceAccounts.alice,
            subject: (held ? "retained held " : "retained accepted ") + version)
        let values = try f.source.peerMetadataObjects(revisionID: next.revisionID)
        XCTAssertTrue(values.contains { Fixture.isEvidence($0, for: next.revisionID) })
        let package = try frozen(
            values, context: f.context, contextToken: f.receiver.peerIntakeContextToken(), phase: .sealed,
            profile: profile)
        if held { f.receiverAccounts.bobHasGroup = false }
        f.receiver = nil
        try seed(package.files, root: f.receiverRoot, fixture: f)
        try FileManager.default.removeItem(at: f.receiverRoot.appendingPathComponent("index"))
        f.receiver = try Fixture.open(f.receiverRoot, f.receiverAccounts)

        let state = try f.receiver.inspectPeerIntake(
            context: f.context, packageID: package.manifest.packageID)
        XCTAssertEqual(state.phase, .applied)
        XCTAssertFalse(state.recoveryRequired)
        XCTAssertEqual(state.manifestDigest, package.publication.manifestDigest)
        XCTAssertEqual(
            try f.receiver.get(next.itemID).revisionID, held ? f.base.revisionID : next.revisionID)
        XCTAssertEqual(
            try f.receiver.history(next.itemID).contains { $0.revisionID == next.revisionID }, !held)
        let page = try f.receiver.resumePeerIntake(
            context: f.context, packageID: package.manifest.packageID)
        let resumed = try XCTUnwrap(page.objects.first { $0.descriptor.id == next.revisionID })
        XCTAssertEqual(resumed.nextOffset, try XCTUnwrap(values.first { $0.0.id == next.revisionID }).1.count)
        XCTAssertEqual(resumed.evaluation?.disposition, held ? .held : .eligible)
        if !held {
            XCTAssertEqual(try f.receiver.get(next.itemID), next)
            let exported = try f.receiver.peerMetadataObjects(revisionID: next.revisionID)
            let original = try XCTUnwrap(values.first { $0.0.id == next.revisionID })
            XCTAssertEqual(exported.first { $0.0 == original.0 }?.1, original.1)
            XCTAssertTrue(exported.contains { Fixture.isEvidence($0, for: next.revisionID) })
        }
        code("invalidPeerPackage") {
            _ = try f.receiver.beginPeerIntake(
                context: f.context, manifestBytes: JSON.encode(package.manifest))
        }
        let locators = try assertPublishedPreserved(package, root: f.receiverRoot)
        f.receiver = nil
        f.receiver = try Fixture.open(f.receiverRoot, f.receiverAccounts)
        try f.receiver.rebuildIndex()
        XCTAssertEqual(
            try f.receiver.get(next.itemID).revisionID, held ? f.base.revisionID : next.revisionID)
        XCTAssertEqual(try assertPublishedPreserved(package, root: f.receiverRoot), locators)
        try f.capacity()
    }

    func testSealedV1UnappliedProofRecoversAcceptedSourceIntentWithoutChangingBytes() throws {
        try recoverSealed(held: false)
    }

    func testSealedV1UnappliedProofPreservesCurrentPermissionHoldAcrossColdRebuild() throws {
        try recoverSealed(held: true)
    }

    func testSealedV2UnappliedProofRecoversAcceptedSourceIntentWithoutChangingBytes() throws {
        try recoverSealed(held: false, profile: PeerPackage.retainedOriginalProfile)
    }

    func testSealedV2UnappliedProofPreservesCurrentPermissionHoldAcrossColdRebuild() throws {
        try recoverSealed(held: true, profile: PeerPackage.retainedOriginalProfile)
    }

    func testReservedLocalBeginAndPreparedStageObjectsKeepExactV1ManifestDigest() throws {
        try reservedLocal(profile: PeerPackage.retainedMetadataProfile)
    }

    func testReservedLocalBeginAndPreparedStageObjectsKeepExactV2ManifestDigest() throws {
        try reservedLocal(profile: PeerPackage.retainedOriginalProfile)
    }

    func testReservedLocalV1SavedDocumentHistoryPreservesExactCanonicalTreeAcrossColdRebuild() throws {
        try reservedLocal(profile: PeerPackage.retainedMetadataProfile, savedDocument: true)
    }

    func testReservedLocalV2SavedDocumentHistoryPreservesExactCanonicalTreeAcrossColdRebuild() throws {
        try reservedLocal(profile: PeerPackage.retainedOriginalProfile, savedDocument: true)
    }

    private func saveDocument(_ f: Fixture) throws -> Revision {
        try f.capacity()
        return try f.source.withAccess(forUID: f.sourceAccounts.alice) {
            let original = Data("%PDF-1.4\nretained tiny original\n".utf8)
            let upload = try f.source.beginAttachment(
                .init(
                    itemID: f.base.itemID, expectedRevisionID: f.base.revisionID,
                    operationID: Fixture.id(), filename: "retained.pdf", mediaType: "application/pdf",
                    byteCount: Int64(original.count), sha256: AuthorityRecordCodec.sha256(original)))
            let uploadID = try XCTUnwrap(upload.uploadID)
            _ = try f.source.appendAttachment(uploadID: uploadID, offset: 0, data: original)
            let attached = try f.source.finishAttachment(uploadID: uploadID).revision
            guard
                case .prepared(let snapshot) = try f.source.prepareAttachmentDocument(
                    itemID: attached.itemID, expectedRevisionID: attached.revisionID,
                    attachmentID: upload.attachment.attachmentID, operationID: Fixture.id(), identity: .init()
                )
            else { throw TractandaError("fixture", "Expected retained document preparation") }
            let writer = try DocumentContentStore(
                root: f.sourceRoot, ownerUID: tractanda_uid(),
                minimumFreeBytes: AttachmentFixtureCapacity.reserveBytes
            ).begin(source: snapshot.source, identity: .init(), maximumWriteBytes: 128 * 1024)
            let parsed = try DoclingDocTagsParser.parse(
                Data("<doctag><text>retained canonical page</text></doctag>".utf8))
            let geometry = try DocumentPageGeometry(
                sourceWidth: 512, sourceHeight: 256, sourceUnit: "pdfPoint", displayWidth: 512,
                displayHeight: 256, canvasWidth: 2048, canvasHeight: 1024, contentLeft: 0, contentTop: 0,
                contentWidth: 2048, contentHeight: 1024)
            try writer.append(
                DocumentStoredPage(
                    pageNumber: 1, sourceSHA256: snapshot.source.sha256,
                    page: AttachmentDocumentPage(
                        pageNumber: 1, geometry: geometry, rasterSHA256: String(repeating: "b", count: 64),
                        parsed: parsed, generatedTokens: 16, stopReason: "stop")))
            try writer.append(
                DocumentStoredPage(
                    pageNumber: 2, sourceSHA256: snapshot.source.sha256,
                    status: "failed", failureCode: "retained-fixture"))
            let prepared = try writer.preparePublication()
            let corpus = try f.source.prepareAttachmentDocumentCorpus(snapshot, prepared: prepared)
            let saved = try f.source.finishAttachmentDocument(snapshot, prepared: prepared, corpus: corpus)
            let revision = try f.source.get(saved.itemID)
            let document = try XCTUnwrap(
                AttachmentDocumentRepresentation.representations(in: revision.fields).first)
            XCTAssertEqual(document.state, "partial")
            try f.capacity()
            return revision
        }
    }

    private func documentFiles(_ f: Fixture, revision: Revision) throws -> [String: Data] {
        let document = try XCTUnwrap(
            AttachmentDocumentRepresentation.representations(in: revision.fields).first)
        let reference = try XCTUnwrap(document.content)
        let contents = DocumentContentStore(
            root: f.sourceRoot, ownerUID: tractanda_uid(),
            minimumFreeBytes: AttachmentFixtureCapacity.reserveBytes)
        let directory = try contents.directory(reference.contentID)
        var files: [String: Data] = [:]
        for part in [
            PeerPackage.DocumentPart.manifest,
            .init(role: .node, level: 0, ordinal: 0),
            .init(role: .page, level: 0, ordinal: 1),
            .init(role: .page, level: 0, ordinal: 2),
        ] {
            try f.capacity()
            let path = directory + part.relativePath
            let raw = try Data(contentsOf: path.reduce(f.sourceRoot) { $0.appendingPathComponent($1) })
            XCTAssertLessThanOrEqual(raw.count, 128 * 1024)
            files[path.joined(separator: "/")] = raw
        }
        XCTAssertEqual(files.count, 4)
        XCTAssertEqual(try contents.readPage(reference, pageNumber: 2).status, "failed")
        return files
    }

    private func reservedLocal(profile: String, savedDocument: Bool = false) throws {
        for phase in [PeerPackage.IntakePhase.staged, .prepared] {
            let f = try Fixture()
            let revision = try savedDocument ? saveDocument(f) : f.base!
            let values = try f.source.peerMetadataObjects(revisionID: revision.revisionID)
            let canonical = try savedDocument ? documentFiles(f, revision: revision) : [:]
            let history = try f.source.history(revision.itemID)
            let token = try f.source.peerIntakeContextToken()
            f.source = nil
            let coordinator = PeerIntakeCoordinator(
                root: f.sourceRoot, ownerUID: tractanda_uid(), storeID: f.storeID)
            let local = try coordinator.context(peerID: "local")
            let package = try frozen(
                values, context: local, contextToken: token, phase: phase, profile: profile)
            let initial =
                phase == .staged
                ? package.files.filter { $0.key.hasSuffix("/begin.json") } : package.files
            try seed(initial, root: f.sourceRoot, fixture: f)

            // This is the reserved-Begin continuation seam, not a full operation-authority test.
            let manifest = try coordinator.stageObjects(
                values, context: local, packageID: package.manifest.packageID)
            XCTAssertEqual(manifest, package.manifest)
            XCTAssertEqual(
                AuthorityRecordCodec.sha256(try JSON.encode(manifest)), package.publication.manifestDigest)
            try coordinator.journal.prepare(package.publication)
            XCTAssertEqual(
                try coordinator.journal.intakeState(context: local, packageID: manifest.packageID).phase,
                .prepared)
            try assertPreserved(
                package.files.filter { !$0.key.hasSuffix("/sealed.json") }, root: f.sourceRoot)

            let first = try XCTUnwrap(values.first)
            let changedBytes = first.1 + Data("changed".utf8)
            let changed = PeerPackage.Object(
                kind: first.0.kind, id: first.0.id, length: changedBytes.count,
                sha256: AuthorityRecordCodec.sha256(changedBytes))
            code("invalidPeerPackage") {
                _ = try coordinator.stageObjects(
                    [(changed, changedBytes)] + values.dropFirst(), context: local,
                    packageID: manifest.packageID)
            }
            try assertPreserved(package.files, root: f.sourceRoot)
            let fresh = try coordinator.stageObjects(values, context: local, packageID: Fixture.id())
            XCTAssertEqual(fresh.profile, "tractanda.peer-package.v3")
            try assertPreserved(canonical, root: f.sourceRoot)
            try FileManager.default.removeItem(at: f.sourceRoot.appendingPathComponent("index"))
            f.source = try Fixture.open(f.sourceRoot, f.sourceAccounts)
            try f.source.rebuildIndex()
            XCTAssertEqual(try f.source.get(revision.itemID), revision)
            XCTAssertEqual(try f.source.history(revision.itemID), history)
            if savedDocument {
                let document = try XCTUnwrap(
                    AttachmentDocumentRepresentation.representations(in: revision.fields).first)
                f.sourceAccounts.bobHasGroup = false
                for historical in history {
                    code("forbidden") {
                        _ = try f.source.withAccess(forUID: f.sourceAccounts.bob) {
                            try f.source.get(revision.itemID, revisionID: historical.revisionID)
                        }
                    }
                }
                code("forbidden") {
                    _ = try f.source.withAccess(forUID: f.sourceAccounts.bob) {
                        try f.source.documentContentPart(
                            itemID: revision.itemID, revisionID: revision.revisionID,
                            attachmentID: document.attachmentID, kind: "manifest")
                    }
                }
            }
            try assertPreserved(package.files, root: f.sourceRoot)
            try assertPreserved(canonical, root: f.sourceRoot)
            try f.capacity()
        }
    }

    func testUnsealedForeignV1StagesRemainAccountedAndCannotGainNetworkAcceptance() throws {
        try unsealedForeign(profile: PeerPackage.retainedMetadataProfile)
    }

    func testUnsealedForeignV2StagesRemainAccountedAndCannotGainNetworkAcceptance() throws {
        try unsealedForeign(profile: PeerPackage.retainedOriginalProfile)
    }

    private func unsealedForeign(profile: String) throws {
        let f = try Fixture()
        try f.bootstrap()
        let next = try f.edit(subject: "unsealed historical bytes")
        let values = try f.source.peerMetadataObjects(revisionID: next.revisionID)
        XCTAssertEqual(try f.packet(values).manifest.profile, "tractanda.peer-package.v3")
        let token = try f.receiver.peerIntakeContextToken()
        let package = try frozen(
            values, context: f.context, contextToken: token, phase: .staged, profile: profile)
        // Even unsupported old foreign object stages must survive without becoming active.
        let unsupportedBytes = Data("unsupported retained document stage".utf8)
        let unsupported = PeerPackage.Object(
            kind: .document, id: try Fixture.id(), length: unsupportedBytes.count,
            sha256: AuthorityRecordCodec.sha256(unsupportedBytes))
        let oldDocument = try frozen(
            [(unsupported, unsupportedBytes)], context: f.context, contextToken: token, phase: .staged,
            profile: profile)
        let frozenFiles = package.files.merging(oldDocument.files) { old, _ in old }
        f.receiver = nil
        try seed(frozenFiles, root: f.receiverRoot, fixture: f)
        let quota = try StagingByteQuota(
            root: f.receiverRoot, ownerUID: tractanda_uid(),
            maximumBytes: Int64(AttachmentFixtureCapacity.fixtureCapBytes))
        XCTAssertEqual(quota.usedBytes, Int64(frozenFiles.values.reduce(0) { $0 + $1.count }))
        f.receiver = try Fixture.open(f.receiverRoot, f.receiverAccounts)
        for old in [package, oldDocument] {
            let state = try f.receiver.inspectPeerIntake(
                context: f.context, packageID: old.manifest.packageID)
            XCTAssertEqual(state.phase, .staged)
            XCTAssertFalse(state.recoveryRequired)
            code("invalidPeerPackage") {
                _ = try f.receiver.beginPeerIntake(
                    context: f.context, manifestBytes: JSON.encode(old.manifest))
            }
            code("historicalPeerPackage") {
                let object = try XCTUnwrap(old.objects.first)
                _ = try f.receiver.appendPeerObject(
                    context: f.context, packageID: old.manifest.packageID,
                    object: object.0, offset: 0, bytes: object.1)
            }
            code("historicalPeerPackage") {
                _ = try f.receiver.commitPeerIntake(
                    context: f.context, packageID: old.manifest.packageID,
                    expectedContextToken: f.receiver.peerIntakeContextToken())
            }
        }
        XCTAssertEqual(try f.receiver.get(next.itemID), f.base)
        XCTAssertFalse(try f.receiver.history(next.itemID).contains { $0.revisionID == next.revisionID })
        try f.receiver.rebuildIndex()
        try assertPreserved(frozenFiles, root: f.receiverRoot)
        let reopenedQuota = try StagingByteQuota(
            root: f.receiverRoot, ownerUID: tractanda_uid(),
            maximumBytes: Int64(AttachmentFixtureCapacity.fixtureCapBytes))
        XCTAssertEqual(reopenedQuota.usedBytes, quota.usedBytes)
        try f.capacity()
    }
}
