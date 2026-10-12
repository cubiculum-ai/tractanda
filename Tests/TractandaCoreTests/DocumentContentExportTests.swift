import Crypto
import XCTest

@testable import TractandaCore

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

final class DocumentContentExportTests: XCTestCase {
    private let fixtureCap: UInt64 = 16 * 1024 * 1024
    private func guardCapacity(_ bytes: UInt64 = 0, fixtureRoot: URL? = nil) throws {
        var info = statvfs()
        let root = FileManager.default.temporaryDirectory
        guard bytes <= fixtureCap, statvfs(root.path, &info) == 0, info.f_frsize > 0 else {
            throw TractandaError("resourceLimit", "Cannot reserve export fixture capacity.")
        }
        if let fixtureRoot {
            guard let entries = FileManager.default.enumerator(atPath: fixtureRoot.path) else {
                throw TractandaError("resourceLimit", "Cannot inspect export fixture tree.")
            }
            var allocated: UInt64 = 0
            var count = 0
            while let relative = entries.nextObject() as? String {
                count += 1
                var value = stat()
                guard count <= 4096,
                    lstat(fixtureRoot.appendingPathComponent(relative).path, &value) == 0,
                    value.st_blocks >= 0
                else { throw TractandaError("resourceLimit", "Cannot measure bounded export fixture.") }
                let blocks = UInt64(value.st_blocks).multipliedReportingOverflow(by: 512)
                let sum = allocated.addingReportingOverflow(blocks.partialValue)
                guard !blocks.overflow, !sum.overflow, sum.partialValue <= fixtureCap - min(fixtureCap, bytes)
                else {
                    throw TractandaError("resourceLimit", "Export fixture would cross its 16 MiB cap.")
                }
                allocated = sum.partialValue
            }
        }
        let free = UInt64(info.f_bavail).multipliedReportingOverflow(by: UInt64(info.f_frsize))
        guard !free.overflow, free.partialValue >= UInt64(AttachmentFixtureCapacity.reserveBytes) + fixtureCap
        else {
            throw TractandaError("resourceLimit", "Export fixture needs genuine 10 GiB free plus 16 MiB cap.")
        }
    }
    private final class Accounts: AccountDirectory {
        let alice: UInt32 = 61992
        var allowed = true
        func user(forUID uid: UInt32) throws -> AccountIdentity {
            AccountIdentity(
                uid: uid, name: uid == alice ? "alice" : "admin", primaryGroupName: "staff",
                groupIDs: uid == getuid() || allowed ? [71992] : [])
        }
        func user(named name: String) throws -> AccountIdentity {
            try user(forUID: name == "alice" ? alice : getuid())
        }
        func groupID(named name: String) throws -> UInt32 { 71992 }
    }
    private struct Fixture {
        let root: URL
        let store: ItemStore
        let service: ItemService
        let revision: Revision
        let attachment: AttachmentDescriptor
        let original: Data
        let accounts: Accounts
        var output: URL { root.appendingPathComponent("exported") }
    }
    private func fixture(pages: Int = 2) throws -> Fixture {
        // Conservative source + canonical tree + complete export + Index allowance, <16MiB.
        try guardCapacity(8 * 1024 * 1024)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "document-export-" + Identifier.make())
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: root) } }
        let accounts = Accounts()
        let store = try AttachmentFixtureCapacity.makeStore(root: root, accounts: accounts)
        _ = try store.configureAccess(
            .object(["profile": .text(AccessConfiguration.profile), "groups": .list([.text("staff")])]),
            operationID: "access")
        var revision = try store.commit(
            CommitRequest(
                classID: "Item",
                changes: [
                    "permissions": .object([
                        "profile": .text(ItemPermissions.profile), "owner": .text("admin"),
                        "group": .text("staff"), "mode": .integer(0o640), "acl": .object([:]),
                    ])
                ], operationID: "item")
        ).revision
        let original = Data((0..<262_161).map { UInt8($0 % 251) })
        let upload = try store.beginAttachment(
            AttachmentUploadRequest(
                itemID: revision.itemID, expectedRevisionID: revision.revisionID, operationID: "attach",
                filename: "../unsafe.pdf", mediaType: "application/pdf", byteCount: Int64(original.count),
                sha256: SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined()))
        let id = try XCTUnwrap(upload.uploadID)
        try guardCapacity(1024 * 1024, fixtureRoot: root)
        _ = try store.appendAttachment(uploadID: id, offset: 0, data: original.prefix(262_144))
        try guardCapacity(1024 * 1024, fixtureRoot: root)
        _ = try store.appendAttachment(uploadID: id, offset: 262_144, data: original.suffix(17))
        revision = try store.finishAttachment(uploadID: id).revision
        if pages > 0 {
            guard
                case .prepared(let snapshot) = try store.prepareAttachmentDocument(
                    itemID: revision.itemID, expectedRevisionID: revision.revisionID,
                    attachmentID: upload.attachment.attachmentID, operationID: "extract", identity: .init())
            else { throw TractandaError("fixture", "Expected document preparation.") }
            let contents = DocumentContentStore(
                root: root, ownerUID: getuid(), minimumFreeBytes: AttachmentFixtureCapacity.reserveBytes)
            let writer = try contents.begin(
                source: snapshot.source, identity: .init(), maximumWriteBytes: 2 * 1024 * 1024)
            for number in 1...pages {
                try guardCapacity(1024 * 1024, fixtureRoot: root)
                if number == 1 {
                    let raw =
                        "<doctag>" + String(repeating: " ", count: 200_000)
                        + "<text>" + String(repeating: "saved text ", count: 4_000) + "</text></doctag>"
                    let parsed = try DoclingDocTagsParser.parse(Data(raw.utf8))
                    let geometry = try DocumentPageGeometry(
                        sourceWidth: 512, sourceHeight: 256, sourceUnit: "pdfPoint", displayWidth: 512,
                        displayHeight: 256, canvasWidth: 2048, canvasHeight: 1024, contentLeft: 0,
                        contentTop: 0, contentWidth: 2048, contentHeight: 1024)
                    try writer.append(
                        DocumentStoredPage(
                            pageNumber: 1, sourceSHA256: snapshot.source.sha256,
                            page: AttachmentDocumentPage(
                                pageNumber: 1, geometry: geometry,
                                rasterSHA256: String(repeating: "b", count: 64),
                                parsed: parsed, generatedTokens: 512, stopReason: "stop")))
                } else {
                    try writer.append(
                        DocumentStoredPage(
                            pageNumber: Int64(number), sourceSHA256: snapshot.source.sha256,
                            status: number == pages ? "failed" : "unsupported",
                            failureCode: "explicit-fixture-outcome"))
                }
            }
            let prepared = try writer.preparePublication()
            let corpus = try store.prepareAttachmentDocumentCorpus(snapshot, prepared: prepared)
            _ = try store.finishAttachmentDocument(snapshot, prepared: prepared, corpus: corpus)
            revision = try store.get(revision.itemID)
        }
        completed = true
        return Fixture(
            root: root, store: store, service: ItemService(store: store), revision: revision,
            attachment: upload.attachment, original: original, accounts: accounts)
    }
    private func client(
        _ fixture: Fixture, peerUID: UInt32? = nil,
        hook: @escaping (String, [String: Any]) throws -> Void = { _, _ in },
        mutate: @escaping (String, Data) throws -> Data = { _, response in response }
    ) -> ItemClient {
        ItemClient(transport: { request in
            let envelope = try JSONSerialization.jsonObject(with: request) as! [String: Any]
            let call = (envelope["methodCalls"] as! [[Any]])[0]
            let method = call[0] as! String
            try hook(method, call[1] as! [String: Any])
            return try mutate(
                method, fixture.service.handle(request, peerUID: peerUID ?? fixture.accounts.alice))
        })
    }
    private func mutatePart(_ response: Data, _ change: (inout [String: Any]) -> Void) throws -> Data {
        var envelope = try JSONSerialization.jsonObject(with: response) as! [String: Any]
        var calls = envelope["methodResponses"] as! [[Any]]
        var part = calls[0][1] as! [String: Any]
        change(&part)
        calls[0][1] = part
        envelope["methodResponses"] = calls
        return try JSONSerialization.data(withJSONObject: envelope)
    }
    private func assertUnpublished(_ fixture: Fixture) throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.output.path))
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).contains {
                $0.hasPrefix(".tractanda-item-export-")
            })
    }
    func testMultiLevelClosurePreservesCanonicalPagesAndOriginal() throws {
        let fixture = try fixture(pages: 129)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var requests = 0
        var pageChunks = 0
        let revision = try ItemDirectoryExport.export(
            client: client(
                fixture,
                hook: { method, args in
                    if method == "TractandaAttachment/documentContent" {
                        requests += 1
                        XCTAssertEqual(args["revisionID"] as? String, fixture.revision.revisionID)
                        XCTAssertEqual(args["limit"] as? Int, 262_144)
                        if args["kind"] as? String == "page", args["index"] as? Int == 1 { pageChunks += 1 }
                        try self.guardCapacity(1024 * 1024, fixtureRoot: fixture.root)
                    }
                }), itemID: fixture.revision.itemID, destination: fixture.output)
        XCTAssertEqual(revision, fixture.revision)
        XCTAssertEqual(
            try JSON.decode(
                Revision.self, Data(contentsOf: fixture.output.appendingPathComponent("revision.json"))),
            fixture.revision)
        XCTAssertEqual(
            try Data(
                contentsOf: fixture.output.appendingPathComponent(
                    fixture.attachment.attachmentID + ".original")), fixture.original)
        let reference = try XCTUnwrap(
            AttachmentDocumentRepresentation.representations(in: revision.fields).first?.content)
        let contents = DocumentContentStore(root: fixture.root, ownerUID: getuid())
        let base = fixture.output.appendingPathComponent("document-content/" + reference.contentID)
        let canonical = try contents.directory(reference.contentID).reduce(fixture.root) {
            $0.appendingPathComponent($1)
        }
        for relative in ["manifest.json", "nodes/1/0/0.json", "nodes/0/0/0.json", "nodes/0/0/1.json"] {
            XCTAssertEqual(
                try Data(contentsOf: base.appendingPathComponent(relative)),
                try Data(contentsOf: canonical.appendingPathComponent(relative)))
        }
        for number in 1...129 {
            let bytes = try Data(
                contentsOf: base.appendingPathComponent("pages/\((number - 1) / 128)/\(number).json"))
            XCTAssertEqual(
                bytes, try Data(contentsOf: contents.pageURLForTesting(reference, number: Int64(number))))
            XCTAssertEqual(
                try DocumentValue.strictDecode(DocumentStoredPage.self, data: bytes),
                try contents.readPage(reference, pageNumber: Int64(number)))
        }
        XCTAssertEqual(try contents.readPage(reference, pageNumber: 129).status, "failed")
        XCTAssertGreaterThan(pageChunks, 1)
        XCTAssertGreaterThan(requests, 132)
    }
    func testCopiedRepresentationUsesCurrentLocalContentRatherThanForeignProvenance() throws {
        let original = try fixture()
        defer { try? FileManager.default.removeItem(at: original.root) }
        try guardCapacity(2 * 1024 * 1024, fixtureRoot: original.root)
        let copied = try original.store.commit(
            CommitRequest(
                action: .copy, itemID: original.revision.itemID,
                expectedRevisionID: original.revision.revisionID, operationID: "copy")
        ).revision
        let descriptor = try XCTUnwrap(AttachmentDescriptor.descriptors(in: copied.fields).first)
        let document = try XCTUnwrap(
            AttachmentDocumentRepresentation.representations(in: copied.fields).first)
        XCTAssertEqual(document.source.itemID, original.revision.itemID)
        let copiedFixture = Fixture(
            root: original.root, store: original.store, service: original.service, revision: copied,
            attachment: descriptor, original: original.original, accounts: original.accounts)
        _ = try ItemDirectoryExport.export(
            client: client(
                copiedFixture, peerUID: getuid(),
                hook: { method, args in
                    if method == "TractandaAttachment/documentContent" {
                        XCTAssertEqual(args["itemID"] as? String, copied.itemID)
                        XCTAssertEqual(args["revisionID"] as? String, copied.revisionID)
                        try self.guardCapacity(1024 * 1024, fixtureRoot: original.root)
                    }
                }), itemID: copied.itemID, destination: copiedFixture.output)
        let content = try XCTUnwrap(document.content)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: copiedFixture.output.appendingPathComponent(
                    "document-content/" + content.contentID + "/manifest.json"
                ).path))
        XCTAssertEqual(
            try Data(
                contentsOf: copiedFixture.output.appendingPathComponent(descriptor.attachmentID + ".original")
            ), original.original)
    }
    func testNoRepresentationStillExportsOriginalAndRevision() throws {
        let fixture = try fixture(pages: 0)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try ItemDirectoryExport.export(
            client: client(fixture), itemID: fixture.revision.itemID, destination: fixture.output)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.output.appendingPathComponent("document-content").path))
        XCTAssertEqual(
            try Data(
                contentsOf: fixture.output.appendingPathComponent(
                    fixture.attachment.attachmentID + ".original")), fixture.original)
    }
    func testLaterReadableHeadKeepsCapturedRevision() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var changed = false
        let exported = try ItemDirectoryExport.export(
            client: client(
                fixture,
                hook: { method, _ in
                    if method == "TractandaAttachment/list", !changed {
                        changed = true
                        _ = try fixture.store.commit(
                            CommitRequest(
                                action: .revise, itemID: fixture.revision.itemID,
                                expectedRevisionID: fixture.revision.revisionID,
                                changes: ["subject": .text("later")], operationID: "later"))
                    }
                }), itemID: fixture.revision.itemID, destination: fixture.output)
        XCTAssertEqual(exported.revisionID, fixture.revision.revisionID)
        XCTAssertNotEqual(try fixture.store.get(exported.itemID).revisionID, exported.revisionID)
    }
    func testRevokedCurrentPermissionAbortsAndPreservesError() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        XCTAssertThrowsError(
            try ItemDirectoryExport.export(
                client: client(
                    fixture,
                    hook: { method, _ in
                        if method == "TractandaAttachment/documentContent" {
                            fixture.accounts.allowed = false
                        }
                    }), itemID: fixture.revision.itemID, destination: fixture.output)
        ) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "forbidden")
        }
        try assertUnpublished(fixture)
    }
    func testCorruptAndIncompleteAndStalePartsNeverPublish() throws {
        for fault in ["hash", "empty", "identity", "path", "length"] {
            let fixture = try fixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            XCTAssertThrowsError(
                try ItemDirectoryExport.export(
                    client: client(
                        fixture,
                        mutate: { method, response in
                            guard method == "TractandaAttachment/documentContent" else { return response }
                            return try self.mutatePart(response) { part in
                                switch fault {
                                case "hash":
                                    var bytes = Data(base64Encoded: part["data"] as! String)!
                                    bytes[bytes.startIndex] ^= 1
                                    part["data"] = bytes.base64EncodedString()
                                case "empty":
                                    part["data"] = ""
                                    part["nextOffset"] = 0
                                    part["isComplete"] = false
                                case "identity": part["contentID"] = Identifier.make()
                                case "path": part["relativePath"] = "../escaped.json"
                                default: part["byteCount"] = 65_537
                                }
                            }
                        }), itemID: fixture.revision.itemID, destination: fixture.output))
            try assertUnpublished(fixture)
        }
    }
    func testStaleOriginalListRevisionNeverPublishes() throws {
        let fixture = try fixture(pages: 0)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        XCTAssertThrowsError(
            try ItemDirectoryExport.export(
                client: client(
                    fixture,
                    mutate: { method, response in
                        guard method == "TractandaAttachment/list" else { return response }
                        return try self.mutatePart(response) { part in part["revisionID"] = Identifier.make()
                        }
                    }), itemID: fixture.revision.itemID, destination: fixture.output)
        ) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "protocolError")
        }
        try assertUnpublished(fixture)
    }
    func testMissingCanonicalPartNeverPublishes() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let reference = try XCTUnwrap(
            AttachmentDocumentRepresentation.representations(in: fixture.revision.fields).first?.content)
        let contents = DocumentContentStore(root: fixture.root, ownerUID: getuid())
        XCTAssertThrowsError(
            try ItemDirectoryExport.export(
                client: client(
                    fixture,
                    hook: { method, _ in
                        if method == "TractandaAttachment/documentContent" {
                            try? FileManager.default.removeItem(
                                at: contents.pageURLForTesting(reference, number: 2))
                        }
                    }), itemID: fixture.revision.itemID, destination: fixture.output))
        try assertUnpublished(fixture)
    }
    func testExistingDestinationIncludingSymlinkIsPreserved() throws {
        let fixture = try fixture(pages: 0)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.createSymbolicLink(
            at: fixture.output, withDestinationURL: fixture.root.appendingPathComponent("missing"))
        XCTAssertThrowsError(
            try ItemDirectoryExport.export(
                client: client(fixture), itemID: fixture.revision.itemID, destination: fixture.output))
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: fixture.output.path),
            fixture.root.appendingPathComponent("missing").path)
    }
}
