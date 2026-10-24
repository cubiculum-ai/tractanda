import Crypto
import XCTest

@testable import TractandaCore

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

final class PersonalRecoveryInventoryTests: XCTestCase {
    // Every test estimates under 4 MiB. The existing 32 MiB guard is more conservative than
    // the approved 128 MiB maximum and preserves the genuine 10 GiB filesystem reserve.
    override func setUpWithError() throws { try AttachmentFixtureCapacity.requireFree() }

    private func id() throws -> String { try UUID.makeVersion1().uuidString.lowercased() }
    private func root() throws -> URL {
        let result = FileManager.default.temporaryDirectory.appendingPathComponent(
            "personal-recovery-" + Identifier.make())
        try FileManager.default.createDirectory(
            at: result, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try directory(result, "items")
        return result
    }
    @discardableResult
    private func directory(_ root: URL, _ path: String) throws -> URL {
        var current = root
        for part in path.split(separator: "/") {
            current.appendPathComponent(String(part))
            try FileManager.default.createDirectory(
                at: current, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        return current
    }
    private func write(_ bytes: Data, root: URL, path: String, mode: Int = 0o600) throws {
        try AttachmentFixtureCapacity.requireFree(at: root)
        guard bytes.count < 4 * 1024 * 1024 else {
            throw TractandaError("resourceLimit", "Recovery fixture estimate exceeded.")
        }
        let url = root.appendingPathComponent(path)
        try directory(root, url.deletingLastPathComponent().path.dropFirst(root.path.count + 1).description)
        try bytes.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }
    private func revision(
        item: String? = nil, revisionID: String? = nil, parents: [String] = [],
        deleted: Bool = false, subject: String = "preserved", modern: Bool = false,
        extra: [String: ItemValue] = [:]
    ) throws -> Revision {
        var fields: [String: ItemValue] = [
            "itemID": .text(try item ?? id()), "revisionID": .text(try revisionID ?? id()),
            "classID": .text("Item"), "schemaVersion": .integer(1),
            "createdAt": .date("2026-10-24T10:00:00Z"), "modifiedAt": .date("2020-01-01T00:00:00Z"),
            "actor": .text("user:fixture"), "operationID": .text("fixture"),
            "requestIdentity": .text("fixture"), "subject": .text(subject), "isDeleted": .boolean(deleted),
        ]
        fields.merge(extra) { _, value in value }
        if modern {
            fields["revisionAncestry"] = try RevisionProvenance(
                kind: parents.count > 1 ? .resolution : .authored, originReplicaID: id(),
                parents: parents.sorted(), writtenFields: ["isDeleted", "subject"], unsetFields: [],
                frontier: parents.count > 1 ? parents.sorted() : []
            ).itemValue
        } else if let parent = parents.first {
            fields["supersedes"] = .text(parent)
        }
        return try Revision(fields: fields, formatVersion: modern ? 2 : 1)
    }
    @discardableResult
    private func save(_ revision: Revision, _ root: URL, minute: String = "01") throws -> String {
        let path = "items/2026/10/24/11/\(minute)/\(revision.itemID)/\(revision.revisionID).tractanda"
        try write(RecordCodec.encode(revision), root: root, path: path)
        return path
    }
    private func inspect(_ roots: URL..., limits: PersonalRecoveryInventory.Limits = .init()) throws
        -> PersonalRecoveryInventory.Result
    {
        try PersonalRecoveryInventory.inspect(
            roots.map { .init(root: $0, ownerUID: getuid()) }, limits: limits)
    }
    private func fingerprint(_ root: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        for case let url as URL in enumerator {
            let metadata = try FileMetadata.read(at: url)
            let key = String(url.path.dropFirst(root.path.count + 1))
            var value =
                "\(metadata.mode):\(metadata.uid):\(metadata.size):\(metadata.modificationSeconds):\(metadata.modificationNanoseconds)"
            if metadata.type == .regular {
                value += ":" + AuthorityRecordCodec.sha256(try Data(contentsOf: url))
            }
            result[key] = value
        }
        return result
    }

    func testCanonicalFilesAlonePreserveDAGMergeAndTombstoneWithoutAuthorityOrIndex() throws {
        let root = try self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try revision()
        let left = try revision(item: first.itemID, parents: [first.revisionID], modern: true)
        let right = try revision(item: first.itemID, parents: [first.revisionID], deleted: true)
        let merged = try revision(
            item: first.itemID, parents: [left.revisionID, right.revisionID], deleted: true, modern: true)
        for record in [merged, right, first, left] { try save(record, root) }
        let before = try fingerprint(root)
        let result = try inspect(root)
        XCTAssertTrue(result.isStructurallyComplete, "\(result.diagnostics)")
        XCTAssertEqual(result.records.count, 4)
        XCTAssertEqual(result.items[first.itemID]?.heads, [merged.revisionID])
        XCTAssertEqual(
            result.records[merged.revisionID]?.parents, [left.revisionID, right.revisionID].sorted())
        XCTAssertTrue(try XCTUnwrap(result.records[merged.revisionID]).isDeleted)
        XCTAssertEqual(try fingerprint(root), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("index").path))
        // The content stays in the original MIME envelopes; the plan neither rewrites nor fabricates it.
        let path = try XCTUnwrap(result.records[left.revisionID]?.locations.first?.path)
        XCTAssertEqual(try RecordCodec.decode(Data(contentsOf: root.appendingPathComponent(path))), left)
    }

    func testUnresolvedHeadsNeverSelectLiveBranchOverDeletedBranch() throws {
        let root = try self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try revision()
        let live = try revision(item: first.itemID, parents: [first.revisionID])
        let deleted = try revision(item: first.itemID, parents: [first.revisionID], deleted: true)
        for record in [first, live, deleted] { try save(record, root) }
        let result = try inspect(root)
        XCTAssertEqual(result.items[first.itemID]?.heads, [live.revisionID, deleted.revisionID].sorted())
        XCTAssertEqual(result.diagnostics.map(\.kind), [.unresolvedHeads])
        XCTAssertTrue(try XCTUnwrap(result.records[deleted.revisionID]).isDeleted)
    }

    func testMissingAndCrossItemParentsAreDistinctFromCycles() throws {
        let root = try self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let unrelated = try revision()
        let missing = try revision(parents: [id()])
        let cross = try revision(parents: [unrelated.revisionID])
        for record in [unrelated, missing, cross] { try save(record, root) }
        let result = try inspect(root)
        XCTAssertTrue(
            result.diagnostics.contains { $0.kind == .missingParent && $0.revisionID == missing.revisionID })
        XCTAssertTrue(
            result.diagnostics.contains { $0.kind == .crossItemParent && $0.revisionID == cross.revisionID })
        XCTAssertFalse(result.diagnostics.contains { $0.kind == .cycle })
        XCTAssertFalse(result.isStructurallyComplete)
    }

    func testConflictingDuplicateRevisionBytesAreRetainedAndDiagnosed() throws {
        let a = try self.root()
        let b = try self.root()
        defer {
            try? FileManager.default.removeItem(at: a)
            try? FileManager.default.removeItem(at: b)
        }
        let original = try revision()
        let conflict = try revision(
            item: original.itemID, revisionID: original.revisionID, subject: "different bytes")
        try save(original, a)
        try save(conflict, b)
        let beforeA = try fingerprint(a)
        let beforeB = try fingerprint(b)
        let result = try inspect(a, b)
        XCTAssertEqual(result.diagnostics.map(\.kind), [.conflictingRevision])
        XCTAssertTrue(try XCTUnwrap(result.items[original.itemID]).hasDiagnostics)
        XCTAssertEqual(try fingerprint(a), beforeA)
        XCTAssertEqual(try fingerprint(b), beforeB)
        // Identical copies retain both locators and require no rewrite.
        try save(original, b)
        let identical = try inspect(a, b)
        XCTAssertTrue(identical.isStructurallyComplete)
        XCTAssertEqual(identical.records[original.revisionID]?.locations.count, 2)
    }

    func testCycleIsDiagnosedWithoutRecursiveAncestryTraversal() throws {
        let root = try self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let item = try id()
        let a = try id()
        let b = try id()
        try save(revision(item: item, revisionID: a, parents: [b]), root)
        try save(revision(item: item, revisionID: b, parents: [a]), root)
        let result = try inspect(root)
        XCTAssertTrue(result.diagnostics.contains { $0.kind == .cycle })
        XCTAssertEqual(result.items[item]?.heads, [])
        XCTAssertEqual(result.records.count, 2)
    }

    func testOriginalPayloadVerificationIsReadOnlyAndMissingCorruptCopiesStayInvalid() throws {
        let root = try self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data(repeating: 0x41, count: 600_000)
        let attachment = try AttachmentDescriptor(
            attachmentID: id(), filename: "owned.txt", mediaType: "text/plain",
            byteCount: Int64(payload.count),
            sha256: AuthorityRecordCodec.sha256(payload))
        let record = try revision(extra: ["attachments": .list([attachment.itemValue])])
        try save(record, root)
        XCTAssertTrue(try inspect(root).diagnostics.contains { $0.kind == .missingPayload })
        let path = "attachments/payloads/2026/10/24/11/01/\(attachment.attachmentID).payload"
        try write(payload, root: root, path: path, mode: 0o400)
        // Deliberately invalid former control/SQLite data must neither be opened nor changed.
        try write(Data("broken old index".utf8), root: root, path: "index/items.sqlite")
        try write(Data("irrelevant old controls".utf8), root: root, path: ".peer-configuration/junk")
        let before = try fingerprint(root)
        let valid = try inspect(root)
        XCTAssertTrue(valid.isStructurallyComplete, "\(valid.diagnostics)")
        XCTAssertEqual(valid.payloadBytesBudgeted, UInt64(payload.count))
        XCTAssertEqual(try fingerprint(root), before)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("index/attachments.sqlite").path))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: root.appendingPathComponent(path).path)
        try write(Data(repeating: 0x42, count: payload.count), root: root, path: path, mode: 0o400)
        let corruptBefore = try fingerprint(root)
        XCTAssertTrue(try inspect(root).diagnostics.contains { $0.kind == .invalidPayload })
        XCTAssertEqual(try fingerprint(root), corruptBefore)
    }

    func testSavedDocumentClosureIsVerifiedWithoutPlacementIndexAndMissingPageIsDiagnosed() throws {
        let root = try self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data("tiny original".utf8)
        let attachment = try AttachmentDescriptor(
            attachmentID: id(), filename: "owned.pdf", mediaType: "application/pdf",
            byteCount: Int64(payload.count), sha256: AuthorityRecordCodec.sha256(payload))
        let first = try revision(extra: ["attachments": .list([attachment.itemValue])])
        let source = try AttachmentDocumentSource(
            itemID: first.itemID, revisionID: first.revisionID, attachmentID: attachment.attachmentID,
            sha256: attachment.sha256, byteCount: attachment.byteCount, mediaType: attachment.mediaType)
        let store = DocumentContentStore(
            root: root, ownerUID: getuid(), minimumFreeBytes: AttachmentFixtureCapacity.reserveBytes)
        let writer = try store.begin(source: source, identity: .init())
        try writer.append(
            DocumentStoredPage(
                pageNumber: 1, sourceSHA256: source.sha256, status: "failed", failureCode: "fixture"))
        let prepared = try writer.preparePublication()
        let reference = try store.publishPrepared(prepared)
        try save(first, root)
        try write(
            payload, root: root,
            path: "attachments/payloads/2026/10/24/11/01/\(attachment.attachmentID).payload", mode: 0o400)
        let documentPath = try store.directory(reference.contentID).joined(separator: "/")
        let representation = try AttachmentDocumentRepresentation(
            representationID: id(), attachmentID: attachment.attachmentID, source: source,
            extractedAt: prepared.extractedAt, identity: .init(), content: reference)
        let saved = try revision(
            item: first.itemID, parents: [first.revisionID],
            extra: [
                "attachments": .list([attachment.itemValue]),
                "attachmentDocument": .list([representation.itemValue]),
            ])
        try save(saved, root)
        // Dispose only fixture-created derived/control material before the actual recovery check.
        for path in [
            "index", "documents/.staging", "documents/.placements",
            ".tractanda-store-identity.json", ".document-placement.lock",
        ] {
            let url = root.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
        let before = try fingerprint(root)
        let valid = try inspect(root)
        XCTAssertTrue(valid.isStructurallyComplete, "\(valid.diagnostics)")
        XCTAssertEqual(try fingerprint(root), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("index").path))
        // The budget charges manifest and hash nodes too, rather than trusting the advertised page total.
        var limits = PersonalRecoveryInventory.Limits()
        limits.maximumTotalPayloadBytes = UInt64(payload.count) + UInt64(reference.totalEncodedBytes)
        XCTAssertThrowsError(try inspect(root, limits: limits)) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "resourceLimit")
        }
        XCTAssertEqual(try fingerprint(root), before)
        try FileManager.default.removeItem(at: root.appendingPathComponent(documentPath + "/pages/0/1.json"))
        let missingBefore = try fingerprint(root)
        let incomplete = try inspect(root)
        XCTAssertTrue(incomplete.diagnostics.contains { $0.kind == .invalidPayload })
        XCTAssertEqual(try fingerprint(root), missingBefore)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("index").path))
    }

    func testMalformedCanonicalLeafMarksItsItemIncomplete() throws {
        let root = try self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try revision()
        try save(first, root)
        let next = try revision(item: first.itemID, parents: [first.revisionID])
        let path = try save(next, root)
        try write(Data("malformed canonical envelope".utf8), root: root, path: path)
        let before = try fingerprint(root)
        let result = try inspect(root)
        XCTAssertTrue(try XCTUnwrap(result.items[first.itemID]).hasDiagnostics)
        XCTAssertTrue(
            result.diagnostics.contains {
                $0.kind == .invalidEntry && $0.itemID == first.itemID && $0.revisionID == next.revisionID
            })
        XCTAssertEqual(try fingerprint(root), before)
        try FileManager.default.removeItem(at: root.appendingPathComponent(path))
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent(path).path,
            withDestinationPath: root.path)
        let linked = try inspect(root)
        XCTAssertTrue(try XCTUnwrap(linked.items[first.itemID]).hasDiagnostics)
        XCTAssertTrue(
            linked.diagnostics.contains { $0.itemID == first.itemID && $0.revisionID == next.revisionID })
    }

    func testInventoryReaderKeepsEnumeratedDescriptorWhenPathIsReplaced() throws {
        let root = try self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try revision()
        let path = try save(original, root)
        let fd = open(root.appendingPathComponent(path).path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { _ = close(fd) }
        try FileManager.default.removeItem(at: root.appendingPathComponent(path))
        let replacement = try revision(
            item: original.itemID, revisionID: original.revisionID, subject: "replacement")
        try save(replacement, root)
        var charged = 0
        let loaded = try PooledCanonicalRecord.readForInventory(
            path: path, descriptor: fd, ownerUID: getuid(), readBudget: { charged += $0 })
        XCTAssertEqual(loaded.record.revision, original)
        XCTAssertEqual(charged, try RecordCodec.encode(original).count)
        XCTAssertEqual(loaded.record.metadata.size, UInt64(charged))
    }

    func testPayloadReaderKeepsSelectedRootDescriptorWhenRootPathBecomesSymlink() throws {
        let root = try self.root()
        let outside = try self.root()
        let moved = root.appendingPathExtension("retained")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: moved)
            try? FileManager.default.removeItem(at: outside)
        }
        let payload = Data("selected original".utf8)
        let attachment = try AttachmentDescriptor(
            attachmentID: id(), filename: "owned.txt", mediaType: "text/plain",
            byteCount: Int64(payload.count),
            sha256: AuthorityRecordCodec.sha256(payload))
        let path = "attachments/payloads/2026/10/24/11/01/\(attachment.attachmentID).payload"
        try write(payload, root: root, path: path, mode: 0o400)
        try write(Data(repeating: 0x42, count: payload.count), root: outside, path: path, mode: 0o400)
        let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { _ = close(fd) }
        try FileManager.default.moveItem(at: root, to: moved)
        try FileManager.default.createSymbolicLink(atPath: root.path, withDestinationPath: outside.path)
        var charged = 0
        XCTAssertNoThrow(
            try AttachmentPayloadStore.validateForInventory(
                attachment, path: path, root: root, rootDescriptor: fd, ownerUID: getuid(),
                readBudget: { charged += $0 }))
        XCTAssertEqual(charged, payload.count)
        XCTAssertThrowsError(try inspect(root))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("index").path))
    }

    func testIntakeHiddenAndAtomicTemporaryFilesAreExcluded() throws {
        let root = try self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let record = try revision()
        let path = try save(record, root)
        try write(Data("unpublished".utf8), root: root, path: path + ".a1b2c3")
        try write(Data("unaccepted".utf8), root: root, path: "peer-intake/" + path)
        try write(Data("hidden".utf8), root: root, path: "items/.staging/other.tractanda")
        let before = try fingerprint(root)
        let result = try inspect(root)
        XCTAssertTrue(result.isStructurallyComplete)
        XCTAssertEqual(result.records.count, 1)
        XCTAssertEqual(result.stagedEntriesExcluded, 2)
        XCTAssertEqual(try fingerprint(root), before)
    }

    func testUnsafeLinksAndSpecialFilesNeverBecomeRecords() throws {
        let root = try self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let record = try revision()
        let path = try save(record, root)
        let unsafe = root.appendingPathComponent("items/2026/10/24/11/02")
        try FileManager.default.createSymbolicLink(atPath: unsafe.path, withDestinationPath: root.path)
        let fifo = root.appendingPathComponent(path + ".fifo")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let result = try inspect(root)
        XCTAssertEqual(result.records.count, 1)
        XCTAssertEqual(result.diagnostics.filter { $0.kind == .invalidEntry }.count, 2)
    }

    func testInventoryLimitsFailClosedWithoutCreatingDerivedState() throws {
        let root = try self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        try save(revision(), root)
        let before = try fingerprint(root)
        for setting in 0..<3 {
            var limits = PersonalRecoveryInventory.Limits()
            if setting == 0 { limits.maximumEntries = 1 }
            if setting == 1 { limits.maximumTotalRecordBytes = 1 }
            if setting == 2 { limits.maximumMetadataBytes = 1 }
            XCTAssertThrowsError(try inspect(root, limits: limits)) {
                XCTAssertEqual(($0 as? TractandaError)?.code, "resourceLimit")
            }
        }
        XCTAssertEqual(try fingerprint(root), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("index").path))
    }
}
