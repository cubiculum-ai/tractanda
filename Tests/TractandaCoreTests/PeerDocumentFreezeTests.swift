import Crypto
import XCTest

@testable import TractandaCore

final class PeerDocumentFreezeTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let contents: DocumentContentStore
        let writer: DocumentContentWriter
        let prepared: PreparedDocumentContent
        let reference: DocumentContentReference
        let files: DocumentContentFiles
    }
    private func fixture() throws -> Fixture {
        try AttachmentFixtureCapacity.requireFree()
        let root = (try GuardedFixtureDirectory.parent()).appendingPathComponent(
            "peer-document-freeze-" + Identifier.make())
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let contents = DocumentContentStore(
            root: root, ownerUID: getuid(), minimumFreeBytes: AttachmentFixtureCapacity.reserveBytes)
        let id = try UUID.makeVersion1().uuidString.lowercased()
        let source = try AttachmentDocumentSource(
            itemID: id, revisionID: id, attachmentID: id,
            sha256: String(repeating: "a", count: 64), byteCount: 1, mediaType: "application/pdf")
        let writer = try contents.begin(source: source, identity: .init())
        for number in 1...2 {
            try writer.append(
                DocumentStoredPage(
                    pageNumber: Int64(number), sourceSHA256: source.sha256,
                    status: "failed", failureCode: "fixture"))
        }
        let prepared = try writer.preparePublication()
        let manifest = DocumentManifest(
            schema: "tractanda.document-manifest.v2", contentID: id,
            publicationID: prepared.stage[2], source: source, identity: .init(),
            extractedAt: prepared.extractedAt,
            rootLevel: prepared.rootLevel, rootByteCount: prepared.rootEntry.byteCount,
            rootSHA256: prepared.rootEntry.sha256,
            pageCount: prepared.rootEntry.lastPage, totalEncodedBytes: prepared.byteCount,
            coverage: prepared.coverage)
        let raw = try JSON.encode(manifest)
        let reference = try DocumentContentReference(
            contentID: id, manifestSHA256: AuthorityRecordCodec.sha256(raw),
            rootSHA256: manifest.rootSHA256, pageCount: manifest.pageCount,
            totalEncodedBytes: manifest.totalEncodedBytes,
            coverage: manifest.coverage)
        let files = DocumentContentFiles(
            root: root, ownerUID: getuid(), minimumFreeBytes: AttachmentFixtureCapacity.reserveBytes)
        try files.writeImmutable(raw, path: prepared.stage + ["manifest.json"])
        return .init(
            root: root, contents: contents, writer: writer, prepared: prepared, reference: reference,
            files: files)
    }
    private func frozen(_ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "peerDocumentFrozen", file: file, line: line)
        }
    }
    func testClosedStageRejectsSupportedMutationAndRemainsClosedAfterReopen() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try f.files.freezePeerStage(f.prepared.stage, reference: f.reference)
        try f.files.freezePeerStage(f.prepared.stage, reference: f.reference)
        frozen { try f.files.writeImmutable(Data([1]), path: f.prepared.stage + ["pages", "0", "3.json"]) }
        frozen { try f.files.removePrivateTree(f.prepared.stage) }
        frozen { try f.contents.discardJob(stage: f.prepared.stage, prepared: f.prepared) }
        frozen { _ = try f.contents.publishPrepared(f.prepared) }
        frozen {
            try f.files.publishDirectory(
                f.prepared.stage,
                to: ["documents", "content", "2030", "01", "01", "01", "01", f.reference.contentID])
        }
        frozen {
            try f.files.adoptPeerDocumentPart(
                stageID: UUID.makeVersion1().uuidString.lowercased(),
                to: f.prepared.stage + ["pages", "0", "3.json"], bytes: 1)
        }
        let reopened = DocumentContentFiles(
            root: f.root, ownerUID: getuid(), minimumFreeBytes: AttachmentFixtureCapacity.reserveBytes)
        XCTAssertEqual(try reopened.frozenPeerStage(f.prepared.stage)?.reference, f.reference)
        frozen { try reopened.removePrivateTree(f.prepared.stage) }
        XCTAssertEqual(try f.contents.readPreparedJobPage(f.prepared, number: 1).status, "failed")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: f.root.appendingPathComponent("documents/content").path))
    }
    func testNestedDamageBetweenVerificationAndInspectionFailsStampValidation() throws {
        for replacement in [false, true] {
            let f = try fixture()
            defer { try? FileManager.default.removeItem(at: f.root) }
            try f.files.freezePeerStage(f.prepared.stage, reference: f.reference)
            let target = (f.prepared.stage + ["pages", "0", "2.json"]).reduce(f.root) {
                $0.appendingPathComponent($1)
            }
            let original = try FileMetadata.read(at: target)
            let bytes = try Data(contentsOf: target)
            if replacement {
                try FileManager.default.removeItem(at: target)
                try bytes.write(to: target)
            } else {
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
                var changed = bytes
                changed[changed.count / 2] ^= 1
                try changed.write(to: target)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: target.path)
            let inspector = try f.contents.beginPeerInspection(base: f.prepared.stage)
            XCTAssertThrowsError(
                try inspector.step(
                    budget: .init(), synchronize: true,
                    inspect: { path, file in
                        if path == ["pages", "0", "2.json"], file.metadata != original {
                            throw TractandaError(
                                "peerObjectCollision", "Nested part differs from the verified stamp.")
                        }
                    })
            ) {
                XCTAssertEqual(($0 as? TractandaError)?.code, "peerObjectCollision")
            }
            XCTAssertFalse(inspector.complete)
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: f.root.appendingPathComponent("documents/content").path))
        }
    }
    func testDocumentSQLProgressUsesCompositeKeysAndRetainsBoundedCursor() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let index = try ItemIndex(
            path: f.root.appendingPathComponent("index/document-work-test.sqlite").path, create: true)
        try index.initializePeerDocumentSchema()
        let scope = "tiny-fixture"
        let content = f.reference.contentID
        let cursor = try JSON.encode(["ordinal": Int64.max])
        try index.peerDocumentSave(scope: scope, content: content, state: cursor)
        XCTAssertEqual(try index.peerDocumentState(scope: scope, content: content), cursor)
        let path = (f.prepared.stage + ["pages", "0", "1.json"]).reduce(f.root) {
            $0.appendingPathComponent($1)
        }
        let metadata = try FileMetadata.read(at: path)
        for part in [
            PeerPackage.DocumentPart(role: .page, level: 0, ordinal: 1),
            .init(role: .node, level: 0, ordinal: 1),
        ] {
            let object = PeerPackage.Object(
                kind: .document, id: content, length: Int(metadata.size),
                sha256: String(repeating: "a", count: 64), part: part)
            try index.peerDocumentRecord(scope: scope, object: object, metadata: metadata)
            XCTAssertEqual(try index.peerDocumentPart(scope: scope, object: object)?.0, object)
            let changed = PeerPackage.Object(
                kind: .document, id: content, length: Int(metadata.size) + 1,
                sha256: object.sha256, part: part)
            XCTAssertThrowsError(
                try index.peerDocumentRecord(scope: scope, object: changed, metadata: metadata))
        }
        try index.peerDocumentReset(scope: scope, content: content)
        XCTAssertNil(try index.peerDocumentState(scope: scope, content: content))
    }
}
