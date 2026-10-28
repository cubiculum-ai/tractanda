import CTractandaPlatform
import Foundation
import XCTest

@testable import TractandaCore

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

final class ContentCommandTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let records: [Revision]
        let current: Revision
        let tombstone: Revision
        let original: AttachmentDescriptor
        let document: AttachmentDocumentRepresentation
        let priorStoreID: String
        let priorReplicaID: String
    }
    private func capacity(_ root: URL) throws {
        var value = statvfs()
        guard statvfs(root.path, &value) == 0, value.f_frsize > 0 else {
            throw TractandaError("resourceLimit", "Fixture capacity unknown")
        }
        let free = UInt64(value.f_bavail).multipliedReportingOverflow(by: UInt64(value.f_frsize))
        guard !free.overflow, free.partialValue >= 10 * 1024 * 1024 * 1024 + 128 * 1024 * 1024 else {
            throw TractandaError("resourceLimit", "Fixture requires genuine10GiB reserve and128MiB cap")
        }
    }
    private func parent(_ body: (URL) throws -> Void) throws {
        try capacity(FileManager.default.temporaryDirectory)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "tcc-" + String(UUID().uuidString.prefix(8)))
        try PrivateConfiguration.makeDirectory(root)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }
    private func run(_ arguments: [String]) throws -> (Int32, Data, Data) {
        let executable = try currentBuiltTestCLI(anchor: Self.self)
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = error
        try process.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        let diagnostics = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, bytes, diagnostics)
    }
    private func policy(_ parent: URL) throws -> URL {
        let account = try SystemAccountDirectory().user(forUID: tractanda_uid())
        let value: ItemValue = .object([
            "profile": .text(AccessConfiguration.profile),
            "users": .list([.text(account.name)]), "groups": .list([]),
        ])
        let path = parent.appendingPathComponent("policy.json")
        try JSON.encode(value).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        return path
    }
    private func raw(_ parent: URL) throws -> Fixture {
        // Under16MiB including seed/runtime/index/report files. Move only fixture-generated
        // canonical subtrees into a raw root; no product copy/cleanup implementation is used.
        try capacity(parent)
        let seed = parent.appendingPathComponent("seed")
        let raw = parent.appendingPathComponent("raw")
        try PrivateConfiguration.makeDirectory(raw)
        let records: [Revision]
        let current: Revision
        let tombstone: Revision
        let original: AttachmentDescriptor
        let document: AttachmentDocumentRepresentation
        let storeID: String
        let replicaID: String
        do {
            let store = try ItemStore.initializeFresh(root: seed)
            let first = try store.commit(
                .init(classID: "Item", changes: ["body": .text("BODY-DO-NOT-DUMP")], operationID: "item")
            ).revision
            let data = Data([137, 80, 78, 71, 13, 10, 26, 10])
            let upload = try store.beginAttachment(
                .init(
                    itemID: first.itemID, expectedRevisionID: first.revisionID,
                    operationID: "original", filename: "fixture.png", mediaType: "image/png",
                    byteCount: Int64(data.count), sha256: AuthorityRecordCodec.sha256(data)))
            let uploadID = try XCTUnwrap(upload.uploadID)
            _ = try store.appendAttachment(uploadID: uploadID, offset: 0, data: data)
            let attached = try store.finishAttachment(uploadID: uploadID).revision
            guard
                case .prepared(let snapshot) = try store.prepareAttachmentDocument(
                    itemID: first.itemID,
                    expectedRevisionID: attached.revisionID, attachmentID: upload.attachment.attachmentID,
                    operationID: "document", identity: .init())
            else { throw TractandaError("fixture", "Expected document preparation") }
            let page = try AttachmentDocumentPage(
                pageNumber: 1,
                geometry: DocumentPageGeometry(
                    sourceWidth: 512, sourceHeight: 256, sourceUnit: "pixel",
                    displayWidth: 512, displayHeight: 256, canvasWidth: 2048, canvasHeight: 1024,
                    contentLeft: 0, contentTop: 0, contentWidth: 2048, contentHeight: 1024),
                rasterSHA256: String(repeating: "b", count: 64),
                parsed: DoclingDocTagsParser.parse(
                    Data("<doctag><text>SAVED-BODY-DO-NOT-DUMP</text></doctag>".utf8)),
                generatedTokens: 16, stopReason: "stop")
            let receipt = try store.finishAttachmentDocument(snapshot, pages: [page])
            current = try store.get(receipt.itemID)
            original = upload.attachment
            document = try XCTUnwrap(
                AttachmentDocumentRepresentation.representations(in: current.fields).first)
            let second = try store.commit(.init(classID: "Item", operationID: "second")).revision
            tombstone = try store.commit(
                .init(
                    action: .revise, itemID: second.itemID, expectedRevisionID: second.revisionID,
                    changes: ["isDeleted": .boolean(true)], operationID: "delete")
            ).revision
            records = [first, attached, current, second, tombstone]
            storeID = try CanonicalReaderRequirement.storeIdentity(root: seed, ownerUID: tractanda_uid())
            replicaID = try XCTUnwrap(store.replicaID)
        }
        for subtree in ["items", "attachments/payloads", "documents/content"] {
            let destination = raw.appendingPathComponent(subtree)
            try PrivateConfiguration.makeDirectory(destination.deletingLastPathComponent())
            try FileManager.default.moveItem(at: seed.appendingPathComponent(subtree), to: destination)
        }
        return Fixture(
            root: raw, records: records, current: current, tombstone: tombstone,
            original: original, document: document, priorStoreID: storeID, priorReplicaID: replicaID)
    }
    private func fingerprint(_ root: URL) throws -> [String: String] {
        var output: [String: String] = [:]
        if let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let url as URL in entries {
                let value = try FileMetadata.read(at: url)
                let bytes =
                    value.type == .regular ? AuthorityRecordCodec.sha256(try Data(contentsOf: url)) : ""
                output[url.standardizedFileURL.resolvingSymlinksInPath().path] =
                    "\(value.uid):\(value.mode):\(value.inode):\(value.size):\(bytes)"
            }
        }
        return output
    }
    private func canonical(_ root: URL) throws -> [String: String] {
        var values: [String: String] = [:]
        for path in ["items", "attachments/payloads", "documents/content"] {
            values.merge(try fingerprint(root.appendingPathComponent(path))) { _, rhs in rhs }
        }
        return try values.filter { try FileMetadata.read(at: URL(fileURLWithPath: $0.key)).type == .regular }
    }
    private func write(_ bytes: Data, _ root: URL, _ path: String, mode: Int = 0o600) throws {
        try capacity(root)
        let file = root.appendingPathComponent(path)
        try PrivateConfiguration.makeDirectory(file.deletingLastPathComponent())
        if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        try bytes.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path)
    }

    func testInspectCLIReferencesDigestsPrivateOutputAndExactInputImmutability() throws {
        try parent { parent in
            let fixture = try raw(parent)
            try write(Data("SECRET-OLD-CONTROL".utf8), fixture.root, "authority/old.json")
            try write(Data("SECRET-PENDING".utf8), fixture.root, ".peer-intake/pending.json")
            let orphan = try UUID.makeVersion1().uuidString.lowercased()
            try write(
                Data("unverified orphan".utf8), fixture.root,
                "attachments/payloads/2026/10/24/11/01/\(orphan).payload", mode: 0o400)
            let before = try fingerprint(fixture.root)
            let reportFile = parent.appendingPathComponent("report.json")
            let user = try SystemAccountDirectory().user(forUID: tractanda_uid())
            let result = try run([
                "inspect-content", fixture.root.path, "--owner", user.name, "--output", reportFile.path,
            ])
            XCTAssertEqual(result.0, 0, String(decoding: result.2, as: UTF8.self))
            let data = try Data(contentsOf: reportFile)
            let report = try JSON.decode(ContentInspectionReport.self, data)
            XCTAssertTrue(report.structurallyComplete)
            XCTAssertEqual(report.counts.items, 2)
            XCTAssertEqual(report.counts.revisions, 5)
            XCTAssertEqual(report.counts.referencedOriginals, 1)
            XCTAssertEqual(report.counts.originalsWithVerifiedLocations, 1)
            XCTAssertEqual(report.counts.referencedSavedDocuments, 1)
            XCTAssertEqual(report.counts.savedDocumentsWithVerifiedLocations, 1)
            XCTAssertEqual(report.originals.first?.descriptor, fixture.original)
            XCTAssertEqual(report.savedDocuments.first?.content, fixture.document.content)
            XCTAssertEqual(Set(report.records.map(\.revisionID)), Set(fixture.records.map(\.revisionID)))
            XCTAssertEqual(
                report.items.first { $0.itemID == fixture.current.itemID }?.heads,
                [fixture.current.revisionID])
            for record in report.records {
                let bytes = try Data(
                    contentsOf: fixture.root.appendingPathComponent(try XCTUnwrap(record.locations.first)))
                XCTAssertEqual(record.sha256, AuthorityRecordCodec.sha256(bytes))
                XCTAssertEqual(record.byteCount, UInt64(bytes.count))
            }
            let text = String(decoding: data, as: UTF8.self)
            for secret in ["BODY-DO-NOT-DUMP", "SECRET-OLD-CONTROL", "SECRET-PENDING", orphan] {
                XCTAssertFalse(text.contains(secret))
            }
            XCTAssertEqual(try FileMetadata.read(at: reportFile).mode & 0o777, 0o600)
            XCTAssertEqual(try fingerprint(fixture.root), before)
            XCTAssertNotEqual(
                try run(["inspect-content", fixture.root.path, "--output", reportFile.path]).0, 0)
            XCTAssertNotEqual(
                try run([
                    "inspect-content", fixture.root.path, "--output",
                    fixture.root.appendingPathComponent("forbidden.json").path,
                ]).0, 0)
            let alias = parent.appendingPathComponent("parent-alias")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: parent)
            XCTAssertNotEqual(
                try run([
                    "inspect-content", fixture.root.path, "--output",
                    alias.appendingPathComponent("raw/forbidden-alias.json").path,
                ]).0, 0)
            let caseAlias = parent.appendingPathComponent("RAW")
            if let metadata = try? FileMetadata.read(at: caseAlias),
                metadata.inode == (try FileMetadata.read(at: fixture.root)).inode
            {
                let refused = try run([
                    "inspect-content", fixture.root.path, "--output",
                    caseAlias.appendingPathComponent("forbidden-case.json").path,
                ])
                XCTAssertNotEqual(refused.0, 0)
                XCTAssertTrue(String(decoding: refused.2, as: UTF8.self).contains("invalidReportDestination"))
                print("Content report case-alias directory identity rejection exercised")
            }
            XCTAssertEqual(try fingerprint(fixture.root), before)
        }
    }

    func testActivationCLIPreservesContentThenNormalOpenWriteRebuildAndBusyRefusal() throws {
        try parent { parent in
            let fixture = try raw(parent)
            let config = try policy(parent)
            let index = parent.appendingPathComponent("active-index")
            let before = try canonical(fixture.root)
            XCTAssertNotEqual(try run(["activate-content", fixture.root.path, config.path]).0, 0)
            let result = try run([
                "activate-content", fixture.root.path, config.path, "--index-directory", index.path,
            ])
            XCTAssertEqual(result.0, 0, String(decoding: result.2, as: UTF8.self))
            let activated = try JSON.decode(ContentActivationReport.self, result.1)
            XCTAssertTrue(activated.ready)
            XCTAssertEqual(activated.items, 2)
            XCTAssertEqual(activated.revisions, 5)
            XCTAssertNotEqual(activated.storeID, fixture.priorStoreID)
            XCTAssertNotEqual(activated.replicaID, fixture.priorReplicaID)
            XCTAssertEqual(try canonical(fixture.root), before)
            let retry = try run([
                "activate-content", fixture.root.path, config.path, "--index-directory", index.path,
            ])
            XCTAssertEqual(retry.0, 0)
            XCTAssertEqual(try JSON.decode(ContentActivationReport.self, retry.1).storeID, activated.storeID)
            var store: ItemStore? = try ItemStore.openInitialized(root: fixture.root, indexDirectory: index)
            let busy = try run(["inspect-content", fixture.root.path])
            XCTAssertNotEqual(busy.0, 0)
            XCTAssertTrue(String(decoding: busy.2, as: UTF8.self).contains("contentBusy"))
            XCTAssertEqual(try store!.get(fixture.current.itemID), fixture.current)
            let updated = try store!.commit(
                .init(
                    action: .revise, itemID: fixture.current.itemID,
                    expectedRevisionID: fixture.current.revisionID,
                    changes: ["subject": .text("after activation")], operationID: "after-activation")
            ).revision
            try store!.withAccess(forUID: tractanda_uid()) { try store!.rebuildIndex() }
            store = nil
            try FileManager.default.removeItem(at: index)
            store = try ItemStore.openInitialized(root: fixture.root, indexDirectory: index)
            XCTAssertEqual(try store!.get(fixture.current.itemID), updated)
            XCTAssertEqual(try store!.history(fixture.current.itemID).count, 4)
            store = nil
            let reportResult = try run(["inspect-content", fixture.root.path])
            XCTAssertEqual(reportResult.0, 0)
            XCTAssertEqual(try JSON.decode(ContentInspectionReport.self, reportResult.1).counts.revisions, 6)
            for (path, value) in before { XCTAssertEqual(try canonical(fixture.root)[path], value) }
        }
    }

    func testMissingExplicitPathOwnerMismatchAndUnpreparedActivationRefuseSafely() throws {
        try parent { parent in
            XCTAssertNotEqual(try run(["inspect-content"]).0, 0)
            let missing = parent.appendingPathComponent("missing")
            XCTAssertNotEqual(try run(["inspect-content", missing.path]).0, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
            let fixture = try raw(parent)
            let before = try canonical(fixture.root)
            let wrong = tractanda_uid() == 0 ? "daemon" : "root"
            XCTAssertNotEqual(try run(["inspect-content", fixture.root.path, "--owner", wrong]).0, 0)
            try write(Data("retain old control".utf8), fixture.root, "authority/old.json")
            try write(Data("retain pending".utf8), fixture.root, "attachments/.staging/pending")
            let control = try fingerprint(fixture.root.appendingPathComponent("authority"))
            let config = try policy(parent)
            let index = parent.appendingPathComponent("must-not-create")
            XCTAssertNotEqual(
                try run(["activate-content", fixture.root.path, config.path, "--index-directory", index.path])
                    .0, 0)
            XCTAssertEqual(try canonical(fixture.root), before)
            XCTAssertEqual(try fingerprint(fixture.root.appendingPathComponent("authority")), control)
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: fixture.root.appendingPathComponent(".tractanda-personal-profile.json").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: index.path))
        }
    }

    func testCorruptMissingAndUnsafeContentReportIncompleteWithoutMutation() throws {
        for variant in ["corrupt", "missing", "unsafe"] {
            try parent { parent in
                let fixture = try raw(parent)
                let payload = try XCTUnwrap(
                    FileManager.default.enumerator(
                        at: fixture.root.appendingPathComponent("attachments/payloads"),
                        includingPropertiesForKeys: nil)?.allObjects.compactMap { $0 as? URL }.first {
                            $0.pathExtension == "payload"
                        })
                if variant == "corrupt" {
                    try write(
                        Data("corrupt".utf8), payload.deletingLastPathComponent(), payload.lastPathComponent,
                        mode: 0o400)
                }
                if variant == "missing" { try FileManager.default.removeItem(at: payload) }
                if variant == "unsafe" {
                    try FileManager.default.setAttributes(
                        [.posixPermissions: 0o644], ofItemAtPath: payload.path)
                }
                let before = try fingerprint(fixture.root)
                let result = try run(["inspect-content", fixture.root.path])
                XCTAssertEqual(result.0, 2)
                let report = try JSON.decode(ContentInspectionReport.self, result.1)
                XCTAssertFalse(report.structurallyComplete)
                XCTAssertFalse(report.diagnostics.isEmpty)
                XCTAssertEqual(report.counts.originalsWithVerifiedLocations, 0)
                XCTAssertEqual(try fingerprint(fixture.root), before)
            }
        }
    }
}
