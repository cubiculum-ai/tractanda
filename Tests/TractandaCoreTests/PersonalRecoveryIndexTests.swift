import Crypto
import XCTest

@testable import TractandaCore

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

final class PersonalRecoveryIndexTests: XCTestCase {
    private final class Accounts: AccountDirectory {
        let alice: UInt32 = 51001
        let bob: UInt32 = 51002
        var users: [AccountIdentity]
        init() {
            users = [(getuid(), "admin"), (51001, "alice"), (51002, "bob")].map {
                AccountIdentity(uid: $0.0, name: $0.1, primaryGroupName: "staff", groupIDs: [70001])
            }
        }
        func user(forUID uid: UInt32) throws -> AccountIdentity {
            guard let result = users.first(where: { $0.uid == uid }) else {
                throw TractandaError("unresolvedPrincipal", "Missing user")
            }
            return result
        }
        func user(named name: String) throws -> AccountIdentity {
            guard let result = users.first(where: { $0.name == name }) else {
                throw TractandaError("unresolvedPrincipal", "Missing user")
            }
            return result
        }
        func groupID(named name: String) throws -> UInt32 {
            guard name == "staff" else { throw TractandaError("unresolvedPrincipal", "Missing group") }
            return 70001
        }
    }
    override func setUpWithError() throws { try AttachmentFixtureCapacity.requireFree() }
    private func id() throws -> String { try UUID.makeVersion1().uuidString.lowercased() }
    private func configuration() throws -> AccessConfiguration {
        try AccessConfiguration(
            .object([
                "profile": .text(AccessConfiguration.profile),
                "users": .list([.text("alice"), .text("bob")]),
            ]))
    }
    private func permissions(_ owner: String = "alice", mode: Int64 = 0o644) -> ItemValue {
        .object([
            "profile": .text(ItemPermissions.profile), "owner": .text(owner),
            "group": .text("staff"), "mode": .integer(mode), "acl": .object([:]),
        ])
    }
    private func revision(
        item: String? = nil, parents: [String] = [], subject: String = "recoverable",
        second: Int = 0, deleted: Bool = false, modern: Bool = false,
        permission: ItemValue? = nil, extra: [String: ItemValue] = [:]
    ) throws -> Revision {
        var fields: [String: ItemValue] = [
            "itemID": .text(try item ?? id()), "revisionID": .text(try id()),
            "classID": .text("Item"), "schemaVersion": .integer(1),
            "createdAt": .date("2026-10-24T10:00:00Z"),
            "modifiedAt": .date(String(format: "2026-10-24T10:00:%02dZ", second)),
            "actor": .text("user:alice"), "operationID": .text(try id()),
            "requestIdentity": .text("preserved"), "subject": .text(subject),
            "isDeleted": .boolean(deleted), "permissions": permission ?? permissions(),
        ]
        fields.merge(extra) { _, new in new }
        if modern {
            fields["revisionAncestry"] = try RevisionProvenance(
                kind: parents.count > 1 ? .resolution : .authored, originReplicaID: id(),
                parents: parents.sorted(), writtenFields: ["subject"], unsetFields: [],
                frontier: parents.count > 1 ? parents.sorted() : []
            ).itemValue
        } else if let parent = parents.first {
            fields["supersedes"] = .text(parent)
        }
        return try Revision(fields: fields, formatVersion: modern ? 2 : 1)
    }
    private func directory(_ root: URL, _ path: String = "") throws -> URL {
        let url = path.isEmpty ? root : root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }
    private func write(_ bytes: Data, root: URL, path: String, mode: Int = 0o600) throws {
        try AttachmentFixtureCapacity.requireFree(at: root)
        // Each test estimates below 4 MiB and bounds every write before touching disk.
        guard bytes.count < 4 * 1024 * 1024 else { throw TractandaError("resourceLimit", "Fixture cap") }
        let url = root.appendingPathComponent(path)
        _ = try directory(url.deletingLastPathComponent())
        try bytes.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }
    private func save(_ revision: Revision, _ root: URL) throws {
        try write(
            RecordCodec.encode(revision), root: root,
            path: "items/2026/10/24/11/01/\(revision.itemID)/\(revision.revisionID).tractanda")
    }
    private func fingerprint(_ root: URL) throws -> [String: String] {
        var output: [String: String] = [:]
        let entries = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        for case let url as URL in entries {
            let metadata = try FileMetadata.read(at: url)
            let path = String(url.path.dropFirst(root.path.count + 1))
            let digest =
                metadata.type == .regular
                ? AuthorityRecordCodec.sha256(try Data(contentsOf: url)) : ""
            output[path] = "\(metadata.mode):\(metadata.uid):\(metadata.inode):\(metadata.size):\(digest)"
        }
        return output
    }
    private func fixture(_ body: (URL, URL, Accounts) throws -> Void) throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "personal-index-" + Identifier.make())
        _ = try directory(parent)
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = try directory(parent, "canonical")
        _ = try directory(root, "items")
        try body(root, parent.appendingPathComponent("derived"), Accounts())
    }
    private func rebuild(
        _ root: URL, _ output: URL, _ accounts: Accounts,
        inventoryLimits: PersonalRecoveryInventory.Limits = .init(), contextID: String? = nil
    ) throws
        -> PersonalRecoveryIndex.Completed
    {
        var limits = PersonalRecoveryIndex.Limits()
        limits.maximumDerivedBytes = AttachmentFixtureCapacity.fixtureCapBytes
        limits.inventory = inventoryLimits
        return try PersonalRecoveryIndex.rebuild(
            source: .init(root: root, ownerUID: getuid()), destination: output,
            accounts: accounts, configuration: configuration(), limits: limits, rebuildContextID: contextID)
    }
    private func assertCode(_ code: String, _ body: () throws -> Void) {
        XCTAssertThrowsError(try body()) { XCTAssertEqual(($0 as? TractandaError)?.code, code) }
    }

    private struct SavedDocumentFixture {
        let base: Revision
        let saved: Revision
        let documentPath: String?
    }

    private func attachment(_ root: URL, text: String, mediaType: String) throws -> AttachmentDescriptor {
        let bytes = Data(text.utf8)
        let result = try AttachmentDescriptor(
            attachmentID: id(), filename: mediaType == "application/pdf" ? "saved.pdf" : "saved.txt",
            mediaType: mediaType, byteCount: Int64(bytes.count), sha256: AuthorityRecordCodec.sha256(bytes))
        try write(
            bytes, root: root,
            path: "attachments/payloads/2026/10/24/11/01/\(result.attachmentID).payload", mode: 0o400)
        return result
    }

    private func documentPage(_ number: Int, source: AttachmentDocumentSource, text: String) throws
        -> DocumentStoredPage
    {
        let parsed = try DoclingDocTagsParser.parse(Data(("<doctag><text>" + text + "</text></doctag>").utf8))
        let geometry = try DocumentPageGeometry(
            sourceWidth: 512, sourceHeight: 256, sourceUnit: "pdfPoint",
            displayWidth: 512, displayHeight: 256, canvasWidth: 2048, canvasHeight: 1024,
            contentLeft: 0, contentTop: 0, contentWidth: 2048, contentHeight: 1024)
        let page = try AttachmentDocumentPage(
            pageNumber: number, geometry: geometry, rasterSHA256: String(repeating: "b", count: 64),
            parsed: parsed, generatedTokens: 16, stopReason: "stop")
        return try DocumentStoredPage(pageNumber: Int64(number), sourceSHA256: source.sha256, page: page)
    }

    private func savedDocument(
        _ root: URL, pages: Int, inline: Bool = false, token: String,
        permission: ItemValue? = nil
    ) throws -> SavedDocumentFixture {
        // Each typed page is bounded below 4 KiB. Estimate before any document stage writes;
        // at 137 pages, metadata and even a duplicate stage fit comfortably under 4 MiB.
        let estimate = pages * 4096 + 1024 * 1024
        guard pages > 0, estimate < 2 * 1024 * 1024 else {
            throw TractandaError("resourceLimit", "Tiny document fixture estimate exceeded.")
        }
        try AttachmentFixtureCapacity.requireFree(at: root)
        let originalBytes = Data("preserved pdf bytes".utf8)
        let original = try AttachmentDescriptor(
            attachmentID: id(), filename: "saved.pdf", mediaType: "application/pdf",
            byteCount: Int64(originalBytes.count), sha256: AuthorityRecordCodec.sha256(originalBytes))
        let base = try revision(
            subject: "document original", extra: ["attachments": .list([original.itemValue])])
        let source = try AttachmentDocumentSource(
            itemID: base.itemID, revisionID: base.revisionID, attachmentID: original.attachmentID,
            sha256: original.sha256, byteCount: original.byteCount, mediaType: original.mediaType)
        let representation: AttachmentDocumentRepresentation
        let documentPath: String?
        if inline {
            guard pages <= 2 else { throw TractandaError("resourceLimit", "Historical inline fixture limit") }
            representation = try AttachmentDocumentRepresentation(
                representationID: id(), attachmentID: original.attachmentID, source: source,
                extractedAt: "2026-10-24T10:00:00Z", identity: .init(),
                pages: (1...pages).map {
                    try XCTUnwrap(documentPage($0, source: source, text: token).page)
                })
            documentPath = nil
        } else {
            let store = DocumentContentStore(
                root: root, ownerUID: getuid(), minimumFreeBytes: AttachmentFixtureCapacity.reserveBytes)
            let writer = try store.begin(
                source: source, identity: .init(), maximumWriteBytes: Int64(estimate))
            for number in 1...pages {
                try AttachmentFixtureCapacity.requireFree(at: root)
                let page = try documentPage(
                    number, source: source, text: number == pages ? token : "bounded synthetic page \(number)"
                )
                guard try JSON.encode(page).count <= 4096 else {
                    throw TractandaError("resourceLimit", "Typed page fixture estimate exceeded.")
                }
                try writer.append(page)
            }
            let prepared = try writer.preparePublication()
            let reference = try store.publishPrepared(prepared)
            documentPath = try store.directory(reference.contentID).joined(separator: "/")
            representation = try AttachmentDocumentRepresentation(
                representationID: id(), attachmentID: original.attachmentID, source: source,
                extractedAt: prepared.extractedAt, identity: .init(), content: reference)
            XCTAssertEqual(reference.pageCount, Int64(pages))
            // Remove fixture-created operational state BEFORE invoking the actual recovery factory.
            for name in [
                "index", "documents/.staging", "documents/.placements",
                ".tractanda-store-identity.json", ".document-placement.lock",
            ] {
                let path = root.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: path.path) {
                    try FileManager.default.removeItem(at: path)
                }
            }
        }
        // Fixture publication starts from an empty root; original bytes are installed only after
        // the old fixture helper has finished, then its operational identity is removed above.
        try write(
            originalBytes, root: root,
            path: "attachments/payloads/2026/10/24/11/01/\(original.attachmentID).payload", mode: 0o400)
        let saved = try revision(
            item: base.itemID, parents: [base.revisionID], subject: "document current", second: 1,
            permission: permission,
            extra: [
                "attachments": .list([original.itemValue]),
                "attachmentDocument": .list([representation.itemValue]),
            ])
        for value in [base, saved] { try save(value, root) }
        return SavedDocumentFixture(base: base, saved: saved, documentPath: documentPath)
    }

    func testCanonicalOnlyRebuildNativeReadHistoryFTSAndReopenKeepOriginalBytes() throws {
        try fixture { root, output, accounts in
            let first = try revision(subject: "historical secret", permission: permissions(mode: 0o600))
            let payload = Data(repeating: 0x41, count: 1024)
            let attachment = try AttachmentDescriptor(
                attachmentID: id(), filename: "owned.txt", mediaType: "text/plain",
                byteCount: Int64(payload.count), sha256: AuthorityRecordCodec.sha256(payload))
            try write(
                payload, root: root,
                path: "attachments/payloads/2026/10/24/11/01/\(attachment.attachmentID).payload", mode: 0o400)
            let current = try revision(
                item: first.itemID, parents: [first.revisionID], subject: "searchable sunflower", second: 1,
                extra: ["attachments": .list([attachment.itemValue])])
            let deadFirst = try revision(subject: "retired")
            let dead = try revision(
                item: deadFirst.itemID, parents: [deadFirst.revisionID], second: 2, deleted: true)
            for value in [dead, current, deadFirst, first] { try save(value, root) }
            try write(Data("pending".utf8), root: root, path: ".peer-intake/unaccepted")
            let before = try fingerprint(root)
            let completed = try rebuild(root, output, accounts)
            for _ in 0..<2 {
                let store = try ItemStore.ReadQualification(
                    recoveredContent: completed, accounts: accounts, configuration: configuration())
                try store.withAccess(forUID: accounts.bob) {
                    XCTAssertEqual(try store.get(first.itemID), current)
                    XCTAssertEqual(try store.get(first.itemID, revisionID: first.revisionID), first)
                    XCTAssertEqual(try store.history(first.itemID), [current, first])
                    XCTAssertEqual(try store.candidates(text: "sunflower"), [current])
                    XCTAssertEqual(
                        try store.query(expression: "subject == \"searchable sunflower\"", text: "sunflower"),
                        [current])
                    XCTAssertTrue(try store.candidates(text: "secret").isEmpty)
                    XCTAssertEqual(try store.get(dead.itemID), dead)
                    XCTAssertEqual(try store.history(dead.itemID), [dead, deadFirst])
                    XCTAssertEqual(try store.candidates().map(\.itemID), [first.itemID])
                }
                XCTAssertEqual(try fingerprint(root), before)
            }
            // Drop every derived file and rebuild again from exactly the same selected originals.
            try FileManager.default.removeItem(at: output)
            let rebuilt = try rebuild(root, output, accounts)
            let store = try ItemStore.ReadQualification(
                recoveredContent: rebuilt, accounts: accounts, configuration: configuration())
            XCTAssertEqual(try store.get(first.itemID), current)
            XCTAssertEqual(try fingerprint(root), before)
        }
    }

    func testCurrentPrivateACLProtectsEntireHistoryAndSearch() throws {
        try fixture { root, output, accounts in
            let first = try revision(subject: "once public")
            let current = try revision(
                item: first.itemID, parents: [first.revisionID], subject: "now private", second: 1,
                permission: permissions(mode: 0o600))
            for value in [first, current] { try save(value, root) }
            let completed = try rebuild(root, output, accounts)
            let store = try ItemStore.ReadQualification(
                recoveredContent: completed, accounts: accounts, configuration: configuration())
            try store.withAccess(forUID: accounts.bob) {
                assertCode("forbidden") { _ = try store.get(first.itemID) }
                assertCode("forbidden") { _ = try store.get(first.itemID, revisionID: first.revisionID) }
                assertCode("forbidden") { _ = try store.history(first.itemID) }
                XCTAssertTrue(try store.candidates(text: "private").isEmpty)
                XCTAssertTrue(try store.candidates().isEmpty)
            }
            try store.withAccess(forUID: accounts.alice) {
                XCTAssertEqual(try store.history(first.itemID), [current, first])
            }
        }
    }

    func testUniquePhysicalMergeHeadRetainsBothParentsWithoutClockWinner() throws {
        try fixture { root, output, accounts in
            let first = try revision()
            let left = try revision(item: first.itemID, parents: [first.revisionID], second: 5, modern: true)
            let right = try revision(item: first.itemID, parents: [first.revisionID], second: 6, modern: true)
            let merge = try revision(
                item: first.itemID, parents: [left.revisionID, right.revisionID],
                subject: "explicit merge", second: 7, modern: true)
            for value in [merge, right, first, left] { try save(value, root) }
            let before = try fingerprint(root)
            let completed = try rebuild(root, output, accounts)
            let store = try ItemStore.ReadQualification(
                recoveredContent: completed, accounts: accounts, configuration: configuration())
            XCTAssertEqual(try store.get(first.itemID), merge)
            XCTAssertEqual(try store.history(first.itemID), [merge, right, left, first])
            XCTAssertEqual(
                try store.get(first.itemID).provenance?.parents, [left.revisionID, right.revisionID].sorted())
            XCTAssertEqual(try fingerprint(root), before)
        }
    }

    func testUnresolvedHeadsFailBeforePublishingAnyDatabase() throws {
        try fixture { root, output, accounts in
            let first = try revision()
            let left = try revision(item: first.itemID, parents: [first.revisionID], second: 1)
            let right = try revision(
                item: first.itemID, parents: [first.revisionID], second: 2, deleted: true)
            for value in [first, left, right] { try save(value, root) }
            let before = try fingerprint(root)
            XCTAssertThrowsError(try rebuild(root, output, accounts)) { error in
                let diagnostics = (error as? PersonalRecoveryIndex.Incomplete)?.diagnostics
                XCTAssertEqual(diagnostics?.map(\.kind), [.unresolvedHeads])
                XCTAssertEqual(diagnostics?.first?.itemID, first.itemID)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
            XCTAssertEqual(try fingerprint(root), before)
        }
    }

    func testUnknownCurrentPrincipalFailsAndRemovesStagedDatabase() throws {
        try fixture { root, output, accounts in
            try save(revision(permission: permissions("missing")), root)
            let before = try fingerprint(root)
            assertCode("unresolvedPrincipal") { _ = try rebuild(root, output, accounts) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
            XCTAssertEqual(try fingerprint(root), before)
            XCTAssertFalse(
                try FileManager.default.contentsOfDirectory(atPath: output.deletingLastPathComponent().path)
                    .contains { $0.hasPrefix(".personal-index-") })
        }
    }

    func testCurrentUnixGroupMembershipIsRefreshedForHistory() throws {
        try fixture { root, output, accounts in
            let first = try revision()
            let current = try revision(
                item: first.itemID, parents: [first.revisionID], second: 1,
                permission: permissions(mode: 0o640))
            for value in [first, current] { try save(value, root) }
            let before = try fingerprint(root)
            let completed = try rebuild(root, output, accounts)
            let store = try ItemStore.ReadQualification(
                recoveredContent: completed, accounts: accounts, configuration: configuration())
            try store.withAccess(forUID: accounts.bob) {
                XCTAssertEqual(try store.history(first.itemID), [current, first])
            }
            accounts.users.removeAll { $0.uid == accounts.bob }
            accounts.users.append(
                AccountIdentity(
                    uid: accounts.bob, name: "bob", primaryGroupName: "other", groupIDs: [70002]))
            try store.withAccess(forUID: accounts.bob) {
                assertCode("forbidden") { _ = try store.history(first.itemID) }
                assertCode("forbidden") { _ = try store.get(first.itemID, revisionID: first.revisionID) }
                XCTAssertTrue(try store.candidates().isEmpty)
            }
            XCTAssertEqual(try fingerprint(root), before)
        }
    }

    func testMissingParentAndUnsafeCanonicalLeafNeverPublishPartialDatabase() throws {
        try fixture { root, output, accounts in
            let orphan = try revision(parents: [id()])
            try save(orphan, root)
            try write(
                Data("unsafe".utf8), root: root, path: "items/2026/10/24/11/01/unsafe/bad.tractanda",
                mode: 0o644)
            let before = try fingerprint(root)
            XCTAssertThrowsError(try rebuild(root, output, accounts)) { error in
                let kinds = (error as? PersonalRecoveryIndex.Incomplete)?.diagnostics.map(\.kind) ?? []
                XCTAssertTrue(kinds.contains(.missingParent))
                XCTAssertTrue(kinds.contains(.invalidEntry))
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
            XCTAssertEqual(try fingerprint(root), before)
        }
    }

    func testSymlinkedDestinationAncestorCannotPutDerivedFilesInsideCanonicalTree() throws {
        try fixture { root, output, accounts in
            try save(revision(), root)
            let alias = output.deletingLastPathComponent().appendingPathComponent("alias")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
            let before = try fingerprint(root)
            assertCode("invalidRecoveryScope") {
                _ = try rebuild(root, alias.appendingPathComponent("derived"), accounts)
            }
            XCTAssertEqual(try fingerprint(root), before)
        }
    }

    func testFailedCanonicalReadQuarantinesMemoryWithoutWritingSourceCheckpoint() throws {
        try fixture { root, output, accounts in
            let original = try revision()
            try save(original, root)
            let completed = try rebuild(root, output, accounts)
            let store = try ItemStore.ReadQualification(
                recoveredContent: completed, accounts: accounts, configuration: configuration())
            let path = "items/2026/10/24/11/01/\(original.itemID)/\(original.revisionID).tractanda"
            try write(Data("corrupt private fixture".utf8), root: root, path: path)
            let afterCorruption = try fingerprint(root)
            XCTAssertThrowsError(try store.get(original.itemID))
            XCTAssertFalse(store.isCanonicalTrusted)
            XCTAssertEqual(try fingerprint(root), afterCorruption)
        }
    }

    func testRebuildSearchesPage137AndCurrentACLProtectsDocumentHistory() throws {
        try fixture { root, output, accounts in
            let document = try savedDocument(
                root, pages: 137, token: "latepageobservatory", permission: permissions(mode: 0o600))
            let ordinary = try revision(subject: "ordinary visible item")
            try save(ordinary, root)
            let before = try fingerprint(root)
            let context = try id()
            let completed = try rebuild(root, output, accounts, contextID: context)
            XCTAssertEqual(completed.rebuildContextID, context)
            for _ in 0..<2 {
                let reader = try ItemStore.ReadQualification(
                    recoveredContent: completed, accounts: accounts, configuration: configuration())
                try reader.withAccess(forUID: accounts.alice) {
                    XCTAssertEqual(try reader.candidates(text: "latepageobservatory"), [document.saved])
                    XCTAssertEqual(
                        try reader.query(
                            expression: "subject == \"document current\"", text: "latepageobservatory"),
                        [document.saved])
                    XCTAssertEqual(try reader.history(document.base.itemID), [document.saved, document.base])
                }
                try reader.withAccess(forUID: accounts.bob) {
                    XCTAssertTrue(try reader.candidates(text: "latepageobservatory").isEmpty)
                    assertCode("forbidden") {
                        _ = try reader.get(document.base.itemID, revisionID: document.base.revisionID)
                    }
                    assertCode("forbidden") { _ = try reader.history(document.base.itemID) }
                    XCTAssertEqual(try reader.candidates(), [ordinary])
                }
                XCTAssertEqual(try fingerprint(root), before)
            }
        }
    }

    func testInlineDocumentsSavedTextReplacementAndTombstoneUseCurrentCorpus() throws {
        try fixture { root, output, accounts in
            let inline = try savedDocument(root, pages: 2, inline: true, token: "historicalinlinevisible")
            let replaced = try savedDocument(root, pages: 1, inline: true, token: "obsoletecorpusword")
            let replacement = try revision(
                item: replaced.base.itemID, parents: [replaced.saved.revisionID],
                subject: "replacement current", second: 2,
                extra: ["attachments": try XCTUnwrap(replaced.saved.fields["attachments"])])
            try save(replacement, root)
            let removed = try savedDocument(root, pages: 1, inline: true, token: "deletedcorpusword")
            let tombstone = try revision(
                item: removed.base.itemID, parents: [removed.saved.revisionID], second: 2, deleted: true,
                extra: [
                    "attachments": try XCTUnwrap(removed.saved.fields["attachments"]),
                    "attachmentDocument": try XCTUnwrap(removed.saved.fields["attachmentDocument"]),
                ])
            try save(tombstone, root)
            let textOriginal = try attachment(root, text: "savedtexttelescope", mediaType: "text/plain")
            let textBase = try revision(extra: ["attachments": .list([textOriginal.itemValue])])
            let textSource = try AttachmentTextSource(
                itemID: textBase.itemID, revisionID: textBase.revisionID,
                attachmentID: textOriginal.attachmentID,
                sha256: textOriginal.sha256, byteCount: textOriginal.byteCount,
                mediaType: textOriginal.mediaType)
            let text = try AttachmentTextRepresentation(
                representationID: id(), attachmentID: textOriginal.attachmentID, source: textSource,
                extractedAt: "2026-10-24T10:00:00Z", text: "savedtexttelescope", sourceByteStart: 0)
            let textCurrent = try revision(
                item: textBase.itemID, parents: [textBase.revisionID], second: 1,
                extra: [
                    "attachments": .list([textOriginal.itemValue]), "attachmentText": .list([text.itemValue]),
                ])
            for value in [textBase, textCurrent] { try save(value, root) }
            let before = try fingerprint(root)
            let completed = try rebuild(root, output, accounts)
            let reader = try ItemStore.ReadQualification(
                recoveredContent: completed, accounts: accounts, configuration: configuration())
            try reader.withAccess(forUID: accounts.bob) {
                XCTAssertEqual(try reader.candidates(text: "historicalinlinevisible"), [inline.saved])
                XCTAssertEqual(try reader.candidates(text: "savedtexttelescope"), [textCurrent])
                XCTAssertTrue(try reader.candidates(text: "obsoletecorpusword").isEmpty)
                XCTAssertTrue(try reader.candidates(text: "deletedcorpusword").isEmpty)
                XCTAssertEqual(try reader.get(replaced.base.itemID), replacement)
                XCTAssertEqual(
                    try reader.get(replaced.base.itemID, revisionID: replaced.saved.revisionID),
                    replaced.saved)
                XCTAssertEqual(try reader.get(removed.base.itemID), tombstone)
                XCTAssertEqual(
                    try reader.history(removed.base.itemID), [tombstone, removed.saved, removed.base])
            }
            XCTAssertEqual(try fingerprint(root), before)
        }
    }

    func testMissingSavedPageFailsFactoryWithoutPublishingOrChangingSelectedFiles() throws {
        try fixture { root, output, accounts in
            let document = try savedDocument(root, pages: 3, token: "missing page fixture")
            let base = try XCTUnwrap(document.documentPath)
            try FileManager.default.removeItem(at: root.appendingPathComponent(base + "/pages/0/3.json"))
            let before = try fingerprint(root)
            XCTAssertThrowsError(try rebuild(root, output, accounts)) { error in
                XCTAssertTrue(
                    (error as? PersonalRecoveryIndex.Incomplete)?.diagnostics.contains {
                        $0.kind == .invalidPayload
                    } == true)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
            XCTAssertEqual(try fingerprint(root), before)
        }
    }

    func testCorruptSavedPageFailsFactoryWithoutPublishingOrChangingSelectedFiles() throws {
        try fixture { root, output, accounts in
            let document = try savedDocument(root, pages: 3, token: "corrupt page fixture")
            let base = try XCTUnwrap(document.documentPath)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: root.appendingPathComponent(base + "/pages/0/3.json").path)
            try write(
                Data("corrupt encoded page".utf8), root: root, path: base + "/pages/0/3.json", mode: 0o400)
            let before = try fingerprint(root)
            XCTAssertThrowsError(try rebuild(root, output, accounts)) { error in
                XCTAssertTrue(
                    (error as? PersonalRecoveryIndex.Incomplete)?.diagnostics.contains {
                        $0.kind == .invalidPayload
                    } == true)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
            XCTAssertEqual(try fingerprint(root), before)
        }
    }

    func testAggregateReconstructionReadBudgetIncludesRecordsManifestNodesAndPages() throws {
        try fixture { root, output, accounts in
            _ = try savedDocument(root, pages: 3, token: "bounded page fixture")
            let inventory = try PersonalRecoveryInventory.inspect([.init(root: root, ownerUID: getuid())])
            XCTAssertFalse(inventory.validatedDocumentLocations.isEmpty)
            let before = try fingerprint(root)
            for records in [false, true] {
                var limits = PersonalRecoveryInventory.Limits()
                if records {
                    limits.maximumTotalRecordBytes = inventory.recordBytesBudgeted
                } else {
                    limits.maximumTotalPayloadBytes = inventory.payloadBytesBudgeted
                }
                assertCode("resourceLimit") {
                    _ = try rebuild(root, output, accounts, inventoryLimits: limits)
                }
                XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
                XCTAssertEqual(try fingerprint(root), before)
                XCTAssertFalse(
                    try FileManager.default.contentsOfDirectory(
                        atPath: output.deletingLastPathComponent().path
                    )
                    .contains { $0.hasPrefix(".personal-index-") })
            }
        }
    }
}
